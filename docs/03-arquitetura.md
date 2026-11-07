# 03. Arquitetura

## Visão geral

```
            Steam P2P (relay quando NAT falha)
Cliente A  <---------------------------->  HOST
Cliente B  <---------------------------->  roda o jogo completo
Cliente C  <---------------------------->  P1 real + P2, P3, P4 ocultos
```

- Topologia em estrela. Cada cliente mantém uma sessão P2P só com o host. Clientes não falam entre si.
- O host é o único que simula física, terreno, economia e tempo.
- Cada cliente roda o jogo completo, carrega o mesmo save, mas desliga a simulação do que não é dele e espelha o estado recebido.

## Componentes por máquina

| Componente | Onde | Função |
|---|---|---|
| Mod Lua UE4SS | host e cliente | hooks nas funções do jogo, aplicação de estado, captura de ações |
| Mod de ponte (Blueprint via Workshop, ou C++ via UE4SS) | host e cliente | lobby, sessão P2P, envio e recepção de bytes, eventos da Steam |
| Jogo | host | simula tudo |
| Jogo | cliente | renderiza, move o próprio pawn, espelha o resto |

O mod Lua chama a ponte por reflexão. A ponte não conhece o jogo; só transporta bytes por slot.

## Slots

- Slot 0: host.
- Slots 1 a 3: um por cliente, atribuído no join. No host, cada slot corresponde a um jogador local oculto criado com `AddLocalPlayer`, com split-screen desativado.
- Toda mensagem carrega o slot de origem.
- Ao sair, o slot é liberado: o pawn oculto solta o que carrega e é removido.

## Puppets

No cliente, os outros jogadores são personagens spawnados sem controlador, não jogadores locais. Motivo: jogador local cria viewport, HUD e disputa de input. O puppet recebe posição, rotação, modo de movimento e velocidade, e interpola.

## Sincronizar pose, depois invocar

Antes de executar um pedido de ação de um cliente, o host:
1. posiciona o pawn oculto com a última pose recebida;
2. aplica a rotação de controle recebida;
3. chama a função do controlador, passando a localização explícita quando a função aceita.

Funções que fazem trace a partir da câmera passam a enxergar o que o cliente enxergava.

## Matriz de sincronização

| Elemento | Autoridade | O que trafega | Canal | O cliente faz sozinho |
|---|---|---|---|---|
| Terreno voxel | Host | operações de esfera, ordenadas | confiável | aplica a mesma operação |
| Próprio pawn | Cliente | pose e modo de movimento | não confiável | movimento e câmera |
| Pawns dos outros | Host retransmite | amostras dos outros slots | não confiável | puppet interpolado |
| Itens: existência | Host | spawn e destroy com id | confiável | nada |
| Itens: transformação | Host, só corpos acordados | posição e rotação quantizadas | não confiável | corpo cinemático, interpola |
| Itens: quem carrega | Host | campo "carregado por" | confiável | anexa ao pawn, predição ao pegar |
| Itens: campos de estado | Host | delta por whitelist | confiável | nada |
| Cavar e despejar | Host executa | pedido com ponto e rotação | confiável | inicia animação |
| Lavar, encher, vender, comprar | Host | pedido; resultado volta como spawn ou campo | confiável | inicia animação |
| Hora do dia | Host | amostra | não confiável | avança entre amostras |
| Dormir | Host | pedido | confiável | nada |
| Sons e animações | evento | sem resposta | não confiável | reproduz |
| HUD, menus, configurações, áudio | local | nada | | tudo |
| Pausa por ESC | bloqueada no host | nada | | hook impede pausar o tempo |
| Save | Host | save no late join | confiável | cache local, nunca autosave no slot real |

## Taxas iniciais

| Fluxo | Taxa |
|---|---|
| Transformações de itens acordados | 20 Hz |
| Pawns | 30 Hz |
| Hora do dia | 1 Hz |
| Pedidos e eventos | imediato |

Estimativa de banda por cliente, antes de relevância:

| Itens acordados | Taxa | Banda |
|---|---|---|
| 500 | 20 Hz | ~1 Mbps |
| 2000 | 10 Hz | ~2 Mbps |

O host envia um fluxo por cliente. Serializar uma vez por tick e reutilizar o buffer para todos enquanto não houver filtro de relevância.

## Ids de entidade

- O host atribui um inteiro crescente de 32 bits a cada item que entra no mundo.
- Spawn carrega: id, caminho da classe, transformação, campos iniciais.
- Reconciliação no carregamento: o cliente abre o mesmo save, recebe um snapshot do host, pareia por classe e posição com raio apertado, apaga o que não pareou e spawna o que faltou. A partir daí só existem ids.
- Itens carregados não trafegam transformação; trafegam "carregado por slot N" e o cliente anexa ao pawn ou puppet local.

## Canais

O P2P legado da Steam aceita tipo de envio por pacote.

| Canal | Tipo | Conteúdo |
|---|---|---|
| 0 | confiável | controle de sessão, spawn, destroy, terreno, campos, pedidos, save |
| 1 | não confiável | transformações, pawns, hora, eventos |

- Pacote não confiável limitado a cerca de 1200 bytes. Com 12 bytes por item, cerca de 90 itens por pacote. Fragmentar por tick e marcar com sequência; o receptor descarta sequência antiga.
- Mensagens grandes no canal confiável, como o save de late join, vão em blocos com hash.

## Relevância

Primeira versão sem filtro, com medição. Segunda versão: por cliente, itens acordados dentro de um raio, mais tudo que qualquer slot carrega, mais itens tocados por um pedido recente.

## Late join

1. Cliente entra no lobby e recebe slot.
2. Host salva num slot dedicado.
3. Save vai pelo canal confiável em blocos, verificado por hash.
4. Cliente carrega o save, desliga simulação local, recebe snapshot de ids.
5. Host reenvia as operações de terreno posteriores ao número de sequência do save.
6. Cliente entra em modo espelho e começa a enviar pose.

## Saída e falhas

- Cliente cai: host solta o que o pawn oculto carrega, remove o pawn, libera o slot.
- Host cai: sessão acaba. Clientes voltam ao menu. Não há migração de host na primeira versão.
- Versão do mod é verificada no join. Versão do jogo também, pelo build id.

## Riscos conhecidos

- Atualização do jogo quebra hooks. Pinar por build id, igual ao coopnet.
- O jogo pode ter caminhos que assumem um único jogador real por máquina, como menus, mapa e autosave.
- Água em baldes e pans: o coopnet sincroniza os campos mas a malha da água nem sempre atualiza. Precisa de investigação no spike.
- Lua do UE4SS não documenta criação de TArray de bytes. A ponte resolve isso expondo funções de string ou de array já alocado.
