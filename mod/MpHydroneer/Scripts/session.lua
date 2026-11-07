-- session.lua: sala, slots, ping, e o roteamento de pose e terreno entre host e clientes.
--
-- Topologia em estrela. O host e o slot 0; clientes recebem os slots 1 a 3 na ordem de entrada.
-- Cliente -> host: POSE (30 Hz), TERRAIN_REQ. Host -> clientes: WELCOME, ROSTER, AVATARS (30 Hz), TERRAIN.
local U = require("util")
local P = require("proto")
local A = require("avatar")
local T = require("terrain")
local mpnet = require("mpnet")

local S = {}

S.MOD_VERSION = "0.2"
local POSE_HZ = 30
local PING_INTERVAL_US = 250000
local WINDOW_US = 5000000
local WARMUP_US = 10000000      -- pings dos primeiros 10 s de cada par ficam fora das medias

S.self, S.name = nil, "?"
S.lobby, S.owner = nil, nil
S.is_host = false
S.my_slot = nil                 -- slot desta maquina (host = 0)
S.peers = {}                    -- [peer] = {slot, name, joined_us, samples = {{t, rtt}}, sent, recv, fps}
S.slots = {}                    -- [slot] = peer
S.terrain_seq = 0
S.stats = { pose_out = 0, pose_in = 0, avatars_out = 0, avatars_in = 0, terrain_out = 0, terrain_in = 0 }

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

local function reset_session()
    for slot in pairs(A.hidden) do A.remove_hidden(slot) end
    A.remove_all_puppets()
    S.lobby, S.owner, S.is_host, S.my_slot = nil, nil, false, nil
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
            return slot
        end
    end
    send(peer, P.bye("sala cheia"), true)
    U.log("sala cheia, recusado: " .. name)
    return nil
end

local function host_drop(peer)
    for slot, p in pairs(S.slots) do
        if p == peer and slot ~= 0 then
            S.slots[slot] = nil
            A.remove_hidden(slot)
            U.log(("slot %d liberado"):format(slot))
        end
    end
    broadcast(P.roster(roster_list()), true)
end

local function slot_of(peer)
    local p = S.peers[peer]
    return p and p.slot
end

-- ---------------------------------------------------------------- mensagens
local function on_message(peer, data)
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
        if m.t == T_.POSE then
            local slot = slot_of(peer)
            if slot then A.set_hidden_pose(slot, m.pose); S.stats.pose_in = S.stats.pose_in + 1 end
        elseif m.t == T_.TERRAIN_REQ then
            local slot = slot_of(peer)
            if slot then
                T.apply(m.edit)
                S.terrain_seq = S.terrain_seq + 1
                broadcast(P.terrain(S.terrain_seq, slot, m.edit), true, peer)
                S.stats.terrain_in = S.stats.terrain_in + 1
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
        elseif m.t == T_.ROSTER then
            local present = {}
            S.slots = {}
            for _, r in ipairs(m.members) do
                present[r.slot] = true
                S.slots[r.slot] = r.peer
                peer_info(r.peer, r.name).slot = r.slot
            end
            for slot in pairs(A.puppets) do if not present[slot] then A.remove_puppet(slot) end end
        elseif m.t == T_.AVATARS then
            S.stats.avatars_in = S.stats.avatars_in + 1
            if U.in_game() then
                for _, a in ipairs(m.avatars) do
                    if a.slot ~= S.my_slot then A.set_puppet_pose(a.slot, a.pose) end
                end
            end
        elseif m.t == T_.TERRAIN then
            if m.origin ~= S.my_slot then
                T.apply(m.edit)
                S.stats.terrain_in = S.stats.terrain_in + 1
            end
        elseif m.t == T_.BYE then
            U.log("o host recusou: " .. m.reason)
            S.leave()
        end
    end
end

-- edicao de terreno feita nesta maquina
S.local_edits = {}
T.on_local_edit = function(e)
    S.local_edits[#S.local_edits + 1] = e
    if #S.local_edits > 200 then table.remove(S.local_edits, 1) end
    if not S.lobby then return end
    S.stats.terrain_out = S.stats.terrain_out + 1
    if S.is_host then
        S.terrain_seq = S.terrain_seq + 1
        broadcast(P.terrain(S.terrain_seq, 0, e), true)
    elseif S.owner then
        send(S.owner, P.terrain_req(e), true)
    end
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
        on_message(ev.peer, ev.data)
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

function S.tick()
    local t = now()
    local in_game = U.in_game()

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
                if #list > 1 or next(A.hidden) then
                    broadcast(P.avatars(pose_seq, list), false)
                    S.stats.avatars_out = S.stats.avatars_out + 1
                end
            elseif S.my_slot and S.owner then
                send(S.owner, P.pose_msg(pose_seq, mine), false)
                S.stats.pose_out = S.stats.pose_out + 1
            end
        end
    end
    if in_game then
        if S.is_host then A.tick_hidden() else A.tick_puppets() end
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
            local st = S.stats
            local e = A.take_error_stats()
            U.log(("REDE pose %d/%d avatares %d/%d terreno %d/%d (env/rec) bonecos %d teleportes %d terreno aplicado %d falhas %d | erro avatar %s"):format(
                st.pose_out, st.pose_in, st.avatars_out, st.avatars_in, st.terrain_out, st.terrain_in,
                A.stats.spawned, A.stats.teleports, T.stats.applied, T.stats.failed,
                e.avg and ("medio %.0f cm, max %.0f cm (%d amostras)"):format(e.avg, e.max, e.n) or "sem amostras"))
        end
        if report then last_report_us = t end
        local title
        if not S.lobby then
            title = "Hydroneer MP " .. S.MOD_VERSION .. " | F8 para hospedar e convidar"
        else
            title = ("Hydroneer MP %s | %s | sala %d/4 | %s | F8 convidar, F9 sair"):format(S.MOD_VERSION,
                S.is_host and "host" or ("slot " .. tostring(S.my_slot or "?")), n,
                #parts > 0 and table.concat(parts, ", ") or "esperando amigo")
        end
        mpnet.set_title(title)
    end
end

return S
