-- =====================================================================
-- Gincana de Halloween — 8: permissões das funções (refeitas do zero)
-- =====================================================================
-- Corrige "permission denied for function fn_admin_creditar" e deixa as
-- permissões de TODAS as funções do schema public num só lugar:
--
--   anon + authenticated : funções do participante (com token) e as 3 de
--                          antes do login (lista de nomes, entrar, e-mail
--                          do admin para o login só com senha)
--   authenticated        : todas as fn_admin_* (achadas pelo nome, então
--                          nenhuma fica de fora) e fn_is_admin (RLS)
--   ninguém da API       : funções internas (fn_saldos, fn_exige_admin,
--                          fn_ranking_base…) e gatilhos
--
-- Pode rodar mais de uma vez. No fim, confere tudo e dá erro (desfazendo
-- a migração) se algo estiver fora da regra.

-- 1) Tira EXECUTE de todo mundo em todas as funções do schema
revoke execute on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

-- 2) Participante (navegador com a chave pública)
grant execute on function
  -- antes do login
  public.fn_lista_login(),
  public.fn_entrar(uuid, text),
  public.fn_email_admin(),
  -- com token de sessão
  public.fn_sair(text),
  public.fn_meu_painel(text),
  public.fn_meus_jogos(text),
  public.fn_ranking(text),
  public.fn_resultado_final(text),
  public.fn_leilao(text),
  public.fn_doar(text, uuid, numeric, text)
to anon, authenticated;

-- 3) Admin: políticas RLS + todas as fn_admin_*
grant execute on function public.fn_is_admin() to authenticated;

do $$
declare
  f regprocedure;
begin
  for f in
    select p.oid::regprocedure
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname like 'fn\_admin\_%'
  loop
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

-- 4) Conferência (falhou → erro e nada desta migração fica gravado)
do $$
declare
  v_anon text[] := array[
    'fn_lista_login', 'fn_entrar', 'fn_email_admin',
    'fn_sair', 'fn_meu_painel', 'fn_meus_jogos', 'fn_ranking',
    'fn_resultado_final', 'fn_leilao', 'fn_doar'];
  r      record;
  v_qtd  integer := 0;
begin
  -- fn_exige_admin precisa mesmo conferir fn_is_admin
  if not exists (
    select 1 from pg_proc p
     where p.oid = 'public.fn_exige_admin()'::regprocedure
       and p.prosrc ~ 'if\s+not\s+public\.fn_is_admin\(\)\s+then\s+raise\s+exception') then
    raise exception 'fn_exige_admin não confere fn_is_admin()';
  end if;

  for r in
    select p.oid::regprocedure as f, p.proname as nome, p.prosecdef, p.prosrc,
           has_function_privilege('anon', p.oid, 'execute')          as anon_exec,
           has_function_privilege('authenticated', p.oid, 'execute') as auth_exec,
           exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                    where a.grantee = 0 and a.privilege_type = 'EXECUTE') as public_exec
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and not exists (select 1 from pg_depend d     -- ignora funções de extensões
                        where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e')
  loop
    if r.public_exec then
      raise exception '% está liberada para PUBLIC', r.f;
    end if;

    if r.nome like 'fn\_admin\_%' then
      v_qtd := v_qtd + 1;
      if r.anon_exec then raise exception '% (admin) está liberada para anon', r.f; end if;
      if not r.auth_exec then raise exception '% (admin) sem EXECUTE para authenticated', r.f; end if;
      if not r.prosecdef then raise exception '% (admin) não é security definer', r.f; end if;
      -- a 1ª instrução do corpo tem que ser a checagem de admin
      if r.prosrc !~ '^\s*(declare\s.*?)?begin\s+perform\s+public\.fn_exige_admin\(\)\s*;' then
        raise exception '% (admin) não começa com perform public.fn_exige_admin()', r.f;
      end if;
    elsif r.nome = any (v_anon) then
      if not (r.anon_exec and r.auth_exec) then
        raise exception '% (participante) sem EXECUTE para anon/authenticated', r.f;
      end if;
    elsif r.nome = 'fn_is_admin' then
      if r.anon_exec or not r.auth_exec then
        raise exception 'fn_is_admin: só authenticated deve executar';
      end if;
    elsif r.anon_exec or r.auth_exec then
      raise exception '% é interna e está liberada para a API', r.f;
    end if;
  end loop;

  if v_qtd < 16 then
    raise exception 'Esperava ao menos 16 funções fn_admin_*, achei %', v_qtd;
  end if;
end;
$$;
