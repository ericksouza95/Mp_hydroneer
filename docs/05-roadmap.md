# 05. Roadmap

## Marco 0. Spike de verificação

**Status: concluído em 2026-11-07, com dois itens adiados.** Resultados em [07-spike.md](07-spike.md). O item 6 perdeu relevância e o item 8 foi para o marco 2.

Objetivo: transformar suposições em fatos antes de escrever protocolo.

1. Instalar UE4SS na cópia do jogo, fora do repositório. Confirmar que carrega no build 23218978.
2. Despejar as classes e propriedades do jogo. Registrar em `docs/` os campos de `BP_ParentItem_C`, das ferramentas iniciais, da pan, do balde, do joalheiro, da loja e do controlador.
3. Verificar se alguma classe nasce com replicação ligada.
4. Contar corpos físicos acordados num save novo e num save de meio de jogo, parado e com o jogador arremessando itens.
5. Verificar se os eventos do SteamCore, como pedido de sessão P2P e entrada no lobby, disparam no jogo empacotado.
6. Verificar se o modkit oficial expõe as classes do SteamCore. Isso decide se a ponte é Blueprint ou C++.
7. Testar `AddLocalPlayer` mais `SetForceDisableSplitscreen` com 3 jogadores ocultos, e medir custo de CPU no host.
8. Testar o bloqueio de pausa por ESC com sessão ativa.

Saída do spike: atualização de `02-decisoes.md` nos pendentes, whitelist inicial de campos, números reais de banda.

## Marco 1. Ponte de transporte

**Status: modo `steam` feito numa instância (2026-11-07).** A `mpnet.dll` está em [08-mpnet.md](08-mpnet.md). Faltam o modo `udp`, o teste entre duas máquinas e o laço por frame.

- Modo `udp` em loopback e modo `steam` via `mpnet.dll`, mesmo protocolo.
- Lobby só por amigos, convite pelo overlay, sessão P2P aceita, ping e pong nos dois canais.
- `qa/gamepool.json` para 2 a 4 cópias do Hydroneer por hardlink, com saves isolados, lançadas pelo `gameslot`.
- Relay `chaos` entre as cópias locais, perfil `bad_wifi`.
- Duas instâncias no mesmo PC, depois duas máquinas reais pela Steam.
- Medição de RTT e perda pelo relay da Steam.

## Marco 2. Andar junto

- Slots, puppets, `POSE` e `PAWNS`.
- Pawn oculto no host seguindo a pose do cliente.
- Verificação de versão no join.
- Probe JSONL em Lua e perfil do esqueleto do Hydroneer para o `animcheck`. Critério: zero glitches e erro de pose dentro da tolerância.

## Marco 3. Terreno e itens

- `TERRAIN` por hooks nas ferramentas de voxel.
- Ids de entidade, `SPAWN`, `DESTROY`, `XFORM`, `SLEEP`, `CARRY`.
- Reconciliação por snapshot em jogo novo.
- Adaptador do Hydroneer para `bots` e `scenarios`: corrida de pickup, handoff de carregar, save e load com rejoin.
- Gravador `.cofr` em Lua para o `flight` assim que o primeiro desync aparecer.

## Marco 4. Loop básico completo

- Cavar, despejar, encher, lavar, vender, comprar, dormir.
- Whitelist de campos, `FIELDS`.
- Eventos de som e animação.

## Marco 5. Late join e robustez

- Transferência de save, replay de terreno, saída de cliente, queda de host.
- Testes com caos de rede: latência, perda, reordenação.
- 4 jogadores em 4 máquinas.

## Marco 6. Distribuição

- Pacote com UE4SS pinado por hash, mod Lua e ponte.
- Guia de instalação.
- Tradução da documentação para inglês.

## Depois

- Relevância por raio.
- Caminhão.
- Máquinas e canos por espelho.
- Upgrade de transporte para SteamNetworkingSockets.
