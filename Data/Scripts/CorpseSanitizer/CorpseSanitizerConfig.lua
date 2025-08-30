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
        -- timing
        preCorpse           = true,
        preCorpseMaxMeters  = 1.5,
        doublePassDelays    = { 0, 120 }, -- do pass A immediately, pass B shortly after
        -- filters
        onlyIfCorpse        = false,
        onlyHostile         = true,                        -- <- NEW: act only on hostiles
        target              = { animals = true, humans = true }, -- flip humans later if you want
        banNames            = { "dogMeat", "skin_dog" },   -- grow this list
        banClasses          = {},

        skipMoney           = true,
        minHp               = 0.00,
        unequipBeforeDelete = true,
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
