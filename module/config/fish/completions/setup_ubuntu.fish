# setup_ubuntu.fish — fish completions for the init_ubuntu CLI
#
# Source of truth: lib/dispatcher.sh (subcommand router + per-subcommand flag
# parsing) and CONTEXT.md "CLI vocabulary". Derived by reading the dispatch
# `case` and each `_dispatcher_*` arg parser — NOT from memory.
#
# Installed to ~/.config/fish/completions/ by module/fish.module.sh, which
# `cp -r`s the whole module/config/fish/ tree (completions/ is fish's
# autoloaded dir — an upstream-imposed plural exception per ADR-0021).
#
# Speed: completions NEVER fork the engine (no `setup_ubuntu list`). Module
# names for install/remove/purge/upgrade/verify/show are completed by globbing
# module/*.module.sh basenames relative to this script (a cheap readdir, no
# subprocess), discovered only when the repo layout is reachable. When it is
# not reachable, module-name value completion is silently skipped and only
# subcommands + flags are offered (keeps Tab instant).
#
# Registered for both `setup_ubuntu` (the PATH name) and `setup_ubuntu.sh`
# (the in-repo script name); a small loop at the bottom wires identical rules.

function __init_ubuntu_subcommands
    # name<TAB>description rows (fish renders the right column as the hint).
    printf '%s\t%s\n' \
        install "Install modules (with deps)" \
        remove  "Remove modules (config retained)" \
        purge   "Remove modules + their config" \
        upgrade "Run upgrade() for modules (or all installed)" \
        verify  "Run verify() for modules (or all installed)" \
        list    "List registered modules" \
        show    "Print a module's metadata" \
        search  "Search modules by name/category/tag" \
        detect  "Print host environment" \
        doctor  "Diff state.json vs system reality" \
        config  "Read/write config.ini (set|get|unset|show)" \
        sync    "Push/pull state over SSH" \
        export  "Export state.json synced sections" \
        import  "Diff/apply an exported payload" \
        status  "(deprecated) alias of 'list --installed'" \
        help    "Show help" \
        version "Show tool version"
end

# Cheap module-name source: glob module/*.module.sh basenames. Resolves the
# repo root from this completion file's own location first (works when run from
# the repo's own fish config), then a couple of well-known install spots. No
# engine fork — a plain readdir. Prints nothing (skips name completion) when no
# module dir is found, so Tab stays fast and never errors.
function __init_ubuntu_module_names
    set -l dirs
    # This file lives at <root>/module/config/fish/completions/setup_ubuntu.fish
    # when run in-repo → repo module dir is three levels up.
    set -l self (status current-filename 2>/dev/null)
    if test -n "$self"
        set -l comp_dir (dirname -- "$self")
        set -l repo_module (realpath -- "$comp_dir/../../.." 2>/dev/null)
        test -n "$repo_module"; and set -a dirs "$repo_module"
    end
    set -a dirs "$PWD/module" "$HOME/initialization/module" /opt/init_ubuntu/module
    for d in $dirs
        if test -d "$d"
            for f in $d/*.module.sh
                test -e "$f"; or continue
                set -l base (basename -- "$f")
                printf '%s\tmodule\n' (string replace -r '\.module\.sh$' '' -- "$base")
            end
            return 0
        end
    end
end

# Lifecycle subcommands that take module-name positionals.
set -l __init_ubuntu_mod_subs install remove purge upgrade verify show

# Every subcommand word — used by the top-level `-n` guard. Kept as a static
# space-separated list (NOT a command substitution): a `$(...)` inside a
# completion condition re-runs every keystroke AND its newline-separated output
# is mis-parsed by fish as separate commands. The list mirrors
# __init_ubuntu_subcommands above.
set -l __init_ubuntu_all_subs install remove purge upgrade verify list show \
    search detect doctor config sync export import status help version

for cmd in setup_ubuntu setup_ubuntu.sh
    # Top-level: offer subcommands only when none has been typed yet.
    complete -c $cmd -f -n "not __fish_seen_subcommand_from $__init_ubuntu_all_subs" \
        -a "(__init_ubuntu_subcommands)"

    # Global / top-level flags (position-independent per dispatcher §7.5).
    complete -c $cmd -f -l help    -d "Show help"
    complete -c $cmd -f -l version -d "Show tool version"
    complete -c $cmd -f -s h       -d "Show help"
    complete -c $cmd -f -s v -l verbose -d "Set log level to DEBUG"
    complete -c $cmd -f -l quiet   -d "Set log level to WARN"
    complete -c $cmd -f -l color -a "auto always never" -d "ANSI color control"

    # Module-name value completion for the lifecycle subcommands (cheap glob).
    complete -c $cmd -f \
        -n "__fish_seen_subcommand_from $__init_ubuntu_mod_subs" \
        -a "(__init_ubuntu_module_names)"

    # ── Per-subcommand flags (mirrors each _dispatcher_* parser) ──────────────
    # install / remove / purge / upgrade share the lifecycle flag set.
    complete -c $cmd -f -n "__fish_seen_subcommand_from install remove purge upgrade" -s y -l yes -d "Assume yes to prompts"
    complete -c $cmd -f -n "__fish_seen_subcommand_from install remove purge upgrade verify" -l dry-run -d "Print intended actions only"
    complete -c $cmd -f -n "__fish_seen_subcommand_from install remove purge" -l no-deps -d "Skip dep resolution"
    complete -c $cmd -f -n "__fish_seen_subcommand_from install remove purge upgrade" -l verbose -d "Stream child output live"
    complete -c $cmd -f -n "__fish_seen_subcommand_from install remove purge upgrade" -l quiet -d "Warn/error only"

    # list
    complete -c $cmd -f -n "__fish_seen_subcommand_from list" -l installed -d "state.json view"
    complete -c $cmd -f -n "__fish_seen_subcommand_from list" -l json -d "Machine-readable output"
    complete -c $cmd -f -n "__fish_seen_subcommand_from list" -l category -r -a "base recommended optional experimental" -d "Filter by category"
    complete -c $cmd -f -n "__fish_seen_subcommand_from list" -l tag -r -d "Filter by tag"

    # show / detect
    complete -c $cmd -f -n "__fish_seen_subcommand_from show detect" -l json -d "Machine-readable output"

    # doctor
    complete -c $cmd -f -n "__fish_seen_subcommand_from doctor" -l validate-modules -d "Lint module metadata"

    # config action keyword (set|get|unset|show) as the first positional.
    complete -c $cmd -f -n "__fish_seen_subcommand_from config; and not __fish_seen_subcommand_from set get unset show" \
        -a "set\t'Write a key' get\t'Read a key' unset\t'Delete a key' show\t'Print config'"

    # export / import (export takes a file; import has --apply / --dry-run / -y).
    complete -c $cmd -F -n "__fish_seen_subcommand_from export import"
    complete -c $cmd -f -n "__fish_seen_subcommand_from export" -l modules -r -d "CSV of sections to export"
    complete -c $cmd -f -n "__fish_seen_subcommand_from import" -l apply -d "Commit (default is dry-run)"
    complete -c $cmd -f -n "__fish_seen_subcommand_from import" -l dry-run -d "Print plan only (default)"
    complete -c $cmd -f -n "__fish_seen_subcommand_from import" -s y -l yes -d "Assume yes"

    # sync
    complete -c $cmd -f -n "__fish_seen_subcommand_from sync" -l pull -d "Pull instead of push"
    complete -c $cmd -f -n "__fish_seen_subcommand_from sync" -l apply -d "Commit (default is dry-run)"
    complete -c $cmd -f -n "__fish_seen_subcommand_from sync" -l modules -r -d "CSV of sections"
    complete -c $cmd -f -n "__fish_seen_subcommand_from sync" -l include-config -d "Include config payload"
    complete -c $cmd -f -n "__fish_seen_subcommand_from sync" -l dry-run -d "Print diff only"
end
