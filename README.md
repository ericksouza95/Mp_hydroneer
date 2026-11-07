# Hydroneer Online Co-op (Mp_hydroneer)

Projeto comunitário, aberto, para levar co-op online ao Hydroneer usando a rede da Steam para hospedar as partidas, sem abrir porta e sem servidor dedicado.

**Estado atual:** fase de pesquisa e desenho. Nenhum código jogável ainda. Toda a investigação, as decisões e a arquitetura estão em [docs/](docs/).

## Por que isso é difícil

O desenvolvedor do Hydroneer afirma que a física do jogo torna o multiplayer convencional inviável, e entrega apenas split-screen local e Steam Remote Play. A afirmação é verdadeira para a replicação padrão do Unreal aplicada a um jogo feito em Blueprint sem nenhuma flag de rede. Ela não é verdadeira para o espaço de soluções. Os detalhes estão em [docs/01-pesquisa.md](docs/01-pesquisa.md).

## A ideia em uma frase

O host simula o mundo inteiro, inclusive um pawn oculto para cada amigo, usando o suporte a split-screen que o jogo já tem. Os amigos enviam sua pose e seus pedidos de ação pela rede P2P da Steam, e recebem de volta um fluxo compacto do estado visível para renderizar localmente.

## Fatos verificados no binário do jogo

| Item | Valor |
|---|---|
| Engine | Unreal Engine 4.26 |
| Física | PhysX 3 |
| Build Steam testado | 23218978 |
| Terreno | Voxel Plugin Pro, com sincronização TCP compilada |
| Steam | plugin SteamCore legado, com P2P e lobbies compilados |
| Netcode do Unreal | compilado, nunca ativado pelo jogo |
| Split-screen | até 4 jogadores locais |

## Documentação

1. [Pesquisa](docs/01-pesquisa.md): o que a comunidade já tentou, o que o dev disse, o que está no executável.
2. [Decisões](docs/02-decisoes.md): registro de cada decisão de engenharia, com data e motivo.
3. [Arquitetura](docs/03-arquitetura.md): topologia, slots, matriz de sincronização, canais, late join.
4. [Protocolo](docs/04-protocolo.md): rascunho das mensagens.
5. [Roadmap](docs/05-roadmap.md): spike de verificação e marcos.
6. [O que usamos do coop-anything](docs/06-coop-anything.md): ferramentas de teste e playbook adotados, e o que fica de fora.
7. [Fontes](docs/99-fontes.md).

## Regras do repositório

- Nenhum arquivo do jogo, pak, save ou binário de terceiros é commitado.
- Só co-op. Nada de trapaça, nada de contornar anti-cheat, nada que afete o multiplayer de outros jogos.
- Toda decisão relevante entra em `docs/02-decisoes.md` antes do código.

## Trabalho relacionado

- [hydroneer-coopnet](https://github.com/Zane11332/hydroneer-coopnet): primeiro protótipo público de host/join para Hydroneer. Reaproveitamos os hooks e aprendizados dele. Veja a pesquisa para o que muda.
- [coop-anything](https://github.com/cranebeaker/coop-anything): playbook e ferramentas de teste para adicionar co-op a jogos single-player.

## Licença

Ainda não definida. Veja a decisão pendente em `docs/02-decisoes.md`.
