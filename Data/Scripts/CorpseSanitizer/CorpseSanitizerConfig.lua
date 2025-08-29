return {
    dryRun       = false,
    insanityMode = true,

    ui           = {
        movie        = "ItemTransfer",
        shadowDelete = true, -- <- always hide rows if engine blocks writes
    },

    nuker        = {
        enabled             = true,
        minHp               = 0.00,
        skipMoney           = true, -- set false if you also want to purge money
        onlyIfCorpse        = true, -- <- allow nuking dead-NPC containers too
        unequipBeforeDelete = true, -- <- try unequip → delete for guarded gear
    },

    proximity    = { radius = 6.0 }, -- your current preference

    logging      = {
        prettyOwner     = true,
        probeOnMiss     = false,
        showWouldDelete = true,
        nuker           = true,
    },
}
