local bind = require("keymap.bind")
local map_cr = bind.map_cr
local map_cu = bind.map_cu
local map_cmd = bind.map_cmd
local map_callback = bind.map_callback
local et = bind.escape_termcode

return {
    -- ["n|<C-/>"] = map_callback(function()
    --         return vim.v.count == 0 and et("<Plug>(comment_toggle_linewise_current)")
    --             or et("<Plug>(comment_toggle_linewise_count)")
    --     end)
    --     :with_silent()
    --     :with_noremap()
    --     :with_expr()
    --     :with_desc("edit: Toggle comment for line"),
}
