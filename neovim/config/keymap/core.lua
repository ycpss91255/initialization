local bind = require("keymap.bind")
local map_cr = bind.map_cr
local map_cmd = bind.map_cmd
-- local map_cu = bind.map_cu
-- local map_callback = bind.map_callback

return {
    ["n|<A-[>"] = "",
    ["n|<A-[>"] = "",
    ["n|J"] = map_cmd("J"):with_noremap():with_desc("edit: Join next line"),
    -- pane size
    ["n|<A-;>"] = "",
    ["n|<A-'>"] = "",
    ["n|<A-[>"] = "",
    ["n|<A-]>"] = "",
    ["n|<A-h>"] = map_cr("vertical resize -5"):with_silent():with_desc("window: Resize -5 vertically"),
    ["n|<A-l>"] = map_cr("vertical resize +5"):with_silent():with_desc("window: Resize +5 vertically"),
    ["n|<A-k>"] = map_cr("resize +2"):with_silent():with_desc("window: Resize +2 horizontally"),
    ["n|<A-j>"] = map_cr("resize -2"):with_silent():with_desc("window: Resize -2 horizontally"),
    -- tab
    ["n|<Tab>"] = map_cr("tabprevious"):with_noremap():with_silent():with_desc("tab: Move to previous tab"),
    ["n|<S-Tab>"] = map_cr("tabnext"):with_noremap():with_silent():with_desc("tab: Move to next tab"),
    ["n|<C-h>"] = map_cr("tabprevious"):with_noremap():with_silent():with_desc("tab: Move to previous tab"),
    ["n|<C-l>"] = map_cr("tabnext"):with_noremap():with_silent():with_desc("tab: Move to next tab"),
    -- window
    ["n|<C-j>"] = map_cr("wincmd w"):with_noremap():with_desc("window: Focus next"),
    ["n|<C-k>"] = map_cr("wincmd W"):with_noremap():with_desc("window: Focus previous"),

    ["i|<C-p>"] = map_cmd("<Esc>yypgi"):with_noremap():with_desc("edit: copy and paste current line"),
    ["i|<A-p>"] = map_cmd("<C-o>p"):with_noremap():with_desc("edit: paste register"),
    -- i mode yypi <C-d>?
    -- # TODO: vscode sync
    -- ["i|<C-BS>"] = map_cmd("<C-w>"):with_noremap():with_desc("FUCKKKKk"),
    -- ["i|<C-H>"] = map_cmd("<C-w>"):with_noremap():with_desc("window: Focus previous"),
}
