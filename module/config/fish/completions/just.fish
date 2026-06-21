# just.fish — recipe-arg completions for init_ubuntu's `just` wrappers
#
# `just` ships its own completions (recipe names, --flags). This file ADDS
# completion for the *arguments forwarded* by the two pass-through recipes that
# carry a small fixed flag/value vocabulary:
#
#   just tui *args      -> ./setup_ubuntu_tui.sh {{args}}
#   just secrets *args  -> ./setup_secrets.sh    {{args}}
#
# (See justfile: `tui *args` / `secrets *args`.) The other forwarding recipes —
# install/remove/.../config — take module names / free-form args, so they are
# left to just's own recipe completion plus the user's shell history.
#
# Source of truth, identical to the binary completions:
#   tui     --backend fzf|whiptail|gum   --lang en|zh-TW   --help --version
#   secrets ssh-key|token|gpg|list|remove (+ their sub-actions / flags)
#
# Scoping: every rule is gated on `__fish_seen_subcommand_from <recipe>` so it
# only fires after that recipe word, never polluting bare `just <Tab>` (which
# just's own completion owns). Installed via module/fish.module.sh's cp -r of
# module/config/fish/.

# ── just tui … ────────────────────────────────────────────────────────────────
complete -c just -f -n "__fish_seen_subcommand_from tui" -l help    -d "Show TUI help"
complete -c just -f -n "__fish_seen_subcommand_from tui" -l version -d "Show tool version"
complete -c just -f -n "__fish_seen_subcommand_from tui" -l backend -r -a "fzf whiptail gum" -d "Force the rendering tier"
complete -c just -f -n "__fish_seen_subcommand_from tui" -l lang    -r -a "en zh-TW"          -d "Force the UI language"

# ── just secrets … ─────────────────────────────────────────────────────────────
complete -c just -f \
    -n "__fish_seen_subcommand_from secrets; and not __fish_seen_subcommand_from ssh-key token gpg list remove help version" \
    -a "ssh-key\t'Manage SSH keys' \
        token\t'Store/read tokens' \
        gpg\t'Manage GPG keys' \
        list\t'List stored secret names' \
        remove\t'Delete a stored secret' \
        help\t'Show help' \
        version\t'Show version'"

complete -c just -f \
    -n "__fish_seen_subcommand_from secrets; and __fish_seen_subcommand_from ssh-key; and not __fish_seen_subcommand_from generate load copy list remove" \
    -a "generate\t'Generate a key pair' \
        load\t'Add a key to ssh-agent' \
        copy\t'ssh-copy-id to a host' \
        list\t'List public keys' \
        remove\t'Delete a key pair (destructive)'"

complete -c just -f \
    -n "__fish_seen_subcommand_from secrets; and __fish_seen_subcommand_from ssh-key; and __fish_seen_subcommand_from generate" \
    -l type -r -a "ed25519 ecdsa rsa" -d "Key type"

complete -c just -f \
    -n "__fish_seen_subcommand_from secrets; and __fish_seen_subcommand_from token; and not __fish_seen_subcommand_from set get" \
    -a "set\t'Store a token (value prompted)' get\t'Print a token value'"

complete -c just -f \
    -n "__fish_seen_subcommand_from secrets; and __fish_seen_subcommand_from gpg; and not __fish_seen_subcommand_from generate import list" \
    -a "generate\t'Generate a GPG key' import\t'Import key material' list\t'List GPG keys'"
