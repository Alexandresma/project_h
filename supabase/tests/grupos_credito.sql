-- =====================================================================
-- Testes: jogo por grupo com/sem "marcar pontos e dinheiro" e crédito do
-- ADM até R$ 100 milhões (migração 11)
-- =====================================================================
-- Como rodar: depois da migração 11, cole este arquivo inteiro no SQL
-- Editor do Supabase e clique em Run.
--
-- Como os outros testes, é um único DO que TERMINA SEMPRE COM ERRO, de
-- propósito, para o Postgres desfazer tudo. Nada fica gravado.
--
--   ✅ Passou:  ERROR: TESTES OK (grupos e crédito): N verificações passaram ...
--   ❌ Falhou:  ERROR: FALHOU: <o que deu errado>
-- =====================================================================
do $teste$
declare
  v_admin_id constant uuid := 'aaaaaaaa-0000-4000-8000-000000000001';
  v_admin_claims constant text :=
    '{"sub":"aaaaaaaa-0000-4000-8000-000000000001","role":"authenticated"}';

  v_n      integer := 0;
  v_estado text;
  v_msg    text;
  v_txt    text;
  v_cnt    integer;
  v_r      jsonb;
  v_tok    text;

  g_bru uuid; g_lob uuid; g_fan uuid;
  ana uuid; bruno uuid; carla uuid; diego uuid;
  j1 uuid; j2 uuid; j3 uuid; j1b uuid;
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
  insert into public.grupo (nome) values ('Bruxas')    returning id into g_bru;   -- 3 membros
  insert into public.grupo (nome) values ('Lobos')     returning id into g_lob;   -- 1 membro
  insert into public.grupo (nome) values ('Fantasmas') returning id into g_fan;   -- vazio
  insert into public.pessoa (nome, grupo_id) values ('Carla', g_bru) returning id into carla;
  insert into public.pessoa (nome, grupo_id) values ('ana',   g_bru) returning id into ana;     -- minúscula: ordem sem caixa
  insert into public.pessoa (nome, grupo_id) values ('Bruno', g_bru) returning id into bruno;
  insert into public.pessoa (nome, grupo_id) values ('Diego', g_lob) returning id into diego;
  perform public.fn_admin_definir_senha(ana, '8101');

  -- -------------------------------------------------------------------
  -- 1. Opção desmarcada (padrão): só registra quem ganhou
  -- -------------------------------------------------------------------
  insert into public.jogo (nome, tipo, modo, formato, pontos, premio)
  values ('Cabo de Guerra', 'Jogo', 'grupo', 'vitoria', 10, 100) returning id into j1;
  assert not (select grupo_pontua from public.jogo where id = j1), 'FALHOU: jogo novo por grupo deveria vir desmarcado';
  insert into public.jogo_grupo (jogo_id, grupo_id) values (j1, g_bru), (j1, g_lob);
  perform public.fn_admin_registrar_resultado(j1, jsonb_build_array(jsonb_build_object('grupo_id', g_bru)));
  reset role;

  select format('%s/%s/%s', count(*), coalesce(sum(pontos), 0), coalesce(sum(premio), 0)) into v_txt
    from public.resultado where jogo_id = j1 and not conta;
  assert v_txt = '3/0/0.00', 'FALHOU: desmarcado deveria gravar quem ganhou com 0 pts, R$ 0 e sem contar: ' || v_txt;
  select format('%s/%s/%s', s.vitorias, s.pontos, s.premio) into v_txt from public.fn_estatisticas() s where s.pessoa_id = ana;
  assert v_txt = '0/0/0.00', 'FALHOU: desmarcado não deveria dar vitória, pontos nem prêmio: ' || v_txt;
  select format('%s/%s', p.pontos, p.vitorias) into v_txt from public.fn_placar_grupos_base() p where p.grupo_id = g_bru;
  assert v_txt = '0/0', 'FALHOU: desmarcado não deveria contar no placar de grupos: ' || v_txt;
  v_r := public.fn_vencedores(j1);
  assert jsonb_array_length(v_r) = 1 and v_r->0->>'nome' = 'Bruxas' and v_r->0->'pontos' = 'null'::jsonb,
    'FALHOU: desmarcado deveria mostrar o vencedor sem pontos: ' || v_r::text;
  set local role anon;
  v_tok := public.fn_entrar(ana, '8101')->>'token';
  v_r := public.fn_meu_painel(v_tok);
  assert (v_r->>'vitorias')::int = 0 and jsonb_array_length(v_r->'resultados') = 0 and (v_r->>'saldo')::numeric = 0,
    'FALHOU: painel não deveria mostrar o jogo que não conta: ' || (v_r->'resultados')::text;
  select (j->>'divide_premio')::boolean into v_txt
    from jsonb_array_elements(public.fn_meus_jogos(v_tok)) j where j->>'nome' = 'Cabo de Guerra';
  assert v_txt = 'false', 'FALHOU: meus jogos: desmarcado deveria vir com divide_premio = false';
  reset role;
  v_n := v_n + 7;

  -- -------------------------------------------------------------------
  -- 2. Opção marcada: divide igualmente
  -- -------------------------------------------------------------------
  perform set_config('request.jwt.claims', v_admin_claims, true);
  set local role authenticated;
  insert into public.jogo (nome, tipo, modo, formato, grupo_pontua)
  values ('Caça ao Tesouro', 'Gincana', 'grupo', 'colocacao', true) returning id into j2;
  insert into public.jogo_grupo (jogo_id, grupo_id) values (j2, g_bru), (j2, g_lob), (j2, g_fan);
  perform public.fn_admin_registrar_resultado(j2, jsonb_build_array(
    jsonb_build_object('grupo_id', g_bru, 'colocacao', 1, 'pontos', 10, 'premio', 100),
    jsonb_build_object('grupo_id', g_lob, 'colocacao', 2, 'pontos', 7,  'premio', 0.05),
    jsonb_build_object('grupo_id', g_fan, 'colocacao', 3, 'pontos', 5,  'premio', 9)));   -- sem membros: nada
  reset role;

  select string_agg(format('%s:%s:%s', p.nome, r.pontos, r.premio), ',' order by lower(p.nome)) into v_txt
    from public.resultado r join public.pessoa p on p.id = r.pessoa_id
   where r.jogo_id = j2 and r.conta;
  assert v_txt = 'ana:3:33.34,Bruno:3:33.33,Carla:3:33.33,Diego:7:0.05',
    'FALHOU: divisão (pontos inteiros; centavo que sobra para o 1º em ordem alfabética): ' || coalesce(v_txt, '∅');
  select sum(premio)::text into v_txt from public.resultado where jogo_id = j2 and grupo_id = g_bru;
  assert v_txt = '100.00', 'FALHOU: a soma do dinheiro dividido deveria bater com o valor do grupo: ' || v_txt;
  select count(*) into v_cnt from public.resultado where jogo_id = j2 and grupo_id = g_fan;
  assert v_cnt = 0, 'FALHOU: grupo sem membros não gera resultado';
  select format('%s/%s/%s', s.vitorias, s.pontos, s.premio) into v_txt from public.fn_estatisticas() s where s.pessoa_id = ana;
  assert v_txt = '1/3/33.34', 'FALHOU: marcado deveria contar vitória, pontos e prêmio divididos: ' || v_txt;
  select string_agg(format('%s:%s:%s', p.nome, p.pontos, p.vitorias), ',' order by p.ordem) into v_txt
    from public.fn_placar_grupos_base() p;
  assert v_txt = 'Bruxas:9:1,Lobos:7:0,Fantasmas:0:0', 'FALHOU: placar de grupos com a soma dos integrantes: ' || v_txt;
  select string_agg(format('%s:%s', x->>'nome', x->>'pontos'), ',' order by (x->>'colocacao')::int) into v_txt
    from jsonb_array_elements(public.fn_vencedores(j2)) x;
  assert v_txt = 'Bruxas:9,Lobos:7', 'FALHOU: vencedores com o total do grupo: ' || coalesce(v_txt, '∅');
  set local role anon;
  v_r := public.fn_meu_painel(v_tok);
  select (j->>'divide_premio')::boolean into v_txt
    from jsonb_array_elements(public.fn_meus_jogos(v_tok)) j where j->>'nome' = 'Caça ao Tesouro';
  reset role;
  assert (v_r->>'vitorias')::int = 1 and jsonb_array_length(v_r->'resultados') = 1 and (v_r->>'saldo')::numeric = 33.34,
    'FALHOU: painel da ana deveria ter só o jogo que conta (R$ 33,34)';
  assert v_txt = 'true', 'FALHOU: meus jogos: marcado deveria vir com divide_premio = true';
  v_n := v_n + 8;

  -- -------------------------------------------------------------------
  -- 3. Mudar a opção apaga o resultado; nova partida copia a opção
  -- -------------------------------------------------------------------
  perform set_config('request.jwt.claims', v_admin_claims, true);
  set local role authenticated;
  update public.jogo set grupo_pontua = false where id = j2;
  reset role;
  select format('%s/%s', (select count(*) from public.resultado where jogo_id = j2),
                (select (pontuado_em is null)::text from public.jogo where id = j2)) into v_txt;
  assert v_txt = '0/true', 'FALHOU: mudar "marcar pontos e dinheiro" deveria apagar o resultado: ' || v_txt;
  set local role authenticated;
  update public.jogo set grupo_pontua = true where id = j1;   -- admin muda pela tabela (coluna liberada)
  j1b := public.fn_admin_nova_partida(j1);
  reset role;
  assert (select grupo_pontua from public.jogo where id = j1b), 'FALHOU: nova partida deveria copiar a opção';
  select count(*) into v_cnt from public.resultado where jogo_id = j1;
  assert v_cnt = 0, 'FALHOU: marcar a opção num jogo pontuado deveria apagar o resultado';
  v_n := v_n + 3;

  -- -------------------------------------------------------------------
  -- 4. Crédito do ADM até R$ 100.000.000,00
  -- -------------------------------------------------------------------
  v_msg := null;
  begin
    set local role authenticated;
    perform public.fn_admin_creditar(diego, 100000000.01, '');
  exception when others then v_msg := sqlerrm; v_estado := sqlstate;
  end;
  reset role;
  assert v_estado = '22023' and v_msg = 'Valor alto demais (máximo R$ 100.000.000,00).',
    'FALHOU: crédito acima de R$ 100 milhões deveria ser recusado: ' || coalesce(v_msg, 'passou');
  set local role authenticated;
  perform public.fn_admin_creditar(diego, 100000000, 'TETO');
  perform public.fn_admin_creditar(diego, 2000000, '');      -- antes o limite era R$ 1 milhão
  reset role;
  select s.saldo::text into v_txt from public.fn_saldos() s where s.pessoa_id = diego;
  assert v_txt = '102000000.00', 'FALHOU: saldo com créditos grandes: ' || v_txt;
  v_n := v_n + 2;

  perform set_config('request.jwt.claims', '{}', true);
  raise exception 'TESTES OK (grupos e crédito): % verificações passaram. (Esta mensagem aparece como erro de propósito: assim tudo o que o teste gravou é desfeito.)', v_n
    using errcode = 'P0001';
end
$teste$;
