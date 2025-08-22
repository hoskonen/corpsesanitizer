-- CorpseSanitizer.lua (0.0.5)
CorpseSanitizer = {
    version = "0.0.5",
    booted  = false,
    config  = {
        dryRun    = true,
        minHealth = 0.50,
        ui        = { movie = "ItemTransfer" },
        proximity = { radius = 3.0, maxList = 20 }, -- meters, how many to log
    },
    ui      = { active = false }
}

local function log(msg) System.LogAlways("[CorpseSanitizer] " .. tostring(msg)) end

-- ===== Faction + relationship helpers (no polling) =====

local FactionCache = { byId = nil } -- lazy

local function getPlayer()
    return System.GetEntityByName("player")
        or System.GetEntityByName("Henry")
        or System.GetEntityByName("dude")
end

-- Build a map: factionId -> name (lazy)
local function buildFactionCache()
    FactionCache.byId = {}
    if not RPG or type(RPG.GetFactions) ~= "function" then
        log("RPG.GetFactions not available; faction names may be missing")
        return
    end
    local ok, list = pcall(RPG.GetFactions)
    if not ok or not list then return end
    for _, f in ipairs(list) do
        -- Typical fields seen in dumps: id / name (keep defensive)
        local id   = f.id or f.Id or f.ID
        local name = f.name or f.Name
        if id ~= nil then FactionCache.byId[id] = tostring(name or ("Faction#" .. tostring(id))) end
    end
end

local function factionNameById(fid)
    if fid == nil then return "?" end
    if not FactionCache.byId then buildFactionCache() end
    -- direct hit
    if FactionCache.byId and FactionCache.byId[fid] then
        return FactionCache.byId[fid]
    end
    -- try RPG.GetFactionById for string ids like "player"
    if RPG and type(RPG.GetFactionById) == "function" then
        local ok, f = pcall(function() return RPG.GetFactionById(fid) end)
        if ok and f then
            local name = f.name or f.Name or tostring(fid)
            if FactionCache.byId then FactionCache.byId[fid] = name end
            return name
        end
    end
    -- fallback
    return tostring(fid)
end


-- Extract soul from entity safely
local function getSoul(ent)
    if not ent then return nil end
    return ent.soul or (ent.GetSoul and ent:GetSoul()) or nil
end

-- Returns table with best-effort info
local function getFactionInfo(ent)
    local s = getSoul(ent)
    local info = { id = nil, name = nil, superfaction = nil, perceivedSuper = nil, relToPlayer = nil }

    if s then
        if type(s.GetFactionID) == "function" then
            local ok, id = pcall(function() return s:GetFactionID() end)
            if ok then
                info.id = id; info.name = factionNameById(id)
            end
        end
        if type(s.GetSuperfaction) == "function" then
            local ok, sf = pcall(function() return s:GetSuperfaction() end)
            if ok then info.superfaction = sf end
        end
        if type(s.GetPerceivedSuperfaction) == "function" then
            local ok, psf = pcall(function() return s:GetPerceivedSuperfaction() end)
            if ok then info.perceivedSuper = psf end
        end
    end

    -- Relationship to player, if both souls exist
    local p = getPlayer()
    local ps = getSoul(p)
    if s and ps and type(s.GetRelationship) == "function" then
        -- We need the *other* soul id; try ps:GetFactionID() or a soul id field if present.
        local otherId = nil
        if type(ps.GetFactionID) == "function" then
            local ok, fid = pcall(function() return ps:GetFactionID() end)
            if ok then otherId = fid end
        end
        -- Some builds expose a numeric soul id (speculative). Try common fields:
        if not otherId and ps.id then otherId = ps.id end
        if not otherId and ps.GetId then
            local ok, sid = pcall(function() return ps:GetId() end)
            if ok then otherId = sid end
        end
        if otherId ~= nil then
            local ok, rel = pcall(function() return s:GetRelationship(otherId) end)
            if ok then info.relToPlayer = tonumber(rel) end -- -1..1
        end
    end

    return info
end

-- Decide if hostile to player; prefer relationship if present, else fallback heuristics
local function isHostileToPlayer(ent)
    local inf = getFactionInfo(ent)
    if inf.relToPlayer ~= nil then
        return inf.relToPlayer <= -0.5, inf
    end
    -- Fallback: different faction id and/or aggressive superfaction
    local p = getPlayer()
    local ps = getSoul(p)
    local pfid = (ps and type(ps.GetFactionID) == "function") and
        (pcall(function() return ps:GetFactionID() end) and ps:GetFactionID() or nil) or nil
    if pfid and inf.id and inf.id ~= pfid then
        return true, inf
    end
    return false, inf
end

local function logFactionSummary(ent, tag)
    local hostile, inf = isHostileToPlayer(ent)
    local nm = (ent.GetName and ent:GetName()) or "<unnamed>"
    local rel = (inf.relToPlayer ~= nil) and string.format("%.2f", inf.relToPlayer) or "n/a"
    log(string.format("%s target '%s': faction=%s (id=%s) super=%s perceived=%s rel=%s hostile=%s",
        tag or "[FACTION]",
        nm,
        tostring(inf.name or "?"),
        tostring(inf.id or "?"),
        tostring(inf.superfaction or "?"),
        tostring(inf.perceivedSuper or "?"),
        rel,
        tostring(hostile)))
end

-- Try common soul getters (may all be absent in your build)
local function trySoulGetters()
    local p = System.GetEntityByName and
        (System.GetEntityByName("player") or System.GetEntityByName("Henry") or System.GetEntityByName("dude"))
    if not p or not p.soul then return nil, "noSoul" end
    local soul = p.soul
    local candidates = {
        "GetInteractionTarget", "GetCurrentContainer", "GetUseEntity", "GetUseTarget",
        "GetLookAtTarget", "GetFocusEntity", "GetTargetEntity",
    }
    for _, name in ipairs(candidates) do
        local fn = soul[name]
        if type(fn) == "function" then
            local ok, ent = pcall(function() return fn(soul) end)
            if ok and ent and ent.GetName then return ent, name end
        end
    end
    return nil, "noGetter"
end

-- Distance^2 helper
local function dist2(a, b)
    local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
    return dx * dx + dy * dy + dz * dz
end

-- Single-shot nearby scan (no polling): list closest entities + basic traits
local function scanNearbyOnce(radiusM, maxList)
    local player = System.GetEntityByName and
        (System.GetEntityByName("player") or System.GetEntityByName("Henry") or System.GetEntityByName("dude"))
    if not (player and player.GetWorldPos) then
        log("scanNearbyOnce: no player or position")
        return {}
    end
    local pos = player:GetWorldPos()
    local list = {}

    local iter = nil
    if System.GetEntitiesInSphere then
        iter = System.GetEntitiesInSphere(pos, radiusM or 3.0)
    elseif System.GetEntities then
        -- fallback: scan all, then filter by radius
        iter = System.GetEntities()
    end

    if not iter then
        log("scanNearbyOnce: no entity enumerator available")
        return {}
    end

    local R2 = (radiusM or 3.0) * (radiusM or 3.0)
    for i = 1, #iter do
        local e = iter[i]
        if e and e.GetWorldPos then
            local epos = e:GetWorldPos()
            local d2 = dist2(pos, epos)
            if (not System.GetEntitiesInSphere and d2 <= R2) or System.GetEntitiesInSphere then
                local rec = {
                    e        = e,
                    d2       = d2,
                    id       = tostring(e.id or "?"),
                    nm       = tostring((e.GetName and e:GetName()) or "<unnamed>"),
                    cls      = tostring(e.class or ""),
                    hasSoul  = (e.soul ~= nil),
                    hasActor = (e.actor ~= nil),
                    deadFlag = (e.soul and e.soul.IsDead and (pcall(function() return e.soul:IsDead() end) and e.soul:IsDead() or nil)) or
                        (e.actor and e.actor.IsDead and (pcall(function() return e.actor:IsDead() end) and e.actor:IsDead() or nil)) or
                        nil,
                }
                table.insert(list, rec)
            end
        end
    end

    table.sort(list, function(a, b) return a.d2 < b.d2 end)
    local cap = math.min(#list, maxList or 20)
    for i = 1, cap do
        local r = list[i]
        log(string.format("near[%02d] d=%.2fm name=%s class=%s id=%s soul=%s actor=%s dead=%s",
            i, math.sqrt(r.d2), r.nm, r.cls, r.id, tostring(r.hasSoul), tostring(r.hasActor), tostring(r.deadFlag)))
    end
    return list
end

local function isDeadFlag(v) return v == true or v == 1 or v == "1" end

local function resolveLootTarget()
    -- 1) Try soul getters first (if any ever exist)
    local ent, via = trySoulGetters()
    local p = getPlayer()
    if ent and p and ent == p then ent = nil end
    if ent then return ent, via end

    -- 2) Proximity list once
    local list = scanNearbyOnce(CorpseSanitizer.config.proximity.radius, CorpseSanitizer.config.proximity.maxList)
    p = getPlayer()

    -- a) STRICT: dead NPC with soul/actor (exclude player)
    local best, bestD2 = nil, 1e12
    for i = 1, #list do
        local r = list[i]
        if r.e and r.e ~= p and r.hasSoul and r.hasActor and isDeadFlag(r.deadFlag) and (r.cls == "NPC" or r.cls == "Human" or r.cls == "AI") then
            if r.d2 < bestD2 then best, bestD2 = r.e, r.d2 end
        end
    end
    if best then return best, "proximity:deadNPC" end

    -- b) RELAXED: any dead entity with soul/actor (exclude player)
    best, bestD2 = nil, 1e12
    for i = 1, #list do
        local r = list[i]
        if r.e and r.e ~= p and r.hasSoul and r.hasActor and isDeadFlag(r.deadFlag) then
            if r.d2 < bestD2 then best, bestD2 = r.e, r.d2 end
        end
    end
    if best then return best, "proximity:deadActor" end

    -- c) Heuristic: “bandit/cuman” name or class=NPC (exclude player)
    best, bestD2 = nil, 1e12
    for i = 1, #list do
        local r = list[i]
        local lname = r.nm:lower()
        if r.e and r.e ~= p and (r.cls == "NPC" or lname:find("bandit") or lname:find("cuman")) then
            if r.d2 < bestD2 then best, bestD2 = r.e, r.d2 end
        end
    end
    if best then return best, "proximity:heuristic" end

    -- d) Last resort: nearest **non-player** entity
    for i = 1, #list do
        local r = list[i]
        if r.e and r.e ~= p then return r.e, "nearestNonPlayer" end
    end

    return nil, "none"
end

-- UI handlers
function CorpseSanitizer:OnOpened(elementName, instanceId, eventName, args)
    self.ui.active = true
    log("OnOpened → transfer UI visible")

    -- one tick to let context settle
    Script.SetTimer(0, function()
        local ent, via = resolveLootTarget() -- ← resolve ONCE

        if not ent then
            log("Loot target: <none> (no getters, no nearby matches)")
            return
        end

        log(string.format("Loot target: %s (id=%s) via=%s",
            tostring(ent.GetName and ent:GetName() or "<unnamed>"),
            tostring(ent.id or "?"),
            tostring(via)))

        -- Faction/relationship summary (safe even if APIs are missing)
        logFactionSummary(ent, "[FACTION]")
    end)
end

function CorpseSanitizer:OnClosed(elementName, instanceId, eventName, args)
    self.ui.active = false
    log("OnClosed → transfer UI hidden")
end

-- Listener registration (call from Bootstrap)
function CorpseSanitizer.EnableTransferLogging()
    local movie = CorpseSanitizer.config.ui.movie
    if not (UIAction and UIAction.RegisterElementListener) then
        log("UIAction not available; cannot register ItemTransfer listeners")
        return
    end
    UIAction.RegisterElementListener(CorpseSanitizer, movie, -1, "OnOpened", "OnOpened")
    UIAction.RegisterElementListener(CorpseSanitizer, movie, -1, "OnClosed", "OnClosed")
    UIAction.RegisterElementListener(CorpseSanitizer, movie, -1, "OnFocusChanged", "OnFocusChanged")
    log("Registered ItemTransfer listeners")
end

function CorpseSanitizer:OnFocusChanged(elementName, instanceId, eventName, args)
    -- Reduced noise; just record client
    local clientId = args and tonumber(args[4]) or -1
    if clientId and clientId >= 0 then
        log(("OnFocusChanged(client=%d)"):format(clientId))
    end
end

function CorpseSanitizer.Bootstrap()
    if CorpseSanitizer.booted then return end
    CorpseSanitizer.booted = true
    log("BOOT ok (version=" .. CorpseSanitizer.version .. ")")
    CorpseSanitizer.EnableTransferLogging()
end
