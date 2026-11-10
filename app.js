/* Gincana de Halloween — app conectado ao Supabase.
   Telas e visual vêm do protótipo (prototipo/index.html).
   - Participante: só funções fn_* com o token da sessão (nunca lê tabelas).
   - Administrador: Supabase Auth (e-mail e senha); lê/grava tabelas (RLS) e funções fn_admin_*. */
(function(){
'use strict';
const $=s=>document.querySelector(s);
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const BRL=v=>(Number(v)||0).toLocaleString('pt-BR',{style:'currency',currency:'BRL'});
const COLORS=['#9b5cff','#ff5470','#4ac7ff','#ff7a1a','#3ddc84','#ffcf4a'];
const ICONS=['🧙','🧛','👻','🎃','🕷️','💀','🦇','🧟'];
const MEDALS=['🥇','🥈','🥉'];
const TOKEN_KEY='gincana-token';

/* ---------- Supabase ---------- */
const CFG=window.GINCANA_CONFIG||{};
const configOk=/^https:\/\/.+/.test(CFG.SUPABASE_URL||'')&&!/COLE-AQUI/.test(CFG.SUPABASE_URL+CFG.SUPABASE_KEY);
const chaveSecreta=/sb_secret_|service_role/.test(CFG.SUPABASE_KEY||'')||jwtRole(CFG.SUPABASE_KEY)==='service_role';
function jwtRole(k){try{return JSON.parse(atob(String(k).split('.')[1].replace(/-/g,'+').replace(/_/g,'/'))).role}catch(e){return null}}
const sb=configOk&&!chaveSecreta&&window.supabase?window.supabase.createClient(CFG.SUPABASE_URL,CFG.SUPABASE_KEY,{auth:{persistSession:true,storageKey:'gincana-admin'}}):null;

async function rpc(fn,args){const{data,error}=await sb.rpc(fn,args||{});if(error)throw error;return data}
async function q(p){const{data,error}=await p;if(error)throw error;return data}
function msgErro(e){
  const m=(e&&(e.message||e.error_description))||'';
  if(/fetch|network|Load failed/i.test(m))return 'Sem conexão com o servidor. Tente de novo.';
  if(/Invalid login credentials/i.test(m))return 'E-mail ou senha incorretos.';
  if(/duplicate key/i.test(m))return 'Esse item já existe.';
  return m||'Algo deu errado. Tente de novo.';
}
const lsGet=k=>{try{return localStorage.getItem(k)}catch(e){return null}};
const lsSet=(k,v)=>{try{v==null?localStorage.removeItem(k):localStorage.setItem(k,v)}catch(e){}};

/* ---------- Estado ---------- */
let mode='carregando';        // carregando | erro | login | admin | user
let erroTela='';
let L=null;                   // tela de login: {evento, pessoas}
let S=null;                   // admin: mesmo formato do protótipo
let U=null;                   // participante: respostas das funções
let token=lsGet(TOKEN_KEY);
let view={adminTab:'painel',userTab:null,gameId:null,rankMode:'pessoas',reveal:false,lastGroup:''};
let pendingConfirm=null,busy=false;

/* ---------- Carregar dados ---------- */
const grp=x=>x?{id:x.id,name:x.nome,icon:x.icone,color:x.cor}:null;

async function carregarLogin(){L=await rpc('fn_lista_login')}

async function carregarAdmin(){
  const [ev,grupos,pessoas,jogos,jg,part,res,rk,gr]=await Promise.all([
    q(sb.from('evento').select('nome,aberto').eq('id',1).single()),
    q(sb.from('grupo').select('id,nome,cor,icone,criado_em').order('criado_em')),
    q(sb.from('pessoa').select('id,nome,grupo_id,tem_senha,bloqueado_ate').order('nome')),
    q(sb.from('jogo').select('id,nome,tipo,descricao,modo,formato,pontos,premio,pontos_1,premio_1,pontos_2,premio_2,pontos_3,premio_3,pontuado_em,criado_em').order('criado_em')),
    q(sb.from('jogo_grupo').select('jogo_id,grupo_id')),
    q(sb.from('participacao').select('jogo_id,pessoa_id')),
    q(sb.from('resultado').select('jogo_id,pessoa_id,grupo_id,colocacao,pontos,premio,registrado_em')),
    rpc('fn_admin_ranking'),
    rpc('fn_admin_placar_grupos')]);
  S={
    event:{name:ev.nome,open:ev.aberto},
    groups:grupos.map(g=>({id:g.id,name:g.nome,color:g.cor,icon:g.icone})),
    people:pessoas.map(p=>({id:p.id,name:p.nome,groupId:p.grupo_id,hasPwd:p.tem_senha,lockedUntil:p.bloqueado_ate&&new Date(p.bloqueado_ate)>new Date()?p.bloqueado_ate:null})),
    games:jogos.map(j=>{
      const results=res.filter(r=>r.jogo_id===j.id).map(r=>({pid:r.pessoa_id,gid:r.grupo_id,place:r.colocacao,points:r.pontos,prize:Number(r.premio)}));
      const groupResults=[];
      if(j.modo==='grupo')results.forEach(r=>{if(r.gid&&!groupResults.some(x=>x.gid===r.gid))groupResults.push({gid:r.gid,place:r.place,points:r.points,prize:r.prize})});
      return{id:j.id,name:j.nome,type:j.tipo,desc:j.descricao,mode:j.modo,scoring:j.formato,points:j.pontos,prize:Number(j.premio),
        places:[1,2,3].map(n=>({points:j['pontos_'+n],prize:Number(j['premio_'+n])})),
        participants:part.filter(x=>x.jogo_id===j.id).map(x=>x.pessoa_id),
        groups:jg.filter(x=>x.jogo_id===j.id).map(x=>x.grupo_id),
        results,groupResults,status:j.pontuado_em?'pontuado':'aberto'};
    }),
    rank:rk.map(r=>({pid:r.pessoa_id,name:r.nome,grp:grp(r.grupo),points:r.pontos,wins:r.vitorias,prize:Number(r.premio),pos:r.posicao,scored:r.pontuou,tied:r.empate,tiebreak:r.no_desempate})),
    groupRank:gr.map(grRow)
  };
}
const grRow=x=>({g:{id:x.grupo_id,name:x.nome,icon:x.icone,color:x.cor},members:x.membros,points:x.pontos,wins:x.vitorias,prize:Number(x.premio||0),pos:x.posicao});

/* Participante: todas as chamadas levam o token; "Sessão inválida" volta ao login */
async function rpcU(fn){
  try{return await rpc(fn,{p_token:token})}
  catch(e){if(/Sessão inválida/.test(e.message||'')){token=null;lsSet(TOKEN_KEY,null);e.sessaoInvalida=true}throw e}
}
async function carregarUser(){
  const [painel,jogos,ranking]=await Promise.all([rpcU('fn_meu_painel'),rpcU('fn_meus_jogos'),rpcU('fn_ranking')]);
  const final=painel.evento.aberto?null:await rpcU('fn_resultado_final');
  U={painel,jogos,ranking,final};
}
const rankRow=r=>({pid:r.pessoa_id,name:r.nome,grp:grp(r.grupo),points:r.pontos,wins:r.vitorias,pos:r.posicao,scored:r.pontuou,tied:r.empate,tiebreak:r.no_desempate});

/* ---------- Início / navegação ---------- */
async function boot(){
  if(!sb){mode='erro';erroTela=chaveSecreta?'O config.js está com a chave SECRETA. Troque pela chave pública (publishable/anon) e nunca publique a secreta.':'Preencha o config.js com a URL e a chave pública do projeto no Supabase.';return render()}
  mode='carregando';render();
  try{
    const{data:{session}}=await sb.auth.getSession();
    if(session){
      if(await rpc('fn_is_admin').catch(()=>false)){await carregarAdmin();mode='admin';return render()}
      await sb.auth.signOut();
    }
    if(token){
      try{await carregarUser();mode='user';return render()}
      catch(e){if(!e.sessaoInvalida)throw e}
    }
    await carregarLogin();mode='login';render();
  }catch(e){mode='erro';erroTela=msgErro(e);render()}
}
async function irLogin(msg){
  U=null;S=null;view={...view,gameId:null,userTab:null,reveal:false,adminTab:'painel'};
  try{await carregarLogin();mode='login'}catch(e){mode='erro';erroTela=msgErro(e)}
  render();top();if(msg)toast(msg);
}
/* Executa uma gravação do admin, recarrega tudo e redesenha.
   fn pode devolver {msg:'...'} para trocar a mensagem de sucesso. */
async function run(fn,okMsg){
  if(busy)return;busy=true;document.body.classList.add('busy');
  let ok=false,msg=okMsg;
  try{const r=await fn();if(r&&typeof r==='object'&&typeof r.msg==='string')msg=r.msg;ok=true}
  catch(e){toast(msgErro(e))}
  try{await carregarAdmin()}catch(e){if(ok)toast(msgErro(e))}
  busy=false;document.body.classList.remove('busy');
  render();if(ok&&msg)toast(msg);
  return ok;
}
async function refreshUser(){
  if(mode!=='user'||busy)return;
  try{await carregarUser();render()}
  catch(e){if(e.sessaoInvalida)irLogin('Sua sessão terminou. Entre de novo.');else toast(msgErro(e))}
}

/* ---------- Admin: ajudantes sobre S ---------- */
const person=id=>S.people.find(p=>p.id===id);
const groupOf=p=>{if(typeof p==='string')p=person(p);return p&&p.groupId?S.groups.find(g=>g.id===p.groupId):null};
const resultOf=(g,pid)=>g.status==='pontuado'?g.results.find(r=>r.pid===pid):null;
const curGame=()=>S.games.find(g=>g.id===view.gameId);
const membersOf=gid=>S.people.filter(p=>p.groupId===gid);
/* Jogo por grupo: participantes são os membros atuais dos grupos escolhidos */
function partsOf(g){return g.mode==='grupo'?S.people.filter(p=>g.groups.includes(p.groupId)).map(p=>p.id):g.participants}
function statsOf(pid){
  const s={pid,points:0,wins:0,podiums:0,prize:0,played:0};
  for(const g of S.games){
    if(partsOf(g).includes(pid))s.played++;
    const r=resultOf(g,pid);
    if(r){if(r.place===1)s.wins++;else s.podiums++;s.points+=r.points;s.prize+=r.prize}
  }
  return s;
}
const rule=()=>S.event.open?'wins':'points';
/* Ranking e placar vêm prontos do servidor (mesma ordem que o participante vê) */
const ranking=()=>S.rank;
const groupTotals=gid=>S.groupRank.find(x=>x.g.id===gid)||{points:0,wins:0,prize:0};

/* ---------- Textos e peças ---------- */
const medalOf=n=>MEDALS[n-1]||'';
const placeText=(formato,place)=>formato==='vitoria'?'Vitória':medalOf(place)+' '+place+'º lugar';
const winIco=(formato,place)=>formato==='vitoria'?'🏆':medalOf(place);
function ModeBadges(modo,formato){
  return `<span class="badge mode">${modo==='grupo'?'👥 Por grupo':'👤 Individual'}</span><span class="badge">${formato==='colocacao'?'🥇 1º/2º/3º':'🏆 Vencedor'}</span>`;
}
function ValuesText(g){
  const per=g.mode==='grupo'?' por membro':'';
  if(g.scoring==='colocacao')return `<span>⭐ ${g.places.map((p,i)=>`${i+1}º ${p.points}`).join(' · ')} pts${per}</span><span class="money">💰 ${g.places.map((p,i)=>`${i+1}º ${BRL(p.prize)}`).join(' · ')}</span>`;
  return `<span>⭐ ${g.points} pts por vitória${per}</span><span class="money">💰 ${BRL(g.prize)}${per}</span>`;
}
/* Vencedores (admin, a partir de S) no mesmo formato de fn_resultado_final */
function winnersOf(g){
  if(g.status!=='pontuado')return[];
  if(g.mode==='grupo')return g.groupResults.slice().sort((a,b)=>a.place-b.place).map(x=>{const gr=S.groups.find(y=>y.id===x.gid);return gr?{label:gr.icon+' '+gr.name,place:x.place,points:x.points,each:true}:null}).filter(Boolean);
  return g.results.slice().sort((a,b)=>a.place-b.place).map(r=>{const p=person(r.pid);return p?{label:p.name,place:r.place,points:r.points}:null}).filter(Boolean);
}
const winnersFromServer=v=>(v||[]).map(x=>({label:x.cada?x.icone+' '+x.nome:x.nome,place:x.colocacao,points:x.pontos,each:!!x.cada}));
function WinnersChips(formato,w){
  if(!w.length)return '<small class="muted">Sem vencedores</small>';
  return `<div class="chips">${w.map(x=>`<span class="chip win-chip">${winIco(formato,x.place)} ${esc(x.label)} <b>+${x.points}${x.each?' cada':''}</b></span>`).join('')}</div>`;
}
const WinnersText=g=>winnersOf(g).map(x=>winIco(g.scoring,x.place)+' '+esc(x.label)).join(', ');
const TIE_TEXT={wins:'Desempate: quem tem mais vitórias fica na frente; empatou nas vitórias, vale quem tem mais pontos; empatou também nos pontos, fica na frente quem chegou primeiro a essa pontuação. Se tudo for igual, a posição é dividida.',
  points:'Desempate: quem tem mais pontos fica na frente; empatou nos pontos, vale quem tem mais vitórias; empatou também nas vitórias, fica na frente quem chegou primeiro a essa pontuação. Se tudo for igual, a posição é dividida.'};

const Av=(name,g,cls='')=>`<span class="av ${cls}" style="--c:${g?g.color:'#6b5a85'}" aria-hidden="true">${esc((name||'?').trim().charAt(0).toUpperCase())}</span>`;
const Avatar=(p,cls='')=>Av(p.name,groupOf(p),cls);
const GLabel=g=>g?esc(g.icon+' '+g.name):'Sem grupo';
const GroupLabel=p=>GLabel(groupOf(p));
const Tile=(v,l,cls='')=>`<div class="tile ${cls}"><b>${v}</b><span>${l}</span></div>`;
const Empty=m=>`<p class="empty">${m}</p>`;
const StatusBadge=g=>g.status==='pontuado'?'<span class="badge ok">Pontuado</span>':'<span class="badge wait">Aguardando resultado</span>';
function ResultBadge(pontuado,formato,r){
  if(!pontuado)return '<span class="badge wait">Aguardando</span>';
  if(!r)return `<span class="badge loss">${formato==='colocacao'?'Sem colocação':'Derrota'}</span>`;
  return `<span class="badge ${r.place===1?'win':'podium'}">${placeText(formato,r.place)}</span>`;
}
const GroupSelect=(name,val)=>`<select name="${name}" aria-label="Grupo"><option value="">Sem grupo</option>${S.groups.map(g=>`<option value="${g.id}" ${g.id===val?'selected':''}>${esc(g.icon+' '+g.name)}</option>`).join('')}</select>`;
const Locked=()=>`<div class="notice">🔒 O evento está encerrado. Reabra o evento no Painel para cadastrar ou pontuar jogos.</div>`;
const hora=iso=>new Date(iso).toLocaleTimeString('pt-BR',{hour:'2-digit',minute:'2-digit'});

function Header(ev,sub){
  const o=ev.open;
  return `<header class="top"><div class="wrap top-in">
    <div class="brand"><span class="brand-ico">🎃</span><div style="min-width:0"><div class="brand-name">${esc(ev.name)}</div><div class="brand-sub">${sub}</div></div></div>
    <div class="top-right"><span class="pill ${o?'pill-on':'pill-off'}" title="${o?'Jogos abertos e ativos':'Evento encerrado'}"><i></i><span class="txt">${o?'Jogos abertos':'Encerrado'}</span></span>
    <button type="button" class="btn ghost sm" data-action="logout">Sair</button></div>
  </div></header>`;
}
function Nav(tabs,cur,act){
  return `<nav class="tabs" aria-label="Navegação"><div class="wrap tabs-in">${tabs.map(t=>`<button type="button" class="tab ${t.id===cur?'active':''}" ${t.id===cur?'aria-current="page"':''} data-action="${act}" data-tab="${t.id}"><span class="tab-ico">${t.ico}</span><span>${t.label}</span></button>`).join('')}</div></nav>`;
}
/* rows: {pid,name,grp,points,wins,prize?,pos,scored,tied,tiebreak} */
function RankList(rows,o={}){
  if(!rows.length)return Empty('Nenhum participante ainda.');
  return `<ol class="rank">${rows.map(r=>{
    const top=r.scored&&r.pos<=3?'top'+r.pos:'';
    const tag=r.tied?'<span class="tag tie">🤝 empate</span>':(r.tiebreak?'<span class="tag tb">⚖️ no desempate</span>':'');
    return `<li class="rk ${o.me===r.pid?'me':''} ${top}">
      <span class="pos">${!r.scored?'–':top?MEDALS[r.pos-1]:r.pos+'º'}</span>${Av(r.name,r.grp)}
      <span class="rk-name"><span>${esc(r.name)}${o.me===r.pid?' <em>você</em>':''} ${tag}</span><small>${GLabel(r.grp)}</small></span>
      <span class="rk-stats">
        ${o.by==='wins'?'':`<span class="cell"><b>${r.points}</b><small>pts</small></span>`}
        <span class="cell"><b>${r.wins}</b><small>${r.wins===1?'vitória':'vitórias'}</small></span>
        ${o.money?`<span class="cell m"><b>${BRL(r.prize)}</b><small>prêmio</small></span>`:''}
      </span></li>`}).join('')}</ol>`;
}
function GroupRank(gr,o={}){
  if(!gr.length)return Empty('Nenhum grupo criado.');
  const max=Math.max(1,...gr.map(x=>x.points));
  return `<ol class="grank">${gr.map(x=>`<li style="--c:${x.g.color}"><div class="gr-top"><span class="pos">${x.pos==null?'–':x.pos<=3?MEDALS[x.pos-1]:x.pos+'º'}</span><span class="g-ico">${esc(x.g.icon)}</span><b class="gr-name">${esc(x.g.name)}</b>
    <span class="gr-val"><b>${x.points}</b> pts · ${x.wins} vit.${o.money?` · <span class="money">${BRL(x.prize)}</span>`:''}</span></div>
    <div class="bar"><i style="width:${x.points/max*100}%"></i></div></li>`).join('')}</ol>`;
}
function Podium(rk,by){
  const t=rk.filter(r=>r.scored).slice(0,3);
  if(!t.length)return Empty('Ninguém pontuou ainda.');
  const order=[[t[1],2],[t[0],1],[t[2],3]];
  return `<div class="podium">${order.map(([r,n])=>r?`<div class="pd pd${n}">${Av(r.name,r.grp,'lg')}<b>${esc(r.name)}</b><small>${by==='wins'?`${r.wins} vit. · ${r.points} pts`:r.points+' pts'}${r.tied?' · empate':''}</small><div class="pd-base">${MEDALS[r.pos-1]||r.pos+'º'}</div></div>`:'<div></div>').join('')}</div>`;
}

/* ---------- Telas simples ---------- */
function Carregando(){return `<div class="wrap main"><p class="empty">Carregando…</p></div>`}
function Erro(){
  return `<div class="login wrap"><div class="hero"><div class="hero-ico">🎃</div><h1 class="spooky">Gincana de Halloween</h1></div>
    <section class="card"><h3>⚠️ Não foi possível abrir</h3><p class="muted" style="margin-top:6px">${esc(erroTela)}</p>
    <div class="row end" style="margin-top:12px"><button type="button" class="btn primary" data-action="retry">Tentar de novo</button></div></section></div>`;
}

/* ---------- Login ---------- */
function Login(){
  const ev=L.evento,o=ev.aberto;
  const ppl=L.pessoas;
  return `<div class="login wrap">
    <div class="hero"><div class="hero-ico">🎃</div><h1 class="spooky">${esc(ev.nome)}</h1>
      <span class="pill ${o?'pill-on':'pill-off'}"><i></i>${o?'Jogos abertos e ativos':'Evento encerrado'}</span></div>
    <div class="grid2">
      <section class="card"><h3>👤 Sou participante</h3><p class="muted small" style="margin-top:4px">Toque no seu nome e digite a senha que o organizador te passou.</p>
        ${ppl.length?`<div class="people-pick">${ppl.map(p=>{const g=grp(p.grupo);return `<button type="button" class="pick" data-action="login-person" data-id="${p.id}">${Av(p.nome,g)}<span>${esc(p.nome)}<small>${GLabel(g)}</small></span></button>`}).join('')}</div>`:`<div style="margin-top:12px">${Empty('Nenhum participante cadastrado ainda.')}</div>`}
      </section>
      <section class="card"><h3>🧙 Sou o administrador</h3><p class="muted small" style="margin-top:4px">Acesso exclusivo de quem organiza a gincana.</p>
        <form data-form="admin-login" class="stack" style="margin-top:12px">
          <label class="fld">E-mail<input name="email" type="email" autocomplete="username" required></label>
          <label class="fld">Senha<input name="senha" type="password" autocomplete="current-password" required></label>
          <button class="btn primary" type="submit">Entrar como administrador</button></form>
      </section>
    </div>
  </div>`;
}
function PersonLoginForm(id,nome){
  return `<form data-form="person-login" class="stack"><input type="hidden" name="id" value="${esc(id)}">
    <label class="fld">Senha de ${esc(nome)}<input name="senha" type="password" inputmode="numeric" autocomplete="current-password" maxlength="6" required autofocus></label>
    <p class="form-err" id="login-err" hidden></p>
    <div class="row end gap"><button type="button" class="btn ghost" data-action="close-modal">Cancelar</button><button class="btn primary" type="submit">Entrar</button></div>
  </form>`;
}

/* ---------- Admin ---------- */
function Admin(){
  const tabs=[{id:'painel',ico:'🏠',label:'Painel'},{id:'jogos',ico:'🎲',label:'Jogos'},{id:'pessoas',ico:'👥',label:'Pessoas'},{id:'grupos',ico:'🏴',label:'Grupos'},{id:'ranking',ico:'🏆',label:'Ranking'}];
  const map={painel:AdminPainel,jogos:AdminJogos,pessoas:AdminPessoas,grupos:AdminGrupos,ranking:AdminRanking};
  return Header(S.event,'Administrador')+Nav(tabs,view.adminTab,'admin-tab')+`<main class="wrap main">${(map[view.adminTab]||AdminPainel)()}</main>`;
}
function AdminPainel(){
  const o=S.event.open,rk=ranking();
  const scored=S.games.filter(g=>g.status==='pontuado').length;
  const pending=S.games.filter(g=>g.status!=='pontuado');
  const totalPrize=rk.reduce((a,r)=>a+r.prize,0),totalWins=rk.reduce((a,r)=>a+r.wins,0);
  const semSenha=S.people.filter(p=>!p.hasPwd).length;
  return `
  <section class="flag ${o?'on':'off'}">
    <div class="flag-main"><div class="flag-dot"></div><div>
      <div class="eyebrow">Status do evento</div><h2>${o?'Jogos abertos e ativos':'Evento encerrado'}</h2>
      <p class="muted small">${o?'Participantes veem os próprios jogos, vitórias, pontuação, prêmio e o ranking por vitórias.':'Todos veem o ranking geral, os jogos jogados e os vencedores com pontuação — sem valores em dinheiro.'}</p></div></div>
    ${o?'<button type="button" class="btn danger" data-action="ask-close-event">Encerrar evento</button>':'<button type="button" class="btn" data-action="ask-reopen-event">Reabrir evento</button>'}
  </section>
  ${semSenha?`<div class="notice">🔑 ${semSenha} participante(s) ainda sem senha — não conseguem entrar. <button type="button" class="link" data-action="admin-tab" data-tab="pessoas">Definir senhas ›</button></div>`:''}
  <div class="tiles">${Tile(S.people.length,'Participantes')}${Tile(S.groups.length,'Grupos')}${Tile(scored+'/'+S.games.length,'Jogos pontuados')}${Tile(totalWins,'Vitórias registradas')}${Tile(BRL(totalPrize),'Prêmios (fictício)','money')}</div>
  <div class="grid2">
    <section class="card"><div class="card-h"><h3>🏆 Pódio atual <span class="muted small">(${o?'por vitórias':'por pontos'})</span></h3><button type="button" class="link" data-action="admin-tab" data-tab="ranking">Ranking completo ›</button></div>${Podium(rk,rule())}</section>
    <section class="card"><div class="card-h"><h3>🏴 Grupos</h3><button type="button" class="link" data-action="admin-tab" data-tab="grupos">Gerenciar ›</button></div>${GroupRank(S.groupRank,{money:true})}</section>
  </div>
  <section class="card"><div class="card-h"><h3>⏳ Aguardando resultado</h3><button type="button" class="link" data-action="admin-tab" data-tab="jogos">Todos os jogos ›</button></div>
    ${pending.length?`<div class="list">${pending.map(g=>`<button type="button" class="list-row" data-action="open-game" data-id="${g.id}"><span class="lr-main"><b>${esc(g.name)}</b><small>${g.type} · ${g.mode==='grupo'?'por grupo · ':''}${partsOf(g).length} participantes</small></span>${partsOf(g).length?'<span class="badge wait">Pontuar</span>':'<span class="badge">Sem participantes</span>'}<span class="chev">›</span></button>`).join('')}</div>`:Empty('Todos os jogos já foram pontuados. 🎉')}
  </section>
  <section class="card"><h3>⚙️ Informações gerais</h3>
    <form data-form="event-info" class="inline-form" style="grid-template-columns:1fr auto"><input name="name" required maxlength="50" value="${esc(S.event.name)}" aria-label="Nome do evento"><button class="btn" type="submit">Salvar nome</button></form>
  </section>`;
}
function AdminJogos(){
  if(view.gameId){const g=curGame();if(g)return GameDetail(g);view.gameId=null}
  const o=S.event.open;
  const list=S.games.slice().sort((a,b)=>(a.status==='pontuado')-(b.status==='pontuado'));
  return `<div class="row between wrap-row"><h2>Jogos e gincanas</h2><button type="button" class="btn primary" data-action="new-game" ${o?'':'disabled'}>+ Novo jogo ou gincana</button></div>
  ${o?'':Locked()}
  ${list.length?`<div class="game-grid">${list.map(g=>{const wt=WinnersText(g);return `<button type="button" class="game-card" data-action="open-game" data-id="${g.id}">
    <div class="row between gap"><span class="badge">${g.type}</span>${StatusBadge(g)}</div><h3>${esc(g.name)}</h3>
    <div class="badges">${ModeBadges(g.mode,g.scoring)}</div>
    <div class="gc-foot"><span>${g.mode==='grupo'?`🏴 ${g.groups.filter(id=>S.groups.some(x=>x.id===id)).length} grupos`:`👥 ${partsOf(g).length}`}</span>${wt?`<span class="gc-w">${wt}</span>`:(g.status==='pontuado'?'<span>Sem vencedores</span>':'')}</div>
  </button>`}).join('')}</div>`:Empty('Nenhum jogo cadastrado. Crie o primeiro!')}`;
}
/* Linha de resultado: para pessoa (individual) ou grupo (por grupo); vencedor (switch) ou colocação (1º/2º/3º) */
function ResultRow(g,key,title,sub,saved,dis){
  const scored=g.status==='pontuado';
  const place=scored&&saved?saved.place:0;
  const def=g.scoring==='colocacao'?g.places[(place||1)-1]:{points:g.points,prize:g.prize};
  const pts=saved?saved.points:def.points,prz=saved?saved.prize:def.prize;
  const per=g.mode==='grupo'?'/membro':'';
  const vals=`<div class="res-vals"><label>Pts${per}<input type="number" class="res-pts" min="0" step="1" value="${pts}" ${dis}></label><label>R$${per}<input type="number" class="res-prize" min="0" step="0.01" value="${prz}" ${dis}></label></div>`;
  const name=`<div class="res-name">${title}<small>${sub}</small></div>`;
  if(g.scoring==='vitoria'){
    return `<div class="res-row ${place?'win':''}" data-key="${key}">
      <label class="switch" title="Venceu?"><input type="checkbox" class="res-win" aria-label="Vitória de ${title}" ${place?'checked':''} ${dis}><span></span></label>
      ${name}<div class="res-state"><span class="w">Vitória</span><span class="l">${scored?'Derrota':'—'}</span></div>${vals}</div>`;
  }
  return `<div class="res-row col ${place?'win':''}" data-key="${key}">${name}
    <div class="place-pick" role="radiogroup" aria-label="Colocação de ${title}">${[0,1,2,3].map(n=>`<label class="pp p${n}"><input type="radio" class="res-place" name="pl-${key}" value="${n}" ${place===n?'checked':''} ${dis}><span>${n?medalOf(n)+' '+n+'º':'—'}</span></label>`).join('')}</div>${vals}</div>`;
}
function GameDetail(g){
  const o=S.event.open,dis=o?'':'disabled',grp=g.mode==='grupo';
  const help=g.scoring==='colocacao'
    ?`Escolha o <b>1º, 2º ou 3º lugar</b>${grp?' de cada grupo':''} — quem ficar sem colocação não pontua. Empates são permitidos.`
    :`Ative ${grp?'o grupo vencedor':'quem <b>venceu</b>'} — ${grp?'os demais grupos':'os demais'} ficam com derrota.`;
  let step1,rows,count;
  if(grp){
    const sel=S.groups.filter(gr=>g.groups.includes(gr.id));count=sel.length;
    step1=S.groups.length?`<p class="muted small">Escolha os grupos que vão disputar. <b>Todos os membros</b> do grupo recebem a mesma pontuação.</p>
      <div class="check-groups">${S.groups.map(gr=>{const mem=membersOf(gr.id);return `<label class="ck grp-ck" style="--c:${gr.color}"><input type="checkbox" data-change="toggle-game-group" value="${gr.id}" ${g.groups.includes(gr.id)?'checked':''} ${dis}><span><b>${esc(gr.icon+' '+gr.name)}</b><small>${mem.length?esc(mem.map(p=>p.name).join(', ')):'Sem membros'}</small></span></label>`}).join('')}</div>`
      :Empty('Crie grupos na aba Grupos.');
    rows=sel.map(gr=>{const mem=membersOf(gr.id);return ResultRow(g,gr.id,esc(gr.icon+' '+gr.name),`${mem.length} ${mem.length===1?'membro':'membros'}: ${esc(mem.map(p=>p.name).join(', ')||'—')}`,g.groupResults.find(x=>x.gid===gr.id),dis)}).join('');
  }else{
    const byGroup=[...S.groups.map(gr=>({gr,ppl:membersOf(gr.id)})),{gr:null,ppl:S.people.filter(p=>!p.groupId||!S.groups.some(x=>x.id===p.groupId))}].filter(x=>x.ppl.length);
    const parts=g.participants.map(person).filter(Boolean);count=parts.length;
    step1=S.people.length?`<div class="chips">${S.groups.map(gr=>`<button type="button" class="chip" data-action="add-group-to-game" data-id="${gr.id}" ${dis}>+ ${esc(gr.icon+' '+gr.name)}</button>`).join('')}
      <button type="button" class="chip" data-action="add-all-to-game" ${dis}>+ Todos</button><button type="button" class="chip" data-action="clear-game" ${dis}>Limpar</button></div>
      <div class="check-groups">${byGroup.map(x=>`<div class="check-group"><div class="cg-title"><i style="background:${x.gr?x.gr.color:'#6b5a85'}"></i>${x.gr?esc(x.gr.icon+' '+x.gr.name):'Sem grupo'}</div>
        ${x.ppl.map(p=>`<label class="ck"><input type="checkbox" data-change="toggle-part" value="${p.id}" ${g.participants.includes(p.id)?'checked':''} ${dis}>${esc(p.name)}</label>`).join('')}</div>`).join('')}</div>`
      :Empty('Cadastre participantes na aba Pessoas.');
    rows=parts.map(p=>ResultRow(g,p.id,esc(p.name),GroupLabel(p),g.results.find(x=>x.pid===p.id),dis)).join('');
  }
  return `<button type="button" class="back" data-action="close-game">← Voltar para jogos</button>
  <section class="card game-head"><div style="min-width:0;flex:1">
      <div class="badges"><span class="badge">${g.type}</span>${StatusBadge(g)}${ModeBadges(g.mode,g.scoring)}</div>
      <h2>${esc(g.name)}</h2>${g.desc?`<p class="muted small">${esc(g.desc)}</p>`:''}
      <div class="meta" style="margin-top:8px">${ValuesText(g)}</div></div>
    <div class="row gap" style="align-self:flex-start"><button type="button" class="btn sm" data-action="edit-game" ${dis}>Editar</button><button type="button" class="btn ghost sm danger-tx" data-action="ask-delete-game" ${dis}>Excluir</button></div>
  </section>
  ${o?'':Locked()}
  <section class="card"><div class="card-h"><h3><span class="step">1</span>${grp?'Grupos participantes':'Participantes'} <span class="muted small">(${count})</span></h3></div>${step1}</section>
  <section class="card"><div class="card-h"><h3><span class="step">2</span>Resultado e pontuação</h3></div>
    ${count?`<p class="muted small">${help} Pontos e prêmio vêm do jogo, mas podem ser ajustados${grp?' (valores por membro)':' por pessoa'}.</p>
    <div class="results">${rows}</div>
    <div class="row end"><button type="button" class="btn primary" data-action="save-results" ${dis}>${g.status==='pontuado'?'Atualizar pontuação':'Salvar pontuação'}</button></div>`
    :Empty(grp?'Selecione os grupos no passo 1 para registrar o resultado.':'Adicione participantes no passo 1 para registrar o resultado.')}
  </section>`;
}
const PwdBadge=p=>p.lockedUntil?'<span class="badge nopwd">🔒 bloqueado</span>':(p.hasPwd?'':'<span class="badge nopwd">sem senha</span>');
function AdminPessoas(){
  const rows=S.people.slice().sort((a,b)=>a.name.localeCompare(b.name,'pt-BR'));
  const o=S.event.open;
  return `<section class="card"><h3>➕ Adicionar participante</h3>
    ${o?`<form data-form="add-person" class="inline-form"><input name="name" required maxlength="40" placeholder="Nome do participante" aria-label="Nome">${GroupSelect('groupId',view.lastGroup)}<button class="btn primary" type="submit">Adicionar</button></form>
    <p class="muted small" style="margin-top:8px">Depois toque no nome para definir a senha (4 a 6 dígitos) e passe para a pessoa.</p>`:Locked()}</section>
  <section class="card"><div class="card-h"><h3>👥 Participantes <span class="muted small">(${rows.length})</span></h3><span class="muted small">Toque para ver tudo, editar e definir a senha</span></div>
    ${rows.length?`<div class="list">${rows.map(p=>{const s=statsOf(p.id);return `<button type="button" class="list-row" data-action="person-detail" data-id="${p.id}">${Avatar(p)}
      <span class="lr-main"><b>${esc(p.name)} ${PwdBadge(p)}</b><small>${GroupLabel(p)} · ${s.played} ${s.played===1?'jogo':'jogos'}</small></span>
      <span class="lr-side"><span><b>${s.wins}</b> vit.</span><span><b>${s.points}</b> pts</span><span class="money">${BRL(s.prize)}</span></span><span class="chev">›</span></button>`}).join('')}</div>`:Empty('Nenhum participante. Adicione acima.')}
  </section>`;
}
function PersonDetail(p){
  const s=statsOf(p.id),games=S.games.filter(g=>partsOf(g).includes(p.id)||resultOf(g,p.id));
  const o=S.event.open;
  return `<div class="tiles t3">${Tile(s.points,'Pontos')}${Tile(s.wins,'Vitórias')}${Tile(BRL(s.prize),'Prêmio','money')}</div>
  <h4>Jogos (${games.length})</h4>
  ${games.length?`<ul class="mini">${games.map(g=>{const r=resultOf(g,p.id);return `<li><span>${esc(g.name)}<small>${g.type} · ${g.mode==='grupo'?'por grupo':'individual'}</small></span><span class="row gap">${r?`<small>+${r.points} pts · <span class="money">${BRL(r.prize)}</span></small>`:''}${ResultBadge(g.status==='pontuado',g.scoring,r)}</span></li>`}).join('')}</ul>`:Empty('Ainda não participou de nenhum jogo.')}
  <h4>🔑 Senha de acesso</h4>
  <p class="muted small">${p.hasPwd?'Senha definida. Por segurança ela não pode ser vista; se a pessoa esquecer, defina uma nova.':'<b>Sem senha:</b> a pessoa ainda não consegue entrar.'}
    ${p.lockedUntil?`<br>🔒 Bloqueada por tentativas erradas até ${hora(p.lockedUntil)}.`:''}</p>
  <form data-form="set-password" class="inline-form" style="grid-template-columns:1fr auto"><input type="hidden" name="id" value="${p.id}">
    <input name="senha" inputmode="numeric" pattern="[0-9]{4,6}" minlength="4" maxlength="6" required autocomplete="off" placeholder="Nova senha: 4 a 6 dígitos" aria-label="Nova senha">
    <button class="btn primary" type="submit">${p.hasPwd?'Trocar senha':'Definir senha'}</button></form>
  ${p.lockedUntil?`<div class="row end" style="margin-top:8px"><button type="button" class="btn sm" data-action="unlock" data-id="${p.id}">Desbloquear</button></div>`:''}
  <p class="muted small" style="margin-top:6px">Trocar a senha desconecta a pessoa dos aparelhos em que ela estava.</p>
  <h4>Dados</h4>
  <form data-form="edit-person" class="stack"><input type="hidden" name="id" value="${p.id}">
    <div class="two"><label class="fld">Nome<input name="name" required maxlength="40" value="${esc(p.name)}" ${o?'':'disabled'}></label><label class="fld">Grupo${GroupSelect('groupId',p.groupId)}</label></div>
    ${o?`<div class="row between gap"><button type="button" class="btn ghost danger-tx" data-action="ask-delete-person" data-id="${p.id}">Excluir</button><button class="btn primary" type="submit">Salvar</button></div>`:Locked()}
  </form>`;
}
function GroupForm(g){
  g=g||{};const ic=g.icon||ICONS[S.groups.length%ICONS.length],co=g.color||COLORS[S.groups.length%COLORS.length];
  return `<form data-form="group" class="stack" ${g.id?'':'style="margin-top:12px"'}>${g.id?`<input type="hidden" name="id" value="${g.id}">`:''}
    <label class="fld">Nome do grupo<input name="name" required maxlength="30" value="${esc(g.name||'')}" placeholder="Ex.: Lobisomens"></label>
    <div><div class="lbl">Ícone</div><div class="swatches">${ICONS.map(i=>`<label class="sw-opt"><input type="radio" name="icon" value="${i}" ${i===ic?'checked':''}><span>${i}</span></label>`).join('')}</div></div>
    <div><div class="lbl">Cor</div><div class="swatches">${COLORS.map(c=>`<label class="sw-opt"><input type="radio" name="color" value="${c}" ${c===co?'checked':''}><span class="dot" style="background:${c}"></span></label>`).join('')}</div></div>
    <div class="row end gap">${g.id?'<button type="button" class="btn ghost" data-action="close-modal">Cancelar</button>':''}<button class="btn primary" type="submit">${g.id?'Salvar':'Criar grupo'}</button></div>
  </form>`;
}
function AdminGrupos(){
  const o=S.event.open;
  return `<section class="card"><h3>➕ Criar grupo</h3>${o?GroupForm():Locked()}</section>
  ${S.groups.length?`<div class="groups">${S.groups.map(g=>{const mem=S.people.filter(p=>p.groupId===g.id),t=groupTotals(g.id),others=S.people.filter(p=>p.groupId!==g.id);
    return `<section class="card group" style="--c:${g.color}">
      <div class="card-h"><h3><span class="g-ico">${esc(g.icon)}</span>${esc(g.name)}</h3>${o?`<div class="row gap"><button type="button" class="btn ghost sm" data-action="edit-group" data-id="${g.id}">Editar</button><button type="button" class="btn ghost sm danger-tx" data-action="ask-delete-group" data-id="${g.id}">Excluir</button></div>`:''}</div>
      <div class="g-stats"><span><b>${mem.length}</b> membros</span><span><b>${t.points}</b> pts</span><span><b>${t.wins}</b> vitórias</span><span class="money">${BRL(t.prize)}</span></div>
      <div class="chips">${mem.map(p=>`<span class="chip member">${esc(p.name)}${o?`<button type="button" class="x" data-action="remove-from-group" data-id="${p.id}" aria-label="Remover ${esc(p.name)} do grupo">✕</button>`:''}</span>`).join('')||'<span class="muted small">Sem membros ainda.</span>'}</div>
      ${o&&others.length?`<select class="add-sel" data-change="add-to-group" data-id="${g.id}" aria-label="Adicionar participante ao grupo"><option value="">+ Adicionar participante…</option>${others.map(p=>{const og=groupOf(p);return `<option value="${p.id}">${esc(p.name)}${og?` (sai de ${esc(og.name)})`:''}</option>`}).join('')}</select>`:''}
    </section>`}).join('')}</div>`:Empty('Nenhum grupo criado ainda.')}`;
}
function AdminRanking(){
  const m=view.rankMode;
  return `<div class="seg" role="tablist">${[['pessoas','Pessoas'],['grupos','Grupos']].map(([k,l])=>`<button type="button" class="${m===k?'on':''}" data-action="rank-mode" data-mode="${k}">${l}</button>`).join('')}</div>
  <section class="card"><p class="muted small" style="margin-bottom:12px">${m==='pessoas'?`Mesma ordem que os participantes veem (${S.event.open?'evento aberto: por vitórias':'evento encerrado: por pontos'}), com pontos e prêmio de todos. ${TIE_TEXT[rule()]}`:'Gincanas por grupo contam uma vez para o grupo; jogos individuais somam os resultados dos membros. Desempate: mais vitórias.'}</p>
  ${m==='pessoas'?RankList(ranking(),{money:true}):GroupRank(S.groupRank,{money:true})}</section>`;
}

/* ---------- Participante (só dados das funções) ---------- */
function User(){
  const P=U.painel,o=P.evento.aberto;
  const tabs=o?[{id:'eu',ico:'🎃',label:'Meu painel'},{id:'jogos',ico:'🎲',label:'Meus jogos'},{id:'ranking',ico:'🏆',label:'Ranking'}]
              :[{id:'final',ico:'🏁',label:'Resultado'},{id:'todos',ico:'🎲',label:'Jogos'},{id:'eu',ico:'🎃',label:'Meu painel'}];
  if(!tabs.some(t=>t.id===view.userTab))view.userTab=tabs[0].id;
  const map={eu:UserEu,jogos:UserJogos,ranking:UserRanking,final:UserFinal,todos:UserTodos};
  const banner=!o&&view.userTab!=='final'?'<div class="closed-banner">🏁 Evento encerrado — veja o resultado final na aba Resultado.</div>':'';
  return Header({name:P.evento.nome,open:o},'Participante · '+esc(P.nome))+Nav(tabs,view.userTab,'user-tab')+`<main class="wrap main ${view.reveal?'':'hide-money'}">${banner}${map[view.userTab]()}</main>`;
}
function UserEu(){
  const P=U.painel,g=grp(P.grupo),o=P.evento.aberto;
  const scored=P.posicao!=null;
  const wins=(P.resultados||[]).slice().sort((a,b)=>a.colocacao-b.colocacao);
  return `<section class="card me-hero" style="--c:${g?g.color:'#6b5a85'}">${Av(P.nome,g,'lg')}<div><div class="eyebrow">Olá,</div><h2>${esc(P.nome)}</h2><span class="g-badge">${g?esc(g.icon+' Grupo '+g.name):'Sem grupo'}</span></div></section>
  <div class="tiles t3">${Tile(P.pontos,'Pontuação')}${Tile(P.vitorias,P.vitorias===1?'Vitória':'Vitórias')}${Tile(scored?P.posicao+'º'+(P.empate?' 🤝':''):'—',o?(P.empate?'No ranking (empate)':'No ranking'):(P.empate?'Posição final (empate)':'Posição final'))}</div>
  <section class="card private"><div class="card-h"><h3>🔒 Meu prêmio</h3><span class="badge priv">Só você vê</span></div>
    <button type="button" class="money-big" data-action="reveal-money" aria-label="${view.reveal?'Ocultar':'Revelar'} prêmio"><span class="mval">${BRL(P.premio)}</span><small>${view.reveal?'Toque para ocultar':'Toque para revelar'}</small></button>
    <p class="muted small">Valor fictício acumulado pelas suas vitórias. É individual: os outros participantes não veem.</p></section>
  <section class="card"><div class="card-h"><h3>🏆 Minhas vitórias e colocações</h3></div>
    ${wins.length?`<ul class="mini">${wins.map(x=>`<li><span>${winIco(x.formato,x.colocacao)} ${esc(x.jogo)}<small>${placeText(x.formato,x.colocacao)}${x.modo==='grupo'?' · com o grupo':''}</small></span><span class="mini-r"><b>+${x.pontos} pts</b><small class="mval">${BRL(x.premio)}</small></span></li>`).join('')}</ul>`:Empty('Nenhuma vitória ainda. Bora assombrar! 👻')}
  </section>`;
}
function UserJogos(){
  const games=U.jogos;
  return `<section class="card"><div class="card-h"><h3>🎲 Jogos que participei <span class="muted small">(${games.length})</span></h3></div>
    ${games.length?`<ul class="mini">${games.map(g=>{const r=g.meu_resultado?{place:g.meu_resultado.colocacao,points:g.meu_resultado.pontos}:null;return `<li><span>${esc(g.nome)}<small>${esc(g.tipo)} · ${g.modo==='grupo'?'por grupo':g.participantes+' participantes'}</small></span><span class="row gap">${r?`<b style="color:var(--gr)">+${r.points} pts</b>`:''}${ResultBadge(g.pontuado,g.formato,r)}</span></li>`}).join('')}</ul>`:Empty('Você ainda não foi incluído em nenhum jogo.')}
  </section>`;
}
function UserRanking(){
  return `<section class="card"><div class="card-h"><h3>🏆 Ranking de vitórias</h3></div>
    <p class="muted small" style="margin-bottom:12px">Enquanto os jogos estão abertos, o ranking mostra apenas as vitórias de cada pessoa.<br>${TIE_TEXT.wins}</p>
    ${RankList(U.ranking.linhas.map(rankRow),{by:'wins',me:U.painel.pessoa_id})}</section>`;
}
function UserFinal(){
  if(!U.final)return Empty('Carregando o resultado final…');
  const rk=U.final.ranking.map(rankRow),me=rk.find(r=>r.pid===U.painel.pessoa_id);
  const frase=me&&me.scored?`Você ficou em <b>${me.pos}º lugar${me.tied?' (empatado)':''}</b> com <b>${me.points} pts</b> e ${me.wins} ${me.wins===1?'vitória':'vitórias'}.`:'Você não pontuou desta vez — obrigado por jogar! 👻';
  return `<section class="card final-hero"><div class="eyebrow">Resultado final</div><h2 class="spooky">O evento terminou!</h2><p>${frase}</p></section>
  <section class="card"><div class="card-h"><h3>🏆 Pódio</h3></div>${Podium(rk,'points')}</section>
  <section class="card"><div class="card-h"><h3>📋 Ranking geral</h3></div><p class="muted small" style="margin-bottom:12px">${TIE_TEXT.points}</p>${RankList(rk,{me:U.painel.pessoa_id})}</section>
  <section class="card"><div class="card-h"><h3>🏴 Grupos</h3></div>${GroupRank(U.final.grupos.map(grRow))}</section>`;
}
function UserTodos(){
  if(!U.final)return Empty('Carregando…');
  const list=U.final.jogos;
  return `<section class="card"><div class="card-h"><h3>🎲 Jogos e gincanas jogados</h3></div>
    ${list.length?`<div class="games-all">${list.map(g=>`<div class="ga"><div class="ga-h"><b>${esc(g.nome)}</b><span class="badge">${esc(g.tipo)}</span></div>
      <div class="badges">${ModeBadges(g.modo,g.formato)}</div>
      ${g.pontuado?WinnersChips(g.formato,winnersFromServer(g.vencedores)):'<small class="muted">Não foi pontuado</small>'}
      <small class="muted">${g.participantes} participantes</small></div>`).join('')}</div>`:Empty('Nenhum jogo cadastrado.')}
  </section>`;
}

/* ---------- render / modal / toast ---------- */
function render(){
  const a=$('#app');
  a.innerHTML=mode==='admin'?Admin():mode==='user'?User():mode==='login'?Login():mode==='erro'?Erro():Carregando();
}
function top(){window.scrollTo({top:0})}
function openModal(title,body){
  $('#modal-root').innerHTML=`<div class="overlay" data-action="modal-bg"><div class="modal" role="dialog" aria-modal="true" aria-label="${esc(title.replace(/<[^>]*>/g,''))}"><div class="modal-h"><h3>${title}</h3><button type="button" class="icon-btn" data-action="close-modal" aria-label="Fechar">✕</button></div><div class="modal-b">${body}</div></div></div>`;
  document.body.classList.add('noscroll');
  const f=$('#modal-root [autofocus]');if(f)f.focus();
}
function closeModal(){$('#modal-root').innerHTML='';document.body.classList.remove('noscroll');pendingConfirm=null}
function confirmBox(title,msg,label,fn,danger=true){
  openModal(title,`<p class="muted">${msg}</p><div class="row end gap" style="margin-top:18px"><button type="button" class="btn ghost" data-action="close-modal">Cancelar</button><button type="button" class="btn ${danger?'danger':'primary'}" data-action="confirm-yes">${label}</button></div>`);
  pendingConfirm=fn;
}
let tt;function toast(m){const t=$('#toast');t.textContent=m;t.classList.add('show');clearTimeout(tt);tt=setTimeout(()=>t.classList.remove('show'),2800)}
function openPerson(id){const p=S&&person(id);if(p)openModal(Avatar(p)+' '+esc(p.name),PersonDetail(p))}

/* ---------- Gravações do admin ---------- */
const int=v=>Math.max(0,parseInt(v,10)||0),num=v=>Math.max(0,Math.round((parseFloat(v)||0)*100)/100);
const addParts=(jogoId,ids)=>ids.length?q(sb.from('participacao').insert(ids.map(pessoa_id=>({jogo_id:jogoId,pessoa_id})))):null;
const addGroups=(jogoId,ids)=>ids.length?q(sb.from('jogo_grupo').insert(ids.map(grupo_id=>({jogo_id:jogoId,grupo_id})))):null;
const registrar=(jogoId,itens)=>rpc('fn_admin_registrar_resultado',{p_jogo_id:jogoId,p_itens:itens});
/* Regrava o resultado de um jogo tirando uma pessoa ou um grupo (horário dos demais é mantido) */
async function regravarSem(g,{pid,gid}){
  if(g.status!=='pontuado')return;
  if(gid){if(!g.groupResults.some(x=>x.gid===gid))return;
    await registrar(g.id,g.groupResults.filter(x=>x.gid!==gid).map(x=>({grupo_id:x.gid,colocacao:x.place,pontos:x.points,premio:x.prize})))}
  else{if(!g.results.some(x=>x.pid===pid))return;
    await registrar(g.id,g.results.filter(x=>x.pid!==pid).map(x=>({pessoa_id:x.pid,colocacao:x.place,pontos:x.points,premio:x.prize})))}
}

/* ---------- actions ---------- */
const actions={
  'retry':()=>boot(),
  'logout':async()=>{
    if(mode==='admin')await sb.auth.signOut().catch(()=>{});
    else if(token){await rpc('fn_sair',{p_token:token}).catch(()=>{});token=null;lsSet(TOKEN_KEY,null)}
    irLogin();
  },
  'login-person':(el,id)=>{const p=L&&L.pessoas.find(x=>x.id===id);if(p)openModal('👤 Entrar',PersonLoginForm(p.id,p.nome))},
  'admin-tab':el=>{view.adminTab=el.dataset.tab;view.gameId=null;render();top()},
  'user-tab':el=>{view.userTab=el.dataset.tab;render();top();refreshUser()},
  'ask-close-event':()=>{const n=S.games.filter(g=>g.status!=='pontuado').length;
    confirmBox('Encerrar o evento?',`Todos os participantes passarão a ver o <b>ranking geral</b>, todos os jogos jogados e os vencedores com pontuação — sem os valores em dinheiro.${n?`<br><br>⚠️ Ainda há <b>${n} jogo(s)</b> sem resultado.`:''}`,'Encerrar evento',
      ()=>run(()=>rpc('fn_admin_encerrar'),'Evento encerrado. Ranking final liberado! 🏁'))},
  'ask-reopen-event':()=>confirmBox('Reabrir o evento?','Os jogos voltam a ficar abertos e ativos e o ranking final deixa de ser exibido aos participantes.','Reabrir',
    ()=>run(()=>rpc('fn_admin_reabrir'),'Evento reaberto.'),false),
  'new-game':()=>{if(!S.event.open)return toast('Evento encerrado.');openModal('Novo jogo ou gincana',GameForm())},
  'open-game':(el,id)=>{view.adminTab='jogos';view.gameId=id;render();top()},
  'close-game':()=>{view.gameId=null;render();top()},
  'edit-game':()=>{const g=curGame();if(g)openModal('Editar jogo',GameForm(g))},
  'ask-delete-game':()=>{const g=curGame();if(!g)return;confirmBox('Excluir jogo?',`"${esc(g.name)}" e a pontuação registrada nele serão removidos.`,'Excluir',
    ()=>{view.gameId=null;run(()=>q(sb.from('jogo').delete().eq('id',g.id)),'Jogo excluído.')})},
  'add-group-to-game':(el,id)=>{const g=curGame();if(!g)return;
    run(()=>addParts(g.id,membersOf(id).map(p=>p.id).filter(x=>!g.participants.includes(x))))},
  'add-all-to-game':()=>{const g=curGame();if(!g)return;
    run(()=>addParts(g.id,S.people.map(p=>p.id).filter(x=>!g.participants.includes(x))))},
  'clear-game':()=>{const g=curGame();if(!g)return;
    run(async()=>{if(g.status==='pontuado')await rpc('fn_admin_limpar_resultado',{p_jogo_id:g.id});await q(sb.from('participacao').delete().eq('jogo_id',g.id))})},
  'save-results':()=>{const g=curGame();if(!g||!S.event.open)return;
    const picks=[...document.querySelectorAll('.res-row')].map(r=>{
      let place=0;
      if(g.scoring==='vitoria')place=r.querySelector('.res-win').checked?1:0;
      else{const c=r.querySelector('.res-place:checked');place=c?Number(c.value):0}
      return{key:r.dataset.key,place,points:int(r.querySelector('.res-pts').value),prize:num(r.querySelector('.res-prize').value)};
    }).filter(x=>x.place>0);
    const itens=picks.map(x=>({[g.mode==='grupo'?'grupo_id':'pessoa_id']:x.key,colocacao:x.place,pontos:x.points,premio:x.prize}));
    const n=picks.length,who=g.mode==='grupo'?'grupo(s)':'pessoa(s)';
    run(()=>registrar(g.id,itens),n?(g.scoring==='colocacao'?`Colocações salvas: ${n} ${who} no pódio 🥇`:`Pontuação salva: ${n} ${who} vencedora(s) 🏆`):'Resultado salvo sem vencedores.')},
  'person-detail':(el,id)=>openPerson(id),
  'unlock':async(el,id)=>{if(await run(()=>rpc('fn_admin_desbloquear',{p_pessoa_id:id}),'Desbloqueado.'))openPerson(id)},
  'ask-delete-person':(el,id)=>{const p=person(id);confirmBox('Excluir participante?',`${esc(p.name)} será removido de todos os jogos e rankings.`,'Excluir',
    ()=>run(()=>q(sb.from('pessoa').delete().eq('id',id)),'Participante excluído.'))},
  'remove-from-group':(el,id)=>{const p=person(id);if(p)run(()=>q(sb.from('pessoa').update({grupo_id:null}).eq('id',id)),`${p.name} saiu do grupo.`)},
  'edit-group':(el,id)=>{const g=S.groups.find(x=>x.id===id);if(g)openModal('Editar grupo',GroupForm(g))},
  'ask-delete-group':(el,id)=>{const g=S.groups.find(x=>x.id===id);confirmBox('Excluir grupo?',`Os membros de "${esc(g.name)}" ficarão sem grupo. Pontos individuais são mantidos.`,'Excluir',
    ()=>run(()=>q(sb.from('grupo').delete().eq('id',id)),'Grupo excluído.'))},
  'rank-mode':el=>{view.rankMode=el.dataset.mode;render()},
  'reveal-money':()=>{view.reveal=!view.reveal;render()},
  'close-modal':closeModal,
  'modal-bg':closeModal,
  'confirm-yes':()=>{const f=pendingConfirm;closeModal();if(f)f()}
};
const forms={
  'admin-login':async fd=>{
    if(busy)return;busy=true;document.body.classList.add('busy');
    try{
      const{error}=await sb.auth.signInWithPassword({email:(fd.email||'').trim(),password:fd.senha||''});
      if(error)throw error;
      if(!await rpc('fn_is_admin')){await sb.auth.signOut();throw new Error('Este usuário não é o administrador.')}
      await carregarAdmin();mode='admin';view.adminTab='painel';
    }catch(e){toast(msgErro(e))}
    busy=false;document.body.classList.remove('busy');render();top();
  },
  'person-login':async fd=>{
    if(busy)return;busy=true;document.body.classList.add('busy');
    const err=$('#login-err');
    try{
      const r=await rpc('fn_entrar',{p_pessoa_id:fd.id,p_senha:fd.senha||''});
      if(r.erro){if(err){err.textContent=r.erro;err.hidden=false;const i=$('#modal-root input[name="senha"]');if(i){i.value='';i.focus()}}}
      else{token=r.token;lsSet(TOKEN_KEY,token);view.userTab=null;view.reveal=false;await carregarUser();mode='user';closeModal();render();top()}
    }catch(e){if(err){err.textContent=msgErro(e);err.hidden=false}}
    busy=false;document.body.classList.remove('busy');
  },
  'event-info':fd=>{const n=(fd.name||'').trim();if(n)run(()=>q(sb.from('evento').update({nome:n}).eq('id',1)),'Nome do evento atualizado.')},
  'game':fd=>{const name=(fd.name||'').trim();if(!name)return;
    const data={nome:name,tipo:fd.type==='Jogo'?'Jogo':'Gincana',modo:fd.mode==='grupo'?'grupo':'individual',formato:fd.scoring==='colocacao'?'colocacao':'vitoria',
      pontos:int(fd.points),premio:num(fd.prize),descricao:(fd.desc||'').trim()};
    [1,2,3].forEach(n=>{data['pontos_'+n]=int(fd['p'+n]);data['premio_'+n]=num(fd['r'+n])});
    closeModal();
    if(fd.id){
      const g=S.games.find(x=>x.id===fd.id);if(!g)return;
      const mudou=g.mode!==data.modo||g.scoring!==data.formato;
      run(async()=>{
        await q(sb.from('jogo').update(data).eq('id',g.id));     // mudar o formato apaga o resultado (gatilho no banco)
        if(mudou&&data.modo==='grupo'&&!g.groups.length)await addGroups(g.id,S.groups.map(x=>x.id));
        if(mudou&&data.modo==='individual'&&g.mode==='grupo'){const ids=partsOf(g).filter(x=>!g.participants.includes(x));await addParts(g.id,ids)}
        return{msg:mudou&&g.status==='pontuado'?'Formato alterado: registre o resultado novamente.':'Jogo atualizado.'};
      });
    }else{
      run(async()=>{
        const novo=await q(sb.from('jogo').insert(data).select('id').single());
        if(data.modo==='grupo')await addGroups(novo.id,S.groups.map(x=>x.id));
        view.adminTab='jogos';view.gameId=novo.id;top();
        return{msg:data.modo==='grupo'?'Gincana criada! Confira os grupos participantes.':'Jogo criado! Agora adicione os participantes.'};
      });
    }},
  'add-person':fd=>{const n=(fd.name||'').trim();if(!n)return;view.lastGroup=fd.groupId||'';
    run(()=>q(sb.from('pessoa').insert({nome:n,grupo_id:fd.groupId||null})),`${n} adicionado(a). Toque no nome para definir a senha.`)
      .then(()=>{const i=document.querySelector('[data-form="add-person"] input[name="name"]');if(i)i.focus()})},
  'edit-person':fd=>{const n=(fd.name||'').trim();if(!n)return;closeModal();
    run(()=>q(sb.from('pessoa').update({nome:n,grupo_id:fd.groupId||null}).eq('id',fd.id)),'Participante atualizado.')},
  'set-password':async fd=>{const s=(fd.senha||'').trim();
    if(!/^\d{4,6}$/.test(s))return toast('A senha deve ter de 4 a 6 dígitos.');
    if(await run(()=>rpc('fn_admin_definir_senha',{p_pessoa_id:fd.id,p_senha:s}),'Senha definida. Passe para a pessoa.'))openPerson(fd.id)},
  'group':fd=>{const n=(fd.name||'').trim();if(!n)return;
    const data={nome:n,icone:fd.icon||ICONS[0],cor:fd.color||COLORS[0]};
    if(fd.id){closeModal();run(()=>q(sb.from('grupo').update(data).eq('id',fd.id)),'Grupo atualizado.')}
    else run(()=>q(sb.from('grupo').insert(data)),`Grupo ${n} criado.`)}
};
function GameForm(g){
  g=g||{};
  const mode=g.mode||'individual',scoring=g.scoring||'vitoria',places=g.places||[{points:10,prize:20},{points:6,prize:10},{points:3,prize:5}];
  return `<form data-form="game" class="stack" data-mode="${mode}" data-scoring="${scoring}">${g.id?`<input type="hidden" name="id" value="${g.id}">`:''}
    <label class="fld">Nome<input name="name" required maxlength="60" value="${esc(g.name||'')}" placeholder="Ex.: Corrida do Caldeirão"></label>
    <label class="fld">Tipo<select name="type">${['Gincana','Jogo'].map(t=>`<option ${g.type===t?'selected':''}>${t}</option>`).join('')}</select></label>
    <div><div class="lbl">Quem pontua</div><div class="opt-cards">
      <label class="oc"><input type="radio" name="mode" value="individual" data-change="game-form" ${mode==='individual'?'checked':''}><span><b>👤 Individual</b><small>Cada pessoa pontua pelo próprio resultado</small></span></label>
      <label class="oc"><input type="radio" name="mode" value="grupo" data-change="game-form" ${mode==='grupo'?'checked':''}><span><b>👥 Por grupo</b><small>Todos do grupo recebem a mesma pontuação</small></span></label></div></div>
    <div><div class="lbl">Como registrar o resultado</div><div class="opt-cards">
      <label class="oc"><input type="radio" name="scoring" value="vitoria" data-change="game-form" ${scoring==='vitoria'?'checked':''}><span><b>🏆 Vencedor</b><small>Marca quem venceu (vitória ou derrota)</small></span></label>
      <label class="oc"><input type="radio" name="scoring" value="colocacao" data-change="game-form" ${scoring==='colocacao'?'checked':''}><span><b>🥇 1º, 2º e 3º lugar</b><small>Pontuação diferente por colocação</small></span></label></div></div>
    <div class="two only-vit"><label class="fld">Pontos por vitória<input name="points" type="number" min="0" step="1" value="${g.points??10}"></label>
      <label class="fld">Prêmio por vitória (R$)<input name="prize" type="number" min="0" step="0.01" value="${g.prize??20}"></label></div>
    <div class="only-col"><div class="places-grid"><span></span><span class="ph">Pontos</span><span class="ph">Prêmio (R$)</span>
      ${places.map((p,i)=>`<span class="pl">${medalOf(i+1)} ${i+1}º</span><input name="p${i+1}" type="number" min="0" step="1" value="${p.points}" aria-label="Pontos ${i+1}º lugar"><input name="r${i+1}" type="number" min="0" step="0.01" value="${p.prize}" aria-label="Prêmio ${i+1}º lugar">`).join('')}</div></div>
    <p class="muted small only-grp">No modo por grupo, pontos e prêmio são <b>por membro</b>: cada pessoa do grupo recebe o valor cheio.</p>
    <label class="fld">Descrição (opcional)<input name="desc" maxlength="120" value="${esc(g.desc||'')}" placeholder="Regras ou observações"></label>
    ${g.id&&g.status==='pontuado'?'<p class="muted small">Mudar valores aqui não altera resultados já registrados (ajuste no passo 2). Mudar o formato apaga o resultado registrado.</p>':''}
    <div class="row end gap"><button type="button" class="btn ghost" data-action="close-modal">Cancelar</button><button class="btn primary" type="submit">${g.id?'Salvar':'Criar e escolher participantes'}</button></div>
  </form>`;
}
const changes={
  'toggle-part':t=>{const g=curGame();if(!g)return;const id=t.value;
    if(t.checked)run(()=>addParts(g.id,[id]));
    else run(async()=>{await regravarSem(g,{pid:id});await q(sb.from('participacao').delete().eq('jogo_id',g.id).eq('pessoa_id',id))})},
  'toggle-game-group':t=>{const g=curGame();if(!g)return;const id=t.value;
    if(t.checked)run(()=>addGroups(g.id,[id]));
    else run(async()=>{await regravarSem(g,{gid:id});await q(sb.from('jogo_grupo').delete().eq('jogo_id',g.id).eq('grupo_id',id))})},
  'game-form':t=>{const f=t.form;f.dataset.mode=f.elements.mode.value;f.dataset.scoring=f.elements.scoring.value},
  'add-to-group':t=>{const p=person(t.value);if(!p)return;const g=S.groups.find(x=>x.id===t.dataset.id);
    run(()=>q(sb.from('pessoa').update({grupo_id:g.id}).eq('id',p.id)),`${p.name} entrou em ${g.name}.`)}
};

document.addEventListener('click',e=>{
  const el=e.target.closest('[data-action]');if(!el)return;
  const a=el.dataset.action;
  if(a==='modal-bg'&&e.target!==el)return;
  if(el.disabled)return;
  const h=actions[a];if(h)h(el,el.dataset.id,e);
});
document.addEventListener('submit',e=>{
  const f=e.target.closest('form[data-form]');if(!f)return;e.preventDefault();
  const h=forms[f.dataset.form];if(h)h(Object.fromEntries(new FormData(f)),f);
});
document.addEventListener('change',e=>{
  const t=e.target;
  if(t.classList.contains('res-win')){t.closest('.res-row').classList.toggle('win',t.checked);return}
  if(t.classList.contains('res-place')){
    const row=t.closest('.res-row'),n=Number(t.value),g=curGame();
    row.classList.toggle('win',n>0);
    if(n>0&&g){row.querySelector('.res-pts').value=g.places[n-1].points;row.querySelector('.res-prize').value=g.places[n-1].prize}
    return;
  }
  const h=changes[t.dataset.change];if(h)h(t);
});
document.addEventListener('keydown',e=>{if(e.key==='Escape'&&$('#modal-root').innerHTML)closeModal()});
/* Participante: atualiza ao voltar para a página */
document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible')refreshUser()});

boot();
})();
