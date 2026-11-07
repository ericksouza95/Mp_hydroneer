// mpnet_udp.cpp: transporte UDP local, sem Steam, para testar varias copias do jogo no
// mesmo PC (uma conta Steam so nao conversa consigo mesma entre processos).
//
// Ativado pela linha 2 do mpnet.token:
//   udp host <porta>          -> host, escuta em 127.0.0.1:<porta>
//   udp client <ip>:<porta>   -> cliente desse host
//
// Topologia em estrela: o cliente so conhece o endereco do host. Mensagens de cliente
// para cliente passam pelo host, que repassa mantendo o remetente original.
//
// Threads:
//   - thread do pipe (mpnet.cpp) chama udp_command(): enfileira e envia na hora, sem esperar.
//   - thread de rede (net_thread): dona do recvfrom, dos acks, dos timers e da retransmissao.
//   As duas usam o mesmo mutex g_mu, sempre por pouco tempo. Nenhuma espera a thread do jogo.
//
// Confiabilidade (tipos 2 e 3): por salto (cliente<->host), por canal. Cada mensagem vira
// fragmentos de ate 1200 bytes de datagrama, com numero de sequencia u32 por (enlace, canal).
// Janela deslizante de 256 fragmentos, ack cumulativo + mascara seletiva de 64 bits,
// retransmissao apos 100 ms, desistencia apos 10 s sem ack (EV_SESSION_FAIL e o par cai).
//
// Formato dos datagramas (little-endian), todos comecam com u8 MAGIC, u8 tipo:
//   HELLO   u32 versao, u32 nonce               cliente -> host, a cada 250 ms ate entrar
//   ROSTER  u32 versao, u8 n, n x u64 id        host -> cliente; tambem serve de keepalive
//   REFUSE  u32 resposta (4 = sala cheia)       host -> cliente
//   PING    nada                                cliente -> host, keepalive
//   BYE     nada                                qualquer lado, saida
//   UNREL   u8 canal, u64 de, u64 para, dados
//   REL     u8 canal, u8 flags, u32 seq, u64 de, u64 para, dados   (flags: 1 primeiro, 2 ultimo)
//   ACK     u8 canal, u32 proximo esperado, u64 mascara (bit i = seq proximo+1+i recebido)

#define WIN32_LEAN_AND_MEAN
#define _CRT_SECURE_NO_WARNINGS
#include <winsock2.h>
#include <ws2tcpip.h>

#include "mpnet_common.h"

#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <vector>

#ifndef SIO_UDP_CONNRESET
#define SIO_UDP_CONNRESET _WSAIOW(IOC_VENDOR, 12)
#endif

namespace {

const u64 ID_PREFIX = 0x7F00000000000000ull;
const u64 FAKE_LOBBY = 0x7E00000000000001ull;

const u8 MAGIC = 0xA7;
enum : u8 { K_HELLO = 1, K_ROSTER = 2, K_REFUSE = 3, K_PING = 4, K_BYE = 5, K_UNREL = 6, K_REL = 7, K_ACK = 8 };

const size_t MAX_DGRAM = 1200;                 // datagrama de fragmento confiavel
const size_t REL_HDR = 2 + 1 + 1 + 4 + 8 + 8;  // magic, tipo, canal, flags, seq, de, para
const size_t FRAG_MAX = MAX_DGRAM - REL_HDR;
const size_t UNREL_MAX = 1200;                 // carga util de um envio nao confiavel
const size_t REL_MAX_MSG = 1u << 20;           // mensagem confiavel maxima
const size_t WINDOW = 256;                     // fragmentos em voo por (enlace, canal)
const u32 RECV_AHEAD = 4096;                   // quanto adiante o receptor guarda fora de ordem
const int CHANNELS = 4;

const u64 RTO_MS = 100;
const u64 GIVEUP_MS = 10000;
const u64 KEEPALIVE_MS = 1000;
const u64 TIMEOUT_MS = 5000;
const u64 HELLO_RETRY_MS = 250;
const u64 JOIN_TIMEOUT_MS = 10000;

const u32 RESP_OK = 1;
const u32 RESP_FULL = 4;  // mesmo valor de k_EChatRoomEnterResponseFull na Steam
const u8 FAIL_TIMEOUT = 4;  // mesmo valor de k_EP2PSessionErrorTimeout

struct Frag {
    u32 seq = 0;
    u64 to = 0;
    size_t payload = 0;
    std::string dg;
    u64 first_ms = 0;  // 0 = ainda nao enviado
    u64 last_ms = 0;
    bool acked = false;
};

struct TxStream {
    u32 next_seq = 0;
    std::deque<Frag> q;  // frente = mais antigo nao confirmado
};

struct RxStream {
    u32 expected = 0;
    std::map<u32, std::string> ooo;  // fora de ordem, datagrama inteiro
    std::string msg;
    u64 from = 0, to = 0;
    bool in_msg = false;
    bool ack_dirty = false;
};

struct Link {
    u64 id = 0;
    sockaddr_in addr{};
    u32 nonce = 0;
    u64 last_recv_ms = 0;
    u64 last_ping_ms = 0;
    TxStream tx[CHANNELS];
    RxStream rx[CHANNELS];
};

enum ClientState { C_IDLE, C_JOINING, C_IN };

std::mutex g_mu;
SOCKET g_sock = INVALID_SOCKET;
bool g_is_host = false;
u16 g_cfg_port = 0;        // host: porta local; cliente: porta do host
in_addr g_cfg_ip{};        // cliente: ip do host
u64 g_self_id = 0;
u64 g_host_id = 0;

// host
bool g_hosting = false;
int g_max_members = 4;
u32 g_roster_ver = 0;
std::vector<std::unique_ptr<Link>> g_clients;

// cliente
ClientState g_cstate = C_IDLE;
Link g_hlink;  // enlace com o host
u64 g_join_start_ms = 0, g_last_hello_ms = 0;
u32 g_known_ver = 0;
std::vector<u64> g_roster;

// So para teste: MPNET_UDP_LOSS=<0..90> descarta essa porcentagem dos datagramas enviados,
// para exercitar a retransmissao. Sem a variavel, nada e descartado.
u32 g_loss_pct = 0;
u32 g_rng = 0x9E3779B9u;

u64 now_ms() { return now_us() / 1000; }

// Tempo decorrido sem estouro: marcas feitas por now_ms() fresco podem ser mais novas que o
// "now" capturado no inicio de uma volta da thread de rede.
u64 since(u64 now, u64 t) { return now > t ? now - t : 0; }

bool seq_lt(u32 a, u32 b) { return (int32_t)(a - b) < 0; }

bool contains(const std::vector<u64>& v, u64 x) {
    for (u64 y : v) if (y == x) return true;
    return false;
}

bool same_addr(const sockaddr_in& a, const sockaddr_in& b) {
    return a.sin_port == b.sin_port && a.sin_addr.s_addr == b.sin_addr.s_addr;
}

std::string name_of(u64 id) { return "udp-" + std::to_string((unsigned)(id & 0xFFFF)); }

std::string addr_str(const sockaddr_in& a) {
    char ip[32] = {0};
    inet_ntop(AF_INET, &a.sin_addr, ip, sizeof ip);
    return std::string(ip) + ":" + std::to_string(ntohs(a.sin_port));
}

// ---------------------------------------------------------------- eventos

void ev_joined(u64 id) { push_event(Writer().u8_(EV_MEMBER_JOINED).u64_(id).str(name_of(id).c_str()).s); }
void ev_left(u64 id) { push_event(Writer().u8_(EV_MEMBER_LEFT).u64_(id).s); }
void ev_packet(u64 from, int ch, const void* p, size_t n) {
    push_event(Writer().u8_(EV_PACKET).u64_(from).u8_((u8)ch).bytes(p, n).s);
}

// ---------------------------------------------------------------- envio cru

void send_raw(const sockaddr_in& to, const std::string& dg) {
    if (g_loss_pct) {  // sempre sob g_mu, entao o gerador nao precisa de trava propria
        g_rng ^= g_rng << 13;
        g_rng ^= g_rng >> 17;
        g_rng ^= g_rng << 5;
        if (g_rng % 100 < g_loss_pct) return;
    }
    int r =sendto(g_sock, dg.data(), (int)dg.size(), 0, (const sockaddr*)&to, sizeof to);
    if (r == SOCKET_ERROR) {
        int e = WSAGetLastError();
        if (e != WSAEWOULDBLOCK) logf("UDP sendto %s falhou: %d", addr_str(to).c_str(), e);
    }
}

std::string hdr(u8 kind) { return Writer().u8_(MAGIC).u8_(kind).s; }

void send_kind(const sockaddr_in& to, u8 kind, int times = 1) {
    std::string dg = hdr(kind);
    for (int i = 0; i < times; ++i) send_raw(to, dg);
}

// ---------------------------------------------------------------- confiavel: envio

void tx_enqueue(Link& l, int ch, u64 from, u64 to, const std::string& data) {
    TxStream& t = l.tx[ch];
    size_t off = 0;
    do {
        size_t n = data.size() - off;
        if (n > FRAG_MAX) n = FRAG_MAX;
        u8 flags = (u8)((off == 0 ? 1 : 0) | (off + n == data.size() ? 2 : 0));
        Frag f;
        f.seq = t.next_seq++;
        f.to = to;
        f.payload = n;
        Writer w;
        w.u8_(MAGIC).u8_(K_REL).u8_((u8)ch).u8_(flags).u32_(f.seq).u64_(from).u64_(to).bytes(data.data() + off, n);
        f.dg = std::move(w.s);
        t.q.push_back(std::move(f));
        off += n;
    } while (off < data.size());
}

// Envia o que cabe na janela e retransmite o que passou do RTO.
void tx_pump(Link& l, u64 now) {
    for (int ch = 0; ch < CHANNELS; ++ch) {
        std::deque<Frag>& q = l.tx[ch].q;
        for (size_t i = 0; i < q.size() && i < WINDOW; ++i) {
            Frag& f = q[i];
            if (f.acked) continue;
            if (f.first_ms == 0) {
                send_raw(l.addr, f.dg);
                f.first_ms = f.last_ms = now;
            } else if (since(now, f.last_ms) >= RTO_MS) {
                send_raw(l.addr, f.dg);
                f.last_ms = now;
            }
        }
    }
}

bool tx_expired(const Link& l, u64 now) {
    for (int ch = 0; ch < CHANNELS; ++ch) {
        const std::deque<Frag>& q = l.tx[ch].q;
        if (!q.empty() && q.front().first_ms && since(now, q.front().first_ms) > GIVEUP_MS) return true;
    }
    return false;
}

void on_ack(Link& l, int ch, u32 next, u64 mask) {
    std::deque<Frag>& q = l.tx[ch].q;
    for (Frag& f : q) {
        if (f.first_ms == 0) break;  // os enviados formam um prefixo da fila
        if (seq_lt(f.seq, next)) {
            f.acked = true;
        } else if (f.seq != next) {
            u32 d = f.seq - next - 1;
            if (d < 64 && ((mask >> d) & 1)) f.acked = true;
        }
    }
    while (!q.empty() && q.front().acked) q.pop_front();
}

void queued(const Link& l, u64 to_filter, bool filter, u32& bytes, u32& packets) {
    for (int ch = 0; ch < CHANNELS; ++ch)
        for (const Frag& f : l.tx[ch].q) {
            if (f.acked || (filter && f.to != to_filter)) continue;
            bytes += (u32)f.payload;
            packets++;
        }
}

// ---------------------------------------------------------------- confiavel: recepcao

void deliver_rel(Link& l, int ch, u64 from, u64 to, const std::string& msg);

void rx_process(Link& l, int ch, const std::string& dg) {
    RxStream& rx = l.rx[ch];
    Reader r(dg);
    r.i = 3;  // magic, tipo, canal
    u8 flags = r.u8_();
    r.u32_();
    u64 from = r.u64_();
    u64 to = r.u64_();
    if (flags & 1) {
        rx.msg.clear();
        rx.in_msg = true;
        rx.from = from;
        rx.to = to;
    } else if (!rx.in_msg) {
        logf("UDP fragmento sem inicio de %s canal %d", addr_str(l.addr).c_str(), ch);
        return;
    }
    rx.msg.append((const char*)r.here(), r.left());
    if (rx.msg.size() > REL_MAX_MSG) {
        logf("UDP mensagem confiavel acima de 1 MB de %s, descartada", addr_str(l.addr).c_str());
        rx.in_msg = false;
        rx.msg.clear();
        return;
    }
    if (flags & 2) {
        rx.in_msg = false;
        std::string msg;
        msg.swap(rx.msg);
        deliver_rel(l, ch, rx.from, rx.to, msg);
    }
}

void rx_frag(Link& l, int ch, u32 seq, const char* p, size_t n) {
    RxStream& rx = l.rx[ch];
    rx.ack_dirty = true;
    if (seq_lt(seq, rx.expected)) return;  // duplicado; so reconfirma
    if (seq != rx.expected) {
        if (seq - rx.expected < RECV_AHEAD && !rx.ooo.count(seq)) rx.ooo.emplace(seq, std::string(p, n));
        return;
    }
    rx_process(l, ch, std::string(p, n));
    rx.expected++;
    for (auto it = rx.ooo.find(rx.expected); it != rx.ooo.end(); it = rx.ooo.find(rx.expected)) {
        std::string dg;
        dg.swap(it->second);
        rx.ooo.erase(it);
        rx_process(l, ch, dg);
        rx.expected++;
    }
}

void send_acks(Link& l) {
    for (int ch = 0; ch < CHANNELS; ++ch) {
        RxStream& rx = l.rx[ch];
        if (!rx.ack_dirty) continue;
        rx.ack_dirty = false;
        u64 mask = 0;
        if (!rx.ooo.empty())
            for (u32 i = 0; i < 64; ++i)
                if (rx.ooo.count(rx.expected + 1 + i)) mask |= 1ull << i;
        send_raw(l.addr, Writer().u8_(MAGIC).u8_(K_ACK).u8_((u8)ch).u32_(rx.expected).u64_(mask).s);
    }
}

// ---------------------------------------------------------------- host

Link* find_client(u64 id) {
    for (auto& c : g_clients) if (c->id == id) return c.get();
    return nullptr;
}
Link* find_client_addr(const sockaddr_in& a) {
    for (auto& c : g_clients) if (same_addr(c->addr, a)) return c.get();
    return nullptr;
}

std::string roster_dgram() {
    Writer w;
    w.u8_(MAGIC).u8_(K_ROSTER).u32_(g_roster_ver).u8_((u8)(1 + g_clients.size())).u64_(g_self_id);
    for (auto& c : g_clients) w.u64_(c->id);
    return w.s;
}

void broadcast_roster(u64 now) {
    std::string dg = roster_dgram();
    for (auto& c : g_clients) {
        send_raw(c->addr, dg);
        c->last_ping_ms = now;
    }
}

void host_remove(u64 id, bool send_bye, const char* why) {
    for (size_t i = 0; i < g_clients.size(); ++i) {
        if (g_clients[i]->id != id) continue;
        logf("UDP host remove %s (%s)", name_of(id).c_str(), why);
        if (send_bye) send_kind(g_clients[i]->addr, K_BYE, 3);
        g_clients.erase(g_clients.begin() + (ptrdiff_t)i);
        ev_left(id);
        g_roster_ver++;
        broadcast_roster(now_ms());
        return;
    }
}

void host_stop() {
    if (!g_hosting) return;
    logf("UDP host encerra a sala");
    for (auto& c : g_clients) send_kind(c->addr, K_BYE, 3);
    for (auto& c : g_clients) ev_left(c->id);
    ev_left(g_self_id);
    g_clients.clear();
    g_hosting = false;
}

void host_on(const sockaddr_in& from, u8 kind, Reader& r, const char* p, size_t n, u64 now) {
    Link* l = find_client_addr(from);
    if (kind == K_HELLO) {
        if (!g_hosting) return;  // sem sala: o cliente insiste ate dar tempo
        r.u32_();                // versao
        u32 nonce = r.u32_();
        if (l && l->nonce == nonce) {  // ROSTER perdido: reenvia
            l->last_recv_ms = now;
            send_raw(l->addr, roster_dgram());
            return;
        }
        if (l) host_remove(l->id, false, "nova sessao no mesmo endereco");
        if ((int)(1 + g_clients.size()) >= g_max_members) {
            logf("UDP sala cheia, recusando %s", addr_str(from).c_str());
            send_raw(from, Writer().u8_(MAGIC).u8_(K_REFUSE).u32_(RESP_FULL).s);
            return;
        }
        auto c = std::make_unique<Link>();
        c->id = ID_PREFIX | ntohs(from.sin_port);
        c->addr = from;
        c->nonce = nonce;
        c->last_recv_ms = now;
        u64 id = c->id;
        g_clients.push_back(std::move(c));
        logf("UDP host aceita %s de %s", name_of(id).c_str(), addr_str(from).c_str());
        ev_joined(id);
        g_roster_ver++;
        broadcast_roster(now);
        return;
    }
    if (!l) {
        // Cliente que nao sabe que saiu da sala (perdeu o BYE): avisa de novo.
        if (kind == K_PING) send_kind(from, K_BYE);
        return;
    }
    l->last_recv_ms = now;
    switch (kind) {
    case K_PING:
        break;
    case K_BYE:
        host_remove(l->id, false, "BYE");
        break;
    case K_UNREL: {
        int ch = r.u8_();
        r.u64_();  // remetente: o host confia no endereco, nao no campo
        u64 to = r.u64_();
        if (ch >= CHANNELS || r.i != 2 + 1 + 8 + 8) return;
        if (to == g_self_id) {
            ev_packet(l->id, ch, r.here(), r.left());
        } else if (Link* d = find_client(to)) {
            Writer w;
            w.u8_(MAGIC).u8_(K_UNREL).u8_((u8)ch).u64_(l->id).u64_(to).bytes(r.here(), r.left());
            send_raw(d->addr, w.s);
        } else {
            logf("UDP nao confiavel para destino desconhecido %llu", (unsigned long long)to);
        }
        break;
    }
    case K_REL: {
        if (n < REL_HDR) return;
        int ch = r.u8_();
        r.u8_();
        u32 seq = r.u32_();
        if (ch >= CHANNELS) return;
        rx_frag(*l, ch, seq, p, n);
        break;
    }
    case K_ACK: {
        int ch = r.u8_();
        u32 next = r.u32_();
        u64 mask = r.u64_();
        if (ch >= CHANNELS || r.i != 2 + 1 + 4 + 8) return;
        on_ack(*l, ch, next, mask);
        tx_pump(*l, now);
        break;
    }
    default:
        break;
    }
}

// ---------------------------------------------------------------- cliente

void client_reset_link() {
    sockaddr_in a = g_hlink.addr;
    u64 id = g_hlink.id;
    g_hlink = Link();
    g_hlink.addr = a;
    g_hlink.id = id;
}

// Saida do cliente: MEMBER_LEFT para todos, ele mesmo por ultimo.
void client_drop_all(const char* why) {
    logf("UDP cliente sai da sala (%s)", why);
    bool had_self = false;
    for (u64 m : g_roster) {
        if (m == g_self_id) had_self = true;
        else ev_left(m);
    }
    if (had_self) ev_left(g_self_id);
    g_roster.clear();
    g_cstate = C_IDLE;
    client_reset_link();
}

void client_on(const sockaddr_in& from, u8 kind, Reader& r, const char* p, size_t n, u64 now) {
    if (!same_addr(from, g_hlink.addr) || g_cstate == C_IDLE) return;
    g_hlink.last_recv_ms = now;
    switch (kind) {
    case K_ROSTER: {
        u32 ver = r.u32_();
        u32 cnt = r.u8_();
        if (r.left() != cnt * 8u) return;
        std::vector<u64> ids;
        for (u32 i = 0; i < cnt; ++i) ids.push_back(r.u64_());
        if (g_cstate == C_JOINING) {
            if (!contains(ids, g_self_id)) return;
            g_cstate = C_IN;
            g_known_ver = ver;
            g_roster = ids;
            g_hlink.last_ping_ms = now;
            logf("UDP cliente entrou na sala com %u membros", cnt);
            push_event(Writer().u8_(EV_LOBBY_ENTERED).u64_(FAKE_LOBBY).u32_(RESP_OK).u64_(g_host_id).s);
            for (u64 m : ids) ev_joined(m);
            return;
        }
        if (!seq_lt(g_known_ver, ver)) return;  // velho ou repetido
        g_known_ver = ver;
        if (!contains(ids, g_self_id)) { client_drop_all("fora da lista do host"); return; }
        for (u64 m : ids)
            if (!contains(g_roster, m)) ev_joined(m);
        for (u64 m : g_roster)
            if (!contains(ids, m)) ev_left(m);
        g_roster = ids;
        break;
    }
    case K_REFUSE:
        if (g_cstate == C_JOINING) {
            u32 resp = r.u32_();
            logf("UDP host recusou a entrada, resposta %u", resp);
            push_event(Writer().u8_(EV_LOBBY_ENTERED).u64_(FAKE_LOBBY).u32_(resp).u64_(0).s);
            g_cstate = C_IDLE;
            client_reset_link();
        }
        break;
    case K_BYE:
        if (g_cstate == C_IN) client_drop_all("BYE do host");
        break;
    case K_UNREL: {
        if (g_cstate != C_IN) return;
        int ch = r.u8_();
        u64 src = r.u64_();
        u64 to = r.u64_();
        if (ch >= CHANNELS || r.i != 2 + 1 + 8 + 8 || to != g_self_id) return;
        ev_packet(src, ch, r.here(), r.left());
        break;
    }
    case K_REL: {
        if (g_cstate != C_IN || n < REL_HDR) return;
        int ch = r.u8_();
        r.u8_();
        u32 seq = r.u32_();
        if (ch >= CHANNELS) return;
        rx_frag(g_hlink, ch, seq, p, n);
        break;
    }
    case K_ACK: {
        if (g_cstate != C_IN) return;
        int ch = r.u8_();
        u32 next = r.u32_();
        u64 mask = r.u64_();
        if (ch >= CHANNELS || r.i != 2 + 1 + 4 + 8) return;
        on_ack(g_hlink, ch, next, mask);
        tx_pump(g_hlink, now);
        break;
    }
    default:
        break;
    }
}

// Mensagem confiavel completa chegou por um enlace.
void deliver_rel(Link& l, int ch, u64 from, u64 to, const std::string& msg) {
    if (!g_is_host) {
        if (to == g_self_id) ev_packet(from, ch, msg.data(), msg.size());
        return;
    }
    from = l.id;  // o host confia no endereco, nao no campo
    if (to == g_self_id) {
        ev_packet(from, ch, msg.data(), msg.size());
    } else if (Link* d = find_client(to)) {
        tx_enqueue(*d, ch, from, to, msg);
        tx_pump(*d, now_ms());
    } else {
        logf("UDP confiavel para destino desconhecido %llu", (unsigned long long)to);
    }
}

// ---------------------------------------------------------------- thread de rede

void timers(u64 now) {
    if (g_is_host) {
        if (!g_hosting) return;
        std::vector<u64> dead, failed;
        for (auto& c : g_clients) {
            if (since(now, c->last_recv_ms) > TIMEOUT_MS) { dead.push_back(c->id); continue; }
            if (since(now, c->last_ping_ms) >= KEEPALIVE_MS) {
                send_raw(c->addr, roster_dgram());
                c->last_ping_ms = now;
            }
            tx_pump(*c, now);
            if (tx_expired(*c, now)) failed.push_back(c->id);
        }
        for (u64 id : dead) host_remove(id, false, "5 s sem resposta");
        for (u64 id : failed) {
            push_event(Writer().u8_(EV_SESSION_FAIL).u64_(id).u8_(FAIL_TIMEOUT).s);
            host_remove(id, true, "confiavel sem ack por 10 s");
        }
        return;
    }
    if (g_cstate == C_JOINING) {
        if (since(now, g_join_start_ms) > JOIN_TIMEOUT_MS) {
            g_cstate = C_IDLE;
            client_reset_link();
            push_error("UDP: o host " + addr_str(g_hlink.addr) + " nao respondeu em 10 s");
        } else if (since(now, g_last_hello_ms) >= HELLO_RETRY_MS) {
            send_raw(g_hlink.addr, Writer().u8_(MAGIC).u8_(K_HELLO).u32_(MPNET_VERSION).u32_(g_hlink.nonce).s);
            g_last_hello_ms = now;
        }
    } else if (g_cstate == C_IN) {
        if (since(now, g_hlink.last_recv_ms) > TIMEOUT_MS) {
            client_drop_all("host 5 s sem resposta");
            return;
        }
        if (since(now, g_hlink.last_ping_ms) >= KEEPALIVE_MS) {
            send_kind(g_hlink.addr, K_PING);
            g_hlink.last_ping_ms = now;
        }
        tx_pump(g_hlink, now);
        if (tx_expired(g_hlink, now)) {
            push_event(Writer().u8_(EV_SESSION_FAIL).u64_(g_host_id).u8_(FAIL_TIMEOUT).s);
            send_kind(g_hlink.addr, K_BYE, 3);
            client_drop_all("confiavel sem ack por 10 s");
        }
    }
}

void on_datagram(const sockaddr_in& from, const char* p, size_t n, u64 now) {
    if (n < 2 || (u8)p[0] != MAGIC) return;
    Reader r(p, n);
    r.i = 2;
    u8 kind = (u8)p[1];
    if (g_is_host) host_on(from, kind, r, p, n, now);
    else client_on(from, kind, r, p, n, now);
}

DWORD WINAPI net_thread(LPVOID) {
    std::vector<char> buf(65536);
    for (;;) {
        fd_set rs;
        FD_ZERO(&rs);
        FD_SET(g_sock, &rs);
        timeval tv{0, 5000};
        select(0, &rs, nullptr, nullptr, &tv);
        std::lock_guard<std::mutex> lock(g_mu);
        u64 now = now_ms();
        for (int i = 0; i < 4096; ++i) {
            sockaddr_in from{};
            int fl = sizeof from;
            int n = recvfrom(g_sock, buf.data(), (int)buf.size(), 0, (sockaddr*)&from, &fl);
            if (n == SOCKET_ERROR) {
                int e = WSAGetLastError();
                if (e == WSAEWOULDBLOCK) break;
                if (e == WSAECONNRESET || e == WSAEMSGSIZE) continue;
                logf("UDP recvfrom falhou: %d", e);
                break;
            }
            on_datagram(from, buf.data(), (size_t)n, now);
        }
        if (g_is_host) {
            for (auto& c : g_clients) send_acks(*c);
        } else if (g_cstate == C_IN) {
            send_acks(g_hlink);
        }
        timers(now_ms());  // relogio fresco: o lote de recepcao pode ter demorado
    }
}

// ---------------------------------------------------------------- comandos

void cmd_send(Reader& r) {
    u64 to = r.u64_();
    int type = r.u8_();
    int ch = r.u8_();
    std::string data = r.rest();
    if (ch >= CHANNELS || type > 3) {
        logf("UDP SEND invalido: tipo %d canal %d", type, ch);
        return;
    }
    bool reliable = type >= 2;
    if (!reliable && data.size() > UNREL_MAX) {
        logf("UDP SEND nao confiavel de %u bytes recusado (maximo %u)", (u32)data.size(), (u32)UNREL_MAX);
        return;
    }
    if (reliable && data.size() > REL_MAX_MSG) {
        logf("UDP SEND confiavel de %u bytes recusado (maximo %u)", (u32)data.size(), (u32)REL_MAX_MSG);
        return;
    }
    if (to == g_self_id) {  // como na Steam, mandar para si mesmo funciona
        ev_packet(g_self_id, ch, data.data(), data.size());
        return;
    }
    Link* l = nullptr;
    if (g_is_host) {
        if (g_hosting) l = find_client(to);
    } else if (g_cstate == C_IN && contains(g_roster, to)) {
        l = &g_hlink;
    }
    if (!l) {
        logf("UDP SEND para %llu fora da sala, descartado", (unsigned long long)to);
        return;
    }
    if (reliable) {
        tx_enqueue(*l, ch, g_self_id, to, data);
        tx_pump(*l, now_ms());
    } else {
        Writer w;
        w.u8_(MAGIC).u8_(K_UNREL).u8_((u8)ch).u64_(g_self_id).u64_(to).bytes(data.data(), data.size());
        send_raw(l->addr, w.s);
    }
}

void cmd_peer_state() {
    auto emit = [](u64 id, bool relay, u32 bytes, u32 packets) {
        push_event(Writer().u8_(EV_PEER_STATE).u64_(id).u8_(1).u8_(0).u8_(0).u8_(relay ? 1 : 0).u32_(bytes).u32_(packets).s);
    };
    if (g_is_host) {
        for (auto& c : g_clients) {
            u32 b = 0, k = 0;
            queued(*c, 0, false, b, k);
            emit(c->id, false, b, k);
        }
    } else if (g_cstate == C_IN) {
        for (u64 m : g_roster) {
            if (m == g_self_id) continue;
            u32 b = 0, k = 0;
            queued(g_hlink, m, true, b, k);
            emit(m, m != g_host_id, b, k);
        }
    }
}

}  // namespace

// ---------------------------------------------------------------- interface com mpnet.cpp

bool udp_parse_mode(const std::string& line, std::string& err) {
    char role[16] = {0}, arg[128] = {0};
    if (sscanf(line.c_str(), "udp %15s %127s", role, arg) != 2) {
        err = "linha de modo invalida: '" + line + "'";
        return false;
    }
    std::string a = arg;
    if (strcmp(role, "host") == 0) {
        g_is_host = true;
        unsigned long port = strtoul(a.c_str(), nullptr, 10);
        if (port == 0 || port > 65535) { err = "porta invalida: " + a; return false; }
        g_cfg_port = (u16)port;
        return true;
    }
    if (strcmp(role, "client") == 0) {
        g_is_host = false;
        size_t c = a.rfind(':');
        if (c == std::string::npos) { err = "esperado <ip>:<porta>: " + a; return false; }
        std::string ip = a.substr(0, c);
        unsigned long port = strtoul(a.c_str() + c + 1, nullptr, 10);
        if (ip == "localhost") ip = "127.0.0.1";
        if (port == 0 || port > 65535 || inet_pton(AF_INET, ip.c_str(), &g_cfg_ip) != 1) {
            err = "endereco invalido: " + a;
            return false;
        }
        g_cfg_port = (u16)port;
        return true;
    }
    err = "papel desconhecido: " + std::string(role);
    return false;
}

bool udp_start(std::string& err) {
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) { err = "WSAStartup falhou"; return false; }
    g_sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (g_sock == INVALID_SOCKET) { err = "socket falhou: " + std::to_string(WSAGetLastError()); return false; }
    char loss[16] = {0};
    if (GetEnvironmentVariableA("MPNET_UDP_LOSS", loss, sizeof loss) > 0) {
        g_loss_pct = (u32)strtoul(loss, nullptr, 10);
        if (g_loss_pct > 90) g_loss_pct = 90;
        g_rng ^= (u32)GetCurrentProcessId() * 2654435761u;
        if (!g_rng) g_rng = 1;
        logf("UDP teste: descartando %u%% dos datagramas enviados", g_loss_pct);
    }
    int big = 4 << 20;
    setsockopt(g_sock, SOL_SOCKET, SO_RCVBUF, (const char*)&big, sizeof big);
    setsockopt(g_sock, SOL_SOCKET, SO_SNDBUF, (const char*)&big, sizeof big);
    // Sem isto, um ICMP "porta inalcancavel" (par que fechou) faz o recvfrom falhar.
    BOOL off = FALSE;
    DWORD ret = 0;
    WSAIoctl(g_sock, SIO_UDP_CONNRESET, &off, sizeof off, nullptr, 0, &ret, nullptr, nullptr);

    // So loopback quando possivel: nao dispara o aviso do firewall do Windows.
    sockaddr_in local{};
    local.sin_family = AF_INET;
    if (g_is_host) {
        inet_pton(AF_INET, "127.0.0.1", &local.sin_addr);
        local.sin_port = htons(g_cfg_port);
    } else {
        bool loop = (ntohl(g_cfg_ip.s_addr) >> 24) == 127;
        if (loop) inet_pton(AF_INET, "127.0.0.1", &local.sin_addr);
        else local.sin_addr.s_addr = htonl(INADDR_ANY);
        local.sin_port = 0;
    }
    if (bind(g_sock, (sockaddr*)&local, sizeof local) == SOCKET_ERROR) {
        err = "bind na porta " + std::to_string(g_is_host ? g_cfg_port : 0) + " falhou: " + std::to_string(WSAGetLastError());
        closesocket(g_sock);
        g_sock = INVALID_SOCKET;
        return false;
    }
    int ll = sizeof local;
    getsockname(g_sock, (sockaddr*)&local, &ll);
    u_long nb = 1;
    ioctlsocket(g_sock, FIONBIO, &nb);

    u16 port = ntohs(local.sin_port);
    g_self_id = ID_PREFIX | port;
    if (g_is_host) {
        g_host_id = g_self_id;
    } else {
        g_host_id = ID_PREFIX | g_cfg_port;
        g_hlink.id = g_host_id;
        g_hlink.addr.sin_family = AF_INET;
        g_hlink.addr.sin_addr = g_cfg_ip;
        g_hlink.addr.sin_port = htons(g_cfg_port);
    }
    std::string name = name_of(g_self_id);
    logf("UDP %s pronto em %s, self %016llx", g_is_host ? "host" : "cliente", addr_str(local).c_str(),
         (unsigned long long)g_self_id);
    push_event(Writer().u8_(EV_HELLO).u32_(MPNET_VERSION).u64_(g_self_id).u32_(0).str(name.c_str()).s);

    HANDLE t = CreateThread(nullptr, 0, net_thread, nullptr, 0, nullptr);
    if (!t) { err = "CreateThread falhou"; return false; }
    CloseHandle(t);
    return true;
}

void udp_command(u8 op, Reader& r) {
    std::lock_guard<std::mutex> lock(g_mu);
    u64 now = now_ms();
    switch (op) {
    case OP_HOST: {
        if (!g_is_host) { push_error("UDP: HOST so no modo 'udp host'"); break; }
        if (g_hosting) { push_error("UDP: ja hospedando"); break; }
        int maxm = r.u8_();
        if (maxm < 2 || maxm > 4) maxm = 4;
        g_max_members = maxm;
        g_hosting = true;
        g_roster_ver = 1;
        logf("UDP host abre sala, max %d", maxm);
        push_event(Writer().u8_(EV_LOBBY_CREATED).u32_(1).u64_(FAKE_LOBBY).s);
        push_event(Writer().u8_(EV_LOBBY_ENTERED).u64_(FAKE_LOBBY).u32_(RESP_OK).u64_(g_self_id).s);
        ev_joined(g_self_id);
        break;
    }
    case OP_JOIN:
        if (g_is_host) { push_error("UDP: JOIN so no modo 'udp client'"); break; }
        if (g_cstate != C_IDLE) { logf("UDP JOIN ignorado: ja entrando ou na sala"); break; }
        client_reset_link();
        g_hlink.nonce = (u32)(now_us() ^ ((u64)GetCurrentProcessId() << 20));
        g_cstate = C_JOINING;
        g_known_ver = 0;
        g_join_start_ms = now;
        g_last_hello_ms = now;
        logf("UDP JOIN em %s", addr_str(g_hlink.addr).c_str());
        send_raw(g_hlink.addr, Writer().u8_(MAGIC).u8_(K_HELLO).u32_(MPNET_VERSION).u32_(g_hlink.nonce).s);
        break;
    case OP_LEAVE:
        if (g_is_host) {
            host_stop();
        } else if (g_cstate == C_IN) {
            send_kind(g_hlink.addr, K_BYE, 3);
            client_drop_all("LEAVE");
        } else if (g_cstate == C_JOINING) {
            send_kind(g_hlink.addr, K_BYE, 3);
            g_cstate = C_IDLE;
            client_reset_link();
        }
        break;
    case OP_INVITE:
    case OP_SET_LOBBY_DATA:
        break;  // sem efeito no modo UDP
    case OP_SEND:
        cmd_send(r);
        break;
    case OP_CLOSE_PEER: {
        u64 id = r.u64_();
        if (g_is_host) host_remove(id, true, "CLOSE_PEER");
        else logf("UDP CLOSE_PEER ignorado no cliente");
        break;
    }
    case OP_PEER_STATE:
        cmd_peer_state();
        break;
    default:
        break;
    }
}
