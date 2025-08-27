-- CorpseSanitizer.lua (0.2.3) — WUID capture + corpse→stash resolution + read-only enumeration

CorpseSanitizer = {
    version = "0.2.3",
    booted  = false,
    config  = {
        dryRun    = true,
        minHealth = 0.50,
        ui        = { movie = "ItemTransfer" },
        proximity = { radius = 5.0, maxList = 24 },
    },
    ui      = { active = false },
    _loot   = { lastWUID = nil, lastOwnerId = nil },
}

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
    local player = getPlayer()
    if not (player and player.GetWorldPos) then return {} end
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

-- safe timer wrapper (keeps handler alive if something throws)
local function later(ms, fn)
    Script.SetTimer(ms or 0, function()
        local ok, err = pcall(fn)
        if not ok then log("[timer] error: " .. tostring(err)) end
    end)
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

local function prettyOwner(wuid)
    if not wuid or tostring(wuid) == "userdata: 0000000000000000" then return "none/unknown" end
    -- try owner entity first (nicer label)
    if XGenAIModule and type(XGenAIModule.GetOwnerEntity) == "function" then
        local ok, ent = pcall(function() return XGenAIModule.GetOwnerEntity(wuid) end)
        if ok and ent then
            if ent.GetName then return tostring(wuid) .. " [" .. tostring(ent:GetName()) .. "]" end
            if ent.class then return tostring(wuid) .. " [" .. tostring(ent.class) .. "]" end
        end
    end
    -- fallback: resolve entity by WUID if available
    if XGenAIModule and type(XGenAIModule.GetEntityByWUID) == "function" then
        local ok, ent = pcall(function() return XGenAIModule.GetEntityByWUID(wuid) end)
        if ok and ent and ent.GetName then
            return tostring(wuid) .. " [" .. tostring(ent:GetName()) .. "]"
        end
    end
    return tostring(wuid)
end

-- candidate inventory WUID for ownership checks on any entity
local function getCandidateWuidForOwnership(e)
    local w = getEntityWuid(e)
    if w then return w, "entityWuid" end
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

-- ─────────────────────────────────────────────────────────────────────────────
-- Corpse detection + stash resolution
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

local function isDeadEntity(e)
    if not e then return false end
    local s = e.soul or (e.GetSoul and e:GetSoul())
    if s and type(s.IsDead) == "function" then
        local ok, v = pcall(function() return s:IsDead() end); if ok and (v == true or v == 1) then return true end
    end
    if e.actor and type(e.actor.IsDead) == "function" then
        local ok, v = pcall(function() return e.actor:IsDead() end); if ok and (v == true or v == 1) then return true end
    end
    if s and type(s.IsAlive) == "function" then
        local ok, v = pcall(function() return s:IsAlive() end); if ok and v == false then return true end
    end
    if s and type(s.GetHealth) == "function" then
        local ok, h = pcall(function() return s:GetHealth() end); if ok and tonumber(h) and h <= 0 then return true end
    end
    if s and type(s.GetHitPoints) == "function" then
        local ok, h = pcall(function() return s:GetHitPoints() end); if ok and tonumber(h) and h <= 0 then return true end
    end
    return false
end

local function findNearestCorpse(radius)
    local list   = scanNearbyOnce(radius or 5.0, 48)
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
        if nearestStash and math.sqrt(d2s) <= 2.0 then return nearestStash, "Stash(victim-adjacent)" end
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

-- ─────────────────────────────────────────────────────────────────────────────
-- Enumeration: read-only item listing
-- ─────────────────────────────────────────────────────────────────────────────
local function resolveItemEntry(entry)
    if ItemManager and ItemManager.GetItem and type(entry) == "userdata" then
        local ok, it = pcall(ItemManager.GetItem, entry)
        if ok and it then return it end
    end
    if type(entry) == "table" and (entry.class or entry.Class or entry.id or entry.Id) then
        return entry
    end
    return nil
end

local function getItemOwnerWuid(entry)
    if type(entry) == "userdata" and ItemManager and ItemManager.GetItemOwner then
        local ok, w = pcall(ItemManager.GetItemOwner, entry)
        if ok and w then return w, "ItemManager.GetItemOwner(handle)" end
    end
    if type(entry) == "table" and ItemManager and ItemManager.GetItemOwner then
        local id = entry.id or entry.Id
        if id then
            local ok, w = pcall(ItemManager.GetItemOwner, id)
            if ok and w then return w, "ItemManager.GetItemOwner(row.id)" end
        end
        if type(entry.GetLinkedOwner) == "function" then
            local ok, w = pcall(function() return entry:GetLinkedOwner() end)
            if ok and w then return w, "item:GetLinkedOwner()" end
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

local function logItemsTable(items, how, cap)
    cap = cap or 20
    local keys = {}
    for k in pairs(items) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        local ta, tb = type(a), type(b)
        if ta == "number" and tb == "number" then return a < b end
        if ta == "number" then return true end
        if tb == "number" then return false end
        return tostring(a) < tostring(b)
    end)
    local shown = 0
    for _, k in ipairs(keys) do
        local row             = items[k]
        local it              = resolveItemEntry(row)
        local class, hp, amt  = getItemSummary(it)
        local ownerWuid, lane = getItemOwnerWuid(row); if not ownerWuid then ownerWuid, lane = getItemOwnerWuid(it) end
        local ownerStr = ownerWuid and prettyOwner(ownerWuid) or "?"
        log(string.format("  [%s] class=%s hp=%s amt=%s owner=%s%s",
            tostring(k), class, hp, amt, ownerStr, lane and (" [" .. lane .. "]") or ""))
        shown = shown + 1
        if shown >= cap then break end
    end
    log("Enumerator used: " .. how .. string.format(" (raw keys walked, %d entries shown)", shown))
end

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
                        logItemsTable(items, comp .. ":" .. m, 20)
                        return true
                    end
                end
            end
        end
    end
    return false
end

local function tryEnumerateByWuid(stashEnt, wuid)
    if EntityModule and wuid then
        local ok1, owner = pcall(function() return EntityModule.GetInventoryOwner(wuid) end)
        if ok1 then log("WUID owner = " .. tostring(owner)) end
        local ok2, canUse = pcall(function() return EntityModule.CanUseInventory(wuid) end)
        if ok2 then log("CanUseInventory = " .. tostring(canUse)) end
    end

    local function tryStashField(field)
        local obj = stashEnt and stashEnt[field]
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
        local t, how = tryStashField(f)
        if t then return t, how end
    end

    local lanes = {
        { mod = "Inventory",       fns = { "GetItems", "GetItemsForInventory", "GetInventoryTable" } },
        { mod = "InventoryModule", fns = { "GetItems", "GetInventoryItems", "GetInventoryTable" } },
        { mod = "XGenAIModule",    fns = { "GetInventoryItems" } },
        { mod = "EntityModule",    fns = { "GetInventoryItems", "GetInventoryTable" } },
    }
    for _, lane in ipairs(lanes) do
        local mod = _G[lane.mod]
        if mod and wuid then
            for _, fn in ipairs(lane.fns) do
                if type(mod[fn]) == "function" then
                    local ok, res = pcall(function() return mod[fn](wuid) end)
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
    local p = getPlayer()
    local act = p and p.actor
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
        local victim, vdist = findNearestCorpse(8.0)

        if victim then
            local vWuid = getEntityWuid(victim)
            log(("Victim (corpse): %s d=%.2fm vWUID=%s"):format(tostring(victim:GetName() or "<corpse>"), vdist or -1,
                tostring(vWuid)))

            -- A) direct tables on corpse entity
            if tryEnumerateDirectOnEntity(victim) then return end

            -- B) if the corpse exposes a WUID, try it
            local vwuid, via = getCandidateWuidForOwnership(victim)
            if vwuid then
                log(("Victim WUID lane: %s → %s"):format(tostring(vwuid), via))
                local items, how = tryEnumerateByWuid(victim, vwuid)
                if items then
                    logItemsTable(items, how, 20); return
                end
            end
        else
            log("Victim: <none> within 8m")
        end

        -- C) ownership match near corpse
        if victim then
            local stash, why = resolveCorpseContainerViaOwnership(victim, 12.0)
            if stash then
                log(("Loot container: %s via %s"):format(tostring(stash:GetName() or "<stash>"), why))
                local swuid, lane = getStashInventoryWuid(stash)
                log(("Stash WUID: %s (via %s)"):format(tostring(swuid), tostring(lane)))
                if swuid then
                    local items, how = tryEnumerateByWuid(stash, swuid)
                    if items then
                        logItemsTable(items, how, 20); return
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

        -- E) final fallback — nearest dead hostile NPC inventory directly
        do
            local list = scanNearbyOnce(10.0, 48)
            local npc, bestD2
            for i = 1, #list do
                local e = list[i].e
                if e and (e.class == "NPC" or e.class == "Human" or e.class == "AI") and isDeadEntity(e) then
                    if not npc or list[i].d2 < bestD2 then npc, bestD2 = e, list[i].d2 end
                end
            end
            if npc and npc.inventory and type(npc.inventory.GetInventoryTable) == "function" then
                local ndist = math.sqrt(bestD2 or 0)
                log(("Fallback NPC-inventory: %s (d=%.2fm)"):format(tostring(npc.GetName and npc:GetName() or "<npc>"),
                    ndist or -1))
                local ok, items = pcall(function() return npc.inventory:GetInventoryTable(npc.inventory) end)
                if ok and type(items) == "table" then
                    logItemsTable(items, "npc.inventory:GetInventoryTable", 20); return
                end
                log("Fallback NPC-inventory: enumeration failed")
            else
                log("Fallback NPC-inventory: no dead hostile nearby, or no inventory")
            end
        end

        -- F) class-based fallback & retry
        local stash2, source = resolveCorpseContainer(victim, 10.0)
        if stash2 then
            log(("Loot container: %s via %s"):format(tostring(stash2:GetName() or "<stash>"), source))
            local swuid2, via2 = getStashInventoryWuid(stash2)
            log(("Stash WUID: %s (via %s)"):format(tostring(swuid2), tostring(via2)))
            if swuid2 then
                local items2, how2 = tryEnumerateByWuid(stash2, swuid2)
                if items2 then
                    logItemsTable(items2, how2, 20); return
                end
            end
        else
            log("Loot container: <none> near corpse (no StashCorpse; no nearby Stash)")
            if victim then
                log("→ Probing neighbors around corpse…"); probeNearVictim(victim, 12.0)
            end
            later(200, function()
                local corpse2 = victim or select(1, findNearestCorpse(10.0))
                if corpse2 then
                    local stash3, why3 = resolveCorpseContainerViaOwnership(corpse2, 12.0)
                    if stash3 then
                        log(("[retry] Loot container: %s via %s"):format(tostring(stash3:GetName() or "<stash>"), why3))
                        local w3, lane3 = getStashInventoryWuid(stash3)
                        log(("[retry] Stash WUID: %s (via %s)"):format(tostring(w3), tostring(lane3)))
                        if w3 then
                            local items3, how3 = tryEnumerateByWuid(stash3, w3)
                            if items3 then
                                logItemsTable(items3, how3, 20); return
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
    installLootBeginHook()
    installActorOpenHook()
    log(CorpseSanitizer._loot._orig and "Loot hook: active" or "Loot hook: inactive")
    log(CorpseSanitizer._loot._origActor and "Actor hook: active" or "Actor hook: inactive")
    CorpseSanitizer.EnableTransferLogging()
end
