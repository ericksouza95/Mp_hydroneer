# 10. savesync: entrada tardia pela transferência do save

Código em `lua/savesync.lua`, biblioteca compartilhada que os scripts de deploy e de pacote copiam para a pasta `Scripts` de cada mod. Mod de teste em `mod/MpSaveTest/`.

## O que faz

Quem entra na sala joga no mundo do host. O host salva o mundo, manda os arquivos do slot pela ponte, e o cliente grava esses arquivos como o slot local `MpHydroneerHost` e carrega esse slot. Depois disso o cliente está no mesmo mundo, com os mesmos itens nos mesmos lugares. O que mudar dali em diante fica com a sessão, que recebe a marca de terreno do momento do save para saber a partir de qual edição reaplicar.

O módulo não chama a `mpnet`. A sessão passa as funções de envio, log e relógio em `SS.init` e entrega os pacotes recebidos.

## Contrato com a sessão

| Função | Lado | Efeito |
|---|---|---|
| `SS.init({ send, log, now_us })` | os dois | `send(peer, bytes, reliable, canal)`, `log(texto)`, `now_us()` em microssegundos |
| `SS.handles(bytes)` | os dois | verdadeiro se o primeiro byte está entre 20 e 29 |
| `SS.host_handle(peer, bytes)`, `SS.host_tick()` | host | atende pedidos; o tick roda a cada frame |
| `SS.host_terrain_mark` | host | gancho; chamado logo antes do `Autosave`, o valor vai no cabeçalho do save |
| `SS.on_client_loaded(peer, marca)` | host | gancho; o cliente avisou que carregou o mundo |
| `SS.client_request(host)` | cliente | começa a entrada; repete o pedido a cada 2 s até o host responder, desiste em 5 min |
| `SS.client_handle(peer, bytes)`, `SS.client_tick()` | cliente | recebe, grava e carrega |
| `SS.on_world_loaded(marca)` | cliente | gancho; chamado 5 s depois de `InGame?` ficar verdadeiro no mundo do host. Em seguida o módulo manda `LOADED` ao host |
| `SS.drop_peer(peer)` | os dois | par saiu: tira da fila, cancela a transferência; no cliente, host saindo vira `failed` |
| `SS.state()` | os dois | `idle`, `requested`, `saving`, `sending`, `receiving`, `loading`, `loaded`, `failed` |
| `SS.progress()` | os dois | fração de 0 a 1: bytes confirmados no host, bytes recebidos no cliente |

Extras, fora do contrato: `SS.config` (caminho de carga), `SS.stats` (medidas da última operação), `SS.current_slot()`, `SS.saves_dir()`, `SS.diag()`.

A marca de terreno é lida antes do `Autosave`. Edições anteriores à marca estão no save. Edições posteriores podem ou não estar, e a sessão deve reaplicá-las; reaplicar uma escavação que já está no save não muda nada.

## Mensagens

Primeiro byte é o tipo. Todas confiáveis, no canal 2, para o volume do save não atrasar o tráfego do jogo no canal 0. Inteiros little-endian. `req` é um número aleatório que o cliente sorteia a cada `client_request`; mensagens com outro `req` são ignoradas.

| Tipo | Nome | Sentido | Conteúdo |
|---|---|---|---|
| 20 | `REQ` | cliente para host | `u32 req`, `u16 versão` (1) |
| 21 | `STATUS` | host para cliente | `u32 req`, `u8 código` (1 na fila, 2 salvando), `u16 posição na fila`. Repetido a cada 5 s enquanto espera |
| 22 | `HEADER` | host para cliente | `u32 req`, `u8 flags` (1 = criativo), marca, `s1 slot do host`, `u32 total`, `u8 n`, n × (`s1 nome`, `u32 tamanho`) |
| 23 | `CHUNK` | host para cliente | `u32 req`, `u8 arquivo` (1..n), `u32 offset`, `i64 hash do pedaço`, dados (128 KB) |
| 24 | `DONE` | host para cliente | `u32 req`, `u8 n`, n × `i64 hash do arquivo` |
| 25 | `ACK` | cliente para host | `u32 req`, `u32 bytes recebidos no total` |
| 26 | `LOADED` | cliente para host | `u32 req`, marca |
| 27 | `ABORT` | qualquer | `u32 req`, `s2 motivo` |

Marca: `u8 0` + `i64` para inteiro, `u8 1` + `double` para número com fração. Volta do mesmo tipo que a sessão mandou.

Nomes de arquivo aceitos pelo cliente: só `[A-Za-z0-9_-.]+.sav`, para o host não conseguir escrever fora da pasta do slot.

### Integridade

Hash FNV-1a sobre palavras de 64 bits, lidas com `string.unpack` de 8 em 8 palavras, com o tamanho do pedaço misturado no fim. Cada `CHUNK` leva o hash do próprio pedaço, e o cliente confere antes de aceitar. O hash do arquivo encadeia os hashes dos pedaços e vem no `DONE`. O cliente também confere ordem dos offsets e tamanhos. Qualquer diferença vira `ABORT` e `failed`.

Custo medido no jogo: cerca de 150 ms para os 21 MB, espalhados pelos ticks, nunca mais de 3 ms num tick do host.

### Ritmo de envio

| Limite | Valor |
|---|---|
| Pedaço | 128 KB |
| Por `host_tick` | até 256 KB, dois pedaços |
| Em voo, sem `ACK` do cliente | até 2 MB |
| Leitura do disco para a memória | 2 MB por tick, depois do save |

A janela usa o `ACK` do próprio savesync, não o estado interno da ponte, e vale igual na Steam e no UDP. O cliente confirma cada pedaço. O host lê o slot inteiro para a memória antes de mandar o cabeçalho, então um autosave do jogo no meio da transferência não mistura duas versões. Cada pedaço enviado é liberado da memória.

### Host

1. `REQ` entra na fila; o host responde `STATUS` com a posição. Um pedido por vez.
2. `REQ` repetido de quem já está na fila ou sendo servido é ignorado. `REQ` com `req` novo de quem está sendo servido recomeça o atendimento dele. Duplicata atrasada de um pedido já servido é ignorada.
3. O atendimento só começa com o host dentro de um mundo (`InGame?`).
4. Marca de terreno, `Autosave()` no controlador local, espera de no mínimo 3 s até `IsSavingOrLoading` ficar falso, com limite de 90 s.
5. Lê o slot atual (`GetSlotInfoSaveGame`), lista os `.sav` da pasta pelo `FindFiles` do jogo mais a lista conhecida (`Level.sav`, `Player.sav`, `SaveData.sav`), lê tudo para a memória em pedaços.
6. `HEADER`, `CHUNK` no ritmo acima, `DONE`. Terminou quando o `ACK` chega ao total. Cliente sem confirmar nada por 60 s: `ABORT` e o próximo da fila.
7. `LOADED` do cliente chama `on_client_loaded(peer, marca)`.

`drop_peer` tira o par da fila, cancela a transferência em andamento e passa para o próximo.

### Cliente

1. `REQ` a cada 2 s até chegar `STATUS` ou `HEADER`. Sem resposta em 5 min: `failed`.
2. Depois de respondido, 90 s sem nenhuma mensagem do host: `failed`.
3. Recebe, confere e guarda os pedaços na memória.
4. Carga, descrita abaixo.
5. 5 s depois de `InGame?` no mundo novo: `on_world_loaded(marca)`, `LOADED` ao host, estado `loaded`.

## Caminho de carga que funciona

Build 23218978. Testado nos dois casos pedidos.

### Do menu principal

```
EMSFunctionLibrary:SetCurrentSaveGameName(gm, "MpHydroneerHost")
GM_Hydroneer_C:ContinueGame(criativo, false, false, "MpHydroneerHost")
```

`ContinueGame` do game mode basta. Ele fecha o menu, carrega o slot e põe `InGame?` em verdadeiro em 1,3 a 1,7 s. É o padrão (`load_method = "gm"`).

O caminho pelos botões também funciona (`load_method = "menu"`): `SetCurrentSaveGameName`, botão Continuar do `UI_MainMenu_C`, 2,5 s, `UI_Menu_SaveManager_C:SaveSelected(slot)`, 1,5 s, `ContinueMainGame()`. Chega ao mesmo mundo, com os mesmos 557 itens, mas leva 5,3 s por causa das esperas. Fica como reserva. Com `load_method = "auto"`, o módulo tenta o `ContinueGame` e, se nada acontecer em 25 s, vai pelos botões.

### De dentro de um mundo

`ContinueGame` chamado com o cliente já num mundo não recarrega o nível. O jogo carrega no lugar só a posição do jogador: no teste, os 8 itens iniciais do mundo do próprio cliente continuaram lá, e os itens que o host tinha movido não foram para as posições do save. Não serve.

O que funciona (`leave_method = "menu"`, o padrão):

1. Se o slot atual não é `MpHydroneerHost`, `Autosave()` do mundo do próprio cliente, para ele não perder o progresso.
2. `GameplayStatics:OpenLevel(gm, "L_GameWorld", true, "")`. O nível recarrega e o menu principal aparece em cerca de 4 s.
3. Espera um game mode novo, `InGame?` falso e o menu na tela, mais 3 s. Chama `CollectGarbage()`.
4. Grava os arquivos e segue o caminho do menu principal.

`leave_method = "gm"` tenta o `ContinueGame` direto e, como o nível não recarrega, cai no caminho acima depois de 15 s. `leave_method = "gm_inplace"` é só o experimento que mostrou o problema.

### Onde os arquivos ficam

`<ProjectSavedDirectory>/SaveGames/MpHydroneerHost/`, com o caminho absoluto dado por `KismetSystemLibrary:ConvertToAbsolutePath`. O módulo recusa gravar se o caminho não terminar em `/Saved/`. Nas cópias de teste, com `-userdir=QaUser`, isso dá `<cópia>\Mining\QaUser\Saved\SaveGames\`. A pasta é criada pelo `MakeDirectory` do `BlueprintFileUtils` do jogo, e só se ainda não existe; o `mkdir` pelo `os.execute` é o último recurso. Cada arquivo é gravado como `.mptmp` e renomeado por cima do anterior. Arquivos `.sav` antigos que não vieram do host são apagados. O jogo cria sozinho `MpHydroneerHost_backup_1` ao carregar.

## Os nomes dos itens batem?

Sim, para os itens que o save guarda. É a resposta que decide como casar itens entre host e cliente.

O EasyMultiSave grava o nome de cada ator e recria o ator com o mesmo nome. Isso vale também para os criados em tempo de execução, com nomes como `BP_Pan_C_2147479733`. Prova: no mundo do próprio cliente, os itens iniciais se chamavam `BP_Brush_C_2147479724`, `BP_Pan_C_2147479725` e assim por diante. Depois de carregar o save do host, os mesmos itens passaram a se chamar `BP_Brush_C_2147479730`, `BP_Pan_C_2147479731`, os nomes do host.

| Cenário | Itens no host | Itens no cliente | Mesmo nome | Mesma classe e posição entre os de mesmo nome |
|---|---|---|---|---|
| Cliente no menu principal | 557 | 557 | 557 | 557, 0 cm de diferença |
| Cliente no menu, caminho pelos botões | 557 | 557 | 557 | 557, 0 cm |
| Cliente já no próprio jogo novo | 557 | 557 | 555 | 555, 0 cm |

A exceção são `BP_DrillT1_C` e `BP_HarvesterT1_C`, da loja inicial. Eles não são recriados pelo save com o nome gravado: o jogo os cria de novo ao carregar, com o próximo nome livre do processo. Num processo novo o nome coincide por acaso, `..._2147481711` e `..._2147481709` nos dois lados. Num processo que já teve outro mundo, ganharam `..._2147477894` e `..._2147477893`, na mesma classe e posição exata. O `CollectGarbage` antes da carga não mudou isso.

Regra para a sessão: casar itens pelo nome; o que sobrar sem par, casar por classe e posição, com tolerância de 1 cm logo depois da carga.

Os itens de loja (`BP_Anvil3`, `BP_Bucket3`, e outros com nome de nível) não guardam a posição no save: movidos no host, voltaram ao lugar original no cliente. O teste usa como marca os itens iniciais, que guardam.

## Testes

`mod/MpSaveTest/Scripts/main.lua`, duas cópias do jogo neste PC pelo modo UDP da ponte, `inst2` como host e `inst3` como cliente, porta 7778.

```
powershell -NoProfile -ExecutionPolicy Bypass -File tools\run-test.ps1 -Instance E:\hydroneer-qa\inst2 -Mod MpSaveTest `
  -Config "transport=udp,role=host,addr=127.0.0.1:7778,newgame=1,report=E:/hydroneer-qa/out/ss-host.txt" -X 0 -Y 560
powershell -NoProfile -ExecutionPolicy Bypass -File tools\run-test.ps1 -Instance E:\hydroneer-qa\inst3 -Mod MpSaveTest `
  -Config "transport=udp,role=client,addr=127.0.0.1:7778,report=E:/hydroneer-qa/out/ss-client.txt" -X 960 -Y 560
```

Para o cliente começar no próprio jogo, acrescentar `newgame=1,joindelay=20`. Chaves próprias do MpSaveTest: `testsecs` (480), `joindelay`, `loadmethod`, `leavemethod`, `saveown`.

O host começa um jogo novo, marca o mundo (anda 8 m com o jogador e põe a panela, a lanterna e a pá iniciais em posições novas), abre a sala e atende. O cliente entra na sala e pede o mundo. Os dois gravam no relatório o slot, a posição do jogador, o dinheiro (soma de `BP_Coin_C.Amount`), a contagem de `BP_ParentItem_C`, os 20 primeiros nomes e as marcas. A lista completa de itens, com classe e posição, vai para `<relatório>-<etapa>-itens.txt`.

### Resultados (2026-11-10, build 23218978)

| Medida | Cliente no menu | Cliente no próprio jogo |
|---|---|---|
| Save no host (`Autosave` até `IsSavingOrLoading` falso) | 3,0 s, o mínimo; o save terminou antes | 3,0 s |
| Leitura para a memória, em ticks | 225 a 278 ms | igual |
| Tamanho | 20,87 MB em 3 arquivos | igual |
| Transferência, UDP local | 2,2 a 2,3 s, 9 MB/s | 2,2 a 3,4 s, 6,2 a 6,8 MB/s |
| Hash no host | 150 ms no total, até 3 ms num tick | igual |
| Gravação no cliente | 26 a 43 ms, num tick | igual |
| Salvar o próprio mundo | não se aplica | 2 s |
| `OpenLevel` até o menu, mais 3 s de espera | não se aplica | 7 s |
| `ContinueGame` até `InGame?` | 1,3 a 1,7 s | 1,4 a 1,5 s |
| Fim da transferência até `on_world_loaded`, com 5 s de acomodação | 9,4 a 9,9 s | 16,9 a 17,0 s |
| Pedido até `loaded`, total | 15 a 16 s | 23 s |
| Posição do jogador no cliente | a do save do host, 22779 5713 239 | igual |
| Marca de terreno | 42 enviada, 42 devolvida | igual |
| Dinheiro | 0 nos dois lados; jogo novo não tem moedas | igual |

Leitura:

- A transferência no UDP local ficou limitada pelo laço do jogo, com duas cópias no mesmo PC rodando a 33 a 53 ticks por segundo, e não pelo limite de 256 KB por tick. Pela Steam, entre duas casas, a banda vai mandar. No primeiro teste real (doc 08), 1 Mbit/s passou sem perda; o save a 1 MB/s levaria cerca de 21 s.
- O cliente congela por alguns segundos na troca de nível. A ponte segue viva porque o keepalive é da thread de rede da DLL.

Simulação fora do jogo: dois `LuaRuntime` 5.4 (lupa) com objetos do jogo falsos testaram o protocolo de ponta a ponta, o reenvio do pedido quando os primeiros se perdem, a fila com dois clientes e o `drop_peer` no meio da transferência. Os scripts ficaram fora do repositório.

### Não testado

- Pela Steam, entre duas máquinas. Só UDP local.
- Dois clientes ao mesmo tempo no jogo. A fila só foi testada na simulação.
- Mundo com dinheiro, máquinas e veículos comprados. O save de um jogo novo tem 557 itens e nenhuma moeda.
- Mundo criativo. O cabeçalho leva a flag, e o cliente a passa ao `ContinueGame`.
- Caminho de usuário com acentos. O `io` do Lua abre arquivos pela página de código ANSI. Para um usuário com acento no nome, a gravação e a leitura dos `.sav` podem falhar e precisar das funções de arquivo do jogo (`BlueprintFileUtils`).

## Achados para outras partes

- **Token da `mpnet` repetido.** `mpnet.start` usa `math.randomseed(os.time())` e `os.time()` no token do pipe. Duas cópias abertas no mesmo segundo pegam o mesmo token. Uma delas se conecta ao pipe da outra, e a outra falha com `CreateNamedPipe` erro 231. No teste, o host ficou ligado à ponte do cliente. O MpSaveTest contorna iniciando a ponte do cliente 2,5 s depois. A `lua/mpnet.lua` da cópia de trabalho já mistura no token o caminho da DLL, o endereço de uma tabela e `os.clock()`, o que resolve; o atraso do MpSaveTest ficou por segurança.
- **Slot do jogo novo.** `NewGame()` ignora `BP_GameInstance_C.SaveSlot` e usa o último slot aberto. Depois de carregar o mundo do host, um jogo novo do cliente sobrescreveria `MpHydroneerHost`. O MpSaveTest chama `SetCurrentSaveGameName(gm, "MpSaveTest-<papel>")` antes do `NewGame()`. Os robôs do MpHydroneer devem fazer o mesmo.
- **"Continuar" do jogo.** Depois de jogar na sala, o Continuar do menu abre a cópia do mundo do host. O mundo do próprio cliente fica no slot dele, salvo antes da troca.
