-- Scripts/CorpseSanitizer/CS_UI.lua
local CS = CorpseSanitizer

function CS.EnableTransferLogging()
    if UIAction and UIAction.RegisterElementListener then
        UIAction.RegisterElementListener(CS, "ItemTransfer", -1, "OnOpened", "OnOpened")
        UIAction.RegisterElementListener(CS, "ItemTransfer", -1, "OnClosed", "OnClosed")
        System.LogAlways("[CorpseSanitizer] UI listeners installed")
    else
        System.LogAlways("[CorpseSanitizer] UI listener API not available")
    end
end
