return {
    dryRun       = false,
    insanityMode = true,

    ui           = {
        movie        = "ItemTransfer",
        shadowDelete = false, -- SWF repopulates; don’t shadow-delete
        echoToUI     = false, -- keep UI mirroring off while testing
    },

    nuker        = {
        enabled             = true,
        minHp               = 0.00,
        skipMoney           = true,
        onlyIfCorpse        = false, -- < allow nuking NPC inventories
        preCorpse           = true,  -- < run a quick pre-corpse sweep
        unequipBeforeDelete = true,
        preCorpseMaxMeters  = 1.5,   -- only nuke NPCs within this distance of the player
    },

    proximity    = { radius = 6.0 },

    logging      = {
        prettyOwner     = true,
        probeOnMiss     = false,
        showWouldDelete = true,
        nuker           = true,
        dumpRows        = true,
    },
}
