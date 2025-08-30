-- Scripts/CorpseSanitizer/CS_Feature_PreCorpse.lua
local CS   = CorpseSanitizer
local log  = CS._log
local nlog = CS._nlog

CS.onOpenedUse(function(self, elementName, instanceId)
    local N = self.config and self.config.nuker
    if not (N and N.enabled and N.preCorpse and not N.onlyIfCorpse) then return end

    -- OPTIONAL safety: require any corpse nearby
    local findCorpse = self.findNearestCorpse or CS.findNearestCorpse
    local corpseNearby = findCorpse and
    select(1, findCorpse((self.config.proximity and self.config.proximity.radius) or 6.0)) or true
    if not corpseNearby then
        nlog("pre-corpse skipped (no corpse nearby)")
        return
    end

    -- You have scanNearbyOnce in your file; if not, this will no-op
    local scan = self.scanNearbyOnce or CS.scanNearbyOnce
    if not scan then
        nlog("pre-corpse skipped (no scanNearbyOnce)"); return
    end

    local list  = scan((self.config.proximity and self.config.proximity.radius) or 6.0, 24)
    local m     = N.preCorpseMaxMeters or 1.5
    local maxD2 = m * m
    local tgt   = N.target or { animals = true, humans = true }

    local npcWritable
    for i = 1, #list do
        local e  = list[i].e
        local d2 = list[i].d2 or 1e9
        if d2 <= maxD2 and e and e ~= CS.getPlayer() and not CS.isCorpseEntity(e)
            and (e.inventory or e.container or e.stash) then
            local isA, isH = CS.classifyVictim(e)
            if ((isA and tgt.animals) or (isH and tgt.humans))
                and (not N.onlyHostile or CS.isHostileToPlayer(e)) then
                npcWritable = e
                break
            end
        end
    end

    if not npcWritable then
        nlog(string.format("pre-corpse skipped (no writable/hostile target within %.2fm)", m))
        return
    end

    local delays = N.doublePassDelays or { 0, 120 }
    for _, ms in ipairs(delays) do
        CS.later(ms, function() pcall(CS.nukeNpcInventory, npcWritable, { victim = npcWritable }) end)
    end
end)
