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

## Pendentes

- **Licença.** Precisa ser escolhida antes de receber contribuição externa. Sugestão: MIT, igual ao UE4SS e ao coop-anything.
- **Whitelist de campos por classe.** Primeira versão em `07-spike.md`, tabela de classes e funções.
- **Idioma da documentação pública.** Português agora. Tradução para inglês quando houver algo jogável.
