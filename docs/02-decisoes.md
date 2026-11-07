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

## Pendentes

- **Licença.** Precisa ser escolhida antes de receber contribuição externa. Sugestão: MIT, igual ao UE4SS e ao coop-anything.
- **Ponte Blueprint ou C++.** Depende do spike: o modkit oficial precisa expor as classes do SteamCore para o mod de ponte compilar em Blueprint. Se não expuser, a ponte vira mod C++ do UE4SS.
- **Whitelist de campos por classe.** Depende do dump das classes no spike.
- **Idioma da documentação pública.** Português agora. Tradução para inglês quando houver algo jogável.
