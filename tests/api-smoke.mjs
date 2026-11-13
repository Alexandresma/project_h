// Teste pela API real do Supabase, com a chave pública (anon/publishable),
// exatamente como o navegador de um participante faria.
//
// Uso (PowerShell):
//   $env:SUPABASE_URL="https://xxxx.supabase.co"
//   $env:SUPABASE_ANON_KEY="sb_publishable_..."   # ou a chave anon antiga
//   $env:TESTE_NOME="Nome de um participante cadastrado"
//   $env:TESTE_SENHA="1234"
//   node tests/api-smoke.mjs
//
// Só lê dados. Efeitos: 1 tentativa de senha errada (zerada no login certo
// em seguida) e 1 sessão criada e encerrada.

const URL_BASE = (process.env.SUPABASE_URL || '').replace(/\/+$/, '');
const CHAVE = process.env.SUPABASE_ANON_KEY;
const NOME = process.env.TESTE_NOME;
const SENHA = process.env.TESTE_SENHA;

if (!URL_BASE || !CHAVE || !NOME || !SENHA) {
  console.error('Defina SUPABASE_URL, SUPABASE_ANON_KEY, TESTE_NOME e TESTE_SENHA.');
  process.exit(2);
}
if (/service_role|sb_secret_/.test(CHAVE) || jwtRole(CHAVE) === 'service_role') {
  console.error('Use a chave PÚBLICA (anon/publishable), nunca a service_role/secret.');
  process.exit(2);
}

const cab = { apikey: CHAVE, 'Content-Type': 'application/json' };
let falhas = 0, ok = 0;

function jwtRole(k) {
  try { return JSON.parse(Buffer.from(k.split('.')[1], 'base64url').toString()).role; } catch { return null; }
}
function check(cond, msg, extra) {
  if (cond) { ok++; console.log('  ✔ ' + msg); }
  else { falhas++; console.log('  ✘ ' + msg + (extra !== undefined ? '\n      ' + JSON.stringify(extra).slice(0, 300) : '')); }
}
async function rpc(fn, args = {}) {
  const r = await fetch(`${URL_BASE}/rest/v1/rpc/${fn}`, { method: 'POST', headers: cab, body: JSON.stringify(args) });
  const corpo = await r.text();
  let json; try { json = JSON.parse(corpo); } catch { json = corpo; }
  return { status: r.status, json, corpo };
}
// Caminhos de todas as chaves "premio" num JSON
function caminhosPremio(v, caminho = '$', out = []) {
  if (Array.isArray(v)) v.forEach((x, i) => caminhosPremio(x, `${caminho}[]`, out));
  else if (v && typeof v === 'object')
    for (const [k, x] of Object.entries(v)) {
      if (k === 'premio') out.push(`${caminho}.${k}`);
      caminhosPremio(x, `${caminho}.${k}`, out);
    }
  return out;
}

console.log('\n1. Tabelas não podem ser lidas com a chave pública');
for (const t of ['evento', 'admin', 'grupo', 'pessoa', 'sessao', 'jogo', 'jogo_grupo', 'participacao', 'resultado', 'caixa', 'transferencia']) {
  const r = await fetch(`${URL_BASE}/rest/v1/${t}?select=*&limit=1`, { headers: cab });
  const corpo = await r.text();
  check(!r.ok && /42501|permission denied/i.test(corpo), `${t}: negado (HTTP ${r.status})`, corpo);
}

console.log('\n2. Funções internas e de admin negadas');
const NADA = '00000000-0000-4000-8000-000000000000';
for (const [fn, args] of [['fn_admin_ranking'], ['fn_admin_placar_grupos'], ['fn_ranking_base'], ['fn_estatisticas'],
    ['fn_placar_grupos_base'], ['fn_saldos'], ['fn_admin_adicionar_caixas', { p_qtd: 1 }],
    ['fn_admin_arrematar', { p_caixa_id: NADA, p_pessoa_id: NADA, p_valor: 1 }],
    ['fn_admin_desfazer_venda', { p_caixa_id: NADA }], ['fn_doacoes_json', { p_pessoa_id: NADA }],
    ['fn_partida', { p_jogo_id: NADA }], ['fn_admin_nova_partida', { p_jogo_id: NADA }],
    ['fn_admin_desfazer_doacao', { p_id: NADA }],
    ['fn_admin_novo_evento', { p_nome: 'x', p_manter_pessoas: true, p_manter_grupos: true }],
    ['fn_admin_exibir_ranking', { p_visivel: true }], ['fn_admin_creditar', { p_para: NADA, p_valor: 1, p_motivo: '' }],
    ['fn_ranking_liberado'], ['fn_lista_vitorias', { p_eu: NADA }]]) {
  const r = await rpc(fn, args);
  check(r.status >= 400 && /42501|permission denied/i.test(r.corpo), `${fn}: negado (HTTP ${r.status})`, r.json);
}

console.log('\n3. Lista do login e login do admin só com senha');
const emailAdm = await rpc('fn_email_admin');
check(emailAdm.status === 200 && typeof emailAdm.json === 'string' && emailAdm.json.includes('@'),
  'fn_email_admin devolve o e-mail da conta do admin (a senha continua com o Supabase Auth)');
const lista = await rpc('fn_lista_login');
check(lista.status === 200, 'fn_lista_login responde', lista.json);
const pessoas = lista.json?.pessoas || [];
check(!/"(premio|pontos|senha|senha_hash|vitorias)"/.test(lista.corpo), 'lista só tem nomes e grupos');
const eu = pessoas.find(p => p.nome === NOME);
check(!!eu, `participante "${NOME}" está na lista`);
if (!eu) { console.log(`\nResultado: ${ok} ok, ${falhas + 1} falha(s)`); process.exit(1); }

console.log('\n4. Login');
const errado = await rpc('fn_entrar', { p_pessoa_id: eu.id, p_senha: 'x-errada' });
check(errado.json?.erro === 'Senha incorreta' && !errado.json?.token, 'senha errada → só "Senha incorreta"', errado.json);
const login = await rpc('fn_entrar', { p_pessoa_id: eu.id, p_senha: SENHA });
const token = login.json?.token;
check(!!token, 'senha certa → token', login.json);
if (!token) { console.log(`\nResultado: ${ok} ok, ${falhas} falha(s)`); process.exit(1); }

console.log('\n5. Prêmio: só o próprio, só onde deve');
const painel = await rpc('fn_meu_painel', { p_token: token });
const jogos = await rpc('fn_meus_jogos', { p_token: token });
const ranking = await rpc('fn_ranking', { p_token: token });
check(painel.status === 200 && painel.json?.pessoa_id === eu.id, 'meu painel é meu', painel.json);
check(caminhosPremio(painel.json).every(c => c === '$.premio' || c === '$.resultados[].premio'),
  'painel: prêmio só no total e nos meus resultados', caminhosPremio(painel.json));
const somaResultados = (painel.json?.resultados || []).reduce((s, r) => s + Number(r.premio), 0);
check(Math.abs(somaResultados - Number(painel.json?.premio)) < 0.005, 'painel: total = soma dos meus resultados');
check(jogos.status === 200 && Array.isArray(jogos.json)
    && jogos.json.every(j => Object.keys(j).sort().join() === 'descricao,divide_premio,formato,id,modo,nome,partida,tipo'),
  'meus jogos: só as regras (sem resultado, pontos nem prêmio)', (jogos.json || [])[0]);
check(ranking.status === 200 && caminhosPremio(ranking.json).length === 0, 'ranking: nenhum prêmio', caminhosPremio(ranking.json));
const visivel = !!painel.json?.evento?.ranking_visivel;
if (!visivel) {
  check(!/"(pontos|posicao|empate|no_desempate)"/.test(painel.corpo + ranking.corpo), 'ranking oculto: painel e ranking sem pontos nem colocação');
  const linhas = ranking.json?.linhas || [];
  const ordenada = linhas.every((l, i) => i === 0 || linhas[i - 1].vitorias > l.vitorias
    || (linhas[i - 1].vitorias === l.vitorias && linhas[i - 1].nome.localeCompare(l.nome, 'pt-BR', { sensitivity: 'base' }) <= 0));
  check(ordenada, 'ranking oculto: ordem por vitórias e depois nome (não vaza os pontos)');
}
if (ranking.json?.aberto) {
  check(!/"pontos"/.test(ranking.corpo), 'ranking com evento aberto: sem pontos');
  const final = await rpc('fn_resultado_final', { p_token: token });
  check(final.status >= 400, 'resultado final bloqueado com evento aberto', final.json);
} else {
  const final = await rpc('fn_resultado_final', { p_token: token });
  check(final.status === 200 && caminhosPremio(final.json).length === 0, 'resultado final: nenhum prêmio', caminhosPremio(final.json));
  if (!visivel) check(!/"(pontos|posicao)"/.test(final.corpo) && (final.json?.grupos || []).length === 0,
    'resultado final oculto: sem pontos, colocação nem placar de grupos');
}

console.log('\n6. Leilão, doações e crédito do ADM: só o meu dinheiro e as minhas caixas');
const p = painel.json || {};
check(Math.abs(Number(p.ganho) - Number(p.premio)) < 0.005
    && Math.abs(Number(p.saldo) - (Number(p.ganho) + Number(p.credito) + Number(p.recebido) - Number(p.doado) - Number(p.gasto))) < 0.005,
  'painel: saldo = ganho + crédito do ADM + recebido − doado − gasto', { ganho: p.ganho, credito: p.credito, recebido: p.recebido, doado: p.doado, gasto: p.gasto, saldo: p.saldo });
const somaDoacoes = tipo => (p.doacoes || []).filter(x => x.tipo === tipo).reduce((s, x) => s + Number(x.valor), 0);
check(Math.abs(somaDoacoes('recebida') - Number(p.recebido)) < 0.005 && Math.abs(somaDoacoes('feita') - Number(p.doado)) < 0.005
    && Math.abs(somaDoacoes('credito') - Number(p.credito)) < 0.005,
  'painel: recebido/doado/crédito do ADM = soma do meu extrato');
check((p.doacoes || []).filter(x => x.tipo === 'credito').every(x => x.nome === null), 'crédito do ADM aparece sem nome de participante');
const gastoArremates = (p.arremates || []).reduce((s, a) => s + Number(a.valor), 0);
check(Math.abs(gastoArremates - Number(p.gasto)) < 0.005, 'painel: gasto = soma dos meus arremates');
const leilao = await rpc('fn_leilao', { p_token: token });
if (ranking.json?.aberto) {
  check(leilao.status >= 400, 'leilão bloqueado com evento aberto', leilao.json);
} else {
  const caixas = leilao.json?.caixas || [];
  check(leilao.status === 200, 'fn_leilao responde', leilao.json);
  check(caixas.filter(c => !c.minha).every(c => Object.keys(c).sort().join() === 'minha,numero,vendida'),
    'caixas dos outros: só número e vendida (sem comprador, preço nem conteúdo)', caixas.filter(c => !c.minha));
  check(caixas.filter(c => c.minha).length === (p.arremates || []).length, 'minhas caixas = meus arremates');
  const outros = leilao.json?.pessoas || [];
  check(outros.every(x => Object.keys(x).sort().join() === 'id,nome') && !outros.some(x => x.id === eu.id),
    'lista para doar: só id e nome dos outros (sem saldo)', outros.slice(0, 3));
}

console.log('\n7. Sessão');
const inventado = await rpc('fn_meu_painel', { p_token: 'token-inventado' });
check(inventado.status >= 400 && /Sessão inválida/.test(inventado.corpo), 'token inventado → "Sessão inválida"', inventado.json);
await rpc('fn_sair', { p_token: token });
const depois = await rpc('fn_meu_painel', { p_token: token });
check(depois.status >= 400 && /Sessão inválida/.test(depois.corpo), 'depois de sair o token não vale', depois.json);

console.log(`\nResultado: ${ok} ok, ${falhas} falha(s)`);
process.exit(falhas ? 1 : 0);
