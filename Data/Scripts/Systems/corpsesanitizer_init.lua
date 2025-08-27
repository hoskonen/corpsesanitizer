local ok = Script.ReloadScript("Scripts/CorpseSanitizer/CorpseSanitizer.lua")
System.LogAlways("[CorpseSanitizer] systems init loaded")
if ok and CorpseSanitizer and CorpseSanitizer.Bootstrap then
    CorpseSanitizer.Bootstrap()
else
    System.LogAlways(string.format(
        "[CorpseSanitizer] ERROR: Bootstrap missing (ok=%s, CS=%s, Bootstrap=%s)",
        tostring(ok),
        tostring(CorpseSanitizer),
        tostring(CorpseSanitizer and CorpseSanitizer.Bootstrap)))
end
