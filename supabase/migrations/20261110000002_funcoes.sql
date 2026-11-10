-- =====================================================================
-- Gincana de Halloween — 2/3: funções
-- =====================================================================
-- Todas: security definer + search_path vazio + nomes qualificados.
--
-- REGRA DE PRIVACIDADE: nenhuma função do participante devolve prêmio de
-- outra pessoa. Só fn_meu_painel e fn_meus_jogos têm a chave "premio", e
-- sempre com o valor da própria pessoa da sessão.
--
-- Quem pode executar o quê está na migração 3 (permissões).

-- =====================================================================
-- Internas (sem EXECUTE para anon/authenticated)
-- =====================================================================

-- Confere o token e devolve a pessoa da sessão
create function public.fn_sessao_pessoa(p_token text)
returns uuid
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_pessoa uuid;
begin
  update public.sessao s
     set ultimo_uso = now()
   where s.token_hash = extensions.digest(coalesce(p_token, ''), 'sha256')
  returning s.pessoa_id into v_pessoa;

  if v_pessoa is null then
    raise exception 'Sessão inválida' using errcode = 'P0001', hint = 'Entre de novo.';
  end if;
  return v_pessoa;
end;
$$;

create function public.fn_exige_admin()
returns void
language plpgsql stable security definer
set search_path = ''
as $$
begin
  if not public.fn_is_admin() then
    raise exception 'Acesso negado' using errcode = '42501';
  end if;
end;
$$;

create function public.fn_grupo_json(p_grupo_id uuid)
returns jsonb
language sql stable security definer
set search_path = ''
as $$
  select jsonb_build_object('id', g.id, 'nome', g.nome, 'icone', g.icone, 'cor', g.cor)
    from public.grupo g
   where g.id = p_grupo_id;
$$;

-- Totais por pessoa (só jogos pontuados têm linhas em resultado)
create function public.fn_estatisticas()
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
    left join public.resultado r on r.pessoa_id = p.id
   group by p.id;
$$;

-- Ranking de pessoas (mesma ordem para admin e participantes)
--   aberto    → 1) vitórias 2) pontos   3) quem chegou primeiro à pontuação atual
--   encerrado → 1) pontos   2) vitórias 3) idem
-- Divide a posição (empate) só quando os três critérios são iguais.
-- "no_desempate": separado de alguém com o mesmo 1º critério.
-- Quem não pontuou fica sem posição.
create function public.fn_ranking_base()
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
           rank() over (order by b.k1 desc, b.k2 desc, b.alcancou_em asc nulls last) as pos,
           row_number() over (order by b.k1 desc, b.k2 desc, b.alcancou_em asc nulls last,
                                       lower(b.nome), b.pessoa_id) as ord_n,
           count(*) over (partition by b.k1) as n_k1
      from base b
  )
  select o.pessoa_id, o.nome, o.grupo_id,
         o.vitorias, o.colocacoes, o.pontos, o.premio, o.alcancou_em,
         case when o.pontuou then o.pos::integer end,
         o.pontuou,
         o.pontuou and count(*) over (partition by o.pos) > 1,
         o.pontuou and count(*) over (partition by o.pos) = 1 and o.n_k1 > 1,
         o.ord_n::integer
    from ord o;
$$;

-- Placar de grupos: jogo por grupo conta uma vez para o grupo;
-- jogos individuais somam o resultado dos membros. Desempate: vitórias.
create function public.fn_placar_grupos_base()
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
         case when t.pontos > 0
              then (rank() over (order by t.pontos desc, t.vitorias desc))::integer end,
         (row_number() over (order by t.pontos desc, t.vitorias desc, lower(t.nome), t.id))::integer
    from tot t;
$$;

-- Jogos de uma pessoa: individuais em que está inscrita, por grupo em que
-- o grupo dela disputa, e qualquer jogo em que tenha resultado.
create function public.fn_jogos_da_pessoa(p_pessoa_id uuid)
returns table (jogo_id uuid)
language sql stable security definer
set search_path = ''
as $$
  select j.id
    from public.jogo j
   where (j.modo = 'individual' and exists (
            select 1 from public.participacao pa
             where pa.jogo_id = j.id and pa.pessoa_id = p_pessoa_id))
      or (j.modo = 'grupo' and exists (
            select 1 from public.jogo_grupo jg
              join public.pessoa p on p.grupo_id = jg.grupo_id
             where jg.jogo_id = j.id and p.id = p_pessoa_id))
      or exists (
            select 1 from public.resultado r
             where r.jogo_id = j.id and r.pessoa_id = p_pessoa_id);
$$;

create function public.fn_qtd_participantes(p_jogo_id uuid)
returns integer
language sql stable security definer
set search_path = ''
as $$
  select (case j.modo
            when 'individual' then
              (select count(*) from public.participacao pa where pa.jogo_id = j.id)
            else
              (select count(*) from public.pessoa p
                 join public.jogo_grupo jg on jg.grupo_id = p.grupo_id
                where jg.jogo_id = j.id)
          end)::integer
    from public.jogo j
   where j.id = p_jogo_id;
$$;

-- Vencedores de um jogo (sem prêmio): por pessoa ou por grupo
create function public.fn_vencedores(p_jogo_id uuid)
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
               from (select r.grupo_id, min(r.colocacao) as colocacao, max(r.pontos) as pontos
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

-- Ao regravar um resultado, quem manteve colocação e pontos mantém o
-- horário (critério 3 do desempate); quem mudou ganha o horário de agora.
create function public.fn_horario_mantido(p_antigos jsonb, p_pessoa_id uuid,
                                          p_colocacao integer, p_pontos integer)
returns timestamptz
language sql volatile security definer
set search_path = ''
as $$
  select coalesce((
    select (a->>'registrado_em')::timestamptz
      from jsonb_array_elements(p_antigos) a
     where (a->>'pessoa_id')::uuid = p_pessoa_id
       and (a->>'colocacao')::integer = p_colocacao
       and (a->>'pontos')::integer = p_pontos
     limit 1), clock_timestamp());
$$;

-- =====================================================================
-- Participante (EXECUTE para anon)
-- =====================================================================

-- Lista para a tela de login: só nome e grupo
create function public.fn_lista_login()
returns jsonb
language sql stable security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'evento', (select jsonb_build_object('nome', e.nome, 'aberto', e.aberto)
                 from public.evento e where e.id = 1),
    'pessoas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', p.id, 'nome', p.nome, 'grupo', public.fn_grupo_json(p.grupo_id))
             order by lower(p.nome))
        from public.pessoa p), '[]'::jsonb));
$$;

-- Login do participante. Devolve {token, pessoa_id, nome} ou {erro}.
-- Não usa exceção nos erros de senha, para o contador de tentativas
-- ficar gravado. 5 erros seguidos → bloqueio de 10 minutos.
create function public.fn_entrar(p_pessoa_id uuid, p_senha text)
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_p          public.pessoa%rowtype;
  v_tentativas integer;
  v_token      text;
begin
  select * into v_p from public.pessoa p where p.id = p_pessoa_id for update;
  if not found then
    return jsonb_build_object('erro', 'Senha incorreta');
  end if;

  if v_p.bloqueado_ate is not null and v_p.bloqueado_ate > now() then
    return jsonb_build_object(
      'erro', format('Muitas tentativas erradas. Tente de novo em %s min.',
                     ceil(extract(epoch from (v_p.bloqueado_ate - now())) / 60)::integer),
      'bloqueado_ate', v_p.bloqueado_ate);
  end if;

  if v_p.senha_hash is null or p_senha is null
     or extensions.crypt(p_senha, v_p.senha_hash) <> v_p.senha_hash then
    v_tentativas := v_p.tentativas_erradas + 1;
    update public.pessoa p
       set tentativas_erradas = case when v_tentativas >= 5 then 0 else v_tentativas end,
           bloqueado_ate      = case when v_tentativas >= 5
                                     then now() + interval '10 minutes' end
     where p.id = v_p.id;
    return jsonb_build_object('erro', 'Senha incorreta');
  end if;

  update public.pessoa p
     set tentativas_erradas = 0, bloqueado_ate = null
   where p.id = v_p.id;

  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.sessao (token_hash, pessoa_id)
  values (extensions.digest(v_token, 'sha256'), v_p.id);

  return jsonb_build_object('token', v_token, 'pessoa_id', v_p.id, 'nome', v_p.nome);
end;
$$;

create function public.fn_sair(p_token text)
returns void
language sql volatile security definer
set search_path = ''
as $$
  delete from public.sessao s
   where s.token_hash = extensions.digest(coalesce(p_token, ''), 'sha256');
$$;

-- Meu painel: grupo, pontos, vitórias, posição e o MEU prêmio
create function public.fn_meu_painel(p_token text)
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
     where r.pessoa_id = v_eu);
end;
$$;

-- Meus jogos: jogos em que participo e o MEU resultado
create function public.fn_meus_jogos(p_token text)
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_eu uuid := public.fn_sessao_pessoa(p_token);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', j.id, 'nome', j.nome, 'tipo', j.tipo, 'descricao', j.descricao,
             'modo', j.modo, 'formato', j.formato,
             'participantes', public.fn_qtd_participantes(j.id),
             'pontuado', j.pontuado_em is not null,
             'meu_resultado', case when r.id is null then null
                                   else jsonb_build_object('colocacao', r.colocacao,
                                                           'pontos', r.pontos,
                                                           'premio', r.premio) end)
           order by (j.pontuado_em is null) desc, lower(j.nome))
      from public.jogo j
      join public.fn_jogos_da_pessoa(v_eu) m on m.jogo_id = j.id
      left join public.resultado r on r.jogo_id = j.id and r.pessoa_id = v_eu), '[]'::jsonb);
end;
$$;

-- Ranking de pessoas. Aberto: só vitórias. Encerrado: + pontos.
-- Nunca devolve prêmio.
create function public.fn_ranking(p_token text)
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_eu     uuid := public.fn_sessao_pessoa(p_token);
  v_aberto boolean;
begin
  select e.aberto into v_aberto from public.evento e where e.id = 1;
  return jsonb_build_object(
    'aberto', v_aberto,
    'criterio', case when v_aberto then 'vitorias' else 'pontos' end,
    'linhas', coalesce((
      select jsonb_agg(
               jsonb_build_object(
                 'pessoa_id', r.pessoa_id, 'nome', r.nome,
                 'grupo', public.fn_grupo_json(r.grupo_id),
                 'vitorias', r.vitorias, 'posicao', r.posicao, 'pontuou', r.pontuou,
                 'empate', r.empate, 'no_desempate', r.no_desempate,
                 'eu', r.pessoa_id = v_eu)
               || case when v_aberto then '{}'::jsonb
                       else jsonb_build_object('pontos', r.pontos) end
             order by r.ordem)
        from public.fn_ranking_base() r), '[]'::jsonb));
end;
$$;

-- Resultado final (só com evento encerrado): ranking com pontos, placar de
-- grupos e todos os jogos com vencedores. Nunca devolve prêmio.
create function public.fn_resultado_final(p_token text)
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_eu uuid := public.fn_sessao_pessoa(p_token);
begin
  if (select e.aberto from public.evento e where e.id = 1) then
    raise exception 'O resultado final aparece quando o evento for encerrado.'
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
               'id', j.id, 'nome', j.nome, 'tipo', j.tipo,
               'modo', j.modo, 'formato', j.formato,
               'participantes', public.fn_qtd_participantes(j.id),
               'pontuado', j.pontuado_em is not null,
               'vencedores', public.fn_vencedores(j.id))
             order by (j.pontuado_em is not null) desc, lower(j.nome))
        from public.jogo j), '[]'::jsonb));
end;
$$;

-- =====================================================================
-- Administrador (EXECUTE para authenticated; cada uma confere fn_is_admin)
-- =====================================================================

-- Define/redefine a senha (4 a 6 dígitos). Zera bloqueio e derruba as
-- sessões abertas dessa pessoa.
create function public.fn_admin_definir_senha(p_pessoa_id uuid, p_senha text)
returns void
language plpgsql volatile security definer
set search_path = ''
as $$
begin
  perform public.fn_exige_admin();
  if p_senha is null or p_senha !~ '^[0-9]{4,6}$' then
    raise exception 'A senha deve ter de 4 a 6 dígitos.' using errcode = '22023';
  end if;

  update public.pessoa p
     set senha_hash = extensions.crypt(p_senha, extensions.gen_salt('bf', 8)),
         tentativas_erradas = 0,
         bloqueado_ate = null
   where p.id = p_pessoa_id;
  if not found then
    raise exception 'Pessoa não encontrada' using errcode = 'P0002';
  end if;

  delete from public.sessao s where s.pessoa_id = p_pessoa_id;
end;
$$;

create function public.fn_admin_desbloquear(p_pessoa_id uuid)
returns void
language plpgsql volatile security definer
set search_path = ''
as $$
begin
  perform public.fn_exige_admin();
  update public.pessoa p
     set tentativas_erradas = 0, bloqueado_ate = null
   where p.id = p_pessoa_id;
end;
$$;

-- Registra (ou regrava) o resultado de um jogo.
-- p_itens: lista de
--   individual: {"pessoa_id": "...", "colocacao": 1, "pontos": 10, "premio": 20}
--   por grupo:  {"grupo_id":  "...", "colocacao": 1, "pontos": 10, "premio": 20}
-- colocacao: 1 a 3 (formato 'vitoria' só aceita 1; padrão 1).
-- pontos/premio: opcionais; padrão = valores do jogo. Em jogo por grupo
-- valem por membro, e todos os membros atuais do grupo recebem o mesmo.
-- Lista vazia = jogo pontuado sem vencedores.
create function public.fn_admin_registrar_resultado(p_jogo_id uuid, p_itens jsonb)
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
    raise exception 'O evento está encerrado. Reabra o evento para cadastrar ou pontuar.'
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

create function public.fn_admin_limpar_resultado(p_jogo_id uuid)
returns void
language plpgsql volatile security definer
set search_path = ''
as $$
begin
  perform public.fn_exige_admin();
  delete from public.resultado r where r.jogo_id = p_jogo_id;
  update public.jogo j set pontuado_em = null where j.id = p_jogo_id;
end;
$$;

create function public.fn_admin_encerrar()
returns void
language plpgsql volatile security definer
set search_path = ''
as $$
begin
  perform public.fn_exige_admin();
  update public.evento e set aberto = false, encerrado_em = now() where e.id = 1;
end;
$$;

create function public.fn_admin_reabrir()
returns void
language plpgsql volatile security definer
set search_path = ''
as $$
begin
  perform public.fn_exige_admin();
  update public.evento e set aberto = true, encerrado_em = null where e.id = 1;
end;
$$;

-- Ranking do admin: mesma ordem dos participantes + pontos e prêmio de todos
create function public.fn_admin_ranking()
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
begin
  perform public.fn_exige_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'pessoa_id', r.pessoa_id, 'nome', r.nome,
             'grupo', public.fn_grupo_json(r.grupo_id),
             'vitorias', r.vitorias, 'colocacoes', r.colocacoes,
             'pontos', r.pontos, 'premio', r.premio,
             'qtd_jogos', (select count(*) from public.fn_jogos_da_pessoa(r.pessoa_id)),
             'posicao', r.posicao, 'pontuou', r.pontuou,
             'empate', r.empate, 'no_desempate', r.no_desempate)
           order by r.ordem)
      from public.fn_ranking_base() r), '[]'::jsonb);
end;
$$;

create function public.fn_admin_placar_grupos()
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
begin
  perform public.fn_exige_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'grupo_id', g.grupo_id, 'nome', g.nome, 'icone', g.icone, 'cor', g.cor,
             'membros', g.membros, 'pontos', g.pontos, 'vitorias', g.vitorias,
             'premio', g.premio, 'posicao', g.posicao)
           order by g.ordem)
      from public.fn_placar_grupos_base() g), '[]'::jsonb);
end;
$$;
