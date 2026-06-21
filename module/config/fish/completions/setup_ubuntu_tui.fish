# setup_ubuntu_tui.fish — fish completions for the init_ubuntu TUI launcher
#
# Source of truth: setup_ubuntu_tui.sh `_tui_usage` + the --backend / --lang
# arg parser. Accepted values, read straight from the parser:
#   --backend : fzf | whiptail | gum   (gum is the legacy dialog backend)
#   --lang    : en | zh-TW
#
# Installed to ~/.config/fish/completions/ by module/fish.module.sh (cp -r of
# the whole module/config/fish/ tree). The TUI takes flags only — no
# subcommands and no positional args — so this file just enumerates the flags
# and the small fixed value sets.
#
# Registered for both `setup_ubuntu_tui.sh` (the invocation form in the prompt /
# README) and a bare `setup_ubuntu_tui` in case it lands on PATH without the
# extension.

for cmd in setup_ubuntu_tui.sh setup_ubuntu_tui
    complete -c $cmd -f
    complete -c $cmd -f -s h -l help    -d "Show help"
    complete -c $cmd -f -l version      -d "Show tool version"
    complete -c $cmd -f -l backend -r -a "fzf whiptail gum" -d "Force the rendering tier"
    complete -c $cmd -f -l lang    -r -a "en zh-TW"          -d "Force the UI language"
end
