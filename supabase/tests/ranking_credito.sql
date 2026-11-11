-- =====================================================================
-- Testes: ranking oculto, "Meus jogos" só com regras, crédito do ADM e
-- e-mail do admin para o login só com senha (migração 7)
-- =====================================================================
-- Como rodar: depois da migração 7, cole este arquivo inteiro no SQL
-- Editor do Supabase e clique em Run.
--
-- Como os outros testes, é um único DO que TERMINA SEMPRE COM ERRO, de
-- propósito, para o Postgres desfazer tudo. Nada fica gravado.
--
--   ✅ Passou:  ERROR: TESTES OK (ranking oculto e crédito): N verificações passaram ...
--   ❌ Falhou:  ERROR: FALHOU: <o que deu errado>
--
-- Valores "marcadores": ganhos 71.23 / 52.19, crédito 87.41 com o motivo
-- CREDITO-Z9. Pontos 37 / 29 / 23 (para provar que não aparecem).
-- =====================================================================
do $teste$
declare
  v_admin_id constant uuid := 'aaaaaaaa-0000-4000-8000-000000000001';
  v_admin_claims constant text :=
    '{"sub":"aaaaaaaa-0000-4000-8000-000000000001","role":"authenticated"}';
  v_outro_claims constant text :=
    '{"sub":"bbbbbbbb-0000-4000-8000-000000000002","role":"authenticated"}';

  v_n      integer := 0;
  v_estado text;
  v_msg    text;
  v_fn     text;
  v_cnt    integer;
  v_txt    text;
  v_r      jsonb;
  v_painel jsonb;
  v_final  jsonb;
  v_tok    text;
  v_tokb   text;
  v_tokc   text;
  v_ordem  text[];

  ana uuid; bruno uuid; carla uuid;
  j1 uuid; j2 uuid; j3 uuid;
  c1 uuid; t1 uuid;
begin
  -- -------------------------------------------------------------------
  -- 0. Banco zerado (desfeito no fim) + admin de teste
  -- -------------------------------------------------------------------
  update public.evento set aberto = true, encerrado_em = null, ranking_visivel = false where id = 1;
  delete from public.transferencia;
  update public.caixa set pessoa_id = null, valor = null, vendido_em = null;
  delete from public.caixa;
  delete from public.resultado;
  delete from public.participacao;
  delete from public.jogo_grupo;
  delete from public.jogo;
  delete from public.sessao;
  delete from public.pessoa;
  delete from public.grupo;
  insert into public.admin (user_id) values (v_admin_id) on conflict do nothing;

  perform set_config('request.jwt.claims', v_admin_claims, true);
  set local role authenticated;
  insert into public.pessoa (nome) values ('Ana')   returning id into ana;
  insert into public.pessoa (nome) values ('Bruno') returning id into bruno;
  insert into public.pessoa (nome) values ('Carla') returning id into carla;
  perform public.fn_admin_definir_senha(ana, '7101');
  perform public.fn_admin_definir_senha(bruno, '7102');
  perform public.fn_admin_definir_senha(carla, '7103');

  insert into public.jogo (nome, tipo, descricao, modo, formato) values
    ('Corrida', 'Gincana', 'DESC-CORRIDA', 'individual', 'colocacao') returning id into j1;
  insert into public.jogo (nome, modo, formato) values ('Quiz', 'individual', 'vitoria') returning id into j2;
  insert into public.jogo (nome, modo, formato) values ('Maçã', 'individual', 'vitoria') returning id into j3;
  insert into public.participacao (jogo_id, pessoa_id)
  select j, p from unnest(array[j1, j2, j3]) j, unnest(array[ana, bruno, carla]) p;

  -- Bruno e Carla 1 vitória cada; Carla tem MAIS pontos (37) que Bruno (29).
  -- Ana 0 vitórias, 23 pontos.
  perform public.fn_admin_registrar_resultado(j1, jsonb_build_array(
    jsonb_build_object('pessoa_id', carla, 'colocacao', 1, 'pontos', 37, 'premio', 71.23),
    jsonb_build_object('pessoa_id', ana,   'colocacao', 2, 'pontos', 23, 'premio', 0)));
  perform public.fn_admin_registrar_resultado(j2, jsonb_build_array(
    jsonb_build_object('pessoa_id', bruno, 'pontos', 29, 'premio', 52.19)));

  -- -------------------------------------------------------------------
  -- 1. Permissões das funções novas
  -- -------------------------------------------------------------------
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  foreach v_fn in array array[
      'public.fn_admin_exibir_ranking(true)', 'public.fn_admin_creditar(null, 1, '''')',
      'public.fn_ranking_liberado()', 'public.fn_lista_vitorias(null)'] loop
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

  perform set_config('request.jwt.claims', v_outro_claims, true);
  foreach v_fn in array array[
      'public.fn_admin_exibir_ranking(false)', format('public.fn_admin_creditar(%L, 1, '''')', ana)] loop
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
  perform set_config('request.jwt.claims', '{}', true);

  -- -------------------------------------------------------------------
  -- 2. E-mail do admin (login só com senha)
  -- -------------------------------------------------------------------
  set local role anon;
  v_txt := public.fn_email_admin();
  reset role;
  assert v_txt is not distinct from (select u.email::text from public.admin a join auth.users u on u.id = a.user_id
                                      order by u.created_at limit 1),
    'FALHOU: fn_email_admin deveria devolver o e-mail da conta do admin, veio ' || coalesce(v_txt, '∅');
  v_n := v_n + 1;

  -- -------------------------------------------------------------------
  -- 3. Ranking OCULTO com o período aberto
  -- -------------------------------------------------------------------
  set local role anon;
  v_tok  := public.fn_entrar(ana, '7101')->>'token';
  v_tokb := public.fn_entrar(bruno, '7102')->>'token';
  v_tokc := public.fn_entrar(carla, '7103')->>'token';
  v_r := public.fn_ranking(v_tok);
  reset role;
  -- Bruno antes de Carla (nome), mesmo com menos pontos: a ordem não vaza a pontuação
  select array_agg(format('%s:%s', l->>'nome', l->>'vitorias') order by o) into v_ordem
    from jsonb_array_elements(v_r->'linhas') with ordinality t(l, o);
  assert v_ordem = array['Bruno:1','Carla:1','Ana:0'], 'FALHOU: lista de vitórias: ' || array_to_string(v_ordem, ', ');
  assert not (v_r->>'visivel')::boolean and v_r::text !~ '"(pontos|posicao|empate|no_desempate|premio)"',
    'FALHOU: ranking oculto com pontos/colocação';
  v_n := v_n + 2;

  -- muda os pontos (Carla 37 → 2): a ordem não muda
  perform set_config('request.jwt.claims', v_admin_claims, true);
  set local role authenticated;
  perform public.fn_admin_registrar_resultado(j1, jsonb_build_array(
    jsonb_build_object('pessoa_id', carla, 'colocacao', 1, 'pontos', 2, 'premio', 71.23),
    jsonb_build_object('pessoa_id', ana,   'colocacao', 2, 'pontos', 23, 'premio', 0)));
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  set local role anon;
  v_r := public.fn_ranking(v_tok);
  reset role;
  select array_agg(l->>'nome' order by o) into v_ordem
    from jsonb_array_elements(v_r->'linhas') with ordinality t(l, o);
  assert v_ordem = array['Bruno','Carla','Ana'], 'FALHOU: ordem oculta mudou com os pontos: ' || array_to_string(v_ordem, ', ');
  v_n := v_n + 1;
  perform set_config('request.jwt.claims', v_admin_claims, true);
  set local role authenticated;
  perform public.fn_admin_registrar_resultado(j1, jsonb_build_array(
    jsonb_build_object('pessoa_id', carla, 'colocacao', 1, 'pontos', 37, 'premio', 71.23),
    jsonb_build_object('pessoa_id', ana,   'colocacao', 2, 'pontos', 23, 'premio', 0)));
  reset role;
  perform set_config('request.jwt.claims', '{}', true);

  -- painel: sem pontos e sem colocação; vitórias, jogos e as próprias colocações sem pontos
  set local role anon;
  v_painel := public.fn_meu_painel(v_tokc);
  reset role;
  assert not (v_painel ? 'pontos' or v_painel ? 'posicao' or v_painel ? 'empate')
     and (v_painel->>'vitorias')::int = 1 and (v_painel->>'qtd_jogos')::int = 3
     and not (v_painel->'evento'->>'ranking_visivel')::boolean,
    'FALHOU: painel oculto: ' || v_painel::text;
  assert jsonb_array_length(v_painel->'resultados') = 1 and not (v_painel->'resultados'->0 ? 'pontos')
     and v_painel->'resultados'->0->>'colocacao' = '1',
    'FALHOU: próprias colocações sem pontos';
  v_n := v_n + 2;

  -- "Meus jogos": só as regras
  set local role anon;
  v_r := public.fn_meus_jogos(v_tokc);
  reset role;
  assert jsonb_array_length(v_r) = 3
     and not exists (select 1 from jsonb_array_elements(v_r) e
                      where (select string_agg(k, ',' order by k) from jsonb_object_keys(e) k)
                            <> 'descricao,formato,id,modo,nome,partida,tipo'),
    'FALHOU: meus jogos deveria ter só as regras: ' || v_r::text;
  assert (select e->>'descricao' from jsonb_array_elements(v_r) e where e->>'nome' = 'Corrida') = 'DESC-CORRIDA',
    'FALHOU: meus jogos com a descrição';
  v_n := v_n + 2;

  -- exibir com o período aberto: recusado pelo banco
  perform set_config('request.jwt.claims', v_admin_claims, true);
  v_msg := null;
  begin
    set local role authenticated;
    perform public.fn_admin_exibir_ranking(true);
  exception when others then v_msg := sqlerrm;
  end;
  reset role;
  assert v_msg = 'Encerre o período de jogos antes de exibir o ranking.', 'FALHOU: exibir com período aberto: ' || coalesce(v_msg, 'passou');
  select ranking_visivel::text into v_txt from public.evento;
  assert v_txt = 'false', 'FALHOU: ranking ficou visível com período aberto';
  -- mesmo que a flag fique ligada com o período aberto, as funções continuam ocultando
  reset role;
  update public.evento set ranking_visivel = true where id = 1;
  perform set_config('request.jwt.claims', '{}', true);
  set local role anon;
  v_txt := public.fn_ranking(v_tok)::text || public.fn_meu_painel(v_tok)::text;
  reset role;
  update public.evento set ranking_visivel = false where id = 1;
  assert v_txt !~ '"(pontos|posicao)"', 'FALHOU: período aberto com a flag ligada mostrou pontos/colocação';
  perform set_config('request.jwt.claims', v_admin_claims, true);
  v_n := v_n + 3;

  -- -------------------------------------------------------------------
  -- 4. Crédito do ADM (com o período ABERTO)
  -- -------------------------------------------------------------------
  foreach v_txt in array array['0', '-5', '1.234', '2000000'] loop
    v_estado := null;
    begin
      set local role authenticated;
      perform public.fn_admin_creditar(ana, v_txt::numeric, '');
    exception when others then v_estado := sqlstate;
    end;
    reset role;
    assert v_estado = '22023', format('FALHOU: crédito de %s deveria ser recusado', v_txt);
    v_n := v_n + 1;
  end loop;
  v_estado := null;
  begin
    set local role authenticated;
    perform public.fn_admin_creditar(gen_random_uuid(), 10, '');
  exception when others then v_estado := sqlstate;
  end;
  reset role;
  assert v_estado = '22023', 'FALHOU: crédito para pessoa inexistente';
  v_n := v_n + 1;

  set local role authenticated;
  perform public.fn_admin_creditar(ana, 87.41, '  CREDITO-Z9 ');
  reset role;
  select id into t1 from public.transferencia;
  select format('%s/%s/%s', origem, coalesce(de_pessoa_id::text, 'null'), motivo) into v_txt from public.transferencia;
  assert v_txt = 'admin/null/CREDITO-Z9', 'FALHOU: crédito gravado com origem admin: ' || v_txt;
  v_n := v_n + 1;

  -- só dinheiro: pontos e vitórias não mudam
  select string_agg(format('%s:%s/%s', p.nome, s.pontos, s.vitorias), ' ' order by p.nome)
    into v_txt from public.fn_estatisticas() s join public.pessoa p on p.id = s.pessoa_id;
  assert v_txt = 'Ana:23/0 Bruno:29/1 Carla:37/1', 'FALHOU: crédito mudou pontos/vitórias: ' || v_txt;
  select string_agg(format('%s:%s/%s/%s/%s/%s/%s', p.nome, s.ganho, s.credito, s.recebido, s.doado, s.gasto, s.saldo), ' ' order by p.nome)
    into v_txt from public.fn_saldos() s join public.pessoa p on p.id = s.pessoa_id;
  assert v_txt = 'Ana:0.00/87.41/0.00/0.00/0.00/87.41 Bruno:52.19/0.00/0.00/0.00/0.00/52.19 Carla:71.23/0.00/0.00/0.00/0.00/71.23',
    'FALHOU: saldos com crédito: ' || v_txt;
  v_n := v_n + 2;

  -- regra da tabela: crédito sem origem admin ou doação sem quem doa → recusado
  reset role;
  v_estado := null;
  begin
    insert into public.transferencia (origem, de_pessoa_id, para_pessoa_id, valor) values ('participante', null, ana, 1);
  exception when others then v_estado := sqlstate;
  end;
  assert v_estado = '23514', 'FALHOU: doação sem quem doa deveria violar a regra';
  v_estado := null;
  begin
    insert into public.transferencia (origem, de_pessoa_id, para_pessoa_id, valor) values ('admin', bruno, ana, 1);
  exception when others then v_estado := sqlstate;
  end;
  assert v_estado = '23514', 'FALHOU: crédito do ADM com quem doa deveria violar a regra';
  v_n := v_n + 2;

  -- participante vê o crédito como "Crédito do ADM"; os outros não veem nada
  perform set_config('request.jwt.claims', '{}', true);
  set local role anon;
  v_painel := public.fn_meu_painel(v_tok);
  reset role;
  assert v_painel->>'credito' = '87.41' and v_painel->>'saldo' = '87.41' and v_painel->>'recebido' = '0.00',
    'FALHOU: painel da Ana com o crédito: ' || v_painel::text;
  assert jsonb_array_length(v_painel->'doacoes') = 1
     and v_painel->'doacoes'->0->>'tipo' = 'credito'
     and v_painel->'doacoes'->0->'nome' = 'null'::jsonb
     and v_painel->'doacoes'->0->>'recado' = 'CREDITO-Z9',
    'FALHOU: extrato da Ana com "Crédito do ADM": ' || (v_painel->'doacoes')::text;
  set local role anon;
  v_txt := public.fn_meu_painel(v_tokb)::text || public.fn_meu_painel(v_tokc)::text
        || public.fn_ranking(v_tokb)::text || public.fn_meus_jogos(v_tokb)::text;
  reset role;
  assert position('87.41' in v_txt) = 0 and position('CREDITO-Z9' in v_txt) = 0,
    'FALHOU: outro participante viu o crédito da Ana';
  v_n := v_n + 3;

  -- -------------------------------------------------------------------
  -- 5. Período ENCERRADO, ranking ainda oculto
  -- -------------------------------------------------------------------
  perform set_config('request.jwt.claims', v_admin_claims, true);
  set local role authenticated;
  perform public.fn_admin_encerrar();
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  set local role anon;
  v_final := public.fn_resultado_final(v_tok);
  v_r     := public.fn_ranking(v_tok);
  v_painel := public.fn_meu_painel(v_tok);
  reset role;
  assert not (v_final->>'visivel')::boolean and v_final->'grupos' = '[]'::jsonb
     and (v_final::text || v_r::text || v_painel::text) !~ '"(pontos|posicao|empate|no_desempate)"',
    'FALHOU: encerrado e oculto ainda sem pontos/colocação';
  select array_agg(l->>'nome' order by o) into v_ordem
    from jsonb_array_elements(v_final->'ranking') with ordinality t(l, o);
  assert v_ordem = array['Bruno','Carla','Ana'], 'FALHOU: resultado oculto = lista de vitórias: ' || array_to_string(v_ordem, ', ');
  select l->'vencedores' into v_r from jsonb_array_elements(v_final->'jogos') l where l->>'nome' = 'Corrida';
  assert (select array_agg(format('%s:%s', x->>'nome', x->>'colocacao') order by o) from jsonb_array_elements(v_r) with ordinality t(x, o))
         = array['Carla:1','Ana:2'],
    'FALHOU: vencedores sem pontos, com a colocação: ' || v_r::text;
  v_n := v_n + 3;

  -- doação de Ana usando o crédito; Carla arremata
  set local role anon;
  perform public.fn_doar(v_tok, bruno, 50, '');
  reset role;
  perform set_config('request.jwt.claims', v_admin_claims, true);
  set local role authenticated;
  perform public.fn_admin_adicionar_caixas(1);
  select id into c1 from public.caixa where numero = 1;
  -- desfazer crédito já usado (Ana doou 50 de 87.41): recusado
  v_msg := null;
  begin
    perform public.fn_admin_desfazer_doacao(t1);
  exception when others then v_msg := sqlerrm;
  end;
  assert v_msg = 'Ana já usou parte desse valor. Desfaça antes o arremate ou a doação que usou o dinheiro.',
    'FALHOU: desfazer crédito já usado: ' || coalesce(v_msg, 'passou');
  -- crédito também pode ser dado com o período encerrado
  perform public.fn_admin_creditar(carla, 5, 'fantasia');
  reset role;
  select format('%s/%s', s.credito, s.saldo) into v_txt from public.fn_saldos() s where s.pessoa_id = carla;
  assert v_txt = '5.00/76.23', 'FALHOU: crédito com período encerrado: ' || v_txt;
  select format('%s/%s/%s', s.credito, s.doado, s.saldo) into v_txt from public.fn_saldos() s where s.pessoa_id = ana;
  assert v_txt = '87.41/50.00/37.41', 'FALHOU: saldo da Ana (crédito − doação): ' || v_txt;
  v_n := v_n + 3;

  -- -------------------------------------------------------------------
  -- 6. Exibir ranking: pontos e colocação aparecem; ocultar volta
  -- -------------------------------------------------------------------
  set local role authenticated;
  perform public.fn_admin_exibir_ranking(true);
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  set local role anon;
  v_final  := public.fn_resultado_final(v_tok);
  v_r      := public.fn_ranking(v_tok);
  v_painel := public.fn_meu_painel(v_tokc);
  reset role;
  select array_agg(format('%s:%s:%s', l->>'nome', l->>'pontos', coalesce(l->>'posicao', '-')) order by o) into v_ordem
    from jsonb_array_elements(v_final->'ranking') with ordinality t(l, o);
  assert (v_final->>'visivel')::boolean and v_ordem = array['Carla:37:1','Bruno:29:2','Ana:23:3'],
    'FALHOU: ranking liberado: ' || array_to_string(v_ordem, ', ');
  assert (v_r->>'visivel')::boolean and v_r::text ~ '"pontos"' and v_r::text !~ '"premio"',
    'FALHOU: fn_ranking liberado com pontos e sem prêmio';
  assert (v_painel->>'pontos')::int = 37 and (v_painel->>'posicao')::int = 1
     and (v_painel->'resultados'->0->>'pontos')::int = 37
     and (v_painel->'evento'->>'ranking_visivel')::boolean,
    'FALHOU: painel liberado com pontos e posição';
  select l->'vencedores' into v_r from jsonb_array_elements(v_final->'jogos') l where l->>'nome' = 'Corrida';
  assert v_r->0->>'pontos' = '37', 'FALHOU: vencedores com pontos depois de liberar';
  -- dinheiro continua privado com o ranking liberado
  assert (v_final::text) !~ '"premio"' and position('87.41' in v_painel::text) = 0
     and position('52.19' in v_painel::text) = 0,
    'FALHOU: ranking liberado mostrou dinheiro de outra pessoa';
  v_n := v_n + 5;

  perform set_config('request.jwt.claims', v_admin_claims, true);
  set local role authenticated;
  perform public.fn_admin_exibir_ranking(false);
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  set local role anon;
  v_r := public.fn_ranking(v_tok);
  reset role;
  assert not (v_r->>'visivel')::boolean and v_r::text !~ '"pontos"', 'FALHOU: ocultar de novo';
  v_n := v_n + 1;

  -- reabrir o período volta a ocultar
  perform set_config('request.jwt.claims', v_admin_claims, true);
  set local role authenticated;
  perform public.fn_admin_exibir_ranking(true);
  perform public.fn_admin_reabrir();
  reset role;
  select format('%s/%s', aberto::text, ranking_visivel::text) into v_txt from public.evento;
  assert v_txt = 'true/false', 'FALHOU: reabrir deveria ocultar o ranking: ' || v_txt;
  v_n := v_n + 1;

  -- desfazer crédito (Ana desfaz a doação antes): volta ao saldo sem crédito
  set local role authenticated;
  perform public.fn_admin_desfazer_doacao((select id from public.transferencia where origem = 'participante'));
  perform public.fn_admin_desfazer_doacao(t1);
  reset role;
  select format('%s/%s', s.credito, s.saldo) into v_txt from public.fn_saldos() s where s.pessoa_id = ana;
  assert v_txt = '0.00/0.00', 'FALHOU: desfazer crédito: ' || v_txt;
  v_n := v_n + 1;

  -- novo evento: ranking oculto e créditos apagados
  set local role authenticated;
  perform public.fn_admin_encerrar();
  perform public.fn_admin_exibir_ranking(true);
  perform public.fn_admin_novo_evento('Outra gincana', true, true);
  reset role;
  select format('%s/%s/%s', aberto::text, ranking_visivel::text, (select count(*) from public.transferencia)) into v_txt from public.evento;
  assert v_txt = 'true/false/0', 'FALHOU: novo evento: período aberto, ranking oculto, sem créditos: ' || v_txt;
  perform set_config('request.jwt.claims', '{}', true);
  v_n := v_n + 1;

  raise exception 'TESTES OK (ranking oculto e crédito): % verificações passaram. (Esta mensagem aparece como erro de propósito: assim tudo o que o teste gravou é desfeito.)', v_n
    using errcode = 'P0001';
end
$teste$;
