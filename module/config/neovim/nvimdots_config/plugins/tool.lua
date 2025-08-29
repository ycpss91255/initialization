local tool = {}

local in_tmux = function ()
	return os.getenv("TMUX") ~= nil
end

tool["christoomey/vim-tmux-navigator"] = {
	lazy = false,
	cond = in_tmux,
	cmd = {
		"TmuxNavigatePrevious",
		 "TmuxNavigateNext",
		},
}
tool["wakatime/vim-wakatime"] = {
	lazy = false,
}

return tool
