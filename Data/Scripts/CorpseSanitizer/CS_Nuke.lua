-- Scripts/CorpseSanitizer/CS_Nuke.lua
local CS   = CorpseSanitizer
local log  = CS._log
local nlog = CS._nlog

-- ---------- helpers: banlist ----------
local function isBannedByConfig(name, classId)
  local N = CS and CS.config and CS.config.nuker
  if not N then return false end
  local bN, bC = N.banNames or {}, N.banClasses or {}
  local n = string.lower(tostring(name or ""))
  local c = string.lower(tostring(classId or ""))
  for i = 1, #bN do if n == string.lower(tostring(bN[i])) then return true end end
  for i = 1, #bC do if c == string.lower(tostring(bC[i])) then return true end end
  return false
end

-- ---------- helpers: delete attempts (PASTE YOUR ROBUST VERSIONS IF YOU HAVE THEM) ----------
-- If you have richer lanes (global Inventory.DeleteItem, DeleteItemOfClass, etc.),
-- PASTE THEM HERE to replace these basics.

local function tryDeleteForSubject(subject, handle, classId, amount)
  amount = amount or -1
  -- lane 1: subject.inventory:DeleteItem(handle, amount)
  local inv = subject and subject.inventory
  if inv and inv.DeleteItem and handle then
    local ok = pcall(inv.DeleteItem, inv, handle, amount)
    if ok then return true, "subject.inventory:DeleteItem", 1 end
  end
  -- lane 2: global Inventory.DeleteItem(handle, amount)
  if Inventory and Inventory.DeleteItem and handle then
    local ok = pcall(Inventory.DeleteItem, handle, amount)
    if ok then return true, "Inventory.DeleteItem", 2 end
  end
  -- lane 3: global Inventory.DeleteItemOfClass(subject, classId, amount)
  if Inventory and Inventory.DeleteItemOfClass and subject and classId then
    local ok = pcall(Inventory.DeleteItemOfClass, subject, classId, amount)
    if ok then return true, "Inventory.DeleteItemOfClass", 3 end
  end
  return false, "no-lane", 3
end

local function TryUnequip(subject, ownerWuid, handle)
  -- If you have a working unequip lane in your old file, PASTE IT HERE and return true on success.
  return false, "no-unequip"
end

-- ---------- nuker ----------
function CS.nukeNpcInventory(subject, ctx)
  ctx       = ctx or {}
  local C   = CS.config or {}
  local N   = (C.nuker or {})
  local dry = C.dryRun and true or false
  local tag = dry and "[nuke][dry]" or "[nuke]"

  if not N.enabled then
    nlog(tag .. " abort (nuker.enabled=false)"); return
  end
  if not subject then
    nlog(tag .. " abort (no subject)"); return
  end

  local isCorpse   = CS.isCorpseEntity(subject) or false
  local allowByCtx = ctx.corpseCtx == true
  if N.onlyIfCorpse and not (isCorpse or allowByCtx) then
    nlog(tag .. " abort (onlyIfCorpse=true, no corpseCtx)"); return
  end

  local subjectWuid = (CS.getEntityWuid and CS.getEntityWuid(subject)) or nil
  if not subjectWuid then
    nlog(tag .. " abort (no subject WUID)"); return
  end

  -- enumerate
  local items, how = ctx.items, "prelisted"
  if type(items) ~= "table" then items, how = CS.enumSubject(subject) end
  if type(items) ~= "table" then
    nlog(tag .. " abort (no enumerable inventory)"); return
  end

  local beforeCount = CS.countKeys(items)
  nlog(("Before: %d items (via=%s)"):format(beforeCount, tostring(how)))
  if beforeCount == 0 then
    CS.UIRefresh:Refresh()
    return true
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
  local uiIds = {}

  for _, k in ipairs(keys) do
    repeat
      local row    = items[k]
      local it     = CS.resolveItemEntry(row) -- may be nil
      local class  = (it and (it.class or it.Class)) or (row and (row.class or row.Class))
      local handle = (type(row) == "userdata") and row
          or (type(row) == "table" and (row.id or row.Id or row.handle or row.Handle))
          or nil
      -- resolve pretty name for ban checks
      local name   = class
      if class and ItemManager and ItemManager.GetItemName then
        local okNm, nm = pcall(ItemManager.GetItemName, tostring(class))
        if okNm and nm and nm ~= "" then name = nm end
      end

      -- hp normalize
      local hp = (it and (it.health or it.Health or it.cond)) or 1.0
      if type(hp) == "number" and hp > 1.001 and hp <= 100 then hp = hp / 100 end

      -- money guard
      local isMoney = false
      if N.skipMoney then
        isMoney = CS.lower_eq(name, "money") or CS.lower_eq(class, "money")
            or tostring(class) == "5ef63059-322e-4e1b-abe8-926e100c770e"
      end
      if isMoney then
        kept = kept + 1; break
      end

      -- hp threshold
      if N.minHp and hp < N.minHp then
        kept = kept + 1; break
      end

      -- owner match (if provided)
      if handle and ItemManager and ItemManager.GetItemOwner and ctx.victim then
        local okO, owner = pcall(ItemManager.GetItemOwner, handle)
        if okO and owner then
          local vW = CS.getEntityWuid and CS.getEntityWuid(ctx.victim)
          if vW and owner ~= vW then
            kept = kept + 1; break
          end
        end
      end

      -- banlist decision
      if not isBannedByConfig(name, class) then
        kept = kept + 1; break
      end

      -- delete
      local deletedThis = false
      if dry then
        nlog(string.format("%s Would delete %s (%s)", tag, tostring(class or "?"), tostring(handle)))
        deletedThis = true; deleted = deleted + 1
      else
        local okDel, via, attemptsTried = tryDeleteForSubject(subject, handle, class, -1)
        if (not okDel) and (N.unequipBeforeDelete and handle) then
          local ownerWuid
          if ItemManager and ItemManager.GetItemOwner then
            local okO, w = pcall(ItemManager.GetItemOwner, handle)
            if okO and w then ownerWuid = w end
          end
          if not ownerWuid and subject then ownerWuid = CS.getEntityWuid and CS.getEntityWuid(subject) end
          if ownerWuid then
            local unOk, unVia = TryUnequip(subject, ownerWuid, handle)
            if unOk then
              okDel, via, attemptsTried = tryDeleteForSubject(subject, handle, class, -1)
              if okDel then nlog(string.format("[nuke] unequipped via %s → delete via %s", tostring(unVia), tostring(via))) end
            end
          end
        end
        if okDel then
          deletedThis = true; deleted = deleted + 1
          nlog(string.format("%s deleted class=%s handle=%s via %s (lanesTried=%s)", tag, tostring(class),
            tostring(handle), tostring(via), tostring(attemptsTried)))
        end
      end

      do
        local uiid = CS.uiIdFromRow(row); if uiid then uiIds[#uiIds + 1] = uiid end
      end
      if not deletedThis then
        kept = kept + 1; if not dry then
          nlog(string.format("%s delete failed for class=%s handle=%s", tag,
            tostring(class), tostring(handle)))
        end
      end
    until true
  end

  -- re-enum & finalize
  local itemsAfter0, howAfter0 = CS.enumSubject(subject)
  local after0 = CS.countKeys(itemsAfter0 or {})
  nlog(("After0: %d items (via=%s)"):format(after0, tostring(howAfter0)))

  local function finalize(reason)
    CS.UIRefresh:Refresh()
    nlog("UI refresh reason: " .. tostring(reason))
    nlog(string.format("%s summary: deleted=%d kept=%d dry=%s (via=%s, subject=%s)",
      tag, deleted, kept, tostring(dry), "prelisted",
      tostring(subject.class or (subject.GetName and subject:GetName()) or "entity")))
  end

  if after0 == CS.countKeys(items) and deleted > 0 then
    CS.later(50, function()
      local itemsAfter1 = select(1, CS.enumSubject(subject))
      local after1 = CS.countKeys(itemsAfter1 or {})
      nlog(("After1(+50ms): %d items"):format(after1))
      if after1 < CS.countKeys(items) then
        finalize("engine mutated after delay"); return
      end
      finalize("nothing changed; forced refresh")
    end)
    return true
  end

  if (after0 < CS.countKeys(items)) or (deleted > 0) then
    finalize("engine changed immediately or best-effort")
  else
    finalize("nothing changed; forced refresh anyway")
  end
  return true
end
