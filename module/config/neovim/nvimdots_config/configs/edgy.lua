return function()
	local function trouble_filter(position)
		return function(_, win)
			local tw = vim.w[win].trouble
			return tw
				and tw.position == position
				and tw.type == "split"
				and tw.relative == "editor"
				and not vim.w[win].trouble_preview
		end
	end

	require("edgy").setup({
		animate = { enabled = false },
		close_when_all_hidden = true,
		exit_when_last = true,
		wo = { winbar = false },
		keys = {
			q = false,
			Q = false,
			["<C-q>"] = false,
			["<A-j>"] = function(win)
				win:resize("height", -2)
			end,
			["<A-k>"] = function(win)
				win:resize("height", 2)
			end,
			["<A-h>"] = function(win)
				win:resize("width", -2)
			end,
			["<A-l>"] = function(win)
				win:resize("width", 2)
			end,
		},
		left = {
			{
				ft = "codecompanion",
				pinned = true,
				collapsed = false,
				size = { height = 0.6, width = 0.25 },
				open = "CodeCompanionChat Toggle",
			},
			{
				ft = "trouble",
				pinned = true,
				collapsed = false,
				size = { height = 0.4, width = 0.25 },
				open = function()
					return vim.b.buftype == "" and "Trouble symbols toggle win.position=right"
				end,
				filter = trouble_filter("right"),
			},
		},
		right = {
			{
				ft = "NvimTree",
				pinned = true,
				collapsed = false,
				size = { width = 0.15 },
				open = "NvimTreeOpen",
			},
		},
		bottom = {
			{ ft = "qf", size = { height = 0.3 } },
			{
				ft = "trouble",
				size = { height = 0.3 },
				open = function()
					return vim.b.buftype == "" and "Trouble symbols toggle win.position=bottom"
				end,
				filter = trouble_filter("bottom"),
			},
			{ ft = "neotest-output-panel", size = { height = 0.25 } },
			{
				ft = "toggleterm",
				size = { height = 0.3 },
				filter = function(_, win)
					local cfg = vim.api.nvim_win_get_config(win)
					local term = require("toggleterm.terminal").get(1)
					return cfg.relative == "" and term.direction == "horizontal"
				end,
			},
			{
				ft = "help",
				size = { height = 0.3 },
				filter = function(buf)
					return vim.bo[buf].buftype == "help"
				end,
			},
		},
	})
end
