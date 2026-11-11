-- savesync.lua: entrada tardia pela transferencia do save do host ("savesync").
--
-- O host salva o mundo, manda os arquivos do slot pela ponte e o cliente grava tudo como o slot
-- local "MpHydroneerHost" e carrega esse slot. Ver docs/10-savesync.md.
--
-- Uso (a sessao liga o modulo a ponte; o modulo nunca chama a mpnet direto):
--   local SS = require("savesync")
--   SS.init({ send = function(peer, bytes, reliable, channel) ... end,
--             log = function(texto) ... end,
--             now_us = function() return mpnet.now_us end })
--   ao receber um pacote: if SS.handles(data) then (host) SS.host_handle(peer, data) / (cliente) SS.client_handle(peer, data) end
--   a cada frame: SS.host_tick() ou SS.client_tick()
--   cliente: SS.client_request(host_peer)
--   par saiu: SS.drop_peer(peer)
--   ganchos: SS.host_terrain_mark, SS.on_client_loaded(peer, marca), SS.on_world_loaded(marca)
--
-- Mensagens: tipos 20 a 29 no primeiro byte, todas confiaveis no canal 2.
local SS = {}

SS.VERSION = 1
SS.SLOT = "MpHydroneerHost"
SS.CHANNEL = 2

SS.CHUNK = 128 * 1024               -- dados por mensagem (a ponte aceita ate 1 MB)
SS.TICK_BYTES = 256 * 1024          -- maximo enviado por host_tick
SS.WINDOW = 2 * 1024 * 1024         -- maximo enviado e ainda sem ACK do cliente
SS.REQ_EVERY_US = 2000000           -- cliente repete o pedido ate o host responder
SS.REQ_GIVEUP_US = 300000000        -- 5 min sem resposta: desiste
SS.SILENCE_US = 90000000            -- cliente: host calado depois de responder
SS.STATUS_EVERY_US = 5000000        -- host: STATUS para quem espera na fila ou o save
SS.ACK_STALL_US = 60000000          -- host: cliente sem confirmar nada
SS.SAVE_MIN_US = 3000000            -- espera minima depois do Autosave
SS.SAVE_MAX_US = 90000000
SS.SETTLE_US = 5000000              -- espera depois de InGame? antes de avisar a sessao

-- Ajustes do caminho de carga (o padrao e o que funcionou nos testes; ver docs/10-savesync.md).
--   load_method: "gm" (GM_Hydroneer_C:ContinueGame), "menu" (botoes do menu) ou "auto" (gm e, se nada acontecer, menu)
--   leave_method: como sair de um mundo ja carregado: "menu" (OpenLevel, espera o menu principal e carrega de la),
--     "gm" (ContinueGame direto do mundo e, como ele nao recarrega o nivel, cai no "menu" depois de 15 s) ou
--     "gm_inplace" (experimento: aceita a carga no lugar; so o jogador muda, os itens ficam errados)
--   save_own_world: salva o mundo do proprio cliente antes de trocar pelo do host
SS.config = { load_method = "gm", leave_method = "menu", save_own_world = true }

-- Ganchos que a sessao sobrescreve
SS.host_terrain_mark = function() return 0 end
SS.on_client_loaded = function(peer, terrain_mark) end
SS.on_world_loaded = function(terrain_mark) end

-- Medidas da ultima operacao, para relatorio
SS.stats = {}

local T = { REQ = 20, STATUS = 21, HEADER = 22, CHUNK = 23, DONE = 24, ACK = 25, LOADED = 26, ABORT = 27 }
SS.T = T
local ST_QUEUED, ST_SAVING = 1, 2

local pack, unpack = string.pack, string.unpack

local opts = {
    send = function() end,
    log = function() end,
    now_us = function() return os.time() * 1000000 end,
}

local function now() return opts.now_us() end
local function log(text) pcall(opts.log, "savesync: " .. text) end
local function send(peer, bytes) opts.send(peer, bytes, true, SS.CHANNEL) end

function SS.init(o)
    o = o or {}
    opts.send = o.send or opts.send
    opts.log = o.log or opts.log
    opts.now_us = o.now_us or opts.now_us
end

function SS.handles(bytes)
    local t = type(bytes) == "string" and string.byte(bytes, 1)
    return t ~= nil and t >= 20 and t <= 29
end

-- ---------------------------------------------------------------- hash
-- FNV-1a em palavras de 64 bits: barato em Lua 5.4 (8 bytes por passo, multiplicacao que da a volta em 2^64).
local PRIME = 0x100000001b3
local OFFSET = 0xcbf29ce484222325
local W8 = "<i8i8i8i8i8i8i8i8"

local function hash_block(h, s, p, last)
    while p <= last do
        local a, b, c, d, e, f, g, k = unpack(W8, s, p)
        h = (h ~ a) * PRIME; h = (h ~ b) * PRIME; h = (h ~ c) * PRIME; h = (h ~ d) * PRIME
        h = (h ~ e) * PRIME; h = (h ~ f) * PRIME; h = (h ~ g) * PRIME; h = (h ~ k) * PRIME
        p = p + 64
    end
    return h
end

local function hash_chunk(s)
    local n = #s
    local full = n - n % 64
    local h = hash_block(OFFSET, s, 1, full - 63)
    if full < n then
        local tail = s:sub(full + 1) .. string.rep("\0", 64 - (n - full))
        h = hash_block(h, tail, 1, 1)
    end
    return (h ~ n) * PRIME
end
SS.hash_chunk = hash_chunk

-- hash do arquivo: encadeia os hashes dos pedacos, na mesma divisao dos dois lados
local function hash_mix(h, chunk_hash) return (h ~ chunk_hash) * PRIME end

-- ---------------------------------------------------------------- codificacao
local function pack_mark(m)
    m = tonumber(m) or 0
    if math.type(m) == "integer" then return pack("<Bi8", 0, m) end
    return pack("<Bd", 1, m)
end

local function unpack_mark(s, p)
    local kind
    kind, p = unpack("<B", s, p)
    if kind == 0 then return unpack("<i8", s, p) end
    return unpack("<d", s, p)
end

local function msg_abort(req, reason) return pack("<BI4s2", T.ABORT, req, reason:sub(1, 400)) end

-- ---------------------------------------------------------------- acesso ao jogo (autonomo: nao depende do util.lua)
local function valid(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end

local function fstr(v)
    if v == nil then return nil end
    if type(v) == "string" then return v end
    local ok, s = pcall(function() return v:ToString() end)
    return ok and s or nil
end

local cache = {}
local function lib(key, path)
    local o = cache[key]
    if not valid(o) then o = StaticFindObject(path); cache[key] = o end
    return valid(o) and o or nil
end
local function statics() return lib("gs", "/Script/Engine.Default__GameplayStatics") end
local function ksl() return lib("ksl", "/Script/Engine.Default__KismetSystemLibrary") end
local function ems() return lib("ems", "/Script/EasyMultiSave.Default__EMSFunctionLibrary") end
local function fileutils() return lib("fu", "/Script/BlueprintFileUtils.Default__BlueprintFileUtilsBPLibrary") end

local function game_mode()
    local gm = FindFirstOf("GM_Hydroneer_C")
    return valid(gm) and gm or nil
end

local function in_game()
    local gm = game_mode()
    if not gm then return false end
    local ok, v = pcall(function() return gm["InGame?"] end)
    return ok and v == true
end

local function controller()
    local gm = game_mode()
    if not gm then return nil end
    local ok, pc = pcall(function() return statics():GetPlayerController(gm, 0) end)
    return (ok and valid(pc)) and pc or nil
end

local function address(o)
    local ok, a = pcall(function() return o:GetAddress() end)
    return ok and a or nil
end

function SS.current_slot()
    local ctx = controller() or game_mode()
    if not ctx then return nil end
    local ok, name = pcall(function()
        local out = {}
        ems():GetSlotInfoSaveGame(ctx, out)
        return fstr(out.SaveGameName or out[1])
    end)
    return ok and name or nil
end

local function saving_or_loading()
    local ctx = controller() or game_mode()
    if not ctx then return false end
    local ok, v = pcall(function() return ems():IsSavingOrLoading(ctx) end)
    return ok and v == true
end

-- <ProjectSavedDirectory>/SaveGames/, com barras normais e caminho absoluto
function SS.saves_dir()
    local ok, dir = pcall(function()
        local d = fstr(ksl():GetProjectSavedDirectory())
        local okabs, abs = pcall(function() return fstr(ksl():ConvertToAbsolutePath(d)) end)
        if okabs and abs and abs ~= "" then d = abs end
        return d
    end)
    if not ok or not dir or dir == "" then return nil end
    dir = dir:gsub("\\", "/")
    if dir:sub(-1) ~= "/" then dir = dir .. "/" end
    -- trava de seguranca: so escreve dentro de uma pasta Saved do jogo
    if not dir:match("/Saved/$") then return nil end
    return dir .. "SaveGames/"
end

local function file_size(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local n = f:seek("end")
    f:close()
    return n
end

local function dir_writable(dir)
    local probe = dir .. ".mpsavesync"
    local f = io.open(probe, "wb")
    if not f then return false end
    f:close()
    os.remove(probe)
    return true
end

-- Cria a pasta so se ela ainda nao existe. Primeiro pela funcao do jogo (sem janela de console).
local function ensure_dir(dir)
    if dir_writable(dir) then return true end
    pcall(function() fileutils():MakeDirectory(dir, true) end)
    if dir_writable(dir) then return true end
    os.execute('mkdir "' .. dir:gsub("/", "\\"):gsub("\\$", "") .. '" 2>nul')
    return dir_writable(dir)
end

local KNOWN_FILES = { "Level.sav", "Player.sav", "SaveData.sav" }

-- Arquivos .sav de uma pasta de slot. Usa o FindFiles do jogo; sem ele, a lista conhecida.
local function list_saves(dir)
    local names, seen = {}, {}
    pcall(function()
        local out = {}
        fileutils():FindFiles(dir, out, ".sav")
        local arr = out.FoundFiles or out[1]
        arr:ForEach(function(_, e)
            local s = fstr(e:get())
            local name = s and s:match("([^/\\]+)$")
            if name and name:match("%.sav$") and not seen[name] then seen[name] = true; names[#names + 1] = name end
        end)
    end)
    local source = "FindFiles"
    for _, n in ipairs(KNOWN_FILES) do
        if not seen[n] and file_size(dir .. n) then seen[n] = true; names[#names + 1] = n; source = "FindFiles+lista" end
    end
    table.sort(names)
    return names, source
end

-- Grava por arquivo temporario e troca, para nunca deixar um .sav pela metade.
local function write_parts(path, parts)
    local tmp = path .. ".mptmp"
    local f = io.open(tmp, "wb")
    if not f then return false, "nao abriu " .. tmp end
    for _, p in ipairs(parts) do
        if not f:write(p) then f:close(); os.remove(tmp); return false, "falha ao gravar " .. tmp end
    end
    f:close()
    os.remove(path)
    local ok, e = os.rename(tmp, path)
    if not ok then return false, "rename: " .. tostring(e) end
    return true
end

local function start_autosave()
    local pc = controller()
    if not pc then return false, "sem controlador local" end
    local ok, e = pcall(function() pc:Autosave() end)
    if not ok then return false, tostring(e) end
    return true
end

-- Espera o save: no minimo SAVE_MIN_US e ate IsSavingOrLoading ficar falso. Devolve "wait", "done" ou "timeout".
local function poll_save(job, t0)
    local busy = saving_or_loading()
    if busy then job.saw_saving = true end
    local el = now() - t0
    if el >= SS.SAVE_MAX_US then return "timeout" end
    if el >= SS.SAVE_MIN_US and not busy then return "done" end
    return "wait"
end

-- ---------------------------------------------------------------- host
local host = { queue = {}, job = nil, served = {} }

local function queue_pos(peer)
    for i, q in ipairs(host.queue) do if q.peer == peer then return i end end
    return nil
end

local function send_status(peer, req, code, pos)
    send(peer, pack("<BI4BI2", T.STATUS, req, code, pos or 0))
end

local host_close_files
local function host_finish(job, ok, why)
    host.job = nil
    host_close_files(job)
    if not ok then
        log(("host: transferencia para %s abortada: %s"):format(tostring(job.peer), why))
        if job.peer then send(job.peer, msg_abort(job.req, why)) end
    end
end

function SS.host_handle(peer, bytes)
    local t = string.byte(bytes, 1)
    if t == T.REQ then
        local req, ver = unpack("<I4I2", bytes, 2)
        if ver ~= SS.VERSION then
            send(peer, msg_abort(req, ("versao do savesync diferente: host %d, cliente %d"):format(SS.VERSION, ver)))
            return
        end
        local job = host.job
        if job and job.peer == peer then
            if job.req == req then return end             -- pedido repetido de quem ja esta sendo servido
            log(("host: %s pediu de novo (pedido novo %d), recomeca"):format(tostring(peer), req))
            host_finish(job, true)
            table.insert(host.queue, 1, { peer = peer, req = req, t = now() })
            send_status(peer, req, ST_QUEUED, 1)
            return
        end
        local pos = queue_pos(peer)
        if pos then
            host.queue[pos].req = req                      -- repetido: so atualiza o numero do pedido
            return
        end
        local s = host.served[peer]
        if s and s.req == req then return end             -- duplicata atrasada de um pedido ja servido
        host.queue[#host.queue + 1] = { peer = peer, req = req, t = now() }
        send_status(peer, req, ST_QUEUED, #host.queue)
        log(("host: pedido de %s, posicao %d na fila"):format(tostring(peer), #host.queue))
    elseif t == T.ACK then
        local req, bytes_ok = unpack("<I4I4", bytes, 2)
        local job = host.job
        if job and job.peer == peer and job.req == req and bytes_ok > job.acked then
            job.acked = bytes_ok
            job.last_ack = now()
        end
    elseif t == T.LOADED then
        local req, p = unpack("<I4", bytes, 2)
        local mark = unpack_mark(bytes, p)
        local s = host.served[peer]
        if s and s.req == req then
            host.served[peer] = nil
            log(("host: %s carregou o mundo (marca de terreno %s)"):format(tostring(peer), tostring(mark)))
            local ok, e = pcall(SS.on_client_loaded, peer, mark)
            if not ok then log("host: erro em on_client_loaded: " .. tostring(e)) end
        end
    elseif t == T.ABORT then
        local req, reason = unpack("<I4s2", bytes, 2)
        local job = host.job
        if job and job.peer == peer and job.req == req then
            log(("host: cliente %s desistiu: %s"):format(tostring(peer), reason))
            host_finish(job, true)
        end
        local pos = queue_pos(peer)
        if pos then table.remove(host.queue, pos) end
    end
end

local function host_begin(job)
    job.state = "saving"
    job.t0 = now()
    local okm, mark = pcall(SS.host_terrain_mark)
    job.mark = okm and mark or 0
    send_status(job.peer, job.req, ST_SAVING, 0)
    local ok, e = start_autosave()
    if not ok then host_finish(job, false, "Autosave falhou: " .. tostring(e)); return end
    job.t_save = now()
    log(("host: salvando para %s (marca de terreno %s)"):format(tostring(job.peer), tostring(job.mark)))
end

SS.READ_PER_TICK = 2 * 1024 * 1024

-- Abre os arquivos do slot. A leitura vai para a memoria aos poucos (host_read_step), em pedacos do
-- tamanho de CHUNK, para nao travar um frame e para um autosave no meio da transferencia nao misturar versoes.
local function host_open_files(job)
    local slot = SS.current_slot()
    local base = SS.saves_dir()
    if not slot or slot == "" then return false, "sem nome de slot" end
    if not base then return false, "sem pasta de saves" end
    local dir = base .. slot .. "/"
    local names, source = list_saves(dir)
    local files, total = {}, 0
    for _, name in ipairs(names) do
        local h = io.open(dir .. name, "rb")
        if h then
            local size = h:seek("end")
            h:seek("set", 0)
            files[#files + 1] = { name = name, fh = h, size = size, chunks = {}, read = 0, hash = OFFSET }
            total = total + size
        end
    end
    local has_level = false
    for _, f in ipairs(files) do if f.name == "Level.sav" then has_level = true end end
    if not has_level then
        for _, f in ipairs(files) do f.fh:close() end
        return false, "Level.sav nao encontrado em " .. dir
    end
    job.slot, job.files, job.total = slot, files, total
    job.fi, job.ci, job.off, job.sent, job.acked = 1, 1, 0, 0, 0
    job.read_fi, job.t_read = 1, now()
    local list = {}
    for _, f in ipairs(files) do list[#list + 1] = ("%s %d"):format(f.name, f.size) end
    log(("host: slot %s, %d arquivos (%s), %.2f MB: %s"):format(slot, #files, source, total / 1048576, table.concat(list, ", ")))
    return true
end

-- Le ate READ_PER_TICK. Devolve true quando tudo esta na memoria.
local function host_read_step(job)
    local budget = SS.READ_PER_TICK
    while budget > 0 and job.read_fi <= #job.files do
        local f = job.files[job.read_fi]
        if f.read >= f.size then
            f.fh:close(); f.fh = nil
            job.read_fi = job.read_fi + 1
        else
            local want = math.min(SS.CHUNK, f.size - f.read)
            local piece = f.fh:read(want)
            if not piece or #piece ~= want then return nil, "leitura curta em " .. f.name .. " (o arquivo mudou?)" end
            f.chunks[#f.chunks + 1] = piece
            f.read = f.read + #piece
            budget = budget - #piece
        end
    end
    return job.read_fi > #job.files
end

function host_close_files(job)
    for _, f in ipairs(job.files or {}) do if f.fh then pcall(function() f.fh:close() end); f.fh = nil end end
end

local function host_send_header(job)
    local creative = false
    pcall(function() creative = controller()["IsCreativeMode?"] == true end)
    local parts = { pack("<BI4B", T.HEADER, job.req, creative and 1 or 0), pack_mark(job.mark),
        pack("<s1I4B", job.slot, job.total, #job.files) }
    for _, f in ipairs(job.files) do parts[#parts + 1] = pack("<s1I4", f.name, f.size) end
    send(job.peer, table.concat(parts))
    job.creative = creative
end

local function host_pump(job)
    local budget = SS.TICK_BYTES
    local t_hash = 0
    while budget > 0 and job.fi <= #job.files and job.sent - job.acked < SS.WINDOW do
        local f = job.files[job.fi]
        local data = f.chunks[job.ci]
        if data == nil then
            job.fi, job.ci, job.off = job.fi + 1, 1, 0
        else
            local c0 = os.clock()
            local h = hash_chunk(data)
            t_hash = t_hash + (os.clock() - c0)
            f.hash = hash_mix(f.hash, h)
            send(job.peer, pack("<BI4BI4i8", T.CHUNK, job.req, job.fi, job.off, h) .. data)
            f.chunks[job.ci] = false            -- libera a memoria do que ja saiu
            job.ci, job.off, job.sent, budget = job.ci + 1, job.off + #data, job.sent + #data, budget - #data
        end
    end
    job.hash_s = (job.hash_s or 0) + t_hash
    if t_hash > (job.hash_max_s or 0) then job.hash_max_s = t_hash end
    if job.fi > #job.files and not job.done_sent then
        local parts = { pack("<BI4B", T.DONE, job.req, #job.files) }
        for _, f in ipairs(job.files) do parts[#parts + 1] = pack("<i8", f.hash) end
        send(job.peer, table.concat(parts))
        job.done_sent = true
    end
end

function SS.host_tick()
    local t = now()
    -- STATUS periodico para quem espera, que serve de sinal de vida para o cliente
    if t - (host.last_status or 0) >= SS.STATUS_EVERY_US then
        host.last_status = t
        for i, q in ipairs(host.queue) do send_status(q.peer, q.req, ST_QUEUED, i) end
        if host.job and host.job.state == "saving" then send_status(host.job.peer, host.job.req, ST_SAVING, 0) end
    end
    if not host.job then
        if #host.queue == 0 or not in_game() then return end
        local q = table.remove(host.queue, 1)
        host.job = { peer = q.peer, req = q.req }
        host_begin(host.job)
        return
    end
    local job = host.job
    if job.state == "saving" and not job.reading then
        local r = poll_save(job, job.t_save)
        if r == "wait" then return end
        job.save_s = (now() - job.t_save) / 1e6
        if r == "timeout" then log("host: o save nao terminou no prazo; mandando o que esta no disco") end
        if not job.saw_saving then log("host: IsSavingOrLoading nunca ficou verdadeiro depois do Autosave") end
        local ok, e = host_open_files(job)
        if not ok then host_finish(job, false, e); return end
        job.reading = true
        log(("host: save pronto em %.1f s"):format(job.save_s))
    end
    if job.state == "saving" and job.reading then
        local done, e = host_read_step(job)
        if done == nil then host_finish(job, false, e); return end
        if not done then return end
        log(("host: arquivos lidos para a memoria em %.0f ms"):format((now() - job.t_read) / 1000))
        host_send_header(job)
        job.state, job.t_send, job.last_ack = "sending", now(), now()
        SS.stats.host_save_s = job.save_s
    end
    if job.state == "sending" then
        host_pump(job)
        if job.done_sent and job.acked >= job.total then
            local secs = (now() - job.t_send) / 1e6
            local mb = job.total / 1048576
            SS.stats.host_transfer_s, SS.stats.host_mb, SS.stats.host_mbps = secs, mb, mb / math.max(secs, 1e-3)
            SS.stats.host_hash_s, SS.stats.host_hash_max_ms = job.hash_s, (job.hash_max_s or 0) * 1000
            SS.stats.host_mark = job.mark
            log(("host: enviado para %s: %.2f MB em %.1f s (%.2f MB/s), save %.1f s, hash total %.0f ms, pior tick %.1f ms"):format(
                tostring(job.peer), mb, secs, mb / math.max(secs, 1e-3), job.save_s, job.hash_s * 1000, (job.hash_max_s or 0) * 1000))
            host.served[job.peer] = { req = job.req, mark = job.mark, t = now() }
            host_finish(job, true)
        elseif now() - job.last_ack > SS.ACK_STALL_US then
            host_finish(job, false, "cliente parou de confirmar")
        end
    end
end

-- ---------------------------------------------------------------- cliente
local cl = { state = "idle" }

local function client_fail(why, tell_host)
    log("cliente: falhou: " .. why)
    if tell_host and cl.host and cl.req then send(cl.host, msg_abort(cl.req, why)) end
    cl.state = "failed"
    cl.files = nil
end

function SS.client_request(host_peer)
    math.randomseed(os.time() + (now() % 1000000))
    cl = { state = "requested", host = host_peer, req = math.random(1, 0x7fffffff), t0 = now(), last_req = 0, answered = false }
    SS.stats.client = {}
    log(("cliente: pedindo o mundo ao host %s (pedido %d)"):format(tostring(host_peer), cl.req))
end

local function client_header(bytes)
    local req, flags, p = unpack("<I4B", bytes, 2)
    if req ~= cl.req then return end
    local mark
    mark, p = unpack_mark(bytes, p)
    local slot, total, n
    slot, total, n, p = unpack("<s1I4B", bytes, p)
    local files = {}
    for i = 1, n do
        local name, size
        name, size, p = unpack("<s1I4", bytes, p)
        if not name:match("^[%w_%-%.]+%.sav$") then client_fail("nome de arquivo recusado: " .. name, true); return end
        files[i] = { name = name, size = size, got = 0, parts = {}, hash = OFFSET }
    end
    cl.files, cl.total, cl.got, cl.mark, cl.host_slot = files, total, 0, mark, slot
    cl.creative = (flags & 1) ~= 0
    cl.state, cl.t_header = "receiving", now()
    log(("cliente: recebendo o slot %s do host: %d arquivos, %.2f MB, marca de terreno %s"):format(slot, n, total / 1048576, tostring(mark)))
end

local function client_chunk(bytes)
    local req, fi, off, h, p = unpack("<I4BI4i8", bytes, 2)
    if req ~= cl.req or cl.state ~= "receiving" then return end
    local f = cl.files[fi]
    if not f then client_fail("pedaco de arquivo inexistente " .. fi, true); return end
    local data = bytes:sub(p)
    if off ~= f.got then client_fail(("pedaco fora de ordem em %s: %d, esperado %d"):format(f.name, off, f.got), true); return end
    if hash_chunk(data) ~= h then client_fail(("hash errado em %s no offset %d"):format(f.name, off), true); return end
    if f.got + #data > f.size then client_fail("arquivo maior que o anunciado: " .. f.name, true); return end
    f.parts[#f.parts + 1] = data
    f.hash = hash_mix(f.hash, h)
    f.got = f.got + #data
    cl.got = cl.got + #data
    send(cl.host, pack("<BI4I4", T.ACK, cl.req, cl.got))
end

local function client_done(bytes)
    local req, n, p = unpack("<I4B", bytes, 2)
    if req ~= cl.req or cl.state ~= "receiving" then return end
    if n ~= #cl.files then client_fail("numero de arquivos diferente no fim", true); return end
    for i = 1, n do
        local h
        h, p = unpack("<i8", bytes, p)
        local f = cl.files[i]
        if f.got ~= f.size then client_fail(("%s incompleto: %d de %d"):format(f.name, f.got, f.size), true); return end
        if f.hash ~= h then client_fail("hash do arquivo nao confere: " .. f.name, true); return end
    end
    local secs = (now() - cl.t_header) / 1e6
    SS.stats.client.transfer_s = secs
    log(("cliente: %.2f MB recebidos e conferidos em %.1f s"):format(cl.total / 1048576, secs))
    cl.state, cl.t_load = "loading", now()
    cl.phase, cl.t_phase = "leave", now()
end

function SS.client_handle(peer, bytes)
    if cl.state == "idle" or cl.state == "failed" or cl.state == "loaded" or peer ~= cl.host then return end
    local t = string.byte(bytes, 1)
    cl.last_msg = now()
    if t == T.STATUS then
        local req, code, pos = unpack("<I4BI2", bytes, 2)
        if req ~= cl.req then return end
        if not cl.answered then
            log(("cliente: host respondeu (%s%s)"):format(code == ST_SAVING and "salvando" or "na fila",
                code == ST_QUEUED and (", posicao " .. pos) or ""))
        end
        cl.answered = true
        cl.queue_pos, cl.host_saving = pos, code == ST_SAVING
    elseif t == T.HEADER then
        cl.answered = true
        if cl.state == "requested" then client_header(bytes) end
    elseif t == T.CHUNK then
        client_chunk(bytes)
    elseif t == T.DONE then
        client_done(bytes)
    elseif t == T.ABORT then
        local req, reason = unpack("<I4s2", bytes, 2)
        if req == cl.req and (cl.state == "requested" or cl.state == "receiving") then client_fail("host abortou: " .. reason, false) end
    end
end

-- Situacao do jogo para o relatorio
local function diag()
    local menu = "?"
    pcall(function()
        local m = game_mode().UI_MainMenu
        menu = valid(m) and tostring(m:IsInViewport()) or "sem widget"
    end)
    local cursor = "?"
    pcall(function() cursor = tostring(controller().bShowMouseCursor) end)
    local pos = "?"
    pcall(function() local v = controller().Pawn:K2_GetActorLocation(); pos = ("%.0f %.0f %.0f"):format(v.X, v.Y, v.Z) end)
    return ("InGame? %s, slot %s, menu na tela %s, cursor %s, jogador em %s"):format(tostring(in_game()),
        tostring(SS.current_slot()), menu, cursor, pos)
end
SS.diag = diag

local function set_phase(p)
    cl.phase, cl.t_phase = p, now()
    log("cliente: carga -> " .. p .. " (" .. diag() .. ")")
end

local function phase_elapsed() return now() - cl.t_phase end

local function write_files()
    local base = SS.saves_dir()
    if not base then return false, "pasta de saves invalida" end
    local dir = base .. SS.SLOT .. "/"
    if not ensure_dir(dir) then return false, "nao consegui criar " .. dir end
    local keep = {}
    for _, f in ipairs(cl.files) do keep[f.name] = true end
    for _, old in ipairs((list_saves(dir))) do
        if not keep[old] then os.remove(dir .. old); log("cliente: removido arquivo antigo " .. old) end
    end
    local c0 = os.clock()
    for _, f in ipairs(cl.files) do
        local ok, e = write_parts(dir .. f.name, f.parts)
        if not ok then return false, e end
        if file_size(dir .. f.name) ~= f.size then return false, "tamanho gravado nao confere: " .. f.name end
    end
    log(("cliente: %d arquivos gravados em %s (%.0f ms)"):format(#cl.files, dir, (os.clock() - c0) * 1000))
    return true
end

local function call_continue_game()
    local gm = game_mode()
    pcall(function() ems():SetCurrentSaveGameName(gm, SS.SLOT) end)
    local ok, e = pcall(function() gm:ContinueGame(cl.creative == true, false, false, SS.SLOT) end)
    log("cliente: GM_Hydroneer_C:ContinueGame -> " .. (ok and "ok" or tostring(e)))
    return ok
end

local function main_menu()
    local gm = game_mode()
    if not gm then return nil end
    local ok, m = pcall(function() return gm.UI_MainMenu end)
    if ok and valid(m) then return m end
    local f = FindFirstOf("UI_MainMenu_C")
    return valid(f) and f or nil
end

-- Uma fase por tick. Cada fase olha o relogio e o jogo e decide a proxima.
local function client_load_step()
    local p = cl.phase
    if p == "leave" then
        cl.leave = SS.config.leave_method
        if in_game() then
            cl.was_in_game = true
            cl.old_gm = address(game_mode())
            local cur = SS.current_slot()
            if SS.config.save_own_world and cur ~= SS.SLOT then
                local ok, e = start_autosave()
                log(("cliente: salvando o proprio mundo (%s) antes de trocar: %s"):format(tostring(cur), ok and "ok" or tostring(e)))
                cl.t_own = now()
                set_phase(ok and "own_save" or "leave_world")
            else
                set_phase("leave_world")
            end
        else
            set_phase("menu_wait")
        end
    elseif p == "own_save" then
        if poll_save(cl, cl.t_own) ~= "wait" then set_phase("leave_world") end
    elseif p == "leave_world" then
        if cl.leave == "gm" or cl.leave == "gm_inplace" then
            -- grava por cima e chama ContinueGame direto do mundo; o proprio jogo recarrega o nivel
            local ok, e = write_files()
            if not ok then client_fail(e, true); return end
            cl.t_continue = now()
            call_continue_game()
            set_phase("ingame_wait")
        else
            local gm = game_mode()
            local lvl = "L_GameWorld"
            pcall(function() lvl = fstr(statics():GetCurrentLevelName(gm, true)) or lvl end)
            local ok, e = pcall(function() statics():OpenLevel(gm, FName(lvl), true, "") end)
            log(("cliente: OpenLevel(%s) para voltar ao menu: %s"):format(lvl, ok and "ok" or tostring(e)))
            set_phase("menu_wait")
        end
    elseif p == "menu_wait" then
        local gm = game_mode()
        local ready = gm and not in_game() and main_menu() ~= nil and (not cl.old_gm or address(gm) ~= cl.old_gm)
        if ready then
            if not cl.menu_seen then
                cl.menu_seen = now()
                -- Vindo de um mundo, os atores antigos ainda existem ate o proximo GC. Se o save tiver um ator com o
                -- mesmo nome de um deles, o jogo da outro nome ao carregado. Forca o GC antes de carregar.
                if cl.old_gm then
                    local ok, e = pcall(function() ksl():CollectGarbage() end)
                    log("cliente: CollectGarbage: " .. (ok and "ok" or tostring(e)))
                end
            end
            if now() - cl.menu_seen >= 3000000 then set_phase("write") end
        else
            cl.menu_seen = nil
            if phase_elapsed() > 120000000 then client_fail("o menu principal nao apareceu", true) end
        end
    elseif p == "write" then
        local ok, e = write_files()
        if not ok then client_fail(e, true); return end
        cl.method = SS.config.load_method == "menu" and "menu" or "gm"
        set_phase("load")
    elseif p == "load" then
        cl.t_continue = now()
        if cl.method == "gm" then
            call_continue_game()
            set_phase("ingame_wait")
        else
            pcall(function() ems():SetCurrentSaveGameName(game_mode(), SS.SLOT) end)
            local ok, e = pcall(function()
                main_menu():BndEvt__UI_MainMenu_ContinueButton_1_K2Node_ComponentBoundEvent_14_OnButtonClickedEvent__DelegateSignature()
            end)
            log("cliente: menu -> Continuar: " .. (ok and "ok" or tostring(e)))
            set_phase("menu_select")
        end
    elseif p == "menu_select" then
        if phase_elapsed() < 2500000 then return end
        local sm = FindFirstOf("UI_Menu_SaveManager_C")
        if not valid(sm) then
            if phase_elapsed() > 20000000 then client_fail("a lista de saves nao abriu", true) end
            return
        end
        local ok, e = pcall(function() sm:SaveSelected(SS.SLOT) end)
        log("cliente: lista de saves -> SaveSelected: " .. (ok and "ok" or tostring(e)))
        cl.sm = sm
        set_phase("menu_continue")
    elseif p == "menu_continue" then
        if phase_elapsed() < 1500000 then return end
        local ok, e = pcall(function() cl.sm:ContinueMainGame() end)
        log("cliente: lista de saves -> ContinueMainGame: " .. (ok and "ok" or tostring(e)))
        cl.sm = nil
        set_phase("ingame_wait")
    elseif p == "ingame_wait" then
        local gm = game_mode()
        -- vindo de um mundo, so vale o InGame? depois de o nivel recarregar (GM novo ou InGame? falso no meio)
        if not in_game() then cl.saw_out = true end
        local fresh = not cl.old_gm or cl.saw_out or (gm and address(gm) ~= cl.old_gm)
        if now() - (cl.last_diag or 0) > 5000000 then
            cl.last_diag = now()
            log(("cliente: esperando o mundo, %.0f s: %s, GM novo %s"):format(phase_elapsed() / 1e6, diag(),
                tostring(gm ~= nil and cl.old_gm ~= nil and address(gm) ~= cl.old_gm)))
        end
        if in_game() and fresh then
            cl.t_ingame = now()
            SS.stats.client.continue_to_ingame_s = (cl.t_ingame - cl.t_continue) / 1e6
            set_phase("settle")
        elseif SS.config.load_method == "auto" and cl.method == "gm" and not cl.old_gm and phase_elapsed() > 25000000
            and not in_game() and main_menu() ~= nil then
            log("cliente: ContinueGame nao levou ao jogo em 25 s; tentando pelo menu")
            cl.method = "menu"
            set_phase("load")
        elseif cl.leave == "gm_inplace" and cl.old_gm and phase_elapsed() > 10000000 then
            -- experimento: aceita a carga no lugar, sem recarregar o nivel, para comparar os itens
            log("cliente: experimento gm_inplace: aceitando a carga sem recarregar o nivel")
            cl.t_ingame = now()
            SS.stats.client.continue_to_ingame_s = (cl.t_ingame - cl.t_continue) / 1e6
            set_phase("settle")
        elseif cl.leave == "gm" and cl.old_gm and not fresh and phase_elapsed() > 15000000 then
            -- ContinueGame chamado de dentro de um mundo nao recarregou o nivel: volta ao menu e carrega de la
            log("cliente: ContinueGame de dentro do mundo nao recarregou o nivel em 15 s; voltando ao menu")
            cl.leave = "menu"
            set_phase("leave_world")
        elseif phase_elapsed() > 180000000 then
            client_fail("o mundo do host nao carregou em 180 s", true)
        end
    elseif p == "settle" then
        if not in_game() then set_phase("ingame_wait"); return end
        if phase_elapsed() < SS.SETTLE_US then return end
        local slot = SS.current_slot()
        if slot ~= SS.SLOT then log(("cliente: aviso: slot atual %s, esperado %s"):format(tostring(slot), SS.SLOT)) end
        SS.stats.client.load_s = (now() - cl.t_load) / 1e6
        SS.stats.client.mark = cl.mark
        SS.stats.client.method = (cl.was_in_game and ("de um mundo, " .. tostring(cl.leave)) or "do menu") .. ", " .. tostring(cl.method or "gm")
        log(("cliente: mundo do host carregado: %.1f s do fim da transferencia ate InGame?+%.0f s (%s); %s"):format(
            SS.stats.client.load_s, SS.SETTLE_US / 1e6, SS.stats.client.method, diag()))
        cl.state = "loaded"
        cl.files = nil
        local ok, e = pcall(SS.on_world_loaded, cl.mark)
        if not ok then log("cliente: erro em on_world_loaded: " .. tostring(e)) end
        send(cl.host, pack("<BI4", T.LOADED, cl.req) .. pack_mark(cl.mark))
    end
end

function SS.client_tick()
    local s = cl.state
    if s == "requested" then
        local t = now()
        if not cl.answered then
            if t - cl.t0 > SS.REQ_GIVEUP_US then client_fail("o host nao respondeu em 5 min", false); return end
            if t - cl.last_req >= SS.REQ_EVERY_US then
                cl.last_req = t
                send(cl.host, pack("<BI4I2", T.REQ, cl.req, SS.VERSION))
            end
        elseif t - (cl.last_msg or t) > SS.SILENCE_US then
            client_fail("o host ficou calado", true)
        end
    elseif s == "receiving" then
        if now() - (cl.last_msg or now()) > SS.SILENCE_US then client_fail("a transferencia parou", true) end
    elseif s == "loading" then
        local ok, e = pcall(client_load_step)
        if not ok then client_fail("erro na carga: " .. tostring(e), true) end
    end
end

-- ---------------------------------------------------------------- comum
function SS.drop_peer(peer)
    local pos = queue_pos(peer)
    if pos then table.remove(host.queue, pos); log("host: " .. tostring(peer) .. " saiu da fila") end
    if host.job and host.job.peer == peer then
        log("host: " .. tostring(peer) .. " saiu durante a transferencia")
        host_finish(host.job, true)
    end
    host.served[peer] = nil
    if cl.host == peer and (cl.state == "requested" or cl.state == "receiving" or cl.state == "loading") then
        client_fail("o host saiu", false)
    end
end

function SS.state()
    if cl.state ~= "idle" then return cl.state end
    if host.job then return host.job.state end
    return "idle"
end

function SS.progress()
    if cl.state ~= "idle" then
        if cl.state == "receiving" then return (cl.got or 0) / math.max(cl.total or 1, 1) end
        if cl.state == "loading" or cl.state == "loaded" then return 1 end
        return 0
    end
    local job = host.job
    if job and job.state == "sending" then return job.acked / math.max(job.total, 1) end
    return 0
end

return SS
