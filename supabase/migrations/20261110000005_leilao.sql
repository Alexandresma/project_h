-- =====================================================================
-- Gincana de Halloween — 5: leilão de caixas surpresa
-- =====================================================================
-- Saldo = ganho nos jogos (soma de resultado.premio) − gasto no leilão
-- (soma de caixa.valor). Calculado sempre; nunca guardado em coluna.
--
-- Arremate só por fn_admin_arrematar: na mesma transação confere evento
-- encerrado + caixa disponível (lock da linha) + saldo suficiente (lock
-- da pessoa, para dois arremates da mesma pessoa não passarem juntos).
--
-- Participante: fn_meu_painel passa a trazer o PRÓPRIO saldo e arremates;
-- fn_leilao mostra as caixas (vendida ou não, "minha") sem comprador nem
-- preço das dos outros, e o conteúdo só das caixas que ele arrematou.

-- ---------------------------------------------------------------------
-- Tabela
-- ---------------------------------------------------------------------
create table public.caixa (
  id         uuid primary key default gen_random_uuid(),
  numero     integer not null unique check (numero > 0),
  conteudo   text not null default '' check (char_length(conteudo) <= 60),
  pessoa_id  uuid references public.pessoa(id),          -- arrematante
  valor      numeric(12,2) check (valor > 0),
  vendido_em timestamptz,
  criado_em  timestamptz not null default now(),
  constraint caixa_venda_completa check (
    (pessoa_id is null and valor is null and vendido_em is null)
    or (pessoa_id is not null and valor is not null and vendido_em is not null))
);
create index caixa_pessoa_idx on public.caixa (pessoa_id);

alter table public.caixa enable row level security;

create policy caixa_admin on public.caixa
  for all to authenticated
  using ((select public.fn_is_admin())) with check ((select public.fn_is_admin()));

-- Caixa vendida não pode ser excluída (desfaça a venda antes)
create function public.tg_caixa_vendida_nao_exclui()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if old.pessoa_id is not null then
    raise exception 'Desfaça a venda antes de excluir a caixa.' using errcode = 'P0001';
  end if;
  return old;
end;
$$;
create trigger caixa_vendida_nao_exclui before delete on public.caixa
  for each row execute function public.tg_caixa_vendida_nao_exclui();

-- Excluir uma pessoa devolve as caixas que ela arrematou ao leilão
create function public.tg_pessoa_libera_caixas()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  update public.caixa c
     set pessoa_id = null, valor = null, vendido_em = null
   where c.pessoa_id = old.id;
  return old;
end;
$$;
create trigger pessoa_libera_caixas before delete on public.pessoa
  for each row execute function public.tg_pessoa_libera_caixas();

-- ---------------------------------------------------------------------
-- Interna: saldo por pessoa
-- ---------------------------------------------------------------------
create function public.fn_saldos()
returns table (pessoa_id uuid, ganho numeric, gasto numeric, saldo numeric)
language sql stable security definer
set search_path = ''
as $$
  select s.pessoa_id,
         s.premio::numeric(12,2),
         coalesce(c.gasto, 0)::numeric(12,2),
         (s.premio - coalesce(c.gasto, 0))::numeric(12,2)
    from public.fn_estatisticas() s
    left join (select x.pessoa_id, sum(x.valor) as gasto
                 from public.caixa x
                where x.pessoa_id is not null
                group by x.pessoa_id) c on c.pessoa_id = s.pessoa_id;
$$;

-- Arremates de uma pessoa (só usada com a pessoa da sessão ou pelo admin)
create function public.fn_arremates_json(p_pessoa_id uuid)
returns jsonb
language sql stable security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'numero', c.numero, 'conteudo', c.conteudo,
           'valor', c.valor, 'vendido_em', c.vendido_em)
         order by c.vendido_em, c.numero), '[]'::jsonb)
    from public.caixa c
   where c.pessoa_id = p_pessoa_id;
$$;

-- ---------------------------------------------------------------------
-- Participante
-- ---------------------------------------------------------------------

-- Meu painel: o mesmo de antes + MEU dinheiro (ganho, gasto, saldo) e
-- as caixas que EU arrematei.
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
      'gasto', s.gasto,
      'saldo', s.saldo,
      'arremates', public.fn_arremates_json(v_eu),
      'resultados', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'jogo_id', j.id, 'jogo', j.nome, 'tipo', j.tipo,
                 'modo', j.modo, 'formato', j.formato,
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

-- Caixas do leilão (só com o evento encerrado). Das caixas dos outros:
-- só número e "vendida". Das minhas: conteúdo, valor e horário.
create function public.fn_leilao(p_token text)
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_eu uuid := public.fn_sessao_pessoa(p_token);
begin
  if (select e.aberto from public.evento e where e.id = 1) then
    raise exception 'O leilão aparece quando o evento for encerrado.' using errcode = 'P0001';
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
        from public.caixa c), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------
-- Administrador
-- ---------------------------------------------------------------------

-- Cria p_qtd caixas (1 a 50) numeradas em sequência após a maior
create function public.fn_admin_adicionar_caixas(p_qtd integer)
returns integer
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_ini integer;
begin
  perform public.fn_exige_admin();
  if p_qtd is null or p_qtd not between 1 and 50 then
    raise exception 'Informe de 1 a 50 caixas.' using errcode = '22023';
  end if;

  lock table public.caixa in share row exclusive mode;   -- numeração sem buraco nem repetição
  select coalesce(max(c.numero), 0) + 1 into v_ini from public.caixa c;
  insert into public.caixa (numero)
  select n from generate_series(v_ini, v_ini + p_qtd - 1) n;
  return p_qtd;
end;
$$;

-- Registra o arremate. Devolve saldo antes/depois.
create function public.fn_admin_arrematar(p_caixa_id uuid, p_pessoa_id uuid, p_valor numeric)
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
    raise exception 'O leilão só acontece com o evento encerrado. Encerre o evento no Painel.'
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

  -- trava a pessoa: dois arremates dela não usam o mesmo saldo
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

-- Desfaz a venda: a caixa volta a ficar disponível e o valor volta ao saldo
create function public.fn_admin_desfazer_venda(p_caixa_id uuid)
returns void
language plpgsql volatile security definer
set search_path = ''
as $$
begin
  perform public.fn_exige_admin();
  update public.caixa c
     set pessoa_id = null, valor = null, vendido_em = null
   where c.id = p_caixa_id;
  if not found then
    raise exception 'Caixa não encontrada.' using errcode = 'P0002';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- Permissões
-- ---------------------------------------------------------------------
revoke all on public.caixa from public, anon, authenticated;
-- admin lê tudo, edita só o conteúdo e exclui (caixa vendida: o gatilho
-- recusa). Criar caixas e vender/desfazer: só pelas funções.
grant select             on public.caixa to authenticated;
grant update (conteudo)  on public.caixa to authenticated;
grant delete             on public.caixa to authenticated;

revoke execute on function
  public.tg_caixa_vendida_nao_exclui(),
  public.tg_pessoa_libera_caixas(),
  public.fn_saldos(),
  public.fn_arremates_json(uuid),
  public.fn_leilao(text),
  public.fn_admin_adicionar_caixas(integer),
  public.fn_admin_arrematar(uuid, uuid, numeric),
  public.fn_admin_desfazer_venda(uuid)
from public, anon, authenticated;

grant execute on function public.fn_leilao(text) to anon, authenticated;
grant execute on function
  public.fn_admin_adicionar_caixas(integer),
  public.fn_admin_arrematar(uuid, uuid, numeric),
  public.fn_admin_desfazer_venda(uuid)
to authenticated;
