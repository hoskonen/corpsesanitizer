-- Scripts/CorpseSanitizer/CS_Log.lua
local CS = CorpseSanitizer
function CS._log(s) System.LogAlways("[CorpseSanitizer] " .. tostring(s)) end

function CS._nlog(s) if CS.config and CS.config.logging and CS.config.logging.nuker then System.LogAlways(
        "[CorpseSanitizer/Nuke] " .. tostring(s)) end end
