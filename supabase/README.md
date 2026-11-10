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

   (Quem tiver a CLI pode usar `npx supabase link` + `npx supabase db push`.)

## 2. Fechar o cadastro e criar o administrador

1. **Authentication → Sign In / Providers**: desligue **Allow new users to sign up**. Ninguém se cadastra; o participante nem usa o Auth.
2. **Authentication → Users → Add user**: crie o administrador (e-mail e senha).
3. No SQL Editor, marque esse usuário como o administrador:

   ```sql
   insert into public.admin (user_id)
   select id from auth.users where email = 'EMAIL-DO-ADMIN';
   ```

## 3. Teste de privacidade (SQL)

Cole `tests/privacidade.sql` inteiro no SQL Editor e rode.

- ✅ `ERROR: TESTES OK: 140 verificações passaram…` → passou. Aparece como **erro de propósito**: é assim que o Postgres desfaz tudo o que o teste gravou.
- ❌ `ERROR: FALHOU: …` → diz qual regra quebrou. Nada fica gravado.

Durante o teste ele apaga e recria dados dentro de uma transação que sempre é desfeita. Seus dados reais voltam intactos, mas **não rode durante o evento** (as tabelas ficam travadas por alguns segundos).

O que ele verifica:

- `anon` (navegador do participante) não lê nenhuma tabela nem executa funções internas ou de admin.
- Usuário do Auth que não é o admin não vê nada. Nem o admin lê `senha_hash`.
- **Para cada participante**, com o evento aberto e encerrado: nenhum valor de prêmio de outra pessoa ou de grupo aparece em nada que as funções devolvem (busca no texto do JSON). O prêmio próprio vem certo.
- Ranking sem prêmio; com o evento aberto, também sem pontos.
- Senha guardada como bcrypt; senha errada → só "Senha incorreta"; bloqueio após 5 erros; redefinir senha desbloqueia e derruba sessões; "Sair" invalida o token.
- Ordem do ranking e desempate (aberto e encerrado), empate dividido, "no desempate", quem não pontuou fica sem posição; o admin vê a mesma ordem.
- Jogo por grupo: todos os membros iguais e conta uma vez no placar de grupos.
- Evento encerrado bloqueia cadastro e pontuação; reabrir libera.
- Mudar o formato apaga o resultado.

### Teste do leilão (SQL)

Depois da migração 5, cole `tests/leilao.sql` inteiro e rode. Passou → `ERROR: TESTES OK (leilão): 50 verificações passaram…` (também é erro de propósito, nada fica gravado).

Verifica: caixas numeradas em sequência; admin não vende nem cria caixa por fora das funções; arremate recusado com evento aberto, acima do saldo, valor ≤ 0 ou com mais de 2 casas; caixa vendida não é vendida de novo nem excluída; desfazer devolve o saldo; saldo = ganho − gasto; `anon` não lê `caixa` nem executa as funções de admin; **para cada participante**, nenhum valor, saldo ou conteúdo de caixa de outra pessoa aparece no que as funções devolvem; o participante vê o conteúdo só das caixas dele; leilão some com o evento aberto; excluir uma pessoa devolve as caixas dela.

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
| | `fn_meu_painel(p_token)` | meus pontos, vitórias, posição, **meu prêmio**, meu saldo (ganho, gasto, saldo), meus arremates, meus resultados |
| | `fn_meus_jogos(p_token)` | meus jogos e meu resultado em cada um |
| | `fn_ranking(p_token)` | ranking (aberto: só vitórias; encerrado: + pontos) |
| | `fn_resultado_final(p_token)` | só encerrado: ranking, grupos, jogos e vencedores |
| | `fn_leilao(p_token)` | só encerrado: caixas (número, vendida, minha); conteúdo/valor só das minhas |
| Admin (Auth) | `fn_is_admin()` | sou o admin? |
| | `fn_admin_definir_senha(p_pessoa_id, p_senha)` | 4 a 6 dígitos |
| | `fn_admin_desbloquear(p_pessoa_id)` | — |
| | `fn_admin_registrar_resultado(p_jogo_id, p_itens)` | regrava o resultado do jogo |
| | `fn_admin_limpar_resultado(p_jogo_id)` | volta a "aguardando" |
| | `fn_admin_encerrar()` / `fn_admin_reabrir()` | — |
| | `fn_admin_ranking()` / `fn_admin_placar_grupos()` | com prêmio de todos |
| | `fn_admin_adicionar_caixas(p_qtd)` | 1 a 50 caixas, numeradas em sequência |
| | `fn_admin_arrematar(p_caixa_id, p_pessoa_id, p_valor)` | só encerrado e valor ≤ saldo; devolve saldo antes/depois |
| | `fn_admin_desfazer_venda(p_caixa_id)` | caixa volta a ficar disponível |

Cadastro de grupos, pessoas, jogos e participantes: o admin grava direto nas tabelas (RLS só deixa o admin). Em `pessoa`, liste as colunas (`select('id,nome,grupo_id,bloqueado_ate')`), nunca `select('*')`: `senha_hash` não é legível.
