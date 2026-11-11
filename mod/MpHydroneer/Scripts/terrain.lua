-- terrain.lua: escavacoes compartilhadas.
--
-- Toda escavacao do jogo termina numa chamada do VoxelSphereTools (pa: RemoveSphere; despejar:
-- AddSphere). Um hook captura cada chamada local e entrega ao modulo de sessao. Edicoes recebidas
-- sao aplicadas com a mesma chamada, no mesmo VoxelWorld, com uma trava para o hook nao reenviar.
local U = require("util")

local T = {}

T.on_local_edit = nil          -- function(edit) definida pela sessao
T.stats = { captured = 0, applied = 0, failed = 0, hooks = 0, entries = 0, entries_applying = 0,
            skipped_not_host = 0, skipped_in_lua_call = 0 }
-- So o host captura edicoes, e so com a sala aberta (a sessao liga e desliga).
T.capture = false
-- Ligado pela sessao enquanto o Lua executa algo no jogo que pode chegar as funcoes de esfera
-- (acao do cliente, espelho de carregar). Ler parametros nesse caso derruba o jogo (D19).
T.in_lua_call = 0
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
                if not T.capture then T.stats.skipped_not_host = T.stats.skipped_not_host + 1; return end
                if T.in_lua_call > 0 then
                    T.stats.skipped_in_lua_call = T.stats.skipped_in_lua_call + 1
                    U.log("AVISO: edicao de terreno dentro de uma chamada do mod (" .. fn .. "); nao foi transmitida")
                    return
                end
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

-- ---------------------------------------------------------------- retalhos de terreno
-- Quando a edicao acontece dentro de uma chamada do mod (acao do cliente executada no host),
-- o hook nao pode ler os parametros. Em vez da chamada, copiamos o resultado: os valores dos
-- voxels de um cubo ao redor do ponto, lidos depois da acao.
local data_tools
local function dt()
    if not U.valid(data_tools) then data_tools = StaticFindObject("/Script/Voxel.Default__VoxelDataTools") end
    return data_tools
end

T.patch_stats = { read = 0, applied = 0, voxels_set = 0, read_us = 0, apply_us = 0, voxel_size = 0 }

-- Le um cubo de voxels ao redor de (x, y, z) com meio-lado `radius_cm`.
-- Devolve { world, ox, oy, oz, n, values } (values: n^3 bytes, valor * 127 com sinal) ou nil.
function T.read_patch(world_name, x, y, z, radius_cm, now_us)
    local w = U.voxel_world(world_name)
    if not w then return nil end
    local vs = 0
    pcall(function() vs = w.VoxelSize end)
    if not vs or vs <= 0 then vs = 25 end
    T.patch_stats.voxel_size = vs
    local okc, c = pcall(function() return w:K2_GlobalToLocalFloat(U.vec(x, y, z)) end)
    if not okc or not c then return nil end
    local h = math.ceil(radius_cm / vs) + 1
    local ox, oy, oz = math.floor(c.X + 0.5) - h, math.floor(c.Y + 0.5) - h, math.floor(c.Z + 0.5) - h
    local n = 2 * h + 1
    local t0 = now_us and now_us() or 0
    local tools = dt()
    local bytes = {}
    local out = {}
    for i = 0, n - 1 do
        for j = 0, n - 1 do
            for k = 0, n - 1 do
                local v = 1
                pcall(function()
                    tools:GetValue(out, w, { X = ox + i, Y = oy + j, Z = oz + k })
                    v = out.Value or 1
                end)
                local q = math.floor(math.max(-1, math.min(1, v)) * 127 + 0.5)
                bytes[#bytes + 1] = string.char(q & 0xFF)
            end
        end
    end
    if now_us then T.patch_stats.read_us = now_us() - t0 end
    T.patch_stats.read = T.patch_stats.read + 1
    return { world = world_name, ox = ox, oy = oy, oz = oz, n = n, values = table.concat(bytes) }
end

-- Grava no mundo local os voxels do retalho que estiverem diferentes.
function T.apply_patch(p, now_us)
    local w = U.voxel_world(p.world)
    if not w then T.stats.failed = T.stats.failed + 1; return false end
    local tools = dt()
    local t0 = now_us and now_us() or 0
    local out, idx, set = {}, 0, 0
    applying = true
    for i = 0, p.n - 1 do
        for j = 0, p.n - 1 do
            for k = 0, p.n - 1 do
                idx = idx + 1
                local q = p.values:byte(idx)
                if q > 127 then q = q - 256 end
                local want = q / 127
                local pos = { X = p.ox + i, Y = p.oy + j, Z = p.oz + k }
                pcall(function()
                    tools:GetValue(out, w, pos)
                    if math.abs((out.Value or 1) - want) > 0.02 then
                        tools:SetValue(w, pos, want)
                        set = set + 1
                    end
                end)
            end
        end
    end
    applying = false
    if now_us then T.patch_stats.apply_us = now_us() - t0 end
    T.patch_stats.applied = T.patch_stats.applied + 1
    T.patch_stats.voxels_set = T.patch_stats.voxels_set + set
    return true
end

-- Executa fn sob a trava de chamada do Lua (D19).
function T.guarded(fn, ...)
    T.in_lua_call = T.in_lua_call + 1
    local ok, a, b = pcall(fn, ...)
    T.in_lua_call = T.in_lua_call - 1
    return ok, a, b
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
