-- =====================================================================
-- Testes: partidas, doações entre participantes e novo evento
-- =====================================================================
-- Como rodar: depois da migração 6, cole este arquivo inteiro no SQL
-- Editor do Supabase e clique em Run.
--
-- Como os outros testes, é um único DO que TERMINA SEMPRE COM ERRO, de
-- propósito, para o Postgres desfazer tudo. Nada fica gravado.
--
--   ✅ Passou:  ERROR: TESTES OK (doações e partidas): N verificações passaram ...
--   ❌ Falhou:  ERROR: FALHOU: <o que deu errado>
--
-- Valores "marcadores": ganhos 271.13 / 162.29 / 90.31, doações 41.17 e
-- 13.07, recados RECADO-X1 / RECADO-Y2. Para cada participante o teste
-- procura no texto de tudo o que as funções devolvem qualquer valor de
-- dinheiro que não seja dele.
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
  v_tokb   text;
  v_tokc   text;
  v_p      record;
  v_senhas jsonb;

  g1 uuid; g2 uuid;
  ana uuid; bruno uuid; carla uuid;
  j1 uuid; j1b uuid; j1c uuid; j2 uuid; j2b uuid; j3 uuid;
  c1 uuid;
  t1 uuid; t2 uuid;
begin
  -- -------------------------------------------------------------------
  -- 0. Banco zerado (desfeito no fim) + admin de teste
  -- -------------------------------------------------------------------
  update public.evento set aberto = true, encerrado_em = null where id = 1;
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
  insert into public.admin (user_id)
  values ((v_admin_claims::jsonb->>'sub')::uuid) on conflict do nothing;

  perform set_config('request.jwt.claims', v_admin_claims, true);
  set local role authenticated;

  insert into public.grupo (nome) values ('Bruxas')   returning id into g1;
  insert into public.grupo (nome) values ('Vampiros') returning id into g2;
  insert into public.pessoa (nome, grupo_id) values ('Ana', g1)   returning id into ana;
  insert into public.pessoa (nome, grupo_id) values ('Bruno', g1) returning id into bruno;
  insert into public.pessoa (nome, grupo_id) values ('Carla', g2) returning id into carla;
  v_senhas := jsonb_build_object(ana, '6101', bruno, '6102', carla, '6103');
  for v_p in select key as id, value #>> '{}' as senha from jsonb_each(v_senhas) loop
    perform public.fn_admin_definir_senha(v_p.id::uuid, v_p.senha);
  end loop;

  -- -------------------------------------------------------------------
  -- 1. Partidas
  -- -------------------------------------------------------------------
  insert into public.jogo (nome, tipo, modo, formato, pontos, premio)
  values ('Quiz do Terror', 'Jogo', 'individual', 'vitoria', 5, 200) returning id into j1;
  insert into public.participacao (jogo_id, pessoa_id) values (j1, ana), (j1, bruno), (j1, carla);
  perform public.fn_admin_registrar_resultado(j1, jsonb_build_array(
    jsonb_build_object('pessoa_id', ana, 'premio', 200)));

  select count(*) into v_cnt from public.jogo where id = j1 and serie_id = j1 and numero_partida = 1;
  assert v_cnt = 1, 'FALHOU: jogo novo deveria começar a própria série (partida 1)';
  v_n := v_n + 1;

  j1b := public.fn_admin_nova_partida(j1);
  select count(*) into v_cnt from public.jogo j
   where j.id = j1b and j.serie_id = j1 and j.numero_partida = 2 and j.nome = 'Quiz do Terror'
     and j.tipo = 'Jogo' and j.modo = 'individual' and j.formato = 'vitoria'
     and j.pontos = 5 and j.premio = 200 and j.pontuado_em is null;
  assert v_cnt = 1, 'FALHOU: nova partida deveria copiar o jogo, zerada, como partida 2';
  select count(*) into v_cnt from public.participacao where jogo_id = j1b;
  assert v_cnt = 0, 'FALHOU: nova partida deveria começar sem participantes';
  select count(*) into v_cnt from public.resultado where jogo_id = j1b;
  assert v_cnt = 0, 'FALHOU: nova partida deveria começar sem resultado';
  select count(*) into v_cnt from public.resultado where jogo_id = j1;
  assert v_cnt = 1, 'FALHOU: a partida anterior deveria manter o resultado';
  v_n := v_n + 4;

  -- partida 2: Ana vence de novo (cada partida conta separado)
  insert into public.participacao (jogo_id, pessoa_id) values (j1b, ana), (j1b, bruno);
  perform public.fn_admin_registrar_resultado(j1b, jsonb_build_array(
    jsonb_build_object('pessoa_id', ana, 'premio', 71.13)));
  reset role;
  select vitorias into v_cnt from public.fn_estatisticas() where pessoa_id = ana;
  set local role authenticated;
  assert v_cnt = 2, 'FALHOU: cada partida deveria contar no ranking (Ana 2 vitórias), veio ' || v_cnt;
  v_n := v_n + 1;

  -- nova partida a partir de uma antiga continua a numeração
  j1c := public.fn_admin_nova_partida(j1);
  select numero_partida into v_cnt from public.jogo where id = j1c;
  assert v_cnt = 3, 'FALHOU: terceira partida deveria ser a de número 3';
  delete from public.jogo where id = j1c;
  v_n := v_n + 1;

  -- por grupo: mantém os grupos escolhidos
  insert into public.jogo (nome, tipo, modo, formato, pontos, premio, grupo_pontua)
  values ('Caça às Abóboras', 'Gincana', 'grupo', 'vitoria', 10, 0, true) returning id into j2;
  insert into public.jogo_grupo (jogo_id, grupo_id) values (j2, g2);
  j2b := public.fn_admin_nova_partida(j2);
  select string_agg(grupo_id::text, ',') into v_txt from public.jogo_grupo where jogo_id = j2b;
  assert v_txt = g2::text, 'FALHOU: nova partida por grupo deveria manter os grupos escolhidos';
  assert (select grupo_pontua from public.jogo where id = j2b), 'FALHOU: nova partida deveria copiar "marcar pontos e dinheiro"';
  v_n := v_n + 1;

  -- renomear uma partida renomeia a série inteira (e só ela)
  insert into public.jogo (nome) values ('Morder a Maçã') returning id into j3;
  update public.jogo set nome = 'Quiz Assombrado', tipo = 'Gincana' where id = j1b;
  select count(*) into v_cnt from public.jogo
   where serie_id = j1 and nome = 'Quiz Assombrado' and tipo = 'Gincana';
  assert v_cnt = 2, 'FALHOU: renomear uma partida deveria renomear todas da série';
  select count(*) into v_cnt from public.jogo where id = j3 and nome = 'Morder a Maçã';
  assert v_cnt = 1, 'FALHOU: renomear não pode mexer em outra série';
  v_n := v_n + 2;

  -- série só pela função
  v_estado := null;
  begin
    insert into public.jogo (nome, serie_id, numero_partida) values ('invasor', j1, 9);
  exception when others then v_estado := sqlstate;
  end;
  assert v_estado = '42501', 'FALHOU: admin conseguiu gravar serie_id direto';
  v_estado := null;
  begin
    update public.jogo set numero_partida = 7 where id = j1;
  exception when others then v_estado := sqlstate;
  end;
  assert v_estado = '42501', 'FALHOU: admin conseguiu mudar numero_partida direto';
  v_n := v_n + 2;

  -- participante vê "partida" só quando a série tem mais de uma
  insert into public.participacao (jogo_id, pessoa_id) values (j3, bruno);
  perform public.fn_admin_registrar_resultado(j3, jsonb_build_array(
    jsonb_build_object('pessoa_id', bruno, 'premio', 162.29)));
  -- Carla ganha 90.31 na gincana por grupo (partida 1)
  perform public.fn_admin_registrar_resultado(j2, jsonb_build_array(
    jsonb_build_object('grupo_id', g2, 'premio', 90.31)));
  reset role;
  perform set_config('request.jwt.claims', '{}', true);

  set local role anon;
  v_tok := public.fn_entrar(ana, '6101')->>'token';
  v_r := public.fn_meus_jogos(v_tok);
  reset role;
  select string_agg(format('%s#%s', e->>'nome', coalesce(e->>'partida', '-')), ',' order by e->>'partida')
    into v_txt from jsonb_array_elements(v_r) e;
  assert v_txt = 'Quiz Assombrado#1,Quiz Assombrado#2', 'FALHOU: meus jogos com número da partida: ' || coalesce(v_txt, '∅');
  set local role anon;
  v_tokb := public.fn_entrar(bruno, '6102')->>'token';
  v_r := public.fn_meus_jogos(v_tokb);
  reset role;
  select e->'partida' into v_r from jsonb_array_elements(v_r) e where e->>'nome' = 'Morder a Maçã';
  assert v_r = 'null'::jsonb, 'FALHOU: jogo com uma partida só não mostra número';
  v_n := v_n + 2;

  -- Ganhos: Ana 200 + 71.13 = 271.13 · Bruno 162.29 · Carla 90.31

  -- -------------------------------------------------------------------
  -- 2. Doações com o período de jogos ABERTO: aceitas (apostas)
  -- -------------------------------------------------------------------
  set local role anon;
  v_r := public.fn_doar(v_tok, bruno, 5, 'APOSTA-A1');
  reset role;
  assert (v_r->>'saldo_antes')::numeric = 271.13 and (v_r->>'saldo_depois')::numeric = 266.13,
    'FALHOU: doação com período aberto deveria passar (271.13 → 266.13): ' || v_r::text;
  select format('%s/%s/%s', t.origem, t.valor, t.motivo) into v_txt
    from public.transferencia t where t.de_pessoa_id = ana and t.para_pessoa_id = bruno;
  assert v_txt = 'participante/5.00/APOSTA-A1', 'FALHOU: doação aberta gravada errado: ' || coalesce(v_txt, 'nada');
  -- saldo continua conferido com os jogos abertos
  v_msg := null;
  begin
    set local role anon;
    perform public.fn_doar(v_tok, bruno, 266.14, '');
  exception when others then v_msg := sqlerrm;
  end;
  reset role;
  assert v_msg = 'Saldo insuficiente: você tem R$ 266,13.', 'FALHOU: saldo com período aberto: ' || coalesce(v_msg, 'passou');
  -- quem recebeu vê com os jogos abertos
  set local role anon;
  v_painel := public.fn_meu_painel(v_tokb);
  reset role;
  assert (v_painel->>'recebido')::numeric = 5 and (v_painel->>'saldo')::numeric = 167.29,
    'FALHOU: Bruno deveria ver a doação recebida com os jogos abertos (saldo 162.29 + 5)';
  v_n := v_n + 3;

  -- admin desfaz (Bruno ainda tem o valor): o resto do teste segue com os saldos de antes
  perform set_config('request.jwt.claims', v_admin_claims, true);
  set local role authenticated;
  perform public.fn_admin_desfazer_doacao((select t.id from public.transferencia t where t.motivo = 'APOSTA-A1'));
  reset role;
  select count(*) into v_cnt from public.transferencia;
  assert v_cnt = 0, 'FALHOU: desfazer doação feita com os jogos abertos';
  v_n := v_n + 1;

  perform set_config('request.jwt.claims', v_admin_claims, true);
  set local role authenticated;
  perform public.fn_admin_encerrar();
  -- período encerrado: nova partida recusada
  v_msg := null;
  begin
    perform public.fn_admin_nova_partida(j1);
  exception when others then v_msg := sqlerrm;
  end;
  assert v_msg like 'O período de jogos está encerrado%', 'FALHOU: nova partida com período encerrado: ' || coalesce(v_msg, 'passou');
  v_n := v_n + 1;
  reset role;
  perform set_config('request.jwt.claims', '{}', true);

  -- -------------------------------------------------------------------
  -- 3. Doações com o período ENCERRADO
  -- -------------------------------------------------------------------
  set local role anon;
  v_r := public.fn_doar(v_tok, bruno, 41.17, '  RECADO-X1  ');
  reset role;
  assert (v_r->>'saldo_antes')::numeric = 271.13 and (v_r->>'saldo_depois')::numeric = 229.96,
    'FALHOU: saldo antes/depois da doação: ' || v_r::text;
  select id into t1 from public.transferencia where de_pessoa_id = ana;
  select count(*) into v_cnt from public.transferencia
   where id = t1 and para_pessoa_id = bruno and valor = 41.17 and motivo = 'RECADO-X1';
  assert v_cnt = 1, 'FALHOU: doação gravada com quem doou = pessoa do token';
  v_n := v_n + 2;

  -- regras
  foreach v_fn in array array[
      format('%L, %L, 1, %L', v_tok, ana, ''),           -- para si mesma
      format('%L, null, 1, %L', v_tok, ''),
      format('%L, %L, 1, %L', v_tok, gen_random_uuid(), ''),
      format('%L, %L, 0, %L', v_tok, bruno, ''),
      format('%L, %L, -1, %L', v_tok, bruno, ''),
      format('%L, %L, 1.234, %L', v_tok, bruno, ''),
      format('%L, %L, null, %L', v_tok, bruno, ''),
      format('%L, %L, 1, %L', v_tok, bruno, repeat('x', 61))] loop
    v_estado := null;
    begin
      set local role anon;
      execute 'select public.fn_doar(' || v_fn || ')';
    exception when others then v_estado := sqlstate;
    end;
    reset role;
    assert v_estado = '22023', 'FALHOU: doação deveria ser recusada: ' || v_fn;
    v_n := v_n + 1;
  end loop;

  v_msg := null;
  begin
    set local role anon;
    perform public.fn_doar(v_tok, bruno, 229.97, '');
  exception when others then v_msg := sqlerrm;
  end;
  reset role;
  assert v_msg = 'Saldo insuficiente: você tem R$ 229,96.', 'FALHOU: doação acima do saldo: ' || coalesce(v_msg, 'passou');
  v_msg := null;
  begin
    set local role anon;
    perform public.fn_doar('token-falso', bruno, 1, '');
  exception when others then v_msg := sqlerrm;
  end;
  reset role;
  assert v_msg = 'Sessão inválida', 'FALHOU: fn_doar aceitou token falso';
  v_n := v_n + 2;

  set local role anon;
  perform public.fn_doar(v_tokb, carla, 13.07, 'RECADO-Y2');
  reset role;
  select id into t2 from public.transferencia where de_pessoa_id = bruno;

  -- Saldos: Ana 271.13 − 41.17 = 229.96 · Bruno 162.29 + 41.17 − 13.07 = 190.39 · Carla 90.31 + 13.07 = 103.38
  select string_agg(format('%s:%s/%s/%s/%s/%s', p.nome, s.ganho, s.recebido, s.doado, s.gasto, s.saldo), ' ' order by p.nome)
    into v_txt from public.fn_saldos() s join public.pessoa p on p.id = s.pessoa_id;
  assert v_txt = 'Ana:271.13/0.00/41.17/0.00/229.96 Bruno:162.29/41.17/13.07/0.00/190.39 Carla:90.31/13.07/0.00/0.00/103.38',
    'FALHOU: saldos com doações: ' || v_txt;
  -- só dinheiro: pontos e vitórias não mudam
  select string_agg(format('%s:%s/%s', p.nome, s.pontos, s.vitorias), ' ' order by p.nome)
    into v_txt from public.fn_estatisticas() s join public.pessoa p on p.id = s.pessoa_id;
  assert v_txt = 'Ana:10/2 Bruno:10/1 Carla:10/1', 'FALHOU: doação não pode mudar pontos/vitórias: ' || v_txt;
  v_n := v_n + 2;

  -- arremate usa o saldo com doações; doação usada não pode ser desfeita
  perform set_config('request.jwt.claims', v_admin_claims, true);
  set local role authenticated;
  perform public.fn_admin_adicionar_caixas(2);
  select id into c1 from public.caixa where numero = 1;
  perform public.fn_admin_arrematar(c1, carla, 103.38);
  v_msg := null;
  begin
    perform public.fn_admin_desfazer_doacao(t2);
  exception when others then v_msg := sqlerrm;
  end;
  assert v_msg = 'Carla já usou parte desse valor. Desfaça antes o arremate ou a doação que usou o dinheiro.',
    'FALHOU: desfazer doação já gasta: ' || coalesce(v_msg, 'passou');
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  v_msg := null;
  begin
    set local role anon;
    v_tokc := public.fn_entrar(carla, '6103')->>'token';
    perform public.fn_doar(v_tokc, ana, 0.01, '');
  exception when others then v_msg := sqlerrm;
  end;
  reset role;
  assert v_msg = 'Saldo insuficiente: você tem R$ 0,00.', 'FALHOU: doação com saldo zerado: ' || coalesce(v_msg, 'passou');
  v_n := v_n + 2;

  -- admin: lê todas as doações, mas não grava direto
  perform set_config('request.jwt.claims', v_admin_claims, true);
  set local role authenticated;
  select count(*) into v_cnt from public.transferencia;
  assert v_cnt = 2, 'FALHOU: admin deveria ver as 2 doações';
  v_estado := null;
  begin
    insert into public.transferencia (de_pessoa_id, para_pessoa_id, valor) values (ana, carla, 1);
  exception when others then v_estado := sqlstate;
  end;
  assert v_estado = '42501', 'FALHOU: admin conseguiu inserir doação direto';
  v_estado := null;
  begin
    delete from public.transferencia where id = t1;
  exception when others then v_estado := sqlstate;
  end;
  assert v_estado = '42501', 'FALHOU: admin conseguiu apagar doação direto';
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  v_n := v_n + 3;

  -- -------------------------------------------------------------------
  -- 4. anon e usuário que não é o admin
  -- -------------------------------------------------------------------
  v_estado := null;
  begin
    set local role anon;
    perform 1 from public.transferencia limit 1;
  exception when others then v_estado := sqlstate;
  end;
  reset role;
  assert v_estado = '42501', 'FALHOU: anon conseguiu ler a tabela transferencia';
  v_n := v_n + 1;

  foreach v_fn in array array[
      'public.fn_saldos()', 'public.fn_doacoes_json(null)', 'public.fn_partida(null)',
      'public.fn_admin_nova_partida(null)', 'public.fn_admin_desfazer_doacao(null)',
      'public.fn_admin_novo_evento(''x'', true, true)'] loop
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
  select count(*) into v_cnt from public.transferencia;
  assert v_cnt = 0, 'FALHOU: não-admin leu doações';
  foreach v_fn in array array[
      format('public.fn_admin_desfazer_doacao(%L)', t1), format('public.fn_admin_nova_partida(%L)', j1),
      'public.fn_admin_novo_evento(''x'', true, true)'] loop
    v_estado := null;
    begin
      execute 'select ' || v_fn;
    exception when others then v_estado := sqlstate;
    end;
    assert v_estado = '42501', format('FALHOU: não-admin conseguiu executar %s', v_fn);
    v_n := v_n + 1;
  end loop;
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  v_n := v_n + 1;

  -- -------------------------------------------------------------------
  -- 5. PRIVACIDADE — para cada participante
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
    -- horários não contam (os segundos "13.07…" poderiam parecer valor)
    v_txt := regexp_replace(v_txt, '[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?', 'HH', 'g');

    -- (a) nenhum valor de dinheiro de outra pessoa nem doação de que não participou
    with meus as (
      select x.v from public.fn_saldos() s,
             lateral (values (s.ganho::text), (s.recebido::text), (s.doado::text),
                             (s.gasto::text), (s.saldo::text)) x(v)
       where s.pessoa_id = v_p.id
      union select t.valor::text from public.transferencia t where v_p.id in (t.de_pessoa_id, t.para_pessoa_id)
      union select t.motivo from public.transferencia t where v_p.id in (t.de_pessoa_id, t.para_pessoa_id)
      union select c.valor::text from public.caixa c where c.pessoa_id = v_p.id
      union select r.premio::text from public.resultado r where r.pessoa_id = v_p.id
    ), alheios as (
      select x.v from public.fn_saldos() s,
             lateral (values (s.ganho::text), (s.recebido::text), (s.doado::text),
                             (s.gasto::text), (s.saldo::text)) x(v)
       where s.pessoa_id <> v_p.id
      union select t.valor::text from public.transferencia t where v_p.id not in (t.de_pessoa_id, t.para_pessoa_id)
      union select t.motivo from public.transferencia t where v_p.id not in (t.de_pessoa_id, t.para_pessoa_id)
      union select c.valor::text from public.caixa c where c.pessoa_id is distinct from v_p.id
    )
    select array_agg(a.v) into v_vaz
      from alheios a
     where a.v is not null and a.v not in ('', '0.00')
       and a.v not in (select v from meus where v is not null)
       and position(a.v in v_txt) > 0;
    assert v_vaz is null, format('FALHOU: %s recebeu dinheiro/doação de outra pessoa: %s', v_p.nome, v_vaz);

    -- (b) o próprio dinheiro vem certo
    select format('%s/%s/%s/%s/%s', s.ganho, s.recebido, s.doado, s.gasto, s.saldo) into v_msg
      from public.fn_saldos() s where s.pessoa_id = v_p.id;
    assert format('%s/%s/%s/%s/%s', v_painel->>'ganho', v_painel->>'recebido', v_painel->>'doado',
                  v_painel->>'gasto', v_painel->>'saldo') = v_msg,
      format('FALHOU: dinheiro de %s deveria ser %s', v_p.nome, v_msg);

    -- (c) extrato: só as minhas doações
    select count(*) into v_cnt from public.transferencia t where v_p.id in (t.de_pessoa_id, t.para_pessoa_id);
    assert jsonb_array_length(v_painel->'doacoes') = v_cnt, format('FALHOU: extrato de doações de %s', v_p.nome);

    -- (d) lista para doar: os outros, só id e nome
    assert jsonb_array_length(v_leilao->'pessoas') = 2
       and not exists (select 1 from jsonb_array_elements(v_leilao->'pessoas') x
                        where (x->>'id')::uuid = v_p.id
                           or (select string_agg(k, ',' order by k) from jsonb_object_keys(x) k) <> 'id,nome'),
      format('FALHOU: lista para doar de %s deveria ter só id e nome dos outros', v_p.nome);
    v_n := v_n + 4;
  end loop;

  -- extrato do Bruno: recebeu de Ana, doou para Carla
  set local role anon;
  v_painel := public.fn_meu_painel(v_tokb);
  reset role;
  select string_agg(format('%s:%s:%s:%s', e->>'tipo', e->>'nome', e->>'recado', e->>'valor'), ' ' order by o)
    into v_txt from jsonb_array_elements(v_painel->'doacoes') with ordinality t(e, o);
  assert v_txt = 'recebida:Ana:RECADO-X1:41.17 feita:Carla:RECADO-Y2:13.07', 'FALHOU: extrato do Bruno: ' || coalesce(v_txt, '∅');
  v_n := v_n + 1;

  -- -------------------------------------------------------------------
  -- 6. Desfazer doação (admin) e reabrir
  -- -------------------------------------------------------------------
  perform set_config('request.jwt.claims', v_admin_claims, true);
  set local role authenticated;
  perform public.fn_admin_desfazer_venda(c1);
  perform public.fn_admin_desfazer_doacao(t2);
  reset role;
  select s.saldo::text into v_txt from public.fn_saldos() s where s.pessoa_id = bruno;
  assert v_txt = '203.46', 'FALHOU: desfazer doação devolve o valor a quem doou (Bruno 203.46), veio ' || v_txt;
  v_n := v_n + 1;

  set local role authenticated;
  perform public.fn_admin_reabrir();
  reset role;
  select count(*) into v_cnt from public.transferencia;
  assert v_cnt = 1, 'FALHOU: reabrir não apaga doações';
  set local role anon;
  v_r := public.fn_doar(v_tokb, carla, 1, '');
  reset role;
  select count(*) into v_cnt from public.transferencia;
  assert v_cnt = 2 and (v_r->>'saldo_depois')::numeric = 202.46, 'FALHOU: doação depois de reabrir deveria passar';
  v_n := v_n + 2;

  -- -------------------------------------------------------------------
  -- 7. Novo evento
  -- -------------------------------------------------------------------
  set local role authenticated;
  perform public.fn_admin_encerrar();
  perform public.fn_admin_arrematar(c1, ana, 10);
  v_estado := null;
  begin
    perform public.fn_admin_novo_evento('   ', true, true);
  exception when others then v_estado := sqlstate;
  end;
  assert v_estado = '22023', 'FALHOU: novo evento sem nome deveria ser recusado';

  -- mantendo pessoas e grupos (a partir do período encerrado, com arremate e doação)
  perform public.fn_admin_novo_evento('  Gincana 2027 ', true, true);
  reset role;
  select format('%s/%s', nome, aberto::text) into v_txt from public.evento where id = 1;
  assert v_txt = 'Gincana 2027/true', 'FALHOU: novo evento deveria ficar aberto com o nome novo: ' || v_txt;
  select format('%s/%s/%s/%s/%s/%s/%s', (select count(*) from public.jogo), (select count(*) from public.resultado),
                (select count(*) from public.participacao), (select count(*) from public.jogo_grupo),
                (select count(*) from public.caixa), (select count(*) from public.transferencia),
                (select count(*) from public.pessoa where grupo_id is not null))
    into v_txt;
  assert v_txt = '0/0/0/0/0/0/3', 'FALHOU: novo evento deveria apagar jogos/resultados/caixas/doações e manter grupos: ' || v_txt;
  select count(*) into v_cnt from public.grupo;
  assert v_cnt = 2, 'FALHOU: grupos mantidos';
  set local role anon;
  v_r := public.fn_entrar(carla, '6103');
  v_painel := public.fn_meu_painel(v_r->>'token');
  reset role;
  assert v_r ? 'token' and (v_painel->>'saldo')::numeric = 0 and (v_painel->>'vitorias')::int = 0,
    'FALHOU: pessoa mantida entra com a mesma senha e começa zerada';
  v_n := v_n + 5;

  -- mantendo pessoas, sem grupos
  set local role authenticated;
  perform public.fn_admin_novo_evento('Sem grupos', true, false);
  reset role;
  select format('%s/%s/%s', (select count(*) from public.grupo), (select count(*) from public.pessoa),
                (select count(*) from public.pessoa where grupo_id is not null)) into v_txt;
  assert v_txt = '0/3/0', 'FALHOU: sem grupos, as pessoas mantidas ficam sem grupo: ' || v_txt;
  v_n := v_n + 1;

  -- sem manter ninguém
  set local role authenticated;
  perform public.fn_admin_novo_evento('Do zero', false, false);
  reset role;
  select format('%s/%s', (select count(*) from public.pessoa), (select count(*) from public.sessao)) into v_txt;
  assert v_txt = '0/0', 'FALHOU: sem manter pessoas, pessoas e sessões são apagadas: ' || v_txt;
  perform set_config('request.jwt.claims', '{}', true);
  v_n := v_n + 1;

  raise exception 'TESTES OK (doações e partidas): % verificações passaram. (Esta mensagem aparece como erro de propósito: assim tudo o que o teste gravou é desfeito.)', v_n
    using errcode = 'P0001';
end
$teste$;
