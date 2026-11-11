-- world.lua: estado global do mundo vindo do host. Hoje: hora do dia.
-- Dormir funciona sozinho: a cama e uma acao de mundo, executada no host, que adianta o relogio dele.
local U = require("util")
local P = require("proto")

local W = {}

W.stats = { sent = 0, applied = 0 }
local last_send = 0
local client_paused_by_us = false

local function cycle()
    local dn = FindFirstOf("BP_DayNightCycle_C")
    return U.valid(dn) and dn or nil
end

function W.host_tick(broadcast)
    local t = os.clock()
    if t - last_send < 1 then return end
    last_send = t
    local dn = cycle()
    if not dn then return end
    local ok, hour, paused = pcall(function() return dn.Hour, dn["Paused?"] end)
    if ok and type(hour) == "number" then
        broadcast(P.time(hour, paused == true), false)
        W.stats.sent = W.stats.sent + 1
    end
end

function W.client_handle(m)
    local dn = cycle()
    if not dn then return end
    if not client_paused_by_us then
        -- o relogio local para; a hora passa a vir do host
        pcall(function() dn:PauseTime() end)
        client_paused_by_us = true
    end
    pcall(function()
        if math.abs((dn.Hour or 0) - m.hour) > 0.01 then
            dn.Hour = m.hour
            dn:Update()
        end
    end)
    W.stats.applied = W.stats.applied + 1
end

function W.client_reset()
    if client_paused_by_us then
        local dn = cycle()
        if dn then pcall(function() dn:UnpauseTime() end) end
        client_paused_by_us = false
    end
end

return W
