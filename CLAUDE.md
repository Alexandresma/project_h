# Gincana de Halloween

Aplicação web, responsiva para celular, para organizar uma gincana de Halloween. Um administrador cadastra jogos, pessoas e grupos e registra resultados; os participantes acompanham seus jogos, vitórias, pontuação e o ranking.

- Protótipo de referência (comportamento e visual esperados): `prototipo/index.html`. Abrir no navegador; PIN do admin no protótipo: 1234.
- Documentação completa: https://claude.ai/artifact/Af1oVQft6GNSQj1ZYgSMiA
- Idioma de toda a interface e dos textos: português do Brasil.

## Regras que não podem ser quebradas

1. **Participante não se cadastra nem cria conta.** Não existe tela de "Criar conta", "Cadastre-se" ou "Esqueci a senha". O administrador cadastra cada participante (nome, grupo, senha). O participante abre o link, toca no próprio nome e digita a senha que o administrador definiu.
2. **Senha do participante**: definida e redefinida só pelo administrador; guardada como hash (nunca texto puro); senha errada mostra só "Senha incorreta"; bloqueio temporário após várias tentativas erradas; sessão fica salva no navegador até "Sair".
3. **Prêmio em dinheiro (fictício) é privado**: cada participante vê só o próprio valor; o administrador vê o de todos. O servidor nunca envia ao navegador de um participante o dinheiro de outra pessoa — esconder só na tela não basta.
4. **Um único administrador**, com login próprio (Supabase Auth, e-mail e senha), separado da lista de participantes.

## Perfis

| Perfil | Pode |
| --- | --- |
| Administrador | Cadastrar evento, jogos, pessoas, grupos e senhas; registrar resultados; encerrar/reabrir o evento; ver tudo de todos, inclusive dinheiro |
| Participante | Só consultar: meu painel (grupo, pontos, vitórias, posição, prêmio próprio), meus jogos, ranking |

## Pontuação

Cada jogo tem um formato = quem pontua × como registra:

| | Vencedor | 1º, 2º e 3º lugar |
| --- | --- | --- |
| Individual | marca quem venceu | colocação por pessoa |
| Por grupo | marca o grupo vencedor | colocação por grupo |

- Pontos e prêmio definidos por vitória ou por colocação; o admin pode ajustar por pessoa/grupo ao registrar.
- Empates de colocação são permitidos.
- Vitória = 1º lugar. 2º e 3º somam pontos e prêmio, mas não contam como vitória.
- Por grupo: todos os membros recebem a mesma pontuação e prêmio. No ranking de grupos a gincana conta uma vez para o grupo.
- Mudar o formato de um jogo com resultado apaga o resultado.
- Cada resultado guarda o horário em que foi registrado (usado no desempate).

## Ranking e desempate

| Critério | Evento aberto | Evento encerrado |
| --- | --- | --- |
| 1º | mais vitórias | mais pontos |
| 2º | mais pontos | mais vitórias |
| 3º | quem chegou primeiro à pontuação atual | idem |

- Só divide a posição quando todos os critérios são iguais; mostrar "empate" para os envolvidos.
- Quem foi separado pelos critérios 2 ou 3 mostra a etiqueta "no desempate".
- Quem não pontuou aparece sem posição.
- Admin vê a mesma ordem que os participantes.
- Durante o evento, o ranking do participante mostra só vitórias (sem pontos e sem dinheiro).

## Status do evento

- Aberto: admin cadastra e pontua; participante vê os próprios dados e o ranking por vitórias.
- Encerrado: admin não cadastra nem pontua até reabrir; participante vê ranking geral com pontos, pódio, placar de grupos e todos os jogos com vencedores e pontuação — nunca o dinheiro dos outros.

## Leilão de caixas surpresa

Ao final dos jogos, o dinheiro fictício ganho vira saldo para um leilão de caixas surpresa. **Saldo = ganho nos jogos − gasto no leilão.**

- Admin cadastra caixas em lote, numeradas em sequência (#01, #02…), exibidas como caixa de papelão surrada com "?" (ver `BoxSVG()` no protótipo). Conteúdo opcional por caixa, visível só ao admin antes da venda.
- Admin registra o arremate: escolhe quem arrematou e o valor; a tela mostra saldo antes/depois.
- Arremate só é aceito com o **evento encerrado** e se o valor **≤ saldo** da pessoa. Ao salvar: caixa recebe selo **VENDIDO** e o valor sai do saldo.
- Admin pode desfazer a venda (valor volta ao saldo) e excluir caixas não vendidas; vê ganho, gasto e saldo de todos.
- Participante (evento encerrado) tem a aba **Leilão**: vê todas as caixas, quais estão vendidas e as suas ("É SUA!"); não vê comprador nem preço das caixas dos outros; descobre o conteúdo só das caixas que arrematou.
- No painel do participante: **Meu dinheiro** (saldo, ganho, gasto) e **Como gastei** (cada caixa: conteúdo, horário, valor; total gasto). Mesma regra de privacidade do prêmio.
- Implementação: o arremate é uma função do banco que, na mesma transação, confere evento encerrado + caixa disponível (com lock da linha) + saldo suficiente. Saldo é calculado (ganhos − arremates), nunca guardado em coluna. A função do participante só devolve o conteúdo das caixas que ele arrematou.

## Stack e arquitetura

- Banco: Supabase (PostgreSQL). Migrações versionadas em SQL (`supabase/migrations/`).
- Front-end: página estática (HTML/CSS/JS, sem build obrigatório) usando `@supabase/supabase-js`; hospedagem gratuita (Netlify, Vercel ou GitHub Pages).
- Tabelas: evento, grupo, pessoa (com hash da senha), jogo, jogo_grupo, participacao, resultado (colocação, pontos, prêmio, horário), caixa (número, conteúdo, arrematante, valor, horário da venda).
- **Participantes não têm conta no Supabase.** Uma função do banco confere participante + senha e devolve um token de sessão; as demais funções (ex.: `fn_meu_painel`, `fn_ranking`) exigem o token.
- **Acesso do participante só por funções** (RPC, `security definer`), nunca leitura direta das tabelas. RLS ligado em todas as tabelas; a role `anon` só tem EXECUTE nas funções públicas.
- Status do evento e privacidade do prêmio são aplicados dentro das funções.
- Projetos Supabase novos exigem GRANT explícito para tabelas/funções expostas pela API.
- Chave `service_role` nunca vai para o front-end nem para o repositório; usar só a chave pública (anon/publishable) no navegador.

## Pontos em aberto

- Senha: uma por pessoa (recomendado) ou a mesma para todos? Formato (só dígitos ou alfanumérica)?
- Data do evento (o plano gratuito do Supabase pausa projetos após 7 dias sem acesso).
