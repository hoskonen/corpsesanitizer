-- Scripts/CorpseSanitizer/CorpseSanitizer.lua
CorpseSanitizer = CorpseSanitizer or
{ version = "0.6.0", ui = { active = false }, pipes = { onOpened = {}, onClosed = {} } }
local CS = CorpseSanitizer

local function load(name)
    local path = "Scripts/CorpseSanitizer/" .. name
    local ok, err = pcall(Script.ReloadScript, path)
    if not ok then
        System.LogAlways("[CorpseSanitizer] load fail: " .. tostring(path) .. " -> " .. tostring(err))
    end
end

-- load order (utils first; nuker + features after)
load("CS_Config.lua")
load("CS_Log.lua")
load("CS_Util.lua")
load("CS_Enum.lua")
load("CS_Nuke.lua")
load("CS_UI.lua")
load("CS_Feature_PreCorpse.lua")
load("CS_Feature_CorpseLane.lua")

-- tiny pipe API so features can hook without touching core
function CS.onOpenedUse(fn) CS.pipes.onOpened[#CS.pipes.onOpened + 1] = fn end

function CS.onClosedUse(fn) CS.pipes.onClosed[#CS.pipes.onClosed + 1] = fn end

function CS.Bootstrap()
    if CS._booted then return end
    CS._booted = true
    if CS.ReloadConfig then CS.ReloadConfig() end
    if CS.EnableTransferLogging then CS.EnableTransferLogging() end
    System.LogAlways(string.format("[CorpseSanitizer] boot ok v%s", tostring(CS.version)))
end

-- UI event fan-out
function CS:OnOpened(elementName, instanceId, eventName, args)
    self.ui.active = true
    CS._log(("OnOpened → transfer UI visible (element=%s, instance=%s)"):format(tostring(elementName),
        tostring(instanceId)))
    -- fan out to feature pipes
    for i = 1, #self.pipes.onOpened do pcall(self.pipes.onOpened[i], self, elementName, instanceId, eventName, args) end
end

function CS:OnClosed(elementName, instanceId, eventName, args)
    self.ui.active = false
    CS._log(("OnClosed (element=%s, instance=%s)"):format(tostring(elementName), tostring(instanceId)))
    for i = 1, #self.pipes.onClosed do pcall(self.pipes.onClosed[i], self, elementName, instanceId, eventName, args) end
end
