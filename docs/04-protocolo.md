# 04. Protocolo (rascunho)

Binário, little-endian. Todo pacote começa com um cabeçalho. Campos de posição em centímetros do Unreal, quantizados.

## Cabeçalho

| Campo | Tipo | Nota |
|---|---|---|
| versão | u8 | versão do protocolo |
| canal | u8 | 0 confiável, 1 não confiável |
| slot origem | u8 | 0 host |
| sequência | u16 | por canal e por origem |
| contagem | u8 | mensagens no pacote |

## Quantização

| Dado | Formato | Precisão |
|---|---|---|
| posição | 3 x i32 em cm | 1 cm, suficiente para o mapa inteiro |
| posição relativa a âncora | 3 x i16 | 1 cm dentro de 327 m de uma âncora, usado em itens |
| rotação | quaternion "smallest three", 32 bits | ~0,02 grau |
| yaw e pitch de controle | 2 x i16 | 0,005 grau |
| velocidade | 3 x i16 em cm/s | |

## Mensagens do cliente para o host

| Tipo | Campos | Canal |
|---|---|---|
| `HELLO` | versão do mod, build id do jogo, nome | 0 |
| `POSE` | posição, yaw, pitch, velocidade, modo de movimento, flags (agachado, correndo, pulando) | 1 |
| `ACT_DIG` | ponto de impacto, normal, yaw, pitch, id da ferramenta | 0 |
| `ACT_DUMP` | ponto, yaw, pitch, id da ferramenta | 0 |
| `ACT_PICKUP` | id do item | 0 |
| `ACT_DROP` | id do item, impulso | 0 |
| `ACT_USE_PRIMARY` | id do item, ponto, yaw, pitch | 0 |
| `ACT_USE_SECONDARY` | id do item, ponto, yaw, pitch | 0 |
| `ACT_BUTTON` | id do ator de botão | 0 |
| `ACT_SLEEP` | | 0 |
| `LOADED` | sequência de terreno do save carregado | 0 |
| `PING` | tempo local | 1 |

## Mensagens do host para o cliente

| Tipo | Campos | Canal |
|---|---|---|
| `WELCOME` | slot, lista de slots ocupados, sequência de terreno atual | 0 |
| `DENY` | motivo | 0 |
| `SPAWN` | id, classe (índice numa tabela enviada em `WELCOME`), posição, rotação, campos iniciais | 0 |
| `DESTROY` | id | 0 |
| `XFORM` | âncora, N x (id, posição relativa i16, rotação) | 1 |
| `SLEEP` | id, posição, rotação final | 0 |
| `CARRY` | id, slot ou 255 para ninguém | 0 |
| `FIELDS` | id, N x (índice do campo, valor) | 0 |
| `TERRAIN` | sequência, operação, posição, raio, valor, flags | 0 |
| `PAWNS` | N x (slot, posição, yaw, pitch, velocidade, modo, flags) | 1 |
| `TIME` | hora do dia | 1 |
| `EVENT` | tipo, slot, id, posição | 1 |
| `SAVE_BEGIN` | tamanho, hash, número de blocos | 0 |
| `SAVE_BLOCK` | índice, bytes | 0 |
| `SNAPSHOT` | N x (id, classe, posição, rotação) | 0 |
| `SLOT_LEFT` | slot | 0 |
| `PONG` | tempo do cliente, tempo do host | 1 |

## Regras

- O cliente nunca aplica uma ação localmente, exceto a predição de `ACT_PICKUP` e o início de animações.
- O host responde `ACT_PICKUP` com `CARRY`. Se o `CARRY` vier com outro slot, o cliente desfaz a predição.
- `XFORM` só contém corpos acordados. Um corpo que dorme recebe `SLEEP` uma vez.
- `FIELDS` usa índices numa whitelist por classe, publicada em `WELCOME`. A whitelist nasce do dump das classes no spike.
- Sequência de `TERRAIN` é global e crescente. O cliente aplica em ordem e guarda a última. Late join reenvia a partir da última do save.
- Tudo que o cliente envia por canal 1 pode ser perdido sem efeito permanente.
