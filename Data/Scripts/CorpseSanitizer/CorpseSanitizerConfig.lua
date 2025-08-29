return {
    -- No mutations anywhere
    dryRun       = true, -- ← forces nuker to only log “Would delete …”
    insanityMode = true, -- keep the normal open → detect → enumerate flow alive

    ui           = {
        movie          = "ItemTransfer",
        shadowDelete   = true, -- ← do NOT hide/change rows in .gfx yet
        -- uiOnly    = false,  -- (if this key exists in your build) keep false for now
        debugHideApple = true
    },

    nuker        = {
        enabled             = true, -- let nuker run so it logs per-item “would delete”
        minHp               = 0.00,
        skipMoney           = true,
        onlyIfCorpse        = true,  -- only act on confirmed corpses; avoids live NPCs
        unequipBeforeDelete = false, -- not needed while dryRun=true
    },

    proximity    = { radius = 6.0 },

    logging      = {
        prettyOwner     = true, -- prints the nice owner WUID next to each item
        probeOnMiss     = true, -- extra hints when corpse WUID is read-only
        showWouldDelete = true, -- shows “[nuke] Would delete …” lines per row
        nuker           = true, -- prints Before/After counts and summary
        dumpRows        = true
    },
}
