-- proto.lua: mensagens do jogo, em binario (string.pack, little-endian).
-- O primeiro byte e o tipo. Canal 0 = confiavel, canal 1 = nao confiavel.
local P = {}

P.VERSION = 1          -- muda quando o formato de qualquer mensagem mudar
P.CH_RELIABLE, P.CH_FAST = 0, 1

P.T = {
    WELCOME = 1,       -- host -> cliente: slot e versao
    ROSTER = 2,        -- host -> todos: quem esta em cada slot
    POSE = 3,          -- cliente -> host: pose do proprio personagem
    AVATARS = 4,       -- host -> todos: pose de cada slot
    TERRAIN = 5,       -- host -> clientes: edicao de terreno com sequencia
    TERRAIN_REQ = 6,   -- cliente -> host: edicao feita pelo cliente
    PING = 7,          -- qualquer -> qualquer
    PONG = 8,
    BYE = 9,           -- versao incompativel ou sala cheia
}

-- Pose: posicao, yaw, pitch, velocidade, velocidade maxima de caminhada, flags.
-- flags: 1 agachado, 2 no ar, 4 correndo
local POSE_FMT = "<fffffffffB"

function P.pose(p)
    return string.pack(POSE_FMT, p.x, p.y, p.z, p.yaw, p.pitch, p.vx, p.vy, p.vz, p.speed, p.flags)
end
local function read_pose(s, i)
    local x, y, z, yaw, pitch, vx, vy, vz, speed, flags, ni = string.unpack(POSE_FMT, s, i)
    return { x = x, y = y, z = z, yaw = yaw, pitch = pitch, vx = vx, vy = vy, vz = vz, speed = speed, flags = flags }, ni
end

function P.welcome(slot, mod_version)
    return string.pack("<BBBs1", P.T.WELCOME, P.VERSION, slot, mod_version)
end

-- members: lista de {slot, peer, name}
function P.roster(members)
    local parts = { string.pack("<BB", P.T.ROSTER, #members) }
    for _, m in ipairs(members) do parts[#parts + 1] = string.pack("<Bi8s1", m.slot, m.peer, m.name:sub(1, 64)) end
    return table.concat(parts)
end

function P.pose_msg(seq, pose)
    return string.pack("<BI2", P.T.POSE, seq) .. P.pose(pose)
end

-- avatars: lista de {slot, pose}
function P.avatars(seq, avatars)
    local parts = { string.pack("<BI2B", P.T.AVATARS, seq, #avatars) }
    for _, a in ipairs(avatars) do parts[#parts + 1] = string.pack("<B", a.slot) .. P.pose(a.pose) end
    return table.concat(parts)
end

-- Edicao de terreno: funcao do VoxelSphereTools, mundo, centro, raio, extra (valor ou intervalo), 4 flags.
P.FN = { AddSphere = 1, RemoveSphere = 2, SetValueSphere = 3, RemoveSphereWithDurability = 4 }
P.FN_NAME = { "AddSphere", "RemoveSphere", "SetValueSphere", "RemoveSphereWithDurability" }
local EDIT_FMT = "<Bs1ffffffB"

local function edit(e)
    return string.pack(EDIT_FMT, P.FN[e.fn], e.world, e.x, e.y, e.z, e.radius, e.a or 0, e.b or 0, e.flags)
end
local function read_edit(s, i)
    local fn, world, x, y, z, radius, a, b, flags, ni = string.unpack(EDIT_FMT, s, i)
    return { fn = P.FN_NAME[fn], world = world, x = x, y = y, z = z, radius = radius, a = a, b = b, flags = flags }, ni
end

function P.terrain(seq, origin_slot, e)
    return string.pack("<BI4B", P.T.TERRAIN, seq, origin_slot) .. edit(e)
end
function P.terrain_req(e)
    return string.pack("<B", P.T.TERRAIN_REQ) .. edit(e)
end

function P.ping(seq, t_us) return string.pack("<BI4i8", P.T.PING, seq, t_us) end
function P.pong(seq, t_us, fps) return string.pack("<BI4i8f", P.T.PONG, seq, t_us, fps) end
function P.bye(reason) return string.pack("<Bs1", P.T.BYE, reason) end

-- Decodifica qualquer mensagem. Devolve uma tabela com .t ou nil se invalida.
function P.decode(s)
    if #s < 1 then return nil end
    local t = string.byte(s, 1)
    local ok, m = pcall(function()
        if t == P.T.WELCOME then
            local ver, slot, mv = string.unpack("<BBs1", s, 2)
            return { version = ver, slot = slot, mod_version = mv }
        elseif t == P.T.ROSTER then
            local n, i = string.unpack("<B", s, 2)
            local members = {}
            for k = 1, n do
                local slot, peer, name
                slot, peer, name, i = string.unpack("<Bi8s1", s, i)
                members[k] = { slot = slot, peer = peer, name = name }
            end
            return { members = members }
        elseif t == P.T.POSE then
            local seq, i = string.unpack("<I2", s, 2)
            local pose = read_pose(s, i)
            return { seq = seq, pose = pose }
        elseif t == P.T.AVATARS then
            local seq, n, i = string.unpack("<I2B", s, 2)
            local list = {}
            for k = 1, n do
                local slot
                slot, i = string.unpack("<B", s, i)
                local pose
                pose, i = read_pose(s, i)
                list[k] = { slot = slot, pose = pose }
            end
            return { seq = seq, avatars = list }
        elseif t == P.T.TERRAIN then
            local seq, origin, i = string.unpack("<I4B", s, 2)
            return { seq = seq, origin = origin, edit = (read_edit(s, i)) }
        elseif t == P.T.TERRAIN_REQ then
            return { edit = (read_edit(s, 2)) }
        elseif t == P.T.PING then
            local seq, t_us = string.unpack("<I4i8", s, 2)
            return { seq = seq, t_us = t_us }
        elseif t == P.T.PONG then
            local seq, t_us, fps = string.unpack("<I4i8f", s, 2)
            return { seq = seq, t_us = t_us, fps = fps }
        elseif t == P.T.BYE then
            return { reason = (string.unpack("<s1", s, 2)) }
        end
        return {}
    end)
    if not ok or not m then return nil end
    m.t = t
    return m
end

-- Diferenca entre angulos em graus, em [-180, 180)
function P.angle_diff(a, b)
    return (a - b + 180) % 360 - 180
end

return P
