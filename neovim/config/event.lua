local definitions = {
	-- Example
	bufs = {
		{ "BufWritePre", "COMMIT_EDITMSG", "setlocal noundofile" },
	},
	inserts = {
		{ "InsertEnter", "*", "inoremap <C-H> <C-w>" },
	},
}

return definitions
