-- =====================================================================
-- Gincana de Halloween — 7: ranking oculto, "Meus jogos" só com regras,
-- crédito do ADM e login do admin só com a senha
-- =====================================================================
-- 1. Ranking oculto: os participantes não veem colocação nem pontuação até
--    o período de jogos estar encerrado E o admin tocar em "Exibir ranking"
--    (evento.ranking_visivel). Reabrir o período volta a ocultar. A regra é
--    aplicada AQUI, nas funções do participante — esconder na tela não basta.
--    Enquanto oculto, a lista de vitórias é ordenada por vitórias e depois
--    por nome (nunca pelos pontos, para a ordem não vazar a pontuação).
-- 2. "Meus jogos" devolve só as regras de cada jogo: sem resultado e sem pontos.
-- 3. Crédito do ADM: o admin dá dinheiro a um participante sem tirar de
--    ninguém (transferencia com origem 'admin' e de_pessoa_id nulo).
--    Saldo = ganho + crédito do ADM + doações recebidas − doadas − gasto.
-- 4. Login do admin só com a senha: o app busca o e-mail do admin com
--    fn_email_admin() e entra no Supabase Auth com esse e-mail + a senha.

-- =====================================================================
-- 1. Ranking oculto
-- =====================================================================
alter table public.evento add column ranking_visivel boolean not null default false;

-- Ranking liberado para os participantes?
create function public.fn_ranking_liberado()
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select coalesce((select not e.aberto and e.ranking_visivel from public.evento e where e.id = 1), false);
$$;

-- Lista de vitórias (ranking oculto): sem posição, sem pontos; ordem por
-- vitórias e depois por nome.
create function public.fn_lista_vitorias(p_eu uuid)
returns jsonb
language sql stable security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'pessoa_id', s.pessoa_id, 'nome', p.nome,
           'grupo', public.fn_grupo_json(p.grupo_id),
           'vitorias', s.vitorias, 'eu', s.pessoa_id = p_eu)
         order by s.vitorias desc, lower(p.nome), p.id), '[]'::jsonb)
    from public.fn_estatisticas() s
    join public.pessoa p on p.id = s.pessoa_id;
$$;

-- Admin: exibir / ocultar o ranking para os participantes
create function public.fn_admin_exibir_ranking(p_visivel boolean)
returns void
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_aberto boolean;
begin
  perform public.fn_exige_admin();
  select e.aberto into v_aberto from public.evento e where e.id = 1 for update;
  if coalesce(p_visivel, false) and v_aberto then
    raise exception 'Encerre o período de jogos antes de exibir o ranking.' using errcode = 'P0001';
  end if;
  update public.evento e set ranking_visivel = coalesce(p_visivel, false) where e.id = 1;
end;
$$;

-- Reabrir o período volta a ocultar o ranking
create or replace function public.fn_admin_reabrir()
returns void
language plpgsql volatile security definer
set search_path = ''
as $$
begin
  perform public.fn_exige_admin();
  update public.evento e
     set aberto = true, encerrado_em = null, ranking_visivel = false
   where e.id = 1;
end;
$$;

-- Ranking do participante.
--   oculto  → só nome, grupo e vitórias (ordem: vitórias, nome)
--   liberado → colocação, pontos e etiquetas de empate
-- Nunca devolve prêmio.
create or replace function public.fn_ranking(p_token text)
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_eu     uuid := public.fn_sessao_pessoa(p_token);
  v_aberto boolean;
  v_lib    boolean := public.fn_ranking_liberado();
begin
  select e.aberto into v_aberto from public.evento e where e.id = 1;
  if not v_lib then
    return jsonb_build_object('aberto', v_aberto, 'visivel', false, 'criterio', 'vitorias',
                              'linhas', public.fn_lista_vitorias(v_eu));
  end if;
  return jsonb_build_object(
    'aberto', v_aberto, 'visivel', true, 'criterio', 'pontos',
    'linhas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'pessoa_id', r.pessoa_id, 'nome', r.nome,
               'grupo', public.fn_grupo_json(r.grupo_id),
               'vitorias', r.vitorias, 'pontos', r.pontos,
               'posicao', r.posicao, 'pontuou', r.pontuou,
               'empate', r.empate, 'no_desempate', r.no_desempate,
               'eu', r.pessoa_id = v_eu)
             order by r.ordem)
        from public.fn_ranking_base() r), '[]'::jsonb));
end;
$$;

-- Resultado final (período encerrado).
--   oculto  → lista de vitórias, sem placar de grupos; vencedores sem pontos
--   liberado → ranking com pontos, placar de grupos, vencedores com pontos
create or replace function public.fn_resultado_final(p_token text)
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_eu  uuid := public.fn_sessao_pessoa(p_token);
  v_lib boolean;
begin
  if (select e.aberto from public.evento e where e.id = 1) then
    raise exception 'O resultado final aparece quando o período de jogos for encerrado.'
      using errcode = 'P0001';
  end if;
  v_lib := public.fn_ranking_liberado();

  return jsonb_build_object(
    'visivel', v_lib,
    'ranking', case when not v_lib then public.fn_lista_vitorias(v_eu) else coalesce((
      select jsonb_agg(jsonb_build_object(
               'pessoa_id', r.pessoa_id, 'nome', r.nome,
               'grupo', public.fn_grupo_json(r.grupo_id),
               'pontos', r.pontos, 'vitorias', r.vitorias,
               'posicao', r.posicao, 'pontuou', r.pontuou,
               'empate', r.empate, 'no_desempate', r.no_desempate,
               'eu', r.pessoa_id = v_eu)
             order by r.ordem)
        from public.fn_ranking_base() r), '[]'::jsonb) end,
    'grupos', case when not v_lib then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object(
               'grupo_id', g.grupo_id, 'nome', g.nome, 'icone', g.icone, 'cor', g.cor,
               'membros', g.membros, 'pontos', g.pontos, 'vitorias', g.vitorias,
               'posicao', g.posicao)
             order by g.ordem)
        from public.fn_placar_grupos_base() g), '[]'::jsonb) end,
    'jogos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', j.id, 'nome', j.nome, 'partida', public.fn_partida(j.id), 'tipo', j.tipo,
               'modo', j.modo, 'formato', j.formato,
               'participantes', public.fn_qtd_participantes(j.id),
               'pontuado', j.pontuado_em is not null,
               'vencedores', case when v_lib then public.fn_vencedores(j.id) else (
                   select coalesce(jsonb_agg(v - 'pontos' order by o), '[]'::jsonb)
                     from jsonb_array_elements(public.fn_vencedores(j.id)) with ordinality x(v, o)) end)
             order by (j.pontuado_em is not null) desc, lower(j.nome), j.numero_partida)
        from public.jogo j), '[]'::jsonb));
end;
$$;

-- =====================================================================
-- 2. Meus jogos: só as regras
-- =====================================================================
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
             'modo', j.modo, 'formato', j.formato)
           order by lower(j.nome), j.numero_partida)
      from public.jogo j
      join public.fn_jogos_da_pessoa(v_eu) m on m.jogo_id = j.id), '[]'::jsonb);
end;
$$;

-- =====================================================================
-- 3. Crédito do ADM
-- =====================================================================
alter table public.transferencia
  add column origem text not null default 'participante'
    check (origem in ('participante', 'admin')),
  alter column de_pessoa_id drop not null,
  drop constraint transferencia_outra_pessoa,
  add constraint transferencia_origem check (
    (origem = 'admin' and de_pessoa_id is null)
    or (origem = 'participante' and de_pessoa_id is not null and de_pessoa_id <> para_pessoa_id));

-- Saldo: + crédito do ADM (muda as colunas devolvidas: precisa recriar)
drop function public.fn_saldos();
create function public.fn_saldos()
returns table (pessoa_id uuid, ganho numeric, credito numeric, recebido numeric, doado numeric,
               gasto numeric, saldo numeric)
language sql stable security definer
set search_path = ''
as $$
  select s.pessoa_id,
         s.premio::numeric(12,2),
         coalesce(tc.credito, 0)::numeric(12,2),
         coalesce(tr.recebido, 0)::numeric(12,2),
         coalesce(td.doado, 0)::numeric(12,2),
         coalesce(c.gasto, 0)::numeric(12,2),
         (s.premio + coalesce(tc.credito, 0) + coalesce(tr.recebido, 0)
                   - coalesce(td.doado, 0) - coalesce(c.gasto, 0))::numeric(12,2)
    from public.fn_estatisticas() s
    left join (select x.pessoa_id, sum(x.valor) as gasto
                 from public.caixa x
                where x.pessoa_id is not null
                group by x.pessoa_id) c on c.pessoa_id = s.pessoa_id
    left join (select t.para_pessoa_id as pessoa_id, sum(t.valor) as credito
                 from public.transferencia t where t.origem = 'admin'
                group by t.para_pessoa_id) tc on tc.pessoa_id = s.pessoa_id
    left join (select t.para_pessoa_id as pessoa_id, sum(t.valor) as recebido
                 from public.transferencia t where t.origem = 'participante'
                group by t.para_pessoa_id) tr on tr.pessoa_id = s.pessoa_id
    left join (select t.de_pessoa_id as pessoa_id, sum(t.valor) as doado
                 from public.transferencia t where t.origem = 'participante'
                group by t.de_pessoa_id) td on td.pessoa_id = s.pessoa_id;
$$;

-- Extrato de transferências de uma pessoa: doações feitas/recebidas e
-- créditos do ADM (tipo 'credito', sem nome). Só usada com a pessoa da sessão.
create or replace function public.fn_doacoes_json(p_pessoa_id uuid)
returns jsonb
language sql stable security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'tipo', case when t.origem = 'admin' then 'credito'
                        when t.de_pessoa_id = p_pessoa_id then 'feita' else 'recebida' end,
           'nome', o.nome, 'recado', t.motivo, 'valor', t.valor, 'criado_em', t.criado_em)
         order by t.criado_em), '[]'::jsonb)
    from public.transferencia t
    left join public.pessoa o
      on o.id = case when t.de_pessoa_id = p_pessoa_id then t.para_pessoa_id else t.de_pessoa_id end
   where p_pessoa_id in (t.de_pessoa_id, t.para_pessoa_id);
$$;

-- Meu painel: + crédito do ADM; sem pontos e sem colocação enquanto o
-- ranking estiver oculto
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
         where x.pessoa_id = v_eu), '[]'::jsonb))
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

-- Crédito do ADM: qualquer valor, sem tirar de ninguém. Jogos abertos ou
-- encerrados. Só dinheiro: pontos e vitórias não mudam.
create function public.fn_admin_creditar(p_para uuid, p_valor numeric, p_motivo text)
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
  if p_valor > 1000000 then
    raise exception 'Valor alto demais (máximo R$ 1.000.000,00).' using errcode = '22023';
  end if;
  if char_length(v_motivo) > 60 then
    raise exception 'O motivo pode ter até 60 caracteres.' using errcode = '22023';
  end if;

  insert into public.transferencia (origem, de_pessoa_id, para_pessoa_id, valor, motivo)
  values ('admin', null, p_para, p_valor, v_motivo);
end;
$$;

-- Desfazer doação ou crédito do ADM: só se quem recebeu ainda tem esse saldo
create or replace function public.fn_admin_desfazer_doacao(p_id uuid)
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
    raise exception 'Transferência não encontrada.' using errcode = 'P0002';
  end if;

  select p.nome into v_nome from public.pessoa p where p.id = v_t.para_pessoa_id for update;
  select s.saldo into v_saldo from public.fn_saldos() s where s.pessoa_id = v_t.para_pessoa_id;
  if v_saldo < v_t.valor then
    raise exception '% já usou parte desse valor. Desfaça antes o arremate ou a doação que usou o dinheiro.', v_nome
      using errcode = 'P0001';
  end if;

  delete from public.transferencia t where t.id = v_t.id;
end;
$$;

-- Novo evento: também volta a ocultar o ranking (créditos vão junto com
-- as transferências)
create or replace function public.fn_admin_novo_evento(p_nome text, p_manter_pessoas boolean, p_manter_grupos boolean)
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
  update public.evento e
     set nome = v_nome, aberto = true, encerrado_em = null, ranking_visivel = false
   where e.id = 1;

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
-- 4. Login do admin só com a senha
-- =====================================================================
-- Devolve o e-mail da conta do administrador (Supabase Auth). A senha
-- continua sendo conferida pelo Supabase Auth; sem ela o e-mail não dá
-- acesso a nada.
create function public.fn_email_admin()
returns text
language sql stable security definer
set search_path = ''
as $$
  select u.email::text
    from public.admin a
    join auth.users u on u.id = a.user_id
   order by u.created_at
   limit 1;
$$;

-- =====================================================================
-- Permissões
-- =====================================================================
revoke execute on function
  public.fn_ranking_liberado(),
  public.fn_lista_vitorias(uuid),
  public.fn_admin_exibir_ranking(boolean),
  public.fn_saldos(),
  public.fn_doacoes_json(uuid),
  public.fn_admin_creditar(uuid, numeric, text),
  public.fn_email_admin()
from public, anon, authenticated;

grant execute on function public.fn_email_admin() to anon, authenticated;
grant execute on function
  public.fn_admin_exibir_ranking(boolean),
  public.fn_admin_creditar(uuid, numeric, text)
to authenticated;
-- evento.ranking_visivel: o admin lê (select da tabela inteira), mas só
-- muda por fn_admin_exibir_ranking.
