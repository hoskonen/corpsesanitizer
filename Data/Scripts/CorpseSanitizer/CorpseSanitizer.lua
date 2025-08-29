-- Scripts/CorpseSanitizer/CorpseSanitizer.lua
-- Clean smoke-test build: robust logging + optional UI echo (no engine writes)

-- ─────────────────────────────────────────────────────────────────────────────
-- Module header: expose ONE global table
-- ─────────────────────────────────────────────────────────────────────────────
CorpseSanitizer = CorpseSanitizer or {
    version = "0.5.0-clean",
    booted  = false,
    ui      = { active = false },
    _loot   = { lastWUID = nil, lastOwnerId = nil },
}
local CS = CorpseSanitizer

local function log(msg) System.LogAlways("[CorpseSanitizer] " .. tostring(msg)) end

-- ─────────────────────────────────────────────────────────────────────────────
-- UI helpers (GFx)
-- ─────────────────────────────────────────────────────────────────────────────
-- supports any number of call arguments (e.g., id + idx)
local function uicall(movie, inst, fn, ...)
    if not (UIAction and UIAction.CallFunction) then return false end
    local ok = pcall(UIAction.CallFunction, movie, inst, fn, ...)
    return ok and true or false
end

local function setarray(movie, inst, key, tbl)
    if not (UIAction and UIAction.SetArray) then return false end
    local ok = pcall(UIAction.SetArray, movie, inst, key, tbl)
    return ok and true or false
end

-- Normalize one engine row into a SWF-friendly row (include aliases)
local function toUiRow(row)
    local id     = tostring((row.id or row.Id or row.stackId or row.StackId or row.handle or row.Handle) or
        ("cs_" .. tostring(os.time())))
    local name   = tostring(row.name or row.Name or row.displayName or row.DisplayName or row.class or "Unknown")
    local class  = tostring(row.class or row.Class or "unknown")
    local amount = tonumber(row.amt or row.Amt or row.amount or row.Amount or row.count or row.Count or 1) or 1
    local hp     = row.hp or row.HP or row.health or row.Health or 1.0
    if type(hp) == "number" and hp > 1.001 then hp = hp / 100 end
    local icon = tostring(row.icon or row.Icon or "")
    return {
        id = id,
        Id = id,
        name = name,
        Name = name,
        class = class,
        Class = class,
        amount = amount,
        Amount = amount,
        count = amount,
        Count = amount,
        hp = hp,
        HP = hp,
        health = hp,
        Health = hp,
        icon = icon,
        Icon = icon,
    }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- ItemTransfer UI Controller (bound to exposed fc_* API)
-- ─────────────────────────────────────────────────────────────────────────────
local UIXfer = {
    movie     = "ItemTransfer",
    inst      = 0, -- your logs showed instance=0; Set/Clr also try -1 as fallback
    activeIdx = 0, -- 0 = first inv (left), 1 = second inv (right)
}

-- Replace a pane's items: write Items array, then bind to pane via fc_setItems(idx)
function UIXfer:SetItemsFor(idx, rows)
    idx = tonumber(idx) or 0
    local list = {}
    for i = 1, #rows do list[i] = toUiRow(rows[i]) end

    local movie = self.movie or "ItemTransfer"
    local insts = { self.inst or 0, -1 } -- try current instance, then broadcast

    local okArr, okFc = false, false
    for _, inst in ipairs(insts) do
        okArr = setarray(movie, inst, "Items", list) or okArr
        okFc  = uicall(movie, inst, "fc_setItems", idx) or okFc
    end

    self.activeIdx = idx
    System.LogAlways(string.format(
        "[CorpseSanitizer/UI] SetItemsFor: pane=%d rows=%d setarray=%s fc_setItems=%s (movie=%s inst=%s/%s)",
        idx, #list, tostring(okArr), tostring(okFc), tostring(movie), tostring(insts[1]), tostring(insts[2])))

    return okArr and okFc
end

-- Clear a pane (array + fc_clearItems)
function UIXfer:ClearFor(idx)
    idx = tonumber(idx) or 0
    local movie = self.movie or "ItemTransfer"
    local insts = { self.inst or 0, -1 }
    local okArr, okFc = false, false
    for _, inst in ipairs(insts) do
        okArr = setarray(movie, inst, "Items", {}) or okArr
        okFc  = uicall(movie, inst, "fc_clearItems", idx) or okFc
    end
    self.activeIdx = idx
    System.LogAlways(string.format(
        "[CorpseSanitizer/UI] ClearFor: pane=%d setarray=%s fc_clearItems=%s", idx, tostring(okArr), tostring(okFc)))
    return okArr and okFc
end

function UIXfer:SetBoth(leftRows, rightRows)
    self:SetItemsFor(0, leftRows or {})
    self:SetItemsFor(1, rightRows or {})
    return true
end

function UIXfer:RemoveIdFor(idx, id)
    idx = tonumber(idx) or 0
    uicall(self.movie or "ItemTransfer", self.inst or 0, "fc_removeItem", tostring(id), idx)
    return true
end

function UIXfer:ChangeFor(idx, row)
    idx = tonumber(idx) or 0
    setarray(self.movie or "ItemTransfer", self.inst or 0, "Items", { toUiRow(row) })
    uicall(self.movie or "ItemTransfer", self.inst or 0, "fc_changeItem", idx)
    return true
end

function UIXfer:AddFor(idx, row)
    idx = tonumber(idx) or 0
    setarray(self.movie or "ItemTransfer", self.inst or 0, "Items", { toUiRow(row) })
    uicall(self.movie or "ItemTransfer", self.inst or 0, "fc_addItem", idx)
    return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Config (defaults + merge external)
-- ─────────────────────────────────────────────────────────────────────────────
local DEFAULT_CONFIG = {
    dryRun       = true, -- log-only
    insanityMode = true,

    ui           = {
        movie        = "ItemTransfer",
        shadowDelete = false,   -- keep off for smoke test
        echoToUI     = false,   -- when true, mirror enumerated rows into SWF
        pane         = "active" -- "active" | "left" | "right" | 0 | 1
    },

    nuker        = { -- present for parity; not used in clean build
        enabled             = true,
        minHp               = 0.00,
        skipMoney           = true,
        onlyIfCorpse        = true,
        unequipBeforeDelete = false,
    },

    proximity    = { radius = 6.0, maxList = 24 },

    logging      = {
        prettyOwner     = true,
        probeOnMiss     = true,
        showWouldDelete = true,
        nuker           = true,
        dumpRows        = true, -- print per-row
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

CS.config = deepMerge({}, DEFAULT_CONFIG)
do
    local ok, overrides = pcall(dofile, "Scripts/CorpseSanitizer/CorpseSanitizerConfig.lua")
    if ok and type(overrides) == "table" then deepMerge(CS.config, overrides) end
end

local function b(x) return x and "true" or "false" end
local function logEffectiveConfig()
    local c = CS.config or {}
    System.LogAlways("[CorpseSanitizer/Config] dryRun=" .. b(c.dryRun) .. " insanityMode=" .. b(c.insanityMode))
    local ui = c.ui or {}
    System.LogAlways("[CorpseSanitizer/Config] ui.movie=" .. tostring(ui.movie) ..
        " shadowDelete=" .. b(ui.shadowDelete) .. " echoToUI=" .. b(ui.echoToUI) .. " pane=" .. tostring(ui.pane))
    local nk = c.nuker or {}
    System.LogAlways("[CorpseSanitizer/Config] nuker.enabled=" .. b(nk.enabled) ..
        " minHp=" .. tostring(nk.minHp) .. " skipMoney=" .. b(nk.skipMoney) ..
        " onlyIfCorpse=" .. b(nk.onlyIfCorpse) .. " unequipBeforeDelete=" .. b(nk.unequipBeforeDelete))
    local px = c.proximity or {}
    System.LogAlways("[CorpseSanitizer/Config] proximity.radius=" .. tostring(px.radius) ..
        " maxList=" .. tostring(px.maxList))
    local lg = c.logging or {}
    System.LogAlways("[CorpseSanitizer/Config] logging.prettyOwner=" .. b(lg.prettyOwner) ..
        " probeOnMiss=" .. b(lg.probeOnMiss) .. " showWouldDelete=" .. b(lg.showWouldDelete) ..
        " nuker=" .. b(lg.nuker) .. " dumpRows=" .. b(lg.dumpRows))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Targeting + enumeration (no engine mutations)
-- ─────────────────────────────────────────────────────────────────────────────
local function getPlayer()
    return _G.g_localActor or (_G.System and _G.System.GetLocalPlayer and System.GetLocalPlayer())
end

local function getPlayerPos()
    local a = getPlayer()
    if a and a.GetPos then
        local ok, p = pcall(a.GetPos, a)
        if ok and p then return p end
    end
    return nil
end

local function scanNearby(radius)
    radius = radius or (CS.config.proximity and CS.config.proximity.radius) or 6.0
    local pos = getPlayerPos()
    if not pos then return {} end
    if System and System.GetEntitiesInSphere then
        local ok, ents = pcall(System.GetEntitiesInSphere, pos, radius)
        if ok and type(ents) == "table" then return ents end
    end
    return {}
end

local function isHumanoid(e)
    local cls = tostring(e and e.class or "")
    return (cls == "NPC") or (cls == "Human") or (cls == "AI") or (cls:find("deadBody", 1, true) ~= nil)
end

local function findNearestHumanoid(radius)
    local list = scanNearby(radius)
    local best, bestD2
    local pl = getPlayerPos()
    for i = 1, #list do
        local e = list[i]
        if e and isHumanoid(e) and e.GetPos and pl then
            local ok, p = pcall(e.GetPos, e)
            if ok and p and p.x then
                local dx, dy, dz = (p.x - pl.x), (p.y - pl.y), (p.z - pl.z)
                local d2 = dx * dx + dy * dy + dz * dz
                if not bestD2 or d2 < bestD2 then best, bestD2 = e, d2 end
            end
        end
    end
    return best, bestD2
end

-- Enumerate NPC inventory robustly (0-based, 1-based, or sparse), no mutations
local function enumNPCInventory(npc)
    local inv = npc and npc.inventory
    if inv and type(inv.GetInventoryTable) == "function" then
        local ok, t = pcall(inv.GetInventoryTable, inv)
        if ok and type(t) == "table" then
            local rows = {}
            local via  = "inventory:GetInventoryTable (raw keys walked)"
            if t[0] ~= nil then
                local max = -1
                for k in pairs(t) do
                    if type(k) == "number" and k > max then max = k end
                end
                for i = 0, max do rows[#rows + 1] = t[i] end
            else
                for i = 1, #t do rows[#rows + 1] = t[i] end
                local seen = {}
                for i = 1, #t do seen[i] = true end
                for k, v in pairs(t) do
                    if not seen[k] then rows[#rows + 1] = v end
                end
            end
            return rows, via
        end
    end
    return nil, "no-enumerator"
end

-- iterate any table and yield zero-based index + row (works for 0/1-based/sparse)
local function inv_iter0(t)
    if type(t) ~= "table" then
        return function() return nil end
    end
    if t[0] ~= nil then
        local max = -1
        for k in pairs(t) do if type(k) == "number" and k > max then max = k end end
        local i = -1
        return function()
            i = i + 1; if i <= max then return i, t[i] end
        end
    end
    local n = #t
    if n > 0 then
        local i = 0
        return function()
            i = i + 1; if i <= n then return (i - 1), t[i] end
        end
    end
    local k = nil
    return function()
        k = next(t, k); if k ~= nil then return 0, t[k] end
    end
end

-- pretty-print one row (safe)
local function logRow(i0, row)
    -- Safe coercers
    local function num(x, d)
        local n = tonumber(x); if n == nil then return d end; return n
    end
    local function str(x) if x == nil then return "nil" else return tostring(x) end end

    local class = str(row and (row.class or row.Class) or "?")
    local name  = str(row and (row.name or row.displayName or class) or "?")
    local amt   = num(row and (row.amt or row.amount or row.count), 1)
    local hp    = num(row and (row.hp or row.health or row.Health), 1.0)
    -- Normalize hp if it looks like 0–100 instead of 0–1
    if hp > 1.001 and hp <= 100 then hp = hp / 100 end
    local handle = row and (row.handle or row.Handle or row.Id or row.id)

    local ownerStr = ""
    if ItemManager and ItemManager.GetItemOwner and handle then
        local ok, own = pcall(ItemManager.GetItemOwner, handle)
        if ok and own then ownerStr = " owner=" .. tostring(own) end
    end

    System.LogAlways(string.format(
        "[CorpseSanitizer]   [%d] class=%s name=%s hp=%.2f amt=%s handle=%s%s",
        i0, class, name, hp, tostring(amt), tostring(handle), ownerStr))
end


-- Dump rows robustly; count by iterating (don’t trust #t), guard logRow with pcall
local function logInventoryRows(items, how, maxRows)
    maxRows = maxRows or 100
    System.LogAlways("[CorpseSanitizer] Enumerator used: " .. tostring(how))
    local shown, total = 0, 0
    for i0, row in inv_iter0(items) do
        total = total + 1
        if shown < maxRows then
            local ok, err = pcall(logRow, i0, row)
            if not ok then
                System.LogAlways("[CorpseSanitizer] logRow error: " .. tostring(err))
                -- Fallback: print raw fields without numeric formatting
                local cls = tostring(row and (row.class or row.Class) or "?")
                local nm  = tostring(row and (row.name or row.displayName or cls) or "?")
                local amt = tostring(row and (row.amt or row.amount or row.count) or "?")
                local hpv = tostring(row and (row.hp or row.health or row.Health) or "?")
                local hnd = tostring(row and (row.handle or row.Handle or row.Id or row.id) or "nil")
                System.LogAlways(string.format(
                    "[CorpseSanitizer]   [%d] (fallback) class=%s name=%s hp=%s amt=%s handle=%s",
                    i0, cls, nm, hpv, amt, hnd))
            end

            shown = shown + 1
        end
    end
    System.LogAlways(string.format("[CorpseSanitizer] Inventory dump: %d row(s) shown (total=%d)", shown, total))
    if total > shown then
        System.LogAlways(string.format("[CorpseSanitizer] ... %d more row(s) not shown", total - shown))
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- UI listeners
-- ─────────────────────────────────────────────────────────────────────────────
local function resolvePaneIdx()
    local p = CS and CS.config and CS.config.ui and CS.config.ui.pane
    if p == "left" then return 0 end
    if p == "right" then return 1 end
    if p == "active" or p == nil then return UIXfer.activeIdx or 0 end
    local n = tonumber(p); if n == 0 or n == 1 then return n end
    return UIXfer.activeIdx or 0
end

function CorpseSanitizer:OnOpened(elementName, instanceId, eventName, args)
    log("OnOpened → transfer UI visible (element=" ..
        tostring(elementName) .. ", instance=" .. tostring(instanceId) .. ")")

    local radius = (CS.config.proximity and CS.config.proximity.radius) or 6.0
    local npc, d2 = findNearestHumanoid(radius)
    if npc then
        local npcName = "<npc>"
        if npc.GetName then pcall(function() npcName = npc:GetName() end) end
        local dist = d2 and math.sqrt(d2) or 0
        log(string.format("Nearby target: %s (d=%.2fm)", tostring(npcName), dist))

        local items, how = enumNPCInventory(npc)
        if items and type(items) == "table" then
            if not CS.config.logging or CS.config.logging.dumpRows ~= false then
                logInventoryRows(items, how, 100)
            end

            local ui = CS.config.ui
            if ui and ui.echoToUI then
                UIXfer.movie = ui.movie or "ItemTransfer"
                local pane = resolvePaneIdx()
                local ok = UIXfer:SetItemsFor(pane, items)
                if not ok then
                    System.LogAlways("[CorpseSanitizer/UI] echo failed; trying both panes")
                    UIXfer:SetItemsFor(0, items)
                    UIXfer:SetItemsFor(1, items)
                end
            end
        else
            log("No enumerable items for nearby target (" .. tostring(how) .. ")")
            if CS.config.logging and CS.config.logging.probeOnMiss then
                log("Hint: read-only bodies / quest containers may block this lane.")
            end
            local ui = CS.config.ui
            if ui and ui.echoToUI then
                local pane = resolvePaneIdx()
                UIXfer:ClearFor(pane)
            end
        end
    else
        log("No humanoid within " .. tostring(radius) .. " m")
    end
end

function CorpseSanitizer:OnClosed(elementName, instanceId, eventName, args)
    log("OnClosed (element=" .. tostring(elementName) .. ", instance=" .. tostring(instanceId) .. ")")
end

function CorpseSanitizer:OnViewChanged(elementName, instanceId, eventName, args)
    local cid
    if type(args) == "table" then
        cid = args.ClientId or args.clientId or args[1]
    else
        cid = args
    end
    local n = tonumber(cid) or 0
    UIXfer.activeIdx = n
    System.LogAlways(string.format("[CorpseSanitizer] OnViewChanged → active pane=%d", n))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Bootstrap / Shutdown
-- ─────────────────────────────────────────────────────────────────────────────
function CorpseSanitizer.Bootstrap()
    if CS.booted then return end
    CS.booted    = true

    local ui     = CS.config.ui or {}
    UIXfer.movie = ui.movie or "ItemTransfer"
    UIXfer.inst  = 0

    System.LogAlways("[CorpseSanitizer] BOOT ok (version=" ..
        tostring(CS.version) .. ", Lua=" .. tostring(_VERSION) .. ")")
    logEffectiveConfig()

    if UIAction and UIAction.RegisterElementListener then
        UIAction.RegisterElementListener(CorpseSanitizer, UIXfer.movie, -1, "OnOpened", "OnOpened")
        UIAction.RegisterElementListener(CorpseSanitizer, UIXfer.movie, -1, "OnClosed", "OnClosed")
        UIAction.RegisterElementListener(CorpseSanitizer, UIXfer.movie, -1, "OnViewChanged", "OnViewChanged")
        log("Registered UI listeners for " .. tostring(UIXfer.movie))
    else
        log("UIAction missing; cannot register UI listeners")
    end
end

function CorpseSanitizer.Shutdown()
    CS.booted = false
    -- If your engine exposes an Unregister, call it here.
end
