-- MpPing: teste de conexao entre amigos pela Steam, usando a ponte mpnet.
--
-- F8  hospedar a sala e abrir o convite da Steam (de novo: reabre o convite)
-- F9  sair da sala
-- Quem aceita o convite entra sozinho. Com 2 ou mais na sala, todos medem ping
-- entre si e, depois de 15 s, cada um faz um teste de banda de 10 s.
-- Relatorio: %LOCALAPPDATA%\HydroneerMP\relatorio.txt
-- Status: titulo da janela do jogo.

local mpnet = require("mpnet")

local VERSION = "0.1"
local MOD_DIR = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/"):match("^(.*/)Scripts/") or "./"
local DLL = MOD_DIR .. "native/mpnet.dll"
local REPORT_DIR = (os.getenv("LOCALAPPDATA") or MOD_DIR):gsub("\\", "/") .. "/HydroneerMP/"
local REPORT = REPORT_DIR .. "relatorio.txt"
local AUTOTEST = io.open(MOD_DIR .. "autoteste.txt", "rb") ~= nil

do  -- o instalador cria a pasta; isto e so o ultimo recurso
    local f = io.open(REPORT, "a")
    if f then f:close() else os.execute('mkdir "' .. REPORT_DIR:gsub("/", "\\") .. '" 2>nul') end
end

local function log(line)
    local f = io.open(REPORT, "a")
    if f then f:write(os.date("%Y-%m-%d %H:%M:%S ") .. tostring(line) .. "\n"); f:close() end
end

-- ---------------------------------------------------------------- estado
local S = {
    connected = false, self = nil, name = "?", lobby = nil, owner = nil,
    peers = {},          -- [steamid] = {name, joined_us, rtt = {}, sent, recv, rel_rtt = {}, stream = {...}, relay}
    last_ping = 0, last_rel_ping = 0, last_status = 0, last_state = 0, seq = 0,
    t_start = 0,
}

local function peer(id, name)
    local p = S.peers[id]
    if not p then
        p = { name = name or tostring(id), joined_us = mpnet.now_us, rtt = {}, rel_rtt = {}, sent = 0, recv = 0,
              stream_out = nil, stream_in = { got = 0, expected = nil, first = nil, last = nil },
              relay = nil, logged_stream = false }
        S.peers[id] = p
    end
    if name then p.name = name end
    return p
end

local function stats(list)
    if #list == 0 then return nil end
    local s = {}
    for i, v in ipairs(list) do s[i] = v end
    table.sort(s)
    local sum = 0
    for _, v in ipairs(s) do sum = sum + v end
    return { n = #s, min = s[1], avg = sum / #s, p95 = s[math.max(1, math.ceil(#s * 0.95))], max = s[#s] }
end

local function fmt_ms(us) return string.format("%.0f", us / 1000) end

local function targets()
    local out = {}
    for id, p in pairs(S.peers) do
        if id ~= S.self or AUTOTEST then out[#out + 1] = id end
    end
    return out
end

-- ---------------------------------------------------------------- mensagens
-- I seq t   ping nao confiavel (canal 1)    O seq t  resposta
-- i seq t   ping confiavel (canal 0)        o seq t  resposta
-- S seq ... pacote do teste de banda (canal 1, 1100 B)
-- E total   fim do teste de banda (canal 0)

local function on_packet(ev)
    local tag = ev.data:sub(1, 1)
    local p = peer(ev.peer)
    if tag == "I" or tag == "i" then
        local seq, t = string.unpack("<I4i8", ev.data, 2)
        local back = (tag == "I") and "O" or "o"
        mpnet.send(ev.peer, back .. string.pack("<I4i8", seq, t), tag == "I" and mpnet.UNRELIABLE or mpnet.RELIABLE, tag == "I" and 1 or 0)
    elseif tag == "O" or tag == "o" then
        local _, t = string.unpack("<I4i8", ev.data, 2)
        local rtt = mpnet.now_us - t
        if tag == "O" then
            p.recv = p.recv + 1
            p.rtt[#p.rtt + 1] = rtt
            if #p.rtt > 2000 then table.remove(p.rtt, 1) end
        else
            p.rel_rtt[#p.rel_rtt + 1] = rtt
        end
    elseif tag == "S" then
        local si = p.stream_in
        si.got = si.got + 1
        si.first = si.first or mpnet.now_us
        si.last = mpnet.now_us
    elseif tag == "E" then
        local total = string.unpack("<I4", ev.data, 2)
        local si = p.stream_in
        local secs = si.first and si.last and (si.last - si.first) / 1e6 or 0
        log(("BANDA recebida de %s: %d de %d pacotes (%.1f%%), %.0f kbit/s em %.1f s"):format(
            p.name, si.got, total, total > 0 and 100 * si.got / total or 0,
            secs > 0 and si.got * 1100 * 8 / secs / 1000 or 0, secs))
        si.got, si.first, si.last = 0, nil, nil
    end
end

local function handle(ev)
    local E = mpnet.EV
    if ev.type == E.HELLO then
        S.self, S.name = ev.self, ev.name
        log(("pronto: %s, app %d, mpnet %d, MpPing %s"):format(ev.name, ev.app, ev.version, VERSION))
        if ev.app ~= 1106840 then log("AVISO: app id inesperado") end
        if AUTOTEST then mpnet.host(4) end
    elseif ev.type == E.ERROR then
        log("ERRO: " .. ev.message)
    elseif ev.type == E.LOBBY_CREATED then
        log(("sala criada: resultado %d"):format(ev.result))
        if ev.result == 1 and not AUTOTEST then mpnet.invite() end
    elseif ev.type == E.LOBBY_ENTERED then
        if ev.response == 1 then
            S.lobby, S.owner = ev.lobby, ev.owner
            log(("entrou na sala, dono %s"):format(ev.owner == S.self and "voce" or tostring(ev.owner)))
        else
            log(("falha ao entrar na sala, resposta %d"):format(ev.response))
        end
    elseif ev.type == E.MEMBER_JOINED then
        peer(ev.peer, ev.name)
        if ev.peer ~= S.self then log("entrou: " .. ev.name) end
    elseif ev.type == E.MEMBER_LEFT then
        local p = S.peers[ev.peer]
        if p and ev.peer ~= S.self then log("saiu: " .. p.name) end
        S.peers[ev.peer] = nil
        if ev.peer == S.self then S.lobby = nil; S.peers = {} end
    elseif ev.type == E.JOIN_REQUESTED then
        log("convite aceito, entrando na sala")
        if S.lobby then mpnet.leave() end
        mpnet.join(ev.lobby)
    elseif ev.type == E.PACKET then
        on_packet(ev)
    elseif ev.type == E.SESSION_FAIL then
        log(("ERRO de sessao P2P com %s: codigo %d"):format(tostring(ev.peer), ev.error))
    elseif ev.type == E.PEER_STATE then
        local p = S.peers[ev.peer]
        if p then
            if p.relay ~= ev.relay then
                log(("rota com %s: %s"):format(p.name, ev.relay and "relay da Steam" or "direta"))
            end
            p.relay, p.active = ev.relay, ev.active
        end
    end
end

-- ---------------------------------------------------------------- laco
local STREAM_RATE = 120     -- pacotes por segundo
local STREAM_SECS = 10

local function tick()
    if not S.connected then
        local ok = mpnet.connect()
        if not ok then return end
        S.connected = true
        log("ponte conectada")
    end
    for _, ev in ipairs(mpnet.poll()) do handle(ev) end
    local now = mpnet.now_us
    if S.t_start == 0 then S.t_start = now end
    S.ticks = (S.ticks or 0) + 1
    if now - (S.last_rate or 0) > 30000000 then
        if S.last_rate then log(("laco: %.0f ticks/s"):format((S.ticks - (S.last_ticks or 0)) / ((now - S.last_rate) / 1e6))) end
        S.last_rate, S.last_ticks = now, S.ticks
    end

    -- ping nao confiavel 4x por segundo, confiavel a cada 2 s
    if now - S.last_ping > 250000 then
        S.last_ping = now
        S.seq = S.seq + 1
        for _, id in ipairs(targets()) do
            mpnet.send(id, "I" .. string.pack("<I4i8", S.seq, now), mpnet.UNRELIABLE, 1)
            S.peers[id].sent = S.peers[id].sent + 1
        end
    end
    if now - S.last_rel_ping > 2000000 then
        S.last_rel_ping = now
        for _, id in ipairs(targets()) do mpnet.send(id, "i" .. string.pack("<I4i8", S.seq, now), mpnet.RELIABLE, 0) end
    end
    if now - S.last_state > 1000000 then
        S.last_state = now
        mpnet.peer_state()
    end

    -- teste de banda: 15 s depois de conhecer o par, 10 s a 120 pacotes/s
    local pad = string.rep("\0", 1095)
    for _, id in ipairs(targets()) do
        local p = S.peers[id]
        if not p.stream_out and now - p.joined_us > 15000000 then
            p.stream_out = { start = now, sent = 0, done = false }
            log(("BANDA: enviando para %s por %d s a %d pacotes/s"):format(p.name, STREAM_SECS, STREAM_RATE))
        end
        local so = p.stream_out
        if so and not so.done then
            local elapsed = (now - so.start) / 1e6
            local due = math.min(math.floor(elapsed * STREAM_RATE), STREAM_RATE * STREAM_SECS)
            while so.sent < due do
                so.sent = so.sent + 1
                mpnet.send(id, "S" .. string.pack("<I4", so.sent) .. pad, mpnet.UNRELIABLE, 1)
            end
            if elapsed >= STREAM_SECS then
                so.done = true
                mpnet.send(id, "E" .. string.pack("<I4", so.sent), mpnet.RELIABLE, 0)
            end
        end
    end

    -- status no titulo e no relatorio a cada 5 s
    if now - S.last_status > 1000000 then
        local five = (now - (S.last_report or 0)) > 5000000
        S.last_status = now
        local n, parts = 0, {}
        for id, p in pairs(S.peers) do
            n = n + 1
            if id ~= S.self or AUTOTEST then
                local st = stats(p.rtt)
                local loss = p.sent > 0 and math.max(0, 100 * (1 - p.recv / p.sent)) or 0
                parts[#parts + 1] = ("%s %s ms"):format(p.name, st and fmt_ms(st.avg) or "--")
                if five then
                    local rs = stats(p.rel_rtt)
                    log(("PING %s: medio %s ms, min %s, p95 %s, max %s, perda %.1f%% (%d/%d), confiavel medio %s ms, rota %s"):format(
                        p.name, st and fmt_ms(st.avg) or "-", st and fmt_ms(st.min) or "-", st and fmt_ms(st.p95) or "-",
                        st and fmt_ms(st.max) or "-", loss, p.recv, p.sent, rs and fmt_ms(rs.avg) or "-",
                        p.relay == nil and "?" or (p.relay and "relay" or "direta")))
                end
            end
        end
        if five then S.last_report = now end
        local title
        if not S.lobby then
            title = "Hydroneer MP " .. VERSION .. " | F8 para hospedar e convidar"
        else
            title = ("Hydroneer MP %s | sala %d/4 | %s | F8 convidar, F9 sair"):format(VERSION, n,
                #parts > 0 and table.concat(parts, ", ") or "esperando amigo")
        end
        mpnet.set_title(title)
    end
end

-- Laco: por frame quando o UE4SS tem o gancho de tick da engine; senao, ou se o laco
-- por frame nao andar em 2 s, cai para ExecuteWithDelay em cadeia.
local loop_handle, dead = nil, false
local function safe_tick()
    if dead then return end
    local ok, e = pcall(tick)
    if not ok then
        dead = true
        log("ERRO Lua: " .. tostring(e))
        if loop_handle and CancelDelayedAction then pcall(CancelDelayedAction, loop_handle) end
    end
end

local function start_chain()
    local function again()
        ExecuteInGameThread(function()
            safe_tick()
            if not dead then ExecuteWithDelay(10, again) end
        end)
    end
    again()
end

local function start_loop()
    log(("laco: EngineTickAvailable=%s LoopInGameThreadAfterFrames=%s"):format(
        tostring(EngineTickAvailable), type(LoopInGameThreadAfterFrames)))
    if EngineTickAvailable and LoopInGameThreadAfterFrames then
        loop_handle = LoopInGameThreadAfterFrames(1, safe_tick)
        ExecuteWithDelay(2000, function()
            if (S.ticks or 0) < 10 and not dead then
                log("laco por frame nao andou; usando atraso em cadeia")
                if loop_handle and CancelDelayedAction then pcall(CancelDelayedAction, loop_handle) end
                start_chain()
            else
                log("laco por frame ativo")
            end
        end)
    else
        start_chain()
    end
end

-- ---------------------------------------------------------------- inicio e teclas
local started = false
RegisterInitGameStatePostHook(function()
    if started then return end
    started = true
    log("==== MpPing " .. VERSION .. " ====")
    local ok, e = mpnet.start(DLL)
    if not ok then log("ERRO ao iniciar a ponte: " .. tostring(e)); return end
    ExecuteWithDelay(500, function() start_loop() end)
end)

RegisterKeyBind(Key.F8, function()
    ExecuteInGameThread(function()
        if not S.connected then return end
        if S.lobby then mpnet.invite(); log("convite reaberto") else mpnet.host(4); log("criando sala") end
    end)
end)
RegisterKeyBind(Key.F9, function()
    ExecuteInGameThread(function()
        if S.lobby then mpnet.leave(); log("saindo da sala") end
    end)
end)
