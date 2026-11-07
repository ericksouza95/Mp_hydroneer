-- mpnet.lua: lado Lua da ponte nativa mpnet.dll.
--
-- Uso:
--   local mpnet = require("mpnet")
--   mpnet.start("E:/.../mpnet.dll")       -- uma vez
--   a cada tick, na game thread:
--     mpnet.send(peer, bytes, mpnet.RELIABLE, 0)
--     for _, ev in ipairs(mpnet.poll()) do ... end
--
-- SteamIDs sao inteiros Lua de 64 bits.

local M = {}

M.UNRELIABLE, M.UNRELIABLE_NODELAY, M.RELIABLE, M.RELIABLE_BUFFERED = 0, 1, 2, 3

local OP_POLL, OP_HOST, OP_JOIN, OP_LEAVE, OP_INVITE, OP_SEND, OP_SET_LOBBY_DATA, OP_CLOSE_PEER = 1, 2, 3, 4, 5, 6, 7, 8
local OP_SET_TITLE, OP_PEER_STATE = 9, 10
M.EV = {
    HELLO = 1, ERROR = 2, LOBBY_CREATED = 3, LOBBY_ENTERED = 4, MEMBER_JOINED = 5,
    MEMBER_LEFT = 6, PACKET = 7, JOIN_REQUESTED = 8, SESSION_FAIL = 9, SESSION_REQUEST = 10,
    PEER_STATE = 11,
}

-- Relogio da DLL em microssegundos, atualizado a cada poll().
M.now_us = 0

local token, c2s, s2c, loaded, err
local queue = {}

local function frame(payload)
    return string.pack("<s4", payload)
end

function M.start(dll_path)
    if loaded then return true end
    local dir = dll_path:match("^(.*[/\\])") or ""
    math.randomseed(os.time())
    token = string.format("%d%06d", os.time(), math.random(0, 999999))
    local f = io.open(dir .. "mpnet.token", "wb")
    if not f then err = "nao consegui escrever mpnet.token em " .. dir; return false, err end
    f:write(token); f:close()
    local ok, e = package.loadlib(dll_path, "*")
    if not ok then err = "package.loadlib falhou: " .. tostring(e); return false, err end
    loaded = true
    return true
end

-- Abre os pipes. Devolve true quando conectado. Chamar ate dar certo.
function M.connect()
    if s2c then return true end
    if not loaded then return false, err or "nao iniciado" end
    local base = "\\\\.\\pipe\\mpnet_" .. token
    if not c2s then
        c2s = io.open(base .. "_c2s", "wb")
        if not c2s then return false, "pipe c2s ainda nao existe" end
        c2s:setvbuf("full", 1 << 20)
    end
    s2c = io.open(base .. "_s2c", "rb")
    if not s2c then return false, "pipe s2c ainda nao existe" end
    s2c:setvbuf("no")
    return true
end

function M.connected() return s2c ~= nil end

local function push(payload) queue[#queue + 1] = frame(payload) end

function M.host(max_members) push(string.pack("<BB", OP_HOST, max_members or 4)) end
function M.join(lobby) push(string.pack("<Bi8", OP_JOIN, lobby)) end
function M.leave() push(string.pack("<B", OP_LEAVE)) end
function M.invite() push(string.pack("<B", OP_INVITE)) end
function M.close_peer(peer) push(string.pack("<Bi8", OP_CLOSE_PEER, peer)) end
function M.set_lobby_data(k, v) push(string.pack("<B", OP_SET_LOBBY_DATA) .. k .. "\0" .. v) end
function M.set_title(text) push(string.pack("<B", OP_SET_TITLE) .. text) end
function M.peer_state() push(string.pack("<B", OP_PEER_STATE)) end
function M.send(peer, bytes, send_type, channel)
    push(string.pack("<Bi8BB", OP_SEND, peer, send_type or M.RELIABLE, channel or 0) .. bytes)
end

local function decode(e)
    local t = string.byte(e, 1)
    local ev = { type = t }
    local p = 2
    if t == M.EV.HELLO then
        ev.version, ev.self, ev.app, ev.name = string.unpack("<I4i8I4s4", e, p)
    elseif t == M.EV.ERROR then
        ev.message = string.unpack("<s4", e, p)
    elseif t == M.EV.LOBBY_CREATED then
        ev.result, ev.lobby = string.unpack("<i4i8", e, p)
    elseif t == M.EV.LOBBY_ENTERED then
        ev.lobby, ev.response, ev.owner = string.unpack("<i8I4i8", e, p)
    elseif t == M.EV.MEMBER_JOINED then
        ev.peer, ev.name = string.unpack("<i8s4", e, p)
    elseif t == M.EV.MEMBER_LEFT or t == M.EV.SESSION_REQUEST then
        ev.peer = string.unpack("<i8", e, p)
    elseif t == M.EV.PACKET then
        ev.peer, ev.channel, p = string.unpack("<i8B", e, p)
        ev.data = string.sub(e, p)
    elseif t == M.EV.JOIN_REQUESTED then
        ev.lobby, ev.friend = string.unpack("<i8i8", e, p)
    elseif t == M.EV.SESSION_FAIL then
        ev.peer, ev.error = string.unpack("<i8B", e, p)
    elseif t == M.EV.PEER_STATE then
        local active, connecting, err, relay
        ev.peer, active, connecting, err, relay, ev.bytes_queued, ev.packets_queued = string.unpack("<i8BBBBI4I4", e, p)
        ev.active, ev.connecting, ev.error, ev.relay = active ~= 0, connecting ~= 0, err, relay ~= 0
    end
    return ev
end

-- Envia os comandos enfileirados, pede os eventos e os devolve decodificados.
function M.poll()
    if not s2c then return {} end
    queue[#queue + 1] = frame(string.pack("<B", OP_POLL))
    c2s:write(table.concat(queue))
    c2s:flush()
    queue = {}
    local head = s2c:read(4)
    if not head or #head < 4 then error("mpnet: pipe fechado") end
    local total = string.unpack("<I4", head)
    local events = {}
    if total > 0 then
        local body = s2c:read(total)
        M.now_us = string.unpack("<i8", body, 1)
        local p = 9
        while p <= #body do
            local len
            len, p = string.unpack("<I4", body, p)
            events[#events + 1] = decode(string.sub(body, p, p + len - 1))
            p = p + len
        end
    end
    return events
end

return M
