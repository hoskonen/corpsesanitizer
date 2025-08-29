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

-- Forward declares so locals are captured as upvalues inside functions defined earlier
local enumNPCInventory
local hideNameFromTransfer
local hideClassFromTransfer
local resolvePaneIdx
local resolveRow
local toUiRow

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

-- Simple "later" helper: use engine timer if available, else run immediately
local function later(ms, fn)
    if Script and Script.SetTimer then
        Script.SetTimer(ms, fn)
    else
        local ok, err = pcall(fn)
        if not ok then System.LogAlways("[CorpseSanitizer] later() fallback error: " .. tostring(err)) end
    end
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

-- handle/userdata or table row -> handle,it,classId,name,amount,hp
-- 1) Resolve engine row (userdata/table) into usable fields
local function resolveRow(row)
    local handle, it, classId, name, amount, hp

    if type(row) == "userdata" then
        handle = row
        if ItemManager and ItemManager.GetItem then
            local ok, itm = pcall(ItemManager.GetItem, handle)
            if ok and itm then it = itm end
        end
    elseif type(row) == "table" then
        it     = row
        handle = row.handle or row.Handle or row.Id or row.id
    end

    if it then classId = it.class or it.Class end
    if not classId and type(row) == "table" then classId = row.class or row.Class end
    classId = classId and tostring(classId) or "unknown"

    if ItemManager and ItemManager.GetItemName then
        local ok, nm = pcall(ItemManager.GetItemName, classId) -- KCD: expects classId
        if ok and nm and nm ~= "" then name = tostring(nm) end
    end
    if not name and type(it) == "table" and type(it.GetName) == "function" then
        local ok, nm = pcall(it.GetName, it); if ok and nm and nm ~= "" then name = tostring(nm) end
    end
    if not name then name = classId end

    amount = tonumber((it and (it.amount or it.Amount or it.count or it.Count)) or 1) or 1

    hp = tonumber((it and (it.health or it.Health or it.hp or it.HP)) or 1.0) or 1.0
    if hp > 1.001 and hp <= 100 then hp = hp / 100 end

    return handle, it, classId, name, amount, hp
end

-- 2) Build a row object the SWF can consume
local function toUiRow(row)
    local handle, it, classId, name, amount, hp = resolveRow(row)

    -- Prefer handle as unique Id (string). SWF RemoveItem typically uses "Id".
    local id = handle and tostring(handle)
    if not id then
        id = string.format("cs_%s_%s_%s_%d", classId, tostring(amount), tostring(hp), os.time())
    end

    -- Provide both lower- and UpperCamel keys—some SWFs expect one or the other.
    local ui = {
        id = id,
        Id = id,
        name = name,
        Name = name,
        class = classId,
        Class = classId,
        amount = amount,
        Amount = amount,
        hp = hp,
        Hp = hp,
        icon = "",
        Icon = "",
    }
    return ui
end

-- Push a list into ItemTransfer (paneIdx: 0=left, 1=right)
local function pushItemsToPane(paneIdx, rows, inst)
    local idx    = tonumber(paneIdx) or 0
    local instId = (inst ~= nil) and inst or ((UIXfer and UIXfer.inst) or 0)

    if not (UIAction and UIAction.SetArray and UIAction.CallFunction) then
        System.LogAlways("[CorpseSanitizer/UI] UIAction missing; cannot push items")
        return false
    end

    -- build lists
    local items, info, built = {}, {}, 0
    for i = 1, #rows do
        local ok, uirow = pcall(toUiRow, rows[i])
        if ok and uirow then
            items[#items + 1] = uirow
            info[#info + 1]   = { Id = uirow.Id, Hp = uirow.Hp, Amount = uirow.Amount }
            built             = built + 1
        else
            System.LogAlways("[CorpseSanitizer/UI] toUiRow fail at " .. tostring(i - 1))
        end
    end
    System.LogAlways(string.format("[CorpseSanitizer/UI] built %d/%d ui rows", built, #rows))

    -- clear first
    local okClr = pcall(UIAction.CallFunction, "ItemTransfer", instId, "fc_clearItems", idx)
    System.LogAlways("[CorpseSanitizer/UI] fc_clearItems -> " .. tostring(okClr))

    -- write arrays (try both 'name' and 'varname' from XML)
    local okA   = pcall(UIAction.SetArray, "ItemTransfer", instId, "Items", items)
    local okAi  = pcall(UIAction.SetArray, "ItemTransfer", instId, "ItemInfo", info)
    local okG   = pcall(UIAction.SetArray, "ItemTransfer", instId, "g_ItemsA", items)
    local okGi  = pcall(UIAction.SetArray, "ItemTransfer", instId, "g_ItemInfoA", info)

    -- commit
    local okSet = pcall(UIAction.CallFunction, "ItemTransfer", instId, "fc_setItems", idx)

    System.LogAlways(string.format(
        "[CorpseSanitizer/UI] push pane=%s inst=%s list=%d SA=%s SAinfo=%s SAg=%s SAginfo=%s set=%s",
        tostring(idx), tostring(instId), #items, tostring(okA), tostring(okAi), tostring(okG), tostring(okGi),
        tostring(okSet)
    ))
    return okSet
end

-- Hide one class id (faster / unambiguous)
function hideClassFromTransfer(npc, paneIdx, classId)
    local items, how = enumNPCInventory(npc)
    if type(items) ~= "table" then
        System.LogAlways("[CorpseSanitizer/UI] hideClassFromTransfer: no items (" .. tostring(how) .. ")")
        return
    end
    local kept = {}
    for i = 1, #items do
        local it = items[i]
        local cls = (type(it) == "table" and (it.class or it.Class)) or tostring(it)
        if tostring(cls) ~= tostring(classId) then
            kept[#kept + 1] = it
        end
    end
    pushItemsToPane(paneIdx or 0, kept)
end

-- Hide by engine *name* (e.g., "appleDried"), case-insensitively
-- forward declare if enumNPCInventory is defined later:
-- local enumNPCInventory

function hideNameFromTransfer(npc, paneIdx, targetName)
    System.LogAlways("[CorpseSanitizer/UI] hideNameFromTransfer enter pane=" ..
        tostring(paneIdx) .. " target=" .. tostring(targetName))
    if not npc then
        System.LogAlways("[CorpseSanitizer/UI] hideNameFromTransfer: npc=nil")
        return
    end

    local items, how = enumNPCInventory(npc)
    System.LogAlways("[CorpseSanitizer/UI] enum -> items=" ..
        tostring(items) .. " type=" .. tostring(type(items)) .. " how=" .. tostring(how))
    if type(items) ~= "table" then
        System.LogAlways("[CorpseSanitizer/UI] hideNameFromTransfer: no items (" .. tostring(how) .. ")")
        return
    end

    local want = string.lower(tostring(targetName or ""))

    local kept, removed = {}, 0
    for i = 1, #items do
        local row = items[i]
        local handle, it, classId, engName = resolveRow(row)
        local nm = engName or classId or "?"

        local keep = (string.lower(nm) ~= want)
        System.LogAlways(string.format(
            "[CorpseSanitizer/UI] row[%d] cls=%s name=%s keep=%s (handle=%s it=%s)",
            i - 1, tostring(classId), tostring(nm), tostring(keep), tostring(handle), tostring(it)))

        if keep then kept[#kept + 1] = row else removed = removed + 1 end
    end

    System.LogAlways(string.format("[CorpseSanitizer/UI] filter result: kept=%d removed=%d", #kept, removed))
    local ok = pushItemsToPane(paneIdx, kept)
    System.LogAlways("[CorpseSanitizer/UI] push result=" .. tostring(ok))
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
    return System.GetEntityByName("Henry") or System.GetEntityByName("dude")
end

local function getPlayerPos()
    local a = getPlayer()
    if a and a.GetPos then
        local ok, p = pcall(a.GetPos, a)
        if ok and p then return p end
    end
    return nil
end

local function getNameByClassId(classId)
    if not (ItemManager and ItemManager.GetItemName) then return nil end
    if not classId or classId == "" then return nil end
    local ok, nm = pcall(ItemManager.GetItemName, classId)
    if ok and nm and nm ~= "" then return tostring(nm) end
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
function enumNPCInventory(npc)
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

local function logRow(i0, row)
    -- Resolve handle + item
    local handle, it
    if type(row) == "userdata" then
        handle = row
        if ItemManager and ItemManager.GetItem then
            local ok, itm = pcall(ItemManager.GetItem, handle)
            if ok and itm then it = itm end
        end
        row = it or {} -- continue with a table either way
    elseif type(row) == "table" then
        it = row
        handle = row.handle or row.Handle or row.id or row.Id
    else
        System.LogAlways(string.format(
            "[CorpseSanitizer]   [%s] (unsupported row type) type=%s repr=%s",
            tostring(i0), tostring(type(row)), tostring(row)))
        return
    end

    -- Class/amount/hp (coerced safely)
    local class = tostring(it.class or it.Class or row.class or row.Class or "?")
    local amt   = tonumber(it.amount or it.Amount or row.amount or row.Amount or row.count or row.Count or 1) or 1
    local hp    = tonumber(it.health or it.Health or row.health or row.Health or it.hp or it.HP or row.hp or row.HP or
        1.0) or 1.0
    if hp > 1.001 and hp <= 100 then hp = hp / 100 end

    -- NAME: by CLASS id, then item method fallback
    local name = getNameByClassId(class)

    if (not name or name == "") and type(it) == "table" and type(it.GetName) == "function" then
        local ok, nm = pcall(it.GetName, it)
        if ok and nm and nm ~= "" then name = tostring(nm) end
    end

    if not name or name == "" then name = class end

    local owner
    if handle and ItemManager and ItemManager.GetItemOwner then
        local ok, w = pcall(ItemManager.GetItemOwner, handle)
        if ok and w then owner = w end
    end

    -- then your final print (keep the rest of your fields as-is)
    System.LogAlways(string.format(
        "[CorpseSanitizer]   [%s] class=%s name=%s hp=%s amt=%s handle=%s%s",
        tostring(i0), tostring(class), tostring(name), string.format('%.2f', hp),
        tostring(amt), tostring(handle), owner and (" owner=" .. tostring(owner)) or ""
    ))
end

-- Dump rows robustly; count by iterating (don't trust #t), guard logRow with pcall
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
                System.LogAlways(string.format(
                    "[CorpseSanitizer]   [%s] (raw) type=%s repr=%s",
                    tostring(i0), tostring(type(row)), tostring(row)))
            end

            shown = shown + 1
        end
    end
    System.LogAlways(string.format("[CorpseSanitizer] Inventory dump: %d row(s) shown (total=%d)", shown, total))
    if total > shown then
        System.LogAlways(string.format("[CorpseSanitizer] ... %d more row(s) not shown", total - shown))
    end
end

-- Remove all rows whose engine name matches `targetName` by trying id=(i) and id=(i-1) and handle-string
local function guessRemoveByName(npc, paneIdx, targetName)
    local items, how = enumNPCInventory(npc)
    if type(items) ~= "table" then
        System.LogAlways("[CorpseSanitizer/UI] guessRemoveByName: no items (" .. tostring(how) .. ")")
        return 0
    end
    local pane = tonumber(paneIdx) or 0
    local removed = 0
    for i = 1, #items do
        local row = items[i]
        local handle, it, classId, name = resolveRow(row) -- your resolver: handle->item->classId->nice name
        local nm = string.lower(tostring(name or classId or "?"))
        if nm == string.lower(tostring(targetName or "")) then
            local id1 = tostring(i)     -- 1-based guess
            local id0 = tostring(i - 1) -- 0-based fallback
            local idH = handle and tostring(handle) or nil

            local ok1 = pcall(UIAction.CallFunction, "ItemTransfer", UIXfer.inst or 0, "fc_removeItem", id1, pane)
            local ok0 = pcall(UIAction.CallFunction, "ItemTransfer", UIXfer.inst or 0, "fc_removeItem", id0, pane)
            local okH = idH and
                pcall(UIAction.CallFunction, "ItemTransfer", UIXfer.inst or 0, "fc_removeItem", idH, pane) or false

            System.LogAlways(string.format(
                "[CorpseSanitizer/UI] remove try idx=%d nm=%s ids={%s,%s,%s} -> {%s,%s,%s}",
                i - 1, tostring(name), id1, id0, tostring(idH), tostring(ok1), tostring(ok0), tostring(okH)
            ))
            if ok1 or ok0 or okH then removed = removed + 1 end
        end
    end
    System.LogAlways("[CorpseSanitizer/UI] guessRemoveByName removed=" .. tostring(removed))
    return removed
end

-- Remove all rows whose engine name or classId equals target (case-insensitive)
-- Remove all rows whose engine name or classId equals target (case-insensitive),
-- trying multiple Id forms so SWF Remove() matches one.
local function pruneByName(npc, paneIdx, target)
    local items, how = enumNPCInventory(npc)
    if type(items) ~= "table" then
        System.LogAlways("[CorpseSanitizer/UI] pruneByName: no items (" .. tostring(how) .. ")")
        return 0
    end
    local want = string.lower(tostring(target or ""))
    local pane = tonumber(paneIdx) or 0
    local removed = 0

    for i = 1, #items do
        local row = items[i]
        local handle, it, classId, name = resolveRow(row)
        local nm = string.lower(tostring(name or classId or "?"))
        if nm == want then
            local id1 = tostring(i)     -- 1-based guess (common)
            local id0 = tostring(i - 1) -- 0-based fallback
            local idH = handle and tostring(handle) or nil

            local ok1 = pcall(UIAction.CallFunction, "ItemTransfer", UIXfer.inst or 0, "fc_removeItem", id1, pane)
            local ok0 = pcall(UIAction.CallFunction, "ItemTransfer", UIXfer.inst or 0, "fc_removeItem", id0, pane)
            local okH = idH and
                pcall(UIAction.CallFunction, "ItemTransfer", UIXfer.inst or 0, "fc_removeItem", idH, pane) or false

            System.LogAlways(string.format(
                "[CorpseSanitizer/UI] remove idx=%d name=%s ids={%s,%s,%s} -> {%s,%s,%s}",
                i - 1, tostring(name), id1, id0, tostring(idH), tostring(ok1), tostring(ok0), tostring(okH)
            ))
            if ok1 or ok0 or okH then removed = removed + 1 end
        end
    end

    System.LogAlways("[CorpseSanitizer/UI] pruneByName removed=" .. tostring(removed))
    return removed
end

local function rebuildPaneWithout(npc, paneIdx, bannedName)
    local items, how = enumNPCInventory(npc)
    if type(items) ~= "table" then return false end
    local want = string.lower(bannedName or "")
    local arr = {}
    -- Count placeholder; we’ll fix it after we push rows
    arr[1] = 0
    local count = 0

    for i = 1, #items do
        local handle, it, classId, name, amount, hp = resolveRow(items[i])
        local nm = string.lower(tostring(name or classId or "?"))
        if nm ~= want then
            -- each row: push Id, then the InventoryItem.Set() fields
            local id = tostring(i)                       -- any unique string is fine
            arr[#arr + 1] = id
            arr[#arr + 1] = name or classId or "Unknown" -- Name
            arr[#arr + 1] = classId or "unknown"         -- ClassId
            arr[#arr + 1] = 0                            -- Category (0 = SWF maps via GetCategoryId)
            arr[#arr + 1] = "Common"                     -- IconId
            arr[#arr + 1] = tonumber(amount or 1) or 1   -- Amount
            arr[#arr + 1] = 0                            -- MainStat
            arr[#arr + 1] = tonumber(hp or 1.0) or 1.0   -- Health (0..1)
            arr[#arr + 1] = 0                            -- Quality
            arr[#arr + 1] = 0                            -- HealthState
            arr[#arr + 1] = 0.0                          -- Weight
            arr[#arr + 1] = 0                            -- Price
            arr[#arr + 1] = true                         -- IsEnable
            arr[#arr + 1] = false                        -- OutfitPresence
            arr[#arr + 1] = false                        -- IsQuestItem
            arr[#arr + 1] = false                        -- IsNew
            arr[#arr + 1] = 0                            -- Stolen
            arr[#arr + 1] = 0.0                          -- Dirt
            arr[#arr + 1] = 0                            -- Blood
            arr[#arr + 1] = 0                            -- BuffIcon
            arr[#arr + 1] = 0                            -- BuffDefId
            arr[#arr + 1] = false                        -- IsRepainted
            count = count + 1
        end
    end

    arr[1] = count -- fix the count at the start
    local pane = tonumber(paneIdx) or 0
    local inst = UIXfer and (UIXfer.inst or 0) or 0
    local okA = pcall(UIAction.SetArray, "ItemTransfer", inst, "g_ItemsA", arr)
    local okS = pcall(UIAction.CallFunction, "ItemTransfer", inst, "fc_setItems", pane)
    System.LogAlways(string.format("[CorpseSanitizer/UI] fc_setItems filtered pane=%s count=%d -> setArray=%s set=%s",
        tostring(pane), count, tostring(okA), tostring(okS)))
    return okA and okS
end


-- ─────────────────────────────────────────────────────────────────────────────
-- UI listeners
-- ─────────────────────────────────────────────────────────────────────────────
function resolvePaneIdx()
    local p = CS and CS.config and CS.config.ui and CS.config.ui.pane
    if p == "left" then return 0 end
    if p == "right" then return 1 end
    if p == "active" or p == nil then return UIXfer.activeIdx or 0 end
    local n = tonumber(p); if n == 0 or n == 1 then return n end
    return UIXfer.activeIdx or 0
end

function CorpseSanitizer:OnOpened(elementName, instanceId, eventName, args)
    UIXfer.movie = (CS.config.ui and CS.config.ui.movie) or "ItemTransfer"
    if instanceId ~= nil then UIXfer.inst = instanceId end
    log("OnOpened → transfer UI visible (element=" .. tostring(elementName) .. ", instance=" .. tostring(instanceId) ..
        ")")

    local radius = (CS.config.proximity and CS.config.proximity.radius) or 6.0
    local npc, d2 = findNearestHumanoid(radius)
    if not npc then
        log("No humanoid within " .. tostring(radius) .. " m")
        return
    end

    local npcName = "<npc>"
    if npc.GetName then pcall(function() npcName = npc:GetName() end) end
    local dist = d2 and math.sqrt(d2) or 0
    log(string.format("Nearby target: %s (d=%.2fm)", tostring(npcName), dist))

    local items, how = enumNPCInventory(npc)
    if items and type(items) == "table" then
        if not CS.config.logging or CS.config.logging.dumpRows ~= false then
            logInventoryRows(items, how, 100)
        end

        -- Let the SWF finish its initial bind, then sanitize both panes
        later(150, function()
            local inst = UIXfer and (UIXfer.inst or 0) or 0

            for pane = 0, 1 do
                pcall(UIAction.CallFunction, "ItemTransfer", inst, "fc_clearItems", pane)
                local ok = pcall(rebuildPaneWithout, npc, pane, "appleDried")
                System.LogAlways(string.format("[CorpseSanitizer/UI] rebuildPaneWithout pane=%d -> %s", pane,
                    tostring(ok)))
            end

            -- Gentle repaint nudge
            pcall(UIAction.CallFunction, "ItemTransfer", inst, "fc_sortNext")
            pcall(UIAction.CallFunction, "ItemTransfer", inst, "fc_sortPrev")
        end)

        -- OPTIONAL: re-apply when user flips views/tabs/sorts
        -- if UIAction and UIAction.RegisterElementListener then
        --     UIAction.RegisterElementListener(self, UIXfer.movie, UIXfer.inst, "OnViewChanged", "OnViewChanged")
        -- end
    else
        log("No enumerable items for nearby target (" .. tostring(how) .. ")")
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

-- Store last focused/clicked id per pane
CS.ui.last = CS.ui.last or { id = nil, pane = 0 }

function CorpseSanitizer:OnFocusChanged(element, inst, event, args)
    -- args.Ids is a string, could contain multiple ids separated by space
    local ids    = args and args.Ids or args and args[1]
    local client = args and (args.ClientId or args[4]) or 0
    if ids and ids ~= "" then
        CS.ui.last.id   = ids
        CS.ui.last.pane = tonumber(client) or 0
        System.LogAlways(string.format("[CorpseSanitizer/UI] focus ids=%s pane=%s", tostring(ids), tostring(client)))
    end
end

function CorpseSanitizer:OnDoubleClicked(element, inst, event, args)
    local ids    = args and args.Ids or args and args[1]
    local client = args and (args.ClientId or args[2]) or 0
    System.LogAlways(string.format("[CorpseSanitizer/UI] doubleclick ids=%s pane=%s", tostring(ids), tostring(client)))
    -- dev probe: try to remove the clicked row by its SWF Id
    if UIAction and UIAction.CallFunction and ids and ids ~= "" then
        local ok = pcall(UIAction.CallFunction, "ItemTransfer", UIXfer.inst or 0, "fc_removeItem", tostring(ids),
            tonumber(client) or 0)
        System.LogAlways("[CorpseSanitizer/UI] fc_removeItem(" ..
            tostring(ids) .. "," .. tostring(client) .. ") -> " .. tostring(ok))
    end
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
        UIAction.RegisterElementListener(CorpseSanitizer, UIXfer.movie, UIXfer.inst, "OnFocusChanged", "OnFocusChanged")
        UIAction.RegisterElementListener(CorpseSanitizer, UIXfer.movie, UIXfer.inst, "OnDoubleClicked", "OnDoubleClicked")
        log("Registered UI listeners for " .. tostring(UIXfer.movie))
    else
        log("UIAction missing; cannot register UI listeners")
    end
end

function CorpseSanitizer.Shutdown()
    CS.booted = false
    -- If your engine exposes an Unregister, call it here.
end
