# 08. mpnet: ponte nativa com a Steam

Implementa a decisão D16. Código em `native/mpnet/` e `lua/mpnet.lua`.

## Por que existe

O spike mostrou que a SteamID do plugin SteamCore chega vazia ao Lua do UE4SS. A `mpnet.dll` chama a Steam direto, pela API "flat" da `steam_api64.dll` que o próprio jogo já carregou e inicializou. Usa o app do Hydroneer, 1106840. Não usa o app 480, não abre processo externo e não exige compilar o UE4SS.

## Como funciona

```
Lua (game thread)                         mpnet.dll (thread propria)
  mpnet.start(caminho)  -- package.loadlib(caminho, "*")
                        -- DllMain cria a thread
  mpnet.connect()       <-- pipes \\.\pipe\mpnet_<token>_c2s / _s2c
  a cada tick:
    comandos + POLL     -->  executa comandos na Steam
                             le pacotes P2P, chamadas pendentes, membros do lobby
    eventos             <--  responde com a fila de eventos
```

- O Lua escreve um token aleatório em `mpnet.token`, ao lado da DLL, antes de carregá-la. A DLL usa esse token no nome dos pipes, então várias cópias do jogo na mesma máquina não colidem.
- Cada tick é um pedido e uma resposta. O Lua nunca espera por rede, só pela DLL, que responde na hora.
- Se o mod Lua recarregar, a DLL detecta o pipe fechado e reabre.
- Callbacks da Steam são registrados pela DLL e despachados quando o jogo chama `SteamAPI_RunCallbacks`. Chamadas assíncronas, como criar e entrar em lobby, são consultadas por `IsAPICallCompleted` a cada tick.
- Ao entrar num lobby, a DLL aceita sessão P2P com cada membro. Ninguém depende do callback de pedido de sessão.
- Se o jogo foi aberto por um convite, a DLL lê `+connect_lobby` da linha de comando e emite `JOIN_REQUESTED`.

## API Lua

| Função | Efeito |
|---|---|
| `mpnet.start(caminho_da_dll)` | escreve o token e carrega a DLL |
| `mpnet.connect()` | abre os pipes; chamar até devolver true |
| `mpnet.host(max)` | cria lobby só para amigos, 2 a 4 membros |
| `mpnet.join(lobby)` | entra num lobby |
| `mpnet.leave()` | sai do lobby e fecha as sessões P2P |
| `mpnet.invite()` | abre o diálogo de convite do overlay da Steam |
| `mpnet.send(peer, bytes, tipo, canal)` | P2P; tipos `UNRELIABLE`, `UNRELIABLE_NODELAY`, `RELIABLE`, `RELIABLE_BUFFERED` |
| `mpnet.set_lobby_data(k, v)` | metadado do lobby |
| `mpnet.close_peer(peer)` | fecha a sessão com um membro |
| `mpnet.poll()` | envia o que foi enfileirado e devolve a lista de eventos |

SteamIDs são inteiros Lua de 64 bits.

## Eventos

| Código | Nome | Campos |
|---|---|---|
| 1 | `HELLO` | `version`, `self`, `app`, `name` |
| 2 | `ERROR` | `message` |
| 3 | `LOBBY_CREATED` | `result`, `lobby` |
| 4 | `LOBBY_ENTERED` | `lobby`, `response`, `owner` |
| 5 | `MEMBER_JOINED` | `peer`, `name` |
| 6 | `MEMBER_LEFT` | `peer` |
| 7 | `PACKET` | `peer`, `channel`, `data` |
| 8 | `JOIN_REQUESTED` | `lobby`, `friend` (0 quando veio da linha de comando) |
| 9 | `SESSION_FAIL` | `peer`, `error` |
| 10 | `SESSION_REQUEST` | `peer` |

## Comandos no pipe

Quadro: `u32 tamanho` e o conteúdo. Primeiro byte é o código.

| Código | Comando | Argumentos |
|---|---|---|
| 1 | `POLL` | nenhum; pede a resposta |
| 2 | `HOST` | `u8 max` |
| 3 | `JOIN` | `u64 lobby` |
| 4 | `LEAVE` | nenhum |
| 5 | `INVITE` | nenhum |
| 6 | `SEND` | `u64 peer`, `u8 tipo`, `u8 canal`, bytes |
| 7 | `SET_LOBBY_DATA` | `chave\0valor` |
| 8 | `CLOSE_PEER` | `u64 peer` |

Resposta ao `POLL`: `u32 tamanho total`, depois cada evento como `u32 tamanho` e o conteúdo.

## Compilar e testar

```
powershell -ExecutionPolicy Bypass -File native\mpnet\build.ps1
powershell -ExecutionPolicy Bypass -File tools\deploy-test.ps1
```

O build usa o MSVC do Visual Studio 2022, x64, CRT estático. O deploy recusa a pasta da Steam e instala só na cópia de teste. O mod `MpNetTest` roda o autoteste no menu principal e grava `mpnet-test.txt` na pasta do mod.

## Resultado do autoteste, numa instância

Data: 2026-11-07, build Steam 23218978.

| Verificação | Resultado |
|---|---|
| DLL carrega pelo `package.loadlib` | ok |
| Steam já inicializada, app id | 1106840 |
| SteamID real da conta | ok, formato de conta individual conferido |
| P2P para si mesmo, canal confiável e não confiável | os dois chegaram |
| Criar lobby só para amigos, 4 vagas | ok |
| Lista de membros e entrada do próprio usuário | ok |
| Rajada: 300 x 1,1 KB não confiável e 50 x 8 KB confiável | 300/300 e 50/50 |
| Sair do lobby e detectar a saída | ok |
| Callback registrado pela DLL dispara (`LobbyEnter_t`) | ok: o jogo despacha callbacks e a vtable está no formato certo |

Duas execuções seguidas deram o mesmo resultado.

O tempo de ida e volta do loopback foi de cerca de 870 ms no primeiro pacote. Isso inclui a abertura da sessão e a granularidade do laço de teste, que rodou a cerca de 24 ticks por segundo. Não é medida de rede. RTT real exige duas máquinas.

## O que ainda não foi testado

- Duas contas Steam em duas máquinas: P2P real, NAT e relay.
- Convite pelo overlay e o callback de pedido de entrada. O mecanismo de callback foi provado, mas esse callback específico precisa de um amigo convidando.
- Jogo aberto pelo convite com `+connect_lobby`.
- Desempenho do pipe sob carga contínua de 20 a 30 Hz.
- Laço por frame: o teste usou atraso fixo de 16 ms, que na prática rendeu cerca de 24 Hz.
