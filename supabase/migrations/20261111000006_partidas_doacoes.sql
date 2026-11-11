-- =====================================================================
-- Gincana de Halloween — 6: partidas, empates, período de jogos,
-- doações entre participantes e novo evento
-- =====================================================================
-- 1. Partidas: jogos repetidos formam uma série (serie_id) com número da
--    partida. "Nova partida" copia o jogo zerado. Renomear uma partida
--    renomeia a série. Cada partida conta separado no ranking.
-- 2. Ranking sem desempate por horário: iguais nos dois critérios dividem
--    a colocação e a seguinte é a próxima (1º, 2º, 2º, 3º — dense_rank).
-- 3. Textos: "evento encerrado" passa a ser "período de jogos encerrado".
-- 4. Doações: o PARTICIPANTE doa dinheiro a outro (fn_doar, identificado
--    pelo token, nunca por parâmetro). Saldo = ganho + recebido − doado −
--    gasto no leilão. Calculado sempre; nunca guardado em coluna.
-- 5. Novo evento: o admin apaga os dados do evento atual e começa outro,
--    mantendo (se quiser) pessoas e grupos.

-- =====================================================================
-- 1. Partidas
-- =====================================================================
alter table public.jogo
  add column serie_id       uuid,
  add column numero_partida integer not null default 1 check (numero_partida > 0);
update public.jogo set serie_id = id where serie_id is null;
alter table public.jogo alter column serie_id set not null;
alter table public.jogo add constraint jogo_serie_partida_unica unique (serie_id, numero_partida);

-- Jogo novo (fora de fn_admin_nova_partida) começa a própria série
create function public.tg_jogo_serie()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.serie_id is null then
    new.serie_id := new.id;
    new.numero_partida := 1;
  end if;
  return new;
end;
$$;
create trigger jogo_serie before insert on public.jogo
  for each row execute function public.tg_jogo_serie();

-- Renomear (nome/tipo) uma partida renomeia todas da série
create function public.tg_jogo_renomeia_serie()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if pg_trigger_depth() > 1 then
    return null;
  end if;
  update public.jogo j
     set nome = new.nome, tipo = new.tipo
   where j.serie_id = new.serie_id and j.id <> new.id
     and (j.nome, j.tipo) is distinct from (new.nome, new.tipo);
  return null;
end;
$$;
create trigger jogo_renomeia_serie after update of nome, tipo on public.jogo
  for each row when ((old.nome, old.tipo) is distinct from (new.nome, new.tipo))
  execute function public.tg_jogo_renomeia_serie();

-- Número da partida para exibir ("Partida 2"), ou null se a série só tem uma
create function public.fn_partida(p_jogo_id uuid)
returns integer
language sql stable security definer
set search_path = ''
as $$
  select case when (select count(*) from public.jogo x where x.serie_id = j.serie_id) > 1
              then j.numero_partida end
    from public.jogo j
   where j.id = p_jogo_id;
$$;

-- Nova partida: cópia zerada (sem participantes e sem resultado) do jogo.
-- Por grupo: mantém os grupos escolhidos. Devolve o id da nova partida.
create function public.fn_admin_nova_partida(p_jogo_id uuid)
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
                           serie_id, numero_partida)
  values (v_j.nome, v_j.tipo, v_j.descricao, v_j.modo, v_j.formato, v_j.pontos, v_j.premio,
          v_j.pontos_1, v_j.premio_1, v_j.pontos_2, v_j.premio_2, v_j.pontos_3, v_j.premio_3,
          v_j.serie_id, v_num)
  returning id into v_novo;           -- evento encerrado: o gatilho recusa

  if v_j.modo = 'grupo' then
    insert into public.jogo_grupo (jogo_id, grupo_id)
    select v_novo, jg.grupo_id from public.jogo_grupo jg where jg.jogo_id = v_j.id;
  end if;
  return v_novo;
end;
$$;

-- =====================================================================
-- 2. Ranking: sem desempate por horário (dense_rank)
-- =====================================================================
--   aberto    → 1) vitórias 2) pontos
--   encerrado → 1) pontos   2) vitórias
-- Iguais nos dois critérios = mesma colocação ("empate"); a seguinte é a
-- próxima (1º, 2º, 2º, 3º). "no_desempate": empatou no 1º critério e foi
-- separado pelo 2º. Quem não pontuou fica sem posição (e no fim).
create or replace function public.fn_ranking_base()
returns table (pessoa_id uuid, nome text, grupo_id uuid,
               vitorias integer, colocacoes integer, pontos integer, premio numeric,
               alcancou_em timestamptz, posicao integer, pontuou boolean,
               empate boolean, no_desempate boolean, ordem integer)
language sql stable security definer
set search_path = ''
as $$
  with ev as (
    select e.aberto from public.evento e where e.id = 1
  ),
  base as (
    select s.pessoa_id, p.nome, p.grupo_id,
           s.vitorias, s.colocacoes, s.pontos, s.premio, s.alcancou_em,
           case when ev.aberto then s.vitorias else s.pontos   end as k1,
           case when ev.aberto then s.pontos   else s.vitorias end as k2,
           (s.vitorias > 0 or s.pontos > 0) as pontuou
      from public.fn_estatisticas() s
      join public.pessoa p on p.id = s.pessoa_id
     cross join ev
  ),
  ord as (
    select b.*,
           dense_rank() over (order by b.k1 desc, b.k2 desc) as pos,
           row_number() over (order by b.k1 desc, b.k2 desc, lower(b.nome), b.pessoa_id) as ord_n,
           count(*) filter (where b.pontuou) over (partition by b.k1) as n_k1,   -- só quem pontuou
           count(*) over (partition by b.k1, b.k2) as n_k12
      from base b
  )
  select o.pessoa_id, o.nome, o.grupo_id,
         o.vitorias, o.colocacoes, o.pontos, o.premio, o.alcancou_em,
         case when o.pontuou then o.pos::integer end,
         o.pontuou,
         o.pontuou and o.n_k12 > 1,
         o.pontuou and o.n_k12 = 1 and o.n_k1 > 1,
         o.ord_n::integer
    from ord o;
$$;

-- Placar de grupos: pontos, depois vitórias, mesma regra de empate
create or replace function public.fn_placar_grupos_base()
returns table (grupo_id uuid, nome text, icone text, cor text, membros integer,
               pontos integer, vitorias integer, premio numeric,
               posicao integer, ordem integer)
language sql stable security definer
set search_path = ''
as $$
  with por_grupo as (
    select r.grupo_id, r.jogo_id,
           min(r.colocacao) as colocacao, max(r.pontos) as pontos, sum(r.premio) as premio
      from public.resultado r
      join public.jogo j on j.id = r.jogo_id
     where j.modo = 'grupo' and r.grupo_id is not null
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

-- =====================================================================
-- 3. Período de jogos (textos) — mesma regra, mensagem nova
-- =====================================================================
create or replace function public.tg_exige_evento_aberto()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if not coalesce((select e.aberto from public.evento e where e.id = 1), true) then
    raise exception 'O período de jogos está encerrado. Reabra o período na aba Leilão para cadastrar ou pontuar.'
      using errcode = 'P0001';
  end if;
  return coalesce(new, old);
end;
$$;

-- fn_admin_registrar_resultado: só a mensagem do período muda
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
      insert into public.resultado (jogo_id, pessoa_id, grupo_id, colocacao, pontos, premio, registrado_em)
      select v_j.id, p.id, v_grupo, v_col, v_pts, v_prz,
             public.fn_horario_mantido(v_antigos, p.id, v_col, v_pts)
        from public.pessoa p
       where p.grupo_id = v_grupo;
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

-- =====================================================================
-- 4. Doações entre participantes
-- =====================================================================
create table public.transferencia (
  id             uuid primary key default gen_random_uuid(),
  de_pessoa_id   uuid not null references public.pessoa(id) on delete cascade,
  para_pessoa_id uuid not null references public.pessoa(id) on delete cascade,
  valor          numeric(12,2) not null check (valor > 0),
  motivo         text not null default '' check (char_length(motivo) <= 60),
  criado_em      timestamptz not null default clock_timestamp(),
  constraint transferencia_outra_pessoa check (de_pessoa_id <> para_pessoa_id)
);
create index transferencia_de_idx   on public.transferencia (de_pessoa_id);
create index transferencia_para_idx on public.transferencia (para_pessoa_id);

alter table public.transferencia enable row level security;
-- admin só lê direto; doar = fn_doar (participante), desfazer = função do admin
create policy transferencia_admin_le on public.transferencia
  for select to authenticated using ((select public.fn_is_admin()));

-- Saldo por pessoa: ganho + recebido − doado − gasto no leilão.
-- (Muda as colunas devolvidas: precisa recriar.)
drop function public.fn_saldos();
create function public.fn_saldos()
returns table (pessoa_id uuid, ganho numeric, recebido numeric, doado numeric,
               gasto numeric, saldo numeric)
language sql stable security definer
set search_path = ''
as $$
  select s.pessoa_id,
         s.premio::numeric(12,2),
         coalesce(tr.recebido, 0)::numeric(12,2),
         coalesce(td.doado, 0)::numeric(12,2),
         coalesce(c.gasto, 0)::numeric(12,2),
         (s.premio + coalesce(tr.recebido, 0) - coalesce(td.doado, 0) - coalesce(c.gasto, 0))::numeric(12,2)
    from public.fn_estatisticas() s
    left join (select x.pessoa_id, sum(x.valor) as gasto
                 from public.caixa x
                where x.pessoa_id is not null
                group by x.pessoa_id) c on c.pessoa_id = s.pessoa_id
    left join (select t.para_pessoa_id as pessoa_id, sum(t.valor) as recebido
                 from public.transferencia t group by t.para_pessoa_id) tr on tr.pessoa_id = s.pessoa_id
    left join (select t.de_pessoa_id as pessoa_id, sum(t.valor) as doado
                 from public.transferencia t group by t.de_pessoa_id) td on td.pessoa_id = s.pessoa_id;
$$;

-- Doações de uma pessoa (feitas e recebidas). Só usada com a pessoa da
-- sessão: traz o nome da outra pessoa, o recado, o valor e o horário.
create function public.fn_doacoes_json(p_pessoa_id uuid)
returns jsonb
language sql stable security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'tipo', case when t.de_pessoa_id = p_pessoa_id then 'feita' else 'recebida' end,
           'nome', o.nome, 'recado', t.motivo, 'valor', t.valor, 'criado_em', t.criado_em)
         order by t.criado_em), '[]'::jsonb)
    from public.transferencia t
    join public.pessoa o
      on o.id = case when t.de_pessoa_id = p_pessoa_id then t.para_pessoa_id else t.de_pessoa_id end
   where p_pessoa_id in (t.de_pessoa_id, t.para_pessoa_id);
$$;

-- Meu painel: + recebido, doado e o extrato de doações; jogos com partida
create or replace function public.fn_meu_painel(p_token text)
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_eu uuid := public.fn_sessao_pessoa(p_token);
begin
  return (
    select jsonb_build_object(
      'evento', (select jsonb_build_object('nome', e.nome, 'aberto', e.aberto)
                   from public.evento e where e.id = 1),
      'pessoa_id', r.pessoa_id,
      'nome', r.nome,
      'grupo', public.fn_grupo_json(r.grupo_id),
      'pontos', r.pontos,
      'vitorias', r.vitorias,
      'colocacoes', r.colocacoes,
      'posicao', r.posicao,
      'empate', r.empate,
      'no_desempate', r.no_desempate,
      'qtd_jogos', (select count(*) from public.fn_jogos_da_pessoa(v_eu)),
      'premio', r.premio,
      'ganho', s.ganho,
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
                 'colocacao', x.colocacao, 'pontos', x.pontos, 'premio', x.premio)
               order by x.colocacao, x.registrado_em)
          from public.resultado x
          join public.jogo j on j.id = x.jogo_id
         where x.pessoa_id = v_eu), '[]'::jsonb))
      from public.fn_ranking_base() r
      join public.fn_saldos() s on s.pessoa_id = r.pessoa_id
     where r.pessoa_id = v_eu);
end;
$$;

-- Meus jogos: + número da partida
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
             'participantes', public.fn_qtd_participantes(j.id),
             'pontuado', j.pontuado_em is not null,
             'meu_resultado', case when r.id is null then null
                                   else jsonb_build_object('colocacao', r.colocacao,
                                                           'pontos', r.pontos,
                                                           'premio', r.premio) end)
           order by (j.pontuado_em is null) desc, lower(j.nome), j.numero_partida)
      from public.jogo j
      join public.fn_jogos_da_pessoa(v_eu) m on m.jogo_id = j.id
      left join public.resultado r on r.jogo_id = j.id and r.pessoa_id = v_eu), '[]'::jsonb);
end;
$$;

-- Resultado final: + número da partida; mensagem do período
create or replace function public.fn_resultado_final(p_token text)
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_eu uuid := public.fn_sessao_pessoa(p_token);
begin
  if (select e.aberto from public.evento e where e.id = 1) then
    raise exception 'O resultado final aparece quando o período de jogos for encerrado.'
      using errcode = 'P0001';
  end if;

  return jsonb_build_object(
    'ranking', coalesce((
      select jsonb_agg(jsonb_build_object(
               'pessoa_id', r.pessoa_id, 'nome', r.nome,
               'grupo', public.fn_grupo_json(r.grupo_id),
               'pontos', r.pontos, 'vitorias', r.vitorias,
               'posicao', r.posicao, 'pontuou', r.pontuou,
               'empate', r.empate, 'no_desempate', r.no_desempate,
               'eu', r.pessoa_id = v_eu)
             order by r.ordem)
        from public.fn_ranking_base() r), '[]'::jsonb),
    'grupos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'grupo_id', g.grupo_id, 'nome', g.nome, 'icone', g.icone, 'cor', g.cor,
               'membros', g.membros, 'pontos', g.pontos, 'vitorias', g.vitorias,
               'posicao', g.posicao)
             order by g.ordem)
        from public.fn_placar_grupos_base() g), '[]'::jsonb),
    'jogos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', j.id, 'nome', j.nome, 'partida', public.fn_partida(j.id), 'tipo', j.tipo,
               'modo', j.modo, 'formato', j.formato,
               'participantes', public.fn_qtd_participantes(j.id),
               'pontuado', j.pontuado_em is not null,
               'vencedores', public.fn_vencedores(j.id))
             order by (j.pontuado_em is not null) desc, lower(j.nome), j.numero_partida)
        from public.jogo j), '[]'::jsonb));
end;
$$;

-- Leilão do participante: + lista de NOMES dos outros (para doar).
-- Nunca o saldo deles.
create or replace function public.fn_leilao(p_token text)
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_eu uuid := public.fn_sessao_pessoa(p_token);
begin
  if (select e.aberto from public.evento e where e.id = 1) then
    raise exception 'O leilão aparece quando o período de jogos for encerrado.' using errcode = 'P0001';
  end if;

  return jsonb_build_object(
    'caixas', coalesce((
      select jsonb_agg(
               jsonb_build_object('numero', c.numero,
                                  'vendida', c.pessoa_id is not null,
                                  'minha', c.pessoa_id is not distinct from v_eu)
               || case when c.pessoa_id = v_eu
                       then jsonb_build_object('conteudo', c.conteudo, 'valor', c.valor,
                                               'vendido_em', c.vendido_em)
                       else '{}'::jsonb end
             order by c.numero)
        from public.caixa c), '[]'::jsonb),
    'pessoas', coalesce((
      select jsonb_agg(jsonb_build_object('id', p.id, 'nome', p.nome) order by lower(p.nome))
        from public.pessoa p
       where p.id <> v_eu), '[]'::jsonb));
end;
$$;

-- Arremate: só a mensagem do período muda
create or replace function public.fn_admin_arrematar(p_caixa_id uuid, p_pessoa_id uuid, p_valor numeric)
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_aberto boolean;
  v_caixa  public.caixa%rowtype;
  v_nome   text;
  v_saldo  numeric;
begin
  perform public.fn_exige_admin();

  -- trava o evento: ninguém reabre no meio do arremate
  select e.aberto into v_aberto from public.evento e where e.id = 1 for share;
  if v_aberto then
    raise exception 'O leilão só acontece com o período de jogos encerrado. Encerre o período no topo da aba Leilão.'
      using errcode = 'P0001';
  end if;

  if p_valor is null or p_valor <= 0 then
    raise exception 'Informe o valor arrematado.' using errcode = '22023';
  end if;
  if p_valor <> round(p_valor, 2) then
    raise exception 'Use no máximo 2 casas decimais no valor.' using errcode = '22023';
  end if;

  select * into v_caixa from public.caixa c where c.id = p_caixa_id for update;
  if not found then
    raise exception 'Caixa não encontrada.' using errcode = 'P0002';
  end if;
  if v_caixa.pessoa_id is not null then
    raise exception 'Essa caixa já foi vendida.' using errcode = 'P0001';
  end if;

  -- trava a pessoa: arremates e doações dela não usam o mesmo saldo
  select p.nome into v_nome from public.pessoa p where p.id = p_pessoa_id for update;
  if not found then
    raise exception 'Escolha quem arrematou.' using errcode = 'P0002';
  end if;

  select s.saldo into v_saldo from public.fn_saldos() s where s.pessoa_id = p_pessoa_id;
  if p_valor > v_saldo then
    raise exception 'Saldo insuficiente: % tem %.', v_nome,
      'R$ ' || replace(to_char(v_saldo, 'FM999999990.00'), '.', ',')
      using errcode = 'P0001';
  end if;

  update public.caixa c
     set pessoa_id = p_pessoa_id, valor = p_valor, vendido_em = clock_timestamp()
   where c.id = p_caixa_id;

  return jsonb_build_object('saldo_antes', v_saldo, 'saldo_depois', v_saldo - p_valor);
end;
$$;

-- Doar (participante). Quem doa = pessoa do TOKEN.
-- Na mesma transação: período encerrado + saldo suficiente.
create function public.fn_doar(p_token text, p_para uuid, p_valor numeric, p_recado text)
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_eu     uuid := public.fn_sessao_pessoa(p_token);
  v_aberto boolean;
  v_saldo  numeric;
  v_recado text := btrim(coalesce(p_recado, ''));
begin
  select e.aberto into v_aberto from public.evento e where e.id = 1 for share;
  if v_aberto then
    raise exception 'As doações abrem junto com o leilão.' using errcode = 'P0001';
  end if;

  if p_para is null or p_para = v_eu
     or not exists (select 1 from public.pessoa p where p.id = p_para) then
    raise exception 'Escolha para quem doar.' using errcode = '22023';
  end if;
  if p_valor is null or p_valor <= 0 then
    raise exception 'Informe o valor.' using errcode = '22023';
  end if;
  if p_valor <> round(p_valor, 2) then
    raise exception 'Use no máximo 2 casas decimais no valor.' using errcode = '22023';
  end if;
  if char_length(v_recado) > 60 then
    raise exception 'O recado pode ter até 60 caracteres.' using errcode = '22023';
  end if;

  -- trava as duas pessoas (sempre na mesma ordem, sem deadlock)
  perform 1 from public.pessoa p where p.id in (v_eu, p_para) order by p.id for update;

  select s.saldo into v_saldo from public.fn_saldos() s where s.pessoa_id = v_eu;
  if p_valor > v_saldo then
    raise exception 'Saldo insuficiente: você tem %.',
      'R$ ' || replace(to_char(v_saldo, 'FM999999990.00'), '.', ',')
      using errcode = 'P0001';
  end if;

  insert into public.transferencia (de_pessoa_id, para_pessoa_id, valor, motivo)
  values (v_eu, p_para, p_valor, v_recado);

  return jsonb_build_object('saldo_antes', v_saldo, 'saldo_depois', v_saldo - p_valor);
end;
$$;

-- Desfazer doação (admin): só se quem recebeu ainda tem esse saldo
create function public.fn_admin_desfazer_doacao(p_id uuid)
returns void
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_t     public.transferencia%rowtype;
  v_nome  text;
  v_saldo numeric;
begin
  perform public.fn_exige_admin();

  select * into v_t from public.transferencia t where t.id = p_id for update;
  if not found then
    raise exception 'Doação não encontrada.' using errcode = 'P0002';
  end if;

  select p.nome into v_nome from public.pessoa p where p.id = v_t.para_pessoa_id for update;
  select s.saldo into v_saldo from public.fn_saldos() s where s.pessoa_id = v_t.para_pessoa_id;
  if v_saldo < v_t.valor then
    raise exception '% já usou parte desse valor. Desfaça antes o arremate que usou o dinheiro.', v_nome
      using errcode = 'P0001';
  end if;

  delete from public.transferencia t where t.id = v_t.id;
end;
$$;

-- =====================================================================
-- 5. Novo evento
-- =====================================================================
-- Apaga jogos, partidas, resultados, caixas, arremates e doações e cria
-- um evento novo, aberto. Opções: manter pessoas (nome e senha) e manter
-- grupos com os membros. Sem grupos, as pessoas mantidas ficam sem grupo.
create function public.fn_admin_novo_evento(p_nome text, p_manter_pessoas boolean, p_manter_grupos boolean)
returns void
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_nome text := btrim(coalesce(p_nome, ''));
begin
  perform public.fn_exige_admin();
  if char_length(v_nome) not between 1 and 80 then
    raise exception 'Informe o nome do novo evento.' using errcode = '22023';
  end if;

  -- abre primeiro: os gatilhos de "período encerrado" deixam apagar
  update public.evento e set nome = v_nome, aberto = true, encerrado_em = null where e.id = 1;

  delete from public.transferencia where true;
  update public.caixa set pessoa_id = null, valor = null, vendido_em = null where pessoa_id is not null;
  delete from public.caixa where true;
  delete from public.resultado where true;
  delete from public.participacao where true;
  delete from public.jogo_grupo where true;
  delete from public.jogo where true;

  if not coalesce(p_manter_pessoas, false) then
    delete from public.pessoa where true;          -- sessões vão junto (cascade)
  elsif not coalesce(p_manter_grupos, false) then
    update public.pessoa set grupo_id = null where grupo_id is not null;
  end if;
  if not coalesce(p_manter_grupos, false) then
    delete from public.grupo where true;
  end if;
end;
$$;

-- =====================================================================
-- Permissões
-- =====================================================================
revoke all on public.transferencia from public, anon, authenticated;
grant select on public.transferencia to authenticated;      -- RLS: só o admin

-- serie_id / numero_partida: o admin lê (select da tabela inteira), mas
-- não escreve direto — séries só por fn_admin_nova_partida.

revoke execute on function
  public.tg_jogo_serie(),
  public.tg_jogo_renomeia_serie(),
  public.fn_partida(uuid),
  public.fn_admin_nova_partida(uuid),
  public.fn_saldos(),
  public.fn_doacoes_json(uuid),
  public.fn_doar(text, uuid, numeric, text),
  public.fn_admin_desfazer_doacao(uuid),
  public.fn_admin_novo_evento(text, boolean, boolean)
from public, anon, authenticated;

grant execute on function public.fn_doar(text, uuid, numeric, text) to anon, authenticated;
grant execute on function
  public.fn_admin_nova_partida(uuid),
  public.fn_admin_desfazer_doacao(uuid),
  public.fn_admin_novo_evento(text, boolean, boolean)
to authenticated;
