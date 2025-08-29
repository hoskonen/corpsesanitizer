-- Module header: expose ONE global table
CorpseSanitizer = CorpseSanitizer or {
    version = "0.4.0",
    booted  = false,
    ui      = { active = false },
    _loot   = { lastWUID = nil, lastOwnerId = nil },
}
local CS = CorpseSanitizer

-- ==== ItemTransfer UI Controller (Lua 5.1) ===================================
local UIXfer = {
    movie     = "ItemTransfer", -- .gfx element name
    inst      = -1,             -- instance (-1 broadcasts)
    probed    = false,
    addSigs   = {},             -- e.g. "ApseInventoryList::AddItem"
    remSigs   = {},             -- e.g. "ApseInventoryList::RemoveItemById"
    clrSigs   = {},             -- e.g. "ItemTransfer::ClearItems"
    refSigs   = {},             -- e.g. "ItemTransfer::RefreshData"
    arrayKeys = {},             -- discovered SetArray keys (e.g. "ItemsA")
}

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

-- normalize an engine item row into a SWF row
local function toUiRow(row)
    local id     = tostring((row.id or row.Id or row.stackId or row.StackId or row.handle or row.Handle) or
        ("cs_" .. tostring(os.time())))
    local name   = tostring(row.name or row.displayName or row.class or "Unknown")
    local class  = tostring(row.class or row.Class or "unknown")
    local amount = tonumber(row.amt or row.amount or row.count or 1) or 1
    local hp     = row.hp or row.health or row.Health or 1.0
    if type(hp) == "number" and hp > 1.001 then hp = hp / 100 end
    local icon = tostring(row.icon or "")
    return { id = id, name = name, class = class, amount = amount, hp = hp, icon = icon }
end

-- ==== ItemTransfer UI Controller (bound to exposed fc_* API) ================
local UIXfer = {
    movie     = "ItemTransfer",
    inst      = 0, -- your logs showed instance=0; change to -1 if your build needs broadcast
    activeIdx = 0, -- 0 = first inv (left), 1 = second inv (right)
}

-- Replace a pane's items: write array, then bind to pane via fc_setItems(idx)
function UIXfer:SetItemsFor(idx, rows)
    idx = tonumber(idx) or 0
    local list = {}
    for i = 1, #rows do list[i] = toUiRow(rows[i]) end
    setarray(self.movie, self.inst, "Items", list)    -- <arrays name="Items" varname="g_ItemsA">
    uicall(self.movie, self.inst, "fc_setItems", idx) -- <function funcname="fc_setItems">
    self.activeIdx = idx
    return true
end

-- Clear a pane (array + fc_clearItems)
function UIXfer:ClearFor(idx)
    idx = tonumber(idx) or 0
    setarray(self.movie, self.inst, "Items", {})
    uicall(self.movie, self.inst, "fc_clearItems", idx) -- <function funcname="fc_clearItems">
    self.activeIdx = idx
    return true
end

-- Convenience: set both panes in one go
function UIXfer:SetBoth(leftRows, rightRows)
    self:SetItemsFor(0, leftRows or {})
    self:SetItemsFor(1, rightRows or {})
    return true
end

-- Remove a specific row by id from a pane
function UIXfer:RemoveIdFor(idx, id)
    idx = tonumber(idx) or 0
    uicall(self.movie, self.inst, "fc_removeItem", tostring(id), idx) -- <function funcname="fc_removeItem">
    return true
end

-- Change a specific row (conservative: stage item in Items, then fc_changeItem)
function UIXfer:ChangeFor(idx, row)
    idx = tonumber(idx) or 0
    setarray(self.movie, self.inst, "Items", { toUiRow(row) })
    uicall(self.movie, self.inst, "fc_changeItem", idx) -- <function funcname="fc_changeItem">
    return true
end

-- Optional: single-add path (stage one row, then fc_addItem)
function UIXfer:AddFor(idx, row)
    idx = tonumber(idx) or 0
    setarray(self.movie, self.inst, "Items", { toUiRow(row) })
    uicall(self.movie, self.inst, "fc_addItem", idx) -- <function funcname="fc_addItem">
    return true
end

-- ==== Config + logging =======================================================
local DEFAULT_CONFIG = {
    dryRun       = true, -- log-only by default
    insanityMode = true,

    ui           = {
        movie        = "ItemTransfer",
        shadowDelete = false, -- no UI mutation during smoke test
    },

    nuker        = {
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

local function log(msg) System.LogAlways("[CorpseSanitizer] " .. tostring(msg)) end

-- ==== Helpers: nearest entity + inventory enumeration ========================
local function getPlayerPos()
    local a = _G.g_localActor or (_G.System and _G.System.GetLocalPlayer and System.GetLocalPlayer())
    if a and a.GetPos then
        local ok, p = pcall(a.GetPos, a)
        if ok and p then return p end
    end
    return nil
end

-- Very conservative scan: use engine helper if available; otherwise no-op
local function scanNearby(radius)
    radius = radius or (CS.config.proximity and CS.config.proximity.radius) or 6.0
    local pos = getPlayerPos()
    if not pos then return {} end

    -- Try Cry-style sphere queries if exposed in Lua in your build
    if System and System.GetEntitiesInSphere then
        local ok, ents = pcall(System.GetEntitiesInSphere, pos, radius)
        if ok and type(ents) == "table" then return ents end
    end

    -- Fallback: nothing (keeps smoke test safe if API not exposed)
    return {}
end

local function isHumanoid(e)
    local cls = tostring(e and e.class or "")
    return (cls == "NPC") or (cls == "Human") or (cls == "AI") or (cls:find("deadBody", 1, true) ~= nil)
end

local function findNearestHumanoid(radius)
    local list = scanNearby(radius)
    local best, bestD2
    for i = 1, #list do
        local e = list[i]
        if e and isHumanoid(e) and e.GetPos then
            local ok, p = pcall(e.GetPos, e)
            local pl = getPlayerPos()
            if ok and p and pl and p.x then
                local dx, dy, dz = (p.x - pl.x), (p.y - pl.y), (p.z - pl.z)
                local d2 = dx * dx + dy * dy + dz * dz
                if not bestD2 or d2 < bestD2 then best, bestD2 = e, d2 end
            end
        end
    end
    return best, bestD2
end

local function prettyOwner(handle)
    if not (CS.config.logging and CS.config.logging.prettyOwner) then return "" end
    if ItemManager and ItemManager.GetItemOwner then
        local ok, own = pcall(ItemManager.GetItemOwner, handle)
        if ok and own then return " owner=" .. tostring(own) end
    end
    return ""
end

local function enumNPCInventory(npc)
    -- Lane: npc.inventory:GetInventoryTable()
    if npc and npc.inventory and type(npc.inventory.GetInventoryTable) == "function" then
        local ok, t = pcall(npc.inventory.GetInventoryTable, npc.inventory)
        if ok and type(t) == "table" then
            local rows, keys = {}, {}
            -- prefer numeric keys [0..N-1] if present; else use pairs
            local maxi = -1
            for k in pairs(t) do
                if type(k) == "number" and k > maxi then maxi = k end
            end
            if maxi >= 0 then
                for i = 0, maxi do keys[#keys + 1] = i end
            else
                for k in pairs(t) do keys[#keys + 1] = k end
            end

            for i = 1, #keys do
                local k = keys[i]
                local row = t[k]
                if row then rows[#rows + 1] = row end
            end

            return rows, "inventory:GetInventoryTable"
        end
    end
    return nil, "no-enumerator"
end

local function logItemsTable(items, how, max, subject)
    max = max or 25
    log("Enumerator used: " .. tostring(how) .. " (" .. tostring(#items) .. " entries shown)")
    for i = 1, math.min(#items, max) do
        local r      = items[i]
        local class  = tostring(r.class or r.Class or "?")
        local name   = tostring(r.name or r.displayName or class)
        local hp     = tonumber(r.hp or r.Health or 1.0) or 1.0
        local amt    = tonumber(r.amt or r.amount or r.count or 1) or 1
        local handle = r.handle or r.Id or r.id
        log(string.format("  [%d] class=%s (%s) hp=%.2f amt=%s%s",
            i - 1, class, name, hp, tostring(amt), prettyOwner(handle)))
    end
end

-- pretty-print a single inventory row (safe in Lua 5.1)
local function logRow(i, row)
    local class = tostring(row.class or row.Class or "?")
    local name  = tostring(row.name or row.displayName or class)
    local amt   = tonumber(row.amt or row.amount or row.count or 1) or 1
    local hp    = row.hp or row.health or row.Health or 1.0
    if type(hp) == "number" and hp > 1.001 then hp = hp / 100 end
    local handle = row.handle or row.Handle or row.Id or row.id
    local ownerStr = ""
    if ItemManager and ItemManager.GetItemOwner and handle then
        local ok, own = pcall(ItemManager.GetItemOwner, handle)
        if ok and own then ownerStr = " owner=" .. tostring(own) end
    end
    System.LogAlways(string.format(
        "[CorpseSanitizer]   [%d] class=%s name=%s hp=%.2f amt=%s handle=%s%s",
        i - 1, class, name, hp, tostring(amt), tostring(handle), ownerStr))
end

-- dump a table of rows with a header (no mutation)
-- dump a table of rows with a header (no mutation), robust against sparse/0-based
local function logInventoryRows(items, how, maxRows)
    maxRows = maxRows or 100
    local n = (type(items) == "table") and (#items or 0) or 0
    System.LogAlways(string.format("[CorpseSanitizer] Inventory dump via %s: %d row(s)",
        tostring(how), n))

    local shown = 0
    for i0, row in inv_iter0(items) do
        if row then
            local ok, err = pcall(logRow, i0, row)
            if not ok then
                System.LogAlways("[CorpseSanitizer] logRow error: " .. tostring(err) ..
                    " (i0=" .. tostring(i0) .. ", rowType=" .. tostring(type(row)) .. ")")
            end
            shown = shown + 1
            if shown >= maxRows then break end
        end
    end

    if shown < (n or 0) then
        System.LogAlways(string.format("[CorpseSanitizer] ... %d more row(s) not shown",
            (n or 0) - shown))
    end
end


-- Iterate any inventory table and always yield a zero-based index (i0), row.
local function inv_iter0(t)
    if type(t) ~= "table" then
        return function() return nil end
    end

    -- Case A: engine uses 0-based numeric keys (t[0] exists)
    if t[0] ~= nil then
        local max = -1
        for k in pairs(t) do
            if type(k) == "number" and k > max then max = k end
        end
        local i = -1
        return function()
            i = i + 1
            if i <= max then return i, t[i] end
        end
    end

    -- Case B: 1-based packed array (#t usable) → convert to zero-based
    local n = #t
    if n > 0 then
        local i = 0
        return function()
            i = i + 1
            if i <= n then return (i - 1), t[i] end
        end
    end

    -- Case C: sparse/pairs table → just walk pairs, zero-base index unknown (use 0)
    local k = nil
    return function()
        k = next(t, k)
        if k ~= nil then return 0, t[k] end
    end
end

local function dump_items_zero_based(items)
    System.LogAlways(string.format("[CorpseSanitizer] dump: %s row(s)", tostring(#items or "?")))
    for i0, row in inv_iter0(items) do
        local ok, err = pcall(logRow, i0, row)
        if not ok then
            System.LogAlways("[CorpseSanitizer] dump_items_zero_based/logRow error: " .. tostring(err))
        end
    end
end



-- ==== UI listeners ===========================================================
function CorpseSanitizer:OnOpened(elementName, instanceId, eventName, args)
    log("OnOpened → transfer UI visible (element=" ..
        tostring(elementName) .. ", instance=" .. tostring(instanceId) .. ")")

    -- 1) Try nearest humanoid within radius
    local radius = (CS.config.proximity and CS.config.proximity.radius) or 6.0
    local npc, d2 = findNearestHumanoid(radius)

    if npc then
        local npcName = (npc.GetName and pcall(npc.GetName, npc) and npc:GetName()) or "<npc>"
        local dist = d2 and math.sqrt(d2) or 0
        log(string.format("Nearby target: %s (d=%.2fm)", tostring(npcName), dist))

        local items, how = enumNPCInventory(npc)
        if items and #items > 0 then
            -- detailed, per-row logging (no mutations)
            if not CS.config.logging or CS.config.logging.dumpRows ~= false then
                logInventoryRows(items, how, 100)
                dump_items_zero_based(items)
            end
        else
            log("No enumerable items for nearby target (" .. tostring(how) .. ")")
            if CS.config.logging and CS.config.logging.probeOnMiss then
                log("Hint: WUID/stash lanes are disabled in smoke test; read-only bodies may show no items here.")
            end
        end
    else
        log("No humanoid within " .. tostring(radius) .. " m")
    end

    -- No UI or engine mutations in smoke test
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

-- Optional focus listener stub (kept for parity with some builds)
function CorpseSanitizer:OnFocusChanged(elementName, instanceId, eventName, args)
    -- noop for smoke test
end

-- ==== Bootstrap ==============================================================
function CorpseSanitizer.Bootstrap()
    if CS.booted then return end
    CS.booted    = true

    -- set UI movie/inst for helpers
    local movie  = (CS.config and CS.config.ui and CS.config.ui.movie) or "ItemTransfer"
    UIXfer.movie = movie
    UIXfer.inst  = 0 -- most of your logs showed instance=0; change to -1 if needed

    System.LogAlways("[CorpseSanitizer] BOOT ok (version=" ..
        tostring(CS.version) .. ", Lua=" .. tostring(_VERSION) .. ")")

    if UIAction and UIAction.RegisterElementListener then
        UIAction.RegisterElementListener(CorpseSanitizer, movie, -1, "OnOpened", "OnOpened")
        UIAction.RegisterElementListener(CorpseSanitizer, movie, -1, "OnClosed", "OnClosed")
        UIAction.RegisterElementListener(CorpseSanitizer, movie, -1, "OnFocusChanged", "OnFocusChanged")
        UIAction.RegisterElementListener(CorpseSanitizer, movie, -1, "OnViewChanged", "OnViewChanged")
        log("Registered UI listeners for " .. movie)
    else
        log("UIAction missing; cannot register UI listeners")
    end
end
