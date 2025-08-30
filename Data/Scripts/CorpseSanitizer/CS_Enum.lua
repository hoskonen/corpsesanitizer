-- Scripts/CorpseSanitizer/CS_Enum.lua
local CS = CorpseSanitizer
local log = CS._log

-- Resolve a row (userdata handle or table) to an item table when possible
function CS.resolveItemEntry(row)
    if type(row) == "table" then return row end
    if type(row) == "userdata" and ItemManager and ItemManager.GetItem then
        local ok, it = pcall(ItemManager.GetItem, row)
        if ok and it then return it end
    end
end

-- Enumerate a subject's inventory using your common, working lane first
-- Feel free to replace with your richer version later
function CS.enumSubject(subject)
    if not subject then return nil, "noSubject" end
    local inv = subject.inventory or subject.container or subject.stash
    if inv and inv.GetInventoryTable then
        local ok, t = pcall(inv.GetInventoryTable, inv)
        if ok and type(t) == "table" then return t, "inventory:GetInventoryTable" end
    end
    return nil, "noenum"
end

-- Pretty logging (keeps your console readable)
function CS.logInventoryRows(items, how, maxRows)
    maxRows = maxRows or 50
    local n = 0
    for k, v in pairs(items or {}) do
        if n >= maxRows then break end
        n            = n + 1
        local handle = (type(v) == "userdata") and v or (type(v) == "table" and (v.id or v.Id or v.handle or v.Handle))
        local it     = CS.resolveItemEntry(v)
        local class  = (it and (it.class or it.Class)) or (type(v) == "table" and (v.class or v.Class)) or "?"
        local name   = class
        if class and ItemManager and ItemManager.GetItemName then
            local okNm, nm = pcall(ItemManager.GetItemName, tostring(class))
            if okNm and nm and nm ~= "" then name = nm end
        end
        local hp = (it and (it.health or it.Health or it.cond)) or 1.0
        if type(hp) == "number" and hp > 1.001 and hp <= 100 then hp = hp / 100 end
        local amt = (it and (it.amount or it.Amount)) or
        (type(v) == "table" and (v.amount or v.Amount or v.count or v.Count)) or 1
        log(string.format("  [%s] class=%s name=%s hp=%.2f amt=%s handle=%s",
            tostring(k), tostring(class), tostring(name), tonumber(hp) or 1.0, tostring(amt), tostring(handle)))
    end
    log(string.format("Inventory dump: %d row(s) shown (total≈%d)", n, CS.countKeys(items or {})))
end
