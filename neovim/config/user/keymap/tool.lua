local bind = require("keymap.bind")
local map_cu = bind.map_cu

return {
	["n|<A-\\>"] = "",
	["i|<A-\\>"] = "",
	["t|<A-\\>"] = "",
	["n|<F5>"] = "",
	["i|<F5>"] = "",
	["t|<F5>"] = "",

	-- tmux-navigator
    -- ["n|<C-j>"] = map_cu("TmuxNavigatePrevious"):with_noremap():with_desc("tmux: Navigate Previous"),
    -- ["n|<C-k>"] = map_cu("TmuxNavigateNext"):with_noremap():with_desc("tmux: Navigate Next"),
}
