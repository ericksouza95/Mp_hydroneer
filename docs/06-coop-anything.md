# 06. O que usamos do coop-anything

Repositório: https://github.com/cranebeaker/coop-anything, licença MIT. Avaliação feita em 2026-11-07 sobre o clone da branch principal.

O coop-anything é três coisas: um playbook de como mods de co-op são feitos, um conjunto de ferramentas de teste independentes de jogo, e skills para agentes de código. Nada nele é netcode pronto. O que ele entrega é método e instrumentação de teste. Abaixo, item por item, o que entra, quando, e o que fica de fora.

## Restrição que muda nosso desenho

O playbook de Steam afirma: um PC só roda uma conta Steam, então não dá para testar dois jogadores localmente pela Steam de verdade. A solução deles é um transporte alternativo por UDP em localhost no mesmo código, escolhido por flag. Isso vira a decisão D12: a ponte de transporte tem dois modos, `udp` para testes num PC só e `steam` para jogar. O modo UDP é também o que permite usar o relay de caos.

## Entra agora

| Item | O que é | Como usamos | Marco |
|---|---|---|---|
| `playbook/how-coop-mods-work.md` | As oito perguntas que todo mod responde e a ordem de construção em estágios | Checklist de desenho. Nossa matriz em `03-arquitetura.md` responde as oito. A ordem deles bate com nosso roadmap: hook, transporte, puppet, autoridade, interações, transições, testes, distribuição | 0 |
| `playbook/lessons.md` | 21 lições de seis projetos | Regras de trabalho. As que mais nos afetam: bot dentro do jogo e não por teclado simulado; testar co-op com dois clientes reais; nunca tocar a instalação e os saves do dono; sempre em janela; apagar log antes de cada execução; nunca superestimar o nível de QA | 0 |
| `playbook/multi-instance-testing.md` | Como rodar várias cópias do jogo num PC: instalações por hardlink, saves isolados, `steam_appid.txt`, checagens de instância única | O coopnet já rodou duas cópias do Hydroneer num PC. Vamos seguir o método deles para 4 cópias com hardlink, já que o jogo tem 14 GB | 0 |
| `tools/gameslot` + `tools/gamepool` | Lock para só uma bateria de cópias por vez, guarda de RAM, pool de cópias prontas, lançamento minimizado, leitura de log de crash, tudo de um JSON por jogo | Escrever `qa/gamepool.json` para o Hydroneer. Nunca lançar cópia sem o slot | 1 |
| `tools/chaos` | Relay UDP com perfis `lan`, `good_wifi`, `bad_wifi`, `mobile_tether`, `transatlantic`, `hell`, trocáveis em tempo real, com semente fixa | Entre as cópias locais no modo UDP da ponte. `bad_wifi` é o perfil de trabalho para bugs de sincronização, `hell` o de estresse | 1 |
| Skills `coop-build-from-zero`, `coop-networking`, `coop-sync-testing`, `coop-qa` | Resumos de 15 a 40 linhas que apontam para o playbook | Lidas como checklist no começo de cada marco | 0 |

## Entra nos marcos 2 e 3

| Item | O que é | Como usamos | Marco |
|---|---|---|---|
| `tools/animcheck` | Lê um fluxo JSONL por máquina com posição, rotação, animação e ossos de cada ator, e acusa deslize, T-pose, flutuação, jitter, rubber-band e travamento. Compara dono contra observador com o atraso de interpolação descontado | Um probe em Lua escreve o JSONL do próprio pawn e dos puppets. Um perfil com os nomes de osso do esqueleto do Hydroneer, extraídos no spike. Valida a interpolação dos puppets com números em vez de olho | 2 |
| `tools/scenarios` | Estado inicial e teste num JSON, com reset no lugar e recarga de save só quando precisa | Cenários: "dois jogadores ao lado do rio com pá e pan", "três jogadores com itens espalhados", "late join num save de meio de jogo" | 3 |
| `tools/bots` | Doze playbooks de co-op sobre um adaptador de ações que escrevemos, com diff de estado depois de cada passo e janelas de silêncio para links ruins | Adaptador do Hydroneer com `goto_pos`, `pickup`, `drop`, `activate`, `save_game`, `load_game`, `session_join`, `session_leave`, mais `snapshot` com itens por id, posição, quem carrega, sequência de terreno e hora. Playbooks que nos servem: corrida de pickup, handoff de carregar, save e load com rejoin. O bot roda dentro do jogo, em Lua, comandado por arquivo ou pela ponte | 3 |

## Entra quando houver desync para caçar

| Item | O que é | Por que depois |
|---|---|---|
| `tools/flight` | Caixa-preta por máquina em formato `.cofr` aberto, mais analisador que alinha 2 a 4 máquinas, acha a primeira divergência até chave e valor, encolhe a execução e gera teste de regressão | O gravador oficial é C++, mas o formato é documentado e Lua 5.4 tem `string.pack`. Nosso mapeamento: txn é uma mensagem confiável com sequência, efeito é cada spawn, destroy, campo ou operação de terreno, digest é um hash da tabela de itens por categoria. Vale o esforço quando o marco 3 começar a divergir |
| `tools/inspect` | Tabela ao vivo de todas as cópias lado a lado | Depende de uma ponte de leitura de estado em cada cópia. Vem junto com o adaptador dos bots |

## Fica de fora, com motivo

| Item | Motivo |
|---|---|
| `tools/ownership` | Biblioteca C++ de dono por ator com épocas e handoff. Nossa autoridade é só do host, sem transferência. Volta a ser relevante se um dia distribuirmos simulação de máquinas por proximidade |
| `tools/fuzz` | Exige o núcleo de sincronização em C++ atrás de uma interface alvo. Nosso núcleo é Lua. Se a ponte virar C++, reavaliar |
| `tools/fakeworld` | Mundo exemplo em C++. Faremos um modelo pequeno em Python do nosso protocolo quando precisarmos de testes sem o jogo |
| `tools/bridge` | Servidor RPC em C++ dentro do processo. Sem mod C++, nossa ponte de teste é por arquivo, como o coopnet, com um cliente Python que imita a API do bridge para os bots |
| `tools/hotreload`, `tools/buildlock`, `tools/mutants` | Iteração de build C++. O UE4SS já recarrega Lua a quente. A parte Python de `mutants` pode servir para nossas ferramentas de teste mais tarde |
| `playbook/networking-steam-spacewar.md` | Resolve o caso de jogos sem Steamworks próprio. O Hydroneer tem o SteamCore e o app id próprio, então o Spacewar não entra. Só aproveitamos a lição do transporte duplo |
| `playbook/split-screen.md` | É sobre várias instâncias num PC para sofá, não sobre o jogador oculto do split-screen nativo que usamos. Nada a aproveitar |
| Diretório e `games/<slug>` | Entra no fim, pelo skill `coop-contribute`, quando houver algo jogável. O Zane11332 reivindicou o Hydroneer na issue 145; coordenar lá antes de abrir PR |

## Como referenciar

Submódulo em `vendor/coop-anything`, fixado no commit `a71be2c`. As ferramentas são Python 3 sem dependências:

```
git submodule update --init
python -I vendor/coop-anything/tools/test_all.py
```

Atualizar o commit fixado é uma decisão explícita, registrada em `02-decisoes.md`.
