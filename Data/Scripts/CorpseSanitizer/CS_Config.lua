-- Scripts/CorpseSanitizer/CS_Config.lua
local CS = CorpseSanitizer

local DEFAULT_CONFIG = {
    dryRun       = false,
    insanityMode = true,

    ui           = { movie = "ItemTransfer", shadowDelete = false, echoToUI = false },

    proximity    = { radius = 6.0, maxList = 24 },

    nuker        = {
        enabled                   = true,
        minHp                     = 0.00,
        skipMoney                 = true,
        unequipBeforeDelete       = true,

        -- routing
        onlyIfCorpse              = false,
        preCorpse                 = true,
        preCorpseMaxMeters        = 1.5,
        doublePassDelays          = { 0, 120 },

        -- gates
        onlyHostile               = true,
        hostileIfDifferentFaction = true,
        target                    = { animals = true, humans = true },

        -- rules
        banNames                  = { "dogMeat", "skin_dog", "appleDried" },
        banClasses                = { -- add GUIDs here
            -- "02d9c556-6c40-4e5e-abab-48b2acc7287a",
        },
    },

    logging      = {
        nuker       = true,
        dumpRows    = true,
        prettyOwner = true,
        probeOnMiss = false,
    },
}

local function deepMerge(dst, src)
    for k, v in pairs(src or {}) do
        if type(v) == "table" and type(dst[k]) == "table" then deepMerge(dst[k], v) else dst[k] = v end
    end
    return dst
end

function CS.ReloadConfig()
    CS.config = deepMerge({}, DEFAULT_CONFIG)
    -- external overrides live at Scripts/CorpseSanitizer/CorpseSanitizerConfig.lua
    local ok, overrides = pcall(dofile, "Scripts/CorpseSanitizer/CorpseSanitizerConfig.lua")
    if ok and type(overrides) == "table" then deepMerge(CS.config, overrides) end
    System.LogAlways("[CorpseSanitizer] config loaded")
end
