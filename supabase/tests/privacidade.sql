-- =====================================================================
-- Testes: privacidade do prêmio, permissões, senha, ranking e evento
-- (atualizado na migração 7: ranking oculto até o admin exibir)
-- =====================================================================
-- Como rodar: cole este arquivo inteiro no SQL Editor do Supabase e clique
-- em Run.
--
-- É um único comando DO: ele apaga os dados, cria dados de teste, roda as
-- verificações e TERMINA SEMPRE COM ERRO, de propósito, para o Postgres
-- desfazer tudo. Nada fica gravado, nem se algum teste falhar.
--
--   ✅ Passou:  ERROR: TESTES OK: N verificações passaram ...
--   ❌ Falhou:  ERROR: FALHOU: <o que deu errado>
--
-- Os prêmios dos dados de teste são valores "marcadores" (111.37, 222.41,
-- 333.53, 444.67, 55.55). Para cada participante, o teste procura no texto
-- de tudo o que as funções devolvem qualquer marcador que não seja dele.
-- =====================================================================
do $teste$
declare
  v_admin_claims constant text :=
    '{"sub":"aaaaaaaa-0000-4000-8000-000000000001","role":"authenticated"}';
  v_outro_claims constant text :=
    '{"sub":"bbbbbbbb-0000-4000-8000-000000000002","role":"authenticated"}';

  v_n      integer := 0;      -- verificações que passaram
  v_estado text;              -- sqlstate capturado
  v_msg    text;              -- mensagem capturada
  v_tab    text;
  v_fn     text;
  v_cnt    integer;
  v_txt    text;
  v_vaz    text[];
  v_r      jsonb;
  v_painel jsonb;
  v_jogos  jsonb;
  v_rank   jsonb;
  v_final  jsonb;
  v_tok    text;
  v_tok2   text;
  v_esperado text;
  v_ordem  text[];
  v_p      record;
  v_i      integer;

  g1 uuid; g2 uuid; g3 uuid;                       -- Bruxas, Vampiros, Fantasmas
  ana uuid; bruno uuid; carla uuid; diego uuid; elisa uuid; fabio uuid;
  j1 uuid; j2 uuid; j3 uuid; j4 uuid;
  v_senhas jsonb;
begin
  -- -------------------------------------------------------------------
  -- 0. Banco zerado (desfeito no fim) + um admin de teste
  -- -------------------------------------------------------------------
  update public.evento set aberto = true, encerrado_em = null where id = 1;
  delete from public.transferencia;                                            -- migração 6
  update public.caixa set pessoa_id = null, valor = null, vendido_em = null;   -- migração 5
  delete from public.caixa;
  delete from public.resultado;
  delete from public.participacao;
  delete from public.jogo_grupo;
  delete from public.jogo;
  delete from public.sessao;
  delete from public.pessoa;
  delete from public.grupo;
  insert into public.admin (user_id)
  values ((v_admin_claims::jsonb->>'sub')::uuid) on conflict do nothing;

  -- -------------------------------------------------------------------
  -- 1. Admin monta a gincana pela API (testa RLS de escrita do admin)
  -- -------------------------------------------------------------------
  perform set_config('request.jwt.claims', v_admin_claims, true);
  set local role authenticated;

  insert into public.grupo (nome, cor, icone) values ('Bruxas',    '#9b5cff', '🧙') returning id into g1;
  insert into public.grupo (nome, cor, icone) values ('Vampiros',  '#ff5470', '🧛') returning id into g2;
  insert into public.grupo (nome, cor, icone) values ('Fantasmas', '#4ac7ff', '👻') returning id into g3;

  insert into public.pessoa (nome, grupo_id) values ('Ana',   g1) returning id into ana;
  insert into public.pessoa (nome, grupo_id) values ('Bruno', g1) returning id into bruno;
  insert into public.pessoa (nome, grupo_id) values ('Carla', g2) returning id into carla;
  insert into public.pessoa (nome, grupo_id) values ('Diego', g2) returning id into diego;
  insert into public.pessoa (nome, grupo_id) values ('Elisa', g3) returning id into elisa;
  insert into public.pessoa (nome, grupo_id) values ('Fabio', g3) returning id into fabio;

  v_senhas := jsonb_build_object(ana, '4101', bruno, '4102', carla, '4103',
                                 diego, '4104', elisa, '4105', fabio, '410600');
  for v_p in select key as id, value #>> '{}' as senha from jsonb_each(v_senhas) loop
    perform public.fn_admin_definir_senha(v_p.id::uuid, v_p.senha);
  end loop;

  -- J1: individual, 1º/2º/3º
  insert into public.jogo (nome, tipo, modo, formato) values ('Corrida do Caldeirão', 'Gincana', 'individual', 'colocacao') returning id into j1;
  -- J2: por grupo, vencedor (15 pts / R$ 30 por membro)
  insert into public.jogo (nome, tipo, modo, formato, pontos, premio) values ('Caça às Abóboras', 'Gincana', 'grupo', 'vitoria', 15, 30) returning id into j2;
  -- J3: individual, vencedor (5 pts / R$ 10)
  insert into public.jogo (nome, modo, formato, pontos, premio) values ('Quiz do Terror', 'individual', 'vitoria', 5, 10) returning id into j3;
  -- J4: individual, vencedor, ainda sem resultado
  insert into public.jogo (nome, modo, formato) values ('Morder a Maçã', 'individual', 'vitoria') returning id into j4;

  insert into public.participacao (jogo_id, pessoa_id)
  select j1, p from unnest(array[ana, bruno, carla, diego, elisa, fabio]) p;
  insert into public.participacao (jogo_id, pessoa_id) values (j3, ana), (j3, bruno), (j3, diego), (j4, bruno), (j4, fabio);
  insert into public.jogo_grupo (jogo_id, grupo_id) values (j2, g1), (j2, g2), (j2, g3);

  -- Resultados (prêmios ajustados = marcadores)
  perform public.fn_admin_registrar_resultado(j1, jsonb_build_array(
    jsonb_build_object('pessoa_id', ana,   'colocacao', 1, 'premio', 111.37),
    jsonb_build_object('pessoa_id', elisa, 'colocacao', 2, 'pontos', 25, 'premio', 333.53),
    jsonb_build_object('pessoa_id', carla, 'colocacao', 3, 'premio', 222.41)));
  perform public.fn_admin_registrar_resultado(j2, jsonb_build_array(
    jsonb_build_object('grupo_id', g2, 'premio', 55.55)));
  perform public.fn_admin_registrar_resultado(j3, jsonb_build_array(
    jsonb_build_object('pessoa_id', bruno, 'pontos', 10, 'premio', 444.67)));

  reset role;
  perform set_config('request.jwt.claims', '{}', true);

  -- Horários fixos (só histórico: não entram no desempate)
  update public.resultado set registrado_em = '2026-10-31 22:00+00' where jogo_id = j1;
  update public.resultado set registrado_em = '2026-10-31 23:00+00' where jogo_id = j2;
  update public.resultado set registrado_em = '2026-11-01 00:00+00' where jogo_id = j3;

  -- Totais esperados:
  --   Ana   1 vit 10 pts R$ 111.37      Bruno 1 vit 10 pts R$ 444.67
  --   Carla 1 vit 18 pts R$ 277.96      Diego 1 vit 15 pts R$  55.55
  --   Elisa 0 vit 25 pts R$ 333.53      Fabio — não pontuou

  -- -------------------------------------------------------------------
  -- 2. Dados do teste conferidos
  -- -------------------------------------------------------------------
  select count(*) into v_cnt from public.resultado where jogo_id = j2;
  assert v_cnt = 2, 'FALHOU: jogo por grupo deveria gerar 1 linha por membro de Vampiros (2), gerou ' || v_cnt;
  select count(*) into v_cnt from public.resultado where jogo_id = j2 and pontos = 15 and premio = 55.55 and grupo_id = g2;
  assert v_cnt = 2, 'FALHOU: membros do grupo vencedor deveriam receber os mesmos pontos e prêmio';
  v_n := v_n + 2;

  -- -------------------------------------------------------------------
  -- 3. Senha guardada como hash
  -- -------------------------------------------------------------------
  select count(*) into v_cnt from public.pessoa
   where senha_hash is null or senha_hash !~ '^\$2[aby]\$'
      or senha_hash in ('4101', '4102', '4103', '4104', '4105', '410600');
  assert v_cnt = 0, 'FALHOU: senha deveria estar só como hash bcrypt';
  v_n := v_n + 1;

  -- -------------------------------------------------------------------
  -- 4. anon (navegador do participante) não lê nenhuma tabela
  -- -------------------------------------------------------------------
  foreach v_tab in array array['evento','admin','grupo','pessoa','sessao','jogo',
                               'jogo_grupo','participacao','resultado','caixa',
                               'transferencia'] loop
    v_estado := null;
    begin
      set local role anon;
      execute format('select 1 from public.%I limit 1', v_tab);
    exception when others then v_estado := sqlstate;
    end;
    reset role;
    assert v_estado = '42501', format('FALHOU: anon conseguiu ler a tabela %s', v_tab);
    v_n := v_n + 1;
  end loop;

  v_estado := null;
  begin
    set local role anon;
    insert into public.jogo (nome) values ('invasor');
  exception when others then v_estado := sqlstate;
  end;
  reset role;
  assert v_estado = '42501', 'FALHOU: anon conseguiu inserir jogo';
  v_n := v_n + 1;

  -- anon não executa funções internas nem de admin
  foreach v_fn in array array[
      'public.fn_estatisticas()', 'public.fn_ranking_base()', 'public.fn_placar_grupos_base()',
      'public.fn_sessao_pessoa(''x'')', 'public.fn_jogos_da_pessoa(null)', 'public.fn_vencedores(null)',
      'public.fn_admin_ranking()', 'public.fn_admin_placar_grupos()', 'public.fn_admin_encerrar()',
      'public.fn_admin_definir_senha(null, ''1234'')', 'public.fn_admin_registrar_resultado(null, ''[]'')'] loop
    v_estado := null;
    begin
      set local role anon;
      execute 'select ' || v_fn;
    exception when others then v_estado := sqlstate;
    end;
    reset role;
    assert v_estado = '42501', format('FALHOU: anon conseguiu executar %s', v_fn);
    v_n := v_n + 1;
  end loop;

  -- -------------------------------------------------------------------
  -- 5. Usuário logado no Auth que NÃO é o admin não vê nada
  -- -------------------------------------------------------------------
  perform set_config('request.jwt.claims', v_outro_claims, true);
  set local role authenticated;
  select count(*) into v_cnt from public.pessoa;
  assert v_cnt = 0, 'FALHOU: não-admin leu pessoas';
  select count(*) into v_cnt from public.resultado;
  assert v_cnt = 0, 'FALHOU: não-admin leu resultados';
  reset role;
  v_n := v_n + 2;

  foreach v_fn in array array['public.fn_admin_ranking()', 'public.fn_admin_encerrar()',
                              'public.fn_admin_definir_senha(null, ''1234'')'] loop
    v_estado := null;
    begin
      set local role authenticated;
      execute 'select ' || v_fn;
    exception when others then v_estado := sqlstate;
    end;
    reset role;
    assert v_estado = '42501', format('FALHOU: não-admin conseguiu executar %s', v_fn);
    v_n := v_n + 1;
  end loop;

  v_estado := null;
  begin
    set local role authenticated;
    insert into public.grupo (nome) values ('invasor');
  exception when others then v_estado := sqlstate;
  end;
  reset role;
  assert v_estado = '42501', 'FALHOU: não-admin conseguiu criar grupo';
  v_n := v_n + 1;

  -- Nem o admin lê o hash da senha direto
  perform set_config('request.jwt.claims', v_admin_claims, true);
  v_estado := null;
  begin
    set local role authenticated;
    perform senha_hash from public.pessoa limit 1;
  exception when others then v_estado := sqlstate;
  end;
  reset role;
  assert v_estado = '42501', 'FALHOU: admin conseguiu ler senha_hash';
  set local role authenticated;
  select count(*) into v_cnt from public.pessoa where tem_senha;
  reset role;
  assert v_cnt = 6, 'FALHOU: admin deveria ver as 6 pessoas com tem_senha, viu ' || v_cnt;
  perform set_config('request.jwt.claims', '{}', true);
  v_n := v_n + 2;

  -- -------------------------------------------------------------------
  -- 6. Login, senha errada, bloqueio, sair, sessão inválida
  -- -------------------------------------------------------------------
  set local role anon;
  v_r := public.fn_entrar(ana, '9999');
  reset role;
  assert v_r = '{"erro":"Senha incorreta"}'::jsonb, 'FALHOU: senha errada deveria responder só "Senha incorreta", veio ' || v_r::text;
  v_n := v_n + 1;

  set local role anon;
  v_r := public.fn_entrar(gen_random_uuid(), '4101');
  reset role;
  assert v_r = '{"erro":"Senha incorreta"}'::jsonb, 'FALHOU: pessoa inexistente deveria responder "Senha incorreta"';
  v_n := v_n + 1;

  -- 5 erros seguidos → bloqueio; nem a senha certa entra
  for v_i in 1..5 loop
    set local role anon;
    v_r := public.fn_entrar(bruno, '0000');
    reset role;
    assert v_r->>'erro' = 'Senha incorreta', format('FALHOU: tentativa %s deveria dizer "Senha incorreta"', v_i);
  end loop;
  set local role anon;
  v_r := public.fn_entrar(bruno, '4102');
  reset role;
  assert v_r ? 'erro' and not v_r ? 'token' and v_r->>'erro' like 'Muitas tentativas%',
    'FALHOU: depois de 5 erros a conta deveria ficar bloqueada, veio ' || v_r::text;
  v_n := v_n + 2;

  -- admin redefine a senha → desbloqueia
  perform set_config('request.jwt.claims', v_admin_claims, true);
  set local role authenticated;
  perform public.fn_admin_definir_senha(bruno, '4102');
  reset role;
  set local role anon;
  v_r := public.fn_entrar(bruno, '4102');
  reset role;
  assert v_r ? 'token', 'FALHOU: depois de redefinir a senha o login deveria funcionar';
  v_n := v_n + 1;

  -- senha fora do formato é recusada
  foreach v_txt in array array['12', '1234567', 'abcd', '12a4', ''] loop
    v_estado := null;
    begin
      set local role authenticated;
      perform public.fn_admin_definir_senha(ana, v_txt);
    exception when others then v_estado := sqlstate;
    end;
    reset role;
    assert v_estado = '22023', format('FALHOU: senha "%s" deveria ser recusada', v_txt);
    v_n := v_n + 1;
  end loop;

  -- redefinir senha derruba as sessões abertas
  set local role anon;
  v_tok := public.fn_entrar(carla, '4103')->>'token';
  reset role;
  set local role authenticated;
  perform public.fn_admin_definir_senha(carla, '4103');
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  v_msg := null;
  begin
    set local role anon;
    perform public.fn_meu_painel(v_tok);
  exception when others then v_msg := sqlerrm;
  end;
  reset role;
  assert v_msg = 'Sessão inválida', 'FALHOU: sessão antiga deveria cair depois de redefinir a senha';
  v_n := v_n + 1;

  -- sair encerra a sessão; token inventado não vale
  set local role anon;
  v_tok := public.fn_entrar(diego, '4104')->>'token';
  perform public.fn_meu_painel(v_tok);
  perform public.fn_sair(v_tok);
  reset role;
  foreach v_txt in array array[v_tok, 'token-inventado', ''] loop
    v_msg := null;
    begin
      set local role anon;
      perform public.fn_ranking(v_txt);
    exception when others then v_msg := sqlerrm;
    end;
    reset role;
    assert v_msg = 'Sessão inválida', 'FALHOU: token inválido/encerrado deveria dar "Sessão inválida"';
    v_n := v_n + 1;
  end loop;

  -- a lista do login não traz prêmio, pontos nem senha
  set local role anon;
  v_r := public.fn_lista_login();
  reset role;
  v_txt := v_r::text;
  assert jsonb_array_length(v_r->'pessoas') = 6
     and v_txt !~ '"(premio|pontos|senha|senha_hash|vitorias)"',
    'FALHOU: lista do login deveria ter só nomes e grupos';
  v_n := v_n + 1;

  -- -------------------------------------------------------------------
  -- 7. PRIVACIDADE com o evento ABERTO — para cada participante
  -- -------------------------------------------------------------------
  for v_p in select p.id, p.nome from public.pessoa p order by p.nome loop
    set local role anon;
    v_tok    := public.fn_entrar(v_p.id, v_senhas->>(v_p.id::text))->>'token';
    v_painel := public.fn_meu_painel(v_tok);
    v_jogos  := public.fn_meus_jogos(v_tok);
    v_rank   := public.fn_ranking(v_tok);
    reset role;
    assert v_tok is not null, 'FALHOU: login de ' || v_p.nome;

    -- (a) nenhum valor de prêmio de outra pessoa aparece em nada que ela recebe
    v_txt := v_painel::text || v_jogos::text || v_rank::text;
    with meus as (
      select r.premio::text v from public.resultado r where r.pessoa_id = v_p.id
      union select s.premio::text from public.fn_estatisticas() s where s.pessoa_id = v_p.id
    ), alheios as (
      select r.premio::text v from public.resultado r where r.pessoa_id <> v_p.id
      union select s.premio::text from public.fn_estatisticas() s where s.pessoa_id <> v_p.id
    )
    select array_agg(a.v) into v_vaz
      from alheios a
     where a.v <> '0.00' and a.v not in (select v from meus) and position(a.v in v_txt) > 0;
    assert v_vaz is null, format('FALHOU: %s recebeu prêmio de outra pessoa: %s', v_p.nome, v_vaz);

    -- (b) ranking sem prêmio e, com evento aberto, sem pontos nem colocação (migração 7)
    assert v_rank::text !~ '"premio"', 'FALHOU: ranking contém prêmio (' || v_p.nome || ')';
    assert v_rank::text !~ '"(pontos|posicao|empate|no_desempate)"', 'FALHOU: ranking aberto contém pontos/colocação (' || v_p.nome || ')';
    assert v_painel::text !~ '"(pontos|posicao)"', 'FALHOU: painel com ranking oculto contém pontos/colocação (' || v_p.nome || ')';

    -- (c) o painel traz o PRÓPRIO prêmio, com o valor certo
    select s.premio::text into v_esperado from public.fn_estatisticas() s where s.pessoa_id = v_p.id;
    assert v_painel->>'pessoa_id' = v_p.id::text and v_painel->>'premio' = v_esperado,
      format('FALHOU: painel de %s deveria ter prêmio %s, veio %s', v_p.nome, v_esperado, v_painel->>'premio');

    -- (d) "meus jogos" só traz as regras: sem resultado, pontos nem prêmio (migração 7)
    select count(*) into v_cnt
      from jsonb_array_elements(v_jogos) e
     where e ? 'premio' or e ? 'pontos' or e ? 'meu_resultado' or e ? 'pontuado';
    assert v_cnt = 0, 'FALHOU: meus jogos com resultado/pontos (' || v_p.nome || ')';

    -- (e) resultado final ainda não existe
    v_msg := null;
    begin
      set local role anon;
      perform public.fn_resultado_final(v_tok);
    exception when others then v_msg := sqlerrm;
    end;
    reset role;
    assert v_msg like 'O resultado final aparece%', 'FALHOU: resultado final liberado com evento aberto';

    set local role anon;
    perform public.fn_sair(v_tok);
    reset role;
    v_n := v_n + 7;
  end loop;

  -- prêmios conferidos um a um
  set local role anon;
  v_tok := public.fn_entrar(carla, '4103')->>'token';
  v_painel := public.fn_meu_painel(v_tok);
  v_jogos := public.fn_meus_jogos(v_tok);
  v_tok2 := public.fn_entrar(fabio, '410600')->>'token';
  v_r := public.fn_meu_painel(v_tok2);
  reset role;
  assert v_painel->>'premio' = '277.96', 'FALHOU: prêmio da Carla deveria ser 277.96';
  assert not v_painel ? 'pontos' and (v_painel->>'vitorias')::int = 1, 'FALHOU: vitórias da Carla (sem pontos com ranking oculto)';
  assert jsonb_array_length(v_painel->'resultados') = 2, 'FALHOU: Carla tem 2 resultados';
  assert v_r->>'premio' = '0.00' and not v_r ? 'posicao', 'FALHOU: Fabio não pontuou: R$ 0 e sem posição';
  assert (v_r->>'qtd_jogos')::int = 3, 'FALHOU: Fabio participa de 3 jogos (J1, J2 pelo grupo, J4)';
  v_n := v_n + 5;

  -- -------------------------------------------------------------------
  -- 8. Ranking com evento ABERTO
  --    participante: só vitórias, ordem vitórias → nome (migração 7)
  --    admin: vitórias → pontos; iguais = empate (dense_rank)
  -- -------------------------------------------------------------------
  set local role anon;
  v_rank := public.fn_ranking(v_tok);
  reset role;
  select array_agg(l->>'nome' order by o) into v_ordem
    from jsonb_array_elements(v_rank->'linhas') with ordinality t(l, o);
  assert v_ordem = array['Ana','Bruno','Carla','Diego','Elisa','Fabio'],
    'FALHOU: lista de vitórias (vitórias, depois nome): ' || array_to_string(v_ordem, ', ');
  assert not exists (select 1 from jsonb_array_elements(v_rank->'linhas') l
                      where (select string_agg(k, ',' order by k) from jsonb_object_keys(l) k) <> 'eu,grupo,nome,pessoa_id,vitorias'),
    'FALHOU: lista de vitórias só com nome, grupo e vitórias';
  assert (select count(*) from jsonb_array_elements(v_rank->'linhas') l where (l->>'eu')::boolean) = 1
     and (select l->>'nome' from jsonb_array_elements(v_rank->'linhas') l where (l->>'eu')::boolean) = 'Carla',
    'FALHOU: marcação "eu" no ranking';
  v_n := v_n + 3;

  perform set_config('request.jwt.claims', v_admin_claims, true);
  set local role authenticated;
  v_r := public.fn_admin_ranking();
  reset role;
  select array_agg(l->>'nome' order by o) into v_ordem
    from jsonb_array_elements(v_r) with ordinality t(l, o);
  assert v_ordem = array['Carla','Diego','Ana','Bruno','Elisa','Fabio'],
    'FALHOU: ordem do ranking aberto (admin): ' || array_to_string(v_ordem, ', ');
  select array_agg(coalesce(l->>'posicao', '-') order by o) into v_ordem
    from jsonb_array_elements(v_r) with ordinality t(l, o);
  -- Ana e Bruno: mesmas vitórias e pontos → dividem o 3º; Elisa fica em 4º (1º, 2º, 3º, 3º, 4º)
  assert v_ordem = array['1','2','3','3','4','-'], 'FALHOU: posições do ranking aberto: ' || array_to_string(v_ordem, ', ');
  assert (select bool_and((l->>'empate')::boolean and not (l->>'no_desempate')::boolean)
            from jsonb_array_elements(v_r) l where l->>'nome' in ('Ana','Bruno')),
    'FALHOU: Ana e Bruno deveriam estar empatados';
  -- Carla e Diego: mesma vitória, separados pelos pontos → "no desempate"
  assert (select bool_and((l->>'no_desempate')::boolean and not (l->>'empate')::boolean)
            from jsonb_array_elements(v_r) l where l->>'nome' in ('Carla','Diego')),
    'FALHOU: Carla e Diego deveriam estar "no desempate"';
  -- Elisa: única com 0 vitórias entre quem pontuou → sem etiqueta
  assert (select not (l->>'empate')::boolean and not (l->>'no_desempate')::boolean
            from jsonb_array_elements(v_r) l where l->>'nome' = 'Elisa'),
    'FALHOU: Elisa não deveria ter etiqueta';
  assert (select not (l->>'empate')::boolean and not (l->>'no_desempate')::boolean and not (l->>'pontuou')::boolean
            from jsonb_array_elements(v_r) l where l->>'nome' = 'Fabio'),
    'FALHOU: Fabio não pontuou: sem etiquetas';
  assert (select l->>'premio' from jsonb_array_elements(v_r) l where l->>'nome' = 'Bruno') = '444.67',
    'FALHOU: admin deveria ver o prêmio de todos';
  v_n := v_n + 7;

  -- o horário não desempata: mudar quem pontuou antes não muda nada
  update public.resultado set registrado_em = '2026-10-30 22:00+00' where jogo_id = j3;
  set local role authenticated;
  v_r := public.fn_admin_ranking();
  reset role;
  select array_agg(coalesce(l->>'posicao', '-') || case when (l->>'empate')::boolean then 'E' else '' end order by o) into v_ordem
    from jsonb_array_elements(v_r) with ordinality t(l, o);
  assert v_ordem = array['1','2','3E','3E','4','-'], 'FALHOU: horário não pode desempatar: ' || array_to_string(v_ordem, ', ');
  update public.resultado set registrado_em = '2026-11-01 00:00+00' where jogo_id = j3;
  v_n := v_n + 1;

  -- placar de grupos (admin): jogo por grupo conta uma vez
  set local role authenticated;
  v_r := public.fn_admin_placar_grupos();
  reset role;
  select array_agg(format('%s:%s:%s:%s', l->>'nome', l->>'pontos', l->>'vitorias', l->>'posicao') order by o) into v_ordem
    from jsonb_array_elements(v_r) with ordinality t(l, o);
  assert v_ordem = array['Fantasmas:25:0:1','Bruxas:20:2:2','Vampiros:18:1:3'],
    'FALHOU: placar de grupos: ' || array_to_string(v_ordem, ', ');
  assert (select l->>'premio' from jsonb_array_elements(v_r) l where l->>'nome' = 'Vampiros') = '333.51',
    'FALHOU: prêmio do grupo Vampiros (2 × 55.55 + 222.41)';
  v_n := v_n + 2;

  -- regras de registro
  v_estado := null;
  begin
    set local role authenticated;
    perform public.fn_admin_registrar_resultado(j3, jsonb_build_array(jsonb_build_object('pessoa_id', carla)));
  exception when others then v_estado := sqlstate;
  end;
  reset role;
  assert v_estado = '22023', 'FALHOU: não deveria pontuar quem não participa do jogo';
  v_estado := null;
  begin
    set local role authenticated;
    perform public.fn_admin_registrar_resultado(j3, jsonb_build_array(jsonb_build_object('pessoa_id', bruno, 'colocacao', 2)));
  exception when others then v_estado := sqlstate;
  end;
  reset role;
  assert v_estado = '22023', 'FALHOU: jogo "vencedor" não aceita 2º lugar';
  v_n := v_n + 2;

  -- -------------------------------------------------------------------
  -- 9. Evento ENCERRADO
  -- -------------------------------------------------------------------
  set local role authenticated;
  perform public.fn_admin_encerrar();
  reset role;

  -- admin não cadastra nem pontua
  foreach v_txt in array array[
      'insert into public.jogo (nome) values (''novo'')',
      'insert into public.grupo (nome) values (''novo'')',
      'update public.pessoa set nome = ''Ana Maria'' where nome = ''Ana''',
      'delete from public.participacao where true',
      'select public.fn_admin_registrar_resultado(''' || j4 || ''', ''[]'')',
      'select public.fn_admin_limpar_resultado(''' || j1 || ''')'] loop
    v_msg := null;
    begin
      set local role authenticated;
      execute v_txt;
    exception when others then v_msg := sqlerrm;
    end;
    reset role;
    assert v_msg like 'O período de jogos está encerrado%', 'FALHOU: com evento encerrado deveria bloquear: ' || v_txt;
    v_n := v_n + 1;
  end loop;
  perform set_config('request.jwt.claims', '{}', true);

  -- encerrado, ranking ainda oculto: nada de pontos nem colocação (migração 7)
  for v_p in select p.id, p.nome from public.pessoa p order by p.nome loop
    set local role anon;
    v_tok    := public.fn_entrar(v_p.id, v_senhas->>(v_p.id::text))->>'token';
    v_txt    := public.fn_meu_painel(v_tok)::text || public.fn_meus_jogos(v_tok)::text
             || public.fn_ranking(v_tok)::text;
    v_final  := public.fn_resultado_final(v_tok);
    perform public.fn_sair(v_tok);
    reset role;
    assert (v_txt || v_final::text) !~ '"(pontos|posicao|empate|no_desempate)"',
      'FALHOU: ranking oculto com pontos/colocação (' || v_p.nome || ')';
    assert not (v_final->>'visivel')::boolean and v_final->'grupos' = '[]'::jsonb,
      'FALHOU: resultado final oculto sem placar de grupos (' || v_p.nome || ')';
    v_n := v_n + 2;
  end loop;

  -- admin exibe o ranking
  perform set_config('request.jwt.claims', v_admin_claims, true);
  set local role authenticated;
  perform public.fn_admin_exibir_ranking(true);
  reset role;
  perform set_config('request.jwt.claims', '{}', true);

  -- participante: login funciona; nada de prêmio alheio em lugar nenhum
  for v_p in select p.id, p.nome from public.pessoa p order by p.nome loop
    set local role anon;
    v_tok    := public.fn_entrar(v_p.id, v_senhas->>(v_p.id::text))->>'token';
    v_painel := public.fn_meu_painel(v_tok);
    v_jogos  := public.fn_meus_jogos(v_tok);
    v_rank   := public.fn_ranking(v_tok);
    v_final  := public.fn_resultado_final(v_tok);
    reset role;
    assert v_tok is not null, 'FALHOU: login com evento encerrado (' || v_p.nome || ')';

    v_txt := v_painel::text || v_jogos::text || v_rank::text || v_final::text;
    with meus as (
      select r.premio::text v from public.resultado r where r.pessoa_id = v_p.id
      union select s.premio::text from public.fn_estatisticas() s where s.pessoa_id = v_p.id
    ), alheios as (
      select r.premio::text v from public.resultado r where r.pessoa_id <> v_p.id
      union select s.premio::text from public.fn_estatisticas() s where s.pessoa_id <> v_p.id
      union select g.premio::text from public.fn_placar_grupos_base() g
    )
    select array_agg(a.v) into v_vaz
      from alheios a
     where a.v <> '0.00' and a.v not in (select v from meus) and position(a.v in v_txt) > 0;
    assert v_vaz is null, format('FALHOU: (encerrado) %s recebeu prêmio de outra pessoa/grupo: %s', v_p.nome, v_vaz);

    assert v_rank::text !~ '"premio"' and v_final::text !~ '"premio"',
      'FALHOU: ranking/resultado final com prêmio (' || v_p.nome || ')';
    assert v_rank::text ~ '"pontos"', 'FALHOU: ranking encerrado deveria mostrar pontos';

    set local role anon;
    perform public.fn_sair(v_tok);
    reset role;
    v_n := v_n + 4;
  end loop;

  -- ranking encerrado: pontos → vitórias; Ana e Bruno iguais nos dois → dividem o 4º
  select array_agg(format('%s:%s%s', l->>'nome', coalesce(l->>'posicao', '-'),
                          case when (l->>'empate')::boolean then 'E'
                               when (l->>'no_desempate')::boolean then 'D' else '' end) order by o) into v_ordem
    from jsonb_array_elements(v_final->'ranking') with ordinality t(l, o);
  assert v_ordem = array['Elisa:1','Carla:2','Diego:3','Ana:4E','Bruno:4E','Fabio:-'],
    'FALHOU: ranking final: ' || array_to_string(v_ordem, ', ');
  select array_agg(format('%s:%s', l->>'nome', l->>'pontos') order by o) into v_ordem
    from jsonb_array_elements(v_final->'grupos') with ordinality t(l, o);
  assert v_ordem = array['Fantasmas:25','Bruxas:20','Vampiros:18'], 'FALHOU: grupos no resultado final';
  select l->'vencedores' into v_r from jsonb_array_elements(v_final->'jogos') l where l->>'nome' = 'Caça às Abóboras';
  assert jsonb_array_length(v_r) = 1 and v_r->0->>'nome' = 'Vampiros' and (v_r->0->>'cada')::boolean,
    'FALHOU: vencedor do jogo por grupo aparece uma vez, como grupo';
  select l->'vencedores' into v_r from jsonb_array_elements(v_final->'jogos') l where l->>'nome' = 'Corrida do Caldeirão';
  assert (select array_agg(x->>'nome' order by o) from jsonb_array_elements(v_r) with ordinality t(x, o)) = array['Ana','Elisa','Carla'],
    'FALHOU: vencedores da Corrida em ordem de colocação';
  v_n := v_n + 4;

  -- reabrir libera o cadastro
  perform set_config('request.jwt.claims', v_admin_claims, true);
  set local role authenticated;
  perform public.fn_admin_reabrir();
  insert into public.jogo (nome) values ('Depois de reabrir');
  reset role;
  v_n := v_n + 1;

  -- -------------------------------------------------------------------
  -- 10. Mudar o formato de um jogo com resultado apaga o resultado
  -- -------------------------------------------------------------------
  set local role authenticated;
  update public.jogo set nome = 'Quiz do Terror II' where id = j3;      -- só nome: mantém
  reset role;
  select count(*) into v_cnt from public.resultado where jogo_id = j3;
  assert v_cnt = 1, 'FALHOU: mudar só o nome não pode apagar o resultado';

  set local role authenticated;
  update public.jogo set formato = 'colocacao' where id = j1;           -- igual: mantém
  reset role;
  select count(*) into v_cnt from public.resultado where jogo_id = j1;
  assert v_cnt = 3, 'FALHOU: formato igual não pode apagar o resultado';

  set local role authenticated;
  update public.jogo set formato = 'colocacao' where id = j3;           -- mudou: apaga
  update public.jogo set modo = 'individual' where id = j2;             -- mudou: apaga
  reset role;
  select count(*) into v_cnt from public.resultado where jogo_id in (j2, j3);
  assert v_cnt = 0, 'FALHOU: mudar o formato deveria apagar o resultado';
  select count(*) into v_cnt from public.jogo where id in (j2, j3) and pontuado_em is not null;
  assert v_cnt = 0, 'FALHOU: jogo com formato mudado volta a "aguardando resultado"';
  perform set_config('request.jwt.claims', '{}', true);
  v_n := v_n + 4;

  -- -------------------------------------------------------------------
  -- Fim: erro proposital para desfazer tudo
  -- -------------------------------------------------------------------
  raise exception 'TESTES OK: % verificações passaram. (Esta mensagem aparece como erro de propósito: assim tudo o que o teste gravou é desfeito.)', v_n
    using errcode = 'P0001';
end
$teste$;
