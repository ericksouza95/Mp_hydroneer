-- util.lua: log, configuracao e acesso ao jogo usados pelos outros modulos.
local U = {}

U.MOD_DIR = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/"):match("^(.*/)Scripts/") or "./"
U.DATA_DIR = (os.getenv("LOCALAPPDATA") or U.MOD_DIR):gsub("\\", "/") .. "/HydroneerMP/"
U.REPORT = U.DATA_DIR .. "relatorio.txt"

-- Configuracao opcional em <mod>/mp-config.txt, uma chave=valor por linha.
--   transport=steam|udp     role=host|client     addr=127.0.0.1:7777
--   newgame=1 (inicia jogo novo sozinho)   bot=walk|dig|none   report=<arquivo>
U.cfg = { transport = "steam", role = "", addr = "127.0.0.1:7777", newgame = "0", bot = "none" }
do
    local f = io.open(U.MOD_DIR .. "mp-config.txt", "rb")
    if f then
        for line in f:lines() do
            local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
            if k then U.cfg[k] = v end
        end
        f:close()
    end
    if U.cfg.report and U.cfg.report ~= "" then U.REPORT = U.cfg.report end
    local t = io.open(U.REPORT, "a")
    if t then t:close() else os.execute('mkdir "' .. U.DATA_DIR:gsub("/", "\\") .. '" 2>nul') end
end

function U.log(line)
    local f = io.open(U.REPORT, "a")
    if f then f:write(os.date("%Y-%m-%d %H:%M:%S ") .. tostring(line) .. "\n"); f:close() end
end

-- ---------------------------------------------------------------- jogo
local gs, ksl
function U.gameplay_statics()
    if not (gs and gs:IsValid()) then gs = StaticFindObject("/Script/Engine.Default__GameplayStatics") end
    return gs
end
function U.system_library()
    if not (ksl and ksl:IsValid()) then ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end
    return ksl
end

function U.valid(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v
end

function U.game_mode()
    local gm = FindFirstOf("GM_Hydroneer_C")
    return U.valid(gm) and gm or nil
end

function U.in_game()
    local gm = U.game_mode()
    if not gm then return false end
    local ok, v = pcall(function() return gm["InGame?"] end)
    return ok and v == true
end

-- O controlador do jogador desta maquina: o primeiro jogador local.
function U.local_controller()
    local gm = U.game_mode()
    if not gm then return nil end
    local ok, pc = pcall(function() return U.gameplay_statics():GetPlayerController(gm, 0) end)
    if ok and U.valid(pc) then return pc end
    return nil
end

function U.local_pawn()
    local pc = U.local_controller()
    if not pc then return nil end
    local ok, p = pcall(function() return pc.Pawn end)
    if ok and U.valid(p) then return p end
    return nil
end

function U.vec(x, y, z) return { X = x, Y = y, Z = z } end

function U.location(actor)
    local v = actor:K2_GetActorLocation()
    return v.X, v.Y, v.Z
end

function U.delta_seconds()
    local gm = U.game_mode()
    if not gm then return 1 / 60 end
    local ok, d = pcall(function() return U.gameplay_statics():GetWorldDeltaSeconds(gm) end)
    return (ok and type(d) == "number" and d > 0) and d or 1 / 60
end

-- Altura do chao em (x, y), por trace vertical. Usado nos testes de terreno.
function U.ground_z(x, y, z_top, z_bottom)
    local gm = U.game_mode()
    if not gm then return nil end
    local hit = {}
    local ok, r = pcall(function()
        return U.system_library():LineTraceSingle(gm, U.vec(x, y, z_top), U.vec(x, y, z_bottom), 0, true, {}, 0, hit, true,
            { R = 0, G = 0, B = 0, A = 0 }, { R = 0, G = 0, B = 0, A = 0 }, 0)
    end)
    if not ok or not r then return nil end
    local okz, z = pcall(function()
        local h = hit.OutHit or hit
        return h.ImpactPoint and h.ImpactPoint.Z or h.Location.Z
    end)
    return okz and z or nil
end

-- Densidade do voxel num ponto do mundo (negativo = solido, positivo = ar) e busca da superficie.
local data_tools
function U.voxel_world(name)
    for _, v in ipairs(FindAllOf("VoxelWorld") or {}) do
        if v:GetFName():ToString() == name then return v end
    end
end
function U.voxel_value(world_name, x, y, z)
    if not U.valid(data_tools) then data_tools = StaticFindObject("/Script/Voxel.Default__VoxelDataTools") end
    local w = U.voxel_world(world_name)
    if not w then return nil end
    local ok, v = pcall(function()
        local loc = w:K2_GlobalToLocalFloat(U.vec(x, y, z))
        local out = {}
        data_tools:GetInterpolatedValue(out, w, loc)
        return out.Value
    end)
    return ok and v or nil
end
function U.voxel_surface(x, y, z_top, z_bottom)
    for _, v in ipairs(FindAllOf("VoxelWorld") or {}) do
        local name = v:GetFName():ToString()
        if name:find("HydroVoxelWorld", 1, true) then
            -- fora dos limites de um mundo a leitura da -1 (solido) em todo lugar; so vale a passagem de ar para solido
            local z, saw_air = z_top, false
            while z >= z_bottom do
                local val = U.voxel_value(name, x, y, z)
                if val and val > 0 then saw_air = true
                elseif val and val < 0 and saw_air then return { world = name, z = z } end
                z = z - 25
            end
        end
    end
    return nil
end

return U
