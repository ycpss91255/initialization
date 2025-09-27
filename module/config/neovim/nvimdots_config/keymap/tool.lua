local bind = require("keymap.bind")
local map_cr = bind.map_cr
local map_cu = bind.map_cu
local map_cmd = bind.map_cmd
local map_callback = bind.map_callback

return {
	["n|<A-\\>"] = "",
	["i|<A-\\>"] = "",
	["t|<A-\\>"] = "",
	["n|<F5>"] = "",
	["i|<F5>"] = "",
	["t|<F5>"] = "",
	["n|<C-n>"] = map_callback(function()
			require("edgy").toggle("right")
		end)
		:with_noremap()
		:with_silent()
		:with_desc("filetree: Toggle"),

	-- tmux-navigator
    -- ["n|<C-j>"] = map_cu("TmuxNavigatePrevious"):with_noremap():with_desc("tmux: Navigate Previous"),
    -- ["n|<C-k>"] = map_cu("TmuxNavigateNext"):with_noremap():with_desc("tmux: Navigate Next"),
}
