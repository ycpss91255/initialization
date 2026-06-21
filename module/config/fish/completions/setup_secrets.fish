# setup_secrets.fish — fish completions for the init_ubuntu secrets sub-tool
#
# Source of truth: setup_secrets.sh `_secrets_usage` + the per-command arg
# parsers (`_secrets_cmd_*` / `_secrets_ssh_key_*` / `_secrets_token_*` /
# `_secrets_gpg_*`). Subcommands and their actions, read straight from the
# dispatch `case` blocks:
#   ssh-key  generate | load | copy | list | remove
#   token    set | get
#   gpg      generate | import | list
#   list                         (no sub-action)
#   remove   <name>              (top-level token delete)
#   help | version
#
# Installed to ~/.config/fish/completions/ by module/fish.module.sh (cp -r of
# the whole module/config/fish/ tree). No engine fork — pure static vocabulary.
#
# Registered for both `setup_secrets` (the PATH name in the prompt) and
# `setup_secrets.sh` (the in-repo script name).

for cmd in setup_secrets setup_secrets.sh
    # Top-level commands (only before one is chosen).
    complete -c $cmd -f -n "not __fish_seen_subcommand_from ssh-key token gpg list remove help version" \
        -a "ssh-key\t'Manage SSH keys' \
            token\t'Store/read tokens' \
            gpg\t'Manage GPG keys' \
            list\t'List stored secret names' \
            remove\t'Delete a stored secret' \
            help\t'Show help' \
            version\t'Show version'"

    # ── ssh-key actions ───────────────────────────────────────────────────────
    complete -c $cmd -f -n "__fish_seen_subcommand_from ssh-key; and not __fish_seen_subcommand_from generate load copy list remove" \
        -a "generate\t'Generate a key pair' \
            load\t'Add a key to ssh-agent' \
            copy\t'ssh-copy-id to a host' \
            list\t'List public keys' \
            remove\t'Delete a key pair (destructive)'"

    # ssh-key generate flags + --type value set.
    complete -c $cmd -f -n "__fish_seen_subcommand_from ssh-key; and __fish_seen_subcommand_from generate" \
        -l type -r -a "ed25519 ecdsa rsa" -d "Key type"
    complete -c $cmd -F -n "__fish_seen_subcommand_from ssh-key; and __fish_seen_subcommand_from generate load copy remove" \
        -l file -d "Key file path"
    complete -c $cmd -f -n "__fish_seen_subcommand_from ssh-key; and __fish_seen_subcommand_from generate" \
        -l comment -r -d "Key comment"
    complete -c $cmd -f -n "__fish_seen_subcommand_from ssh-key; and __fish_seen_subcommand_from generate" \
        -l no-passphrase -d "Skip passphrase"
    complete -c $cmd -f -n "__fish_seen_subcommand_from ssh-key; and __fish_seen_subcommand_from remove" \
        -l yes -d "Confirm destructive delete"

    # ── token actions ─────────────────────────────────────────────────────────
    complete -c $cmd -f -n "__fish_seen_subcommand_from token; and not __fish_seen_subcommand_from set get" \
        -a "set\t'Store a token (value prompted)' get\t'Print a token value'"

    # ── gpg actions ───────────────────────────────────────────────────────────
    complete -c $cmd -f -n "__fish_seen_subcommand_from gpg; and not __fish_seen_subcommand_from generate import list" \
        -a "generate\t'Generate a GPG key' import\t'Import key material' list\t'List GPG keys'"
    complete -c $cmd -F -n "__fish_seen_subcommand_from gpg; and __fish_seen_subcommand_from import" \
        -d "GPG key file to import"
end
