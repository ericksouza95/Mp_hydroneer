-- session.lua: sala, slots, fases de entrada e o roteamento entre host e clientes.
--
-- Topologia em estrela. O host e o slot 0; clientes recebem os slots 1 a 3 na ordem de entrada.
-- Fases do cliente: entrou na sala -> recebe e carrega o mundo do host (savesync) -> ativo.
-- No cliente ativo, as acoes de mundo vao para o host (input), e o mundo vem do host:
-- itens (items), terreno (terrain), hora (world) e as poses dos outros (avatar).
local U = require("util")
local P = require("proto")
local A = require("avatar")
local T = require("terrain")
local I = require("input")
local IT = require("items")
local W = require("world")
local SS = require("savesync")
local mpnet = require("mpnet")

local S = {}

S.MOD_VERSION = "0.3"
local POSE_HZ = 30
local PING_INTERVAL_US = 250000
local WINDOW_US = 5000000
local WARMUP_US = 10000000      -- pings dos primeiros 10 s de cada par ficam fora das medias
local NOSAVE = U.cfg.nosave == "1"   -- testes: pula a transferencia do save (os dois comecam jogo novo)

S.self, S.name = nil, "?"
S.lobby, S.owner = nil, nil
S.is_host = false
S.my_slot = nil                 -- slot desta maquina (host = 0)
S.active = false                -- cliente: mundo do host carregado, sessao em andamento
S.peers = {}                    -- [peer] = {slot, name, joined_us, samples, sent, recv, fps, active}
S.slots = {}                    -- [slot] = peer
S.terrain_seq = 0
S.edit_log = {}                 -- host: { {seq, edit} } para repetir a quem entra depois do save
S.stats = { pose_out = 0, pose_in = 0, avatars_out = 0, avatars_in = 0, terrain_out = 0, terrain_in = 0, input_in = 0 }

local last_pose_us, pose_seq, last_ping_us, ping_seq, last_report_us, last_title_us = 0, 0, 0, 0, 0, 0

local function now() return mpnet.now_us end

local function peer_info(peer, name)
    local p = S.peers[peer]
    if not p then
        p = { name = name or tostring(peer), joined_us = now(), samples = {}, sent = 0, recv = 0, fps = 0 }
        S.peers[peer] = p
    end
    if name then p.name = name end
    return p
end

local function send(peer, bytes, reliable)
    if reliable then mpnet.send(peer, bytes, mpnet.RELIABLE, P.CH_RELIABLE)
    else mpnet.send(peer, bytes, mpnet.UNRELIABLE, P.CH_FAST) end
end

local function others()
    local list = {}
    for peer in pairs(S.peers) do if peer ~= S.self then list[#list + 1] = peer end end
    return list
end

local function roster_list()
    local list = {}
    for slot = 0, 3 do
        local peer = S.slots[slot]
        if peer then list[#list + 1] = { slot = slot, peer = peer, name = (S.peers[peer] and S.peers[peer].name) or S.name } end
    end
    return list
end

local function broadcast(bytes, reliable, except)
    for _, peer in ipairs(others()) do
        if peer ~= except then send(peer, bytes, reliable) end
    end
end

-- So para clientes com o mundo carregado (estado do mundo nao faz sentido antes).
local function broadcast_active(bytes, reliable, except)
    for _, peer in ipairs(others()) do
        local p = S.peers[peer]
        if peer ~= except and p and p.active then send(peer, bytes, reliable) end
    end
end

local function slot_of(peer)
    local p = S.peers[peer]
    return p and p.slot
end

local function controllers_by_slot()
    local t = {}
    local main = U.local_controller()
    if main then t[0] = main end
    for slot, h in pairs(A.hidden) do
        if U.valid(h.controller) then t[slot] = h.controller end
    end
    return t
end

-- ---------------------------------------------------------------- savesync e modulos
SS.init({
    send = function(peer, bytes, reliable, channel)
        mpnet.send(peer, bytes, reliable == false and mpnet.UNRELIABLE or mpnet.RELIABLE, channel or SS.CHANNEL)
    end,
    log = U.log,
    now_us = function() return mpnet.now_us end,
})
SS.host_terrain_mark = function() return S.terrain_seq end

IT.broadcast = function(bytes, reliable) broadcast_active(bytes, reliable) end
IT.my_slot = function() return S.my_slot end
I.on_send = function(bytes) if S.owner then send(S.owner, bytes, true) end end
I.item_id_of = IT.client_id_of
I.item_by_id = IT.host_item

-- host: cliente com o mundo carregado na marca de terreno `mark`
local function host_activate(peer, mark)
    local p = S.peers[peer]
    if not p or p.active then return end
    p.active = true
    local n = 0
    for _, e in ipairs(S.edit_log) do
        if e[1] > (mark or 0) then
            if e[3] then send(peer, P.terrain_patch(e[1], e[3]), true) else send(peer, P.terrain(e[1], 0, e[2]), true) end
            n = n + 1
        end
    end
    IT.host_start()
    local items = IT.host_snapshot(function(bytes, reliable) send(peer, bytes, reliable) end)
    IT.host.carry = {}          -- reenvia quem carrega o que
    U.log(("%s ativo: %d edicoes de terreno repetidas desde a marca %d, %d itens enviados"):format(p.name, n, mark or 0, items))
end
SS.on_client_loaded = function(peer, mark) host_activate(peer, mark) end

-- cliente: mundo do host carregado
local function client_activate(mark)
    if S.active then return end
    S.active = true
    T.guarded(I.client_enable)
    U.log(("mundo do host carregado (marca de terreno %s); acoes de mundo agora vao para o host"):format(tostring(mark)))
end
SS.on_world_loaded = function(mark) client_activate(mark) end

local function reset_session()
    for slot in pairs(A.hidden) do A.remove_hidden(slot) end
    A.remove_all_puppets()
    I.client_disable()
    W.client_reset()
    IT.client_reset()
    IT.host_reset()
    for peer in pairs(S.peers) do pcall(SS.drop_peer, peer) end
    T.capture = false
    S.lobby, S.owner, S.is_host, S.my_slot, S.active = nil, nil, false, nil, false
    S.peers, S.slots = {}, {}
end

-- ---------------------------------------------------------------- comandos do jogador
function S.host_or_invite()
    if not S.lobby and not U.in_game() then
        U.log("F8: entre num jogo antes de hospedar (o menu principal nao tem mundo para o amigo)")
        mpnet.set_title("Hydroneer MP " .. S.MOD_VERSION .. " | entre num jogo e aperte F8 de novo")
        return
    end
    if S.lobby then
        mpnet.invite()
        U.log("convite reaberto")
    else
        mpnet.host(4)
        U.log("criando sala")
    end
end

function S.leave()
    if S.lobby then
        mpnet.leave()
        U.log("saindo da sala")
    end
end

-- ---------------------------------------------------------------- host
local function host_assign(peer, name)
    for slot, p in pairs(S.slots) do if p == peer then return slot end end
    for slot = 1, 3 do
        if not S.slots[slot] then
            S.slots[slot] = peer
            peer_info(peer, name).slot = slot
            A.add_hidden(slot)
            send(peer, P.welcome(slot, S.MOD_VERSION), true)
            broadcast(P.roster(roster_list()), true)
            U.log(("slot %d para %s"):format(slot, name))
            if NOSAVE then host_activate(peer, S.terrain_seq) end
            return slot
        end
    end
    send(peer, P.bye("sala cheia"), true)
    U.log("sala cheia, recusado: " .. name)
    return nil
end

local function host_drop(peer)
    pcall(SS.drop_peer, peer)
    for slot, p in pairs(S.slots) do
        if p == peer and slot ~= 0 then
            S.slots[slot] = nil
            A.remove_hidden(slot)
            U.log(("slot %d liberado"):format(slot))
        end
    end
    broadcast(P.roster(roster_list()), true)
end

-- ---------------------------------------------------------------- mensagens
local function on_message(peer, data, channel)
    if channel == SS.CHANNEL or SS.handles(data) then
        if S.is_host then SS.host_handle(peer, data) else SS.client_handle(peer, data) end
        return
    end
    local m = P.decode(data)
    if not m then return end
    local T_ = P.T
    if m.t == T_.PING then
        send(peer, P.pong(m.seq, m.t_us, 1 / U.delta_seconds()), false)
    elseif m.t == T_.PONG then
        local p = peer_info(peer)
        p.recv = p.recv + 1
        p.fps = m.fps
        p.samples[#p.samples + 1] = { now(), now() - m.t_us }
    elseif S.is_host then
        local p = S.peers[peer]
        if not (p and p.active) then return end
        if m.t == T_.POSE then
            local slot = slot_of(peer)
            if slot then A.set_hidden_pose(slot, m.pose); S.stats.pose_in = S.stats.pose_in + 1 end
        elseif m.t == T_.INPUT then
            local slot = slot_of(peer)
            local h = slot and A.hidden[slot]
            if h and U.valid(h.controller) then
                -- a mira do pawn oculto ja segue a pose; acerta a rotacao exata antes de agir
                local pose = A.hidden_pose(slot)
                if pose then pcall(function() h.controller:SetControlRotation({ Pitch = pose.pitch, Yaw = pose.yaw, Roll = 0 }) end) end
                local skipped_before = T.stats.skipped_in_lua_call
                T.guarded(I.host_replay, h.controller, m)
                S.stats.input_in = S.stats.input_in + 1
                if T.stats.skipped_in_lua_call > skipped_before then
                    -- a acao editou o terreno dentro da chamada: copia o resultado ao redor da mira
                    local hx, hy, hz, world
                    pcall(function()
                        local hit = h.controller.CrosshairTraceHit
                        local pt = hit.ImpactPoint or hit.Location
                        hx, hy, hz = pt.X, pt.Y, pt.Z
                        local a = hit.Actor:Get()
                        if a and a:IsValid() then world = a:GetFName():ToString() end
                    end)
                    if hx and world and world:find("VoxelWorld", 1, true) then
                        local patch = T.read_patch(world, hx, hy, hz, tonumber(U.cfg.patch_cm or "90"), function() return mpnet.now_us end)
                        if patch then
                            S.terrain_seq = S.terrain_seq + 1
                            S.edit_log[#S.edit_log + 1] = { S.terrain_seq, nil, patch }
                            broadcast_active(P.terrain_patch(S.terrain_seq, patch), true)
                            S.stats.terrain_out = S.stats.terrain_out + 1
                            U.log(("terreno: retalho %d voxels (%d^3) em %s, voxel %.0f cm, leitura %.1f ms"):format(
                                patch.n ^ 3, patch.n, world, T.patch_stats.voxel_size, T.patch_stats.read_us / 1000))
                        end
                    else
                        U.log("terreno: edicao dentro da acao, mas a mira nao bateu num mundo de voxel (" .. tostring(world) .. ")")
                    end
                end
                if U.cfg.debug_input == "1" then
                    local c = h.controller
                    local look, hit, carry, loc, rot = "-", "-", "-", "?", "?"
                    pcall(function() local a = c.LastThingLookingAt; if a and a:IsValid() then look = a:GetFName():ToString() end end)
                    pcall(function() local a = c.CrosshairTraceHit.Actor:Get(); if a and a:IsValid() then hit = a:GetFName():ToString() end end)
                    pcall(function() local a = c.CarryingItem; if a and a:IsValid() then carry = a:GetFName():ToString() end end)
                    pcall(function() local x, y, z = U.location(c.Pawn); loc = ("%.0f %.0f %.0f"):format(x, y, z) end)
                    pcall(function() local r = c:GetControlRotation(); rot = ("p%.0f y%.0f"):format(r.Pitch, r.Yaw) end)
                    U.log(("INPUT slot %d %s %s: mira %s, olhando %s, raio bateu em %s, carregando %s, pawn em %s"):format(
                        slot, P.ACTIONS[m.action] and P.ACTIONS[m.action].name or "?", m.pressed and "apertou" or "soltou",
                        rot, look, hit, carry, loc))
                end
            end
        end
    else
        if m.t == T_.WELCOME then
            if m.version ~= P.VERSION then
                U.log(("ERRO: protocolo do host %d, o meu %d. Atualizem o mod para a mesma versao."):format(m.version, P.VERSION))
                S.leave()
                return
            end
            S.my_slot = m.slot
            U.log(("bem-vindo: slot %d, host com mod %s"):format(m.slot, m.mod_version))
            if NOSAVE then client_activate(0) else SS.client_request(S.owner) end
        elseif m.t == T_.ROSTER then
            local present = {}
            S.slots = {}
            for _, r in ipairs(m.members) do
                present[r.slot] = true
                S.slots[r.slot] = r.peer
                peer_info(r.peer, r.name).slot = r.slot
            end
            for slot in pairs(A.puppets) do if not present[slot] then A.remove_puppet(slot) end end
        elseif m.t == T_.BYE then
            U.log("o host recusou: " .. m.reason)
            S.leave()
        elseif not S.active then
            return                 -- estado do mundo antes de carregar o mundo do host: ignora
        elseif m.t == T_.AVATARS then
            S.stats.avatars_in = S.stats.avatars_in + 1
            if U.in_game() then
                for _, a in ipairs(m.avatars) do
                    if a.slot ~= S.my_slot then A.set_puppet_pose(a.slot, a.pose) end
                end
            end
        elseif m.t == T_.TERRAIN then
            T.apply(m.edit)
            S.stats.terrain_in = S.stats.terrain_in + 1
        elseif m.t == T_.TERRAIN_PATCH then
            T.apply_patch(m.patch, function() return mpnet.now_us end)
            S.stats.terrain_in = S.stats.terrain_in + 1
            U.log(("terreno: retalho aplicado, %d voxels gravados ate agora, ultima aplicacao %.1f ms"):format(
                T.patch_stats.voxels_set, T.patch_stats.apply_us / 1000))
        elseif m.t == T_.TIME then
            W.client_handle(m)
        elseif m.t == T_.ITEM_NEW or m.t == T_.ITEM_XFORM or m.t == T_.ITEM_GONE or m.t == T_.ITEM_STATE
            or m.t == T_.CARRY or m.t == T_.SNAPSHOT_DONE then
            T.guarded(IT.client_handle, m)
        end
    end
end

-- edicao de terreno capturada no host (o cliente nao captura: as acoes dele rodam no host)
S.local_edits = {}
T.on_local_edit = function(e)
    S.local_edits[#S.local_edits + 1] = e
    if #S.local_edits > 200 then table.remove(S.local_edits, 1) end
    if not (S.lobby and S.is_host) then return end
    S.stats.terrain_out = S.stats.terrain_out + 1
    S.terrain_seq = S.terrain_seq + 1
    S.edit_log[#S.edit_log + 1] = { S.terrain_seq, e }
    broadcast_active(P.terrain(S.terrain_seq, 0, e), true)
end

-- ---------------------------------------------------------------- eventos da ponte
function S.handle(ev)
    local E = mpnet.EV
    if ev.type == E.HELLO then
        S.self, S.name = ev.self, ev.name
        U.log(("pronto: %s, app %d, mpnet %d, MpHydroneer %s, protocolo %d"):format(ev.name, ev.app, ev.version, S.MOD_VERSION, P.VERSION))
    elseif ev.type == E.ERROR then
        U.log("ERRO da ponte: " .. ev.message)
    elseif ev.type == E.LOBBY_CREATED then
        U.log(("sala criada: resultado %d"):format(ev.result))
        if ev.result == 1 and U.cfg.transport == "steam" then mpnet.invite() end
    elseif ev.type == E.LOBBY_ENTERED then
        if ev.response == 1 then
            S.lobby, S.owner = ev.lobby, ev.owner
            S.is_host = (ev.owner == S.self)
            if S.is_host then
                S.my_slot = 0
                S.slots[0] = S.self
                peer_info(S.self, S.name).slot = 0
                T.capture = true
                IT.host_start()
            end
            U.log(S.is_host and "sala aberta, voce e o host" or "entrou na sala do host")
        else
            U.log(("falha ao entrar na sala, resposta %d"):format(ev.response))
        end
    elseif ev.type == E.MEMBER_JOINED then
        peer_info(ev.peer, ev.name)
        if ev.peer ~= S.self then
            U.log("entrou: " .. ev.name)
            if S.is_host then host_assign(ev.peer, ev.name) end
        end
    elseif ev.type == E.MEMBER_LEFT then
        local p = S.peers[ev.peer]
        if ev.peer == S.self then
            reset_session()
            U.log("fora da sala")
        else
            if p then U.log("saiu: " .. p.name) end
            if S.is_host then host_drop(ev.peer) end
            if p and p.slot then A.remove_puppet(p.slot) end
            S.peers[ev.peer] = nil
            if not S.is_host and ev.peer == S.owner then
                U.log("o host saiu")
                reset_session()
            end
        end
    elseif ev.type == E.JOIN_REQUESTED then
        if S.lobby and ev.lobby == S.lobby then
            U.log("convite para a sala atual ignorado")
        else
            U.log("convite aceito, entrando na sala")
            if S.lobby then mpnet.leave() end
            mpnet.join(ev.lobby)
        end
    elseif ev.type == E.PACKET then
        on_message(ev.peer, ev.data, ev.channel)
    elseif ev.type == E.SESSION_FAIL then
        U.log(("ERRO de sessao P2P com %s: codigo %d"):format(tostring(ev.peer), ev.error))
    elseif ev.type == E.PEER_STATE then
        local p = S.peers[ev.peer]
        if p then
            if p.relay ~= ev.relay then U.log(("rota com %s: %s"):format(p.name, ev.relay and "relay" or "direta")) end
            p.relay = ev.relay
        end
    end
end

-- ---------------------------------------------------------------- tick
local function window_stats(p, t)
    local list = {}
    local keep = {}
    for _, s in ipairs(p.samples) do
        if t - s[1] <= WINDOW_US then keep[#keep + 1] = s end
        if t - s[1] <= WINDOW_US and s[1] - p.joined_us > WARMUP_US then list[#list + 1] = s[2] end
    end
    p.samples = keep
    if #list == 0 then return nil end
    table.sort(list)
    local sum = 0
    for _, v in ipairs(list) do sum = sum + v end
    return { n = #list, avg = sum / #list / 1000, min = list[1] / 1000, max = list[#list] / 1000 }
end

local function any_active()
    for _, p in pairs(S.peers) do if p.active then return true end end
    return false
end

function S.tick()
    local t = now()
    local in_game = U.in_game()

    -- transferencia do mundo
    if S.lobby then
        if S.is_host then SS.host_tick() else SS.client_tick() end
    end

    -- pose e avatares
    if S.lobby and in_game and t - last_pose_us >= 1000000 / POSE_HZ then
        last_pose_us = t
        pose_seq = (pose_seq + 1) % 65536
        local pawn, pc = U.local_pawn(), U.local_controller()
        if pawn then
            local mine = A.read_pose(pawn, pc)
            if S.is_host then
                local list = { { slot = 0, pose = mine } }
                for slot in pairs(A.hidden) do
                    local hp = A.hidden_pose(slot)
                    if hp then list[#list + 1] = { slot = slot, pose = hp } end
                end
                if any_active() then
                    broadcast_active(P.avatars(pose_seq, list), false)
                    S.stats.avatars_out = S.stats.avatars_out + 1
                end
            elseif S.active and S.my_slot and S.owner then
                send(S.owner, P.pose_msg(pose_seq, mine), false)
                S.stats.pose_out = S.stats.pose_out + 1
            end
        end
    end

    if in_game and S.lobby then
        if S.is_host then
            A.tick_hidden()
            if any_active() then
                IT.host_tick(controllers_by_slot)
                W.host_tick(function(bytes, reliable) broadcast_active(bytes, reliable) end)
            end
        elseif S.active then
            A.tick_puppets()
            I.client_tick()
            T.guarded(IT.client_tick)
        end
    end

    -- ping
    if S.lobby and t - last_ping_us >= PING_INTERVAL_US then
        last_ping_us = t
        ping_seq = ping_seq + 1
        for _, peer in ipairs(others()) do
            if S.is_host or peer == S.owner then
                send(peer, P.ping(ping_seq, t), false)
                local p = S.peers[peer]
                if p then p.sent = p.sent + 1 end
            end
        end
        if ping_seq % 4 == 0 then mpnet.peer_state() end
    end

    -- relatorio a cada 5 s, titulo a cada 1 s
    local report = t - last_report_us >= WINDOW_US
    if t - last_title_us >= 1000000 then
        last_title_us = t
        local parts, n = {}, 0
        for peer, p in pairs(S.peers) do
            n = n + 1
            if peer ~= S.self and (S.is_host or peer == S.owner) then
                local w = window_stats(p, t)
                parts[#parts + 1] = ("%s %s ms (%.0f fps)"):format(p.name, w and ("%.0f"):format(w.avg) or "--", p.fps or 0)
                if report then
                    U.log(("PING %s: %s, fps remoto %.0f, rota %s"):format(p.name,
                        w and ("media %.0f ms, min %.0f, max %.0f em %d amostras"):format(w.avg, w.min, w.max, w.n)
                          or "aquecendo (primeiros 10 s fora da media)",
                        p.fps or 0, p.relay == nil and "?" or (p.relay and "relay" or "direta")))
                end
            end
        end
        if report and S.lobby then
            local st, is, its = S.stats, I.stats, IT.stats
            local e = A.take_error_stats()
            U.log(("REDE pose %d/%d avatares %d/%d terreno %d/%d input %d/%d (env/rec) | erro avatar %s"):format(
                st.pose_out, st.pose_in, st.avatars_out, st.avatars_in, st.terrain_out, st.terrain_in, is.sent, st.input_in,
                e.avg and ("medio %.0f cm, max %.0f cm"):format(e.avg, e.max) or "sem amostras"))
            U.log(("ITENS host: registrados %d (novos %d), posicoes %d, estados %d, removidos %d | cliente: associados %d, copias %d, posicoes %d, estados %d, removidos %d, ids desconhecidos %d, espelho carregar %d"):format(
                its.registered, its.runtime, its.xform_sent, its.state_sent, its.gone_sent,
                its.paired, its.spawned, its.xform_applied, its.state_applied, its.destroyed, its.unknown_id, its.carry_mirror))
            U.log(("TERRENO capturado %d aplicado %d falhas %d, fora do host %d, dentro de chamada do mod %d | input executado %d falhas %d | hora env %d apl %d"):format(
                T.stats.captured, T.stats.applied, T.stats.failed, T.stats.skipped_not_host, T.stats.skipped_in_lua_call,
                is.replayed, is.replay_fail, W.stats.sent, W.stats.applied))
        end
        if report then last_report_us = t end
        local title
        if not S.lobby then
            title = "Hydroneer MP " .. S.MOD_VERSION .. " | F8 para hospedar e convidar"
        elseif not S.is_host and not S.active then
            title = ("Hydroneer MP %s | recebendo o mundo do host: %s %.0f%%"):format(S.MOD_VERSION, SS.state(), 100 * (SS.progress() or 0))
        else
            title = ("Hydroneer MP %s | %s | sala %d/4 | %s | F8 convidar, F9 sair"):format(S.MOD_VERSION,
                S.is_host and "host" or ("slot " .. tostring(S.my_slot or "?")), n,
                #parts > 0 and table.concat(parts, ", ") or "esperando amigo")
        end
        mpnet.set_title(title)
    end
end

return S
