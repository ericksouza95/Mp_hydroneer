# 07. Spike de verificação (marco 0)

Data: 2026-11-07. Build Steam 23218978. UE4SS experimental `v3.0.1-1217-g4fb9b615`, SHA-256 `fbdacd0fae434e23d53b1181f6b085219d7cbf7e2cc8a13a00303f842c38194f`.

Todos os testes rodaram numa cópia do jogo por hardlink, fora da pasta da Steam, com a pasta de usuário redirecionada. A instalação original e os saves do dono não foram tocados. Relatórios brutos em `spike/`.

## Ambiente de teste

| Item | Como |
|---|---|
| Cópia do jogo | `E:\hydroneer-qa\inst0`, hardlink de cada arquivo da instalação Steam, mais `steam_appid.txt` com `1106840` |
| Isolamento de saves | linha de comando `-userdir=QaUser`. Confirmado: a pasta salva vira `inst0\Mining\QaUser\Saved` |
| Janela | `-windowed -ResX=1280 -ResY=720` |
| Mod | `MpSpike`, Lua, três fases. A fase 3 está em `spike/MpSpike/fase3.lua` |

## Resultados

| # | Pergunta do roadmap | Resultado |
|---|---|---|
| 1 | UE4SS carrega no build 23218978? | **Sim.** Sem crash nas três fases |
| 2 | Dump de classes e propriedades | **Feito.** 165 mil objetos, headers C++ com offsets de 851 tipos, headers UHT. Guardados fora do repositório |
| 3 | Alguma classe nasce replicando? | Só as que o Unreal replica por padrão: GameState, controlador e personagem. Itens, terreno, ciclo dia e noite, loja e joalheiro têm `bReplicates=false` |
| 4 | Quantos corpos físicos acordados? | **Zero.** Mundo novo: 557 itens e 8 mil componentes de malha. Nenhum simula física em repouso, medido a 20 s e a 50 s |
| 5 | Os eventos do SteamCore funcionam pelo Lua? | **Parcial, com bloqueio.** Ver abaixo |
| 6 | O modkit expõe o SteamCore? | Não testado. Passou a ser opção secundária, ver decisão pendente |
| 7 | 3 jogadores ocultos e custo de CPU | **Funciona com 4.** Ver abaixo |
| 8 | Bloqueio de pausa por ESC | Não testado. Precisa de input; fica para o marco 2 |

### Física: o argumento do desenvolvedor não se sustenta em repouso

O item base tem `LockPhysics`, `PhysicsLockTimer` e `TriggerPhysics`. Em tempo de execução, nenhum dos 557 itens de um mundo novo estava simulando física depois de assentar. O jogo já desliga a física de tudo que está parado. Só trafega o que está em movimento naquele instante, e um mundo parado custa zero banda.

Falta medir o pior caso: o jogador arremessando itens, terra caindo, esteiras. Isso entra no marco 3 com o probe de banda.

### Jogadores extras: o caminho oficial do Remote Play aceita 4

- `AddLocalPlayer` só adiciona um jogador local. Chamadas seguintes são ignoradas.
- `AddRemotePlayer` recebe uma estrutura com um único campo inteiro, `SessionID`. O Lua consegue montá-la. Chamado com 101, 102 e 103, o jogo criou 4 controladores, 4 personagens e 4 jogadores locais, e registrou as sessões na instância do jogo.
- `SetForceDisableSplitscreen` desliga a divisão de tela com os 4 presentes.

Custo de frame, com limite de FPS e vsync desligados pelo console:

| Cenário | Frame médio | FPS | Pior frame |
|---|---|---|---|
| 1 jogador | 10,84 ms | 92 | 18,44 ms |
| 4 jogadores, tela única | 11,42 ms | 88 | 16,88 ms |

Os 3 jogadores extras parados custam cerca de 5 % no host. Uma primeira medição bateu no limite de 60 FPS e foi descartada.

### Iniciar partida sem menu

`GM_Hydroneer_C:NewGame()` com `BP_GameInstance_C.SaveSlot` preenchido entra no jogo em 1 segundo. Testes automáticos não dependem de clicar no menu.

### Steam pelo Lua: o bloqueio

| Teste | Resultado |
|---|---|
| Subsistemas `Networking`, `User` e `SteamUtilities` | encontrados |
| `IsSteamAvailable` | true |
| `GetSteamID` | volta como tabela vazia |
| `BreakSteamID` dessa tabela | `"0"` |
| `SendP2PPacket` com tabela Lua como array de bytes | a chamada aceita a tabela, mas retorna false porque o destino virou o ID zero |
| `IsP2PPacketAvailable` | parâmetro de saída funciona: `{MessageSize=0}` |
| `GetP2PSessionState` | estrutura de saída preenchida corretamente |

A estrutura `FSteamID` do SteamCore não expõe nenhum campo por reflexão, só 8 bytes opacos. O UE4SS converte estruturas em tabelas pelos campos refletidos, então a SteamID se perde ao entrar no Lua. Toda função do SteamCore que recebe SteamID fica inutilizável pelo Lua, inclusive P2P, lobby e convite. A decisão D02 precisa ser revista quanto ao **como**, não quanto ao **quê**.

O que continua de pé:

- A DLL da Steam do próprio jogo, SDK 1.47, exporta a API "flat" em C: `SteamAPI_ISteamNetworking_SendP2PPacket`, `ReadP2PPacket`, `SteamAPI_ISteamUser_GetSteamID`, `SteamAPI_ISteamMatchmaking_CreateLobby`, `SteamInternal_FindOrCreateUserInterface` e `SteamAPI_RunCallbacks`. Código nativo dentro do processo chama isso direto, com o app id do Hydroneer e a Steam já inicializada pelo jogo.
- O Lua do UE4SS tem `package.loadlib` e `require`, e o `cpath` inclui a pasta do mod. A DLL do UE4SS não exporta a API C do Lua, então um módulo Lua nativo clássico não funciona, mas carregar uma DLL nossa no processo funciona.
- A DLL do UE4SS exporta funções C como `execute_lua_in_mod` e `get_lua_state_by_mod_name`, usáveis por código nativo para empurrar dados para o Lua.

## Classes e funções que o protocolo vai usar

| Uso | Classe | Membros |
|---|---|---|
| Iniciar e carregar | `GM_Hydroneer_C` | `NewGame`, `ContinueGame(Creative, CloudSaving, ClearResources, Slot)`, `InGame?` |
| Slots | `GM_Hydroneer_C` | `AddRemotePlayer({SessionID})`, `RemovePlayer({SessionID})`, `CanAddPlayer?`, `OnPlayerAdded`, `OnPlayerRemoved` |
| Slots | `BP_GameInstance_C` | `SessionIDs`, `RemotePlayStarted`, `SaveSlot` |
| Ações | `BP_GameController_C` | `PickUpItem(Item)`, `TryPickupItem`, `DropItem`, `MoveDirt(PickUp?, Radius)`, `RemoveDirtByLocation(Location, Radius)`, `CarryingItem`, `CrosshairTraceHit`, `LastThingLookingAt`, `ChangeTime`, `EMS Save` |
| Item | `BP_ParentItem_C` | `BeingCarriedBy`, `BeingStoredBy`, `PaidFor?`, `StoreSellPrice`, `CurrencyType`, `LockPhysics`, `TriggerPhysics`, `OnGrounded` |
| Moeda | `BP_Coin_C` | `Amount`, `InitAmount`, `CombineCoins` |
| Pan | `BP_Pan_C` | `DirtLoads`, `DirtQualityAverage`, `HasLiquidType?`, `Vein`, `Scrubbed`, `AddDirt`, `EmptyDirt` |
| Balde | `BP_Bucket_C` | `DirtLoads`, `DirtQualityAverage`, `HasLiquidType?`, `Vein`, `AddDirt`, `Empty` |
| Pá | `BP_ParentShovel_C` | `DirtQuality`, `MaxDepth`, `Vein`, `LMBDownWhileCarrying(Controller, HitActor, HitLocation)` |
| Venda | `BP_Jeweller_C` | `ItemsToSell`, `TotalSalePrice`, `OverrideMouseClicked(Component, Controller)`, `SpawnCash` |
| Compra | `BP_WorldStore_C` | `ItemsToBuy`, `TotalBuyPrice`, `HydroCoins`, `OverrideMouseClicked(Component, Controller)` |
| Armazenamento | `AC_Storage_C` | `Stored`, `InStorageZone` |
| Hora | `BP_DayNightCycle_C` | `Hour`, `Paused?`, `Day?`, `SpeedUpToSunrise(Bed, Controller)` |
| Terreno | `BP_HydroVoxelWorld_C` | voxel do Voxel Plugin Pro; edições pelas `VoxelSphereTools` |

Os cliques de loja e joalheiro recebem o controlador que clicou. O host executa a compra ou a venda passando o controlador do pawn oculto do cliente.

## Consequências para o projeto

1. O pawn oculto entra pelo `AddRemotePlayer`, não pelo `AddLocalPlayer`. Slots 1 a 3 usam `SessionID` próprios do mod.
2. Banda em repouso é zero. O protocolo precisa tratar bem as rajadas, não o regime permanente.
3. O transporte Steam precisa de código nativo. Ver a decisão pendente em `02-decisoes.md`.
