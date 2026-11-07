-- MpHydroneer: co-op do Hydroneer. Ver docs/ no repositorio.
--
-- F8  hospedar e abrir o convite da Steam (de novo: reabre o convite)
-- F9  sair da sala
-- Relatorio: %LOCALAPPDATA%\HydroneerMP\relatorio.txt
local U = require("util")
local mpnet = require("mpnet")
local S = require("session")
local T = require("terrain")
local A = require("avatar")

local DLL = U.MOD_DIR .. "native/mpnet.dll"
local cfg = U.cfg

local function mode_line()
    if cfg.transport ~= "udp" then return nil end
    if cfg.role == "host" then return "udp host " .. (cfg.addr:match(":(%d+)$") or "7777") end
    return "udp client " .. cfg.addr
end

-- ---------------------------------------------------------------- robos de teste (so com mp-config.txt)
local bot = { digs = {}, last_dig = 0, t0 = nil, checked = false }

local function bot_tick()
    if cfg.bot == "none" or not U.in_game() then return end
    local pawn, pc = U.local_pawn(), U.local_controller()
    if not pawn then return end
    local t = os.clock()
    bot.t0 = bot.t0 or t
    local el = t - bot.t0
    -- posicao de partida so depois da animacao de entrada do jogo novo
    if not bot.spawn and el > 10 then bot.spawn = { U.location(pawn) }; U.log(("BOT partida em %.0f %.0f %.0f"):format(table.unpack(bot.spawn))) end
    local secs = tonumber(cfg.testsecs or "90")
    if not bot.moved and tonumber(cfg.offset_x or "0") ~= 0 then
        bot.moved = true
        local x, y, z = U.location(pawn)
        pawn:K2_TeleportTo(U.vec(x + tonumber(cfg.offset_x), y, z + 50), pawn:K2_GetActorRotation())
    end
    if el < secs - 15 then
        -- anda em circulo
        local a = el * 0.6 + (cfg.role == "client" and math.pi or 0)
        pawn:AddMovementInput(U.vec(math.cos(a), math.sin(a), 0), 1.0, false)
        -- terrainsync (host): a cada 8 s aplica uma remocao e manda como escavacao local
        if cfg.bot == "terrainsync" and cfg.role == "host" and S.lobby and bot.spawn and el - bot.last_dig > 6 and el > 20 then
            bot.last_dig = el
            bot.n = (bot.n or 0) + 1
            local x, y, z = table.unpack(bot.spawn)
            local px, py = x + 200, y + (bot.n - 2) * 220      -- grade ao lado do ponto de partida, onde se pode cavar
            local hit = U.voxel_surface(px, py, z + 300, z - 3000)
            if hit then
                local e = { fn = "RemoveSphere", world = hit.world, x = px, y = py, z = hit.z, radius = 120, a = 0, b = 0, flags = 15 }
                T.apply(e)
                T.on_local_edit(e)
                bot.digs[#bot.digs + 1] = { px, py, hit.z }
                U.log(("BOT terrainsync: removido e enviado em %.0f %.0f z %.0f (%s)"):format(px, py, hit.z, hit.world))
            end
        end
        -- applytest: acha a superficie do voxel pela densidade e aplica uma remocao pelo caminho das edicoes recebidas
        if cfg.bot == "applytest" and el - bot.last_dig > 6 and el > 15 then
            bot.last_dig = el
            local x, y, z = U.location(pawn)
            local px, py = x + 200, y
            local hit = U.voxel_surface(px, py, z + 300, z - 3000)
            if not hit then
                U.log(("BOT applytest: nenhum mundo de voxel solido abaixo de %.0f %.0f"):format(px, py))
            else
                U.log(("BOT applytest superficie do voxel em z %.0f no mundo %s; densidade 50 cm abaixo antes: %.2f"):format(
                    hit.z, hit.world, U.voxel_value(hit.world, px, py, hit.z - 50) or 99))
                local ok = T.apply({ fn = "RemoveSphere", world = hit.world, x = px, y = py, z = hit.z, radius = 150, a = 0, b = 0, flags = 15 })
                bot.digs[#bot.digs + 1] = { px, py, hit.z }
                ExecuteWithDelay(1500, function()
                    ExecuteInGameThread(function()
                        local after = U.voxel_value(hit.world, px, py, hit.z - 50)
                        U.log(("BOT applytest %s; densidade 50 cm abaixo depois: %s -> %s"):format(ok and "aplicado" or "falhou",
                            after and ("%.2f"):format(after) or "?", (after and after > 0) and "AR (removido)" or "SOLIDO"))
                    end)
                end)
            end
        end
        -- dig: pega a pa inicial, olha para o chao e clica, como um jogador (a escavacao roda fora do Lua)
        if cfg.bot == "dig" and el > 12 and (cfg.role ~= "host" or S.lobby) then
            if not bot.shovel then
                local best, bd
                for _, s in ipairs(FindAllOf("BP_ShovelT1_C") or {}) do
                    local sx, sy, sz = U.location(s)
                    local x, y, z = U.location(pawn)
                    local d = (sx - x) ^ 2 + (sy - y) ^ 2 + (sz - z) ^ 2
                    if not bd or d < bd then best, bd = s, d end
                end
                if best then
                    bot.shovel = best
                    local sx, sy, sz = U.location(best)
                    pawn:K2_TeleportTo(U.vec(sx + 80, sy, sz + 100), pawn:K2_GetActorRotation())
                    local ok, err = pcall(function() pc:PickUpItem(best) end)
                    U.log(("BOT pegou a pa: %s"):format(ok and "ok" or tostring(err)))
                else
                    U.log("BOT sem pa no mundo"); bot.shovel = false
                end
            elseif bot.shovel and el - bot.last_dig > 4 then
                bot.last_dig = el
                pcall(function() pc:SetControlRotation({ Pitch = -60, Yaw = (el * 40) % 360, Roll = 0 }) end)
                local key = { KeyName = FName("LeftMouseButton") }
                local ok, err = pcall(function() pc:InpActEvt_LMB_K2Node_InputActionEvent_5(key) end)
                ExecuteWithDelay(150, function()
                    ExecuteInGameThread(function() pcall(function() pc:InpActEvt_LMB_K2Node_InputActionEvent_6(key) end) end)
                end)
                local carrying = "?"
                pcall(function() carrying = pc.CarryingItem:GetFName():ToString() end)
                U.log(("BOT clique de escavar (%s), carregando %s, entradas nos hooks %d, capturas %d"):format(
                    ok and "ok" or tostring(err), carrying, T.stats.entries, T.stats.captured))
            end
        end
    elseif not bot.checked and el >= secs - 5 then
        bot.checked = true
        -- densidade 50 cm abaixo do centro de cada edicao feita ou recebida: positivo = ar = escavado
        local pts = {}
        for _, d in ipairs(bot.digs) do if d[3] then pts[#pts + 1] = { d[1], d[2], d[3] } end end
        for _, e in ipairs(S.received_edits or {}) do pts[#pts + 1] = { e.x, e.y, e.z, e.world } end
        for _, e in ipairs(S.local_edits or {}) do
            if cfg.bot ~= "terrainsync" then pts[#pts + 1] = { e.x, e.y, e.z, e.world, e.fn } end
        end
        for _, p in ipairs(pts) do
            local world = p[4]
            if not world then local h = U.voxel_surface(p[1], p[2], p[3] + 300, p[3] - 300); world = h and h.world end
            -- no centro exato da edicao: a pa remove uma esfera ao redor do ponto
            local v = world and U.voxel_value(world, p[1], p[2], p[3])
            U.log(("CHECK %.0f %.0f %.0f %s densidade no centro %s"):format(p[1], p[2], p[3], p[5] or "",
                v and ("%.2f"):format(v) or "?"))
        end
        U.log(("BOT fim: bonecos %d, hidden %d, terreno capturado %d aplicado %d"):format(
            A.stats.spawned, (function() local n = 0 for _ in pairs(A.hidden) do n = n + 1 end return n end)(),
            T.stats.captured, T.stats.applied))
        U.log("TESTE_FIM")
    end
end

-- ---------------------------------------------------------------- modo espelho (teste de boneco numa instancia)
-- mirror=1: um boneco no slot 9 segue o proprio jogador com 150 ms de atraso e 3 m de lado.
local mirror = { hist = {}, last_log = 0, err_sum = 0, err_n = 0, err_max = 0, anim_moving = 0, anim_n = 0 }

local function mirror_tick()
    if cfg.mirror ~= "1" or not U.in_game() then return end
    local pawn, pc = U.local_pawn(), U.local_controller()
    if not pawn then return end
    local t = os.clock()
    local pose = A.read_pose(pawn, pc)
    pose.x = pose.x + 300
    mirror.hist[#mirror.hist + 1] = { t, pose }
    while #mirror.hist > 2 and mirror.hist[2][1] <= t - 0.15 do table.remove(mirror.hist, 1) end
    local target = mirror.hist[1][2]
    A.set_puppet_pose(9, target)
    A.tick_puppets()
    local p = A.puppets[9]
    if p and U.valid(p.pawn) then
        local x, y, z = U.location(p.pawn)
        local err = math.sqrt((x - target.x) ^ 2 + (y - target.y) ^ 2)
        mirror.err_sum, mirror.err_n = mirror.err_sum + err, mirror.err_n + 1
        if err > mirror.err_max then mirror.err_max = err end
        local target_speed = math.sqrt(target.vx ^ 2 + target.vy ^ 2)
        if target_speed > 100 then
            mirror.anim_n = mirror.anim_n + 1
            local ok, sp = pcall(function() return p.pawn.Mesh:GetAnimInstance().Speed end)
            if ok and type(sp) == "number" and sp > 50 then mirror.anim_moving = mirror.anim_moving + 1 end
        end
        if t - mirror.last_log > 5 then
            mirror.last_log = t
            local okv, v = pcall(function() return p.pawn:GetVelocity() end)
            local ok2, sp = pcall(function() return p.pawn.Mesh:GetAnimInstance().Speed end)
            U.log(("ESPELHO erro medio %.0f cm, max %.0f, boneco vel %.0f, anim Speed %s, anda-com-animacao %d/%d, teleportes %d"):format(
                mirror.err_sum / math.max(mirror.err_n, 1), mirror.err_max,
                okv and math.sqrt(v.X ^ 2 + v.Y ^ 2) or -1, ok2 and ("%.0f"):format(sp) or "?",
                mirror.anim_moving, mirror.anim_n, A.stats.teleports))
            mirror.err_sum, mirror.err_n, mirror.err_max = 0, 0, 0
        end
    end
end

-- registra edicoes recebidas para o CHECK do robo
do
    local apply = T.apply
    S.received_edits = {}
    T.apply = function(e)
        S.received_edits[#S.received_edits + 1] = e
        return apply(e)
    end
end

-- ---------------------------------------------------------------- laco
local state = { connected = false, ticks = 0, auto_done = false }
local dead, loop_handle = false, nil

local function tick()
    if not state.connected then
        if not mpnet.connect() then return end
        state.connected = true
        U.log("ponte conectada")
    end
    for _, ev in ipairs(mpnet.poll()) do S.handle(ev) end
    state.ticks = state.ticks + 1
    local now = mpnet.now_us
    if now - (state.rate_t or 0) > 30000000 then
        if state.rate_t then
            U.log(("laco: %.0f ticks/s"):format((state.ticks - state.rate_n) / ((now - state.rate_t) / 1e6)))
        end
        state.rate_t, state.rate_n = now, state.ticks
    end

    -- modo UDP de teste: entra ou abre a sala sozinho quando o jogo estiver carregado
    if cfg.transport == "udp" and not state.auto_done and S.self and U.in_game() then
        state.auto_done = true
        if cfg.role == "host" then mpnet.host(4) else mpnet.join(0) end
    end

    S.tick()
    bot_tick()
    mirror_tick()
end

local function safe_tick()
    if dead then return end
    local ok, e = pcall(tick)
    if not ok then
        dead = true
        U.log("ERRO Lua: " .. tostring(e))
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
            if state.ticks < 10 and not dead then
                U.log("laco por frame nao andou; usando atraso em cadeia")
                if loop_handle and CancelDelayedAction then pcall(CancelDelayedAction, loop_handle) end
                start_chain()
            end
        end)
    else
        start_chain()
    end
end

-- ---------------------------------------------------------------- inicio
local started = false
RegisterInitGameStatePostHook(function()
    if started then return end
    started = true
    U.log("==== MpHydroneer " .. S.MOD_VERSION .. " ==== transporte " .. cfg.transport .. (cfg.role ~= "" and (" " .. cfg.role) or ""))
    T.install_hooks()
    local ok, e = mpnet.start(DLL, mode_line())
    if not ok then U.log("ERRO ao iniciar a ponte: " .. tostring(e)); return end
    ExecuteWithDelay(500, start_loop)
    if cfg.newgame == "1" then
        ExecuteWithDelay(8000, function()
            ExecuteInGameThread(function()
                local gi, gm = FindFirstOf("BP_GameInstance_C"), U.game_mode()
                pcall(function() gi.SaveSlot = "MpTeste-" .. (cfg.role ~= "" and cfg.role or "x") end)
                local okn, en = pcall(function() gm:NewGame() end)
                U.log("jogo novo automatico: " .. (okn and "ok" or tostring(en)))
            end)
        end)
    end
end)

RegisterKeyBind(Key.F8, function()
    ExecuteInGameThread(function() if state.connected then S.host_or_invite() end end)
end)
RegisterKeyBind(Key.F9, function()
    ExecuteInGameThread(function() S.leave() end)
end)
