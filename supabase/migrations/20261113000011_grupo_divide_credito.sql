-- =====================================================================
-- Gincana de Halloween — 11: jogos por grupo dividem pontos e dinheiro
--                            (opcional) e crédito do ADM até R$ 100 milhões
-- =====================================================================
-- Jogo por grupo ganha a opção "marcar pontos e dinheiro" (jogo.grupo_pontua):
--   * desmarcada (padrão dos jogos novos): o resultado só registra quem
--     ganhou — não conta vitória, pontos nem dinheiro para ninguém, nem no
--     placar de grupos (resultado.conta = false, pontos 0, R$ 0);
--   * marcada: os pontos e o dinheiro do grupo são divididos igualmente
--     entre os integrantes. Pontos inteiros, arredondados para baixo
--     (10 ÷ 3 = 3 cada). Dinheiro em centavos: R$ 100 ÷ 3 = 33,34 + 33,33 +
--     33,33 (o centavo que sobra vai para o 1º em ordem alfabética).
--     No placar de grupos conta a soma do que os integrantes receberam.
-- Mudar a opção num jogo com resultado apaga o resultado (como o formato).
-- Jogos por grupo que já existiam ficam com a opção MARCADA (continuam
-- contando); o resultado já gravado só é dividido quando for salvo de novo.

-- 1) Colunas novas
alter table public.jogo add column grupo_pontua boolean not null default true;   -- já existentes: marcados
alter table public.jogo alter column grupo_pontua set default false;               -- novos: desmarcados
alter table public.resultado add column conta boolean not null default true;

grant insert (grupo_pontua), update (grupo_pontua) on public.jogo to authenticated;

-- 2) Mudar a opção apaga o resultado (como mudar o formato)
create or replace function public.tg_jogo_formato_mudou()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.modo is distinct from old.modo or new.formato is distinct from old.formato
     or new.grupo_pontua is distinct from old.grupo_pontua then
    delete from public.resultado r where r.jogo_id = new.id;
    new.pontuado_em := null;
  end if;
  return new;
end;
$$;

drop trigger jogo_formato_mudou on public.jogo;
create trigger jogo_formato_mudou before update of modo, formato, grupo_pontua on public.jogo
  for each row execute function public.tg_jogo_formato_mudou();

-- 3) Registrar resultado: divide ou só registra
create or replace function public.fn_admin_registrar_resultado(p_jogo_id uuid, p_itens jsonb)
returns integer
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_j       public.jogo%rowtype;
  v_antigos jsonb;
  v_item    jsonb;
  v_col     integer;
  v_pts     integer;
  v_prz     numeric;
  v_pessoa  uuid;
  v_grupo   uuid;
  v_k       integer;
  v_n       integer := 0;
  v_qtd     integer;
  v_cent    bigint;
begin
  perform public.fn_exige_admin();

  if not (select e.aberto from public.evento e where e.id = 1) then
    raise exception 'O período de jogos está encerrado. Reabra o período na aba Leilão para cadastrar ou pontuar.'
      using errcode = 'P0001';
  end if;

  select * into v_j from public.jogo j where j.id = p_jogo_id for update;
  if not found then
    raise exception 'Jogo não encontrado' using errcode = 'P0002';
  end if;

  if p_itens is null or jsonb_typeof(p_itens) <> 'array' then
    raise exception 'Resultado inválido: envie uma lista.' using errcode = '22023';
  end if;

  select coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb) into v_antigos
    from public.resultado r where r.jogo_id = v_j.id;
  delete from public.resultado r where r.jogo_id = v_j.id;

  for v_item in select value from jsonb_array_elements(p_itens) loop
    v_col := coalesce((v_item->>'colocacao')::integer, 1);
    if v_col not between 1 and 3 or (v_j.formato = 'vitoria' and v_col <> 1) then
      raise exception 'Colocação inválida para este jogo: %', v_col using errcode = '22023';
    end if;

    v_pts := coalesce((v_item->>'pontos')::integer,
               case when v_j.formato = 'vitoria' then v_j.pontos
                    when v_col = 1 then v_j.pontos_1
                    when v_col = 2 then v_j.pontos_2
                    else v_j.pontos_3 end);
    v_prz := coalesce((v_item->>'premio')::numeric,
               case when v_j.formato = 'vitoria' then v_j.premio
                    when v_col = 1 then v_j.premio_1
                    when v_col = 2 then v_j.premio_2
                    else v_j.premio_3 end);

    if v_j.modo = 'individual' then
      v_pessoa := (v_item->>'pessoa_id')::uuid;
      if v_pessoa is null or not exists (
           select 1 from public.participacao pa
            where pa.jogo_id = v_j.id and pa.pessoa_id = v_pessoa) then
        raise exception 'Essa pessoa não participa deste jogo.' using errcode = '22023';
      end if;
      insert into public.resultado (jogo_id, pessoa_id, grupo_id, colocacao, pontos, premio, registrado_em)
      values (v_j.id, v_pessoa, null, v_col, v_pts, v_prz,
              public.fn_horario_mantido(v_antigos, v_pessoa, v_col, v_pts));
      v_n := v_n + 1;
    else
      v_grupo := (v_item->>'grupo_id')::uuid;
      if v_grupo is null or not exists (
           select 1 from public.jogo_grupo jg
            where jg.jogo_id = v_j.id and jg.grupo_id = v_grupo) then
        raise exception 'Esse grupo não participa deste jogo.' using errcode = '22023';
      end if;
      if not v_j.grupo_pontua then
        -- sem "marcar pontos e dinheiro": só registra quem ganhou; não conta
        -- vitória, pontos nem dinheiro para ninguém
        insert into public.resultado (jogo_id, pessoa_id, grupo_id, colocacao, pontos, premio, registrado_em, conta)
        select v_j.id, p.id, v_grupo, v_col, 0, 0,
               public.fn_horario_mantido(v_antigos, p.id, v_col, 0), false
          from public.pessoa p
         where p.grupo_id = v_grupo;
      else
        -- divide igualmente entre os integrantes: pontos inteiros (a sobra
        -- é descartada); dinheiro em centavos, o centavo que sobra vai para
        -- os primeiros em ordem alfabética (a soma bate com o valor do grupo)
        select count(*) into v_qtd from public.pessoa p where p.grupo_id = v_grupo;
        v_cent := round(v_prz * 100)::bigint;
        if v_qtd > 0 then                     -- grupo sem membros: nada a dividir
        insert into public.resultado (jogo_id, pessoa_id, grupo_id, colocacao, pontos, premio, registrado_em, conta)
        select v_j.id, m.id, v_grupo, v_col, v_pts / v_qtd,
               ((v_cent / v_qtd) + case when m.ordem <= v_cent % v_qtd then 1 else 0 end) / 100.0,
               public.fn_horario_mantido(v_antigos, m.id, v_col, v_pts / v_qtd), true
          from (select p.id, row_number() over (order by lower(p.nome), p.id) as ordem
                  from public.pessoa p
                 where p.grupo_id = v_grupo) m;
        end if;
      end if;
      get diagnostics v_k = row_count;
      v_n := v_n + v_k;
    end if;
  end loop;

  update public.jogo j set pontuado_em = clock_timestamp() where j.id = v_j.id;
  return v_n;
exception
  when unique_violation then
    raise exception 'A mesma pessoa ou grupo aparece mais de uma vez no resultado.'
      using errcode = '22023';
end;
$$;

-- 4) Somas: só resultados que contam
create or replace function public.fn_estatisticas()
returns table (pessoa_id uuid, vitorias integer, colocacoes integer, pontos integer,
               premio numeric, alcancou_em timestamptz)
language sql stable security definer
set search_path = ''
as $$
  select p.id,
         (count(r.id) filter (where r.colocacao = 1))::integer,
         (count(r.id) filter (where r.colocacao > 1))::integer,
         coalesce(sum(r.pontos), 0)::integer,
         coalesce(sum(r.premio), 0)::numeric(12,2),
         max(r.registrado_em)
    from public.pessoa p
    left join public.resultado r on r.pessoa_id = p.id and r.conta
   group by p.id;
$$;

create or replace function public.fn_placar_grupos_base()
returns table (grupo_id uuid, nome text, icone text, cor text, membros integer,
               pontos integer, vitorias integer, premio numeric,
               posicao integer, ordem integer)
language sql stable security definer
set search_path = ''
as $$
  with por_grupo as (
    select r.grupo_id, r.jogo_id,
           min(r.colocacao) as colocacao, sum(r.pontos) as pontos, sum(r.premio) as premio
      from public.resultado r
      join public.jogo j on j.id = r.jogo_id
     where j.modo = 'grupo' and r.grupo_id is not null and r.conta
     group by r.grupo_id, r.jogo_id
  ),
  individuais as (
    select p.grupo_id, r.colocacao, r.pontos, r.premio
      from public.resultado r
      join public.jogo j on j.id = r.jogo_id
      join public.pessoa p on p.id = r.pessoa_id
     where j.modo = 'individual' and p.grupo_id is not null
  ),
  tudo as (
    select t.grupo_id, t.colocacao, t.pontos, t.premio from por_grupo t
    union all
    select i.grupo_id, i.colocacao, i.pontos, i.premio from individuais i
  ),
  tot as (
    select g.id, g.nome, g.icone, g.cor,
           (select count(*) from public.pessoa p where p.grupo_id = g.id)::integer as membros,
           coalesce(sum(t.pontos), 0)::integer as pontos,
           (count(t.colocacao) filter (where t.colocacao = 1))::integer as vitorias,
           coalesce(sum(t.premio), 0)::numeric(12,2) as premio
      from public.grupo g
      left join tudo t on t.grupo_id = g.id
     group by g.id
  )
  select t.id, t.nome, t.icone, t.cor, t.membros, t.pontos, t.vitorias, t.premio,
         case when t.pontos > 0 or t.vitorias > 0
              then (dense_rank() over (order by t.pontos desc, t.vitorias desc))::integer end,
         (row_number() over (order by t.pontos desc, t.vitorias desc, lower(t.nome), t.id))::integer
    from tot t;
$$;

-- Vencedores: grupo mostra o total que o grupo recebeu (sem pontos se não conta)
create or replace function public.fn_vencedores(p_jogo_id uuid)
returns jsonb
language sql stable security definer
set search_path = ''
as $$
  select case when j.modo = 'grupo' then
           coalesce((
             select jsonb_agg(jsonb_build_object(
                      'grupo_id', x.grupo_id, 'nome', g.nome, 'icone', g.icone, 'cor', g.cor,
                      'colocacao', x.colocacao, 'pontos', x.pontos, 'cada', true)
                    order by x.colocacao, lower(g.nome))
               from (select r.grupo_id, min(r.colocacao) as colocacao,
                            case when bool_and(r.conta) then sum(r.pontos) end as pontos
                       from public.resultado r
                      where r.jogo_id = j.id and r.grupo_id is not null
                      group by r.grupo_id) x
               join public.grupo g on g.id = x.grupo_id), '[]'::jsonb)
         else
           coalesce((
             select jsonb_agg(jsonb_build_object(
                      'pessoa_id', p.id, 'nome', p.nome,
                      'colocacao', r.colocacao, 'pontos', r.pontos)
                    order by r.colocacao, lower(p.nome))
               from public.resultado r
               join public.pessoa p on p.id = r.pessoa_id
              where r.jogo_id = j.id), '[]'::jsonb)
         end
    from public.jogo j
   where j.id = p_jogo_id;
$$;

-- Meu painel: "minhas vitórias e colocações" só com o que conta
create or replace function public.fn_meu_painel(p_token text)
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_eu  uuid := public.fn_sessao_pessoa(p_token);
  v_lib boolean := public.fn_ranking_liberado();
  v_r   jsonb;
begin
  select jsonb_build_object(
      'evento', (select jsonb_build_object('nome', e.nome, 'aberto', e.aberto, 'ranking_visivel', v_lib)
                   from public.evento e where e.id = 1),
      'pessoa_id', r.pessoa_id,
      'nome', r.nome,
      'grupo', public.fn_grupo_json(r.grupo_id),
      'vitorias', r.vitorias,
      'colocacoes', r.colocacoes,
      'qtd_jogos', (select count(*) from public.fn_jogos_da_pessoa(v_eu)),
      'premio', r.premio,
      'ganho', s.ganho,
      'credito', s.credito,
      'recebido', s.recebido,
      'doado', s.doado,
      'gasto', s.gasto,
      'saldo', s.saldo,
      'arremates', public.fn_arremates_json(v_eu),
      'doacoes', public.fn_doacoes_json(v_eu),
      'resultados', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'jogo_id', j.id, 'jogo', j.nome, 'partida', public.fn_partida(j.id),
                 'tipo', j.tipo, 'modo', j.modo, 'formato', j.formato,
                 'colocacao', x.colocacao, 'premio', x.premio)
               || case when v_lib then jsonb_build_object('pontos', x.pontos) else '{}'::jsonb end
               order by x.colocacao, x.registrado_em)
          from public.resultado x
          join public.jogo j on j.id = x.jogo_id
         where x.pessoa_id = v_eu and x.conta), '[]'::jsonb))
    || case when v_lib then jsonb_build_object('pontos', r.pontos, 'posicao', r.posicao,
                                               'empate', r.empate, 'no_desempate', r.no_desempate)
            else '{}'::jsonb end
    into v_r
    from public.fn_ranking_base() r
    join public.fn_saldos() s on s.pessoa_id = r.pessoa_id
   where r.pessoa_id = v_eu;
  return v_r;
end;
$$;

-- Meus jogos: o participante vê se o prêmio do grupo é dividido
create or replace function public.fn_meus_jogos(p_token text)
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_eu uuid := public.fn_sessao_pessoa(p_token);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', j.id, 'nome', j.nome, 'partida', public.fn_partida(j.id),
             'tipo', j.tipo, 'descricao', j.descricao,
             'modo', j.modo, 'formato', j.formato,
             'divide_premio', j.modo = 'grupo' and j.grupo_pontua)
           order by lower(j.nome), j.numero_partida)
      from public.jogo j
      join public.fn_jogos_da_pessoa(v_eu) m on m.jogo_id = j.id), '[]'::jsonb);
end;
$$;

-- Nova partida copia a opção
create or replace function public.fn_admin_nova_partida(p_jogo_id uuid)
returns uuid
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_j    public.jogo%rowtype;
  v_num  integer;
  v_novo uuid;
begin
  perform public.fn_exige_admin();

  select * into v_j from public.jogo j where j.id = p_jogo_id;
  if not found then
    raise exception 'Jogo não encontrado' using errcode = 'P0002';
  end if;
  -- trava a série: duas "nova partida" ao mesmo tempo não repetem o número
  perform 1 from public.jogo j where j.serie_id = v_j.serie_id for update;
  select max(j.numero_partida) + 1 into v_num from public.jogo j where j.serie_id = v_j.serie_id;

  insert into public.jogo (nome, tipo, descricao, modo, formato, pontos, premio,
                           pontos_1, premio_1, pontos_2, premio_2, pontos_3, premio_3,
                           grupo_pontua, serie_id, numero_partida)
  values (v_j.nome, v_j.tipo, v_j.descricao, v_j.modo, v_j.formato, v_j.pontos, v_j.premio,
          v_j.pontos_1, v_j.premio_1, v_j.pontos_2, v_j.premio_2, v_j.pontos_3, v_j.premio_3,
          v_j.grupo_pontua, v_j.serie_id, v_num)
  returning id into v_novo;           -- evento encerrado: o gatilho recusa

  if v_j.modo = 'grupo' then
    insert into public.jogo_grupo (jogo_id, grupo_id)
    select v_novo, jg.grupo_id from public.jogo_grupo jg where jg.jogo_id = v_j.id;
  end if;
  return v_novo;
end;
$$;

-- 5) Crédito do ADM: até R$ 100.000.000,00
create or replace function public.fn_admin_creditar(p_para uuid, p_valor numeric, p_motivo text)
returns void
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_motivo text := btrim(coalesce(p_motivo, ''));
begin
  perform public.fn_exige_admin();
  if p_para is null or not exists (select 1 from public.pessoa p where p.id = p_para) then
    raise exception 'Escolha para quem creditar.' using errcode = '22023';
  end if;
  if p_valor is null or p_valor <= 0 then
    raise exception 'Informe o valor.' using errcode = '22023';
  end if;
  if p_valor <> round(p_valor, 2) then
    raise exception 'Use no máximo 2 casas decimais no valor.' using errcode = '22023';
  end if;
  if p_valor > 100000000 then
    raise exception 'Valor alto demais (máximo R$ 100.000.000,00).' using errcode = '22023';
  end if;
  if char_length(v_motivo) > 60 then
    raise exception 'O motivo pode ter até 60 caracteres.' using errcode = '22023';
  end if;

  insert into public.transferencia (origem, de_pessoa_id, para_pessoa_id, valor, motivo)
  values ('admin', null, p_para, p_valor, v_motivo);
end;
$$;

-- create or replace mantém as permissões das funções (conferidas na migração 8)
