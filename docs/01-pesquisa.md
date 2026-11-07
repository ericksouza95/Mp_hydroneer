# 01. Pesquisa

Data da pesquisa: 2026-11-07.

## 1. Posição do desenvolvedor

- grandmaMax, Foulball Hangover, abril de 2023: "devido à intensidade da física do Hydroneer, multiplayer convencional não é possível". Solução oficial: split-screen por Steam Remote Play.
- Mesmo dev: "não é tão simples quanto portar para UE5".
- Resposta marcada como oficial por um dev em outro tópico, escrita por um usuário: "há dados demais para transmitir e manter em sincronia; cada pedaço de terra, cada minério, cada cano solto tem cálculo de física".
- Em 2021 o update 2.0 foi anunciado como "multiplayer update" e atrasado para reescrever o sistema de save, otimizar e trocar o motor de física. O que saiu em maio de 2022 foi split-screen local até 4 jogadores mais Remote Play.

Leitura nossa: o argumento descreve o custo de replicar cada corpo físico pela replicação padrão do Unreal. Ele não considera host autoritativo com corpos dormindo fora do fluxo, quantização e delta. O Satisfactory, também em Unreal, replica milhares de itens por segundo em esteiras com cerca de 3 bytes por delta a 3 Hz.

## 2. Tentativas da comunidade

### hydroneer-coopnet (Zane11332, outubro de 2026)

Único protótipo público de host/join. Versão 0.3, 2 commits. Testado no build Steam 23218978, o mesmo instalado aqui.

Como funciona:
- Mod Lua para UE4SS. No host, chama `AddLocalPlayer` no `GM_Hydroneer_C` para criar o segundo jogador do split-screen e esconde a divisão de tela com `SetForceDisableSplitscreen`.
- O amigo envia eixos de movimento e eventos de tecla. O host replica esses inputs no pawn oculto. O amigo recebe estado e reconcilia o próprio pawn: snap acima de 400 cm, blend acima de 10 cm.
- Como o Lua do UE4SS não tem socket, o jogo escreve e lê dois arquivos texto, e um processo Python com Steamworks.NET faz o transporte pela Steam usando o app 480 (Spacewar).
- Sincroniza: movimento, pegar, carregar, soltar, arremessar, escavar e despejar terra, água e terra em baldes e pans, animações e sons de ferramenta, itens criados em runtime.
- Não sincroniza: dinheiro, lojas, máquinas, construção, veículos, missões. Os mundos divergem se alguém usar.
- Late join: host salva, save de cerca de 21 MB vai pela rede com SHA-256, cliente carrega, edições de terreno posteriores são reaplicadas.

Hooks e nomes de classe que ele revelou, úteis para nós:
- `GM_Hydroneer_C`: `InGame?`, `AddLocalPlayer()`.
- `BP_GameController_C`: `Pawn`, `CarryingItem`, `PickUpItem`, `TryPickupItem`, `DropItem`, `MoveDirt`, `RemoveDirtByLocation`, `StartFreeplacing`, `SetControlRotation`, `IsInputKeyDown`.
- `BP_GameCharacter_C`: `CharacterMovement` com `MaxWalkSpeed`, `SetMovementMode`, `Velocity`.
- `BP_ParentItem_C`: `ProxyItem`, `Dirt`, `DirtFX`, `PlayPrimaryUseAnim`, `PlaySecondaryUseAnim`.
- `AC_Animator_C`: `PlayAnimation`.
- `VoxelSphereTools`: `AddSphere`, `RemoveSphere`, `SetValueSphere`, `RemoveSphereWithDurability` e variantes `Async`. Hookeados no host para capturar edições de terreno.
- Save por EasyMultiSave: `Level.sav`, `Player.sav`, `SaveData.sav`.
- Mapa identificado pelo nome de mundo contendo `EmberCradle`.

Problemas que ele documenta e que vamos evitar:
- Hookear todas as funções do controlador derruba o jogo. Só hooks por nome.
- O guard de física fazia o próprio jogador andar a 17 cm/s em vez de 330.
- Pareamento de itens por classe e distância mais próxima, frágil entre dois PCs porque os nomes gerados divergem.
- Espelho de campos por lista negra de nomes como `time`, `speed`, `physic`.

### Outros precedentes

- **Pacific Drive co-op** (UE 4.27): abre o mapa com `?listen` via UE4SS, spawna e possui um personagem por jogador remoto, usa o RPC nativo `ServerChangeName` como canal de comando. O jogo não tem replicação própria, então o mod replica tudo à mão. Menu de pausa derruba o host em modo rede, troca de mapa derruba o listen server.
- **HogWarp** (Hogwarts Legacy, UE4): servidor próprio e sincronização por hooks, time do Skyrim Together.
- **Nitrox** (Subnautica, Unity): cada entidade tem um dono de simulação, os demais recebem estado.
- **Satisfactory** (UE4, nativo): esteiras eram a maior parte do tráfego; passaram a delta por mudança, taxa de 3 Hz, serialização em bits, relevância de inventário só quando aberto. De 48 bytes para 3 bytes por delta.
- **coop-anything**: playbook com ferramentas de teste reutilizáveis: relay com caos de rede, gravador de voo para achar o primeiro desync, fuzzer N jogadores, pool de instâncias do jogo num PC.

## 3. O que está no executável

Varredura de strings em `Mining-Win64-Shipping.exe`, build Steam 23218978, executável datado de 2026-05-12. Contagem de ocorrências ASCII e UTF-16.

| Símbolo | ASCII | UTF-16 | Significado |
|---|---|---|---|
| `++UE4+Release-4.26-CL-15973114` | | 3 | Unreal 4.26 |
| `PhysX` / `PhysXVehicle` | 113 / 18 | 19 / 2 | PhysX 3 ativo, veículos PhysX |
| `eENABLE_ENHANCED_DETERMINISM` | 1 | | flag de determinismo do PhysX existe como opção |
| `IpNetDriver` | | 11 | driver de rede do Unreal compilado |
| `OnlineSubsystemSteam` / `SteamNetDriver` / `SteamSockets` | 1 / 0 / 0 | 2 / 1 / 2 | netcode do Unreal sobre Steam compilado |
| `PendingNetGame` / `ServerChangeName` / `ReplicatedMovement` / `SetReplicates` | 2 / 1 / 3 / 1 | 3 / 2 / 2 / 0 | fluxo de join e replicação de movimento nativos presentes |
| `SendP2PPacket` / `ReadP2PPacket` / `AcceptP2PSessionWithUser` | 1 / 1 / 1 | | P2P legado da Steam exposto pelo SteamCore |
| `P2PSessionRequest` / `bAllowP2PPacketRelay` / `ESteamP2PSend` | sim | | evento de sessão, relay e tipo de envio por pacote |
| `CreateLobby` / `JoinLobby` / `RequestLobbyList` / `InviteUserToLobby` | sim | | lobbies pelo SteamCore |
| `SteamNetworking006` | 1 | | interface legada ISteamNetworking |
| `SteamNetworkingMessages` / `SteamNetworkingSockets` | 0 | 0 | API moderna não exposta pelo plugin |
| `VoxelMultiplayerTcpInterface` | 3 | 1 | sync TCP de voxels do Voxel Plugin Pro compilado |
| `VoxelSphereTools` / `VoxelWorld` | 36 / 35 | 1 / 11 | ferramentas de edição de terreno |
| `EasyMultiSave` | 1 | 6 | sistema de save |
| `SetForceDisableSplitscreen` / `CreatePlayer` / `FourPlayerSplitscreenLayout` | 1 / 2 / sim | | split-screen até 4 |

Plugins presentes conforme `Engine.ini` gerado pelo jogo: VoxelPro, SteamCore, EasyFileSystem, AutoSettings, DLSS, PivotTool. SDK Steamworks v1.47 (`steam_api64.dll`).

Modding oficial: Steam Workshop desde a 2.0, modkit da comunidade para a 3.0.8 com Blueprints sem bytecode. UE4SS funciona no jogo, com Lua e C++.

## 4. Conclusões da pesquisa

1. O jogo já tem tudo que precisa para hospedar pela Steam de dentro do processo: lobbies, P2P com relay, e um segundo, terceiro e quarto jogador locais.
2. A física impõe só uma restrição real: PhysX não é determinístico entre máquinas, logo cada corpo tem um único dono de simulação. Em host autoritativo, o dono é sempre o host.
3. O volume de dados é problema de protocolo. Corpos dormindo não trafegam. Um item acordado cabe em cerca de 12 bytes quantizados.
4. O coopnet provou o conceito do pawn oculto. A implementação precisa ser refeita no transporte, nos ids de entidade e no espelho de estado.
