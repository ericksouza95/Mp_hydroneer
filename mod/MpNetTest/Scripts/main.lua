-- MpNetTest: autoteste da ponte mpnet numa unica instancia do jogo.
-- Resultado em <pasta do mod>/mpnet-test.txt, terminando em MPNET_TESTE_FIM.
local mpnet = require("mpnet")

local MOD_DIR = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/"):match("^(.*/)Scripts/") or "./"
local OUT = MOD_DIR .. "mpnet-test.txt"
local DLL = MOD_DIR .. "native/mpnet.dll"

local function w(line)
    local f = io.open(OUT, "a")
    if f then f:write(os.date("%H:%M:%S ") .. tostring(line) .. "\n"); f:close() end
end

local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
local ctx
local function now()
    local ok, t = pcall(function() return gs:GetRealTimeSeconds(ctx) end)
    return ok and t or 0
end

local state = { step = "conectar", t0 = 0, self = nil, got = {}, burst = { u = 0, r = 0 }, ticks = 0, events = 0 }

local function stats(tag)
    w(("%s: ticks=%d eventos=%d"):format(tag, state.ticks, state.events))
end

local function handle(ev)
    state.events = state.events + 1
    local E = mpnet.EV
    if ev.type == E.HELLO then
        state.self = ev.self
        w(("HELLO versao=%d app=%d self=%d (0x%x) nome=%s"):format(ev.version, ev.app, ev.self, ev.self, ev.name))
    elseif ev.type == E.ERROR then
        w("ERRO da DLL: " .. ev.message)
    elseif ev.type == E.LOBBY_CREATED then
        w(("LOBBY_CREATED resultado=%d lobby=%d"):format(ev.result, ev.lobby))
    elseif ev.type == E.LOBBY_ENTERED then
        state.lobby = ev.lobby
        w(("LOBBY_ENTERED lobby=%d resposta=%d dono=%d"):format(ev.lobby, ev.response, ev.owner))
    elseif ev.type == E.MEMBER_JOINED then
        w(("MEMBER_JOINED %d %s"):format(ev.peer, ev.name))
        state.member_self = (ev.peer == state.self)
    elseif ev.type == E.MEMBER_LEFT then
        w(("MEMBER_LEFT %d"):format(ev.peer))
        state.member_left = true
    elseif ev.type == E.PACKET then
        local tag = ev.data:sub(1, 1)
        if tag == "P" then
            local sent = string.unpack("<d", ev.data, 2)
            w(("PACKET ping canal=%d de=%d bytes=%d rtt=%.1f ms"):format(ev.channel, ev.peer, #ev.data, (now() - sent) * 1000))
            state.got[ev.channel] = true
        elseif tag == "U" then
            state.burst.u = state.burst.u + 1
        elseif tag == "R" then
            state.burst.r = state.burst.r + 1
        end
    else
        w("evento " .. ev.type)
    end
end

local function step()
    local t = now()
    if state.step == "conectar" then
        local ok, e = mpnet.connect()
        if ok then
            w("pipes conectados")
            state.step = "hello"; state.t0 = t
        elseif t - state.t0 > 10 then
            w("FALHA: pipes nao conectaram: " .. tostring(e)); state.step = "fim"
        end
        return
    end
    for _, ev in ipairs(mpnet.poll()) do handle(ev) end
    state.ticks = state.ticks + 1

    if state.step == "hello" then
        if state.self then
            local ping = "P" .. string.pack("<d", t)
            mpnet.send(state.self, ping, mpnet.RELIABLE, 0)
            mpnet.send(state.self, ping, mpnet.UNRELIABLE, 1)
            w("ping para si mesmo enviado nos canais 0 (confiavel) e 1 (nao confiavel)")
            state.step = "ping"; state.t0 = t
        elseif t - state.t0 > 5 then
            w("FALHA: sem HELLO"); state.step = "fim"
        end
    elseif state.step == "ping" then
        if (state.got[0] and state.got[1]) or t - state.t0 > 5 then
            w(("loopback: canal0=%s canal1=%s"):format(tostring(state.got[0] or false), tostring(state.got[1] or false)))
            mpnet.host(4)
            w("host(4) pedido")
            state.step = "lobby"; state.t0 = t
        end
    elseif state.step == "lobby" then
        if (state.lobby and state.member_self) or t - state.t0 > 10 then
            w(("lobby: id=%s self_membro=%s"):format(tostring(state.lobby), tostring(state.member_self or false)))
            local pad = string.rep("x", 1100)
            for i = 1, 300 do mpnet.send(state.self, "U" .. pad, mpnet.UNRELIABLE, 1) end
            local big = string.rep("y", 8000)
            for i = 1, 50 do mpnet.send(state.self, "R" .. big, mpnet.RELIABLE, 0) end
            w("rajada enviada: 300 x 1101 B nao confiavel, 50 x 8001 B confiavel")
            state.step = "rajada"; state.t0 = t
        end
    elseif state.step == "rajada" then
        if (state.burst.u >= 300 and state.burst.r >= 50) or t - state.t0 > 5 then
            w(("rajada recebida em %.0f ms: nao confiavel %d/300, confiavel %d/50"):format(
                (t - state.t0) * 1000, state.burst.u, state.burst.r))
            mpnet.leave()
            state.step = "saida"; state.t0 = t
        end
    elseif state.step == "saida" then
        if state.member_left or t - state.t0 > 5 then
            w("saida do lobby: membro_saiu=" .. tostring(state.member_left or false))
            stats("total")
            state.step = "fim"
        end
    end
end

local function loop()
    ExecuteInGameThread(function()
        local ok, e = pcall(step)
        if not ok then w("ERRO Lua: " .. tostring(e)); state.step = "fim" end
        if state.step == "fim" then
            w("MPNET_TESTE_FIM")
        else
            ExecuteWithDelay(16, loop)
        end
    end)
end

local started = false
RegisterInitGameStatePostHook(function()
    if started then return end
    started = true
    ExecuteWithDelay(8000, function()
        ExecuteInGameThread(function()
            ctx = FindFirstOf("GM_Hydroneer_C")
            w("==== MpNetTest ==== dll=" .. DLL)
            local ok, e = mpnet.start(DLL)
            w("start: " .. tostring(ok) .. " " .. tostring(e or ""))
            if ok then state.t0 = now(); loop() else w("MPNET_TESTE_FIM") end
        end)
    end)
end)
