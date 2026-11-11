-- proto.lua: mensagens do jogo, em binario (string.pack, little-endian).
-- O primeiro byte e o tipo. Canal 0 = confiavel, canal 1 = nao confiavel.
local P = {}

P.VERSION = 2          -- muda quando o formato de qualquer mensagem mudar
P.CH_RELIABLE, P.CH_FAST = 0, 1      -- canal 2 e do savesync (tipos 20 a 29)

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
    INPUT = 10,        -- cliente -> host: acao de mundo apertada ou solta
    ITEM_NEW = 12,     -- host -> clientes: item com id de rede, nome, classe e posicao
    ITEM_XFORM = 13,   -- host -> clientes: posicoes de itens que se moveram (nao confiavel)
    ITEM_GONE = 14,    -- host -> clientes: item destruido
    ITEM_STATE = 15,   -- host -> clientes: campos de estado do item (terra, agua, valor...)
    CARRY = 16,        -- host -> clientes: o que cada slot carrega
    TIME = 17,         -- host -> clientes: hora do dia
    SNAPSHOT_DONE = 18,-- host -> cliente: fim da lista inicial de itens
    TERRAIN_PATCH = 19,-- host -> clientes: valores de um cubo de voxels (edicao feita numa acao do cliente)
}

function P.terrain_patch(seq, p)
    return string.pack("<BI4s1i4i4i4B", P.T.TERRAIN_PATCH, seq, p.world, p.ox, p.oy, p.oz, p.n) .. p.values
end

-- Acoes de mundo do controlador. Pares: o indice menor do evento e "apertou", o maior "soltou".
P.ACTIONS = {
    { name = "Pickup", down = "InpActEvt_Pickup_K2Node_InputActionEvent_12", up = "InpActEvt_Pickup_K2Node_InputActionEvent_13" },
    { name = "LMB", down = "InpActEvt_LMB_K2Node_InputActionEvent_5", up = "InpActEvt_LMB_K2Node_InputActionEvent_6" },
    { name = "RMB", down = "InpActEvt_RMB_K2Node_InputActionEvent_7", up = "InpActEvt_RMB_K2Node_InputActionEvent_8" },
    { name = "Rotate", down = "InpActEvt_Rotate_K2Node_InputActionEvent_15" },
    { name = "Rotate2", down = "InpActEvt_Rotate2_K2Node_InputActionEvent_14" },
    { name = "Rotate3", down = "InpActEvt_Rotate3_K2Node_InputActionEvent_10" },
    { name = "VehicleKey", down = "InpActEvt_VehicleKey_K2Node_InputActionEvent_11" },
    { name = "RotationMod", down = "InpActEvt_RotationMod_K2Node_InputActionEvent_2", up = "InpActEvt_RotationMod_K2Node_InputActionEvent_3" },
    { name = "BuildPlaceCloser", down = "InpActEvt_BuildPlaceCloser_K2Node_InputActionEvent_1" },
    { name = "BuildPlaceFurther", down = "InpActEvt_BuildPlaceFurther_K2Node_InputActionEvent_0" },
}
P.ACTION_INDEX = {}
for i, a in ipairs(P.ACTIONS) do P.ACTION_INDEX[a.name] = i end

-- look: o que o cliente estava olhando (a deteccao de mira roda no cliente): kind 0 nada,
-- 1 item (id de rede), 2 objeto do mapa (caminho completo, igual nos dois mundos).
function P.input(action_index, pressed, key_name, look_kind, look_id, look_path)
    return string.pack("<BBBs1BI4s2", P.T.INPUT, action_index, pressed and 1 or 0, key_name or "None",
        look_kind or 0, look_id or 0, look_path or "")
end

local XF = "<ffffff"
function P.item_new(id, fname, class_path, x, y, z, pitch, yaw, roll)
    return string.pack("<BI4s1s2", P.T.ITEM_NEW, id, fname, class_path) .. string.pack(XF, x, y, z, pitch, yaw, roll)
end
-- list: {id, x, y, z, pitch, yaw, roll}; no maximo 40 por mensagem (cabe num datagrama)
function P.item_xform(list)
    local parts = { string.pack("<BB", P.T.ITEM_XFORM, #list) }
    for _, e in ipairs(list) do parts[#parts + 1] = string.pack("<I4", e[1]) .. string.pack(XF, e[2], e[3], e[4], e[5], e[6], e[7]) end
    return table.concat(parts)
end
function P.item_gone(id) return string.pack("<BI4", P.T.ITEM_GONE, id) end
function P.item_state(id, state) return string.pack("<BI4s2", P.T.ITEM_STATE, id, state) end
function P.carry(slot, id) return string.pack("<BBI4", P.T.CARRY, slot, id or 0) end
function P.time(hour, paused) return string.pack("<BfB", P.T.TIME, hour, paused and 1 or 0) end
function P.snapshot_done(count) return string.pack("<BI4", P.T.SNAPSHOT_DONE, count) end

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
        elseif t == P.T.INPUT then
            local a, pressed, key, lk, lid, lpath = string.unpack("<BBs1BI4s2", s, 2)
            return { action = a, pressed = pressed == 1, key = key, look_kind = lk, look_id = lid, look_path = lpath }
        elseif t == P.T.ITEM_NEW then
            local id, fname, cp, i = string.unpack("<I4s1s2", s, 2)
            local x, y, z, pitch, yaw, roll = string.unpack(XF, s, i)
            return { id = id, fname = fname, class_path = cp, x = x, y = y, z = z, pitch = pitch, yaw = yaw, roll = roll }
        elseif t == P.T.ITEM_XFORM then
            local n, i = string.unpack("<B", s, 2)
            local list = {}
            for k = 1, n do
                local id
                id, i = string.unpack("<I4", s, i)
                local x, y, z, pitch, yaw, roll
                x, y, z, pitch, yaw, roll, i = string.unpack(XF, s, i)
                list[k] = { id, x, y, z, pitch, yaw, roll }
            end
            return { list = list }
        elseif t == P.T.ITEM_GONE then
            return { id = (string.unpack("<I4", s, 2)) }
        elseif t == P.T.ITEM_STATE then
            local id, st = string.unpack("<I4s2", s, 2)
            return { id = id, state = st }
        elseif t == P.T.CARRY then
            local slot, id = string.unpack("<BI4", s, 2)
            return { slot = slot, id = id }
        elseif t == P.T.TIME then
            local hour, paused = string.unpack("<fB", s, 2)
            return { hour = hour, paused = paused == 1 }
        elseif t == P.T.SNAPSHOT_DONE then
            return { count = (string.unpack("<I4", s, 2)) }
        elseif t == P.T.TERRAIN_PATCH then
            local seq, world, ox, oy, oz, n, i = string.unpack("<I4s1i4i4i4B", s, 2)
            return { seq = seq, patch = { world = world, ox = ox, oy = oy, oz = oz, n = n, values = s:sub(i, i + n * n * n - 1) } }
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
