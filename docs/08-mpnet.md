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
| 11 | `PEER_STATE` | `peer`, `active`, `connecting`, `error`, `relay`, `bytes_queued`, `packets_queued` |

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
| 9 | `SET_TITLE` | texto UTF-8 do título da janela |
| 10 | `PEER_STATE` | nenhum; gera um `PEER_STATE` por par aceito |

Resposta ao `POLL`: `u32 tamanho total`, `u64 relógio em microssegundos`, depois cada evento como `u32 tamanho` e o conteúdo. O relógio vira `mpnet.now_us` no Lua.

## Regra de ouro: a thread do pipe nunca espera a thread do jogo

Durante o `POLL`, a thread do jogo está parada esperando a resposta. Qualquer chamada na DLL que dependa da thread do jogo trava os dois. Aconteceu na versão 2 com `SetWindowTextW`, que manda uma mensagem para a janela e espera a thread dona processar. O jogo congelou no segundo tick. A correção foi aplicar o título numa thread própria. Toda chamada nova da DLL deve ser conferida contra essa regra.

## Modo UDP

Duas cópias do jogo no mesmo PC não conversam pela Steam, porque usam a mesma conta. O modo UDP troca a Steam por UDP no localhost e mantém os mesmos comandos, eventos e quadros do pipe. O Lua não precisa saber qual transporte está ativo. Código em `native/mpnet/mpnet_udp.cpp`.

### Como ativar

A linha 2 do `mpnet.token` escolhe o modo. A linha 1 continua sendo o token. Espaços e `\r\n` no fim das linhas são ignorados.

| Linha 2 | Efeito |
|---|---|
| ausente ou `steam` | Steam, como antes |
| `udp host <porta>` | host UDP em `127.0.0.1:<porta>` |
| `udp client <ip>:<porta>` | cliente do host nesse endereço; `localhost` vale como `127.0.0.1` |

Qualquer outra coisa gera `ERROR` e a DLL só responde ao `POLL`. No modo UDP a DLL não chama `load_steam()` e funciona sem a `steam_api64.dll`, até num processo Python comum. O host escuta só no loopback para não disparar o aviso do firewall do Windows; o modo serve para teste local, não para LAN.

### Identidade

| Item | Valor |
|---|---|
| id próprio | `0x7F00000000000000 \| porta UDP local` |
| id do host | `0x7F00000000000000 \| porta do host` |
| nome | `udp-<porta>` |
| lobby | `0x7E00000000000001`, fixo |
| `HELLO` | `version` 3, `app` 0 |

O cliente usa uma porta efêmera, então o id dele muda a cada execução.

### Comandos

| Comando | Modo UDP |
|---|---|
| `HOST` | só no host. Abre a sala e emite `LOBBY_CREATED(1, lobby)`, `LOBBY_ENTERED(lobby, 1, self)` e `MEMBER_JOINED(self)`, a mesma sequência da Steam. `max` vale de 2 a 4, contando o host |
| `JOIN` | só no cliente; o argumento é ignorado. Manda HELLO a cada 250 ms. Ao ser aceito, emite `LOBBY_ENTERED(lobby, 1, host)` e um `MEMBER_JOINED` por membro, na ordem da lista do host, incluindo host e o próprio cliente. Sala cheia: `LOBBY_ENTERED(lobby, 4, 0)`, o mesmo código de sala cheia da Steam. Sem resposta em 10 s: `ERROR` |
| `LEAVE` | cliente manda BYE e emite `MEMBER_LEFT` de todos, ele por último. Host manda BYE para todos e faz o mesmo; cada cliente que recebe o BYE também |
| `SEND` | tipos 0 e 1: não confiável, até 1.200 bytes de carga. Tipos 2 e 3: confiável e em ordem por remetente, destinatário e canal, até 1 MB. Fora desses limites, canal acima de 3 ou destino fora da sala, o envio é descartado com linha no `mpnet.log`. Enviar para si mesmo gera `PACKET` local, como na Steam |
| `CLOSE_PEER` | no host, remove o cliente: ele recebe BYE e sai. No cliente não faz nada |
| `PEER_STATE` | um `PEER_STATE` por membro, sem o próprio, como na Steam: `active` 1, `connecting` 0, `error` 0, `relay` 1 só entre clientes. `bytes_queued` e `packets_queued` são os fragmentos confiáveis ainda sem ack |
| `INVITE`, `SET_LOBBY_DATA` | sem efeito |
| `SET_TITLE` | igual nos dois modos |

### Topologia e eventos

A rede é uma estrela: o cliente só conhece o endereço do host. O que um cliente manda para outro passa pelo host, que repassa. O `PACKET` chega com `peer` igual ao remetente original. O host usa o endereço de origem do datagrama para saber quem mandou, não o campo do pacote.

O host guarda a lista da sala, com no máximo 4 membros, ele incluído. Quando a lista muda, ele a manda para todos os clientes com um número de versão. Cada cliente compara com a lista anterior e emite `MEMBER_JOINED` e `MEMBER_LEFT` da diferença.

Keepalive a cada 1 s nos dois sentidos: o cliente manda PING e o host reenvia a lista. Um par calado por 5 s cai. No host, isso gera `MEMBER_LEFT` e uma lista nova. No cliente que perde o host, gera `MEMBER_LEFT` de todos, ele por último, e o cliente volta a ficar fora da sala.

### Confiabilidade

- É garantida por salto, entre cliente e host, com um fluxo por canal. No relay, o host remonta a mensagem e a enfileira no enlace do destino. Isso preserva a ordem por remetente.
- Cada mensagem vira fragmentos de até 1.200 bytes de datagrama, com 24 bytes de cabeçalho. Cada fragmento tem uma sequência `u32` por enlace e canal.
- Janela deslizante de 256 fragmentos em voo. O receptor confirma com ack cumulativo e uma máscara de 64 bits para o que chegou fora de ordem. Os acks saem uma vez por lote recebido.
- Fragmento sem ack é reenviado a cada 100 ms. Se o fragmento mais antigo ficar 10 s sem ack, sai `SESSION_FAIL(peer, 4)` e o par cai como se tivesse ficado calado. O código 4 é o mesmo de timeout da Steam.

Datagramas: todos começam com `u8 0xA7` e `u8 tipo`.

| Tipo | Conteúdo |
|---|---|
| 1 HELLO | `u32 versão`, `u32 nonce` (novo a cada JOIN) |
| 2 ROSTER | `u32 versão da lista`, `u8 n`, `n x u64 id` |
| 3 REFUSE | `u32 resposta` |
| 4 PING | nada |
| 5 BYE | nada; enviado 3 vezes |
| 6 UNREL | `u8 canal`, `u64 de`, `u64 para`, dados |
| 7 REL | `u8 canal`, `u8 flags` (1 primeiro, 2 último), `u32 seq`, `u64 de`, `u64 para`, dados |
| 8 ACK | `u8 canal`, `u32 próximo esperado`, `u64 máscara` |

### Threads

O socket fica numa thread de rede própria. Ela cuida do `recvfrom`, dos acks, do keepalive, da retransmissão e dos timeouts, e põe os eventos na fila comum. A thread do pipe executa os comandos na hora: enfileira e faz o `sendto` não bloqueante. As duas threads dividem um mutex, que nenhuma delas segura enquanto espera. A regra de ouro continua valendo: nada no modo UDP espera a thread do jogo.

### Harness de teste

`tools/mpnet_harness.py` testa o modo UDP sem o jogo:

```
powershell -ExecutionPolicy Bypass -File native\mpnet\build.ps1
python tools\mpnet_harness.py
```

Cada participante é um processo Python. Ele copia a DLL para uma pasta temporária própria, escreve o `mpnet.token`, carrega a DLL com `ctypes` e roda o laço do Lua a 60 Hz. O orquestrador comanda cada processo por JSON e confere os eventos. A saída é uma tabela PASS/FAIL, com código de saída 0 só se tudo passar. Com `--keep`, as pastas temporárias e os `mpnet.log` ficam guardados.

O teste cobre:

- `ERROR` sobre a Steam num processo sem `steam_api64.dll`
- `HELLO`, `HOST`, `JOIN` e a lista de membros em todos os lados
- não confiável de 1.200 bytes nos dois sentidos; acima disso, recusado
- confiável: 200 KB, 1 MB e 500 mensagens em ordem
- relay entre clientes com o remetente certo, confiável e não confiável
- `PEER_STATE`, `LEAVE` de cliente e de host, `CLOSE_PEER` e o 5º membro recusado
- timeout de 5 s ao matar um cliente e ao matar o host
- `ERROR` de `JOIN` sem host em 10 s
- uma segunda sala com 20% de perda simulada: retransmissão, ordem e nenhuma duplicata

A perda vem da variável de ambiente `MPNET_UDP_LOSS=<0..90>`, a porcentagem de datagramas enviados que a DLL descarta. Ela só existe para teste. Sem a variável, nada é descartado.

Não coberto pelo harness: o `SESSION_FAIL` após 10 s sem ack. Ele exige um par que responde ao keepalive mas nunca confirma dados.

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

## Pacote de teste para jogadores: MpPing 0.1

O mod `mod/MpPing` testa a conexão entre amigos. F8 cria a sala e abre o convite da Steam, e quem aceita entra sozinho. Todos medem ping entre si, quatro vezes por segundo no canal não confiável e a cada 2 s no confiável. Depois de 15 s, cada um envia 10 s de tráfego a 120 pacotes de 1,1 KB por segundo, cerca de 1 Mbit/s. O status vai para o título da janela, e o relatório para `%LOCALAPPDATA%\HydroneerMP\relatorio.txt`.

Montagem:

```
powershell -ExecutionPolicy Bypass -File tools\build-package.ps1 -Ue4ssZip <UE4SS_v3.0.1-1217-g4fb9b615.zip>
```

O pacote em `dist/` tem `Instalar.bat`, `Desinstalar.bat`, `Abrir relatorio.bat` e `LEIA-ME.txt`. O instalador acha o jogo pela Steam, confere a versão, faz backup de qualquer arquivo que já exista e guarda a lista do que instalou. Se o UE4SS já estiver instalado por outro mod, só adiciona o MpPing.

Autoteste numa instância, com a própria conta como par:

| Medida | Resultado |
|---|---|
| Laço | 60 ticks por segundo, por frame |
| Ping em regime | 33 ms, o equivalente a 2 frames de laço |
| Primeiro ping | 945 ms, abertura da sessão |
| Banda | 1.198 de 1.200 pacotes, 1 Mbit/s por 10 s |

Teste do pacote numa cópia limpa do jogo: o zip extraído instalou 9 arquivos, o jogo subiu com o mod e o título certo, e a desinstalação deixou a pasta idêntica à original.

### Primeiro teste real entre dois PCs (2026-11-07)

Dois jogadores, cada um na sua casa, com o pacote 0.1 e o build Steam 23218978. O host apertou F8 e convidou pelo overlay. O amigo aceitou o convite e entrou sozinho. A sala ficou aberta por cerca de 33 s depois da entrada.

O relatório 0.1 registra a média acumulada, que fica inflada pelos pings da abertura da sessão. A tabela usa a média de cada janela de 5 s, calculada a partir dos totais acumulados.

| Medida | Host | Amigo |
|---|---|---|
| Ping em regime, por janela de 5 s | 82 a 89 ms | 83 a 88 ms |
| Banda recebida, 10 s a 120 pacotes/s | 1.198/1.200, 1.059 kbit/s | 1.196/1.200, 1.057 kbit/s |
| Perda de ping em regime | 0% | 0% |
| Rota P2P | direta | direta |
| Abertura da sessão P2P | cerca de 5 s, primeiros pings até 5,2 s | igual |
| Laço do jogo | 58 a 60 ticks/s | 57 a 60 ticks/s |

Leitura:

- O ping medido inclui cerca de 33 ms do laço do jogo, visto no autoteste local. A rede entre as casas fica perto de 50 ms.
- O ping não mudou durante o teste de banda.
- A sessão P2P leva uns 5 s para abrir nos dois lados. O protocolo precisa esperar a sessão confirmar antes de mandar estado do mundo.

Bug encontrado: ao receber `JOIN_REQUESTED` para a sala em que já estava, o mod saiu e tentou entrar de novo. Como o host saiu no mesmo instante, a entrada falhou com resposta 2, sala inexistente. A correção é ignorar convite para a sala atual. A causa do segundo convite não foi identificada; a hipótese mais provável é um segundo clique no convite antigo do chat.

Melhorias para o 0.2: ping por janela, sem a abertura da sessão; FPS de cada lado junto com o ping; a correção acima.

Não testado ainda: rota pelo relay da Steam e sessões longas.

## O que ainda não foi testado

- Duas contas Steam em duas máquinas: P2P real, NAT e relay.
- Convite pelo overlay e o callback de pedido de entrada. O mecanismo de callback foi provado, mas esse callback específico precisa de um amigo convidando.
- Jogo aberto pelo convite com `+connect_lobby`.
- Desempenho do pipe sob carga contínua de 20 a 30 Hz.
- Laço por frame: o teste usou atraso fixo de 16 ms, que na prática rendeu cerca de 24 Hz.
