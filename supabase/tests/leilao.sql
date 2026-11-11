-- =====================================================================
-- Testes: leilão de caixas surpresa (saldo, arremate e privacidade)
-- =====================================================================
-- Como rodar: depois da migração 5, cole este arquivo inteiro no SQL
-- Editor do Supabase e clique em Run.
--
-- Como o privacidade.sql, é um único DO que TERMINA SEMPRE COM ERRO, de
-- propósito, para o Postgres desfazer tudo. Nada fica gravado.
--
--   ✅ Passou:  ERROR: TESTES OK (leilão): N verificações passaram ...
--   ❌ Falhou:  ERROR: FALHOU: <o que deu errado>
--
-- Valores "marcadores": ganhos 271.13 / 162.29 / 90.31, arremates 37.19 /
-- 48.23 e conteúdos SEGREDO-A1 / SEGREDO-B2 / SEGREDO-C3. Para cada
-- participante o teste procura no texto de tudo o que as funções devolvem
-- qualquer marcador que não seja dele.
-- =====================================================================
do $teste$
declare
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
  v_vaz    text[];
  v_r      jsonb;
  v_painel jsonb;
  v_leilao jsonb;
  v_tok    text;
  v_p      record;
  v_senhas jsonb;

  ana uuid; bruno uuid; carla uuid;
  j1 uuid;
  c1 uuid; c2 uuid; c3 uuid; c4 uuid;
begin
  -- -------------------------------------------------------------------
  -- 0. Banco zerado (desfeito no fim) + admin de teste
  -- -------------------------------------------------------------------
  update public.evento set aberto = true, encerrado_em = null where id = 1;
  delete from public.transferencia;                       -- migração 6
  update public.caixa set pessoa_id = null, valor = null, vendido_em = null;
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
  -- 1. Admin monta a gincana: Ana 1º, Bruno 2º, Carla 3º
  -- -------------------------------------------------------------------
  perform set_config('request.jwt.claims', v_admin_claims, true);
  set local role authenticated;

  insert into public.pessoa (nome) values ('Ana')   returning id into ana;
  insert into public.pessoa (nome) values ('Bruno') returning id into bruno;
  insert into public.pessoa (nome) values ('Carla') returning id into carla;
  v_senhas := jsonb_build_object(ana, '5101', bruno, '5102', carla, '5103');
  for v_p in select key as id, value #>> '{}' as senha from jsonb_each(v_senhas) loop
    perform public.fn_admin_definir_senha(v_p.id::uuid, v_p.senha);
  end loop;

  insert into public.jogo (nome, modo, formato) values ('Corrida do Caldeirão', 'individual', 'colocacao')
  returning id into j1;
  insert into public.participacao (jogo_id, pessoa_id) values (j1, ana), (j1, bruno), (j1, carla);
  perform public.fn_admin_registrar_resultado(j1, jsonb_build_array(
    jsonb_build_object('pessoa_id', ana,   'colocacao', 1, 'premio', 271.13),
    jsonb_build_object('pessoa_id', bruno, 'colocacao', 2, 'premio', 162.29),
    jsonb_build_object('pessoa_id', carla, 'colocacao', 3, 'premio', 90.31)));

  -- -------------------------------------------------------------------
  -- 2. Caixas em lote, numeradas em sequência
  -- -------------------------------------------------------------------
  assert public.fn_admin_adicionar_caixas(3) = 3, 'FALHOU: deveria criar 3 caixas';
  assert public.fn_admin_adicionar_caixas(1) = 1, 'FALHOU: deveria criar 1 caixa';
  select string_agg(numero::text, ',' order by numero) into v_txt from public.caixa;
  assert v_txt = '1,2,3,4', 'FALHOU: numeração deveria ser 1,2,3,4, veio ' || coalesce(v_txt, '∅');
  v_n := v_n + 3;

  select id into c1 from public.caixa where numero = 1;
  select id into c2 from public.caixa where numero = 2;
  select id into c3 from public.caixa where numero = 3;
  select id into c4 from public.caixa where numero = 4;

  foreach v_fn in array array['public.fn_admin_adicionar_caixas(0)', 'public.fn_admin_adicionar_caixas(51)'] loop
    v_estado := null;
    begin
      execute 'select ' || v_fn;
    exception when others then v_estado := sqlstate;
    end;
    assert v_estado = '22023', 'FALHOU: deveria recusar ' || v_fn;
    v_n := v_n + 1;
  end loop;

  -- conteúdo: o admin edita direto
  update public.caixa set conteudo = 'SEGREDO-A1' where id = c1;
  update public.caixa set conteudo = 'SEGREDO-B2' where id = c2;
  update public.caixa set conteudo = 'SEGREDO-C3' where id = c3;
  select count(*) into v_cnt from public.caixa where conteudo like 'SEGREDO-%';
  assert v_cnt = 3, 'FALHOU: admin deveria conseguir salvar o conteúdo';
  v_n := v_n + 1;

  -- ... mas não vende nem cria caixa por fora das funções
  v_estado := null;
  begin
    update public.caixa set pessoa_id = ana, valor = 1, vendido_em = now() where id = c4;
  exception when others then v_estado := sqlstate;
  end;
  assert v_estado = '42501', 'FALHOU: admin conseguiu vender caixa sem a função (update direto)';
  v_estado := null;
  begin
    insert into public.caixa (numero) values (99);
  exception when others then v_estado := sqlstate;
  end;
  assert v_estado = '42501', 'FALHOU: admin conseguiu inserir caixa direto';
  v_n := v_n + 2;

  -- -------------------------------------------------------------------
  -- 3. Evento aberto: arremate recusado
  -- -------------------------------------------------------------------
  v_msg := null;
  begin
    perform public.fn_admin_arrematar(c1, ana, 10);
  exception when others then v_msg := sqlerrm;
  end;
  assert v_msg like '%período de jogos encerrado%', 'FALHOU: arremate com evento aberto deveria ser recusado: ' || coalesce(v_msg, 'passou');
  v_n := v_n + 1;

  perform public.fn_admin_encerrar();

  -- -------------------------------------------------------------------
  -- 4. Arremates com o evento encerrado
  -- -------------------------------------------------------------------
  -- acima do saldo (271.13) por 1 centavo
  v_msg := null;
  begin
    perform public.fn_admin_arrematar(c1, ana, 271.14);
  exception when others then v_msg := sqlerrm;
  end;
  assert v_msg like 'Saldo insuficiente: Ana tem R$ 271,13%', 'FALHOU: deveria recusar valor acima do saldo: ' || coalesce(v_msg, 'passou');
  v_n := v_n + 1;

  foreach v_fn in array array['0', '-5', '1.234', 'null'] loop
    v_estado := null;
    begin
      execute format('select public.fn_admin_arrematar(%L, %L, %s)', c1, ana, v_fn);
    exception when others then v_estado := sqlstate;
    end;
    assert v_estado = '22023', 'FALHOU: deveria recusar o valor ' || v_fn;
    v_n := v_n + 1;
  end loop;

  v_r := public.fn_admin_arrematar(c1, ana, 37.19);
  assert (v_r->>'saldo_antes')::numeric = 271.13 and (v_r->>'saldo_depois')::numeric = 233.94,
    'FALHOU: saldo antes/depois errado: ' || v_r::text;
  v_n := v_n + 1;

  v_msg := null;
  begin
    perform public.fn_admin_arrematar(c1, bruno, 1);
  exception when others then v_msg := sqlerrm;
  end;
  assert v_msg = 'Essa caixa já foi vendida.', 'FALHOU: caixa vendida foi vendida de novo: ' || coalesce(v_msg, 'passou');
  v_n := v_n + 1;

  perform public.fn_admin_arrematar(c2, bruno, 48.23);

  -- saldo exato passa; depois disso, nem 1 centavo
  perform public.fn_admin_arrematar(c4, carla, 90.31);
  v_msg := null;
  begin
    perform public.fn_admin_arrematar(c3, carla, 0.01);
  exception when others then v_msg := sqlerrm;
  end;
  assert v_msg like 'Saldo insuficiente: Carla tem R$ 0,00%', 'FALHOU: saldo zerado deveria recusar: ' || coalesce(v_msg, 'passou');
  v_n := v_n + 1;

  -- desfazer devolve o saldo
  perform public.fn_admin_desfazer_venda(c4);
  select count(*) into v_cnt from public.caixa where id = c4 and pessoa_id is null and valor is null and vendido_em is null;
  assert v_cnt = 1, 'FALHOU: desfazer a venda deveria liberar a caixa';
  v_n := v_n + 1;

  -- caixa vendida não pode ser excluída
  v_msg := null;
  begin
    delete from public.caixa where id = c1;
  exception when others then v_msg := sqlerrm;
  end;
  assert v_msg = 'Desfaça a venda antes de excluir a caixa.', 'FALHOU: caixa vendida foi excluída';
  v_n := v_n + 1;

  reset role;
  perform set_config('request.jwt.claims', '{}', true);

  -- Saldos esperados: Ana 271.13−37.19 = 233.94 · Bruno 162.29−48.23 = 114.06 · Carla 90.31
  select string_agg(format('%s:%s/%s/%s', p.nome, s.ganho, s.gasto, s.saldo), ' ' order by p.nome) into v_txt
    from public.fn_saldos() s join public.pessoa p on p.id = s.pessoa_id;
  assert v_txt = 'Ana:271.13/37.19/233.94 Bruno:162.29/48.23/114.06 Carla:90.31/0.00/90.31',
    'FALHOU: saldos errados: ' || v_txt;
  v_n := v_n + 1;

  -- -------------------------------------------------------------------
  -- 5. anon e usuário que não é o admin
  -- -------------------------------------------------------------------
  v_estado := null;
  begin
    set local role anon;
    perform 1 from public.caixa limit 1;
  exception when others then v_estado := sqlstate;
  end;
  reset role;
  assert v_estado = '42501', 'FALHOU: anon conseguiu ler a tabela caixa';
  v_n := v_n + 1;

  foreach v_fn in array array[
      'public.fn_saldos()', 'public.fn_arremates_json(null)',
      'public.fn_admin_adicionar_caixas(1)', 'public.fn_admin_arrematar(null, null, 1)',
      'public.fn_admin_desfazer_venda(null)'] loop
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
  set local role authenticated;
  select count(*) into v_cnt from public.caixa;
  assert v_cnt = 0, 'FALHOU: não-admin leu caixas';
  v_estado := null;
  begin
    perform public.fn_admin_arrematar(c3, carla, 1);
  exception when others then v_estado := sqlstate;
  end;
  assert v_estado = '42501', 'FALHOU: não-admin conseguiu arrematar';
  v_estado := null;
  begin
    perform public.fn_admin_desfazer_venda(c1);
  exception when others then v_estado := sqlstate;
  end;
  assert v_estado = '42501', 'FALHOU: não-admin conseguiu desfazer venda';
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  v_n := v_n + 3;

  -- sem token válido, nada
  v_msg := null;
  begin
    set local role anon;
    perform public.fn_leilao('token-falso');
  exception when others then v_msg := sqlerrm;
  end;
  reset role;
  assert v_msg = 'Sessão inválida', 'FALHOU: fn_leilao aceitou token falso';
  v_n := v_n + 1;

  -- -------------------------------------------------------------------
  -- 6. PRIVACIDADE — para cada participante (evento encerrado)
  -- -------------------------------------------------------------------
  for v_p in select p.id, p.nome from public.pessoa p order by p.nome loop
    set local role anon;
    v_tok    := public.fn_entrar(v_p.id, v_senhas->>(v_p.id::text))->>'token';
    v_painel := public.fn_meu_painel(v_tok);
    v_leilao := public.fn_leilao(v_tok);
    v_txt    := v_painel::text || v_leilao::text
             || public.fn_meus_jogos(v_tok)::text || public.fn_ranking(v_tok)::text
             || public.fn_resultado_final(v_tok)::text;
    reset role;
    assert v_tok is not null, 'FALHOU: login de ' || v_p.nome;

    -- (a) nada de dinheiro nem conteúdo que não seja dele
    with meus as (
      select s.ganho::text v from public.fn_saldos() s where s.pessoa_id = v_p.id
      union select s.gasto::text from public.fn_saldos() s where s.pessoa_id = v_p.id
      union select s.saldo::text from public.fn_saldos() s where s.pessoa_id = v_p.id
      union select c.valor::text from public.caixa c where c.pessoa_id = v_p.id
      union select c.conteudo from public.caixa c where c.pessoa_id = v_p.id
    ), alheios as (
      select s.ganho::text v from public.fn_saldos() s where s.pessoa_id <> v_p.id
      union select s.gasto::text from public.fn_saldos() s where s.pessoa_id <> v_p.id
      union select s.saldo::text from public.fn_saldos() s where s.pessoa_id <> v_p.id
      union select c.valor::text from public.caixa c where c.pessoa_id is distinct from v_p.id
      union select c.conteudo from public.caixa c where c.pessoa_id is distinct from v_p.id
    )
    select array_agg(a.v) into v_vaz
      from alheios a
     where a.v is not null and a.v not in ('', '0.00')
       and a.v not in (select v from meus where v is not null)
       and position(a.v in v_txt) > 0;
    assert v_vaz is null, format('FALHOU: %s recebeu dado do leilão de outra pessoa: %s', v_p.nome, v_vaz);

    -- (b) o próprio dinheiro vem certo
    select format('%s/%s/%s', s.ganho, s.gasto, s.saldo) into v_msg from public.fn_saldos() s where s.pessoa_id = v_p.id;
    assert format('%s/%s/%s', v_painel->>'ganho', v_painel->>'gasto', v_painel->>'saldo') = v_msg,
      format('FALHOU: dinheiro de %s deveria ser %s', v_p.nome, v_msg);

    -- (c) caixas: todas aparecem; dos outros, só número e "vendida"
    assert jsonb_array_length(v_leilao->'caixas') = 4, 'FALHOU: participante deveria ver as 4 caixas';
    select count(*) into v_cnt
      from jsonb_array_elements(v_leilao->'caixas') x
     where not (x->>'minha')::boolean
       and (x ? 'conteudo' or x ? 'valor' or x ? 'vendido_em' or x ? 'pessoa_id' or x ? 'nome');
    assert v_cnt = 0, format('FALHOU: %s viu detalhes de caixa que não é dele', v_p.nome);
    select count(*) into v_cnt
      from jsonb_array_elements(v_leilao->'caixas') x
      join public.caixa c on c.numero = (x->>'numero')::integer
     where (x->>'vendida')::boolean <> (c.pessoa_id is not null)
        or (x->>'minha')::boolean <> (c.pessoa_id is not distinct from v_p.id)
        or ((x->>'minha')::boolean and (x->>'conteudo' is distinct from c.conteudo
                                        or (x->>'valor')::numeric is distinct from c.valor));
    assert v_cnt = 0, format('FALHOU: caixas de %s com vendida/minha/conteúdo errados', v_p.nome);

    -- (d) "Como gastei": só as minhas
    select count(*) into v_cnt from public.caixa c where c.pessoa_id = v_p.id;
    assert jsonb_array_length(v_painel->'arremates') = v_cnt, format('FALHOU: arremates de %s', v_p.nome);
    v_n := v_n + 5;
  end loop;

  -- Ana vê o conteúdo da caixa dela
  set local role anon;
  v_tok := public.fn_entrar(ana, '5101')->>'token';
  v_painel := public.fn_meu_painel(v_tok);
  reset role;
  assert v_painel->'arremates'->0->>'conteudo' = 'SEGREDO-A1'
     and (v_painel->'arremates'->0->>'valor')::numeric = 37.19,
    'FALHOU: Ana deveria ver a própria caixa com conteúdo e valor';
  v_n := v_n + 1;

  -- -------------------------------------------------------------------
  -- 7. Evento reaberto: leilão some para o participante; excluir pessoa
  --    devolve as caixas dela
  -- -------------------------------------------------------------------
  perform set_config('request.jwt.claims', v_admin_claims, true);
  set local role authenticated;
  perform public.fn_admin_reabrir();
  reset role;
  perform set_config('request.jwt.claims', '{}', true);

  v_msg := null;
  begin
    set local role anon;
    perform public.fn_leilao(v_tok);
  exception when others then v_msg := sqlerrm;
  end;
  reset role;
  assert v_msg like 'O leilão aparece quando o período de jogos for encerrado.%', 'FALHOU: leilão visível com evento aberto';
  set local role anon;
  v_painel := public.fn_meu_painel(v_tok);
  reset role;
  assert (v_painel->>'saldo')::numeric = 233.94, 'FALHOU: painel aberto deveria manter o saldo da Ana';
  v_n := v_n + 2;

  perform set_config('request.jwt.claims', v_admin_claims, true);
  set local role authenticated;
  delete from public.pessoa where id = ana;
  delete from public.caixa where id = c3;       -- não vendida: pode excluir
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  select count(*) into v_cnt from public.caixa where id = c1 and pessoa_id is null and valor is null;
  assert v_cnt = 1, 'FALHOU: excluir a pessoa deveria devolver a caixa dela ao leilão';
  select count(*) into v_cnt from public.caixa;
  assert v_cnt = 3, 'FALHOU: caixa não vendida deveria ter sido excluída';
  v_n := v_n + 2;

  raise exception 'TESTES OK (leilão): % verificações passaram. (Esta mensagem aparece como erro de propósito: assim tudo o que o teste gravou é desfeito.)', v_n
    using errcode = 'P0001';
end
$teste$;
