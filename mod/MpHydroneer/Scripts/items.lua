-- items.lua: itens do mundo, com o host como dono.
--
-- Host: cada item (BP_ParentItem_C) recebe um id de rede. O host manda a lista inicial ao cliente
-- que acabou de carregar o mundo, e depois so o que muda: itens novos, posicoes de itens que se
-- moveram, campos de estado (terra na pa, agua no balde, valor da moeda...), itens destruidos e
-- o que cada jogador carrega.
-- Cliente: associa cada id ao item local de mesmo nome (os dois carregaram o mesmo save); sem par,
-- cria uma copia da mesma classe. Itens do cliente nao simulam fisica: seguem o host.
-- Base: hydroneer-coopnet (MIT, Zane11332): varredura quente + lenta, campos de estado por reflexao.
local U = require("util")
local P = require("proto")

local IT = {}

IT.stats = { registered = 0, runtime = 0, xform_sent = 0, state_sent = 0, gone_sent = 0,
             paired = 0, spawned = 0, spawn_fail = 0, xform_applied = 0, state_applied = 0,
             destroyed = 0, extras_removed = 0, carry_mirror = 0, unknown_id = 0 }

local ITEM_CLASS_PATH = "/Game/WorldObj/Items/BP_ParentItem.BP_ParentItem_C"

local function short(o) return o:GetFName():ToString() end

-- Um ator destruido continua IsValid por um tempo; o componente raiz nao.
local function alive(it)
    if not U.valid(it) then return false end
    local ok = false
    pcall(function() local r = it:K2_GetRootComponent(); ok = r and r:IsValid() or false end)
    return ok
end
IT.alive = alive

local function class_path(it)
    local s = it:GetClass():GetFullName()
    return s:match("^%S+%s+(.+)$") or s
end

local function xform_of(it)
    local l, r = it:K2_GetActorLocation(), it:K2_GetActorRotation()
    return l.X, l.Y, l.Z, r.Pitch, r.Yaw, r.Roll
end

local function set_xform(it, x, y, z, pitch, yaw, roll)
    local l, r = U.vec(x, y, z), { Pitch = pitch, Yaw = yaw, Roll = roll }
    local ok = pcall(function() it:K2_SetActorLocationAndRotation(l, r, false, {}, true) end)
    if not ok then pcall(function() it:K2_TeleportTo(l, r) end) end
end

local function freeze(it)
    pcall(function()
        local root = it:K2_GetRootComponent()
        if root:IsSimulatingPhysics() then root:SetSimulatePhysics(false) end
    end)
end

-- ---------------------------------------------------------------- campos de estado por reflexao
local state_props = {}
local STATE_SKIP = { "time", "timer", "delta", "speed", "alpha", "rate", "velocity", "distance", "angle",
                     "carr", "hover", "look", "highlight", "pick", "proxy", "physic", "simulat", "outline",
                     "conveyorcount", "inwater", "inliquid" }

local function state_list(it)
    local cls = it:GetClass()
    local k = cls:GetFullName()
    if state_props[k] then return state_props[k] end
    local list, names = {}, {}
    local c, depth = cls, 0
    while c and depth < 8 do
        local cname = ""
        pcall(function() cname = c:GetFName():ToString() end)
        if cname == "" or cname == "Actor" then break end
        pcall(function()
            c:ForEachProperty(function(prop)
                local pn = prop:GetFName():ToString()
                if names[pn] then return end
                local low = pn:lower()
                for _, sk in ipairs(STATE_SKIP) do if low:find(sk, 1, true) then return end end
                local pt = prop:GetClass():GetFName():ToString()
                local kind
                if pt == "IntProperty" or pt == "ByteProperty" or pt == "EnumProperty" then kind = "n"
                elseif pt == "BoolProperty" then kind = "b"
                elseif pt == "FloatProperty" then kind = "f"
                elseif pt == "ObjectProperty" and (pn:find("Mesh", 1, true) or pn == "Dirt") then
                    local vc = ""
                    pcall(function()
                        local v = it[pn]
                        if v and v:IsValid() then vc = v:GetClass():GetFName():ToString() end
                    end)
                    if vc:find("MeshComponent", 1, true) then kind = "m" end
                end
                if kind then names[pn] = true; list[#list + 1] = { pn, kind } end
            end)
        end)
        if cname == "BP_ParentItem_C" then break end
        local sup
        pcall(function() sup = c:GetSuperStruct() end)
        c, depth = sup, depth + 1
    end
    state_props[k] = list
    return list
end

-- "nome=valor;..." (m: v1 visivel / v0 escondido)
local function item_state(it)
    local parts = {}
    for _, e in ipairs(state_list(it)) do
        local v
        pcall(function()
            local x = it[e[1]]
            if e[2] == "m" then
                if x and x:IsValid() then v = x:IsVisible() and "v1" or "v0" end
            elseif e[2] == "b" then v = x and "t" or "f"
            elseif e[2] == "f" then v = string.format("%.1f", x)
            else v = tostring(math.floor(x)) end
        end)
        if v then parts[#parts + 1] = e[1] .. "=" .. v end
    end
    return table.concat(parts, ";")
end

local function apply_state(it, st)
    local kinds = {}
    for _, e in ipairs(state_list(it)) do kinds[e[1]] = e[2] end
    local n = 0
    for k, v in st:gmatch("([^;=]+)=([^;]+)") do
        local kind = kinds[k]
        if kind then
            pcall(function()
                if kind == "m" then
                    local comp, want = it[k], v == "v1"
                    if comp and comp:IsValid() and comp:IsVisible() ~= want then comp:SetVisibility(want, false); n = n + 1 end
                elseif kind == "b" then
                    local want = v == "t"
                    if it[k] ~= want then it[k] = want; n = n + 1 end
                elseif kind == "f" then
                    local want = tonumber(v)
                    if math.abs((it[k] or 0) - want) > 0.05 then it[k] = want; n = n + 1 end
                else
                    local want = tonumber(v)
                    if math.floor(it[k]) ~= want then it[k] = want; n = n + 1 end
                end
            end)
        end
    end
    -- moedas: o numero na moeda acompanha o valor
    if n > 0 and st:find("Amount=", 1, true) then pcall(function() it:InitAmount(it.Amount, false) end) end
    return n
end

-- ================================================================ host
local H = {
    started = false, next_id = 1,
    by_name = {},        -- [fname] = entry {id, it, name, cp, last, state, hot, moved}
    by_id = {},
    all = {},            -- lista para a varredura lenta
    cursor = 1,
    pending_new = {},    -- itens novos, registrados depois de alguns ticks (o jogo termina de montar)
    proxies = {},
    tick = 0,
    carry = {},          -- [slot] = id carregado por ultimo anunciado
    last_full = 0, last_carry_full = 0,
}
IT.host = H

-- broadcast(bytes, reliable): para todos os clientes ativos; definido pela sessao
IT.broadcast = function() end

local function note_proxy_of(it)
    pcall(function()
        local px = it.ProxyItem
        if px and px:IsValid() then H.proxies[short(px)] = true end
    end)
end

local function register(it, runtime)
    local name = short(it)
    if H.by_name[name] or H.proxies[name] then return nil end
    local e = { id = H.next_id, it = it, name = name, cp = class_path(it) }
    H.next_id = H.next_id + 1
    H.by_name[name], H.by_id[e.id] = e, e
    H.all[#H.all + 1] = e
    note_proxy_of(it)
    local ok, x, y, z, p, yw, r = pcall(xform_of, it)
    if ok then e.last = { x, y, z, p, yw } end
    local oks, st = pcall(item_state, it)
    e.state = oks and st or ""
    IT.stats.registered = IT.stats.registered + 1
    if runtime then IT.stats.runtime = IT.stats.runtime + 1 end
    return e
end

function IT.host_start()
    if H.started then return end
    H.started = true
    for _, it in ipairs(FindAllOf("BP_ParentItem_C") or {}) do
        if alive(it) then note_proxy_of(it) end
    end
    for _, it in ipairs(FindAllOf("BP_ParentItem_C") or {}) do
        if alive(it) then register(it, false) end
    end
    pcall(function()
        NotifyOnNewObject(ITEM_CLASS_PATH, function(obj)
            H.pending_new[#H.pending_new + 1] = { it = obj, t = H.tick }
        end)
    end)
    U.log(("itens: host registrou %d itens"):format(#H.all))
end

function IT.id_of(it)
    if not U.valid(it) then return 0 end
    local e = H.by_name[short(it)]
    return e and e.id or 0
end

local function new_msg(e)
    local ok, x, y, z, p, yw, r = pcall(xform_of, e.it)
    if not ok then x, y, z, p, yw, r = 0, 0, 0, 0, 0, 0 end
    return P.item_new(e.id, e.name, e.cp, x, y, z, p, yw, r)
end

-- Lista completa para um cliente que acabou de carregar o mundo.
function IT.host_snapshot(send_to)
    local n = 0
    for _, e in ipairs(H.all) do
        if alive(e.it) then
            send_to(new_msg(e), true)
            if e.state and e.state ~= "" then send_to(P.item_state(e.id, e.state), true) end
            n = n + 1
        end
    end
    send_to(P.snapshot_done(n), true)
    return n
end

local batch = {}
local function flush()
    if #batch == 0 then return end
    IT.broadcast(P.item_xform(batch), false)
    IT.stats.xform_sent = IT.stats.xform_sent + #batch
    batch = {}
end

local function queue_xform(e, x, y, z, p, yw, r)
    batch[#batch + 1] = { e.id, x, y, z, p, yw, r }
    if #batch >= 40 then flush() end
end

local function check(e, force)
    if not alive(e.it) then return "gone" end
    if H.proxies[e.name] then return "proxy" end
    local carried = false
    pcall(function() local by = e.it.BeingCarriedBy; carried = by and by:IsValid() or false end)
    note_proxy_of(e.it)
    local ok, x, y, z, p, yw, r = pcall(xform_of, e.it)
    if not ok then return "err" end
    local l = e.last
    local moved = (not l) or math.abs(l[1] - x) + math.abs(l[2] - y) + math.abs(l[3] - z) > 2
        or math.abs(l[4] - p) > 2 or math.abs(l[5] - yw) > 2
    if moved or force then
        e.last = { x, y, z, p, yw }
        queue_xform(e, x, y, z, p, yw, r)
        if moved then e.moved = true end
    end
    -- estado: o item carregado mostra o estado na copia segurada na mao, se houver
    local okst, st = pcall(item_state, e.it)
    if okst then
        pcall(function()
            local px, by = e.it.ProxyItem, e.it.BeingCarriedBy
            if px and px:IsValid() and by and by:IsValid() then st = item_state(px) end
        end)
        if st ~= e.state then
            e.state = st
            IT.broadcast(P.item_state(e.id, st), true)
            IT.stats.state_sent = IT.stats.state_sent + 1
        end
    end
    if moved or carried then e.hot = 0 elseif e.hot then e.hot = e.hot + 1; if e.hot > 60 then e.hot = nil end end
    return moved and "moved" or "still"
end

local function remove(e)
    if e.gone then return end
    e.gone = true
    H.by_name[e.name] = nil
    IT.broadcast(P.item_gone(e.id), true)
    IT.stats.gone_sent = IT.stats.gone_sent + 1
end

-- carried_by_slot: function() -> { [slot] = controller }, da sessao
function IT.host_tick(controllers_by_slot)
    if not H.started then return end
    H.tick = H.tick + 1
    -- itens novos: registrados ~10 ticks depois de criados
    for i = #H.pending_new, 1, -1 do
        local p = H.pending_new[i]
        if H.tick - p.t >= 10 then
            table.remove(H.pending_new, i)
            if alive(p.it) then
                for _, e in pairs(H.by_name) do note_proxy_of(e.it) end
                local e = register(p.it, true)
                if e then IT.broadcast(new_msg(e), true) end
            end
        end
    end
    -- itens quentes (moveram ou estao carregados) a cada tick
    for _, e in ipairs(H.all) do
        if e.hot and not e.gone then
            if check(e, false) == "gone" then remove(e) end
        end
    end
    -- varredura lenta: 8 itens por tick
    for _ = 1, math.min(8, #H.all) do
        if H.cursor > #H.all then H.cursor = 1 end
        local e = H.all[H.cursor]
        if e and not e.gone then
            local r = check(e, false)
            if r == "gone" then remove(e) end
            H.cursor = H.cursor + 1
        else
            table.remove(H.all, H.cursor)
        end
    end
    -- reenvio lento de tudo que ja se moveu, para corrigir copias que derivaram no cliente
    local t = os.clock()
    if t - H.last_full > 5 then
        H.last_full = t
        for _, e in ipairs(H.all) do
            if e.moved and not e.gone and alive(e.it) then
                local ok, x, y, z, p, yw, r = pcall(xform_of, e.it)
                if ok then queue_xform(e, x, y, z, p, yw, r) end
            end
        end
    end
    flush()
    -- o que cada slot carrega
    local full = t - H.last_carry_full > 3
    if full then H.last_carry_full = t end
    for slot, pc in pairs(controllers_by_slot()) do
        local id = 0
        pcall(function() id = IT.id_of(pc.CarryingItem) end)
        if id ~= H.carry[slot] or full then
            H.carry[slot] = id
            IT.broadcast(P.carry(slot, id), true)
        end
    end
end

function IT.host_reset()
    H.carry = {}
end

-- ================================================================ cliente
local C = {
    by_id = {},          -- [id] = ator local
    id_by_name = {},     -- [fname local] = id
    names = nil,         -- [fname] = ator local (reconstruido sob demanda)
    names_t = -1e9,
    claimed = {},        -- nomes locais ja associados
    my_carry = 0,        -- id que o host diz que eu carrego
    last_carry_try = -1e9,
    snapshot = false,
}
IT.client = C
IT.my_slot = function() return nil end

local function rebuild_names()
    C.names = {}
    for _, it in ipairs(FindAllOf("BP_ParentItem_C") or {}) do C.names[short(it)] = it end
    C.names_t = os.clock()
end

local function local_carried()
    local pc = U.local_controller()
    local it
    pcall(function() it = pc.CarryingItem end)
    if alive(it) then return it end
    return nil
end

local function spawn_copy(m)
    local cls = StaticFindObject(m.class_path)
    if not U.valid(cls) then
        pcall(function() LoadAsset(m.class_path:match("^(.-)%.[^%.]+$") or m.class_path) end)
        cls = StaticFindObject(m.class_path)
    end
    local pawn = U.local_pawn()
    if not (U.valid(cls) and pawn) then IT.stats.spawn_fail = IT.stats.spawn_fail + 1; return nil end
    local actor
    local ok = pcall(function()
        actor = pawn:GetWorld():SpawnActor(cls, U.vec(m.x, m.y, m.z), { Pitch = m.pitch, Yaw = m.yaw, Roll = m.roll })
    end)
    if not (ok and alive(actor)) then IT.stats.spawn_fail = IT.stats.spawn_fail + 1; return nil end
    IT.stats.spawned = IT.stats.spawned + 1
    return actor
end

local function client_new(m)
    if C.by_id[m.id] and alive(C.by_id[m.id]) then return end
    if not C.names or os.clock() - C.names_t > 2 then rebuild_names() end
    local it = C.names[m.fname]
    if not alive(it) then rebuild_names(); it = C.names[m.fname] end
    if not (alive(it) and not C.claimed[m.fname]) then
        -- sem par pelo nome: o jogo recria alguns itens ao carregar com outro nome, na mesma
        -- classe e posicao (furadeira e colheitadeira da loja inicial). Procura assim.
        it = nil
        local cls = m.class_path:match("%.([%w_]+)$")
        local best, bd
        for _, cand in ipairs((cls and FindAllOf(cls)) or {}) do
            local n = short(cand)
            if alive(cand) and not C.claimed[n] and not C.id_by_name[n] then
                local ok, x, y, z = pcall(xform_of, cand)
                if ok then
                    local d = (x - m.x) ^ 2 + (y - m.y) ^ 2 + (z - m.z) ^ 2
                    if d < 50 * 50 and (not bd or d < bd) then best, bd = cand, d end
                end
            end
        end
        if best then it = best; IT.stats.paired_by_place = (IT.stats.paired_by_place or 0) + 1 end
    end
    if alive(it) and not C.claimed[short(it)] then
        C.claimed[short(it)] = true
        IT.stats.paired = IT.stats.paired + 1
    else
        it = spawn_copy(m)
        if it then C.claimed[short(it)] = true end
        if C.snapshot then
            U.log(("itens: novo item do host %d %s -> %s"):format(m.id, m.fname, it and short(it) or "FALHOU"))
        end
    end
    if it then
        C.by_id[m.id] = it
        C.id_by_name[short(it)] = m.id
        freeze(it)
        set_xform(it, m.x, m.y, m.z, m.pitch, m.yaw, m.roll)
    end
end

-- cliente: id de rede de um ator local (0 se nao for item do host)
function IT.client_id_of(actor)
    if not U.valid(actor) then return 0 end
    return C.id_by_name[short(actor)] or 0
end

-- host: ator do item com esse id
function IT.host_item(id)
    local e = H.by_id[id]
    if e and not e.gone and alive(e.it) then return e.it end
    return nil
end

-- Depois da lista inicial: itens locais com nome do jogo que o host nao tem nao existem no mundo dele.
local function remove_extras()
    rebuild_names()
    local mine = local_carried()
    local n = 0
    for name, it in pairs(C.names) do
        if not C.claimed[name] and name:match("_C_%d+$") and it ~= mine and alive(it) then
            local is_proxy = false
            pcall(function() local by = it.BeingCarriedBy; is_proxy = by and by:IsValid() end)
            if not is_proxy then pcall(function() it:K2_DestroyActor() end); n = n + 1 end
        end
    end
    IT.stats.extras_removed = IT.stats.extras_removed + n
    return n
end

function IT.client_handle(m)
    local T = P.T
    if m.t == T.ITEM_NEW then
        client_new(m)
    elseif m.t == T.ITEM_XFORM then
        local mine = local_carried()
        for _, e in ipairs(m.list) do
            local it = C.by_id[e[1]]
            if alive(it) then
                if it ~= mine and e[1] ~= C.my_carry then
                    freeze(it)
                    set_xform(it, e[2], e[3], e[4], e[5], e[6], e[7])
                    IT.stats.xform_applied = IT.stats.xform_applied + 1
                end
            else
                IT.stats.unknown_id = IT.stats.unknown_id + 1
            end
        end
    elseif m.t == T.ITEM_STATE then
        local it = C.by_id[m.id]
        if alive(it) then
            -- o item carregado mostra o estado na copia da mao
            local target = it
            pcall(function() local px = it.ProxyItem; if px and px:IsValid() then target = px end end)
            local n = apply_state(target, m.state)
            if target ~= it then apply_state(it, m.state) end
            if n > 0 then IT.stats.state_applied = IT.stats.state_applied + 1 end
            local amount = m.state:match("Amount=(%d+)")
            if amount and C.snapshot then U.log(("itens: moeda %d agora vale %s"):format(m.id, amount)) end
        end
    elseif m.t == T.ITEM_GONE then
        local it = C.by_id[m.id]
        C.by_id[m.id] = nil
        if alive(it) then pcall(function() it:K2_DestroyActor() end); IT.stats.destroyed = IT.stats.destroyed + 1 end
    elseif m.t == T.SNAPSHOT_DONE then
        C.snapshot = true
        local n = remove_extras()
        local mapped = 0
        for _ in pairs(C.by_id) do mapped = mapped + 1 end
        U.log(("itens: lista inicial do host com %d itens; associados %d, copias %d, falhas %d, extras locais removidos %d"):format(
            m.count, IT.stats.paired, IT.stats.spawned, IT.stats.spawn_fail, n))
    elseif m.t == T.CARRY then
        if m.slot == IT.my_slot() then C.my_carry = m.id end
    end
end

-- Espelha o que o host diz que este jogador carrega, com a logica do proprio jogo.
-- Chamadas daqui rodam sob a trava de reentrancia (D19).
function IT.client_tick()
    if not C.snapshot then return end
    local t = os.clock()
    if t - C.last_carry_try < 0.4 then return end
    local pc = U.local_controller()
    if not pc then return end
    local mine = local_carried()
    local want = C.by_id[C.my_carry]
    if C.my_carry ~= 0 and alive(want) and mine ~= want then
        C.last_carry_try = t
        pcall(function() pc:PickUpItem(want) end)
        IT.stats.carry_mirror = IT.stats.carry_mirror + 1
    elseif C.my_carry == 0 and mine then
        C.last_carry_try = t
        pcall(function() pc:DropItem({}) end)
        freeze(mine)
        IT.stats.carry_mirror = IT.stats.carry_mirror + 1
    end
end

function IT.client_reset()
    C.by_id, C.id_by_name, C.names, C.claimed, C.my_carry, C.snapshot = {}, {}, nil, {}, 0, false
end

return IT
