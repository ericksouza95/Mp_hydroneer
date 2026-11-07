-- terrain.lua: escavacoes compartilhadas.
--
-- Toda escavacao do jogo termina numa chamada do VoxelSphereTools (pa: RemoveSphere; despejar:
-- AddSphere). Um hook captura cada chamada local e entrega ao modulo de sessao. Edicoes recebidas
-- sao aplicadas com a mesma chamada, no mesmo VoxelWorld, com uma trava para o hook nao reenviar.
local U = require("util")

local T = {}

T.on_local_edit = nil          -- function(edit) definida pela sessao
T.stats = { captured = 0, applied = 0, failed = 0, hooks = 0, entries = 0, entries_applying = 0 }
local TRACE = U.cfg.trace_hooks == "1"
local function step(s) if TRACE then U.log("hook: " .. s) end end

local applying = false
local tools
local worlds = {}

local function arg(p)
    local v
    pcall(function() v = p:get() end)
    return v
end

-- layout: posicao do VoxelWorld na lista de argumentos e o tipo do argumento extra.
-- As variantes Async tem WorldContextObject e LatentInfo antes; do outro lado a edicao e
-- aplicada com a variante sincrona equivalente.
local HOOKS = {
    AddSphere = { 3, nil }, RemoveSphere = { 3, nil },
    SetValueSphere = { 3, "value" }, RemoveSphereWithDurability = { 3, "interval" },
    AddSphereAsync = { 5, nil }, RemoveSphereAsync = { 5, nil },
    SetValueSphereAsync = { 5, "value" }, RemoveSphereWithDurabilityAsync = { 5, "interval" },
}

-- Marcador contra crash: gravado antes de ler os parametros do hook e apagado depois.
-- Se o jogo fechar no meio da leitura, o proximo inicio acha o marcador e desliga os hooks.
local MARKER = U.MOD_DIR .. "hook-terreno.marcador"
local function marker_set(on)
    if on then local f = io.open(MARKER, "wb"); if f then f:write(os.date()); f:close() end
    else os.remove(MARKER) end
end

function T.install_hooks()
    local prev = io.open(MARKER, "rb")
    if prev then
        prev:close()
        os.remove(MARKER)
        U.log("AVISO: a ultima sessao fechou durante o hook de terreno. Sincronizacao de terreno DESLIGADA nesta sessao.")
        T.disabled = true
        return
    end
    for fn, layout in pairs(HOOKS) do
        local ok, err = pcall(function()
            RegisterHook("/Script/Voxel.VoxelSphereTools:" .. fn, function(self, ...)
                T.stats.entries = T.stats.entries + 1
                if applying then T.stats.entries_applying = T.stats.entries_applying + 1; return end
                step(fn .. " entrou, " .. select("#", ...) .. " args")
                local a = { ... }
                marker_set(true)
                local ok2, err2 = pcall(function()
                    local w = layout[1]
                    step("lendo mundo")
                    local wobj = arg(a[w])
                    step("mundo lido: " .. type(wobj))
                    local world = wobj:GetFName():ToString()
                    step("mundo " .. world .. ", lendo posicao")
                    local pos = arg(a[w + 1])
                    step("posicao lida, lendo raio")
                    local radius = arg(a[w + 2])
                    step("raio " .. tostring(radius))
                    local ea, eb, b0 = 0, 0, w + 3
                    if layout[2] == "value" then ea = arg(a[w + 3]); b0 = w + 4
                    elseif layout[2] == "interval" then local iv = arg(a[w + 3]); ea, eb = iv.Min, iv.Max; b0 = w + 4 end
                    local flags = 0
                    for i = 0, 3 do if arg(a[b0 + i]) then flags = flags | (1 << i) end end
                    T.stats.captured = T.stats.captured + 1
                    marker_set(false)
                    if T.on_local_edit then
                        local base = fn:gsub("Async$", "")
                        T.on_local_edit({ fn = base, world = world, x = pos.X, y = pos.Y, z = pos.Z, radius = radius, a = ea, b = eb, flags = flags })
                    end
                end)
                marker_set(false)
                if not ok2 then U.log("ERRO no hook de terreno " .. fn .. ": " .. tostring(err2)) end
            end)
        end)
        if ok then T.stats.hooks = T.stats.hooks + 1 else U.log("hook de terreno " .. fn .. " nao instalado: " .. tostring(err)) end
    end
    U.log(("terreno: %d de 8 hooks instalados"):format(T.stats.hooks))
end

local function find_world(name)
    local w = worlds[name]
    if U.valid(w) then return w end
    for _, v in ipairs(FindAllOf("VoxelWorld") or {}) do
        if v:GetFName():ToString() == name then worlds[name] = v; return v end
    end
    return nil
end

function T.apply(e)
    if not U.valid(tools) then tools = StaticFindObject("/Script/Voxel.Default__VoxelSphereTools") end
    local w = find_world(e.world)
    if not (U.valid(tools) and w) then
        T.stats.failed = T.stats.failed + 1
        U.log("terreno: nao aplicado, mundo " .. tostring(e.world) .. (w and "" or " nao encontrado"))
        return false
    end
    local b = {}
    for i = 0, 3 do b[i + 1] = (e.flags & (1 << i)) ~= 0 end
    local pos = U.vec(e.x, e.y, e.z)
    applying = true
    local ok, err = pcall(function()
        if e.fn == "SetValueSphere" then
            tools:SetValueSphere({}, {}, w, pos, e.radius, e.a, b[1], b[2], b[3], b[4])
        elseif e.fn == "RemoveSphereWithDurability" then
            tools:RemoveSphereWithDurability({}, {}, w, pos, e.radius, { Min = math.floor(e.a), Max = math.floor(e.b) }, b[1], b[2], b[3], b[4])
        else
            tools[e.fn](tools, {}, {}, w, pos, e.radius, b[1], b[2], b[3], b[4])
        end
    end)
    applying = false
    if ok then T.stats.applied = T.stats.applied + 1 else
        T.stats.failed = T.stats.failed + 1
        U.log("terreno: falha ao aplicar " .. e.fn .. ": " .. tostring(err))
    end
    return ok
end

return T
