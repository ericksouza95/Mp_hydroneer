-- avatar.lua: pose do jogador local, bonecos dos outros jogadores e pawns ocultos no host.
--
-- Um personagem remoto nunca e teleportado a cada frame: isso trava a animacao de passo.
-- Ele recebe comandos de movimento (AddMovementInput) em direcao a pose recebida e anda
-- com a fisica e a animacao do proprio jogo. So teleporta quando o erro passa de TELEPORT_CM.
local U = require("util")

local A = {}

local TELEPORT_CM = 300
local LEAD_S = 0.10            -- quanto a frente da ultima pose o boneco mira
local ARRIVE_CM = 8

A.puppets = {}                 -- [slot] = {pawn, pose, t}
A.stats = { teleports = 0, spawned = 0, spawn_fail = 0, err_sum = 0, err_n = 0, err_max = 0 }

-- Erro entre a pose recebida (sem a antecipacao) e o personagem; zerado a cada relatorio.
function A.take_error_stats()
    local s = A.stats
    local r = { avg = s.err_n > 0 and s.err_sum / s.err_n or nil, max = s.err_max, n = s.err_n }
    s.err_sum, s.err_n, s.err_max = 0, 0, 0
    return r
end

-- ---------------------------------------------------------------- pose local
local function flags_of(pawn)
    local f = 0
    pcall(function() if pawn.CharacterMovement:IsCrouching() then f = f | 1 end end)
    pcall(function() if pawn.CharacterMovement:IsFalling() then f = f | 2 end end)
    return f
end

function A.read_pose(pawn, controller)
    local x, y, z = U.location(pawn)
    local yaw, pitch = 0, 0
    local okr, r = pcall(function() return controller:GetControlRotation() end)
    if okr and r then yaw, pitch = r.Yaw, r.Pitch
    else local ar = pawn:K2_GetActorRotation(); yaw = ar.Yaw end
    local v = pawn:GetVelocity()
    local speed = 600
    pcall(function() speed = pawn.CharacterMovement.MaxWalkSpeed end)
    return { x = x, y = y, z = z, yaw = yaw, pitch = pitch, vx = v.X, vy = v.Y, vz = v.Z, speed = speed, flags = flags_of(pawn) }
end

-- ---------------------------------------------------------------- motor de movimento
-- Move `pawn` em direcao a `pose`. `controller` e opcional (pawn oculto do host tem um).
function A.drive(pawn, pose, controller)
    if not U.valid(pawn) or not pose then return end
    local x, y, z = U.location(pawn)
    local tx, ty, tz = pose.x + pose.vx * LEAD_S, pose.y + pose.vy * LEAD_S, pose.z
    local dx, dy, dz = tx - x, ty - y, tz - z
    local d2 = math.sqrt(dx * dx + dy * dy)
    local d3 = math.sqrt(dx * dx + dy * dy + dz * dz)
    do
        local ex, ey = pose.x - x, pose.y - y
        local e = math.sqrt(ex * ex + ey * ey)
        A.stats.err_sum, A.stats.err_n = A.stats.err_sum + e, A.stats.err_n + 1
        if e > A.stats.err_max then A.stats.err_max = e end
    end

    pcall(function() pawn.CharacterMovement.MaxWalkSpeed = math.max(pose.speed, 100) * 1.15 end)

    if d3 > TELEPORT_CM then
        pawn:K2_TeleportTo(U.vec(pose.x, pose.y, pose.z), { Pitch = 0, Yaw = pose.yaw, Roll = 0 })
        A.stats.teleports = A.stats.teleports + 1
        return
    end

    if d2 > ARRIVE_CM then
        local scale = math.min(1, d2 / (math.max(pose.speed, 100) * 0.15))
        pawn:AddMovementInput(U.vec(dx / d2, dy / d2, 0), scale, false)
    end

    if controller then
        pcall(function() controller:SetControlRotation({ Pitch = pose.pitch, Yaw = pose.yaw, Roll = 0 }) end)
    end
    pcall(function() pawn:K2_SetActorRotation({ Pitch = 0, Yaw = pose.yaw, Roll = 0 }, false) end)

    -- agachar e pular acompanham as flags
    local crouched = false
    pcall(function() crouched = pawn.CharacterMovement:IsCrouching() end)
    if (pose.flags & 1) ~= 0 and not crouched then pcall(function() pawn:Crouch(false) end)
    elseif (pose.flags & 1) == 0 and crouched then pcall(function() pawn:UnCrouch(false) end) end
    if (pose.flags & 2) ~= 0 and dz > 40 then
        local falling = false
        pcall(function() falling = pawn.CharacterMovement:IsFalling() end)
        if not falling then pcall(function() pawn:Jump() end) end
    end
end

-- ---------------------------------------------------------------- bonecos (clientes)
local function spawn_puppet(pose)
    local me = U.local_pawn()
    if not me then return nil end
    local cls = me:GetClass()
    local world = me:GetWorld()
    local actor
    local ok, err = pcall(function()
        actor = world:SpawnActor(cls, U.vec(pose.x, pose.y, pose.z + 20), { Pitch = 0, Yaw = pose.yaw, Roll = 0 })
    end)
    if not ok or not U.valid(actor) then
        A.stats.spawn_fail = A.stats.spawn_fail + 1
        U.log("ERRO ao criar boneco: " .. tostring(err))
        return nil
    end
    -- Sem controlador, o CharacterMovement so simula se esta flag estiver ligada.
    pcall(function() actor.CharacterMovement.bRunPhysicsWithNoController = true end)
    pcall(function() actor.CharacterMovement:SetMovementMode(1, 0) end)   -- andando
    A.stats.spawned = A.stats.spawned + 1
    return actor
end

-- Atualiza a pose alvo do boneco de `slot`, criando-o se preciso.
function A.set_puppet_pose(slot, pose)
    local p = A.puppets[slot]
    if not p then
        p = { pose = pose }
        A.puppets[slot] = p
    end
    p.pose = pose
    p.t = os.clock()
    if not U.valid(p.pawn) then p.pawn = spawn_puppet(pose) end
end

function A.remove_puppet(slot)
    local p = A.puppets[slot]
    if p and U.valid(p.pawn) then pcall(function() p.pawn:K2_DestroyActor() end) end
    A.puppets[slot] = nil
end

function A.remove_all_puppets()
    for slot in pairs(A.puppets) do A.remove_puppet(slot) end
end

function A.tick_puppets()
    for _, p in pairs(A.puppets) do
        if U.valid(p.pawn) then A.drive(p.pawn, p.pose, nil) end
    end
end

-- ---------------------------------------------------------------- pawns ocultos (host)
-- Cada cliente vira um jogador do caminho de Remote Play do jogo, com SessionID proprio.
local SESSION_BASE = 7000
A.hidden = {}                  -- [slot] = {controller, pawn, pose}

local function controllers_by_name()
    local set = {}
    for _, pc in ipairs(FindAllOf("BP_GameController_C") or {}) do set[pc:GetFName():ToString()] = pc end
    return set
end

function A.add_hidden(slot)
    if A.hidden[slot] then return true end
    local gm = U.game_mode()
    if not gm then return false end
    local before = controllers_by_name()
    local ok, err = pcall(function() gm:AddRemotePlayer({ SessionID = SESSION_BASE + slot }) end)
    if not ok then U.log("ERRO AddRemotePlayer: " .. tostring(err)); return false end
    local h = { pending = true }
    A.hidden[slot] = h
    -- o controlador novo aparece no mesmo frame ou logo depois
    for name, pc in pairs(controllers_by_name()) do
        if not before[name] then h.controller = pc end
    end
    pcall(function()
        local main = U.local_controller()
        if main then U.gameplay_statics():SetForceDisableSplitscreen(main, true) end
    end)
    return true
end

function A.remove_hidden(slot)
    local h = A.hidden[slot]
    if not h then return end
    local gm = U.game_mode()
    if gm then pcall(function() gm:RemovePlayer({ SessionID = SESSION_BASE + slot }) end) end
    A.hidden[slot] = nil
end

function A.set_hidden_pose(slot, pose)
    local h = A.hidden[slot]
    if h then h.pose = pose end
end

function A.hidden_pose(slot)
    local h = A.hidden[slot]
    return h and h.pose
end

function A.tick_hidden()
    for slot, h in pairs(A.hidden) do
        if not U.valid(h.controller) then
            -- procura o controlador pela ordem: o jogo cria um por AddRemotePlayer
            local pcs = FindAllOf("BP_GameController_C") or {}
            local main = U.local_controller()
            local used = {}
            for _, o in pairs(A.hidden) do if U.valid(o.controller) then used[o.controller:GetFName():ToString()] = true end end
            for _, pc in ipairs(pcs) do
                local n = pc:GetFName():ToString()
                if not used[n] and (not main or n ~= main:GetFName():ToString()) then h.controller = pc; break end
            end
        end
        if U.valid(h.controller) then
            local ok, pawn = pcall(function() return h.controller.Pawn end)
            h.pawn = (ok and U.valid(pawn)) and pawn or nil
            if h.pawn and h.pose then A.drive(h.pawn, h.pose, h.controller) end
        end
    end
end

return A
