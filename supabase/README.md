# Banco da Gincana (Supabase)

Fase 1: só o banco. As telas serão ligadas depois que os testes abaixo passarem no projeto real.

## 1. Criar o projeto e aplicar as migrações

1. Crie um projeto em https://supabase.com (plano gratuito).
2. Em **SQL Editor**, cole e rode **em ordem**, um arquivo por vez:
   1. `migrations/20261110000001_schema.sql`
   2. `migrations/20261110000002_funcoes.sql`
   3. `migrations/20261110000003_permissoes.sql`
   4. `migrations/20261110000004_tem_senha.sql` (o admin vê quem já tem senha)
   5. `migrations/20261110000005_leilao.sql` (leilão de caixas surpresa)
   6. `migrations/20261111000006_partidas_doacoes.sql` (partidas, empates sem horário, doações e novo evento)
   7. `migrations/20261111000007_ranking_oculto_credito.sql` (ranking oculto até o admin exibir, "Meus jogos" só com regras, crédito do ADM e login do admin só com a senha)
   8. `migrations/20261112000008_permissoes_funcoes.sql` (refaz o EXECUTE de todas as funções: `fn_admin_*` só para `authenticated`, funções do participante para `anon`, internas para ninguém; no fim confere tudo e dá erro se algo estiver fora da regra — inclusive se alguma `fn_admin_*` não começar checando o admin)
   9. `migrations/20261112000009_doacoes_abertas.sql` (doações entre participantes liberadas também com os jogos abertos — apostas)
   10. `migrations/20261112000010_politicas_rls.sql` (recria as políticas RLS exatamente como no projeto, todas com `fn_is_admin`, e remove as que não são do projeto; o resultado mostra as removidas)

   (Quem tiver a CLI pode usar `npx supabase link` + `npx supabase db push`.)

## 2. Fechar o cadastro e criar o administrador

1. **Authentication → Sign In / Providers**: desligue **Allow new users to sign up**. Ninguém se cadastra; o participante nem usa o Auth.
2. **Authentication → Users → Add user**: crie o administrador (e-mail e senha). No app, o admin entra **só com a senha**: o app busca o e-mail dessa conta no banco (`fn_email_admin`). Esse e-mail fica consultável por qualquer pessoa com a chave pública; se preferir, use um e-mail que não seja o pessoal (ex.: `admin@gincana.app`, marcando *Auto Confirm User*). Use uma senha forte.
3. No SQL Editor, marque esse usuário como o administrador:

   ```sql
   insert into public.admin (user_id)
   select id from auth.users where email = 'EMAIL-DO-ADMIN';
   ```

## 3. Teste de privacidade (SQL)

Cole `tests/privacidade.sql` inteiro no SQL Editor e rode.

- ✅ `ERROR: TESTES OK: 162 verificações passaram…` → passou. Aparece como **erro de propósito**: é assim que o Postgres desfaz tudo o que o teste gravou.
- ❌ `ERROR: FALHOU: …` → diz qual regra quebrou. Nada fica gravado.

Durante o teste ele apaga e recria dados dentro de uma transação que sempre é desfeita. Seus dados reais voltam intactos, mas **não rode durante o evento** (as tabelas ficam travadas por alguns segundos).

O que ele verifica:

- `anon` (navegador do participante) não lê nenhuma tabela nem executa funções internas ou de admin.
- Usuário do Auth que não é o admin não vê nada. Nem o admin lê `senha_hash`.
- **Para cada participante**, com o evento aberto e encerrado: nenhum valor de prêmio de outra pessoa ou de grupo aparece em nada que as funções devolvem (busca no texto do JSON). O prêmio próprio vem certo.
- Ranking sem prêmio; com o ranking oculto, sem pontos nem colocação (no ranking, no painel e no resultado final); "Meus jogos" só com as regras.
- Senha guardada como bcrypt; senha errada → só "Senha incorreta"; bloqueio após 5 erros; redefinir senha desbloqueia e derruba sessões; "Sair" invalida o token.
- Ordem do ranking do admin (aberto: vitórias → pontos; encerrado: pontos → vitórias); iguais nos dois dividem a colocação e a seguinte é a próxima (1º, 2º, 2º, 3º); o horário não desempata; "no desempate"; quem não pontuou fica sem posição. O participante, com o ranking oculto, vê só as vitórias (ordem: vitórias → nome); depois de "Exibir ranking", a mesma ordem do admin.
- Jogo por grupo: todos os membros iguais e conta uma vez no placar de grupos.
- Período de jogos encerrado bloqueia cadastro e pontuação; reabrir libera.
- Mudar o formato apaga o resultado.

### Teste do leilão (SQL)

Depois da migração 10, cole `tests/leilao.sql` inteiro e rode. Passou → `ERROR: TESTES OK (leilão): 50 verificações passaram…` (também é erro de propósito, nada fica gravado).

Verifica: caixas numeradas em sequência; admin não vende nem cria caixa por fora das funções; arremate recusado com evento aberto, acima do saldo, valor ≤ 0 ou com mais de 2 casas; caixa vendida não é vendida de novo nem excluída; desfazer devolve o saldo; saldo = ganho − gasto; `anon` não lê `caixa` nem executa as funções de admin; **para cada participante**, nenhum valor, saldo ou conteúdo de caixa de outra pessoa aparece no que as funções devolvem; o participante vê o conteúdo só das caixas dele; leilão some com o evento aberto; excluir uma pessoa devolve as caixas dela.

### Teste de doações, partidas e novo evento (SQL)

Depois da migração 10, cole `tests/doacoes_partidas.sql` inteiro e rode. Passou → `ERROR: TESTES OK (doações e partidas): 72 verificações passaram…` (erro de propósito, nada fica gravado).

Verifica: nova partida copia o jogo zerado (sem participantes nem resultado), mantém os grupos e numera em sequência; renomear renomeia a série; série só pela função; cada partida conta no ranking; o número da partida só aparece quando a série tem mais de uma; doação aceita com os jogos abertos (e depois de reabrir), com saldo conferido e visível para quem recebeu; recusada para si mesmo, acima do saldo, valor ≤ 0, com mais de 2 casas ou recado longo; quem doa é a pessoa do token; saldo = ganho + recebido − doado − gasto; doação não muda pontos; doação já gasta não pode ser desfeita; admin lê mas não grava doações direto; `anon` não lê `transferencia` nem executa funções internas/de admin; **para cada participante**, nenhum saldo, doação ou recado de outra pessoa aparece no que as funções devolvem e a lista para doar tem só id e nome; novo evento apaga jogos, resultados, caixas e doações, mantendo (ou não) pessoas com senha e grupos.

### Teste de ranking oculto e crédito do ADM (SQL)

Depois da migração 10, cole `tests/ranking_credito.sql` inteiro e rode. Passou → `ERROR: TESTES OK (ranking oculto e crédito): 45 verificações passaram…` (erro de propósito, nada fica gravado).

Verifica: `anon` e quem não é admin não executam `fn_admin_exibir_ranking` nem `fn_admin_creditar`; `fn_email_admin` devolve o e-mail da conta do admin; com o ranking oculto, a lista de vitórias não tem pontos nem colocação e a ordem não muda quando os pontos mudam; painel sem pontos/posição; "Meus jogos" só com as regras; "Exibir ranking" recusado com o período aberto (e, mesmo com a flag ligada, nada aparece com o período aberto); crédito do ADM recusado com valor ≤ 0, mais de 2 casas, acima de R$ 1.000.000 ou para pessoa inexistente; crédito gravado com origem admin e sem quem doa; crédito não muda pontos; saldo = ganho + crédito + recebido − doado − gasto; extrato mostra "crédito" sem nome; outro participante não vê o crédito; vencedores sem pontos enquanto oculto; crédito já usado não pode ser desfeito; depois de exibir: pontos, posição e pódio, sem dinheiro de ninguém; ocultar, reabrir e novo evento voltam a ocultar.

## 4. Teste pela API (o que o navegador realmente recebe)

Crie uma pessoa de teste (SQL Editor; depois do passo 2):

```sql
do $$
declare v uuid;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', (select user_id from public.admin limit 1))::text, true);
  set local role authenticated;
  insert into public.pessoa (nome) values ('Teste API') returning id into v;
  perform public.fn_admin_definir_senha(v, '4321');
end $$;
```

Pegue a URL e a chave **pública** em **Project Settings → API Keys** (publishable ou anon; nunca a secret/service_role) e rode na raiz do projeto (PowerShell):

```powershell
$env:SUPABASE_URL="https://SEU-PROJETO.supabase.co"
$env:SUPABASE_ANON_KEY="sb_publishable_..."
$env:TESTE_NOME="Teste API"
$env:TESTE_SENHA="4321"
node tests/api-smoke.mjs
```

Depois apague a pessoa de teste: `delete from public.pessoa where nome = 'Teste API';`

## Referência rápida das funções

| Quem | Função | Devolve |
| --- | --- | --- |
| Participante | `fn_lista_login()` | evento + nomes e grupos |
| | `fn_entrar(p_pessoa_id, p_senha)` | `{token}` ou `{erro}` |
| | `fn_sair(p_token)` | — |
| | `fn_email_admin()` | e-mail da conta do admin (para o login só com senha) |
| | `fn_meu_painel(p_token)` | minhas vitórias, **meu prêmio**, meu saldo (ganho, crédito do ADM, recebido, doado, gasto, saldo), meus arremates, minhas doações e créditos, meus resultados; pontos e posição só com o ranking liberado |
| | `fn_meus_jogos(p_token)` | só as regras dos meus jogos (nome, partida, tipo, descrição, modo, formato) |
| | `fn_ranking(p_token)` | oculto: só nome, grupo e vitórias (ordem vitórias → nome); liberado: + posição e pontos |
| | `fn_resultado_final(p_token)` | só encerrado: oculto → lista de vitórias e vencedores sem pontos; liberado → ranking, grupos, jogos e vencedores com pontos |
| | `fn_leilao(p_token)` | só encerrado: caixas (número, vendida, minha); conteúdo/valor só das minhas; nomes dos outros (para doar) |
| | `fn_doar(p_token, p_para, p_valor, p_recado)` | jogos abertos ou encerrados; valor ≤ meu saldo; quem doa = pessoa do token |
| Admin (Auth) | `fn_is_admin()` | sou o admin? |
| | `fn_admin_definir_senha(p_pessoa_id, p_senha)` | 4 a 6 dígitos |
| | `fn_admin_desbloquear(p_pessoa_id)` | — |
| | `fn_admin_registrar_resultado(p_jogo_id, p_itens)` | regrava o resultado do jogo |
| | `fn_admin_limpar_resultado(p_jogo_id)` | volta a "aguardando" |
| | `fn_admin_encerrar()` / `fn_admin_reabrir()` | — (reabrir volta a ocultar o ranking) |
| | `fn_admin_exibir_ranking(p_visivel)` | exibe/oculta o ranking para os participantes (exibir só com o período encerrado) |
| | `fn_admin_creditar(p_para, p_valor, p_motivo)` | crédito do ADM: dinheiro para um participante, sem tirar de ninguém |
| | `fn_admin_ranking()` / `fn_admin_placar_grupos()` | com prêmio de todos |
| | `fn_admin_adicionar_caixas(p_qtd)` | 1 a 50 caixas, numeradas em sequência |
| | `fn_admin_arrematar(p_caixa_id, p_pessoa_id, p_valor)` | só encerrado e valor ≤ saldo; devolve saldo antes/depois |
| | `fn_admin_desfazer_venda(p_caixa_id)` | caixa volta a ficar disponível |
| | `fn_admin_desfazer_doacao(p_id)` | desfaz doação ou crédito do ADM, só se quem recebeu ainda tem o valor |
| | `fn_admin_nova_partida(p_jogo_id)` | id da nova partida (cópia zerada) |
| | `fn_admin_novo_evento(p_nome, p_manter_pessoas, p_manter_grupos)` | apaga o evento atual e começa outro, aberto |

Cadastro de grupos, pessoas, jogos e participantes: o admin grava direto nas tabelas (RLS só deixa o admin). Em `pessoa`, liste as colunas (`select('id,nome,grupo_id,bloqueado_ate')`), nunca `select('*')`: `senha_hash` não é legível.
