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

-- ---------------------------------------------------------------- robo de itens (cliente)
-- bot=items: depois de ativo, pega a pa, cava, despeja e solta, tudo pelas teclas enviadas ao host.
local IN = require("input")
local IT = require("items")
local ib = { step = 0, at = 0, log_t = 0 }

local function ib_wait(s) ib.at = os.clock() + s end

local function aim(pc, pawn, tx, ty, tz)
    local x, y, z = U.location(pawn)
    z = z + 64
    pcall(function() local c = pawn.Camera:K2_GetComponentLocation(); x, y, z = c.X, c.Y, c.Z end)
    local r = U.look_at(x, y, z, tx, ty, tz)
    if r then pcall(function() pc:SetControlRotation(r) end) end
end

local function bounds_center(actor)
    local x, y, z = U.location(actor)
    pcall(function()
        local o, e = {}, {}
        actor:GetActorBounds(false, o, e, false)
        local v = o.Origin or o
        if v.X then x, y, z = v.X, v.Y, v.Z end
    end)
    return x, y, z
end

local function looking_at(pc)
    local n = "-"
    pcall(function() local a = pc.LastThingLookingAt; if a and a:IsValid() then n = a:GetFName():ToString() end end)
    return n
end

local function tap(action)
    IN.client_tap(action, true)
    ExecuteWithDelay(150, function() ExecuteInGameThread(function() IN.client_tap(action, false) end) end)
end

local function find_dirt_spot(pawn)
    local vw
    for _, v in ipairs(FindAllOf("VoxelWorld") or {}) do
        if v:GetFName():ToString():find("EmberCradle", 1, true) then vw = v end
    end
    if not vw then return nil end
    local c = vw:K2_GetActorLocation()
    local mx, my = U.location(pawn)
    local best, bd
    for dx = -4000, 4000, 250 do
        for dy = -4000, 4000, 250 do
            local z, who = U.ground_z(c.X + dx, c.Y + dy, c.Z + 5000, c.Z - 5000)
            if z and who and who:find("EmberCradle", 1, true) then
                local d = (c.X + dx - mx) ^ 2 + (c.Y + dy - my) ^ 2
                if not bd or d < bd then best, bd = { c.X + dx, c.Y + dy, z }, d end
            end
        end
    end
    return best
end

local function carrying_name(pc)
    local n = "-"
    pcall(function() local it = pc.CarryingItem; if it and it:IsValid() then n = it:GetFName():ToString() end end)
    return n
end

local function items_bot_tick()
    if cfg.bot ~= "items" or cfg.role ~= "client" or not S.active or not IT.client.snapshot then return end
    local pawn, pc = U.local_pawn(), U.local_controller()
    if not (pawn and pc) then return end
    local t = os.clock()
    if t < ib.at then return end
    if ib.step == 0 then
        ib_wait(4); ib.step = 1
    elseif ib.step == 1 then
        local best, bd
        local x, y, z = U.location(pawn)
        for _, s in ipairs(FindAllOf("BP_ShovelT1_C") or {}) do
            if IT.alive(s) then
                local sx, sy, sz = U.location(s)
                local d = (sx - x) ^ 2 + (sy - y) ^ 2
                if not bd or d < bd then best, bd = s, d end
            end
        end
        if not best then U.log("BOT itens: nenhuma pa"); ib.step = 99; return end
        ib.shovel = best:GetFName():ToString()
        local sx, sy, sz = bounds_center(best)
        pawn:K2_TeleportTo(U.vec(sx + 110, sy, sz + 90), { Pitch = 0, Yaw = 180, Roll = 0 })
        ib.target = { sx, sy, sz }
        U.log(("BOT itens: indo ate a pa %s"):format(ib.shovel))
        ib_wait(1.5); ib.step = 2
    elseif ib.step == 2 then
        aim(pc, pawn, ib.target[1], ib.target[2], ib.target[3])
        ib_wait(0.8); ib.step = 3
    elseif ib.step == 3 then
        tap("Pickup")
        U.log(("BOT itens: E (pegar), o cliente esta olhando %s"):format(looking_at(pc)))
        ib_wait(2.5); ib.step = 4
    elseif ib.step == 4 then
        U.log(("BOT itens: carregando agora %s (esperado %s)"):format(carrying_name(pc), ib.shovel))
        ib.spot = find_dirt_spot(pawn)
        if not ib.spot then U.log("BOT itens: sem ponto cavavel"); ib.step = 99; return end
        local s = ib.spot
        U.log(("BOT itens: ponto cavavel em %.0f %.0f %.0f"):format(s[1], s[2], s[3]))
        pawn:K2_TeleportTo(U.vec(s[1] + 150, s[2], s[3] + 120), { Pitch = 0, Yaw = 180, Roll = 0 })
        ib_wait(2); ib.step = 5
    elseif ib.step == 5 then
        aim(pc, pawn, ib.spot[1], ib.spot[2], ib.spot[3])
        ib_wait(0.8); ib.step = 6
    elseif ib.step == 6 then
        ib.before = U.ground_z(ib.spot[1], ib.spot[2], ib.spot[3] + 500, ib.spot[3] - 500)
        tap("LMB")
        U.log(("BOT itens: clique (cavar), olhando %s, carregando %s"):format(looking_at(pc), carrying_name(pc)))
        ib_wait(3.5); ib.step = 7
    elseif ib.step == 7 then
        local after = U.ground_z(ib.spot[1], ib.spot[2], ib.spot[3] + 500, ib.spot[3] - 500)
        U.log(("BOT itens: chao no ponto antes %.1f depois %s; terreno recebido %d"):format(ib.before or -1,
            after and ("%.1f"):format(after) or "?", S.stats.terrain_in))
        aim(pc, pawn, ib.spot[1], ib.spot[2] + 150, ib.spot[3])
        ib_wait(0.8); ib.step = 8
    elseif ib.step == 8 then
        tap("LMB")
        U.log("BOT itens: clique (despejar)")
        ib_wait(3.5); ib.step = 9
    elseif ib.step == 9 then
        local x, y, z = U.location(pawn)
        local yaw = math.rad(pc:GetControlRotation().Yaw)
        aim(pc, pawn, x + math.cos(yaw) * 150, y + math.sin(yaw) * 150, z - 120)
        ib_wait(0.6); ib.step = 10
    elseif ib.step == 10 then
        tap("Pickup")
        U.log("BOT itens: E (soltar)")
        ib_wait(3); ib.step = 11
    elseif ib.step == 11 then
        U.log(("BOT itens: fim; carregando %s; terreno recebido %d; input enviado %d"):format(carrying_name(pc), S.stats.terrain_in, IN.stats.sent))
        ib.step = 99
    end
end

-- host bot=spawn: cria itens na frente do host durante a sessao, como uma compra ou uma venda faria
local sb = { last = 0, n = 0 }
local SPAWN_CLASSES = { "/Game/WorldObj/Items/BP_Bucket.BP_Bucket_C", "/Game/WorldObj/Items/BP_Pan.BP_Pan_C",
                        "/Game/WorldObj/Items/BP_Coin.BP_Coin_C" }
local function spawn_bot_tick()
    if cfg.bot ~= "spawn" or cfg.role ~= "host" or not S.lobby then return end
    local active = false
    for _, p in pairs(S.peers) do if p.active then active = true end end
    if not active or os.clock() - sb.last < 8 or sb.n >= 6 then return end
    sb.last = os.clock()
    sb.n = sb.n + 1
    local pawn = U.local_pawn()
    if not pawn then return end
    local cp = SPAWN_CLASSES[(sb.n - 1) % #SPAWN_CLASSES + 1]
    local cls = StaticFindObject(cp)
    if not U.valid(cls) then
        -- caminho real da classe: procura um item vivo dessa classe
        local short = cp:match("%.([%w_]+)$")
        local any = FindFirstOf(short)
        if U.valid(any) then cls = any:GetClass() end
    end
    if not U.valid(cls) then U.log("BOT spawn: classe nao encontrada " .. cp); return end
    local x, y, z = U.location(pawn)
    local a
    local ok, err = pcall(function() a = pawn:GetWorld():SpawnActor(cls, U.vec(x + 150, y + (sb.n - 3) * 60, z + 50), { Pitch = 0, Yaw = 0, Roll = 0 }) end)
    if ok and U.valid(a) then
        if cp:find("Coin", 1, true) then pcall(function() a:InitAmount(37 * sb.n, false) end) end
        U.log(("BOT spawn: criado %s"):format(a:GetFName():ToString()))
    else
        U.log("BOT spawn: falhou " .. tostring(err))
    end
end

-- ---------------------------------------------------------------- robos de teste (so com mp-config.txt)
local bot = { digs = {}, last_dig = 0, t0 = nil, checked = false }

local function bot_tick()
    if cfg.bot == "none" or cfg.bot == "items" or cfg.bot == "spawn" or not U.in_game() then return end
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
    if cfg.transport == "udp" and S.self and (U.in_game() or cfg.role ~= "host") and not S.lobby
        and (not state.auto_done or (cfg.role ~= "host" and os.clock() - state.auto_t > 12)) then
        state.auto_done, state.auto_t = true, os.clock()
        if cfg.role == "host" then mpnet.host(4) else mpnet.join(0) end
    end

    S.tick()
    bot_tick()
    mirror_tick()
    items_bot_tick()
    T.guarded(spawn_bot_tick)
end

local function safe_tick()
    if dead then return end
    local ok, e = pcall(tick)
    if not ok then
        -- um erro num tick nao derruba a sessao: registra e segue
        state.errors = (state.errors or 0) + 1
        if state.errors <= 20 or state.errors % 100 == 0 then
            U.log(("ERRO Lua (%d): %s"):format(state.errors, tostring(e)))
        end
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
    if cfg.continue and cfg.continue ~= "" then
        -- teste: carrega um save sozinho e conta jogadores e itens (save gravado durante o co-op)
        ExecuteWithDelay(8000, function()
            ExecuteInGameThread(function()
                local gm = U.game_mode()
                pcall(function() StaticFindObject("/Script/EasyMultiSave.Default__EMSFunctionLibrary"):SetCurrentSaveGameName(gm, cfg.continue) end)
                local okc, ec = pcall(function() gm:ContinueGame(false, false, false, cfg.continue) end)
                U.log("continuar save " .. cfg.continue .. ": " .. (okc and "ok" or tostring(ec)))
                ExecuteWithDelay(12000, function()
                    ExecuteInGameThread(function()
                        local pcs = FindAllOf("BP_GameController_C") or {}
                        local lps = FindAllOf("LocalPlayer") or {}
                        local chars = FindAllOf("BP_Character_HydroGuy_C") or {}
                        local items = FindAllOf("BP_ParentItem_C") or {}
                        U.log(("SAVE SOZINHO: em jogo %s, controladores %d, jogadores locais %d, personagens HydroGuy %d, itens %d"):format(
                            tostring(U.in_game()), #pcs, #lps, #chars, #items))
                        U.log("TESTE_FIM")
                    end)
                end)
            end)
        end)
    end
    if cfg.newgame == "1" then
        ExecuteWithDelay(8000, function()
            ExecuteInGameThread(function()
                local gi, gm = FindFirstOf("BP_GameInstance_C"), U.game_mode()
                local slot = "MpTeste-" .. (cfg.role ~= "" and cfg.role or "x")
                pcall(function() gi.SaveSlot = slot end)
                -- NewGame usa o ultimo slot aberto; sem isto um teste sobrescreveria o MpHydroneerHost
                pcall(function() StaticFindObject("/Script/EasyMultiSave.Default__EMSFunctionLibrary"):SetCurrentSaveGameName(gm, slot) end)
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
