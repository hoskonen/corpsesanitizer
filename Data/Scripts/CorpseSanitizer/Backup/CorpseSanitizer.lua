-- Module header: expose ONE global table
CorpseSanitizer = CorpseSanitizer or {
    version = "0.3.0",
    booted  = false,
    ui      = { active = false },
    _loot   = { lastWUID = nil },
}

local CS = CorpseSanitizer

-- 3) Defaults + deep merge (so external config can override selectively)
local DEFAULT_CONFIG = {
    dryRun       = false,
    insanityMode = true,

    ui           = {
        movie        = "ItemTransfer",
        shadowDelete = false, -- set true in external config if you want UI-only purge when engine blocks writes
    },

    proximity    = { radius = 3.0, maxList = 24 },

    nuker        = {
        enabled             = true,
        minHp               = 0.00,
        skipMoney           = true,
        onlyIfCorpse        = false, -- default now allows NPC nukes
        preCorpse           = true,  -- default to pre-corpse sweep
        unequipBeforeDelete = true,
    },

    logging      = {
        prettyOwner     = true,
        probeOnMiss     = true,
        showWouldDelete = true,
        nuker           = true,
    },
}


local function deepMerge(dst, src)
    if type(dst) ~= "table" then dst = {} end
    if type(src) ~= "table" then return dst end
    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k]) == "table" then
            deepMerge(dst[k], v)
        else
            dst[k] = v
        end
    end
    return dst
end

-- 4) Build effective config (defaults first, then previous in-memory cfg, then external file)
CS.config = deepMerge({}, DEFAULT_CONFIG) -- start with defaults
if type(CS._prevCfg) == "table" then
    deepMerge(CS.config, CS._prevCfg)     -- preserve previous overrides across ReloadScript
end
do
    local ok, overrides = pcall(dofile, "Scripts/CorpseSanitizer/CorpseSanitizerConfig.lua")
    if ok and type(overrides) == "table" then deepMerge(CS.config, overrides) end
end
CS._prevCfg = CS.config -- snapshot to survive future ReloadScript calls

-- 5) Small helpers available everywhere below
local function log(msg) System.LogAlways("[CorpseSanitizer] " .. tostring(msg)) end
local function bool(x) return x and "true" or "false" end

local function logEffectiveConfig()
    local c    = CS.config
    local nuk  = c.nuker or {}
    local lg   = c.logging or {}
    local prox = c.proximity or {}
    local ui   = c.ui or {}

    log(string.format(
        "cfg: dryRun=%s | insanityMode=%s | ui.movie=%s | ui.shadowDelete=%s | radius=%.2f | nuker{enabled=%s,minHp=%.2f,skipMoney=%s,onlyIfCorpse=%s} | logging{prettyOwner=%s,probeOnMiss=%s,showWouldDelete=%s,nuker=%s}",
        bool(c.dryRun), bool(c.insanityMode),
        tostring(ui.movie or "?"), bool(ui.shadowDelete),
        tonumber(prox.radius or 0) or 0,
        bool(nuk.enabled), tonumber(nuk.minHp or 0) or 0,
        bool(nuk.skipMoney), bool(nuk.onlyIfCorpse),
        bool(lg.prettyOwner), bool(lg.probeOnMiss), bool(lg.showWouldDelete), bool(lg.nuker)
    ))
end

-- 6) Public: allow in-game reload of external overrides
function CS.ReloadConfig()
    CS._prevCfg = CS.config -- keep current as baseline
    CS.config = deepMerge({}, DEFAULT_CONFIG)
    deepMerge(CS.config, CS._prevCfg)
    local ok, overrides = pcall(dofile, "Scripts/CorpseSanitizer/CorpseSanitizerConfig.lua")
    if ok and type(overrides) == "table" then deepMerge(CS.config, overrides) end
    log("[config] reloaded")
    logEffectiveConfig()
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Utilities
-- ─────────────────────────────────────────────────────────────────────────────
local function getPlayer()
    return System.GetEntityByName("player")
        or System.GetEntityByName("Henry")
        or System.GetEntityByName("dude")
end

local function dist2(a, b)
    local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z; return dx * dx + dy * dy + dz * dz
end

local function scanNearbyOnce(radiusM, _maxList)
    local player = getPlayer(); if not (player and player.GetWorldPos) then return {} end
    local pos  = player:GetWorldPos()
    local iter = System.GetEntitiesInSphere and System.GetEntitiesInSphere(pos, radiusM or 5.0) or System.GetEntities()
    if not iter then return {} end
    local R2 = (radiusM or 5.0) ^ 2
    local list = {}
    for i = 1, #iter do
        local e = iter[i]
        if e and e.GetWorldPos then
            local inside = System.GetEntitiesInSphere or dist2(pos, e:GetWorldPos()) <= R2
            if inside then list[#list + 1] = { e = e, d2 = dist2(pos, e:GetWorldPos()), cls = tostring(e.class or "") } end
        end
    end
    table.sort(list, function(a, b) return a.d2 < b.d2 end)
    return list
end

-- Simple scheduler (Lua 5.1-safe)
local function later(ms, fn)
    if Script and Script.SetTimer then
        Script.SetTimer(ms, fn)
    else
        local ok, err = pcall(fn)
        if not ok then System.LogAlways("[CorpseSanitizer] later() error: " .. tostring(err)) end
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Engine plumbing: WUID/Owner helpers
-- ─────────────────────────────────────────────────────────────────────────────
local function getEntityWuid(ent)
    if XGenAIModule and type(XGenAIModule.GetMyWUID) == "function" and ent then
        local ok, w = pcall(function() return XGenAIModule.GetMyWUID(ent) end)
        if ok and w then return w end
    end
    return nil
end

local function getInventoryOwner(wuid)
    if XGenAIModule and type(XGenAIModule.GetOwner) == "function" and wuid then
        local ok, owner = pcall(function() return XGenAIModule.GetOwner(wuid) end)
        if ok and owner then return owner end
    end
    return nil
end

local function prettyOwner(ownerWuid, victim)
    if not ownerWuid or tostring(ownerWuid) == "userdata: 0000000000000000" then
        return "none/unknown"
    end
    local vw = victim and getEntityWuid and getEntityWuid(victim)
    if vw and ownerWuid == vw then return "victim" end
    local p = getPlayer()
    local pw = p and getEntityWuid and getEntityWuid(p)
    if pw and ownerWuid == pw then return "player" end
    return tostring(ownerWuid)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Corpse/NPC inspection + stash resolution
-- ─────────────────────────────────────────────────────────────────────────────
local function isEntityDead(e)
    if not e then return false end
    if e.actor and type(e.actor.IsDead) == "function" then
        local ok, res = pcall(e.actor.IsDead, e.actor)
        if ok and res then return true end
    end
    if type(e.GetHealth) == "function" then
        local ok, h = pcall(e.GetHealth, e)
        if ok and type(h) == "number" and h <= 0 then return true end
    end
    return false
end

local function isCorpseEntity(e)
    if not e then return false end
    local cls = tostring(e.class or "")
    if cls == "DeadBody_Human" or cls == "DeadBody_Base_Human"
        or cls == "SO_DeadBody_Human" or cls == "SO_DeadBody_Human_Interactable" then
        return true
    end
    if cls:find("DeadBody", 1, true) ~= nil then return true end
    -- Treat dead NPCs as 'corpse-like' for our purposes (bosses may stay NPC class)
    if isEntityDead(e) then return true end
    return false
end

local function findNearestCorpse(radius)
    local list = scanNearbyOnce(radius or 5.0, 48)
    local player = getPlayer()
    local best, bestD2
    for i = 1, #list do
        local r = list[i]; local e = r.e
        if e and e ~= player and isCorpseEntity(e) then
            if not best or r.d2 < bestD2 then best, bestD2 = e, r.d2 end
        end
    end
    return best, best and math.sqrt(bestD2 or 0) or nil
end

local function getCandidateWuidForOwnership(e)
    local w = getEntityWuid(e); if w then return w, "entityWuid" end
    if type(e.GetInventoryToOpen) == "function" then
        local ok, w2 = pcall(function() return e:GetInventoryToOpen() end)
        if ok and w2 then return w2, "GetInventoryToOpen()" end
    end
    if e.inventoryId and e.inventoryId ~= 0 then return e.inventoryId, "inventoryId" end
    if e.stash and type(e.stash.GetMasterInventory) == "function" then
        local ok, w3 = pcall(function() return e.stash:GetMasterInventory() end)
        if ok and w3 then return w3, "stash:GetMasterInventory()" end
    end
    return nil, "noWuid"
end

local function resolveCorpseContainer(victim, searchRadius)
    local list = scanNearbyOnce(searchRadius or 6.0, 32)
    local vpos = victim and victim.GetWorldPos and victim:GetWorldPos()
    local best, bestD2
    for i = 1, #list do
        local r = list[i]
        if r.cls == "StashCorpse" then
            if victim and vpos and r.e.GetWorldPos then
                local d2 = dist2(vpos, r.e:GetWorldPos())
                if not best or d2 < bestD2 then best, bestD2 = r.e, d2 end
            else
                if not best or r.d2 < bestD2 then best, bestD2 = r.e, r.d2 end
            end
        end
    end
    if best then return best, "StashCorpse" end

    if victim and vpos then
        local nearestStash, d2s
        for i = 1, #list do
            local r = list[i]
            if r.cls == "Stash" and r.e.GetWorldPos then
                local d2 = dist2(vpos, r.e:GetWorldPos())
                if not nearestStash or d2 < d2s then nearestStash, d2s = r.e, d2 end
            end
        end
        if nearestStash and math.sqrt(d2s) <= 2.0 then
            return nearestStash, "Stash(victim-adjacent)"
        end
    end
    return nil
end

local function resolveCorpseContainerViaOwnership(victim, radius)
    if not victim then return nil, "noVictim" end
    local victimWuid = getEntityWuid(victim)
    if not victimWuid then return nil, "noVictimWuid" end

    local list = scanNearbyOnce(radius or 8.0, 64)
    for i = 1, #list do
        local r = list[i]; local e = r.e
        if e and (e.class == "StashCorpse" or e.class == "Stash" or isCorpseEntity(e)
                or e.GetInventoryToOpen or e.inventoryId or e.stash or e.container or e.inventory) then
            local swuid, via = getCandidateWuidForOwnership(e)
            if swuid then
                local owner = getInventoryOwner(swuid)
                if owner and owner == victimWuid then
                    return e, "ownerMatch:" .. tostring(via)
                end
            end
        end
    end
    return nil, "noOwnerMatch"
end

-- Try to unequip a handle before deletion
local function TryUnequip(subject, ownerWuid, handle)
    if not handle then return false end
    local lanes = {
        { "Inventory",    "UnequipItem" }, { "Inventory", "UnEquipItem" },
        { "EntityModule", "UnequipItem" }, { "EntityModule", "UnEquipItem" },
        { "Equipment", "UnequipItem" }, { "EquipmentModule", "UnequipItem" },
    }
    for i = 1, #lanes do
        local M, fn = _G[lanes[i][1]], lanes[i][2]
        if M and type(M[fn]) == "function" and ownerWuid then
            local ok = pcall(M[fn], ownerWuid, handle)
            if ok then return true, lanes[i][1] .. "." .. fn end
        end
    end
    -- component-level fallbacks
    for _, compName in ipairs({ "inventory", "container", "stash" }) do
        local comp = subject and subject[compName]
        if type(comp) == "table" then
            for _, fn in ipairs({ "Unequip", "UnEquip", "UnequipItem", "UnEquipItem" }) do
                if type(comp[fn]) == "function" then
                    local ok = pcall(comp[fn], comp, handle)
                    if ok then return true, "subject." .. compName .. ":" .. fn end
                end
            end
        end
    end
    return false
end

local function isHostileToPlayer(e)
    local p = getPlayer()
    if not e or not p then return false end

    -- common direct methods
    for _, fn in ipairs({ "IsHostileTo", "IsHostile", "IsEnemyTo", "IsEnemy", "IsAggressiveTo" }) do
        local f = e[fn]
        if type(f) == "function" then
            local ok, res = pcall(f, e, p)
            if ok and res then return true end
        end
    end

    -- faction-based fallback (treat different factions as hostile if wanted)
    local ef, pf
    if e.GetFaction then
        local ok, v = pcall(e.GetFaction, e); if ok then ef = v end
    end
    if p.GetFaction then
        local ok, v = pcall(p.GetFaction, p); if ok then pf = v end
    end
    if ef and pf and ef ~= pf then
        if CS.config and CS.config.nuker and CS.config.nuker.hostileIfDifferentFaction ~= false then
            return true
        end
    end

    -- “recently damaged by player” style APIs (if present)
    if e.WasRecentlyDamagedByPlayer and type(e.WasRecentlyDamagedByPlayer) == "function" then
        local ok, res = pcall(e.WasRecentlyDamagedByPlayer, e, 3.0) -- last 3s
        if ok and res then return true end
    end

    return false
end

local function classifyVictim(e)
    local nm = "<entity>"; if e and e.GetName then pcall(function() nm = e:GetName() end) end
    local s = string.lower(tostring(nm))
    local isAnimal = s:find("dog", 1, true) or s:find("boar", 1, true) or s:find("deer", 1, true)
        or s:find("rabbit", 1, true) or s:find("wolf", 1, true)
    return (not not isAnimal), (not isAnimal)
end

-- case-insensitive ban check
local function isBannedByConfig(name, classId)
    local cfg = CS and CS.config and CS.config.nuker
    if not cfg then return false end
    local bN, bC = cfg.banNames or {}, cfg.banClasses or {}
    local n = string.lower(tostring(name or ""))
    local c = string.lower(tostring(classId or ""))

    for i = 1, #bN do
        if n == string.lower(tostring(bN[i])) then return true end
    end
    for i = 1, #bC do
        if c == string.lower(tostring(bC[i])) then return true end
    end
    return false
end

local function lower_eq(a, b) return string.lower(tostring(a or "")) == string.lower(tostring(b or "")) end

-- ─────────────────────────────────────────────────────────────────────────────
-- Item enumeration (read-only) + pretty logging
-- ─────────────────────────────────────────────────────────────────────────────
local function resolveItemEntry(entry)
    if ItemManager and ItemManager.GetItem and type(entry) == "userdata" then
        local ok, it = pcall(ItemManager.GetItem, entry); if ok and it then return it end
    end
    if type(entry) == "table" and (entry.class or entry.Class or entry.id or entry.Id) then return entry end
    return nil
end

-- Try to resolve item owner from an entry that might be a handle or table
local function resolveItemOwner(entry)
    if type(entry) == "userdata" and ItemManager and ItemManager.GetItemOwner then
        local ok, w = pcall(ItemManager.GetItemOwner, entry)
        if ok and w then return w, "ItemManager.GetItemOwner(handle)" end
    end
    if type(entry) == "table" then
        if entry.owner or entry.Owner then
            return entry.owner or entry.Owner, "entry.owner"
        end
        if entry.GetLinkedOwner and type(entry.GetLinkedOwner) == "function" then
            local ok2, w2 = pcall(entry.GetLinkedOwner, entry)
            if ok2 and w2 then return w2, "item:GetLinkedOwner()" end
        end
    end
    return nil, "none"
end

local function getItemOwnerWuid(entry)
    if type(entry) == "userdata" and ItemManager and ItemManager.GetItemOwner then
        local ok, w = pcall(ItemManager.GetItemOwner, entry); if ok and w then
            return w, "ItemManager.GetItemOwner(handle)"
        end
    end
    if type(entry) == "table" and ItemManager and ItemManager.GetItemOwner then
        local id = entry.id or entry.Id
        if id then
            local ok, w = pcall(ItemManager.GetItemOwner, id); if ok and w then
                return w, "ItemManager.GetItemOwner(row.id)"
            end
        end
        if type(entry.GetLinkedOwner) == "function" then
            local ok, w = pcall(function() return entry:GetLinkedOwner() end); if ok and w then
                return w, "item:GetLinkedOwner()"
            end
        end
    end
    return nil, nil
end

local function getItemSummary(it)
    if not it then return "class=?", "hp=?", "amt=?" end
    local class = tostring(it.class or it.Class or it.id or it.Id or "?")
    local nm = ItemManager and ItemManager.GetItemName and ItemManager.GetItemName(it.class or it.Class)
    if nm then class = class .. " (" .. tostring(nm) .. ")" end
    local rawHp = it.health or it.Health or it.cond
    if rawHp and rawHp > 1.001 then rawHp = rawHp / 100 end
    local hp  = rawHp and string.format("%.2f", math.max(0, math.min(1, rawHp))) or "?"
    local amt = tonumber(it.amount or it.Amount or 1) or 1
    return class, hp, tostring(amt)
end

local function logItemsTable(items, how, cap, prettyNpc)
    cap = cap or 20
    local keys = {}; for k in pairs(items) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        local ta, tb = type(a), type(b)
        if ta == "number" and tb == "number" then return a < b end
        if ta == "number" then return true end
        if tb == "number" then return false end
        return tostring(a) < tostring(b)
    end)
    local shown = 0
    for _, k in ipairs(keys) do
        local row                 = items[k]
        local it                  = resolveItemEntry(row)
        local class, hp, amt      = getItemSummary(it)

        local ownerWuid, ownerVia = resolveItemOwner(row)
        local ownerText           = ownerWuid and prettyOwner(ownerWuid, prettyNpc) or "none/unknown"
        log(string.format("  [%s] class=%s hp=%s amt=%s owner=%s %s",
            tostring(k), class, hp, tostring(amt), ownerText, ownerVia or ""))

        shown = shown + 1
        if shown >= cap then break end
    end
    log("Enumerator used: " .. tostring(how) .. string.format(" (raw keys walked, %d entries shown)", shown))
end

-- Minimal neighborhood probe (used when stash wasn’t found)
local function probeNearVictim(victim, radius)
    local vpos = victim and victim.GetWorldPos and victim:GetWorldPos()
    local list = scanNearbyOnce(radius or 12.0, 80)
    local shown = 0
    for i = 1, #list do
        local e = list[i].e
        if e and (e.class == "StashCorpse" or e.class == "Stash" or e.GetInventoryToOpen or e.inventoryId or e.stash or e.container or e.inventory) then
            local via = {}
            if type(e.GetInventoryToOpen) == "function" then via[#via + 1] = "GetInventoryToOpen" end
            if e.inventoryId and e.inventoryId ~= 0 then via[#via + 1] = "invId" end
            if e.stash then via[#via + 1] = "stash" end
            if e.container then via[#via + 1] = "container" end
            if e.inventory then via[#via + 1] = "inventory" end
            local wuid = getEntityWuid(e)
            local owner = wuid and getInventoryOwner(wuid)
            local d = vpos and e.GetWorldPos and math.sqrt(dist2(vpos, e:GetWorldPos())) or math.sqrt(list[i].d2)

            log(("[PROBE] name=%s class=%s d=%.2fm via=%s wuid=%s owner=%s")
                :format(tostring(e.GetName and e:GetName() or "<unnamed>"),
                    tostring(e.class or "?"), d, table.concat(via, "+"),
                    tostring(wuid), owner and prettyOwner(owner) or "none/unknown"))
            shown = shown + 1
            if shown >= 8 then break end
        end
    end
    if shown == 0 then log("[PROBE] No inventory-capable neighbors") end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Stash/NPC enumeration lanes (kept from earlier)
-- ─────────────────────────────────────────────────────────────────────────────
local function enumNPCInventory(npc)
    if not npc then return nil, "noNPC" end
    local inv = npc.inventory or npc.container or npc.stash
    if inv and type(inv.GetInventoryTable) == "function" then
        local ok, t = pcall(function() return inv:GetInventoryTable(inv) end)
        if ok and type(t) == "table" then return t, "inventory:GetInventoryTable" end
    end
    local w = getEntityWuid(npc)
    if w then
        local lanes = {
            { mod = "Inventory",       fn = "GetInventoryTable" },
            { mod = "Inventory",       fn = "GetItems" },
            { mod = "InventoryModule", fn = "GetInventoryTable" },
            { mod = "InventoryModule", fn = "GetInventoryItems" },
            { mod = "EntityModule",    fn = "GetInventoryTable" },
            { mod = "EntityModule",    fn = "GetInventoryItems" },
            { mod = "XGenAIModule",    fn = "GetInventoryItems" },
        }
        for _, L in ipairs(lanes) do
            local M = _G[L.mod]
            if M and type(M[L.fn]) == "function" then
                local ok, t = pcall(function() return M[L.fn](w) end)
                if ok and type(t) == "table" then return t, L.mod .. "." .. L.fn .. "(npcWUID)" end
            end
        end
    end
    return nil, "noEnumLane"
end

local function tryEnumerateDirectOnEntity(ent)
    if not ent then return nil, "no-entity" end
    for _, comp in ipairs({ "inventory", "container", "stash" }) do
        local c = ent[comp]
        if type(c) == "table" then
            for _, m in ipairs({ "GetInventoryTable", "GetItems", "GetAllItems" }) do
                if type(c[m]) == "function" then
                    local ok, items = pcall(function() return c[m](c) end)
                    if ok and type(items) == "table" then
                        log(string.format("Direct: %s:%s → table(#%d)", comp, m, #items))
                        return items, comp .. ":" .. m
                    end
                end
            end
        end
    end
    return nil, "noDirectLane"
end

local function tryEnumerateByWuid(stashEntOrNpc, wuid)
    if EntityModule and wuid then
        local ok1, owner = pcall(function() return EntityModule.GetInventoryOwner(wuid) end)
        if ok1 then log("WUID owner = " .. tostring(owner)) end
        local ok2, canUse = pcall(function() return EntityModule.CanUseInventory(wuid) end)
        if ok2 then log("CanUseInventory = " .. tostring(canUse)) end
    end

    local function tryStashField(field)
        local obj = stashEntOrNpc and stashEntOrNpc[field]
        if obj and type(obj) == "table" then
            for _, m in ipairs({ "GetInventoryTable", "GetAllItems", "GetItems" }) do
                if type(obj[m]) == "function" then
                    local ok, t = pcall(function() return obj[m](obj) end)
                    if ok and type(t) == "table" then
                        log(("stash.%s:%s → table size=%s"):format(field, m, tostring(#t)))
                        return t, ("stash.%s:%s"):format(field, m)
                    end
                end
            end
        end
    end
    for _, f in ipairs({ "inventory", "container", "stash" }) do
        local t, how = tryStashField(f); if t then return t, how end
    end

    local lanes = {
        { mod = "Inventory",       fns = { "GetItems", "GetItemsForInventory", "GetInventoryTable" } },
        { mod = "InventoryModule", fns = { "GetItems", "GetInventoryItems", "GetInventoryTable" } },
        { mod = "XGenAIModule",    fns = { "GetInventoryItems" } },
        { mod = "EntityModule",    fns = { "GetInventoryItems", "GetInventoryTable" } },
    }
    for _, lane in ipairs(lanes) do
        local M = _G[lane.mod]
        if M and wuid then
            for _, fn in ipairs(lane.fns) do
                if type(M[fn]) == "function" then
                    local ok, res = pcall(function() return M[fn](wuid) end)
                    if ok and type(res) == "table" then
                        log(("[%s].%s(wuid) → table size=%s"):format(lane.mod, fn, tostring(#res)))
                        return res, lane.mod .. "." .. fn .. "(wuid)"
                    end
                end
            end
        end
    end
    log("No item enumeration method succeeded for this WUID (read-only).")
    return nil, "none"
end

local function getStashInventoryWuid(stashEnt)
    if not stashEnt then return nil, "noStash" end
    if type(stashEnt.GetInventoryToOpen) == "function" then
        local ok, w = pcall(function() return stashEnt:GetInventoryToOpen() end)
        if ok and w then return w, "GetInventoryToOpen()" end
    end
    if stashEnt.inventoryId and stashEnt.inventoryId ~= 0 then return stashEnt.inventoryId, "inventoryId field" end
    if stashEnt.stash and type(stashEnt.stash.GetMasterInventory) == "function" then
        local ok, w = pcall(function() return stashEnt.stash:GetMasterInventory() end)
        if ok and w then return w, "stash:GetMasterInventory()" end
    end
    return nil, "noWuid"
end

-- ─────────────────────────────────────────────────────────────────────────────
-- UI refresh broker for ItemTransfer.gfx
-- ─────────────────────────────────────────────────────────────────────────────
local UIRefresh = {
    movie = "ItemTransfer",
    tried = false,
    ok    = {},
}

local function ui_call(movie, pathOrFn, maybeFn, ...)
    if not (UIAction and UIAction.CallFunction) then return false end
    local ok = false
    -- try 3-seg (movie, path, fn)
    if maybeFn then ok = pcall(UIAction.CallFunction, movie, pathOrFn, maybeFn, ...) or ok end
    -- try 2-seg (movie, fn)
    ok = pcall(UIAction.CallFunction, movie, pathOrFn, ...) or ok
    return ok
end

local function ui_try(path, fn, ...)
    local sig2 = path .. "::" .. (fn or "<root>")
    local worked = ui_call(UIRefresh.movie, path, fn, ...)
    if worked then
        UIRefresh.ok[sig2] = true; System.LogAlways("[CorpseSanitizer/UI] OK " .. sig2)
    end
    return worked
end

function UIRefresh:Probe()
    if self.tried then return end
    self.tried = true
    local paths = { "ItemTransfer", "ApseInventoryList", "InventoryView" }
    local tries = {
        { "ClearItems" }, { "Clear" }, { "InvalidateData" },
        { "OnViewChanged", 0 }, { "OnViewChanged", 1 },
        { "RequestData" }, { "RefreshData" }, { "ForceRefresh" }, { "Update" },
    }
    for i = 1, #paths do
        for j = 1, #tries do
            local fn = tries[j][1]
            if tries[j][2] == nil then ui_try(paths[i], fn) else ui_try(paths[i], fn, tries[j][2]) end
        end
    end
    -- Also test event path for OnViewChanged
    if UIAction and UIAction.SendEvent then
        pcall(UIAction.SendEvent, self.movie, "OnViewChanged", { 0 })
        pcall(UIAction.SendEvent, self.movie, "OnViewChanged", { 1 })
    end
end

function UIRefresh:Refresh() end

local function ui_remove_row(idStr) end

-- helper used when we capture handles
local function uiIdFromHandle(h)
    return (tostring(h):gsub("^userdata:%s*", ""))
end

local function uiIdFromRow(row)
    if type(row) == "userdata" then return uiIdFromHandle(row) end
    if type(row) == "table" then
        local id = row.id or row.Id or row.stackId or row.StackId or row.handle or row.Handle
        if id ~= nil then return tostring(id) end
    end
    return nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Delete lanes
-- ─────────────────────────────────────────────────────────────────────────────
-- Low-level delete lanes: NO unequip and NO recursion here.
-- Returns: success:boolean, via:string, attempts:number
local function tryDeleteForSubject(subject, handle, class, count)
    count = (count ~= nil) and count or -1

    local function call_success(ok, ret)
        if not ok then return false end
        local t = type(ret)
        if t == "boolean" then
            return ret
        elseif t == "number" then
            return ret ~= 0
        else
            return true -- many engine funcs return nil on success
        end
    end

    local function try_variants(target, fname, variants, isMethod)
        local f = target and target[fname]
        if type(f) ~= "function" then return false, nil, 0 end
        for i = 1, #variants do
            local args = variants[i]
            local ok, ret
            if isMethod then
                ok, ret = pcall(f, target, unpack(args))
            else
                ok, ret = pcall(f, unpack(args))
            end
            if call_success(ok, ret) then
                local arglist = {}
                for j = 1, #args do arglist[j] = tostring(args[j]) end
                return true, string.format("%s(%s)", fname, table.concat(arglist, ",")), i
            end
        end
        return false, nil, #variants
    end

    local attempts = 0

    -- 1) subject component-local lanes
    for _, compName in ipairs({ "inventory", "container", "stash" }) do
        local comp = subject and subject[compName]
        if type(comp) == "table" then
            if handle ~= nil then
                local fnames = { "DeleteItem", "RemoveItem", "DeleteItemById", "RemoveItemById", "DeleteById",
                    "RemoveById", "DeleteStack", "RemoveStack" }
                local variants = { { handle, count }, { handle } }
                for _, fn in ipairs(fnames) do
                    local okc, via = try_variants(comp, fn, variants, true)
                    attempts = attempts + #variants
                    if okc then return true, ("subject.%s:%s"):format(compName, via), attempts end
                end
            end
            if class ~= nil then
                local fnamesC = { "DeleteItemOfClass", "RemoveItemOfClass", "DeleteClass", "RemoveClass", "DeleteByClass",
                    "RemoveByClass" }
                local variantsC = { { tostring(class), count }, { tostring(class) } }
                for _, fn in ipairs(fnamesC) do
                    local okc, via = try_variants(comp, fn, variantsC, true)
                    attempts = attempts + #variantsC
                    if okc then return true, ("subject.%s:%s"):format(compName, via), attempts end
                end
            end
        end
    end

    -- 2) owner/WUID-aware modules
    local ownerWuid
    if handle and ItemManager and ItemManager.GetItemOwner then
        local ok, w = pcall(ItemManager.GetItemOwner, handle)
        if ok and w then ownerWuid = w end
    end
    if not ownerWuid and subject then ownerWuid = getEntityWuid(subject) end

    local moduleSets = {
        { mod = "EntityModule",    H = { "DeleteItem", "RemoveItem", "Delete", "Remove", "DeleteById", "RemoveById" }, C = { "DeleteItemOfClass", "RemoveItemOfClass", "DeleteClass", "RemoveClass", "DeleteByClass", "RemoveByClass" } },
        { mod = "InventoryModule", H = { "DeleteItem", "RemoveItem", "Delete", "Remove", "DeleteById", "RemoveById" }, C = { "DeleteItemOfClass", "RemoveItemOfClass", "DeleteClass", "RemoveClass", "DeleteByClass", "RemoveByClass" } },
        { mod = "XGenAIModule",    H = { "DeleteItem", "RemoveItem", "Delete", "Remove", "DeleteById", "RemoveById" }, C = { "DeleteItemOfClass", "RemoveItemOfClass", "DeleteClass", "RemoveClass", "DeleteByClass", "RemoveByClass" } },
        { mod = "Inventory",       H = { "DeleteItem", "RemoveItem", "Delete", "Remove", "DeleteById", "RemoveById" }, C = { "DeleteItemOfClass", "RemoveItemOfClass", "DeleteClass", "RemoveClass" } },
    }

    if ownerWuid then
        for _, set in ipairs(moduleSets) do
            local M = _G[set.mod]
            if M then
                if handle ~= nil then
                    local variantsH = { { ownerWuid, handle, count }, { ownerWuid, handle } }
                    for _, fn in ipairs(set.H) do
                        if type(M[fn]) == "function" then
                            local okm, via = try_variants(M, fn, variantsH, false)
                            attempts = attempts + #variantsH
                            if okm then return true, ("%s.%s"):format(set.mod, via), attempts end
                        end
                    end
                end
                if class ~= nil then
                    local variantsC = { { ownerWuid, tostring(class), count }, { ownerWuid, tostring(class) } }
                    for _, fn in ipairs(set.C) do
                        if type(M[fn]) == "function" then
                            local okm, via = try_variants(M, fn, variantsC, false)
                            attempts = attempts + #variantsC
                            if okm then return true, ("%s.%s"):format(set.mod, via), attempts end
                        end
                    end
                end
            end
        end
    end

    -- 3) global Inventory.* last resort (no owner)
    if Inventory then
        if handle then
            local variantsIH = { { handle, count }, { handle } }
            for _, fn in ipairs({ "DeleteItem", "RemoveItem", "DeleteById", "RemoveById", "DeleteStack", "RemoveStack" }) do
                if type(Inventory[fn]) == "function" then
                    local okI, via = try_variants(Inventory, fn, variantsIH, false)
                    attempts = attempts + #variantsIH
                    if okI then return true, ("Inventory.%s"):format(via), attempts end
                end
            end
        end
        if class then
            local variantsIC = { { tostring(class), count }, { tostring(class) } }
            for _, fn in ipairs({ "DeleteItemOfClass", "RemoveItemOfClass", "DeleteClass", "RemoveClass" }) do
                if type(Inventory[fn]) == "function" then
                    local okI, via = try_variants(Inventory, fn, variantsIC, false)
                    attempts = attempts + #variantsIC
                    if okI then return true, ("Inventory.%s"):format(via), attempts end
                end
            end
        end
    end

    return false, "no-lane-succeeded", attempts
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Nuker with verification + UI fallback
-- ─────────────────────────────────────────────────────────────────────────────
local function countKeys(t)
    local n = 0; for _ in pairs(t or {}) do n = n + 1 end; return n
end

local function enumSubject(subject)
    -- prefer local inventory component
    local inv = subject and (subject.inventory or subject.container or subject.stash)
    if inv and type(inv.GetInventoryTable) == "function" then
        local ok, t = pcall(function() return inv:GetInventoryTable(inv) end)
        if ok and type(t) == "table" then return t, "inventory:GetInventoryTable" end
    end
    -- fallback to WUID/module lanes
    return enumNPCInventory(subject)
end

local function nukerLog(msg)
    if CS.config and CS.config.logging and CS.config.logging.nuker then
        System.LogAlways("[CorpseSanitizer/Nuke] " .. tostring(msg))
    end
end

local function nukeNpcInventory(subject, ctx)
    ctx       = ctx or {}
    local C   = CS.config or {}
    local N   = (C.nuker or {})
    local dry = C.dryRun and true or false
    local tag = dry and "[nuke][dry]" or "[nuke]"

    if not N.enabled then
        nukerLog(tag .. " abort (nuker.enabled=false)"); return
    end
    if not subject then
        nukerLog(tag .. " abort (no subject)"); return
    end

    local isCorpse   = subject and isCorpseEntity(subject) or false
    local allowByCtx = ctx.corpseCtx == true
    if N.onlyIfCorpse and not (isCorpse or allowByCtx) then
        nukerLog(tag .. " abort (onlyIfCorpse=true, no corpseCtx)"); return
    end

    local subjectWuid = getEntityWuid and getEntityWuid(subject) or nil
    if not subjectWuid then
        nukerLog(tag .. " abort (no subject WUID)"); return
    end

    -- acquire items if not provided
    local items, how = ctx.items, "prelisted"
    if type(items) ~= "table" then items, how = enumSubject(subject) end
    if type(items) ~= "table" then
        nukerLog(tag .. " abort (no enumerable inventory)"); return
    end

    -- snapshot BEFORE
    local beforeCount = countKeys(items)
    nukerLog(("Before: %d items (via=%s)"):format(beforeCount, tostring(how)))
    if beforeCount == 0 then
        UIRefresh.movie = (C.ui and C.ui.movie) or "ItemTransfer"; UIRefresh:Refresh(); return true
    end

    -- deterministic key walk
    local keys = {}; for k in pairs(items) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        local na, nb = type(a) == "number", type(b) == "number"
        if na and nb then return a < b end
        if na then return true end
        if nb then return false end
        return tostring(a) < tostring(b)
    end)

    local deleted, kept = 0, 0
    local removedIds = {}
    local uiIds = {}

    for _, k in ipairs(keys) do
        repeat
            local row    = items[k]
            local it     = resolveItemEntry(row) -- may be nil
            local class  = (it and (it.class or it.Class)) or (row and (row.class or row.Class))
            local handle = (type(row) == "userdata") and row
                or (type(row) == "table" and (row.id or row.Id or row.handle or row.Handle))
                or nil

            -- Resolve pretty name (from classId) for banlist checks
            local name   = nil
            if class and ItemManager and ItemManager.GetItemName then
                local okNm, nm = pcall(ItemManager.GetItemName, tostring(class))
                if okNm and nm and nm ~= "" then name = nm end
            end
            name = name or class or "?"

            -- Normalize HP here (used by minHp)
            local hp
            if it then
                hp = it.health or it.Health or it.cond
            end
            if type(hp) == "number" and hp > 1.001 and hp <= 100 then hp = hp / 100 end
            hp = hp or 1.0

            -- Money guard (more general than the single GUID)
            local isMoney = false
            if N.skipMoney then
                isMoney = lower_eq(name, "money") or lower_eq(class, "money")
                    or tostring(class) == "5ef63059-322e-4e1b-abe8-926e100c770e" -- keep your known GUID
            end
            if isMoney then
                kept = kept + 1; break
            end

            -- HP threshold (if configured)
            if N.minHp and hp < N.minHp then
                kept = kept + 1; break
            end

            -- Banlist (names or class GUIDs; case-insensitive)
            local banned = isBannedByConfig(name, class)
            if not banned then
                kept = kept + 1; break
            end


            -- owner must match the victim if provided
            if handle and ItemManager and ItemManager.GetItemOwner and ctx.victim then
                local okO, owner = pcall(ItemManager.GetItemOwner, handle)
                if okO and owner then
                    local vW = getEntityWuid(ctx.victim)
                    if vW and owner ~= vW then
                        kept = kept + 1; break
                    end
                end
            end

            -- delete phase
            local deletedThis = false
            if dry then
                nukerLog(string.format("%s Would delete %s (%s)", tag, tostring(class or "?"), tostring(handle)))
                deleted = deleted + 1
                deletedThis = true
            else
                local okDel, via, attemptsTried = tryDeleteForSubject(subject, handle, class, -1)

                if (not okDel) and (N.unequipBeforeDelete and handle) then
                    local ownerWuid
                    if ItemManager and ItemManager.GetItemOwner then
                        local okO, w = pcall(ItemManager.GetItemOwner, handle)
                        if okO and w then ownerWuid = w end
                    end
                    if not ownerWuid and subject then ownerWuid = getEntityWuid(subject) end

                    if ownerWuid then
                        local unOk, unVia = TryUnequip(subject, ownerWuid, handle)
                        if unOk then
                            okDel, via, attemptsTried = tryDeleteForSubject(subject, handle, class, -1)
                            if okDel then
                                nukerLog(string.format("[nuke] unequipped via %s → delete via %s",
                                    tostring(unVia), tostring(via)))
                            end
                        end
                    end
                end

                if okDel then
                    deletedThis = true
                    deleted = deleted + 1
                    if handle then removedIds[#removedIds + 1] = uiIdFromHandle(handle) end
                    nukerLog(string.format("%s deleted class=%s handle=%s via %s (lanesTried=%s)",
                        tag, tostring(class), tostring(handle), tostring(via), tostring(attemptsTried)))
                end
            end

            -- Always stash a UI id candidate for shadow delete
            do
                local uiid = uiIdFromRow(row)
                if uiid then uiIds[#uiIds + 1] = uiid end
            end

            if not deletedThis then
                kept = kept + 1
                if not dry then
                    nukerLog(string.format("%s delete failed for class=%s handle=%s", tag, tostring(class),
                        tostring(handle)))
                end
            end
        until true
    end

    -- immediate re-enum
    local itemsAfter0, howAfter0 = enumSubject(subject)
    local after0 = countKeys(itemsAfter0 or {})
    nukerLog(("After0: %d items (via=%s)"):format(after0, tostring(howAfter0)))

    local function finalize(reason)
        UIRefresh.movie = (C.ui and C.ui.movie) or "ItemTransfer"
        UIRefresh:Refresh()
        nukerLog("UI refresh reason: " .. tostring(reason))
        nukerLog(string.format("%s summary: deleted=%d kept=%d dry=%s (via=%s, subject=%s)",
            tag, deleted, kept, tostring(dry), how,
            tostring(subject.class or (subject.GetName and subject:GetName()) or "entity")))
    end

    if after0 == beforeCount and deleted > 0 then
        later(50, function()
            local itemsAfter1 = select(1, enumSubject(subject))
            local after1 = countKeys(itemsAfter1 or {})
            nukerLog(("After1(+50ms): %d items"):format(after1))

            if after1 < beforeCount then
                finalize("engine mutated after delay")
                return
            end

            if after1 < beforeCount then
                finalize("engine mutated after delay")
                return
            end

            if (C.ui and C.ui.shadowDelete) and #uiIds > 0 then
                for i = 1, #uiIds do ui_remove_row(uiIds[i]) end
                finalize("shadow delete (engine read-only?)")
            else
                finalize("no engine change; just forced refresh")
            end
        end)
        return true
    end

    if (after0 < beforeCount) or (deleted > 0) then
        finalize("engine changed immediately or best-effort")
    else
        if (C.ui and C.ui.shadowDelete) and #uiIds > 0 then
            for i = 1, #uiIds do ui_remove_row(uiIds[i]) end
            finalize("shadow delete (engine refused)")
        else
            finalize("nothing changed; forced refresh anyway")
        end
    end

    return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- UI handlers
-- ─────────────────────────────────────────────────────────────────────────────
function CorpseSanitizer:OnOpened(elementName, instanceId, eventName, args)
    self.ui.active = true
    log(("OnOpened → transfer UI visible (element=%s, instance=%s)"):format(tostring(elementName), tostring(instanceId)))

    later(150, function()
        local corpseNearby = select(1, findNearestCorpse((CS.config.proximity and CS.config.proximity.radius) or 6.0))
        if not corpseNearby then
            System.LogAlways("[CorpseSanitizer/Nuke] pre-corpse skipped (no corpse nearby)")
            return
        end

        ----------------------------------------------------------------
        -- 2C: PRE-CORPSE SWEEP (engine-side; no SWF writes)
        ----------------------------------------------------------------
        -- PRE-CORPSE SWEEP (engine-side; no SWF writes)
        if CS and CS.config and CS.config.nuker
            and CS.config.nuker.enabled
            and CS.config.nuker.preCorpse
            and (not CS.config.nuker.onlyIfCorpse) then
            local corpseNearby = select(1, findNearestCorpse((CS.config.proximity and CS.config.proximity.radius) or 6.0))
            if not corpseNearby then
                System.LogAlways("[CorpseSanitizer/Nuke] pre-corpse skipped (no corpse nearby)")
            else
                local list  = scanNearbyOnce((CS.config.proximity and CS.config.proximity.radius) or 6.0, 24)
                local m     = (CS.config.nuker and CS.config.nuker.preCorpseMaxMeters) or 1.5
                local maxD2 = m * m
                local tgt   = (CS.config.nuker and CS.config.nuker.target) or { animals = true, humans = true }

                -- pick the nearest writable NPC that passes target + hostility gates
                local npcWritable
                for i = 1, #list do
                    local e  = list[i].e
                    local d2 = list[i].d2 or 1e9
                    if d2 <= maxD2 and e and e ~= getPlayer() and not isCorpseEntity(e)
                        and (e.inventory or e.container or e.stash) then
                        local isAnimal, isHuman = classifyVictim(e)
                        if ((isAnimal and tgt.animals) or (isHuman and tgt.humans))
                            and (not (CS.config.nuker.onlyHostile or false) or isHostileToPlayer(e)) then
                            npcWritable = e
                            break
                        end
                    end
                end

                if npcWritable then
                    local delays = (CS.config.nuker and CS.config.nuker.doublePassDelays) or { 0, 120 }
                    for _, ms in ipairs(delays) do
                        later(ms, function()
                            pcall(nukeNpcInventory, npcWritable, { victim = npcWritable })
                        end)
                    end
                else
                    System.LogAlways("[CorpseSanitizer/Nuke] pre-corpse skipped (no writable/hostile target within "
                        .. string.format("%.2f", m) .. "m)")
                end
            end
        end

        local corpse, vdist = findNearestCorpse(8.0)

        if corpse then
            local vWuid = getEntityWuid(corpse)
            log(("Victim (corpse): %s d=%.2fm vWUID=%s"):format(tostring(corpse:GetName() or "<corpse>"), vdist or -1,
                tostring(vWuid)))

            -- A) direct enumeration on corpse
            do
                local itemsA, howA = tryEnumerateDirectOnEntity(corpse)
                -- A) direct corpse lane
                if itemsA then
                    -- target gates
                    local isAnimal, isHuman = classifyVictim(corpse)
                    local tgt = CS.config.nuker.target or { animals = true, humans = true }
                    local okVictim = ((isAnimal and tgt.animals) or (isHuman and tgt.humans))
                    if okVictim and ((not CS.config.nuker.onlyHostile) or isHostileToPlayer(corpse)) then
                        -- nuke first (faster UX), then re-enum for logging
                        pcall(nukeNpcInventory, corpse, { items = itemsA, corpseCtx = true, victim = corpse })
                        itemsA, howA = tryEnum(corpse) -- your local re-enumerator
                    end

                    if itemsA and type(itemsA) == "table" then
                        logInventoryRows(itemsA, howA, 100)
                    end
                end
            end

            -- B) if the corpse exposes a WUID, try it
            local vwuid, via = getCandidateWuidForOwnership(corpse)
            if vwuid then
                log(("Victim WUID lane: %s → %s"):format(tostring(vwuid), via))
                local items, how = tryEnumerateByWuid(corpse, vwuid)
                if items then
                    logItemsTable(items, how, 20, corpse)
                    local okNuke, errNuke = pcall(nukeNpcInventory, corpse,
                        { items = items, corpseCtx = true, victim = corpse })
                    if not okNuke then log("[nuke] error: " .. tostring(errNuke)) end
                    return
                end
            end
        else
            log("Victim: <none> within 8m")
        end

        -- C) ownership match near corpse
        if corpse then
            local stash, why = resolveCorpseContainerViaOwnership(corpse, 12.0)
            if stash then
                log(("Loot container: %s via %s"):format(tostring(stash:GetName() or "<stash>"), why))
                local swuid, lane = getStashInventoryWuid(stash)
                log(("Stash WUID: %s (via %s)"):format(tostring(swuid), tostring(lane)))
                if swuid then
                    local items, how = tryEnumerateByWuid(stash, swuid)
                    if items then
                        logItemsTable(items, how, 20, corpse); return
                    end
                end
            else
                log("Ownership resolver: no matching stash for corpse (" .. tostring(why) .. ")")
            end
        end

        -- D) engine-provided WUID hooks
        local wuid = CorpseSanitizer._loot.lastWUID
        if wuid then
            log("OnOpened: using hooked WUID → " .. tostring(wuid))
            local items, how = tryEnumerateByWuid(nil, wuid)
            if items then
                logItemsTable(items, how, 20); return
            end
            log("OnOpened: hooked WUID had no enumerable items via known lanes")
        else
            log("OnOpened: no hooked WUID (hook may be missing in this build)")
        end

        -- E) fallback: nearest NPC-inventory
        do
            local list = scanNearbyOnce(4.0, 24)
            local npc, d2
            for i = 1, #list do
                local r = list[i]
                if r.e and (r.e.class == "NPC" or r.e.class == "Human" or r.e.class == "AI") then
                    npc, d2 = r.e, r.d2; break
                end
            end
            if npc then
                log(("Fallback NPC-inventory: %s (d=%.2fm)"):format(
                    tostring((npc.GetName and npc:GetName()) or "<npc>"), math.sqrt(d2 or 0)))
                local items, how = enumNPCInventory(npc)
                if items then
                    logItemsTable(items, how, 25, npc)
                    -- UI-only purge for read-only corpse / boss container
                    if CS.config.ui and CS.config.ui.shadowDelete and type(items) == "table" and #items > 0 then
                        for i = 1, #items do
                            local uiid = uiIdFromRow(items[i])
                            if uiid then ui_remove_row(uiid) end
                        end
                        UIRefresh.movie = CS.config.ui.movie or "ItemTransfer"
                        UIRefresh:Refresh()
                        log("[CorpseSanitizer] UI shadow purged boss inventory (read-only corpse)")
                        return -- skip nuker for this path; remove this 'return' if you still want to try nuker after purging
                    end

                    if CS.config.insanityMode and (CS.config.nuker and CS.config.nuker.enabled) then
                        local okNuke2, errNuke2 = pcall(nukeNpcInventory, npc, {
                            items  = items,
                            victim = npc,
                        })
                        if not okNuke2 then log("[nuke] error: " .. tostring(errNuke2)) end
                    else
                        log("[NUKE] skipped (insanityMode=false or nuker.enabled=false)")
                    end
                else
                    log("Fallback NPC-inventory: no enumerable items (" .. tostring(how) .. ")")
                end
            end
        end

        -- F) class-based stash fallback & single retry with probe
        local stash2, source = resolveCorpseContainer(corpse, 10.0)
        if stash2 then
            log(("Loot container: %s via %s"):format(tostring(stash2:GetName() or "<stash>"), source))
            local swuid2, via2 = getStashInventoryWuid(stash2)
            log(("Stash WUID: %s (via %s)"):format(tostring(swuid2), tostring(via2)))
            if swuid2 then
                local items2, how2 = tryEnumerateByWuid(stash2, swuid2)
                if items2 then
                    logItemsTable(items2, how2, 20, corpse); return
                end
            end
        else
            log("Loot container: <none> near corpse (no StashCorpse; no nearby Stash)")
            if corpse then
                log("→ Probing neighbors around corpse…"); probeNearVictim(corpse, 12.0)
            end
            later(200, function()
                local corpse2 = corpse or select(1, findNearestCorpse(10.0))
                if corpse2 then
                    local s3, why3 = resolveCorpseContainerViaOwnership(corpse2, 12.0)
                    if s3 then
                        log(("[retry] Loot container: %s via %s"):format(tostring(s3:GetName() or "<stash>"), why3))
                        local w3, lane3 = getStashInventoryWuid(s3)
                        log(("[retry] Stash WUID: %s (via %s)"):format(tostring(w3), tostring(lane3)))
                        if w3 then
                            local items3, how3 = tryEnumerateByWuid(s3, w3)
                            if items3 then
                                logItemsTable(items3, how3, 20, corpse2); return
                            end
                        end
                    else
                        log("[retry] still no stash for corpse — probing again"); probeNearVictim(corpse2, 12.0)
                    end
                else
                    log("[retry] no corpse found within 10m")
                end
            end)
        end
    end)
end

function CorpseSanitizer:OnClosed(elementName, instanceId, eventName, args)
    self.ui.active         = false
    self._loot.lastWUID    = nil
    self._loot.lastOwnerId = nil
    log("OnClosed → transfer UI hidden")
end

function CorpseSanitizer:OnFocusChanged(elementName, instanceId, eventName, args)
    local clientId = args and tonumber(args[4]) or -1
    if clientId and clientId >= 0 then log(("OnFocusChanged(client=%d)"):format(clientId)) end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Listener registration & bootstrap
-- ─────────────────────────────────────────────────────────────────────────────
function CorpseSanitizer.EnableTransferLogging()
    if not (UIAction and UIAction.RegisterElementListener) then
        log("UIAction not available; cannot register ItemTransfer listeners"); return
    end
    local movie = CS.config.ui.movie
    UIAction.RegisterElementListener(CorpseSanitizer, movie, -1, "OnOpened", "OnOpened")
    UIAction.RegisterElementListener(CorpseSanitizer, movie, -1, "OnClosed", "OnClosed")
    UIAction.RegisterElementListener(CorpseSanitizer, movie, -1, "OnFocusChanged", "OnFocusChanged")
    log("Registered ItemTransfer listeners")
end

function CorpseSanitizer.Bootstrap()
    if CorpseSanitizer.booted then return end
    CorpseSanitizer.booted = true
    log("BOOT ok (version=" .. CorpseSanitizer.version .. ")")
    log("Lua=" .. tostring(_VERSION or "unknown"))
    logEffectiveConfig()

    -- Hooks
    if XGenAIModule and type(XGenAIModule.LootInventoryBegin) == "function" and not CS._loot._orig then
        CS._loot._orig = XGenAIModule.LootInventoryBegin
        XGenAIModule.LootInventoryBegin = function(wuid, ...)
            CS._loot.lastWUID = wuid
            log("Loot hook: LootInventoryBegin wuid=" .. tostring(wuid))
            return CS._loot._orig(wuid, ...)
        end
        log("Loot hook: installed on XGenAIModule.LootInventoryBegin")
    else
        log("Loot hook: XGenAIModule.LootInventoryBegin not available or already installed")
    end

    if XGenAIModule then
        for k, v in pairs(XGenAIModule) do
            if type(v) == "function" then
                local name = tostring(k):lower()
                if (name:find("inventory", 1, true) or name:find("transfer", 1, true))
                    and (name:find("open", 1, true) or name:find("begin", 1, true) or name:find("start", 1, true)) then
                    local orig = v
                    XGenAIModule[k] = function(...)
                        local a = { ... }
                        local maybeWuid = a[1]
                        if type(maybeWuid) == "userdata" then
                            CS._loot.lastWUID = maybeWuid
                            log("Loot hook (auto): XGenAIModule." .. k .. " wuid=" .. tostring(maybeWuid))
                        end
                        return orig(...)
                    end
                end
            end
        end
    end


    local p = getPlayer(); local act = p and p.actor
    if act and type(act.OpenItemTransferStore) == "function" and not CS._loot._origActor then
        CS._loot._origActor = act.OpenItemTransferStore
        act.OpenItemTransferStore = function(self, ownerId, wuid, ...)
            CS._loot.lastWUID    = wuid
            CS._loot.lastOwnerId = ownerId
            log(("Actor hook: OpenItemTransferStore owner=%s wuid=%s"):format(tostring(ownerId), tostring(wuid)))
            return CS._loot._origActor(self, ownerId, wuid, ...)
        end
        log("Actor hook: installed on actor.OpenItemTransferStore")
    else
        log("Actor hook: OpenItemTransferStore not available or already installed")
    end

    UIRefresh.movie = (CS.config.ui and CS.config.ui.movie) or "ItemTransfer"
    CS.EnableTransferLogging()
end
