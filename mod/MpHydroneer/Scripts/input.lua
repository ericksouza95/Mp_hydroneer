-- input.lua: acoes de mundo do cliente executadas pelo host.
--
-- Cliente: as acoes que mudam o mundo (pegar, clicar, girar...) sao tiradas dos atalhos do jogo,
-- para o jogo do cliente nao executa-las sozinho. O mod le as teclas reais do jogador e manda
-- "apertou/soltou" ao host. Movimento, pulo, agachar e correr continuam locais.
-- Host: executa a acao no controlador oculto do cliente, cuja mira ja segue a do cliente.
-- Base: hydroneer-coopnet (MIT, Zane11332), reescrito para o protocolo binario.
local U = require("util")
local P = require("proto")

local I = {}

I.stats = { sent = 0, replayed = 0, replay_fail = 0, look_item = 0, look_path = 0, look_missing = 0 }
I.on_send = nil                 -- function(bytes) definida pela sessao (cliente -> host)
I.item_id_of = function(actor) return 0 end         -- cliente: id de rede de um item local (items.lua)
I.item_by_id = function(id) return nil end          -- host: ator do item com esse id (items.lua)

local function full_path(o)
    local s = o:GetFullName()
    return s:match("^%S+%s+(.+)$") or s
end

-- O que o controlador local esta olhando agora, para mandar junto com a acao.
local function current_look()
    local pc = U.local_controller()
    local a
    pcall(function() a = pc.LastThingLookingAt end)
    if not U.valid(a) then return 0, 0, "" end
    local id = I.item_id_of(a)
    if id and id ~= 0 then return 1, id, "" end
    local ok, path = pcall(full_path, a)
    if ok and path then return 2, 0, path end
    return 0, 0, ""
end

local is_settings
local removed = nil             -- copias dos atalhos removidos, para restaurar
local keys_by_action = {}       -- [indice da acao] = { "E", "Gamepad_FaceButton_Left", ... }
local down = {}                 -- [tecla] = true enquanto apertada

local function settings()
    if not U.valid(is_settings) then is_settings = StaticFindObject("/Script/Engine.Default__InputSettings") end
    return is_settings
end

local function key(name) return { KeyName = FName(name) } end

-- ---------------------------------------------------------------- cliente
function I.client_enable()
    if removed then return end
    local is = settings()
    local list = {}
    is.ActionMappings:ForEach(function(_, e)
        local m = e:get()
        local a = m.ActionName:ToString()
        local idx = P.ACTION_INDEX[a]
        local k = m.Key.KeyName:ToString()
        if idx and k ~= "None" then
            list[#list + 1] = { a = a, k = k, s = m.bShift and true or false, c = m.bCtrl and true or false,
                                al = m.bAlt and true or false, cm = m.bCmd and true or false }
            keys_by_action[idx] = keys_by_action[idx] or {}
            table.insert(keys_by_action[idx], k)
        end
    end)
    for _, m in ipairs(list) do
        pcall(function()
            is:RemoveActionMapping({ ActionName = FName(m.a), bShift = m.s, bCtrl = m.c, bAlt = m.al, bCmd = m.cm, Key = key(m.k) }, false)
        end)
    end
    pcall(function() is:ForceRebuildKeymaps() end)
    removed = list
    U.log(("input: %d atalhos de acoes de mundo removidos; as teclas vao para o host"):format(#list))
end

function I.client_disable()
    if not removed then return end
    local is = settings()
    for _, m in ipairs(removed) do
        pcall(function()
            is:AddActionMapping({ ActionName = FName(m.a), bShift = m.s, bCtrl = m.c, bAlt = m.al, bCmd = m.cm, Key = key(m.k) }, false)
        end)
    end
    pcall(function() is:ForceRebuildKeymaps() end)
    U.log(("input: %d atalhos restaurados"):format(#removed))
    removed, keys_by_action, down = nil, {}, {}
end

function I.client_active() return removed ~= nil end

-- Le as teclas a cada tick e manda as bordas.
function I.client_tick()
    if not removed then return end
    local pc = U.local_controller()
    if not pc then return end
    for idx, keys in pairs(keys_by_action) do
        for _, k in ipairs(keys) do
            local now = false
            pcall(function() now = pc:IsInputKeyDown(key(k)) end)
            if now ~= (down[k] or false) then
                down[k] = now
                local a = P.ACTIONS[idx]
                if now or a.up then
                    local lk, lid, lpath = current_look()
                    if I.on_send then I.on_send(P.input(idx, now, k, lk, lid, lpath)) end
                    I.stats.sent = I.stats.sent + 1
                end
                -- so cosmetico: a animacao de uso do item na mao toca na hora; o efeito vem do host
                if now and U.cfg.local_anim ~= "0" and (a.name == "LMB" or a.name == "RMB") then
                    pcall(function()
                        local it = pc.CarryingItem
                        if it and it:IsValid() then
                            if a.name == "LMB" then it:PlayPrimaryUseAnim() else it:PlaySecondaryUseAnim() end
                        end
                    end)
                end
            end
        end
    end
end

-- Para os robos de teste: manda uma acao como se a tecla fosse apertada.
function I.client_tap(action_name, pressed)
    local idx = P.ACTION_INDEX[action_name]
    if idx and I.on_send then
        local lk, lid, lpath = current_look()
        I.on_send(P.input(idx, pressed, "None", lk, lid, lpath))
        I.stats.sent = I.stats.sent + 1
    end
end

-- ---------------------------------------------------------------- host
-- `controller` e o controlador oculto do slot. A chamada e feita sob a trava de reentrancia
-- (D19): hooks com leitura de parametros nao podem rodar dentro dela.
function I.host_replay(controller, m)
    local a = P.ACTIONS[m.action]
    if not a or not U.valid(controller) then return end
    local fn = m.pressed and a.down or a.up
    if not fn then return end
    local k = (m.key and m.key ~= "None") and m.key or "None"
    -- o alvo que o cliente via: o controlador oculto passa a "olhar" para ele antes de agir
    local target
    if m.look_kind == 1 then target = I.item_by_id(m.look_id)
    elseif m.look_kind == 2 and m.look_path ~= "" then
        pcall(function() target = StaticFindObject(m.look_path) end)
    end
    if m.look_kind ~= 0 then
        if U.valid(target) then
            pcall(function() controller.LastThingLookingAt = target end)
            if m.look_kind == 1 then I.stats.look_item = I.stats.look_item + 1 else I.stats.look_path = I.stats.look_path + 1 end
        else
            I.stats.look_missing = I.stats.look_missing + 1
        end
    end
    local ok, err = pcall(function() controller[fn](controller, key(k)) end)
    if ok then I.stats.replayed = I.stats.replayed + 1 else
        I.stats.replay_fail = I.stats.replay_fail + 1
        U.log(("input: falha ao executar %s: %s"):format(fn, tostring(err)))
    end
end

return I
