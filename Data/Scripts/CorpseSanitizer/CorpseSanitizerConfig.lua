-- Only overrides; anything omitted uses DEFAULT_CONFIG
return {
    dryRun = false,
    insanityMode = true,

    proximity = { radius = 6.0 }, -- only override radius; maxList stays default

    nuker = {
        enabled      = true,
        minHp        = 0.00,
        skipMoney    = true,
        onlyIfCorpse = true,
    },

    logging = {
        prettyOwner     = true,
        probeOnMiss     = false,
        showWouldDelete = true,
    },
}
