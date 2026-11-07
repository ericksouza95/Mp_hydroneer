-- MpSpike fase 3: jogadores remotos pelo caminho do Remote Play, frame sem limite, carregamento nativo.
local OUT = "E:/hydroneer-qa/out/spike3.txt"
local function w(line)
    local f = io.open(OUT, "a")
    if f then f:write(os.date("%H:%M:%S ") .. tostring(line) .. "\n"); f:close() end
end
local function try(label, fn)
    local ok, a, b = pcall(fn)
    w(label .. (ok and " OK: " or " ERRO: ") .. tostring(a) .. (b ~= nil and (" | " .. tostring(b)) or ""))
    return ok, a, b
end
local function game(fn)
    ExecuteInGameThread(function()
        local ok, e = pcall(fn)
        if not ok then w("ERRO game-thread: " .. tostring(e)) end
    end)
end
local function later(ms, fn) ExecuteWithDelay(ms, function() game(fn) end) end

w("==== fase 3 inicio ====")
w("package=" .. type(package) .. " loadlib=" .. type(package and package.loadlib) .. " require=" .. type(require)
    .. " cpath=" .. tostring(package and package.cpath))
local started = false

local function console(gm, cmd)
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    try("console '" .. cmd .. "'", function() return ksl:ExecuteConsoleCommand(gm, cmd, nil) end)
end

local function avg_delta(gm, label, n, cb)
    local sum, count, mx, fails = 0, 0, 0, 0
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local function step()
        local ok, d = pcall(function() return gs:GetWorldDeltaSeconds(gm) end)
        if ok and type(d) == "number" then
            sum = sum + d; count = count + 1; if d > mx then mx = d end
        else
            fails = fails + 1
        end
        if count < n and fails < 5 then
            later(50, step)
        else
            w(("%s: delta medio %.2f ms (%.0f fps), pior %.2f ms, %d amostras"):format(
                label, 1000 * sum / math.max(count, 1), count / math.max(sum, 1e-6), 1000 * mx, count))
            if cb then cb() end
        end
    end
    step()
end

local function controllers(label)
    local pcs = FindAllOf("BP_GameController_C") or {}
    local lps = FindAllOf("LocalPlayer") or {}
    w(("%s: controladores=%d localplayers=%d"):format(label, #pcs, #lps))
    for i, pc in ipairs(pcs) do
        local ok, pawn = pcall(function() return pc.Pawn end)
        local pn = (ok and pawn and pawn:IsValid()) and pawn:GetFName():ToString() or "nil"
        local okm, main = pcall(function() return pc:IsMainController_() end)
        w(("  pc%d %s pawn=%s"):format(i, pc:GetFName():ToString(), pn))
    end
    local gi = FindFirstOf("BP_GameInstance_C")
    pcall(function()
        local ids = {}
        gi.SessionIDs:ForEach(function(_, e) ids[#ids + 1] = tostring(e:get()) end)
        w("  GI.SessionIDs=[" .. table.concat(ids, ",") .. "] HasLocalPlayer=" .. tostring(gi.HasLocalPlayer)
            .. " RemotePlayStarted=" .. tostring(gi.RemotePlayStarted))
    end)
end

local function run(gm)
    console(gm, "t.MaxFPS 0")
    console(gm, "r.VSync 0")
    later(2000, function()
        controllers("INICIO")
        avg_delta(gm, "1 jogador, sem limite", 100, function()
            try("AddRemotePlayer SessionID=101", function() return gm:AddRemotePlayer({SessionID = 101}) end)
            later(3000, function()
                controllers("apos remoto 101")
                try("AddRemotePlayer SessionID=102", function() return gm:AddRemotePlayer({SessionID = 102}) end)
                later(3000, function()
                    controllers("apos remoto 102")
                    try("AddRemotePlayer SessionID=103", function() return gm:AddRemotePlayer({SessionID = 103}) end)
                    later(3000, function()
                        controllers("apos remoto 103")
                        local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
                        local pcs = FindAllOf("BP_GameController_C") or {}
                        if pcs[1] then try("SetForceDisableSplitscreen", function() return gs:SetForceDisableSplitscreen(pcs[1], true) end) end
                        later(2000, function()
                            avg_delta(gm, "com jogadores extras, split desligado", 100, function()
                                w("FASE3_CONCLUIDA")
                            end)
                        end)
                    end)
                end)
            end)
        end)
    end)
end

RegisterInitGameStatePostHook(function(gs)
    if started then return end
    started = true
    later(12000, function()
        local gm = FindFirstOf("GM_Hydroneer_C")
        local gi = FindFirstOf("BP_GameInstance_C")
        pcall(function() gi.SaveSlot = "MpSpike3" end)
        try("GM:NewGame()", function() return gm:NewGame() end)
        local waited = 0
        local function wait_ingame()
            waited = waited + 1
            local ok, ing = pcall(function() return gm["InGame?"] end)
            if ok and ing then
                w("EM JOGO apos " .. waited .. " s")
                later(15000, function() run(gm) end)
            elseif waited < 60 then
                later(1000, wait_ingame)
            else
                w("NAO ENTROU NO JOGO"); w("FASE3_CONCLUIDA")
            end
        end
        later(1000, wait_ingame)
    end)
end)
