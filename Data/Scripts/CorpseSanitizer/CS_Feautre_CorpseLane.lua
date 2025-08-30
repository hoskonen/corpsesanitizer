-- Scripts/CorpseSanitizer/CS_Feature_CorpseLane.lua
local CS   = CorpseSanitizer
local log  = CS._log
local nlog = CS._nlog

CS.onOpenedUse(function(self)
    local N = self.config and self.config.nuker
    if not (N and N.enabled) then return end

    local findCorpse = self.findNearestCorpse or CS.findNearestCorpse
    if not findCorpse then return end

    local corpse, vdist = findCorpse(8.0)
    if not corpse then
        log("Victim: <none> within 8m")
        return
    end

    log(("Victim (corpse): %s d=%.2fm vWUID=%s"):format(
        tostring(corpse.GetName and pcall(corpse.GetName, corpse) and corpse:GetName() or corpse.class or "entity"),
        math.sqrt(vdist or 0), tostring((CS.getEntityWuid and CS.getEntityWuid(corpse)) or "nil")
    ))

    local isA, isH = CS.classifyVictim(corpse)
    local tgt = N.target or { animals = true, humans = true }
    local okVictim = ((isA and tgt.animals) or (isH and tgt.humans))
    if N.onlyHostile and not CS.isHostileToPlayer(corpse) then
        nlog("corpse lane: skipped (not hostile)")
        return
    end
    if not okVictim then
        nlog("corpse lane: skipped (target gate)")
        return
    end

    -- enum -> nuke -> re-enum log (reduces visible popping)
    local itemsA, howA = CS.enumSubject(corpse)
    if type(itemsA) == "table" then
        pcall(CS.nukeNpcInventory, corpse, { items = itemsA, corpseCtx = true, victim = corpse })
        itemsA, howA = CS.enumSubject(corpse) -- re-enum after nuke
        CS.logInventoryRows(itemsA, howA, 100)
    else
        log("Direct: no enumerable items for corpse")
    end
end)
