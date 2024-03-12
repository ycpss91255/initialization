local completion = {}
local use_copilot = require("core.settings").use_copilot

if use_copilot then
    completion["github/copilot.vim"] = {
        lazy = true,
        cmd = "Copilot",
        event = "InsertEnter",
    }
end

return completion
