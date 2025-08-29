-- Scripts/Systems/corpsesanitizer_init.lua
local PATH_MAIN = "Scripts/CorpseSanitizer/CorpseSanitizer.lua"
local TAG = "[CorpseSanitizer/init] "

local function log(msg) System.LogAlways(TAG .. tostring(msg)) end

-- If we hot-reload during dev, try to shut down previous listeners cleanly.
if _G.CorpseSanitizer and type(CorpseSanitizer.Shutdown) == "function" then
    pcall(CorpseSanitizer.Shutdown)
end

-- Load main script
log("loading " .. PATH_MAIN)
local okLoad, errLoad = pcall(Script.ReloadScript, PATH_MAIN)
if not okLoad then
    log("ERROR: ReloadScript failed: " .. tostring(errLoad))
    return
end

-- Version banner (if provided by main file)
if _G.CorpseSanitizer and CorpseSanitizer.version then
    log("loaded main OK (version=" .. tostring(CorpseSanitizer.version) .. ", Lua=" .. tostring(_VERSION) .. ")")
else
    log("loaded main OK (Lua=" .. tostring(_VERSION) .. ")")
end

-- Helper: try to call Bootstrap once; return true on success
local function try_bootstrap(attempt)
    attempt = attempt or 1

    -- Optional: if your Bootstrap needs UIAction, wait until it exists.
    if not UIAction then
        log("UIAction not ready (attempt " .. attempt .. ")")
        return false
    end

    if _G.CorpseSanitizer and type(CorpseSanitizer.Bootstrap) == "function" then
        local okBoot, errBoot = pcall(CorpseSanitizer.Bootstrap)
        if okBoot then
            log("Bootstrap OK (attempt " .. attempt .. ")")
            return true
        else
            log("Bootstrap error: " .. tostring(errBoot))
            return false
        end
    else
        log("Bootstrap missing (CS=" .. tostring(_G.CorpseSanitizer) ..
            ", Bootstrap=" .. tostring(_G.CorpseSanitizer and _G.CorpseSanitizer.Bootstrap) ..
            ", attempt " .. attempt .. ")")
        return false
    end
end

-- Immediate attempt
if try_bootstrap(1) then
    return
end

-- Retry a few times in case UI systems appear slightly later
local retries   = 5   -- total attempts (including the first immediate try above)
local delay_ms  = 500 -- 0.5s between attempts
local attempt_i = 1

local function retry()
    attempt_i = attempt_i + 1
    if try_bootstrap(attempt_i) then return end
    if attempt_i < retries then
        Script.SetTimer(delay_ms, retry)
    else
        log("ERROR: giving up after " .. tostring(retries) ..
            " attempts (CS=" .. tostring(_G.CorpseSanitizer) ..
            ", Bootstrap=" .. tostring(_G.CorpseSanitizer and _G.CorpseSanitizer.Bootstrap) .. ")")
    end
end

Script.SetTimer(delay_ms, retry)
