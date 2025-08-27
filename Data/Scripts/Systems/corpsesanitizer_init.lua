-- Scripts/Systems/corpsesanitizer_init.lua
local path = "Scripts/CorpseSanitizer/CorpseSanitizer.lua"
System.LogAlways("[CorpseSanitizer] systems init: loading " .. path)
Script.ReloadScript(path)

if _G.CorpseSanitizer and type(CorpseSanitizer.Bootstrap) == "function" then
    CorpseSanitizer.Bootstrap()
else
    System.LogAlways(string.format(
        "[CorpseSanitizer] ERROR: Bootstrap missing (CS=%s, Bootstrap=%s)",
        tostring(_G.CorpseSanitizer), tostring(_G.CorpseSanitizer and _G.CorpseSanitizer.Bootstrap)))
end
