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
| Administrador | Cadastrar evento, jogos, pessoas, grupos e senhas; registrar resultados; encerrar/reabrir o período de jogos; leilão; criar novo evento; ver tudo de todos, inclusive dinheiro |
| Participante | Consultar: meu painel (grupo, pontos, vitórias, posição, saldo próprio), meus jogos, ranking; no leilão, **doar dinheiro** a outro participante (única ação dele) |

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

## Partidas (jogos repetidos)

- Botão **"↻ Nova partida"** no jogo: cria cópia com mesmo nome, tipo, formato, pontos e prêmios, **zerada** (sem participantes, sem resultado) e ativa. Em gincana por grupo, mantém os grupos escolhidos.
- Partidas do mesmo jogo compartilham um `serie_id` e têm `numero_partida` (1, 2, 3…). Exibição: "Quiz do Terror · Partida 2" (só quando a série tem mais de uma partida).
- Lista de jogos mostra só a partida mais recente de cada série; as anteriores ficam no **histórico** do jogo (participantes e vencedores de cada uma).
- Cada partida conta separadamente no ranking. Renomear uma partida renomeia todas da série.

## Ranking e empates

| Critério | Jogos abertos | Jogos encerrados |
| --- | --- | --- |
| 1º | mais vitórias | mais pontos |
| 2º | mais pontos | mais vitórias |

- **Sem desempate por horário.** Iguais nos dois critérios = **mesma colocação** (etiqueta "empate"); a colocação seguinte é a próxima (1º, 2º, 2º, 3º — `DENSE_RANK`). No pódio, empatados dividem o degrau.
- Quem empatou no 1º critério e foi separado pelo 2º mostra a etiqueta "no desempate".
- Quem não pontuou aparece sem posição. Admin vê a mesma ordem que os participantes.
- Durante os jogos, o ranking do participante mostra só vitórias (sem pontos e sem dinheiro).
- Ranking de grupos: pontos, depois vitórias, mesma regra de empate.

## Período de jogos

- Flag aberto/encerrado. Controle na **aba Leilão**: botões **"Encerrar período de jogos"** / **"Reabrir período de jogos"**. O Painel só mostra o status e um atalho para o Leilão.
- Aberto: admin cadastra e pontua; leilão e transferências bloqueados; participante vê os próprios dados e o ranking por vitórias.
- Encerrado: admin não cadastra nem pontua; leilão e transferências liberados; participante vê ranking geral com pontos, pódio, placar de grupos, todos os jogos com vencedores e a aba Leilão — nunca o dinheiro dos outros.
- **Reabrir com leilão iniciado** (há arremates ou transferências): exigir confirmação explicando que arremates/transferências continuam valendo, novos ficam bloqueados até encerrar de novo e que alterar resultados muda saldos (pode ficar negativo). Para corrigir arremate, usar "Desfazer venda".

## Leilão de caixas surpresa

Ao final dos jogos, o dinheiro fictício vira saldo para um leilão de caixas surpresa.
**Saldo = ganho nos jogos + doações recebidas − doações feitas − gasto no leilão.**

- Admin cadastra caixas em lote, numeradas em sequência (#01, #02…), exibidas como caixa de papelão surrada com "?" (ver `BoxSVG()` no protótipo). Conteúdo opcional por caixa, visível só ao admin antes da venda.
- Admin registra o arremate: escolhe quem arrematou e o valor; a tela mostra saldo antes/depois.
- Arremate só com **período de jogos encerrado** e valor **≤ saldo**. Ao salvar: selo **VENDIDO** e o valor sai do saldo.
- Admin pode desfazer a venda (valor volta ao saldo) e excluir caixas não vendidas; vê ganho, doações, gasto e saldo de todos.
- Participante (jogos encerrados) tem a aba **Leilão**: vê todas as caixas, vendidas e as suas ("É SUA!"); não vê comprador nem preço das caixas dos outros; descobre o conteúdo só das que arrematou.

## Doações entre participantes

- **Quem doa é o próprio participante** (não o admin): na aba Leilão escolhe para quem, quanto e um recado opcional; confirma num modal. Só com período de jogos encerrado. **Só dinheiro**: pontos, vitórias e ranking não mudam.
- Valor ≤ saldo de quem doa. O participante vê só os nomes dos outros, nunca o saldo deles.
- O participante não desfaz a doação. O admin vê todas as doações e pode desfazer uma, desde que quem recebeu ainda tenha esse saldo.
- Participante vê em **Meu dinheiro** (saldo; ganhei nos jogos; recebi; doei; gastei no leilão) e **Como usei meu dinheiro**: extrato com arremates e doações feitas/recebidas (nome da outra pessoa, recado, horário, valor) e total gasto no leilão. Mesma regra de privacidade do prêmio.
- Implementação: `fn_doar(token, para, valor, recado)` identifica quem doa **pelo token de sessão**, nunca por parâmetro vindo do navegador. Arremate e doação conferem, na mesma transação, período encerrado + saldo suficiente (e caixa disponível, com lock da linha, no arremate). Saldo é calculado, nunca guardado em coluna. A função do participante só devolve o conteúdo das caixas que ele arrematou.

## Novo evento

- Botão **"✨ Novo evento"** no Painel (admin): apaga jogos, partidas, resultados, caixas, arremates e doações e cria um evento novo, aberto, com o nome informado.
- Opções (marcadas por padrão): **manter as pessoas cadastradas** (nome e senha) e **manter os grupos** com seus membros. Sem grupos, as pessoas mantidas ficam sem grupo.
- Exige marcar "Entendo que os dados do evento atual serão apagados". Não dá para desfazer.

## Stack e arquitetura

- Banco: Supabase (PostgreSQL). Migrações versionadas em SQL (`supabase/migrations/`).
- Front-end: página estática (HTML/CSS/JS, sem build obrigatório) usando `@supabase/supabase-js`; hospedagem gratuita (Netlify, Vercel ou GitHub Pages).
- Tabelas: evento, grupo, pessoa (com hash da senha), jogo, jogo_grupo, participacao, resultado (colocação, pontos, prêmio, horário), caixa (número, conteúdo, arrematante, valor, horário da venda), transferencia (de, para, valor, motivo, horário). `jogo` tem `serie_id` e `numero_partida`.
- **Participantes não têm conta no Supabase.** Uma função do banco confere participante + senha e devolve um token de sessão; as demais funções (ex.: `fn_meu_painel`, `fn_ranking`) exigem o token.
- **Acesso do participante só por funções** (RPC, `security definer`), nunca leitura direta das tabelas. RLS ligado em todas as tabelas; a role `anon` só tem EXECUTE nas funções públicas.
- Período de jogos e privacidade do dinheiro são aplicados dentro das funções.
- Projetos Supabase novos exigem GRANT explícito para tabelas/funções expostas pela API.
- Chave `service_role` nunca vai para o front-end nem para o repositório; usar só a chave pública (anon/publishable) no navegador.

## Pontos em aberto

- Senha: uma por pessoa (recomendado) ou a mesma para todos? Formato (só dígitos ou alfanumérica)?
- Data do evento (o plano gratuito do Supabase pausa projetos após 7 dias sem acesso).
