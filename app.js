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
const URL_BASE=String(CFG.SUPABASE_URL||'').trim().replace(/\/+(rest\/v1\/*)?$/,'');   // aceita a URL copiada com /rest/v1/
const sb=configOk&&!chaveSecreta&&window.supabase?window.supabase.createClient(URL_BASE,CFG.SUPABASE_KEY,{auth:{persistSession:true,storageKey:'gincana-admin'}}):null;

async function rpc(fn,args){const{data,error}=await sb.rpc(fn,args||{});if(error)throw error;return data}
async function q(p){const{data,error}=await p;if(error)throw error;return data}
function msgErro(e){
  const m=(e&&(e.message||e.error_description))||'';
  if(/fetch|network|Load failed/i.test(m))return 'Sem conexão com o servidor. Tente de novo.';
  if(/Invalid login credentials/i.test(m))return 'Senha incorreta.';
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
  const [ev,grupos,pessoas,jogos,jg,part,res,cx,tr,rk,gr]=await Promise.all([
    q(sb.from('evento').select('nome,aberto,ranking_visivel').eq('id',1).single()),
    q(sb.from('grupo').select('id,nome,cor,icone,criado_em').order('criado_em')),
    q(sb.from('pessoa').select('id,nome,grupo_id,tem_senha,bloqueado_ate').order('nome')),
    q(sb.from('jogo').select('id,nome,tipo,descricao,modo,formato,pontos,premio,pontos_1,premio_1,pontos_2,premio_2,pontos_3,premio_3,pontuado_em,criado_em,serie_id,numero_partida').order('criado_em')),
    q(sb.from('jogo_grupo').select('jogo_id,grupo_id')),
    q(sb.from('participacao').select('jogo_id,pessoa_id')),
    q(sb.from('resultado').select('jogo_id,pessoa_id,grupo_id,colocacao,pontos,premio,registrado_em')),
    q(sb.from('caixa').select('id,numero,conteudo,pessoa_id,valor,vendido_em').order('numero')),
    q(sb.from('transferencia').select('id,origem,de_pessoa_id,para_pessoa_id,valor,motivo,criado_em').order('criado_em')),
    rpc('fn_admin_ranking'),
    rpc('fn_admin_placar_grupos')]);
  S={
    event:{name:ev.nome,open:ev.aberto,rankingVisible:!!ev.ranking_visivel},
    groups:grupos.map(g=>({id:g.id,name:g.nome,color:g.cor,icon:g.icone})),
    people:pessoas.map(p=>({id:p.id,name:p.nome,groupId:p.grupo_id,hasPwd:p.tem_senha,lockedUntil:p.bloqueado_ate&&new Date(p.bloqueado_ate)>new Date()?p.bloqueado_ate:null})),
    games:jogos.map(j=>{
      const results=res.filter(r=>r.jogo_id===j.id).map(r=>({pid:r.pessoa_id,gid:r.grupo_id,place:r.colocacao,points:r.pontos,prize:Number(r.premio)}));
      const groupResults=[];
      if(j.modo==='grupo')results.forEach(r=>{if(r.gid&&!groupResults.some(x=>x.gid===r.gid))groupResults.push({gid:r.gid,place:r.place,points:r.points,prize:r.prize})});
      return{id:j.id,seriesId:j.serie_id,round:j.numero_partida,name:j.nome,type:j.tipo,desc:j.descricao,mode:j.modo,scoring:j.formato,points:j.pontos,prize:Number(j.premio),
        places:[1,2,3].map(n=>({points:j['pontos_'+n],prize:Number(j['premio_'+n])})),
        participants:part.filter(x=>x.jogo_id===j.id).map(x=>x.pessoa_id),
        groups:jg.filter(x=>x.jogo_id===j.id).map(x=>x.grupo_id),
        results,groupResults,status:j.pontuado_em?'pontuado':'aberto'};
    }),
    auction:{items:cx.map(c=>({id:c.id,num:c.numero,content:c.conteudo||'',sold:!!c.pessoa_id,buyerId:c.pessoa_id,price:Number(c.valor||0),soldAt:c.vendido_em}))},
    transfers:tr.map(t=>({id:t.id,from:t.origem==='admin'?'admin':t.de_pessoa_id,to:t.para_pessoa_id,amount:Number(t.valor),note:t.motivo||'',at:t.criado_em})),
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
  const [final,leilao]=painel.evento.aberto?[null,null]:await Promise.all([rpcU('fn_resultado_final'),rpcU('fn_leilao')]);
  U={painel,jogos,ranking,final,leilao};
}
/* Carteira do participante (só dele, vinda de fn_meu_painel) */
function walletU(){
  const P=U.painel;
  const buys=(P.arremates||[]).map(a=>({num:a.numero,content:a.conteudo||'',price:Number(a.valor),soldAt:a.vendido_em}));
  const moves=[...buys.map(i=>({kind:'buy',at:i.soldAt,amount:-i.price,item:i})),
    ...(P.doacoes||[]).map(d=>({kind:d.tipo==='credito'?'admin':d.tipo==='feita'?'sent':'recv',at:d.criado_em,amount:(d.tipo==='feita'?-1:1)*Number(d.valor),other:d.nome,note:d.recado||''}))]
    .sort((a,b)=>new Date(a.at)-new Date(b.at));
  return{earned:Number(P.ganho||0),fromAdmin:Number(P.credito||0),received:Number(P.recebido||0),sent:Number(P.doado||0),spent:Number(P.gasto||0),balance:Number(P.saldo||0),buys,moves};
}
/* "Quiz do Terror · Partida 2" (o servidor só manda o número quando a série tem mais de uma) */
const TitleU=(nome,partida)=>esc(nome)+(partida?` <span class="round">· Partida ${partida}</span>`:'');
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
/* Partidas: jogos repetidos formam uma série (mesmo seriesId), cada um com o número da partida */
const seriesOf=g=>S.games.filter(x=>x.seriesId===g.seriesId).sort((a,b)=>a.round-b.round);
const titleText=g=>g.name+(seriesOf(g).length>1?' · Partida '+g.round:'');
const GameTitle=g=>esc(g.name)+(seriesOf(g).length>1?` <span class="round">· Partida ${g.round}</span>`:'');
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
/* Colocações e pontuação só aparecem para os participantes com os jogos encerrados E o ranking liberado pelo ADM */
const revealed=()=>!S.event.open&&S.event.rankingVisible;
/* Ranking e placar vêm prontos do servidor (mesma ordem que o participante vê) */
const ranking=()=>S.rank;
const groupTotals=gid=>S.groupRank.find(x=>x.g.id===gid)||{points:0,wins:0,prize:0};

/* ---------- Leilão ---------- */
const round2=v=>Math.round((Number(v)||0)*100)/100;
const boxLabel=i=>'Caixa #'+String(i.num).padStart(2,'0');
const nextNum=()=>S.auction.items.reduce((m,i)=>Math.max(m,i.num),0)+1;
/* Carteira (admin): ganho + créditos do ADM + doações recebidas − doações feitas − gasto no leilão = saldo.
   O banco confere de novo no arremate e na doação. */
function walletOf(pid){
  const earned=round2(statsOf(pid).prize);
  const buys=S.auction.items.filter(i=>i.sold&&i.buyerId===pid).sort((a,b)=>new Date(a.soldAt)-new Date(b.soldAt));
  const spent=round2(buys.reduce((a,i)=>a+i.price,0));
  const sum=l=>round2(l.reduce((a,t)=>a+t.amount,0));
  const out=S.transfers.filter(t=>t.from===pid),inn=S.transfers.filter(t=>t.to===pid&&t.from!=='admin'),adm=S.transfers.filter(t=>t.to===pid&&t.from==='admin');
  const sent=sum(out),received=sum(inn),fromAdmin=sum(adm);
  const nm=id=>{const o=person(id);return o?o.name:'—'};
  const moves=[...buys.map(i=>({kind:'buy',at:i.soldAt,amount:-i.price,item:i})),
    ...out.map(t=>({kind:'sent',at:t.at,amount:-t.amount,other:nm(t.to),note:t.note})),
    ...inn.map(t=>({kind:'recv',at:t.at,amount:t.amount,other:nm(t.from),note:t.note})),
    ...adm.map(t=>({kind:'admin',at:t.at,amount:t.amount,note:t.note}))].sort((a,b)=>new Date(a.at)-new Date(b.at));
  return{earned,spent,sent,received,fromAdmin,balance:round2(earned+fromAdmin+received-spent-sent),buys,moves};
}
function BoxSVG(){
  return `<svg viewBox="0 0 120 112" aria-hidden="true">
    <ellipse cx="60" cy="105" rx="47" ry="6" fill="rgba(0,0,0,.35)"/>
    <polygon points="26,40 94,40 90,13 32,17" fill="#8e6033" stroke="#6b4420" stroke-width="2" stroke-linejoin="round"/>
    <path d="M14 40 L106 40 L103 101 L17 103 Z" fill="#c08a52" stroke="#6b4420" stroke-width="2.2" stroke-linejoin="round"/>
    <polygon points="14,40 54,40 41,25 3,31" fill="#d39d63" stroke="#6b4420" stroke-width="2" stroke-linejoin="round"/>
    <polygon points="66,40 106,40 117,27 79,22" fill="#ad7741" stroke="#6b4420" stroke-width="2" stroke-linejoin="round"/>
    <rect x="52" y="40" width="16" height="62" fill="#e6d29c" opacity=".5"/>
    <polygon points="52,40 68,40 66,47 61,44 56,48 52,45" fill="#e6d29c" opacity=".75"/>
    <polygon points="17,103 17,91 27,103" fill="#8a5a2c"/>
    <circle cx="32" cy="86" r="7" fill="#9e6a37" opacity=".55"/>
    <circle cx="90" cy="54" r="4" fill="#9e6a37" opacity=".45"/>
    <path d="M23 52 l9 3 M86 92 l10 -5 M93 58 q-6 7 0 13 M30 68 l6 -2" stroke="#7d5127" stroke-width="1.6" stroke-linecap="round" fill="none"/>
    <path d="M41 25 l-5 -2 M106 40 l3 -6" stroke="#6b4420" stroke-width="1.4" stroke-linecap="round"/>
    <text x="60" y="89" text-anchor="middle" font-family="Nunito,Arial,sans-serif" font-weight="900" font-size="46" fill="#2a180a" transform="rotate(-8 60 74)">?</text>
  </svg>`;
}
function Wallet(w){
  const cells=[['Ganhei nos jogos','money',BRL(w.earned)]];
  if(w.fromAdmin)cells.push(['Recebi do ADM','recv','+ '+BRL(w.fromAdmin)]);
  if(w.received)cells.push(['Recebi de doações','recv','+ '+BRL(w.received)]);
  if(w.sent)cells.push(['Doei','spent','− '+BRL(w.sent)]);
  cells.push(['Gastei no leilão','spent',w.spent?'− '+BRL(w.spent):BRL(0)]);
  return `<button type="button" class="money-big" data-action="reveal-money" aria-label="${view.reveal?'Ocultar':'Revelar'} valores"><span class="mval ${w.balance<0?'neg':''}">${BRL(w.balance)}</span><small>Saldo disponível · ${view.reveal?'toque para ocultar':'toque para revelar'}</small></button>
  <div class="wallet">${cells.map(([l,c,v])=>`<div><small>${l}</small><b class="mval ${c}">${v}</b></div>`).join('')}</div>`;
}
/* Extrato: arremates, doações e créditos do ADM, em ordem de horário */
function MovesList(w){
  if(!w.moves.length)return Empty('Nenhuma movimentação ainda.');
  return `<ul class="mini">${w.moves.map(m=>{
    let t,sub;
    if(m.kind==='buy'){t='📦 '+boxLabel(m.item);sub=(m.item.content?esc(m.item.content)+' · ':'')+'arrematada às '+hora(m.at)}
    else if(m.kind==='sent'){t='🤝 Doação para '+esc(m.other);sub=(m.note?esc(m.note)+' · ':'')+hora(m.at)}
    else if(m.kind==='admin'){t='🧙 Crédito do ADM';sub=(m.note?esc(m.note)+' · ':'')+'transferido pelo organizador às '+hora(m.at)}
    else{t='🎁 Doação de '+esc(m.other);sub=(m.note?esc(m.note)+' · ':'')+hora(m.at)}
    return `<li><span>${t}<small>${sub}</small></span><span class="mini-r"><b class="mval ${m.amount<0?'spent':'recv'}">${m.amount<0?'− ':'+ '}${BRL(Math.abs(m.amount))}</b></span></li>`}).join('')}</ul>`;
}
const WalletLine=w=>`Ganhou ${BRL(w.earned)}${w.fromAdmin?` · recebeu do ADM ${BRL(w.fromAdmin)}`:''}${w.received?` · recebeu ${BRL(w.received)}`:''}${w.sent?` · doou ${BRL(w.sent)}`:''} · gastou ${BRL(w.spent)}`;

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
function WinnersChips(formato,w,showPts=true){
  if(!w.length)return '<small class="muted">Sem vencedores</small>';
  return `<div class="chips">${w.map(x=>`<span class="chip win-chip">${winIco(formato,x.place)} ${esc(x.label)}${showPts&&x.points!=null?` <b>+${x.points}${x.each?' cada':''}</b>`:''}</span>`).join('')}</div>`;
}
const WinnersText=g=>winnersOf(g).map(x=>winIco(g.scoring,x.place)+' '+esc(x.label)).join(', ');
const TIE_TEXT={wins:'Ordem: mais vitórias; empatou nas vitórias, fica na frente quem tem mais pontos. Se vitórias e pontos forem iguais, as pessoas dividem a mesma colocação (ex.: duas pessoas em 2º) e a seguinte fica em 3º.',
  points:'Ordem: mais pontos; empatou nos pontos, fica na frente quem tem mais vitórias. Se pontos e vitórias forem iguais, as pessoas dividem a mesma colocação (ex.: duas pessoas em 2º) e a seguinte fica em 3º.'};

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
const Locked=()=>`<div class="notice">🔒 O período de jogos está encerrado. Para cadastrar ou pontuar jogos, reabra o período na aba Leilão.</div>`;
const hora=iso=>new Date(iso).toLocaleTimeString('pt-BR',{hour:'2-digit',minute:'2-digit'});

function Header(ev,sub){
  const o=ev.open;
  return `<header class="top"><div class="wrap top-in">
    <div class="brand"><span class="brand-ico">🎃</span><div style="min-width:0"><div class="brand-name">${esc(ev.name)}</div><div class="brand-sub">${sub}</div></div></div>
    <div class="top-right"><span class="pill ${o?'pill-on':'pill-off'}" title="${o?'Período de jogos aberto':'Período de jogos encerrado'}"><i></i><span class="txt">${o?'Jogos abertos':'Jogos encerrados'}</span></span>
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
/* Pódio: empatados dividem o degrau */
function Podium(rk,by){
  const top=rk.filter(r=>r.scored&&r.pos<=3);
  if(!top.length)return Empty('Ninguém pontuou ainda.');
  const col=n=>{const g=top.filter(r=>r.pos===n);if(!g.length)return '<div></div>';
    return `<div class="pd pd${n}"><div class="pd-avs">${g.slice(0,3).map(r=>Av(r.name,r.grp,'lg')).join('')}</div><b>${g.map(r=>esc(r.name)).join(' e ')}</b><small>${by==='wins'?`${g[0].wins} vit. · ${g[0].points} pts`:g[0].points+' pts'}${g.length>1?' · empate':''}</small><div class="pd-base">${MEDALS[n-1]}</div></div>`};
  return `<div class="podium">${col(2)}${col(1)}${col(3)}</div>`;
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
      <span class="pill ${o?'pill-on':'pill-off'}"><i></i>${o?'Jogos abertos e ativos':'Período de jogos encerrado'}</span></div>
    <div class="grid2">
      <section class="card"><h3>👤 Sou participante</h3><p class="muted small" style="margin-top:4px">Toque no seu nome e digite a senha que o organizador te passou.</p>
        ${ppl.length?`<div class="people-pick">${ppl.map(p=>{const g=grp(p.grupo);return `<button type="button" class="pick" data-action="login-person" data-id="${p.id}">${Av(p.nome,g)}<span>${esc(p.nome)}<small>${GLabel(g)}</small></span></button>`}).join('')}</div>`:`<div style="margin-top:12px">${Empty('Nenhum participante cadastrado ainda.')}</div>`}
      </section>
      <section class="card"><h3>🧙 Sou o administrador</h3><p class="muted small" style="margin-top:4px">Acesso exclusivo de quem organiza a gincana.</p>
        <form data-form="admin-login" class="stack" style="margin-top:12px">
          <label class="fld">Senha do administrador<input name="senha" type="password" autocomplete="current-password" required></label>
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
  const tabs=[{id:'painel',ico:'🏠',label:'Painel'},{id:'jogos',ico:'🎲',label:'Jogos'},{id:'pessoas',ico:'👥',label:'Pessoas'},{id:'grupos',ico:'🏴',label:'Grupos'},{id:'ranking',ico:'🏆',label:'Ranking'},{id:'leilao',ico:'🎁',label:'Leilão'}];
  const map={painel:AdminPainel,jogos:AdminJogos,pessoas:AdminPessoas,grupos:AdminGrupos,ranking:AdminRanking,leilao:AdminLeilao};
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
      <div class="eyebrow">Período de jogos</div><h2>${o?'Jogos abertos e ativos':'Período de jogos encerrado'}</h2>
      <p class="muted small">${o?'Participantes veem as regras dos próprios jogos, as próprias vitórias e a quantidade de vitórias de cada pessoa — sem colocação nem pontuação. Para encerrar e liberar o leilão, vá à aba Leilão.':`Leilão liberado. Ranking para os participantes: <b>${revealed()?'visível':'oculto'}</b>.`}</p></div></div>
    <div class="row gap" style="flex-wrap:wrap">${o?'':(revealed()?'<button type="button" class="btn" data-action="hide-ranking">Ocultar ranking</button>':'<button type="button" class="btn primary" data-action="ask-show-ranking">🏆 Exibir ranking</button>')}<button type="button" class="btn" data-action="admin-tab" data-tab="leilao">🎁 Ir para o Leilão</button></div>
  </section>
  ${semSenha?`<div class="notice">🔑 ${semSenha} participante(s) ainda sem senha — não conseguem entrar. <button type="button" class="link" data-action="admin-tab" data-tab="pessoas">Definir senhas ›</button></div>`:''}
  <div class="tiles">${Tile(S.people.length,'Participantes')}${Tile(S.groups.length,'Grupos')}${Tile(scored+'/'+S.games.length,'Jogos pontuados')}${Tile(totalWins,'Vitórias registradas')}${Tile(BRL(totalPrize),'Prêmios (fictício)','money')}</div>
  <div class="grid2">
    <section class="card"><div class="card-h"><h3>🏆 Pódio atual <span class="muted small">(${o?'por vitórias':'por pontos'})</span></h3><button type="button" class="link" data-action="admin-tab" data-tab="ranking">Ranking completo ›</button></div>${Podium(rk,rule())}</section>
    <section class="card"><div class="card-h"><h3>🏴 Grupos</h3><button type="button" class="link" data-action="admin-tab" data-tab="grupos">Gerenciar ›</button></div>${GroupRank(S.groupRank,{money:true})}</section>
  </div>
  <section class="card"><div class="card-h"><h3>⏳ Aguardando resultado</h3><button type="button" class="link" data-action="admin-tab" data-tab="jogos">Todos os jogos ›</button></div>
    ${pending.length?`<div class="list">${pending.map(g=>`<button type="button" class="list-row" data-action="open-game" data-id="${g.id}"><span class="lr-main"><b>${GameTitle(g)}</b><small>${g.type} · ${g.mode==='grupo'?'por grupo · ':''}${partsOf(g).length} participantes</small></span>${partsOf(g).length?'<span class="badge wait">Pontuar</span>':'<span class="badge">Sem participantes</span>'}<span class="chev">›</span></button>`).join('')}</div>`:Empty('Todos os jogos já foram pontuados. 🎉')}
  </section>
  <section class="card"><h3>⚙️ Informações gerais</h3>
    <form data-form="event-info" class="inline-form" style="grid-template-columns:1fr auto"><input name="name" required maxlength="50" value="${esc(S.event.name)}" aria-label="Nome do evento"><button class="btn" type="submit">Salvar nome</button></form>
    <div class="row gap" style="margin-top:12px;flex-wrap:wrap"><button type="button" class="btn sm danger-tx" data-action="new-event">✨ Novo evento</button></div>
  </section>`;
}
function AdminJogos(){
  if(view.gameId){const g=curGame();if(g)return GameDetail(g);view.gameId=null}
  const o=S.event.open;
  // só a partida mais recente de cada série; as anteriores ficam no histórico do jogo
  const latest={};S.games.forEach(g=>{if(!latest[g.seriesId]||g.round>latest[g.seriesId].round)latest[g.seriesId]=g});
  const list=Object.values(latest).sort((a,b)=>(a.status==='pontuado')-(b.status==='pontuado'));
  return `<div class="row between wrap-row"><h2>Jogos e gincanas</h2><button type="button" class="btn primary" data-action="new-game" ${o?'':'disabled'}>+ Novo jogo ou gincana</button></div>
  ${o?'':Locked()}
  ${list.length?`<div class="game-grid">${list.map(g=>{const wt=WinnersText(g);return `<button type="button" class="game-card" data-action="open-game" data-id="${g.id}">
    <div class="row between gap"><span class="badge">${g.type}</span>${StatusBadge(g)}</div><h3>${GameTitle(g)}</h3>
    <div class="badges">${ModeBadges(g.mode,g.scoring)}${g.round>1?`<span class="badge">📜 ${g.round-1} ${g.round===2?'partida anterior':'partidas anteriores'}</span>`:''}</div>
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
      <h2>${GameTitle(g)}</h2>${g.desc?`<p class="muted small">${esc(g.desc)}</p>`:''}
      <div class="meta" style="margin-top:8px">${ValuesText(g)}</div></div>
    <div class="row gap" style="align-self:flex-start;flex-wrap:wrap"><button type="button" class="btn sm primary" data-action="new-round" ${dis} title="Cria uma nova partida igual, zerada, e guarda esta no histórico">↻ Nova partida</button><button type="button" class="btn sm" data-action="edit-game" ${dis}>Editar</button><button type="button" class="btn ghost sm danger-tx" data-action="ask-delete-game" ${dis}>Excluir</button></div>
  </section>
  ${o?'':Locked()}
  <section class="card"><div class="card-h"><h3><span class="step">1</span>${grp?'Grupos participantes':'Participantes'} <span class="muted small">(${count})</span></h3></div>${step1}</section>
  <section class="card"><div class="card-h"><h3><span class="step">2</span>Resultado e pontuação</h3></div>
    ${count?`<p class="muted small">${help} Pontos e prêmio vêm do jogo, mas podem ser ajustados${grp?' (valores por membro)':' por pessoa'}.</p>
    <div class="results">${rows}</div>
    <div class="row end"><button type="button" class="btn primary" data-action="save-results" ${dis}>${g.status==='pontuado'?'Atualizar pontuação':'Salvar pontuação'}</button></div>`
    :Empty(grp?'Selecione os grupos no passo 1 para registrar o resultado.':'Adicione participantes no passo 1 para registrar o resultado.')}
  </section>
  ${History(g)}`;
}
function History(g){
  const ser=seriesOf(g);if(ser.length<2)return '';
  return `<section class="card hist"><div class="card-h"><h3>📜 Histórico de partidas <span class="muted small">(${ser.length})</span></h3></div>
    <div class="list">${ser.slice().reverse().map(x=>{const wt=WinnersText(x);return `<button type="button" class="list-row ${x.id===g.id?'cur':''}" data-action="open-game" data-id="${x.id}"><span class="lr-main"><b>Partida ${x.round}${x.id===g.id?' · você está aqui':''}</b><small>${partsOf(x).length} participantes${wt?' · '+wt:''}</small></span>${StatusBadge(x)}<span class="chev">›</span></button>`}).join('')}</div></section>`;
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
      <span class="lr-side"><span><b>${s.wins}</b> vit.</span><span><b>${s.points}</b> pts</span><span class="money" title="Saldo">${BRL(walletOf(p.id).balance)}</span></span><span class="chev">›</span></button>`}).join('')}</div>`:Empty('Nenhum participante. Adicione acima.')}
  </section>`;
}
function PersonDetail(p){
  const s=statsOf(p.id),games=S.games.filter(g=>partsOf(g).includes(p.id)||resultOf(g,p.id));
  const o=S.event.open;
  const w=walletOf(p.id);
  return `<div class="tiles t3">${Tile(s.points,'Pontos')}${Tile(s.wins,'Vitórias')}${Tile(BRL(w.balance),'Saldo','money')}</div>
  <p class="muted small" style="margin-top:8px">${WalletLine(w)}</p>
  ${w.moves.length?`<h4>Movimentações (${w.moves.length})</h4>${MovesList(w)}`:''}
  <h4>Jogos (${games.length})</h4>
  ${games.length?`<ul class="mini">${games.map(g=>{const r=resultOf(g,p.id);return `<li><span>${GameTitle(g)}<small>${g.type} · ${g.mode==='grupo'?'por grupo':'individual'}</small></span><span class="row gap">${r?`<small>+${r.points} pts · <span class="money">${BRL(r.prize)}</span></small>`:''}${ResultBadge(g.status==='pontuado',g.scoring,r)}</span></li>`}).join('')}</ul>`:Empty('Ainda não participou de nenhum jogo.')}
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
function RankingVisibility(){
  const o=S.event.open,v=revealed();
  return `<section class="flag ${v?'on':'off'}"><div class="flag-main"><div class="flag-dot"></div><div>
      <div class="eyebrow">Ranking para os participantes</div><h2>${v?'Ranking visível':'Ranking oculto'}</h2>
      <p class="muted small">${v?'Os participantes veem colocações, pontuação, pódio e placar dos grupos.':o?'Durante os jogos, os participantes veem só a quantidade de vitórias de cada pessoa, sem colocação nem pontuação. O botão fica disponível depois de encerrar o período de jogos (aba Leilão).':'Os participantes ainda veem só a quantidade de vitórias. Quando quiser revelar o resultado final, toque em Exibir ranking.'}</p></div></div>
    ${v?'<button type="button" class="btn" data-action="hide-ranking">Ocultar ranking</button>':`<button type="button" class="btn primary" data-action="ask-show-ranking" ${o?'disabled':''}>🏆 Exibir ranking</button>`}
  </section>`;
}
function AdminRanking(){
  const m=view.rankMode;
  return `${RankingVisibility()}<div class="seg" role="tablist">${[['pessoas','Pessoas'],['grupos','Grupos']].map(([k,l])=>`<button type="button" class="${m===k?'on':''}" data-action="rank-mode" data-mode="${k}">${l}</button>`).join('')}</div>
  <section class="card"><p class="muted small" style="margin-bottom:12px">${m==='pessoas'?`Visão completa do administrador (${S.event.open?'jogos abertos: ordem por vitórias':'jogos encerrados: ordem por pontos'}), com colocação, pontos e prêmio de todos. ${TIE_TEXT[rule()]}`:'Gincanas por grupo contam uma vez para o grupo; jogos individuais somam os resultados dos membros. Ordem: mais pontos, depois mais vitórias; iguais nos dois dividem a colocação.'}</p>
  ${m==='pessoas'?RankList(ranking(),{money:true}):GroupRank(S.groupRank,{money:true})}</section>`;
}

function AdminLeilao(){
  const o=S.event.open,items=S.auction.items.slice().sort((a,b)=>a.num-b.num);
  const sold=items.filter(i=>i.sold),total=round2(sold.reduce((a,i)=>a+i.price,0));
  const wallets=S.people.map(p=>({p,...walletOf(p.id)})).sort((a,b)=>b.balance-a.balance||a.p.name.localeCompare(b.p.name,'pt-BR'));
  return `<h2>🎁 Leilão de caixas surpresa</h2>
  <section class="flag ${o?'on':'off'}">
    <div class="flag-main"><div class="flag-dot"></div><div>
      <div class="eyebrow">Período de jogos</div><h2>${o?'Jogos abertos e ativos':'Período de jogos encerrado'}</h2>
      <p class="muted small">${o?'O leilão usa os prêmios do final dos jogos: arremates e doações só são liberados depois de encerrar o período de jogos. Já dá para cadastrar as caixas.':'Leilão liberado: registre arremates; os participantes já podem doar. Eles veem o resultado final e a aba Leilão.'}</p></div></div>
    ${o?'<button type="button" class="btn danger" data-action="ask-close-event">Encerrar período de jogos</button>':'<button type="button" class="btn" data-action="ask-reopen-event">Reabrir período de jogos</button>'}
  </section>
  <div class="tiles t3">${Tile(items.length,'Caixas')}${Tile(sold.length,'Vendidas')}${Tile(BRL(total),'Arrecadado','money')}</div>
  <section class="card"><h3>➕ Adicionar caixas</h3>
    <form data-form="add-boxes" class="boxes-form">
      <label class="fld">Quantidade<input name="qty" type="number" min="1" max="50" step="1" value="5" required></label>
      <p class="muted small">Numeradas a partir de <b>#${String(nextNum()).padStart(2,'0')}</b>. O conteúdo de cada caixa é opcional: só você vê, e o arrematante descobre depois de comprar.</p>
      <button class="btn primary" type="submit">Adicionar</button></form></section>
  <section class="card"><div class="card-h"><h3>📦 Caixas</h3><span class="muted small">Toque numa caixa para ${o?'editar':'registrar o arremate'}</span></div>
    ${items.length?`<div class="boxes">${items.map(i=>{const b=i.sold?person(i.buyerId):null;return `<button type="button" class="box ${i.sold?'sold':''}" data-action="open-box" data-id="${i.id}" aria-label="${boxLabel(i)}${i.sold?' vendida':''}">${BoxSVG()}${i.sold?'<span class="stamp">VENDIDO</span>':''}<span class="box-num">${boxLabel(i)}</span><span class="box-sub">${i.sold?`${esc(b?b.name:'—')} · <span class="money">${BRL(i.price)}</span>`:(i.content?'🔒 '+esc(i.content):'Disponível')}</span></button>`}).join('')}</div>`:Empty('Nenhuma caixa cadastrada.')}
  </section>
  ${AdminCredits()}
  ${Transfers()}
  <section class="card"><div class="card-h"><h3>💰 Saldos dos participantes</h3><span class="muted small">Ganhos + créditos do ADM + doações recebidas − doações − gastos</span></div>
    ${wallets.length?`<div class="list">${wallets.map(w=>`<div class="list-row" style="cursor:default">${Avatar(w.p)}<span class="lr-main"><b>${esc(w.p.name)}</b><small>${WalletLine(w)}${w.buys.length?` (${w.buys.map(boxLabel).join(', ')})`:''}</small></span><b class="money ${w.balance<0?'neg':''}">${BRL(w.balance)}</b></div>`).join('')}</div>`:Empty('Nenhum participante.')}
  </section>`;
}
/* Crédito do ADM: dinheiro dado pelo organizador, sem tirar de ninguém */
function AdminCredits(){
  const ppl=S.people.slice().sort((a,b)=>a.name.localeCompare(b.name,'pt-BR'));
  const list=S.transfers.filter(t=>t.from==='admin').sort((a,b)=>new Date(b.at)-new Date(a.at));
  return `<section class="card"><div class="card-h"><h3>🧙 Crédito do ADM</h3><span class="muted small">Só dinheiro — a pontuação não muda</span></div>
    <p class="muted small">Dê qualquer valor a um participante, sem tirar de ninguém. Para ele, aparece como <b>"Crédito do ADM"</b>.</p>
    ${ppl.length?`<form data-form="admin-credit" class="stack" style="margin-top:12px">
      <div class="two"><label class="fld">Para quem<select name="to" required><option value="">Escolha…</option>${ppl.map(p=>`<option value="${p.id}">${esc(p.name)} — saldo ${BRL(walletOf(p.id).balance)}</option>`).join('')}</select></label>
        <label class="fld">Valor (R$)<input name="amount" type="number" min="0.01" step="0.01" required placeholder="0,00"></label></div>
      <label class="fld">Motivo (opcional)<input name="note" maxlength="60" placeholder="Ex.: prêmio de melhor fantasia"></label>
      <div class="row end"><button class="btn primary" type="submit">Creditar</button></div>
    </form>`:Empty('Cadastre participantes na aba Pessoas.')}
    ${list.length?`<h4>Créditos feitos (${list.length})</h4><div class="list">${list.map(t=>{const b=person(t.to);return `<div class="list-row" style="cursor:default"><span class="lr-main"><b>ADM → ${esc(b?b.name:'—')}</b><small>${t.note?esc(t.note)+' · ':''}${hora(t.at)}</small></span><b class="money">+ ${BRL(t.amount)}</b><button type="button" class="btn ghost sm danger-tx" data-action="ask-undo-transfer" data-id="${t.id}">Desfazer</button></div>`}).join('')}</div>`:''}
  </section>`;
}
function Transfers(){
  const list=S.transfers.filter(t=>t.from!=='admin').sort((a,b)=>new Date(b.at)-new Date(a.at));
  return `<section class="card"><div class="card-h"><h3>🤝 Doações entre participantes</h3><span class="muted small">Feitas pelos próprios participantes</span></div>
    <p class="muted small">Cada participante escolhe, na aba Leilão dele, para quem doar e quanto. Só dinheiro: a pontuação não muda. Aqui você acompanha e pode desfazer uma doação feita por engano.</p>
    ${list.length?`<div class="list" style="margin-top:12px">${list.map(t=>{const a=person(t.from),b=person(t.to);return `<div class="list-row" style="cursor:default"><span class="lr-main"><b>${esc(a?a.name:'—')} → ${esc(b?b.name:'—')}</b><small>${t.note?esc(t.note)+' · ':''}${hora(t.at)}</small></span><b class="money">${BRL(t.amount)}</b><button type="button" class="btn ghost sm danger-tx" data-action="ask-undo-transfer" data-id="${t.id}">Desfazer</button></div>`}).join('')}</div>`:`<div style="margin-top:12px">${Empty('Nenhuma doação feita ainda.')}</div>`}
  </section>`;
}
function BoxModal(i){
  const b=i.sold?person(i.buyerId):null;
  const head=`<div class="box-modal"><div class="box ${i.sold?'sold':''}">${BoxSVG()}${i.sold?'<span class="stamp">VENDIDO</span>':''}</div>
    <div><div class="eyebrow">${boxLabel(i)}</div><p class="muted small" style="margin-top:4px">${i.content?`Conteúdo: <b style="color:var(--tx)">${esc(i.content)}</b>`:'Conteúdo não informado'}</p></div></div>`;
  if(i.sold)return head+`<div class="sale-preview">Arrematada por <b>${esc(b?b.name:'—')}</b> por <b class="money">${BRL(i.price)}</b><br><small class="muted">${new Date(i.soldAt).toLocaleString('pt-BR')}</small></div>
    <div class="row between gap" style="margin-top:16px"><button type="button" class="btn ghost danger-tx" data-action="ask-undo-sale" data-id="${i.id}">Desfazer venda</button><button type="button" class="btn" data-action="close-modal">Fechar</button></div>`;
  const open=S.event.open;
  const ppl=S.people.slice().sort((a,c)=>a.name.localeCompare(c.name,'pt-BR'));
  return head+`<form data-form="sell-box" class="stack"><input type="hidden" name="id" value="${i.id}">
    <label class="fld">Conteúdo (opcional — só você e o arrematante veem)<input name="content" maxlength="60" value="${esc(i.content||'')}" placeholder="Ex.: kit de chocolates"></label>
    ${open?'<div class="notice">🔒 Encerre o período de jogos (no topo da aba Leilão) para registrar o arremate. Por enquanto dá para salvar o conteúdo.</div>':`
    <div class="two"><label class="fld">Quem arrematou<select name="buyer" data-change="sale-preview"><option value="">Escolha…</option>${ppl.map(p=>{const w=walletOf(p.id);return `<option value="${p.id}" data-bal="${w.balance}">${esc(p.name)} — saldo ${BRL(w.balance)}</option>`}).join('')}</select></label>
      <label class="fld">Valor arrematado (R$)<input name="price" type="number" min="0.01" step="0.01" placeholder="0,00" data-input="sale-preview"></label></div>
    <div class="sale-preview" data-preview>Escolha quem arrematou e o valor.</div>`}
    <div class="row between gap" style="flex-wrap:wrap"><button type="button" class="btn ghost danger-tx" data-action="ask-delete-box" data-id="${i.id}">Excluir caixa</button>
      <div class="row gap">${open?'<button class="btn primary" type="submit">Salvar</button>':`<button type="button" class="btn" data-action="save-box-content" data-id="${i.id}">Só salvar conteúdo</button><button class="btn primary" type="submit">Registrar arremate</button>`}</div></div>
  </form>`;
}
function salePreview(f){
  const sel=f&&f.elements.buyer,box=f&&f.querySelector('[data-preview]');if(!sel||!box)return;
  if(!sel.value){box.textContent='Escolha quem arrematou e o valor.';return}
  const bal=Number(sel.selectedOptions[0].dataset.bal),price=round2(f.elements.price.value),after=round2(bal-price);
  box.innerHTML=`Saldo atual: <b class="money">${BRL(bal)}</b> → depois do arremate: <b class="money ${after<0?'neg':''}">${BRL(after)}</b>${after<0?'<br><small class="neg">Saldo insuficiente para esse valor.</small>':''}`;
}

/* ---------- Participante (só dados das funções) ---------- */
function User(){
  const P=U.painel,o=P.evento.aberto;
  const tabs=o?[{id:'eu',ico:'🎃',label:'Meu painel'},{id:'jogos',ico:'🎲',label:'Meus jogos'},{id:'ranking',ico:'🏆',label:'Ranking'}]
              :[{id:'final',ico:'🏁',label:'Resultado'},{id:'todos',ico:'🎲',label:'Jogos'},{id:'leilao',ico:'🎁',label:'Leilão'},{id:'eu',ico:'🎃',label:'Meu painel'}];
  if(!tabs.some(t=>t.id===view.userTab))view.userTab=tabs[0].id;
  const map={eu:UserEu,jogos:UserJogos,ranking:UserRanking,final:UserFinal,todos:UserTodos,leilao:UserLeilao};
  const banner=!o&&view.userTab!=='final'?`<div class="closed-banner">🏁 Período de jogos encerrado — ${P.evento.ranking_visivel?'veja o resultado final na aba Resultado.':'o ranking final será revelado pelo organizador.'}</div>`:'';
  return Header({name:P.evento.nome,open:o},'Participante · '+esc(P.nome))+Nav(tabs,view.userTab,'user-tab')+`<main class="wrap main ${view.reveal?'':'hide-money'}">${banner}${map[view.userTab]()}</main>`;
}
function UserEu(){
  /* Pontos e colocação só vêm do servidor com o ranking liberado */
  const P=U.painel,g=grp(P.grupo),o=P.evento.aberto,w=walletU(),rv=!!P.evento.ranking_visivel;
  const scored=P.posicao!=null;
  const wins=(P.resultados||[]).slice().sort((a,b)=>a.colocacao-b.colocacao);
  return `<section class="card me-hero" style="--c:${g?g.color:'#6b5a85'}">${Av(P.nome,g,'lg')}<div><div class="eyebrow">Olá,</div><h2>${esc(P.nome)}</h2><span class="g-badge">${g?esc(g.icon+' Grupo '+g.name):'Sem grupo'}</span></div></section>
  ${rv?`<div class="tiles t3">${Tile(P.pontos,'Pontuação')}${Tile(P.vitorias,P.vitorias===1?'Vitória':'Vitórias')}${Tile(scored?P.posicao+'º'+(P.empate?' 🤝':''):'—',P.empate?'Posição final (empate)':'Posição final')}</div>`
      :`<div class="tiles t2">${Tile(P.vitorias,P.vitorias===1?'Vitória':'Vitórias')}${Tile(P.qtd_jogos,P.qtd_jogos===1?'Jogo':'Jogos')}</div>`}
  <section class="card private"><div class="card-h"><h3>🔒 Meu dinheiro</h3><span class="badge priv">Só você vê</span></div>
    ${Wallet(w)}
    <p class="muted small">Valor fictício ganho nas vitórias e colocações, que pode receber doações e é usado no leilão de caixas surpresa. Os outros participantes não veem.</p></section>
  ${o&&!w.moves.length?'':`<section class="card"><div class="card-h"><h3>🛍️ Como usei meu dinheiro</h3><span class="muted small">Gasto no leilão: <b class="mval spent">${BRL(w.spent)}</b></span></div>${MovesList(w)}</section>`}
  <section class="card"><div class="card-h"><h3>🏆 Minhas vitórias e colocações</h3></div>
    ${wins.length?`<ul class="mini">${wins.map(x=>`<li><span>${winIco(x.formato,x.colocacao)} ${TitleU(x.jogo,x.partida)}<small>${placeText(x.formato,x.colocacao)}${x.modo==='grupo'?' · com o grupo':''}</small></span><span class="mini-r">${rv&&x.pontos!=null?`<b>+${x.pontos} pts</b>`:''}<small class="mval">${BRL(x.premio)}</small></span></li>`).join('')}</ul>`:Empty('Nenhuma vitória ainda. Bora assombrar! 👻')}
  </section>`;
}
/* Meus jogos: só as regras (o servidor não manda resultado nem pontos) */
function RulesText(g){
  return `<span class="rules"><small>${g.formato==='colocacao'?'🥇 Vale 1º, 2º e 3º lugar':'🏆 Vale só a vitória (vencedor ou derrota)'}</small><small>${g.modo==='grupo'?'👥 Pontuação por grupo: todos do grupo recebem igual':'👤 Individual: cada pessoa pelo próprio resultado'}</small></span>`;
}
function UserJogos(){
  const games=U.jogos;
  return `<section class="card"><div class="card-h"><h3>🎲 Jogos que participei <span class="muted small">(${games.length})</span></h3></div>
    <p class="muted small" style="margin-bottom:12px">Regras de cada jogo de que você participa.</p>
    ${games.length?`<ul class="mini">${games.map(g=>`<li><span>${TitleU(g.nome,g.partida)}<small>${esc(g.tipo)}${g.descricao?' · '+esc(g.descricao):''}</small>${RulesText(g)}</span></li>`).join('')}</ul>`:Empty('Você ainda não foi incluído em nenhum jogo.')}
  </section>`;
}
/* Lista só com a quantidade de vitórias, sem colocação (ordem: vitórias, depois nome) */
function WinsList(linhas){
  if(!linhas.length)return Empty('Nenhum participante ainda.');
  return `<ol class="rank">${linhas.map(r=>{const g=grp(r.grupo),me=r.pessoa_id===U.painel.pessoa_id;return `<li class="rk ${me?'me':''}">${Av(r.nome,g)}<span class="rk-name"><span>${esc(r.nome)}${me?' <em>você</em>':''}</span><small>${GLabel(g)}</small></span><span class="rk-stats"><span class="cell"><b>${r.vitorias}</b><small>${r.vitorias===1?'vitória':'vitórias'}</small></span></span></li>`}).join('')}</ol>`;
}
const WINS_TEXT='Aqui aparece só a quantidade de vitórias de cada pessoa (1º lugar ou vencedor). As colocações e a pontuação são reveladas pelo organizador depois que os jogos terminarem.';
function UserRanking(){
  return `<section class="card"><div class="card-h"><h3>🏆 Vitórias</h3></div>
    <p class="muted small" style="margin-bottom:12px">${WINS_TEXT}</p>${WinsList(U.ranking.linhas)}</section>`;
}
function UserFinal(){
  if(!U.final)return Empty('Carregando o resultado final…');
  if(!U.final.visivel)return `<section class="card final-hero"><div class="eyebrow">Resultado final</div><h2 class="spooky">Fim dos jogos!</h2>
    <p>O organizador vai revelar o ranking final em breve. 🎃</p></section>
  <section class="card"><div class="card-h"><h3>🏆 Vitórias</h3></div><p class="muted small" style="margin-bottom:12px">${WINS_TEXT}</p>${WinsList(U.final.ranking)}</section>`;
  const rk=U.final.ranking.map(rankRow),me=rk.find(r=>r.pid===U.painel.pessoa_id);
  const frase=me&&me.scored?`Você ficou em <b>${me.pos}º lugar${me.tied?' (empatado)':''}</b> com <b>${me.points} pts</b> e ${me.wins} ${me.wins===1?'vitória':'vitórias'}.`:'Você não pontuou desta vez — obrigado por jogar! 👻';
  return `<section class="card final-hero"><div class="eyebrow">Resultado final</div><h2 class="spooky">Fim dos jogos!</h2><p>${frase}</p></section>
  <section class="card"><div class="card-h"><h3>🏆 Pódio</h3></div>${Podium(rk,'points')}</section>
  <section class="card"><div class="card-h"><h3>📋 Ranking geral</h3></div><p class="muted small" style="margin-bottom:12px">${TIE_TEXT.points}</p>${RankList(rk,{me:U.painel.pessoa_id})}</section>
  <section class="card"><div class="card-h"><h3>🏴 Grupos</h3></div>${GroupRank(U.final.grupos.map(grRow))}</section>`;
}
/* Caixas vêm de fn_leilao: das dos outros só número e "vendida"; das minhas, o conteúdo */
function UserLeilao(){
  if(!U.leilao)return Empty('Carregando o leilão…');
  const items=U.leilao.caixas.map(c=>({num:c.numero,sold:c.vendida,mine:c.minha,content:c.conteudo||''})),w=walletU();
  return `<section class="card private"><div class="card-h"><h3>🔒 Meu saldo para o leilão</h3><span class="badge priv">Só você vê</span></div>${Wallet(w)}</section>
  ${DonateCard(w)}
  <section class="card"><div class="card-h"><h3>🎁 Caixas surpresa</h3><span class="muted small">${items.filter(i=>!i.sold).length} de ${items.length} disponíveis</span></div>
    ${items.length?`<div class="boxes">${items.map(i=>`<div class="box ${i.sold?'sold':''} ${i.mine?'mine':''}">${BoxSVG()}${i.sold?`<span class="stamp">${i.mine?'É SUA!':'VENDIDO'}</span>`:''}<span class="box-num">${boxLabel(i)}</span><span class="box-sub">${i.mine?(i.content?'🎉 '+esc(i.content):'Arrematada por você'):(i.sold?'Vendida':'Disponível')}</span></div>`).join('')}</div>`:Empty('As caixas ainda não foram cadastradas.')}
  </section>
  <section class="card"><div class="card-h"><h3>🛍️ Como usei meu dinheiro</h3><span class="muted small">Gasto no leilão: <b class="mval spent">${BRL(w.spent)}</b></span></div>${MovesList(w)}</section>`;
}
/* Doar: lista só com os NOMES dos outros (de fn_leilao); quem doa é a pessoa do token */
function DonateCard(w){
  const others=(U.leilao.pessoas||[]);
  return `<section class="card"><div class="card-h"><h3>🤝 Doar dinheiro</h3><span class="muted small">Só dinheiro — a pontuação não muda</span></div>
    ${!others.length?Empty('Não há outros participantes.'):w.balance<=0?Empty('Você não tem saldo para doar.'):`
    <form data-form="donate" class="stack">
      <div class="two"><label class="fld">Para quem<select name="to" required><option value="">Escolha…</option>${others.map(o=>`<option value="${esc(o.id)}">${esc(o.nome)}</option>`).join('')}</select></label>
        <label class="fld">Valor (R$)<input name="amount" type="number" min="0.01" step="0.01" required placeholder="0,00"><span class="fld-hint">Você pode doar até <b class="mval">${BRL(w.balance)}</b></span></label></div>
      <label class="fld">Recado (opcional)<input name="note" maxlength="60" placeholder="Ex.: para você arrematar a caixa #05"></label>
      <div class="row end"><button class="btn primary" type="submit">Doar</button></div>
    </form>`}
  </section>`;
}
function UserTodos(){
  if(!U.final)return Empty('Carregando…');
  const list=U.final.jogos;
  return `<section class="card"><div class="card-h"><h3>🎲 Jogos e gincanas jogados</h3></div>
    ${list.length?`<div class="games-all">${list.map(g=>`<div class="ga"><div class="ga-h"><b>${TitleU(g.nome,g.partida)}</b><span class="badge">${esc(g.tipo)}</span></div>
      <div class="badges">${ModeBadges(g.modo,g.formato)}</div>
      ${g.pontuado?WinnersChips(g.formato,winnersFromServer(g.vencedores),!!U.final.visivel):'<small class="muted">Não foi pontuado</small>'}
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
    confirmBox('Encerrar o período de jogos?',`Os jogos deixam de aceitar cadastro e pontuação, o <b>leilão é liberado</b> e todos os participantes passam a ver todos os jogos jogados e os vencedores — sem os valores em dinheiro. As colocações e a pontuação continuam ocultas até você tocar em <b>Exibir ranking</b>.${n?`<br><br>⚠️ Ainda há <b>${n} jogo(s)</b> sem resultado.`:''}`,'Encerrar período de jogos',
      ()=>run(()=>rpc('fn_admin_encerrar'),'Período de jogos encerrado. Leilão liberado! 🎁'))},
  'ask-reopen-event':()=>{
    const sold=S.auction.items.filter(i=>i.sold),tot=round2(sold.reduce((a,i)=>a+i.price,0)),tr=S.transfers.length;
    const reopen=()=>run(()=>rpc('fn_admin_reabrir'),'Período de jogos reaberto.');
    if(!sold.length&&!tr)return confirmBox('Reabrir o período de jogos?','Os jogos voltam a ficar abertos e ativos, o ranking volta a ficar oculto para os participantes e o leilão fica bloqueado até você encerrar de novo.','Reabrir',reopen,false);
    confirmBox('⚠️ O leilão já começou',`Já existem ${sold.length?`<b>${sold.length} arremate(s)</b> (${BRL(tot)})`:''}${sold.length&&tr?' e ':''}${tr?`<b>${tr} doação(ões)</b>`:''}. Se reabrir o período de jogos:<br><br>
      • os arremates e doações feitos <b>continuam valendo</b>;<br>
      • novos arremates e doações ficam <b>bloqueados</b> até encerrar de novo;<br>
      • se você alterar ou registrar resultados, os <b>saldos mudam</b> — quem já gastou pode ficar com <b>saldo negativo</b>;<br>
      • os participantes deixam de ver o resultado final e a aba Leilão, e o ranking volta a ficar oculto.<br><br>Para desfazer um arremate, use "Desfazer venda" na caixa, sem reabrir.`,'Reabrir mesmo assim',reopen);
  },
  'new-game':()=>{if(!S.event.open)return toast('Período de jogos encerrado.');openModal('Novo jogo ou gincana',GameForm())},
  'open-game':(el,id)=>{view.adminTab='jogos';view.gameId=id;render();top()},
  'close-game':()=>{view.gameId=null;render();top()},
  'edit-game':()=>{const g=curGame();if(g)openModal('Editar jogo',GameForm(g))},
  'new-round':()=>{const g=curGame();if(!g||!S.event.open)return;
    run(async()=>{const id=await rpc('fn_admin_nova_partida',{p_jogo_id:g.id});view.gameId=id;top();
      return{msg:`Nova partida criada. ${g.mode==='grupo'?'Confira os grupos':'Escolha os participantes'} — a anterior ficou no histórico.`}})},
  'ask-delete-game':()=>{const g=curGame();if(!g)return;confirmBox('Excluir jogo?',`"${esc(titleText(g))}" e a pontuação registrada nele serão removidos.`,'Excluir',
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
  'ask-delete-person':(el,id)=>{const p=person(id);confirmBox('Excluir participante?',`${esc(p.name)} será removido de todos os jogos e rankings. Caixas arrematadas por essa pessoa voltam a ficar disponíveis e as doações dela são desfeitas.`,'Excluir',
    ()=>run(()=>q(sb.from('pessoa').delete().eq('id',id)),'Participante excluído.'))},
  'remove-from-group':(el,id)=>{const p=person(id);if(p)run(()=>q(sb.from('pessoa').update({grupo_id:null}).eq('id',id)),`${p.name} saiu do grupo.`)},
  'edit-group':(el,id)=>{const g=S.groups.find(x=>x.id===id);if(g)openModal('Editar grupo',GroupForm(g))},
  'ask-delete-group':(el,id)=>{const g=S.groups.find(x=>x.id===id);confirmBox('Excluir grupo?',`Os membros de "${esc(g.name)}" ficarão sem grupo. Pontos individuais são mantidos.`,'Excluir',
    ()=>run(()=>q(sb.from('grupo').delete().eq('id',id)),'Grupo excluído.'))},
  'open-box':(el,id)=>{const i=S.auction.items.find(x=>x.id===id);if(i)openModal('📦 '+boxLabel(i),BoxModal(i))},
  'save-box-content':(el,id)=>{const i=S.auction.items.find(x=>x.id===id);const f=el.closest('form');if(!i||!f)return;
    const c=f.elements.content.value.trim();closeModal();
    run(()=>q(sb.from('caixa').update({conteudo:c}).eq('id',i.id)),'Conteúdo salvo.')},
  'ask-undo-sale':(el,id)=>{const i=S.auction.items.find(x=>x.id===id);if(!i)return;const b=person(i.buyerId);
    confirmBox('Desfazer a venda?',`${boxLabel(i)} volta a ficar disponível e ${BRL(i.price)} voltam para o saldo de ${esc(b?b.name:'—')}.`,'Desfazer venda',
      ()=>run(()=>rpc('fn_admin_desfazer_venda',{p_caixa_id:i.id}),'Venda desfeita. Valor devolvido ao saldo.'))},
  'ask-delete-box':(el,id)=>{const i=S.auction.items.find(x=>x.id===id);if(!i)return;
    confirmBox('Excluir caixa?',`${boxLabel(i)} será removida do leilão.`,'Excluir',
      ()=>run(()=>q(sb.from('caixa').delete().eq('id',i.id)),'Caixa excluída.'))},
  'ask-undo-transfer':(el,id)=>{const t=S.transfers.find(x=>x.id===id);if(!t)return;const adm=t.from==='admin',a=adm?null:person(t.from),b=person(t.to);
    if(b&&walletOf(b.id).balance<t.amount)return toast(`${b.name} já usou parte desse valor. Desfaça antes o arremate ou a doação que usou o dinheiro.`);
    confirmBox(adm?'Desfazer o crédito do ADM?':'Desfazer a doação?',adm?`${BRL(t.amount)} serão retirados do saldo de ${esc(b?b.name:'—')}.`:`${BRL(t.amount)} voltam de ${esc(b?b.name:'—')} para ${esc(a?a.name:'—')}.`,'Desfazer',
      ()=>run(()=>rpc('fn_admin_desfazer_doacao',{p_id:t.id}),adm?'Crédito desfeito.':'Doação desfeita.'))},
  'ask-show-ranking':()=>{if(S.event.open)return toast('Encerre o período de jogos antes.');
    confirmBox('Exibir o ranking?','Todos os participantes passam a ver as <b>colocações</b>, a <b>pontuação</b>, o pódio e o placar dos grupos. O dinheiro de cada um continua privado.','Exibir ranking',
      ()=>run(()=>rpc('fn_admin_exibir_ranking',{p_visivel:true}),'Ranking liberado para os participantes 🏆'),false)},
  'hide-ranking':()=>run(()=>rpc('fn_admin_exibir_ranking',{p_visivel:false}),'Ranking oculto para os participantes.'),
  'new-event':()=>openModal('✨ Novo evento',`<form data-form="new-event" class="stack">
      <div class="notice">Apaga todos os dados do evento atual: jogos, partidas, resultados, caixas do leilão, arremates e doações. Não dá para desfazer.</div>
      <label class="fld">Nome do novo evento<input name="name" required maxlength="50" placeholder="Ex.: Gincana de Halloween 2027"></label>
      <label class="ck"><input type="checkbox" name="keepPeople" checked> Manter as pessoas cadastradas (nome e senha)</label>
      <label class="ck"><input type="checkbox" name="keepGroups" checked> Manter os grupos e quem está em cada um</label>
      <label class="ck"><input type="checkbox" name="ok" required> Entendo que os dados do evento atual serão apagados</label>
      <div class="row end gap"><button type="button" class="btn ghost" data-action="close-modal">Cancelar</button><button class="btn danger" type="submit">Criar novo evento</button></div>
    </form>`),
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
      /* Só a senha: o e-mail da conta do admin vem do banco (fn_email_admin);
         quem confere a senha continua sendo o Supabase Auth */
      const email=await rpc('fn_email_admin');
      if(!email)throw new Error('O administrador ainda não foi configurado no Supabase.');
      const{error}=await sb.auth.signInWithPassword({email,password:fd.senha||''});
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
  'new-event':fd=>{if(fd.ok!=='on')return toast('Confirme que os dados atuais serão apagados.');
    const name=(fd.name||'').trim();if(!name)return toast('Informe o nome do novo evento.');
    const keepP=fd.keepPeople==='on',keepG=fd.keepGroups==='on';
    const nP=keepP?S.people.length:0,nG=keepG?S.groups.length:0;
    closeModal();view={...view,gameId:null,adminTab:'painel'};
    run(()=>rpc('fn_admin_novo_evento',{p_nome:name,p_manter_pessoas:keepP,p_manter_grupos:keepG}),
      `Novo evento criado${keepP?` com ${nP} pessoa(s)`:''}${keepG?` e ${nG} grupo(s)`:''}.`).then(top)},
  /* Crédito do ADM: só a conta do admin consegue (o banco confere) */
  'admin-credit':fd=>{if(mode!=='admin')return;
    const b=person(fd.to),amount=round2(fd.amount),note=(fd.note||'').trim();
    if(!b)return toast('Escolha para quem creditar.');
    if(!(amount>0))return toast('Informe o valor.');
    run(()=>rpc('fn_admin_creditar',{p_para:b.id,p_valor:amount,p_motivo:note}),`${BRL(amount)} creditados para ${b.name} pelo ADM 🧙`)},
  /* Doação do participante: o banco identifica quem doa pelo token e confere período e saldo */
  'donate':fd=>{if(mode!=='user'||!U.leilao)return;
    const b=(U.leilao.pessoas||[]).find(x=>x.id===fd.to),amount=round2(fd.amount),note=(fd.note||'').trim(),w=walletU();
    if(!b)return toast('Escolha para quem doar.');
    if(!(amount>0))return toast('Informe o valor.');
    if(amount>w.balance)return toast(`Saldo insuficiente: você tem ${BRL(w.balance)}.`);
    confirmBox('Confirmar doação?',`Você vai doar <b>${BRL(amount)}</b> para <b>${esc(b.nome)}</b>${note?` com o recado "${esc(note)}"`:''}.<br><br>Depois de confirmar, só o organizador pode desfazer.`,'Doar',async()=>{
      if(busy)return;busy=true;document.body.classList.add('busy');
      let ok=false,sair=false;
      try{await rpc('fn_doar',{p_token:token,p_para:b.id,p_valor:amount,p_recado:note});ok=true}
      catch(e){if(/Sessão inválida/.test(e.message||'')){sair=true;token=null;lsSet(TOKEN_KEY,null)}else toast(msgErro(e))}
      busy=false;document.body.classList.remove('busy');
      if(sair)return irLogin('Sua sessão terminou. Entre de novo.');
      await refreshUser();if(ok)toast(`${BRL(amount)} doados para ${b.nome} 🤝`)},false)},
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
  'add-boxes':fd=>{const n=Math.min(50,Math.max(1,parseInt(fd.qty,10)||0));
    run(()=>rpc('fn_admin_adicionar_caixas',{p_qtd:n}),`${n} caixa(s) adicionada(s).`)},
  /* Arremate: o banco confere de novo evento encerrado, caixa disponível e saldo */
  'sell-box':fd=>{const i=S.auction.items.find(x=>x.id===fd.id);if(!i||i.sold)return;
    const content=(fd.content||'').trim();
    const salvaConteudo=()=>content!==i.content?q(sb.from('caixa').update({conteudo:content}).eq('id',i.id)):null;
    if(S.event.open){closeModal();run(salvaConteudo,'Caixa salva.');return}
    const p=person(fd.buyer),price=round2(fd.price);
    if(!p)return toast('Escolha quem arrematou.');
    if(!(price>0))return toast('Informe o valor arrematado.');
    const w=walletOf(p.id);
    if(price>w.balance)return toast(`Saldo insuficiente: ${p.name} tem ${BRL(w.balance)}.`);
    closeModal();
    run(async()=>{await salvaConteudo();await rpc('fn_admin_arrematar',{p_caixa_id:i.id,p_pessoa_id:p.id,p_valor:price})},
      `${boxLabel(i)} vendida para ${p.name} por ${BRL(price)} 🎁`)},
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
  'sale-preview':t=>salePreview(t.form),
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
document.addEventListener('input',e=>{if(e.target.dataset&&e.target.dataset.input==='sale-preview')salePreview(e.target.form)});
document.addEventListener('keydown',e=>{if(e.key==='Escape'&&$('#modal-root').innerHTML)closeModal()});
/* Participante: atualiza ao voltar para a página */
document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible')refreshUser()});

boot();
})();
