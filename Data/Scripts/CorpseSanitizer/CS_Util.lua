-- Scripts/CorpseSanitizer/CS_Util.lua
local CS = CorpseSanitizer

function CS.later(ms, fn)
    if Script and Script.SetTimer then
        Script.SetTimer(ms, fn)
    else
        local ok, err = pcall(fn)
        if not ok then System.LogAlways("[CorpseSanitizer] later() error: " .. tostring(err)) end
    end
end

function CS.getPlayer()
    return _G.g_localActor or (_G.System and _G.System.GetLocalPlayer and System.GetLocalPlayer())
end

function CS.lower_eq(a, b) return string.lower(tostring(a or "")) == string.lower(tostring(b or "")) end

function CS.countKeys(t)
    local c = 0; for _ in pairs(t or {}) do c = c + 1 end; return c
end

-- soft isCorpse check; if you already have a better one, replace this
function CS.isCorpseEntity(e)
    if not e then return false end
    if e.IsCorpse and type(e.IsCorpse) == "function" then
        local ok, res = pcall(e.IsCorpse, e); if ok then return not not res end
    end
    local nm = "<entity>"; if e.GetName then pcall(function() nm = e:GetName() end) end
    local s = string.lower(tostring(nm))
    return (s:find("deadbody", 1, true) or s:find("dead_body", 1, true) or s:find("so_deadbody", 1, true)) and true or
    false
end

-- classify victim: minimal, extend as needed
function CS.classifyVictim(e)
    local nm = "<entity>"; if e and e.GetName then pcall(function() nm = e:GetName() end) end
    local s = string.lower(tostring(nm))
    local isAnimal = s:find("dog", 1, true) or s:find("boar", 1, true) or s:find("deer", 1, true) or
    s:find("rabbit", 1, true) or s:find("wolf", 1, true)
    return (not not isAnimal), (not isAnimal)
end

function CS.isHostileToPlayer(e)
    local p = CS.getPlayer(); if not e or not p then return false end
    for _, fn in ipairs({ "IsHostileTo", "IsHostile", "IsEnemyTo", "IsEnemy", "IsAggressiveTo" }) do
        local f = e[fn]; if type(f) == "function" then
            local ok, res = pcall(f, e, p); if ok and res then return true end
        end
    end
    local ef, pf
    if e.GetFaction then
        local ok, v = pcall(e.GetFaction, e); if ok then ef = v end
    end
    if p.GetFaction then
        local ok, v = pcall(p.GetFaction, p); if ok then pf = v end
    end
    if ef and pf and ef ~= pf then
        local N = CS.config and CS.config.nuker
        if N and N.hostileIfDifferentFaction ~= false then return true end
    end
    if e.WasRecentlyDamagedByPlayer and type(e.WasRecentlyDamagedByPlayer) == "function" then
        local ok, res = pcall(e.WasRecentlyDamagedByPlayer, e, 3.0); if ok and res then return true end
    end
    return false
end

-- UI stubs (no SWF writes; just keep ids handy)
CS.UIRefresh = { movie = "ItemTransfer" }
function CS.UIRefresh:Refresh() end

function CS.uiIdFromHandle(h) return (tostring(h):gsub("^userdata:%s*", "")) end

function CS.uiIdFromRow(row)
    if type(row) == "userdata" then return CS.uiIdFromHandle(row) end
    if type(row) == "table" then
        local id = row.id or row.Id or row.stackId or row.StackId or row.handle or row.Handle; if id ~= nil then return
            tostring(id) end
    end
end
