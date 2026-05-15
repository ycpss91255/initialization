return function(opts)
	local null_ls = require("null-ls")
	local b = null_ls.builtins

	-- 加入修正版的 checkmake
	table.insert(opts.sources, b.diagnostics.checkmake.with({
		-- 這是關鍵：忽略 stderr 就不會跳出 "violations found" 的紅色警告視窗
		ignore_stderr = true,
		-- 告訴 null-ls，exit code 1 代表發現語法問題，不是工具壞掉
		check_exit_code = function(code)
			return code <= 1
		end,
	}))

	return opts
end
