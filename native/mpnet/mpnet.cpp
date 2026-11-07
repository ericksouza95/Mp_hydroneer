// mpnet: ponte nativa entre o Lua do UE4SS e a Steam do proprio Hydroneer.
//
// Carregada pelo Lua com package.loadlib(caminho, "*"). Nao chama a API C do Lua.
// Usa a steam_api64.dll que o jogo ja carregou e inicializou (SDK 1.47, app 1106840),
// pela API "flat". Conversa com o Lua por dois pipes nomeados, num ciclo de pedido e
// resposta: o Lua escreve comandos terminados por POLL, a DLL responde com os eventos.
//
// Protocolo dos pipes (little-endian):
//   quadro      = u32 tamanho, bytes
//   comando     = u8 op, argumentos
//   resposta    = u32 tamanho total, u64 relogio em microssegundos, depois N x (u32 tamanho, evento)
//   evento      = u8 tipo, dados
// Os codigos estao em docs/08-mpnet.md.

#define WIN32_LEAN_AND_MEAN
#define _CRT_SECURE_NO_WARNINGS
#include <windows.h>

#include <atomic>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <vector>

typedef uint8_t u8;
typedef uint32_t u32;
typedef uint64_t u64;
typedef int32_t HSteamUser;
typedef u64 SteamAPICall_t;

static const u32 MPNET_VERSION = 2;

// ---------------------------------------------------------------- log

static char g_dir[MAX_PATH];
static FILE* g_log = nullptr;
static std::mutex g_log_mutex;

static void logf(const char* fmt, ...) {
    std::lock_guard<std::mutex> lock(g_log_mutex);
    if (!g_log) return;
    SYSTEMTIME t;
    GetLocalTime(&t);
    fprintf(g_log, "%02d:%02d:%02d.%03d ", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(g_log, fmt, ap);
    va_end(ap);
    fputc('\n', g_log);
    fflush(g_log);
}

// ---------------------------------------------------------------- Steam flat API (SDK 1.47)
// CSteamID e passado e devolvido como u64 na API flat antiga, igual ao Steamworks.NET.

#pragma pack(push, 8)
struct P2PSessionState_t {
    u8 m_bConnectionActive;
    u8 m_bConnecting;
    u8 m_eP2PSessionError;
    u8 m_bUsingRelay;
    int32_t m_nBytesQueuedForSend;
    int32_t m_nPacketsQueuedForSend;
    u32 m_nRemoteIP;
    uint16_t m_nRemotePort;
};
struct LobbyCreated_t {  // 513
    int32_t m_eResult;
    u64 m_ulSteamIDLobby;
};
struct LobbyEnter_t {  // 504
    u64 m_ulSteamIDLobby;
    u32 m_rgfChatPermissions;
    bool m_bLocked;
    u32 m_EChatRoomEnterResponse;
};
struct GameLobbyJoinRequested_t {  // 333
    u64 m_steamIDLobby;
    u64 m_steamIDFriend;
};
struct P2PSessionRequest_t {  // 1202
    u64 m_steamIDRemote;
};
struct P2PSessionConnectFail_t {  // 1203
    u64 m_steamIDRemote;
    u8 m_eP2PSessionError;
};
#pragma pack(pop)

static_assert(sizeof(LobbyCreated_t) == 16, "LobbyCreated_t");
static_assert(sizeof(LobbyEnter_t) == 24, "LobbyEnter_t");
static_assert(sizeof(GameLobbyJoinRequested_t) == 16, "GameLobbyJoinRequested_t");
static_assert(sizeof(P2PSessionConnectFail_t) == 16, "P2PSessionConnectFail_t");

// Mesma declaracao do SDK: o MSVC monta a vtable na ordem que a steamclient espera.
class CCallbackBase {
public:
    CCallbackBase() { m_nCallbackFlags = 0; m_iCallback = 0; }
    virtual void Run(void* pvParam) = 0;
    virtual void Run(void* pvParam, bool bIOFailure, SteamAPICall_t hSteamAPICall) = 0;
    int GetICallback() { return m_iCallback; }
    virtual int GetCallbackSizeBytes() = 0;

protected:
    u8 m_nCallbackFlags;
    int m_iCallback;
};

typedef void(__cdecl* CallbackFn)(void*);

class Callback : public CCallbackBase {
public:
    Callback(int id, int size, CallbackFn fn) : m_size(size), m_fn(fn) { m_iCallback = id; }
    void Run(void* p) override { m_fn(p); }
    void Run(void* p, bool, SteamAPICall_t) override { m_fn(p); }
    int GetCallbackSizeBytes() override { return m_size; }

private:
    int m_size;
    CallbackFn m_fn;
};

#define STEAM_FN(ret, name, ...)                    \
    typedef ret(__cdecl* name##_t)(__VA_ARGS__);    \
    static name##_t p_##name = nullptr;

STEAM_FN(HSteamUser, SteamAPI_GetHSteamUser, void)
STEAM_FN(void*, SteamInternal_FindOrCreateUserInterface, HSteamUser, const char*)
STEAM_FN(void, SteamAPI_RegisterCallback, CCallbackBase*, int)
STEAM_FN(void, SteamAPI_UnregisterCallback, CCallbackBase*)
STEAM_FN(u64, SteamAPI_ISteamUser_GetSteamID, intptr_t)
STEAM_FN(const char*, SteamAPI_ISteamFriends_GetPersonaName, intptr_t)
STEAM_FN(const char*, SteamAPI_ISteamFriends_GetFriendPersonaName, intptr_t, u64)
STEAM_FN(void, SteamAPI_ISteamFriends_ActivateGameOverlayInviteDialog, intptr_t, u64)
STEAM_FN(bool, SteamAPI_ISteamFriends_SetRichPresence, intptr_t, const char*, const char*)
STEAM_FN(bool, SteamAPI_ISteamNetworking_SendP2PPacket, intptr_t, u64, const void*, u32, int, int)
STEAM_FN(bool, SteamAPI_ISteamNetworking_IsP2PPacketAvailable, intptr_t, u32*, int)
STEAM_FN(bool, SteamAPI_ISteamNetworking_ReadP2PPacket, intptr_t, void*, u32, u32*, u64*, int)
STEAM_FN(bool, SteamAPI_ISteamNetworking_AcceptP2PSessionWithUser, intptr_t, u64)
STEAM_FN(bool, SteamAPI_ISteamNetworking_CloseP2PSessionWithUser, intptr_t, u64)
STEAM_FN(bool, SteamAPI_ISteamNetworking_GetP2PSessionState, intptr_t, u64, P2PSessionState_t*)
STEAM_FN(bool, SteamAPI_ISteamNetworking_AllowP2PPacketRelay, intptr_t, bool)
STEAM_FN(SteamAPICall_t, SteamAPI_ISteamMatchmaking_CreateLobby, intptr_t, int, int)
STEAM_FN(SteamAPICall_t, SteamAPI_ISteamMatchmaking_JoinLobby, intptr_t, u64)
STEAM_FN(void, SteamAPI_ISteamMatchmaking_LeaveLobby, intptr_t, u64)
STEAM_FN(int, SteamAPI_ISteamMatchmaking_GetNumLobbyMembers, intptr_t, u64)
STEAM_FN(u64, SteamAPI_ISteamMatchmaking_GetLobbyMemberByIndex, intptr_t, u64, int)
STEAM_FN(u64, SteamAPI_ISteamMatchmaking_GetLobbyOwner, intptr_t, u64)
STEAM_FN(bool, SteamAPI_ISteamMatchmaking_SetLobbyData, intptr_t, u64, const char*, const char*)
STEAM_FN(bool, SteamAPI_ISteamMatchmaking_SetLobbyJoinable, intptr_t, u64, bool)
STEAM_FN(bool, SteamAPI_ISteamUtils_IsAPICallCompleted, intptr_t, SteamAPICall_t, bool*)
STEAM_FN(bool, SteamAPI_ISteamUtils_GetAPICallResult, intptr_t, SteamAPICall_t, void*, int, int, bool*)
STEAM_FN(u32, SteamAPI_ISteamUtils_GetAppID, intptr_t)

static intptr_t g_user, g_friends, g_mm, g_net, g_utils;
static u64 g_self = 0;

static bool load_steam(std::string& err) {
    HMODULE h = GetModuleHandleA("steam_api64.dll");
    if (!h) { err = "steam_api64.dll nao esta carregada no processo"; return false; }
#define LOAD(name)                                                          \
    p_##name = (name##_t)GetProcAddress(h, #name);                          \
    if (!p_##name) { err = "export ausente: " #name; return false; }
    LOAD(SteamAPI_GetHSteamUser)
    LOAD(SteamInternal_FindOrCreateUserInterface)
    LOAD(SteamAPI_RegisterCallback)
    LOAD(SteamAPI_UnregisterCallback)
    LOAD(SteamAPI_ISteamUser_GetSteamID)
    LOAD(SteamAPI_ISteamFriends_GetPersonaName)
    LOAD(SteamAPI_ISteamFriends_GetFriendPersonaName)
    LOAD(SteamAPI_ISteamFriends_ActivateGameOverlayInviteDialog)
    LOAD(SteamAPI_ISteamFriends_SetRichPresence)
    LOAD(SteamAPI_ISteamNetworking_SendP2PPacket)
    LOAD(SteamAPI_ISteamNetworking_IsP2PPacketAvailable)
    LOAD(SteamAPI_ISteamNetworking_ReadP2PPacket)
    LOAD(SteamAPI_ISteamNetworking_AcceptP2PSessionWithUser)
    LOAD(SteamAPI_ISteamNetworking_CloseP2PSessionWithUser)
    LOAD(SteamAPI_ISteamNetworking_GetP2PSessionState)
    LOAD(SteamAPI_ISteamNetworking_AllowP2PPacketRelay)
    LOAD(SteamAPI_ISteamMatchmaking_CreateLobby)
    LOAD(SteamAPI_ISteamMatchmaking_JoinLobby)
    LOAD(SteamAPI_ISteamMatchmaking_LeaveLobby)
    LOAD(SteamAPI_ISteamMatchmaking_GetNumLobbyMembers)
    LOAD(SteamAPI_ISteamMatchmaking_GetLobbyMemberByIndex)
    LOAD(SteamAPI_ISteamMatchmaking_GetLobbyOwner)
    LOAD(SteamAPI_ISteamMatchmaking_SetLobbyData)
    LOAD(SteamAPI_ISteamMatchmaking_SetLobbyJoinable)
    LOAD(SteamAPI_ISteamUtils_IsAPICallCompleted)
    LOAD(SteamAPI_ISteamUtils_GetAPICallResult)
    LOAD(SteamAPI_ISteamUtils_GetAppID)
#undef LOAD
    HSteamUser hu = p_SteamAPI_GetHSteamUser();
    if (!hu) { err = "Steam nao inicializada no processo (HSteamUser = 0)"; return false; }
    g_user = (intptr_t)p_SteamInternal_FindOrCreateUserInterface(hu, "SteamUser020");
    g_friends = (intptr_t)p_SteamInternal_FindOrCreateUserInterface(hu, "SteamFriends017");
    g_mm = (intptr_t)p_SteamInternal_FindOrCreateUserInterface(hu, "SteamMatchMaking009");
    g_net = (intptr_t)p_SteamInternal_FindOrCreateUserInterface(hu, "SteamNetworking006");
    g_utils = (intptr_t)p_SteamInternal_FindOrCreateUserInterface(0, "SteamUtils009");
    if (!g_utils) g_utils = (intptr_t)p_SteamInternal_FindOrCreateUserInterface(hu, "SteamUtils009");
    if (!g_user || !g_friends || !g_mm || !g_net || !g_utils) {
        char b[160];
        snprintf(b, sizeof b, "interface ausente user=%p friends=%p mm=%p net=%p utils=%p",
                 (void*)g_user, (void*)g_friends, (void*)g_mm, (void*)g_net, (void*)g_utils);
        err = b;
        return false;
    }
    g_self = p_SteamAPI_ISteamUser_GetSteamID(g_user);
    // Conta individual: universo 1, tipo 1, instancia 1 nos 32 bits altos.
    if ((g_self >> 32) != 0x01100001ull) {
        char b[96];
        snprintf(b, sizeof b, "SteamID inesperada 0x%016llx", (unsigned long long)g_self);
        err = b;
        return false;
    }
    p_SteamAPI_ISteamNetworking_AllowP2PPacketRelay(g_net, true);
    return true;
}

// ---------------------------------------------------------------- eventos

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

static u64 now_us() {
    static LARGE_INTEGER freq = [] { LARGE_INTEGER f; QueryPerformanceFrequency(&f); return f; }();
    LARGE_INTEGER c;
    QueryPerformanceCounter(&c);
    return (u64)(c.QuadPart / freq.QuadPart) * 1000000ull + (u64)((c.QuadPart % freq.QuadPart) * 1000000ull / freq.QuadPart);
}

static HWND g_window = nullptr;
static BOOL CALLBACK find_window(HWND h, LPARAM) {
    DWORD pid = 0;
    GetWindowThreadProcessId(h, &pid);
    if (pid != GetCurrentProcessId() || !IsWindowVisible(h) || GetWindow(h, GW_OWNER)) return TRUE;
    char cls[64] = {0};
    GetClassNameA(h, cls, sizeof cls);
    if (strcmp(cls, "UnrealWindow") == 0) { g_window = h; return FALSE; }
    return TRUE;
}
// SetWindowTextW numa janela de outra thread espera a thread dona processar a mensagem.
// A thread do jogo fica parada esperando a resposta do pipe, entao chamar daqui travaria
// as duas. O titulo e aplicado por uma thread propria, que pode esperar sem segurar ninguem.
static std::mutex g_title_mutex;
static std::wstring g_title_pending;
static bool g_title_dirty = false;
static HANDLE g_title_event = nullptr;

static DWORD WINAPI title_worker(LPVOID) {
    for (;;) {
        WaitForSingleObject(g_title_event, INFINITE);
        std::wstring t;
        {
            std::lock_guard<std::mutex> lock(g_title_mutex);
            if (!g_title_dirty) continue;
            t = g_title_pending;
            g_title_dirty = false;
        }
        if (!g_window || !IsWindow(g_window)) { g_window = nullptr; EnumWindows(find_window, 0); }
        if (g_window) SetWindowTextW(g_window, t.c_str());
    }
}

static void set_title(const std::string& utf8) {
    int n = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), (int)utf8.size(), nullptr, 0);
    std::wstring w(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), (int)utf8.size(), &w[0], n);
    {
        std::lock_guard<std::mutex> lock(g_title_mutex);
        g_title_pending = w;
        g_title_dirty = true;
    }
    if (!g_title_event) {
        g_title_event = CreateEventA(nullptr, FALSE, FALSE, nullptr);
        HANDLE t = CreateThread(nullptr, 0, title_worker, nullptr, 0, nullptr);
        if (t) CloseHandle(t);
    }
    SetEvent(g_title_event);
}

struct Writer {
    std::string s;
    Writer& u8_(u8 v) { s.push_back((char)v); return *this; }
    Writer& u32_(u32 v) { s.append((const char*)&v, 4); return *this; }
    Writer& u64_(u64 v) { s.append((const char*)&v, 8); return *this; }
    Writer& bytes(const void* p, size_t n) { s.append((const char*)p, n); return *this; }
    Writer& str(const char* p) { u32 n = p ? (u32)strlen(p) : 0; u32_(n); return bytes(p, n); }
};

static std::mutex g_ev_mutex;
static std::deque<std::string> g_events;

static void push_event(const std::string& e) {
    std::lock_guard<std::mutex> lock(g_ev_mutex);
    g_events.push_back(e);
}
static void push_error(const std::string& msg) {
    logf("ERRO %s", msg.c_str());
    push_event(Writer().u8_(EV_ERROR).str(msg.c_str()).s);
}

// ---------------------------------------------------------------- callbacks (rodam na thread que chama SteamAPI_RunCallbacks)

static void __cdecl on_join_requested(void* p) {
    auto* d = (GameLobbyJoinRequested_t*)p;
    logf("callback GameLobbyJoinRequested lobby=%llu amigo=%llu", (unsigned long long)d->m_steamIDLobby,
         (unsigned long long)d->m_steamIDFriend);
    push_event(Writer().u8_(EV_JOIN_REQUESTED).u64_(d->m_steamIDLobby).u64_(d->m_steamIDFriend).s);
}
static void __cdecl on_session_request(void* p) {
    auto* d = (P2PSessionRequest_t*)p;
    logf("callback P2PSessionRequest de %llu", (unsigned long long)d->m_steamIDRemote);
    push_event(Writer().u8_(EV_SESSION_REQUEST).u64_(d->m_steamIDRemote).s);
}
static void __cdecl on_session_fail(void* p) {
    auto* d = (P2PSessionConnectFail_t*)p;
    logf("callback P2PSessionConnectFail %llu erro %u", (unsigned long long)d->m_steamIDRemote, d->m_eP2PSessionError);
    push_event(Writer().u8_(EV_SESSION_FAIL).u64_(d->m_steamIDRemote).u8_(d->m_eP2PSessionError).s);
}

// Prova de vida: LobbyEnter_t tambem chega como callback ao criar ou entrar num lobby.
// Se esta linha aparecer no log, o jogo despacha callbacks e a vtable esta certa.
static std::atomic<u32> g_cb_enter_count{0};
static void __cdecl on_lobby_enter_cb(void* p) {
    auto* d = (LobbyEnter_t*)p;
    g_cb_enter_count++;
    logf("callback LobbyEnter lobby=%llu resposta=%u", (unsigned long long)d->m_ulSteamIDLobby, d->m_EChatRoomEnterResponse);
}

static Callback g_cb_join(333, sizeof(GameLobbyJoinRequested_t), on_join_requested);
static Callback g_cb_enter(504, sizeof(LobbyEnter_t), on_lobby_enter_cb);
static Callback g_cb_sreq(1202, sizeof(P2PSessionRequest_t), on_session_request);
static Callback g_cb_sfail(1203, sizeof(P2PSessionConnectFail_t), on_session_fail);

// ---------------------------------------------------------------- estado de lobby e chamadas pendentes

struct Pending {
    SteamAPICall_t call;
    int kind;  // 513 LobbyCreated, 504 LobbyEnter
};
static std::vector<Pending> g_pending;
static u64 g_lobby = 0;
static std::vector<u64> g_members;
static std::vector<u64> g_accepted;

static bool contains(const std::vector<u64>& v, u64 x) {
    for (u64 y : v) if (y == x) return true;
    return false;
}

static void accept_peer(u64 id) {
    if (id == g_self || contains(g_accepted, id)) return;
    p_SteamAPI_ISteamNetworking_AcceptP2PSessionWithUser(g_net, id);
    g_accepted.push_back(id);
}

static void poll_pending() {
    for (size_t i = 0; i < g_pending.size();) {
        Pending pd = g_pending[i];
        bool failed = false;
        if (!p_SteamAPI_ISteamUtils_IsAPICallCompleted(g_utils, pd.call, &failed)) { ++i; continue; }
        if (pd.kind == 513) {
            LobbyCreated_t r{};
            bool ok = p_SteamAPI_ISteamUtils_GetAPICallResult(g_utils, pd.call, &r, sizeof r, 513, &failed);
            logf("LobbyCreated ok=%d falhou=%d resultado=%d lobby=%llu", ok, failed, r.m_eResult,
                 (unsigned long long)r.m_ulSteamIDLobby);
            bool created = ok && !failed && r.m_eResult == 1;
            push_event(Writer().u8_(EV_LOBBY_CREATED).u32_((u32)(failed ? -1 : r.m_eResult)).u64_(r.m_ulSteamIDLobby).s);
            if (created) {
                g_lobby = r.m_ulSteamIDLobby;
                p_SteamAPI_ISteamMatchmaking_SetLobbyData(g_mm, g_lobby, "mpnet", "1");
                push_event(Writer().u8_(EV_LOBBY_ENTERED).u64_(g_lobby).u32_(1).u64_(g_self).s);
            }
        } else if (pd.kind == 504) {
            LobbyEnter_t r{};
            bool ok = p_SteamAPI_ISteamUtils_GetAPICallResult(g_utils, pd.call, &r, sizeof r, 504, &failed);
            logf("LobbyEnter ok=%d falhou=%d resposta=%u lobby=%llu", ok, failed, r.m_EChatRoomEnterResponse,
                 (unsigned long long)r.m_ulSteamIDLobby);
            u64 owner = 0;
            if (ok && !failed && r.m_EChatRoomEnterResponse == 1) {
                g_lobby = r.m_ulSteamIDLobby;
                owner = p_SteamAPI_ISteamMatchmaking_GetLobbyOwner(g_mm, g_lobby);
                accept_peer(owner);
            }
            push_event(Writer().u8_(EV_LOBBY_ENTERED).u64_(r.m_ulSteamIDLobby).u32_(failed ? 0xFFFFFFFFu : r.m_EChatRoomEnterResponse).u64_(owner).s);
        }
        g_pending.erase(g_pending.begin() + i);
    }
}

static void poll_members() {
    if (!g_lobby) {
        for (u64 m : g_members) push_event(Writer().u8_(EV_MEMBER_LEFT).u64_(m).s);
        g_members.clear();
        return;
    }
    std::vector<u64> now;
    int n = p_SteamAPI_ISteamMatchmaking_GetNumLobbyMembers(g_mm, g_lobby);
    for (int i = 0; i < n; ++i) now.push_back(p_SteamAPI_ISteamMatchmaking_GetLobbyMemberByIndex(g_mm, g_lobby, i));
    for (u64 m : now)
        if (!contains(g_members, m)) {
            accept_peer(m);
            const char* name = p_SteamAPI_ISteamFriends_GetFriendPersonaName(g_friends, m);
            push_event(Writer().u8_(EV_MEMBER_JOINED).u64_(m).str(name).s);
        }
    for (u64 m : g_members)
        if (!contains(now, m)) push_event(Writer().u8_(EV_MEMBER_LEFT).u64_(m).s);
    g_members = now;
}

static std::vector<u8> g_rx(1 << 20);

static void poll_packets() {
    for (int ch = 0; ch < 4; ++ch) {
        u32 size = 0;
        int guard = 0;
        while (guard++ < 4096 && p_SteamAPI_ISteamNetworking_IsP2PPacketAvailable(g_net, &size, ch)) {
            if (size > g_rx.size()) g_rx.resize(size);
            u32 got = 0;
            u64 from = 0;
            if (!p_SteamAPI_ISteamNetworking_ReadP2PPacket(g_net, g_rx.data(), (u32)g_rx.size(), &got, &from, ch)) break;
            push_event(Writer().u8_(EV_PACKET).u64_(from).u8_((u8)ch).bytes(g_rx.data(), got).s);
        }
    }
}

// ---------------------------------------------------------------- comandos

struct Reader {
    const u8* p;
    size_t n, i = 0;
    Reader(const std::string& s) : p((const u8*)s.data()), n(s.size()) {}
    bool has(size_t k) const { return i + k <= n; }
    u8 u8_() { return has(1) ? p[i++] : 0; }
    u64 u64_() { u64 v = 0; if (has(8)) { memcpy(&v, p + i, 8); i += 8; } return v; }
    std::string rest() { std::string s((const char*)p + i, n - i); i = n; return s; }
};

static void handle_command(const std::string& frame, bool& is_poll) {
    Reader r(frame);
    u8 op = r.u8_();
    is_poll = false;
    switch (op) {
    case OP_POLL:
        is_poll = true;
        break;
    case OP_HOST: {
        int maxm = r.u8_();
        if (maxm < 2 || maxm > 4) maxm = 4;
        SteamAPICall_t c = p_SteamAPI_ISteamMatchmaking_CreateLobby(g_mm, 1 /* so amigos */, maxm);
        logf("CreateLobby max=%d call=%llu", maxm, (unsigned long long)c);
        if (c) g_pending.push_back({c, 513}); else push_error("CreateLobby devolveu chamada invalida");
        break;
    }
    case OP_JOIN: {
        u64 lobby = r.u64_();
        SteamAPICall_t c = p_SteamAPI_ISteamMatchmaking_JoinLobby(g_mm, lobby);
        logf("JoinLobby %llu call=%llu", (unsigned long long)lobby, (unsigned long long)c);
        if (c) g_pending.push_back({c, 504}); else push_error("JoinLobby devolveu chamada invalida");
        break;
    }
    case OP_LEAVE:
        if (g_lobby) {
            logf("LeaveLobby %llu", (unsigned long long)g_lobby);
            p_SteamAPI_ISteamMatchmaking_LeaveLobby(g_mm, g_lobby);
            for (u64 m : g_accepted) p_SteamAPI_ISteamNetworking_CloseP2PSessionWithUser(g_net, m);
            g_accepted.clear();
            g_lobby = 0;
        }
        break;
    case OP_INVITE:
        if (g_lobby) p_SteamAPI_ISteamFriends_ActivateGameOverlayInviteDialog(g_friends, g_lobby);
        else push_error("convite sem lobby");
        break;
    case OP_SEND: {
        u64 to = r.u64_();
        int type = r.u8_();
        int ch = r.u8_();
        std::string data = r.rest();
        if (!p_SteamAPI_ISteamNetworking_SendP2PPacket(g_net, to, data.data(), (u32)data.size(), type, ch))
            logf("SendP2PPacket falhou para %llu tipo %d canal %d %u bytes", (unsigned long long)to, type, ch, (u32)data.size());
        break;
    }
    case OP_SET_LOBBY_DATA: {
        std::string kv = r.rest();
        size_t z = kv.find('\0');
        if (g_lobby && z != std::string::npos)
            p_SteamAPI_ISteamMatchmaking_SetLobbyData(g_mm, g_lobby, kv.substr(0, z).c_str(), kv.c_str() + z + 1);
        break;
    }
    case OP_CLOSE_PEER: {
        u64 id = r.u64_();
        p_SteamAPI_ISteamNetworking_CloseP2PSessionWithUser(g_net, id);
        for (size_t i = 0; i < g_accepted.size(); ++i)
            if (g_accepted[i] == id) { g_accepted.erase(g_accepted.begin() + i); break; }
        break;
    }
    case OP_SET_TITLE:
        set_title(r.rest());
        break;
    case OP_PEER_STATE:
        for (u64 id : g_accepted) {
            P2PSessionState_t s{};
            if (!p_SteamAPI_ISteamNetworking_GetP2PSessionState(g_net, id, &s)) continue;
            push_event(Writer()
                           .u8_(EV_PEER_STATE)
                           .u64_(id)
                           .u8_(s.m_bConnectionActive)
                           .u8_(s.m_bConnecting)
                           .u8_(s.m_eP2PSessionError)
                           .u8_(s.m_bUsingRelay)
                           .u32_((u32)s.m_nBytesQueuedForSend)
                           .u32_((u32)s.m_nPacketsQueuedForSend)
                           .s);
        }
        break;
    default:
        push_error("comando desconhecido " + std::to_string(op));
    }
}

// ---------------------------------------------------------------- pipes

static bool read_exact(HANDLE h, void* buf, DWORD n) {
    u8* p = (u8*)buf;
    while (n) {
        DWORD got = 0;
        if (!ReadFile(h, p, n, &got, nullptr) || got == 0) return false;
        p += got;
        n -= got;
    }
    return true;
}
static bool write_all(HANDLE h, const void* buf, DWORD n) {
    const u8* p = (const u8*)buf;
    while (n) {
        DWORD put = 0;
        if (!WriteFile(h, p, n, &put, nullptr) || put == 0) return false;
        p += put;
        n -= put;
    }
    return true;
}

static std::string build_reply() {
    poll_pending();
    poll_members();
    poll_packets();
    std::deque<std::string> evs;
    {
        std::lock_guard<std::mutex> lock(g_ev_mutex);
        evs.swap(g_events);
    }
    Writer w;
    w.u64_(now_us());
    for (auto& e : evs) { w.u32_((u32)e.size()); w.bytes(e.data(), e.size()); }
    return w.s;
}

static std::string read_token() {
    std::string path = std::string(g_dir) + "mpnet.token";
    for (int i = 0; i < 200; ++i) {
        FILE* f = fopen(path.c_str(), "rb");
        if (f) {
            char b[64] = {0};
            size_t n = fread(b, 1, sizeof b - 1, f);
            fclose(f);
            std::string t(b, n);
            while (!t.empty() && (t.back() == '\r' || t.back() == '\n' || t.back() == ' ')) t.pop_back();
            if (!t.empty()) return t;
        }
        Sleep(50);
    }
    return "";
}

static DWORD WINAPI worker(LPVOID) {
    logf("mpnet %u iniciando, pasta %s", MPNET_VERSION, g_dir);
    std::string token = read_token();
    if (token.empty()) { logf("sem mpnet.token, encerrando"); return 0; }

    std::string err;
    bool steam_ok = load_steam(err);
    if (steam_ok) {
        p_SteamAPI_RegisterCallback(&g_cb_join, 333);
        p_SteamAPI_RegisterCallback(&g_cb_sreq, 1202);
        p_SteamAPI_RegisterCallback(&g_cb_sfail, 1203);
        p_SteamAPI_RegisterCallback(&g_cb_enter, 504);
        const char* name = p_SteamAPI_ISteamFriends_GetPersonaName(g_friends);
        u32 app = p_SteamAPI_ISteamUtils_GetAppID(g_utils);
        logf("Steam ok: app %u, self %llu", app, (unsigned long long)g_self);
        push_event(Writer().u8_(EV_HELLO).u32_(MPNET_VERSION).u64_(g_self).u32_(app).str(name).s);
        const char* cmd = GetCommandLineA();
        const char* at = cmd ? strstr(cmd, "+connect_lobby") : nullptr;
        if (at) {
            u64 lobby = _strtoui64(at + strlen("+connect_lobby"), nullptr, 10);
            logf("linha de comando pede lobby %llu", (unsigned long long)lobby);
            if (lobby) push_event(Writer().u8_(EV_JOIN_REQUESTED).u64_(lobby).u64_(0).s);
        }
    } else {
        push_error("Steam: " + err);
    }

    std::string base = "\\\\.\\pipe\\mpnet_" + token;
    for (;;) {
        HANDLE in = CreateNamedPipeA((base + "_c2s").c_str(), PIPE_ACCESS_INBOUND, PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
                                     1, 1 << 20, 1 << 20, 0, nullptr);
        HANDLE out = CreateNamedPipeA((base + "_s2c").c_str(), PIPE_ACCESS_OUTBOUND, PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
                                      1, 1 << 20, 1 << 20, 0, nullptr);
        if (in == INVALID_HANDLE_VALUE || out == INVALID_HANDLE_VALUE) {
            logf("CreateNamedPipe falhou: %lu", GetLastError());
            return 0;
        }
        logf("aguardando o Lua em %s", base.c_str());
        BOOL c1 = ConnectNamedPipe(in, nullptr) || GetLastError() == ERROR_PIPE_CONNECTED;
        BOOL c2 = ConnectNamedPipe(out, nullptr) || GetLastError() == ERROR_PIPE_CONNECTED;
        logf("Lua conectado (%d,%d)", c1, c2);
        for (;;) {
            u32 len = 0;
            if (!read_exact(in, &len, 4)) break;
            if (len > (64u << 20)) { logf("quadro grande demais: %u", len); break; }
            std::string frame(len, '\0');
            if (len && !read_exact(in, &frame[0], len)) break;
            bool is_poll = false;
            if (steam_ok) handle_command(frame, is_poll);
            else is_poll = !frame.empty() && (u8)frame[0] == OP_POLL;
            if (is_poll) {
                std::string reply = steam_ok ? build_reply() : [] {
                    std::deque<std::string> evs;
                    { std::lock_guard<std::mutex> lock(g_ev_mutex); evs.swap(g_events); }
                    Writer w;
                    w.u64_(now_us());
                    for (auto& e : evs) { w.u32_((u32)e.size()); w.bytes(e.data(), e.size()); }
                    return w.s;
                }();
                u32 total = (u32)reply.size();
                if (!write_all(out, &total, 4) || (total && !write_all(out, reply.data(), total))) break;
            }
        }
        logf("Lua desconectou; reabrindo os pipes");
        DisconnectNamedPipe(in);
        DisconnectNamedPipe(out);
        CloseHandle(in);
        CloseHandle(out);
    }
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(inst);
        HMODULE pinned = nullptr;
        GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN, (LPCSTR)&DllMain, &pinned);
        DWORD n = GetModuleFileNameA(inst, g_dir, MAX_PATH);
        while (n && g_dir[n - 1] != '\\' && g_dir[n - 1] != '/') --n;
        g_dir[n] = 0;
        g_log = fopen((std::string(g_dir) + "mpnet.log").c_str(), "a");
        HANDLE t = CreateThread(nullptr, 0, worker, nullptr, 0, nullptr);
        if (t) CloseHandle(t);
    }
    return TRUE;
}
