return {
	on_attach = function(bufnr)
		local api = require("nvim-tree.api")

		local function opts(desc)
			return { desc = "nvim-tree: " .. desc, buffer = bufnr, noremap = true, silent = true, nowait = true }
		end

		-- default mappings
		api.config.mappings.default_on_attach(bufnr)

		-- custom mappings
		vim.keymap.set("n", "<CR>", api.node.open.tab, opts("Open: New Tab"))
		vim.keymap.set("n", "o", api.node.open.tab, opts("Open: New Tab"))
		vim.keymap.set("n", "l", api.node.open.tab, opts("Open: New Tab"))
	end,
	view = {
		side = "right",
	},
}