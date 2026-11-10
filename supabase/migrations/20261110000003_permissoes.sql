-- =====================================================================
-- Gincana de Halloween — 3/3: permissões (GRANT explícito)
-- =====================================================================
-- anon          = navegador do participante: só EXECUTE nas funções do
--                 participante. Nenhuma tabela.
-- authenticated = qualquer usuário logado no Supabase Auth. As tabelas
--                 têm RLS que só deixa passar o admin (tabela public.admin).
-- service_role  = nunca vai para o navegador (fica como o Supabase criou).

-- 1) Tira tudo o que o Supabase concede por padrão
revoke all     on all tables    in schema public from public, anon, authenticated;
revoke all     on all sequences in schema public from public, anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;

-- ... e também para objetos criados no futuro neste schema
alter default privileges in schema public revoke all     on tables    from public, anon, authenticated;
alter default privileges in schema public revoke all     on sequences from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

-- 2) Tabelas: só authenticated (RLS filtra para o admin)
grant select           on public.evento to authenticated;
grant update (nome)    on public.evento to authenticated;   -- aberto/encerrado só pelas funções

grant select, insert, update, delete on public.grupo        to authenticated;
grant select, insert, update, delete on public.jogo_grupo   to authenticated;
grant select, insert, update, delete on public.participacao to authenticated;

-- pontuado_em só muda pelas funções de resultado
grant select on public.jogo to authenticated;
grant insert (nome, tipo, descricao, modo, formato, pontos, premio,
              pontos_1, premio_1, pontos_2, premio_2, pontos_3, premio_3)
  on public.jogo to authenticated;
grant update (nome, tipo, descricao, modo, formato, pontos, premio,
              pontos_1, premio_1, pontos_2, premio_2, pontos_3, premio_3)
  on public.jogo to authenticated;
grant delete on public.jogo to authenticated;

-- senha_hash e o contador de tentativas não são legíveis nem graváveis
-- direto, nem pelo admin (senha só por fn_admin_definir_senha).
-- Atenção no front: listar as colunas (select('id,nome,grupo_id,...')),
-- nunca select('*').
grant select (id, nome, grupo_id, bloqueado_ate, criado_em) on public.pessoa to authenticated;
grant insert (nome, grupo_id) on public.pessoa to authenticated;
grant update (nome, grupo_id) on public.pessoa to authenticated;
grant delete                  on public.pessoa to authenticated;

grant select on public.resultado to authenticated;          -- grava só por função

-- admin e sessao: nenhum acesso direto

-- 3) Funções
-- Usada pelas políticas RLS e pelo front para saber se o usuário é o admin
grant execute on function public.fn_is_admin() to authenticated;

-- Participante
grant execute on function
  public.fn_lista_login(),
  public.fn_entrar(uuid, text),
  public.fn_sair(text),
  public.fn_meu_painel(text),
  public.fn_meus_jogos(text),
  public.fn_ranking(text),
  public.fn_resultado_final(text)
to anon, authenticated;

-- Administrador (cada função ainda confere fn_is_admin por dentro)
grant execute on function
  public.fn_admin_definir_senha(uuid, text),
  public.fn_admin_desbloquear(uuid),
  public.fn_admin_registrar_resultado(uuid, jsonb),
  public.fn_admin_limpar_resultado(uuid),
  public.fn_admin_encerrar(),
  public.fn_admin_reabrir(),
  public.fn_admin_ranking(),
  public.fn_admin_placar_grupos()
to authenticated;

-- Internas (fn_sessao_pessoa, fn_estatisticas, fn_ranking_base,
-- fn_placar_grupos_base, fn_jogos_da_pessoa, fn_qtd_participantes,
-- fn_vencedores, fn_grupo_json, fn_horario_mantido, fn_exige_admin,
-- gatilhos): sem EXECUTE para ninguém da API; só rodam de dentro das
-- funções acima (security definer).
