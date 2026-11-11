# 02. Registro de decisões

Formato: número, data, decisão, motivo, consequências. Decisões podem ser revertidas, mas a reversão vira uma nova entrada.

## D01. Host autoritativo com pawn oculto (2026-11-07)

**Decisão.** O host simula o mundo inteiro. Para cada cliente existe um jogador local oculto no host, criado com o suporte de split-screen do jogo, com a divisão de tela desativada. Clientes renderizam um espelho do estado.

**Motivo.** Toda a lógica do jogo roda uma vez só, no host. Economia, máquinas e física não precisam ser reescritas, apenas espelhadas. É a arquitetura que o coopnet provou funcionar.

**Consequências.** Toda ação do cliente custa um RTT. Cada sistema visível precisa de espelho explícito. O host paga CPU por pawn oculto.

## D02. Transporte: P2P legado da Steam via SteamCore, em processo (2026-11-07)

**Decisão.** Usar `SendP2PPacket`, `ReadP2PPacket`, sessões P2P e lobbies do plugin SteamCore que já está compilado no jogo. Sem processo externo, sem app 480.

**Motivo.** Chamável por reflexão, usa o app id do Hydroneer, convites pelo overlay funcionam, NAT traversal e relay pela Steam. Objetivo declarado do projeto: hospedar pela rede da Steam.

**Consequências.** API marcada como obsoleta pela Valve, mas funcional. Pacote não confiável limitado a cerca de 1200 bytes, então o fluxo de transformações fragmenta. Upgrade futuro possível para SteamNetworkingSockets pela flat API da DLL, exigindo mod C++, sem mudar o protocolo.

## D03. Sessão só por convite (2026-11-07)

**Decisão.** Lobby com visibilidade "só amigos", entrada por convite ou pela lista de amigos. Sem lobby público listável na primeira versão.

**Motivo.** Um save sem nenhuma proteção não deve receber desconhecidos. Listagem pública fica para depois.

## D04. Pawn do próprio jogador com autoridade no cliente (2026-11-07)

**Decisão.** O cliente move o próprio pawn localmente e envia a pose pronta. O host posiciona o pawn oculto de forma cinemática com essa pose. Não replicamos inputs para o host simular.

**Motivo.** Replicar inputs e reconciliar gerou drift e bugs no coopnet. Em co-op não há motivo para o host desconfiar da posição do amigo.

**Consequências.** Colisões do pawn com itens acontecem no host numa posição até meio RTT atrasada. Antes de executar qualquer ação, o host sincroniza pose e rotação de controle do pawn oculto com a última amostra, e só então invoca a função do controlador.

## D05. Predição só ao pegar item (2026-11-07)

**Decisão.** Pegar anexa o item ao pawn na hora e desfaz se o host negar. Cavar, despejar, lavar, encher, vender e comprar esperam o host. Animações de ferramenta começam localmente.

**Motivo.** Operações de voxel não são reversíveis para "adicionar". A duração da animação esconde o RTT nas demais ações.

## D06. Itens são cinemáticos no cliente (2026-11-07)

**Decisão.** O cliente nunca simula física de item. Corpos acordados no host recebem transformação a 20 Hz; corpos dormindo recebem uma transformação final e saem do fluxo.

**Motivo.** PhysX não é determinístico entre máquinas. Um único dono de simulação elimina divergência.

## D07. Estrutura para 4 jogadores desde o início (2026-11-07)

**Decisão.** Testes iniciais com 2 jogadores, mas slots, ids de entidade, filas de envio por cliente e gancho de relevância são desenhados para 4 desde a primeira linha.

**Motivo.** Esses pontos são baratos agora e caros depois.

## D08. Pular a noite: basta um jogador dormir (2026-11-07)

**Decisão.** Qualquer jogador que dormir dispara o pulo de noite no host. Sem votação.

## D09. Escopo da primeira versão (2026-11-07)

**Dentro.** Andar, cavar, despejar, carregar, soltar, arremessar, encher água, lavar na pan, vender no joalheiro, comprar na loja de equipamentos, moedas como itens, hora do dia, late join por save.

**Fora.** Veículos, modo de construção, NPCs, missões, canos, máquinas. O caminhão só entra na primeira versão se o custo for baixo, e sai se não for.

## D10. Reaproveitar o coopnet, não contribuir diretamente nele (2026-11-07)

**Decisão.** Reutilizar hooks, nomes de classe e aprendizados do hydroneer-coopnet. Arquitetura de transporte, ids e espelho é refeita neste repositório.

**Motivo.** A ponte por arquivo, o processo Python e o pareamento por distância não são base para 4 jogadores.

## D11. Repositório público, documentação antes do código (2026-11-07)

**Decisão.** Tudo documentado em português neste repositório. Nenhum arquivo do jogo commitado.

## D12. Transporte duplo: UDP em loopback para testes, Steam para jogar (2026-11-07)

**Decisão.** A ponte de transporte tem dois modos escolhidos por configuração: `udp` em localhost e `steam` via SteamCore. O protocolo é o mesmo nos dois.

**Motivo.** Um PC só roda uma conta Steam, então duas cópias do jogo numa máquina não conseguem falar pela Steam. O modo UDP permite testar 2 a 4 cópias num PC e colocar o relay de caos do coop-anything no meio.

**Consequências.** A ponte precisa de uma abstração de peer que esconda se o endereço é um SteamID ou um par ip e porta. Nenhum teste automatizado depende da Steam.

## D13. Adotar as ferramentas de teste e o playbook do coop-anything (2026-11-07)

**Decisão.** Usar o playbook como checklist, e as ferramentas `gameslot`, `gamepool`, `chaos`, `animcheck`, `scenarios` e `bots` nos marcos indicados em `06-coop-anything.md`. `flight` entra quando houver desync para caçar. `ownership`, `fuzz`, `fakeworld`, `bridge` e `hotreload` ficam de fora por serem C++ ou por não se aplicarem a autoridade só do host.

**Motivo.** São ferramentas prontas, MIT, Python sem dependências, generalizadas de um projeto que já passou pelos mesmos problemas. Reescrever seria desperdício.

**Consequências.** Nossos scripts de QA ficam em `qa/` e falam com o coop-anything por adaptadores. O commit usado é fixado. Nenhuma cópia do jogo é lançada sem o lock de slot.

## D14. Jogadores extras entram pelo caminho do Remote Play (2026-11-07)

**Decisão.** No host, cada cliente vira um jogador criado por `GM_Hydroneer_C:AddRemotePlayer({SessionID = N})`, com `N` reservado pelo mod. Sai por `RemovePlayer`.

**Motivo.** O spike mostrou que `AddLocalPlayer` aceita só um jogador extra, enquanto o caminho de Remote Play aceitou três, chegando a 4 no total, com custo de cerca de 5 % de frame no host.

**Consequências.** O mod precisa evitar que o jogo tente ler input do Remote Play da Steam para essas sessões falsas. A verificar no marco 2.

## D15. Física em repouso não trafega (2026-11-07)

**Decisão.** O fluxo `XFORM` acompanha só itens que estão simulando física. A detecção usa o próprio estado do jogo, que trava a física de itens assentados.

**Motivo.** Num mundo novo, nenhum dos 557 itens simulava física depois de assentar.

## D16. Steam por DLL nativa companheira, não pelo SteamCore (2026-11-07)

**Decisão.** A `mpnet.dll`, em C++, é carregada pelo Lua com `package.loadlib` e chama a API flat da `steam_api64.dll` do próprio jogo: P2P legado, lobby, overlay e callbacks. Conversa com o Lua por dois pipes nomeados, num ciclo de pedido e resposta por tick. Detalhes em `08-mpnet.md`.

**Motivo.** A SteamID do SteamCore chega vazia ao Lua do UE4SS, o que inutiliza P2P, lobby e convite pela reflexão. As alternativas eram compilar o UE4SS a partir do código-fonte, que depende de conta GitHub vinculada à Epic, ou instalar o editor Unreal 4.26 para uma ponte Blueprint.

**Consequências.** D02 continua valendo no protocolo e no app id; muda só a implementação. O projeto passa a ter um binário nativo, compilado com o Visual Studio 2022. O autoteste numa instância passou: SteamID real, P2P nos dois canais, lobby, rajada completa e callbacks.

## D17. Personagem remoto anda por comandos de movimento, não por teleporte (2026-11-07)

**Decisão.** Bonecos nos clientes e pawns ocultos no host recebem `AddMovementInput` em direção à pose recebida, mirando 100 ms à frente pela velocidade. Teleporte só acima de 3 m de erro. Bonecos sem controlador ligam `bRunPhysicsWithNoController`.

**Motivo.** Teleporte por frame trava a animação de passo. No teste espelho, a animação acompanhou em 99,7% das amostras; entre duas instâncias, o erro em movimento ficou em 16 cm.

## D18. Terreno: quem cava aplica na hora, o host define a ordem para os outros (2026-11-07)

**Decisão.** Edições locais são aplicadas pelo próprio jogo. O cliente manda ao host; o host aplica e repassa com sequência aos demais, menos à origem. O host manda as próprias edições a todos. Edições recebidas são aplicadas com a mesma chamada do Voxel Plugin, no mundo de voxel com o mesmo nome.

**Motivo.** Sem latência para quem cava. As funções de esfera são determinísticas para a mesma entrada.

**Consequências.** Duas escavações simultâneas no mesmo lugar podem divergir em ordem. Aceito por ora.

## D19. Nunca deixar um hook ler parâmetros dentro de chamada iniciada pelo Lua (2026-11-07)

**Decisão.** Toda chamada do mod que possa chegar a uma função com hook roda sob trava, e o hook sai sem ler nada. O hook de terreno grava um marcador antes de ler parâmetros; se o jogo fechar, o próximo início desliga a sincronização de terreno.

**Motivo.** Com o UE4SS 1217, ler o primeiro parâmetro do hook dentro de uma escavação chamada pelo Lua derrubou o jogo com acesso a endereço nulo.

## D20. Testes com várias cópias por UDP local, Steam só no jogo real (2026-11-07)

**Decisão.** A `mpnet.dll` ganhou o modo UDP de D12, feito por um agente com contrato fixo. Os testes rodam duas cópias por hardlink, com `tools/run-test.ps1` e robôs configurados em `mp-config.txt`. O harness `tools/mpnet_harness.py` testa a ponte sem o jogo.

**Motivo.** Uma conta Steam por máquina impede testar dois jogadores pela Steam num PC.

## D21. O cliente entra no mundo do host pelo save (2026-11-10)

**Decisão.** Ao entrar, o cliente recebe o save do host e o carrega como `MpHydroneerHost`. O mundo do próprio cliente é salvo antes. Feito por um agente, em `lua/savesync.lua`; detalhes em `10-savesync.md`.

**Motivo.** Terreno, itens e dinheiro precisam começar iguais. Depois de carregar o mesmo save, os nomes dos itens coincidem, o que permite associá-los.

## D22. Ações do cliente executadas no host, com o alvo que o cliente via (2026-11-10)

**Decisão.** Substitui a parte de D18 sobre o cliente aplicar as próprias escavações. O cliente não executa ações de mundo; manda tecla e alvo (item por id, objeto do mapa por caminho). O host aponta `LastThingLookingAt` do controlador oculto para o alvo e chama o evento de entrada.

**Motivo.** A mira reproduzida no host erra por centímetros e não acerta itens pequenos; o alvo explícito acerta sempre. Um único caminho cobre pegar, cavar, lavar, comprar, vender e dormir.

## D23. Terreno alterado numa ação do cliente vai como retalho de voxels (2026-11-10)

**Decisão.** Se o hook acusa edição dentro da chamada do mod, o host lê um cubo de voxels ao redor do ponto da mira (13³ com voxel de 20 cm) e manda os valores; o cliente grava os que diferem.

**Motivo.** A escavação da pá roda dentro do evento de clique, e ler parâmetros do hook ali derruba o jogo (D19). Copiar o resultado é exato e independe da ferramenta.

## D24. Itens: host dono, cliente sem física (2026-11-10)

**Decisão.** Itens do cliente não simulam física; seguem posições e estado do host. Associação pelo nome, com reserva por classe e posição.

## Pendentes

- **Licença.** Precisa ser escolhida antes de receber contribuição externa. Sugestão: MIT, igual ao UE4SS e ao coop-anything.
- **Whitelist de campos por classe.** Primeira versão em `07-spike.md`, tabela de classes e funções.
- **Idioma da documentação pública.** Português agora. Tradução para inglês quando houver algo jogável.
