-- =====================================================================
-- Gincana de Halloween — 10: políticas RLS exatamente como no projeto
-- =====================================================================
-- Corrige "permission denied for function is_admin" ao gravar em pessoa.
--
-- O banco real tinha uma função public.is_admin e política(s) que a usam,
-- criadas fora das migrações. A migração 8 tirou o EXECUTE de todas as
-- funções que não são do projeto (inclusive is_admin), e a política
-- passou a falhar para o admin.
--
-- Esta migração:
--   1. remove TODAS as políticas das tabelas do schema public e recria só
--      as 10 do projeto (todas: admin via public.fn_is_admin());
--   2. garante RLS ligado em todas as tabelas do schema public;
--   3. confere tudo no fim (erro = nada fica gravado);
--   4. mostra, como resultado, as políticas removidas que não eram do
--      projeto (tabela vazia = não havia nenhuma extra).
-- A função is_admin fica no banco, sem EXECUTE para ninguém da API (nada
-- do projeto usa). Pode rodar mais de uma vez.

create temp table if not exists _politicas_removidas (
  tabela text, politica text, comando text, papeis text, using_expr text, check_expr text
);
truncate _politicas_removidas;

do $$
declare
  r record;
  v_nossas text[] := array[
    'evento.evento_admin_le', 'evento.evento_admin_altera',
    'grupo.grupo_admin', 'pessoa.pessoa_admin', 'jogo.jogo_admin',
    'jogo_grupo.jogo_grupo_admin', 'participacao.participacao_admin',
    'resultado.resultado_admin_le', 'caixa.caixa_admin',
    'transferencia.transferencia_admin_le'];
begin
  -- 1) remove todas (guardando as que não são do projeto para mostrar)
  for r in select * from pg_policies where schemaname = 'public' loop
    if not (r.tablename || '.' || r.policyname = any (v_nossas)) then
      insert into _politicas_removidas
      values (r.tablename, r.policyname, r.cmd, array_to_string(r.roles, ','), r.qual, r.with_check);
    end if;
    execute format('drop policy %I on public.%I', r.policyname, r.tablename);
  end loop;

  -- 2) RLS ligado em todas as tabelas do schema
  for r in select c.relname from pg_class c
            where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p') loop
    execute format('alter table public.%I enable row level security', r.relname);
  end loop;
end;
$$;

-- 3) as políticas do projeto (iguais às migrações 1, 5 e 6)
create policy evento_admin_le on public.evento
  for select to authenticated using ((select public.fn_is_admin()));
create policy evento_admin_altera on public.evento
  for update to authenticated
  using ((select public.fn_is_admin())) with check ((select public.fn_is_admin()));
create policy grupo_admin on public.grupo
  for all to authenticated
  using ((select public.fn_is_admin())) with check ((select public.fn_is_admin()));
create policy pessoa_admin on public.pessoa
  for all to authenticated
  using ((select public.fn_is_admin())) with check ((select public.fn_is_admin()));
create policy jogo_admin on public.jogo
  for all to authenticated
  using ((select public.fn_is_admin())) with check ((select public.fn_is_admin()));
create policy jogo_grupo_admin on public.jogo_grupo
  for all to authenticated
  using ((select public.fn_is_admin())) with check ((select public.fn_is_admin()));
create policy participacao_admin on public.participacao
  for all to authenticated
  using ((select public.fn_is_admin())) with check ((select public.fn_is_admin()));
create policy resultado_admin_le on public.resultado
  for select to authenticated using ((select public.fn_is_admin()));
create policy caixa_admin on public.caixa
  for all to authenticated
  using ((select public.fn_is_admin())) with check ((select public.fn_is_admin()));
create policy transferencia_admin_le on public.transferencia
  for select to authenticated using ((select public.fn_is_admin()));

-- is_admin (fora do projeto), se existir: ninguém da API executa
do $$
declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p
            where p.pronamespace = 'public'::regnamespace and p.proname = 'is_admin' loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;
end;
$$;

-- 4) conferência
do $$
declare
  r record;
  v_qtd integer;
begin
  select count(*) into v_qtd from pg_policies where schemaname = 'public';
  if v_qtd <> 10 then
    raise exception 'Esperava 10 políticas no schema public, achei %', v_qtd;
  end if;
  for r in select * from pg_policies where schemaname = 'public' loop
    if r.roles <> array['authenticated']::name[] or r.permissive <> 'PERMISSIVE'
       or coalesce(r.qual, r.with_check) !~ 'fn_is_admin\(\)'
       or coalesce(r.qual, '') || coalesce(r.with_check, '') ~ '(^|[^_])is_admin\(' then
      raise exception 'Política fora da regra: %.%', r.tablename, r.policyname;
    end if;
  end loop;
  for r in select c.relname from pg_class c
            where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p')
              and not c.relrowsecurity loop
    raise exception 'Tabela sem RLS: %', r.relname;
  end loop;
end;
$$;

-- Resultado: políticas removidas que não eram do projeto
select * from _politicas_removidas order by tabela, politica;
