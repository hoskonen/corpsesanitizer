-- Module header: expose ONE global table
CorpseSanitizer = CorpseSanitizer or {
    version = "0.2.4",
    booted  = false,
    ui      = { active = false },
    _loot   = { lastWUID = nil },
}

local CS = CorpseSanitizer

-- 3) Defaults + deep merge (so external config can override selectively)
local DEFAULT_CONFIG = {
    dryRun       = false,
    insanityMode = true,
    ui           = { movie = "ItemTransfer" },
    proximity    = { radius = 5.0, maxList = 24 },
    nuker        = {
        enabled      = true,
        minHp        = 0.00,
        skipMoney    = true,
        onlyIfCorpse = true,
    },
    logging      = {
        prettyOwner     = true,
        probeOnMiss     = true,
        showWouldDelete = true,
    },
}

local function deepMerge(dst, src)
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
if type(CS.config) == "table" and type(CS._prevCfg) == "table" then
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
    local c, n, l, p, u = CS.config, (CS.config.nuker or {}), (CS.config.logging or {}), (CS.config.proximity or {}),
        (CS.config.ui or {})
    log(string.format(
        "cfg: dryRun=%s | insanityMode=%s | ui.movie=%s | radius=%.2f | nuker{enabled=%s,minHp=%.2f,skipMoney=%s,onlyIfCorpse=%s} | logging{prettyOwner=%s,probeOnMiss=%s,showWouldDelete=%s}",
        bool(c.dryRun), bool(c.insanityMode),
        tostring(u.movie or "?"),
        tonumber(p.radius or 0) or 0,
        bool(n.enabled), tonumber(n.minHp or 0) or 0,
        bool(n.skipMoney), bool(n.onlyIfCorpse),
        bool(l.prettyOwner), bool(l.probeOnMiss), bool(l.showWouldDelete)))
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
local function log(msg) System.LogAlways("[CorpseSanitizer] " .. tostring(msg)) end

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

local function later(ms, fn)
    Script.SetTimer(ms or 0, function()
        local ok, err = pcall(fn)
        if not ok then log("[timer] error: " .. tostring(err)) end
    end)
end

local function bool(x) return x and "true" or "false" end

local function logEffectiveConfig()
    local c    = CorpseSanitizer.config
    local nuk  = c.nuker or {}
    local lg   = c.logging or {}
    local prox = c.proximity or {}
    local ui   = c.ui or {}

    log(string.format(
        "cfg: dryRun=%s | insanityMode=%s | ui.movie=%s | radius=%.2f | nuker{enabled=%s,minHp=%.2f,skipMoney=%s,onlyIfCorpse=%s} | logging{prettyOwner=%s,probeOnMiss=%s,showWouldDelete=%s}",
        bool(c.dryRun), bool(c.insanityMode),
        tostring(ui.movie or "?"),
        tonumber(prox.radius or 0) or 0,
        bool(nuk.enabled), tonumber(nuk.minHp or 0) or 0,
        bool(nuk.skipMoney), bool(nuk.onlyIfCorpse),
        bool(lg.prettyOwner), bool(lg.probeOnMiss), bool(lg.showWouldDelete)
    ))
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

local _ownerPrettyCache = {}
local function prettyOwner(ownerWuid, victim)
    if not ownerWuid or tostring(ownerWuid) == "userdata: 0000000000000000" then
        return "none/unknown"
    end
    -- victim?
    local vw = victim and getEntityWuid and getEntityWuid(victim)
    if vw and ownerWuid == vw then return "victim" end
    -- player?
    local p = System.GetEntityByName("player") or System.GetEntityByName("Henry") or System.GetEntityByName("dude")
    local pw = p and getEntityWuid and getEntityWuid(p)
    if pw and ownerWuid == pw then return "player" end
    -- default short form
    return tostring(ownerWuid)
end


-- ─────────────────────────────────────────────────────────────────────────────
-- Corpse/NPC inspection + stash resolution
-- ─────────────────────────────────────────────────────────────────────────────
local function isCorpseEntity(e)
    if not e then return false end
    local cls = tostring(e.class or "")
    if cls == "DeadBody_Human" or cls == "DeadBody_Base_Human"
        or cls == "SO_DeadBody_Human" or cls == "SO_DeadBody_Human_Interactable" then
        return true
    end
    return cls:find("DeadBody", 1, true) ~= nil
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

-- Return true if 'entry' is a handle we can pass to Inventory.DeleteItem
local function itemHandle(entry)
    if type(entry) == "userdata" then return entry end
    if type(entry) == "table" then
        -- Some lists put the handle at .id / .Id
        return entry.id or entry.Id or entry.handle or nil
    end
    return nil
end

-- Get the WUID that owns a *handle* (fast, no resolution to item table)
local function ownerOfHandle(h)
    if not (h and ItemManager and ItemManager.GetItemOwner) then return nil, "no-handle" end
    local ok, w = pcall(ItemManager.GetItemOwner, h)
    if ok and w then return w, "ItemManager.GetItemOwner(handle)" end
    return nil, "no-owner"
end


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
    -- If entry is an item handle (userdata), prefer ItemManager.GetItemOwner(handle)
    if type(entry) == "userdata" and ItemManager and ItemManager.GetItemOwner then
        local ok, w = pcall(ItemManager.GetItemOwner, entry)
        if ok and w then return w, "ItemManager.GetItemOwner(handle)" end
    end
    -- If entry is a table already, see if it carries an owner field (rare)
    if type(entry) == "table" then
        if entry.owner or entry.Owner then
            return entry.owner or entry.Owner, "entry.owner"
        end
        -- Some frameworks keep a backref from item to inventory/container
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
            return w,
                "ItemManager.GetItemOwner(handle)"
        end
    end
    if type(entry) == "table" and ItemManager and ItemManager.GetItemOwner then
        local id = entry.id or entry.Id
        if id then
            local ok, w = pcall(ItemManager.GetItemOwner, id); if ok and w then
                return w,
                    "ItemManager.GetItemOwner(row.id)"
            end
        end
        if type(entry.GetLinkedOwner) == "function" then
            local ok, w = pcall(function() return entry:GetLinkedOwner() end); if ok and w then
                return w,
                    "item:GetLinkedOwner()"
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
-- NPC inventory lanes (read-only) + destructive (nuke) with dry-run
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

-- Remove every item in an NPC's own inventory (NOT the player, NOT allies)
-- Remove every item in an NPC's own inventory (NOT the player, NOT allies)
-- Remove every item in an NPC’s own inventory (NOT the player, NOT allies)
local function nukeNpcInventory(npc, prelistedItems)
    local C   = CorpseSanitizer.config or {}
    local N   = C.nuker or {}
    local dry = C.dryRun and true or false
    local tag = dry and "[nuke][dry]" or "[nuke]"

    if not N.enabled then
        log(tag .. " abort (nuker.enabled=false)"); return
    end
    if N.onlyIfCorpse and not (npc and isCorpseEntity(npc)) then
        log(tag .. " abort (onlyIfCorpse=true and npc is not a corpse)"); return
    end
    if not npc then
        log(tag .. " abort (no npc)"); return
    end

    -- Confirm this NPC’s WUID (so we don’t delete someone else’s items)
    local npcWuid = getEntityWuid and getEntityWuid(npc)
    if not npcWuid then
        log(tag .. " abort (no npc WUID)"); return
    end

    -- Collect items to operate on
    local items, how
    if type(prelistedItems) == "table" then
        items, how = prelistedItems, "prelisted"
    else
        local inv = npc.inventory or npc.container or npc.stash
        if not (inv and type(inv.GetInventoryTable) == "function") then
            log(tag .. " abort (npc has no enumerable inventory)"); return
        end
        local ok, t = pcall(function() return inv:GetInventoryTable(inv) end)
        if not (ok and type(t) == "table") then
            log(tag .. " abort (failed to get inventory list)"); return
        end
        items, how = t, "inventory:GetInventoryTable"
    end

    local deleted, kept = 0, 0

    -- stable keys
    local keys = {}
    for k in pairs(items) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        local na, nb = type(a) == "number", type(b) == "number"
        if na and nb then return a < b end
        if na then return true end
        if nb then return false end
        return tostring(a) < tostring(b)
    end)

    for _, k in ipairs(keys) do
        local row     = items[k]
        local it      = resolveItemEntry(row) -- may be nil if row is just a handle
        local classId = (it and (it.class or it.Class)) or (row and (row.class or row.Class))
        local handle  = itemHandle(row)

        -- Decide whether to keep this item
        local keep    = false

        -- 1) Skip money?
        if N.skipMoney and classId == "5ef63059-322e-4e1b-abe8-926e100c770e" then
            keep = true
        end

        -- 2) HP gate (treat >1 as 0-100%)
        if not keep and it and N.minHp then
            local rawHp = it.health or it.Health or it.cond
            if rawHp and rawHp > 1.001 then rawHp = rawHp / 100 end
            local hp = rawHp or 0
            if hp < N.minHp then
                keep = true
            end
        end

        -- 3) Ownership check (when we have a handle)
        if not keep and handle then
            local ownerWuid = select(1, ownerOfHandle(handle))
            if ownerWuid and npcWuid and ownerWuid ~= npcWuid then
                keep = true
            end
        end

        if keep then
            kept = kept + 1
        else
            if dry then
                log(string.format("%s Would delete %s (%s)", tag, tostring(classId or "?"), tostring(handle)))
                deleted = deleted + 1
            else
                local okDel = false
                if handle and Inventory and Inventory.DeleteItem then
                    okDel = pcall(function() return Inventory.DeleteItem(handle, -1) end)
                elseif classId and Inventory and Inventory.DeleteItemOfClass then
                    local count = tonumber((it and (it.amount or it.Amount)) or (row and (row.amount or row.Amount)) or
                        -1) or -1
                    okDel = pcall(function() return Inventory.DeleteItemOfClass(tostring(classId), count) end)
                end
                if okDel then
                    deleted = deleted + 1
                else
                    kept = kept + 1
                    log(string.format("%s delete failed %s (%s)", tag, tostring(classId or "?"), tostring(handle)))
                end
            end
        end
    end

    log(string.format("%s summary: deleted=%d kept=%d dry=%s (via=%s)",
        tag, deleted, kept, tostring(dry), how))
end



-- ─────────────────────────────────────────────────────────────────────────────
-- Stash/NPC enumeration lanes
-- ─────────────────────────────────────────────────────────────────────────────
local function tryEnumerateDirectOnEntity(ent)
    if not ent then return false end
    for _, comp in ipairs({ "inventory", "container", "stash" }) do
        local c = ent[comp]
        if type(c) == "table" then
            for _, m in ipairs({ "GetInventoryTable", "GetItems", "GetAllItems" }) do
                if type(c[m]) == "function" then
                    local ok, items = pcall(function() return c[m](c) end)
                    if ok and type(items) == "table" then
                        log(string.format("Direct: %s:%s → table(#%d)", comp, m, #items))
                        logItemsTable(items, comp .. ":" .. m, 20, ent)
                        return true
                    end
                end
            end
        end
    end
    return false
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
-- Hooks
-- ─────────────────────────────────────────────────────────────────────────────
local function installLootBeginHook()
    if not (XGenAIModule and type(XGenAIModule.LootInventoryBegin) == "function") then
        log("Loot hook: XGenAIModule.LootInventoryBegin not available"); return
    end
    if CorpseSanitizer._loot._orig then return end
    CorpseSanitizer._loot._orig = XGenAIModule.LootInventoryBegin
    XGenAIModule.LootInventoryBegin = function(wuid, ...)
        CorpseSanitizer._loot.lastWUID = wuid
        log("Loot hook: LootInventoryBegin wuid=" .. tostring(wuid))
        return CorpseSanitizer._loot._orig(wuid, ...)
    end
    log("Loot hook: installed on XGenAIModule.LootInventoryBegin")
end

local function installActorOpenHook()
    local p = getPlayer(); local act = p and p.actor
    if not (act and type(act.OpenItemTransferStore) == "function") then
        log("Actor hook: OpenItemTransferStore not available"); return
    end
    if CorpseSanitizer._loot._origActor then return end
    CorpseSanitizer._loot._origActor = act.OpenItemTransferStore
    act.OpenItemTransferStore = function(self, ownerId, wuid, ...)
        CorpseSanitizer._loot.lastWUID    = wuid
        CorpseSanitizer._loot.lastOwnerId = ownerId
        log(("Actor hook: OpenItemTransferStore owner=%s wuid=%s"):format(tostring(ownerId), tostring(wuid)))
        return CorpseSanitizer._loot._origActor(self, ownerId, wuid, ...)
    end
    log("Actor hook: installed on actor.OpenItemTransferStore")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- UI handlers
-- ─────────────────────────────────────────────────────────────────────────────
function CorpseSanitizer:OnOpened(elementName, instanceId, eventName, args)
    self.ui.active = true
    log(("OnOpened → transfer UI visible (element=%s, instance=%s)"):format(tostring(elementName), tostring(instanceId)))

    later(150, function()
        local corpse, vdist = findNearestCorpse(8.0)

        if corpse then
            local vWuid = getEntityWuid(corpse)
            log(("Victim (corpse): %s d=%.2fm vWUID=%s"):format(tostring(corpse:GetName() or "<corpse>"), vdist or -1,
                tostring(vWuid)))

            -- A) direct tables on corpse entity
            if tryEnumerateDirectOnEntity(corpse) then
                if CorpseSanitizer.config.insanityMode and (CorpseSanitizer.config.nuker and CorpseSanitizer.config.nuker.enabled) then
                    nukeNpcInventory(corpse)
                else
                    log(
                        "[NUKE] skipped (insanityMode=false)")
                end
                return
            end

            -- B) if the corpse exposes a WUID, try it
            local vwuid, via = getCandidateWuidForOwnership(corpse)
            if vwuid then
                log(("Victim WUID lane: %s → %s"):format(tostring(vwuid), via))
                local items, how = tryEnumerateByWuid(corpse, vwuid)
                if items then
                    logItemsTable(items, how, 20, corpse)
                    nukeNpcInventory(corpse, items)
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

        -- E) fallback: nearest NPC inventory (what succeeded in your last test)
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
                log(("Fallback NPC-inventory: %s (d=%.2fm)"):format(tostring((npc.GetName and npc:GetName()) or "<npc>"),
                    math.sqrt(d2 or 0)))
                local items, how = enumNPCInventory(npc)
                if items then
                    logItemsTable(items, how, 25, npc)
                    if CorpseSanitizer.config.insanityMode and (CorpseSanitizer.config.nuker and CorpseSanitizer.config.nuker.enabled) then
                        nukeNpcInventory(npc, items)
                    else
                        log("[NUKE] skipped (insanityMode=false or nuker.enabled=false)")
                    end
                else
                    log(
                        "Fallback NPC-inventory: no enumerable items (" .. tostring(how) .. ")")
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
    local movie = CorpseSanitizer.config.ui.movie
    UIAction.RegisterElementListener(CorpseSanitizer, movie, -1, "OnOpened", "OnOpened")
    UIAction.RegisterElementListener(CorpseSanitizer, movie, -1, "OnClosed", "OnClosed")
    UIAction.RegisterElementListener(CorpseSanitizer, movie, -1, "OnFocusChanged", "OnFocusChanged")
    log("Registered ItemTransfer listeners")
end

function CorpseSanitizer.Bootstrap()
    if CorpseSanitizer.booted then return end
    CorpseSanitizer.booted = true
    log("BOOT ok (version=" .. CorpseSanitizer.version .. ")")
    logEffectiveConfig()

    installLootBeginHook()
    installActorOpenHook()
    log(CorpseSanitizer._loot._orig and "Loot hook: active" or "Loot hook: inactive")
    log(CorpseSanitizer._loot._origActor and "Actor hook: active" or "Actor hook: inactive")
    CorpseSanitizer.EnableTransferLogging()
end
