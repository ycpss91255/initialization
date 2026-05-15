return {
	handlers = {
		-- 設為空函式，這會阻止 mason-null-ls 為 checkmake 產生預設的報錯配置
		checkmake = function() end,
	},
}
