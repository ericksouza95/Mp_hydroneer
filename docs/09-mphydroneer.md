# 09. MpHydroneer: o mod de co-op

Código em `mod/MpHydroneer/Scripts/`. Usa a ponte `mpnet` ([08-mpnet.md](08-mpnet.md)). Versão 0.2, protocolo 1.

## O que já faz

- **Sala e slots.** O host abre a sala com F8, já dentro de um jogo. Os clientes recebem os slots 1 a 3 na ordem de entrada. Versão de protocolo diferente recusa a entrada com mensagem no relatório. Convite para a sala em que o jogador já está é ignorado.
- **Ver o outro jogador.** Cada cliente manda a própria pose ao host a 30 Hz. No host, o cliente é um jogador criado pelo caminho de Remote Play do jogo, o pawn oculto, que anda até a pose recebida. O host devolve a pose de todos a 30 Hz, e cada cliente mostra os outros como bonecos.
- **Terreno compartilhado.** Hooks nas funções de esfera do Voxel Plugin capturam cada escavação local. Quem cava aplica na hora. O cliente manda ao host, o host aplica e repassa com número de sequência para os outros. O host manda as próprias edições para todos.
- **Ping e status.** Ping a cada 250 ms, média por janela de 5 s sem os primeiros 10 s de cada par, FPS do outro lado, rota direta ou relay. Status no título da janela, relatório em `%LOCALAPPDATA%\HydroneerMP\relatorio.txt`.

Ainda não sincroniza itens, ferramentas na mão, dinheiro, lojas, máquinas, veículos nem hora do dia.

## Módulos

| Arquivo | Função |
|---|---|
| `main.lua` | inicia a ponte, laço por frame com vigia, teclas F8 e F9, robôs de teste |
| `session.lua` | sala, slots, ping, roteamento de pose e terreno |
| `avatar.lua` | pose local, motor de movimento, bonecos e pawns ocultos |
| `terrain.lua` | hooks de terreno, trava de reaplicação, marcador contra crash, aplicação de edições |
| `proto.lua` | mensagens em binário |
| `util.lua` | log, configuração, acesso ao jogo, leitura de densidade do voxel |

## Mensagens do protocolo 1

Primeiro byte é o tipo. Canal 0 confiável, canal 1 não confiável.

| Tipo | Nome | Sentido | Canal | Conteúdo |
|---|---|---|---|---|
| 1 | `WELCOME` | host para cliente | 0 | versão do protocolo, slot, versão do mod |
| 2 | `ROSTER` | host para todos | 0 | lista de slot, SteamID, nome |
| 3 | `POSE` | cliente para host | 1 | sequência e pose |
| 4 | `AVATARS` | host para todos | 1 | sequência e lista de slot com pose |
| 5 | `TERRAIN` | host para clientes | 0 | sequência, slot de origem, edição |
| 6 | `TERRAIN_REQ` | cliente para host | 0 | edição |
| 7 | `PING` | qualquer | 1 | sequência, relógio do remetente |
| 8 | `PONG` | qualquer | 1 | sequência, relógio ecoado, FPS |
| 9 | `BYE` | host para cliente | 0 | motivo |

Pose: posição, yaw, pitch, velocidade, velocidade máxima de caminhada, flags de agachado e no ar. Edição: função, nome do mundo de voxel, centro, raio, valor ou intervalo, quatro flags.

## Como o personagem remoto anda

Teleportar a cada frame trava a animação de passo. O personagem remoto recebe comandos de movimento do próprio jogo em direção à pose recebida, mirando 100 ms à frente pela velocidade. Ele anda com a física e a animação normais e só teleporta quando o erro passa de 3 m. Agachar e pular seguem as flags. Nos bonecos, que não têm controlador, a física de movimento é ligada à parte.

## Regras aprendidas

- **Reentrância do UE4SS.** Quando o Lua chama uma função do jogo que acaba chamando uma função com hook, o hook roda dentro da chamada e ler os parâmetros dele pode derrubar o jogo. Aconteceu com a escavação chamada direto pelo Lua. Toda chamada nossa que pode chegar às funções de esfera usa a trava `applying`, e o hook sai sem ler nada. Escavações do jogador vêm do código do jogo e não têm esse problema.
- **Marcador contra crash.** O hook de terreno grava um marcador antes de ler os parâmetros e apaga depois. Se o jogo fechar no meio, o próximo início desliga a sincronização de terreno e avisa no relatório.
- **Mundos de voxel.** O jogo tem vários: EmberCradle, Dreck, Icehelm, Mildews, Snowrune, SouthHope e uma zona sem escavação. Fora dos limites de um mundo, a densidade lida é -1 em todo lugar. A edição sempre carrega o nome do mundo em que foi feita.

## Testes numa máquina só

O modo UDP da ponte deixa duas cópias do jogo conversarem nesta máquina. `tools/run-test.ps1` encerra a cópia anterior, instala o mod com uma configuração em `mp-config.txt` e abre o jogo em janela.

```
powershell -ExecutionPolicy Bypass -File tools\run-test.ps1 -Instance E:\hydroneer-qa\inst0 -X 0 -Y 0 `
  -Config "transport=udp,role=host,addr=127.0.0.1:7777,newgame=1,bot=terrainsync,testsecs=75,report=E:/hydroneer-qa/out/host.txt"
powershell -ExecutionPolicy Bypass -File tools\run-test.ps1 -Instance E:\hydroneer-qa\inst1 -X 960 -Y 0 `
  -Config "transport=udp,role=client,addr=127.0.0.1:7777,newgame=1,bot=walk,offset_x=600,testsecs=75,report=E:/hydroneer-qa/out/client.txt"
```

Chaves de `mp-config.txt`:

| Chave | Valores |
|---|---|
| `transport` | `steam` (padrão) ou `udp` |
| `role` | `host` ou `client` no modo UDP |
| `addr` | endereço do host no modo UDP |
| `newgame` | `1` inicia um jogo novo sozinho |
| `bot` | `walk`, `dig` (pega a pá e clica), `terrainsync`, `applytest` ou `none` |
| `mirror` | `1` cria um boneco que segue o próprio jogador, para testar o motor de movimento numa instância |
| `offset_x`, `testsecs`, `report`, `trace_hooks` | deslocamento inicial, duração, arquivo do relatório, rastreio passo a passo do hook |

## Resultados (2026-11-07, build 23218978)

Teste espelho, uma instância, boneco seguindo o próprio jogador com 150 ms de atraso:

| Medida | Resultado |
|---|---|
| Erro de posição em regime | 5 a 11 cm |
| Animação de andar ativa quando o alvo anda | 1.919 de 1.924 amostras |

Duas instâncias pelo modo UDP, host e cliente andando em círculos:

| Medida | Host | Cliente |
|---|---|---|
| Entrada e slot | slot 1 dado | slot 1 recebido |
| Taxa de poses recebidas | cerca de 24/s | cerca de 24/s |
| Erro do personagem remoto em movimento | 16 cm médio, até 30 cm | 16 cm médio, até 29 cm |
| Ping, incluindo o laço do jogo | 50 ms | 50 ms |
| Teleportes depois da entrada | 0 | 0 |
| Edições de terreno enviadas pelo host | 11 aplicadas, 0 falhas | 11 aplicadas, 0 falhas |
| Densidade final nos pontos editados | idêntica nos dois lados | idêntica nos dois lados |

Terreno, o que está e o que não está provado:

| Parte | Situação |
|---|---|
| Rede: edição sai do host, chega ao cliente, na ordem, sem falha | provado, duas instâncias |
| Aplicação: a mesma chamada produz o mesmo voxel nos dois lados | provado, densidade idêntica nos dois lados |
| Aplicação abre buraco | provado num ponto do terreno inicial (sólido para ar); em outros pontos a remoção sintética não alterou o voxel, provavelmente áreas protegidas ou camadas do jogo |
| Captura da escavação real pelo hook | não provado. O robô pega a pá e dispara o clique, mas a pá não cava assim e nenhuma função de terreno é chamada. O teste fica com os jogadores |
| Hook lendo parâmetros dentro de chamada iniciada pelo Lua | derruba o jogo; evitado pela trava, e o marcador desliga o terreno se acontecer na escavação real |

Pacote 0.2, ciclo completo numa cópia limpa: instalação de 14 arquivos, jogo sobe com o mod pela Steam, reinstalação remove a versão anterior sozinha, desinstalação deixa a pasta idêntica à original.
