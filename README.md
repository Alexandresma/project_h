# Gincana de Halloween

App web (celular primeiro) para organizar a gincana. Página estática — HTML, CSS e JS, sem build — falando com o Supabase.

| Arquivo | O que é |
| --- | --- |
| `index.html`, `styles.css`, `app.js` | o app |
| `config.js` | URL e chave **pública** do Supabase |
| `supabase/` | banco: migrações, teste de privacidade e passo a passo ([supabase/README.md](supabase/README.md)) |
| `tests/api-smoke.mjs` | teste pela API com a chave pública |
| `prototipo/index.html` | protótipo de referência (dados só no navegador; PIN 1234) |

## Rodar

1. Banco pronto e testado: siga [supabase/README.md](supabase/README.md) (migrações 1 a 10).
2. Em `config.js`, cole a **Project URL** e a chave **publishable** (ou anon) de *Project Settings → API Keys*. Nunca a secret/service_role — o app se recusa a abrir com ela.
3. Sirva a pasta e abra no navegador:

   ```powershell
   npx serve .
   ```

   (Abrir o `index.html` direto do disco também funciona na maioria dos navegadores.)

## Publicar no GitHub Pages

1. Crie um repositório vazio no GitHub (sem README).
2. Na pasta do projeto:

   ```powershell
   git remote add origin https://github.com/SEU-USUARIO/SEU-REPOSITORIO.git
   git push -u origin main
   ```

3. No GitHub: **Settings → Pages → Build and deployment → Source: Deploy from a branch**, branch `main`, pasta `/ (root)`, **Save**. Em 1–2 minutos o app fica em `https://SEU-USUARIO.github.io/SEU-REPOSITORIO/`.

O repositório fica público no plano gratuito: tudo nele é visível (inclusive as migrações SQL e o `config.js`). Isso é esperado — a segurança está no banco (RLS e funções), e a chave do `config.js` é a pública. Nunca faça commit da chave secret/service_role.

Para atualizar o site depois: `git add -A`, `git commit -m "..."`, `git push`.

## Como entrar

- **Administrador**: só a senha do usuário criado no Supabase Auth e marcado na tabela `admin` (o app busca o e-mail dessa conta no banco).
- **Ranking**: os participantes veem só a quantidade de vitórias até o admin encerrar o período de jogos e tocar em "🏆 Exibir ranking" (aba *Ranking* ou *Painel*). Reabrir o período volta a ocultar. Em "Meus jogos" o participante vê só as regras de cada jogo.
- **Crédito do ADM**: na aba *Leilão*, o admin dá qualquer valor a um participante, sem tirar de ninguém (só dinheiro). O participante vê como "Crédito do ADM".
- **Período de jogos e leilão**: o admin encerra/reabre o período de jogos no topo da aba *Leilão*. Cadastra as caixas ali (dá para fazer antes) e, com o período encerrado, registra cada arremate. Saldo = ganho nos jogos + créditos do ADM + doações recebidas − doações feitas − gasto no leilão; o banco recusa valor acima do saldo.
- **Doações / apostas**: a qualquer momento (jogos abertos ou encerrados) o participante doa parte do saldo a outro — ex.: quem perde uma aposta paga quem ganhou. Com os jogos abertos o formulário fica em *Meu painel*; encerrado, na aba *Leilão* (só dinheiro; pontos não mudam). O admin acompanha e pode desfazer na aba *Leilão*.
- **Partidas**: no jogo, "↻ Nova partida" cria uma cópia zerada; as anteriores ficam no histórico e cada uma conta no ranking.
- **Novo evento**: no *Painel*, "✨ Novo evento" apaga jogos, resultados, caixas e doações e começa outro evento (pode manter pessoas e grupos). Não dá para desfazer.
- **Participante**: toca no próprio nome e digita a senha (4 a 6 dígitos) que o administrador definiu em *Pessoas → toque no nome → Senha de acesso*. Fica conectado até tocar em "Sair".
