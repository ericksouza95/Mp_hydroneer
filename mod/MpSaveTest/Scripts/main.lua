-- MpSaveTest: teste da entrada tardia por transferencia de save (lua/savesync.lua).
--
-- So para testes com mp-config.txt na pasta do mod (mesmas chaves do MpHydroneer):
--   transport=udp  role=host|client  addr=127.0.0.1:7778  newgame=1  report=<arquivo>
-- Chaves proprias:
--   testsecs=480      duracao maxima do teste
--   joindelay=20      cliente com newgame=1: segundos dentro do proprio mundo antes de entrar na sala
--   loadmethod=gm|menu|auto   leavemethod=gm|menu   saveown=1|0   (ver SS.config)
--
-- Host: comeca um jogo novo, abre a sala quando estiver no mundo e serve os pedidos.
-- Cliente: fica no menu (ou no proprio jogo novo, com newgame=1), entra na sala e pede o mundo.
-- Os dois registram slot, posicao, dinheiro, itens e a lista completa de itens num arquivo ao lado do relatorio.
local mpnet = require("mpnet")
local SS = require("savesync")

local MOD_DIR = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/"):match("^(.*/)Scripts/") or "./"
local DLL = MOD_DIR .. "native/mpnet.dll"

local cfg = { transport = "udp", role = "client", addr = "127.0.0.1:7778", newgame = "0", testsecs = "480", joindelay = "20" }
do
    local f = io.open(MOD_DIR .. "mp-config.txt", "rb")
    if f then
        for line in f:lines() do
            local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
            if k then cfg[k] = v end
        end
        f:close()
    end
end
local REPORT = (cfg.report and cfg.report ~= "") and cfg.report or (MOD_DIR .. "savetest.txt")
local IS_HOST = cfg.role == "host"

local function log(line)
    local f = io.open(REPORT, "a")
    if f then f:write(os.date("%Y-%m-%d %H:%M:%S ") .. tostring(line) .. "\n"); f:close() end
end

if cfg.loadmethod then SS.config.load_method = cfg.loadmethod end
if cfg.leavemethod then SS.config.leave_method = cfg.leavemethod end
if cfg.saveown then SS.config.save_own_world = cfg.saveown ~= "0" end

-- ---------------------------------------------------------------- jogo
local function valid(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end

local function game_mode()
    local gm = FindFirstOf("GM_Hydroneer_C")
    return valid(gm) and gm or nil
end

local function in_game()
    local gm = game_mode()
    if not gm then return false end
    local ok, v = pcall(function() return gm["InGame?"] end)
    return ok and v == true
end

local function pawn()
    local gm = game_mode()
    if not gm then return nil end
    local ok, p = pcall(function()
        return StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetPlayerController(gm, 0).Pawn
    end)
    return (ok and valid(p)) and p or nil
end

-- Marca o mundo do host antes do save, para o cliente provar que carregou ESTE mundo e nao um jogo novo igual:
-- o jogador e tres itens vao para posicoes que um jogo novo nao tem.
-- Itens iniciais criados em tempo de execucao (os itens de loja nao guardam a posicao no save).
local MARKED_ITEMS = { "BP_Pan_C_", "BP_Lantern_C_", "BP_ShovelT1_C_" }
local function find_item(prefix)
    for _, it in ipairs(FindAllOf("BP_ParentItem_C") or {}) do
        local ok, n = pcall(function() return it:GetFName():ToString() end)
        if ok and n:sub(1, #prefix) == prefix and valid(it) then return it, n end
    end
end
local function marker_text()
    local out = {}
    for _, name in ipairs(MARKED_ITEMS) do
        local it, full = find_item(name)
        local pos = "ausente"
        if it then pcall(function() local v = it:K2_GetActorLocation(); pos = ("%.0f %.0f %.0f"):format(v.X, v.Y, v.Z) end) end
        out[#out + 1] = (full or name) .. " em " .. pos
    end
    return table.concat(out, "; ")
end
local function mark_world()
    local p = pawn()
    if p then
        pcall(function()
            local v = p:K2_GetActorLocation()
            p:K2_TeleportTo({ X = v.X + 800, Y = v.Y + 400, Z = v.Z + 50 }, p:K2_GetActorRotation())
        end)
    end
    for i, name in ipairs(MARKED_ITEMS) do
        local it = find_item(name)
        if it and p then
            pcall(function()
                local v = p:K2_GetActorLocation()
                it:K2_TeleportTo({ X = v.X + 150 * i, Y = v.Y + 200, Z = v.Z + 100 }, it:K2_GetActorRotation())
            end)
        end
    end
end

-- Retrato do mundo: slot, posicao, dinheiro, itens. Lista completa em <relatorio>-<tag>-itens.txt.
local function snapshot(tag)
    local p = pawn()
    local loc = "?"
    if p then
        pcall(function() local v = p:K2_GetActorLocation(); loc = ("%.0f %.0f %.0f"):format(v.X, v.Y, v.Z) end)
    end
    local money, coins = 0, 0
    for _, c in ipairs(FindAllOf("BP_Coin_C") or {}) do
        pcall(function()
            if valid(c) and not c:GetFName():ToString():find("^Default__") then money = money + c.Amount; coins = coins + 1 end
        end)
    end
    local items = {}
    for _, it in ipairs(FindAllOf("BP_ParentItem_C") or {}) do
        pcall(function()
            if not valid(it) then return end
            local name = it:GetFName():ToString()
            if name:find("^Default__") then return end
            local v = it:K2_GetActorLocation()
            items[#items + 1] = { name = name, cls = it:GetClass():GetFName():ToString(), x = v.X, y = v.Y, z = v.Z }
        end)
    end
    table.sort(items, function(a, b) return a.name < b.name end)
    local file = REPORT:gsub("%.txt$", "") .. "-" .. tag .. "-itens.txt"
    local f = io.open(file, "wb")
    if f then
        for _, it in ipairs(items) do f:write(("%s\t%s\t%.0f\t%.0f\t%.0f\n"):format(it.name, it.cls, it.x, it.y, it.z)) end
        f:close()
    end
    local names = {}
    for i = 1, math.min(20, #items) do names[i] = items[i].name end
    log(("RETRATO %s: slot %s, jogador em %s, dinheiro %d em %d moedas, itens %d"):format(tag, tostring(SS.current_slot()),
        loc, money, coins, #items))
    log(("RETRATO %s: primeiros nomes: %s"):format(tag, table.concat(names, ", ")))
    log(("RETRATO %s: marcadores: %s"):format(tag, marker_text()))
    log(("RETRATO %s: lista completa em %s; %s"):format(tag, file, SS.diag()))
end

-- ---------------------------------------------------------------- savesync
SS.init({
    send = function(peer, bytes, reliable, channel)
        mpnet.send(peer, bytes, reliable and mpnet.RELIABLE or mpnet.UNRELIABLE, channel or 2)
    end,
    log = log,
    now_us = function() return mpnet.now_us end,
})

local finished = false
local function finish(why)
    if finished then return end
    finished = true
    log("TESTE_FIM " .. why)
end

local terrain_seq = 41   -- marca de terreno de mentira: conferida do outro lado
SS.host_terrain_mark = function() terrain_seq = terrain_seq + 1; return terrain_seq end

SS.on_client_loaded = function(peer, mark)
    log(("HOST: cliente %s avisou mundo carregado com marca %s (enviada %s)"):format(tostring(peer), tostring(mark),
        tostring(SS.stats.host_mark)))
    log(("MEDIDAS host: save %.1f s, transferencia %.1f s, %.2f MB, %.2f MB/s, hash %.0f ms no total, pior tick de hash %.1f ms"):format(
        SS.stats.host_save_s or -1, SS.stats.host_transfer_s or -1, SS.stats.host_mb or -1, SS.stats.host_mbps or -1,
        (SS.stats.host_hash_s or 0) * 1000, SS.stats.host_hash_max_ms or -1))
    snapshot("host-depois")
    finish("host")
end

SS.on_world_loaded = function(mark)
    local c = SS.stats.client or {}
    log(("CLIENTE: mundo do host carregado, marca %s"):format(tostring(mark)))
    log(("MEDIDAS cliente: transferencia %.1f s, carga %.1f s (ContinueGame ate InGame? %.1f s), caminho %s"):format(
        c.transfer_s or -1, c.load_s or -1, c.continue_to_ingame_s or -1, tostring(c.method)))
    snapshot("cliente-carregado")
    finish("cliente")
end

-- ---------------------------------------------------------------- laco
local st = { connected = false, ticks = 0, self = nil, lobby = nil, host_peer = nil, hosted = false,
             last_join = 0, requested = false, ingame_since = nil, last_title = 0, last_state = "idle", t0 = os.time(),
             own_snap = false }

local function mode_line()
    if cfg.transport ~= "udp" then return nil end
    if IS_HOST then return "udp host " .. (cfg.addr:match(":(%d+)$") or "7778") end
    return "udp client " .. cfg.addr
end

local function handle(ev)
    local E = mpnet.EV
    if ev.type == E.HELLO then
        st.self = ev.self
        log(("ponte: HELLO versao %d, id %s, nome %s"):format(ev.version, tostring(ev.self), ev.name))
    elseif ev.type == E.ERROR then
        log("ponte: ERRO " .. tostring(ev.message))
    elseif ev.type == E.LOBBY_ENTERED then
        log(("sala: entrou %s resposta %d dono %s"):format(tostring(ev.lobby), ev.response, tostring(ev.owner)))
        if ev.response == 1 then
            st.lobby = ev.lobby
            if not IS_HOST then st.host_peer = ev.owner end
        end
    elseif ev.type == E.MEMBER_JOINED then
        log(("sala: entrou %s (%s)"):format(tostring(ev.peer), tostring(ev.name)))
    elseif ev.type == E.MEMBER_LEFT then
        log(("sala: saiu %s"):format(tostring(ev.peer)))
        SS.drop_peer(ev.peer)
        if ev.peer == st.self then st.lobby = nil end
    elseif ev.type == E.SESSION_FAIL then
        log(("ponte: SESSION_FAIL %s erro %d"):format(tostring(ev.peer), ev.error))
    elseif ev.type == E.PACKET then
        if SS.handles(ev.data) then
            if IS_HOST then SS.host_handle(ev.peer, ev.data) else SS.client_handle(ev.peer, ev.data) end
        end
    end
end

local function tick()
    if not st.connected then
        if not mpnet.connect() then return end
        st.connected = true
        log("ponte conectada")
    end
    for _, ev in ipairs(mpnet.poll()) do handle(ev) end
    st.ticks = st.ticks + 1
    local now = mpnet.now_us
    if now - (st.rate_t or 0) > 30000000 then
        if st.rate_t then log(("laco: %.0f ticks/s, savesync %s %.0f%%"):format((st.ticks - st.rate_n) / ((now - st.rate_t) / 1e6),
            SS.state(), SS.progress() * 100)) end
        st.rate_t, st.rate_n = now, st.ticks
    end

    if in_game() then st.ingame_since = st.ingame_since or now else st.ingame_since = nil end
    local ingame_s = st.ingame_since and (now - st.ingame_since) / 1e6 or 0

    if IS_HOST then
        if not st.marked and ingame_s > 4 then
            st.marked = true
            mark_world()
            log("host: mundo marcado: " .. SS.diag() .. "; " .. marker_text())
        end
        if not st.hosted and st.self and ingame_s > 8 then
            st.hosted = true
            mpnet.host(4)
            log("host: no mundo, abrindo a sala")
        end
        SS.host_tick()
    else
        local ready
        if cfg.newgame == "1" then
            ready = ingame_s > tonumber(cfg.joindelay)
            if ready and not st.own_snap then st.own_snap = true; snapshot("cliente-proprio") end
        else
            ready = os.time() - st.t0 > 15 and valid(FindFirstOf("UI_MainMenu_C"))
        end
        if st.self and ready and not st.lobby and now - st.last_join > 12000000 then
            st.last_join = now
            mpnet.join(0)
            log("cliente: entrando na sala do host " .. cfg.addr)
        end
        if st.host_peer and not st.requested then
            st.requested = true
            log("cliente: no menu? " .. tostring(not in_game()) .. "; " .. SS.diag())
            SS.client_request(st.host_peer)
        end
        SS.client_tick()
    end

    local s = SS.state()
    if s ~= st.last_state then
        log(("estado savesync: %s -> %s"):format(st.last_state, s))
        if IS_HOST and st.last_state == "saving" and s == "sending" then snapshot("host-no-save") end
        if s == "failed" then finish("falhou") end
        st.last_state = s
    end
    if now - st.last_title > 1000000 then
        st.last_title = now
        mpnet.set_title(("MpSaveTest %s | %s %.0f%%"):format(cfg.role, s, SS.progress() * 100))
    end
    if not finished and os.time() - st.t0 > tonumber(cfg.testsecs) then finish("tempo esgotado no estado " .. s) end
end

local dead, loop_handle = false, nil
local function safe_tick()
    if dead then return end
    st.calls = (st.calls or 0) + 1
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
    if EngineTickAvailable and LoopInGameThreadAfterFrames then
        loop_handle = LoopInGameThreadAfterFrames(1, safe_tick)
        ExecuteWithDelay(2000, function()
            if (st.calls or 0) < 10 and not dead then
                log("laco por frame nao andou; usando atraso em cadeia")
                if loop_handle and CancelDelayedAction then pcall(CancelDelayedAction, loop_handle) end
                start_chain()
            end
        end)
    else
        start_chain()
    end
end

local started = false
RegisterInitGameStatePostHook(function()
    if started then return end
    started = true
    log(("==== MpSaveTest ==== %s, transporte %s, config load=%s leave=%s saveown=%s"):format(cfg.role, cfg.transport,
        SS.config.load_method, SS.config.leave_method, tostring(SS.config.save_own_world)))
    -- o token do pipe da mpnet vem de os.time(): duas copias abertas no mesmo segundo pegariam o mesmo pipe.
    -- O cliente inicia a ponte 2,5 s depois para cair num segundo diferente.
    ExecuteWithDelay(IS_HOST and 10 or 2500, function()
        local ok, e = mpnet.start(DLL, mode_line())
        if not ok then log("ERRO ao iniciar a ponte: " .. tostring(e)); return end
        ExecuteWithDelay(500, start_loop)
    end)
    log("pasta de saves: " .. tostring(SS.saves_dir()))
    if cfg.newgame == "1" then
        ExecuteWithDelay(8000, function()
            ExecuteInGameThread(function()
                local gi, gm = FindFirstOf("BP_GameInstance_C"), game_mode()
                pcall(function() gi.SaveSlot = "MpSaveTest-" .. cfg.role end)
                pcall(function()
                    StaticFindObject("/Script/EasyMultiSave.Default__EMSFunctionLibrary"):SetCurrentSaveGameName(gm, "MpSaveTest-" .. cfg.role)
                end)
                local okn, en = pcall(function() gm:NewGame() end)
                log("jogo novo automatico: " .. (okn and "ok" or tostring(en)))
            end)
        end)
    end
end)
