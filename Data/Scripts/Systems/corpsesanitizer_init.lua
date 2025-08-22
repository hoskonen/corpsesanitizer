-- minimal Systems init → load main & call Bootstrap immediately
Script.ReloadScript("Scripts/CorpseSanitizer/CorpseSanitizer.lua")

System.LogAlways("[CorpseSanitizer] systems init loaded")

if CorpseSanitizer and CorpseSanitizer.Bootstrap then
    CorpseSanitizer.Bootstrap()
else
    System.LogAlways("[CorpseSanitizer] ERROR: Bootstrap missing")
end
