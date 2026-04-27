_G.remove_whitespace = function()
	local save_view = vim.fn.winsaveview()
	vim.cmd([[%s/\s\+$//e]])
	vim.cmd([[%s/\($\n\s*\)\+\%$//e]])
	vim.fn.winrestview(save_view)
end

local definitions = {
	-- Example
	bufs = {
		{ "BufWritePre", "COMMIT_EDITMSG", "setlocal noundofile" },
		{ "BufRead", "*.launch", "set filetype=xml" },
		{ "BufNewFile", "*.launch", "set filetype=xml" },
		{ "BufRead,BufNewFile", "*.bats", "set filetype=bash" },
		{ "BufWinEnter", "*.bats", "lua vim.schedule(function() vim.opt_local.foldmethod = 'marker' vim.opt_local.foldmarker = '{,}' vim.opt_local.foldlevel = 99 end)" },
		-- 標記行尾多餘空白為番茄紅背景
		{ "BufWinEnter,WinEnter", "*", [[highlight TrailingWhitespace guibg=#ff6347 | match TrailingWhitespace /\s\+$/]] },
		-- 存檔時自動移除行尾多餘空白與檔案結尾多餘空行，並保持游標位置
		{ "BufWritePre", "*", "lua _G.remove_whitespace()" },
	},
	ft = {
		{ "FileType", "sh,bash", "setlocal shiftwidth=2 tabstop=2 softtabstop=2" },
		{ "FileType", "cmake", "setlocal shiftwidth=2 tabstop=2 softtabstop=2" },
		{ "FileType", "markdown", "setlocal shiftwidth=2 tabstop=2 softtabstop=2" },

		{ "FileType", "python", "setlocal shiftwidth=4 tabstop=4 softtabstop=4" },

		{ "FileType", "go", "setlocal shiftwidth=4 tabstop=4 softtabstop=4 noexpandtab" },
		{ "FileType", "make", "setlocal shiftwidth=4 tabstop=4 softtabstop=4 noexpandtab" },
	},
	inserts = {
		{ "InsertEnter", "*", "inoremap <C-H> <C-w>" },
	},
}

return definitions
