// mpnet_common.h: declaracoes compartilhadas entre o nucleo (mpnet.cpp, pipes e Steam)
// e o transporte UDP (mpnet_udp.cpp). Codigos de evento e comando em docs/08-mpnet.md.
#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <cstdint>
#include <cstring>
#include <string>

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;

static const u32 MPNET_VERSION = 3;

// ---------------------------------------------------------------- codigos do protocolo do pipe

enum : u8 {
    EV_HELLO = 1,
    EV_ERROR = 2,
    EV_LOBBY_CREATED = 3,
    EV_LOBBY_ENTERED = 4,
    EV_MEMBER_JOINED = 5,
    EV_MEMBER_LEFT = 6,
    EV_PACKET = 7,
    EV_JOIN_REQUESTED = 8,
    EV_SESSION_FAIL = 9,
    EV_SESSION_REQUEST = 10,
    EV_PEER_STATE = 11,
};

enum : u8 {
    OP_POLL = 1,
    OP_HOST = 2,
    OP_JOIN = 3,
    OP_LEAVE = 4,
    OP_INVITE = 5,
    OP_SEND = 6,
    OP_SET_LOBBY_DATA = 7,
    OP_CLOSE_PEER = 8,
    OP_SET_TITLE = 9,
    OP_PEER_STATE = 10,
};

// ---------------------------------------------------------------- serializacao little-endian

struct Writer {
    std::string s;
    Writer& u8_(u8 v) { s.push_back((char)v); return *this; }
    Writer& u32_(u32 v) { s.append((const char*)&v, 4); return *this; }
    Writer& u64_(u64 v) { s.append((const char*)&v, 8); return *this; }
    Writer& bytes(const void* p, size_t n) { s.append((const char*)p, n); return *this; }
    Writer& str(const char* p) { u32 n = p ? (u32)strlen(p) : 0; u32_(n); return bytes(p, n); }
};

struct Reader {
    const u8* p;
    size_t n, i = 0;
    Reader(const std::string& s) : p((const u8*)s.data()), n(s.size()) {}
    Reader(const void* data, size_t size) : p((const u8*)data), n(size) {}
    bool has(size_t k) const { return i + k <= n; }
    size_t left() const { return n - i; }
    u8 u8_() { return has(1) ? p[i++] : 0; }
    u32 u32_() { u32 v = 0; if (has(4)) { memcpy(&v, p + i, 4); i += 4; } return v; }
    u64 u64_() { u64 v = 0; if (has(8)) { memcpy(&v, p + i, 8); i += 8; } return v; }
    const u8* here() const { return p + i; }
    std::string rest() { std::string s((const char*)p + i, n - i); i = n; return s; }
};

// ---------------------------------------------------------------- servicos do nucleo (mpnet.cpp)

void logf(const char* fmt, ...);
u64 now_us();
// Fila de eventos devolvida no proximo POLL. Pode ser chamada de qualquer thread.
void push_event(const std::string& e);
void push_error(const std::string& msg);

// ---------------------------------------------------------------- transporte UDP (mpnet_udp.cpp)

// Linha 2 do mpnet.token: "udp host <porta>" ou "udp client <ip>:<porta>".
// Devolve false com err preenchido se a linha nao for valida.
bool udp_parse_mode(const std::string& line, std::string& err);
// Abre o socket, emite EV_HELLO e inicia a thread de rede. Nao toca na Steam.
bool udp_start(std::string& err);
// Comandos de transporte (HOST, JOIN, LEAVE, INVITE, SEND, SET_LOBBY_DATA, CLOSE_PEER,
// PEER_STATE). Roda na thread do pipe; so segura o mutex do UDP por pouco tempo.
void udp_command(u8 op, Reader& r);
