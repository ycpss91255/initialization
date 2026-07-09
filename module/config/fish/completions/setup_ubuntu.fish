# setup_ubuntu.fish — fish completion for the setup_ubuntu CLI (issue #166).
#
# fish auto-loads this from any completions/ directory on $fish_complete_path;
# the fish module ships it to ~/.config/fish/completions/. Module names are
# pulled live from `setup_ubuntu list` so completion tracks the registry
# rather than a hardcoded list.

# Module names from the catalog: `setup_ubuntu list` prints a
# "NAME CATEGORY TAGS" header then one row per module; column 1 (minus the
# header) is the name set. Errors degrade to empty output.
function __setup_ubuntu_modules
    setup_ubuntu list 2>/dev/null | awk 'NR > 1 { print $1 }'
end

# Disable filename completion for this command; positional args are either
# subcommands or module names, never paths.
complete -c setup_ubuntu -f

# ── Level-1 subcommands (only before one has been typed) ─────────────────────
set -l __setup_ubuntu_subs install remove purge upgrade verify list show detect search doctor config sync export import help version

complete -c setup_ubuntu -n "not __fish_seen_subcommand_from $__setup_ubuntu_subs" -a install -d 'Install modules (with deps)'
complete -c setup_ubuntu -n "not __fish_seen_subcommand_from $__setup_ubuntu_subs" -a remove  -d 'Remove modules (config retained)'
complete -c setup_ubuntu -n "not __fish_seen_subcommand_from $__setup_ubuntu_subs" -a purge   -d 'Remove modules + their config'
complete -c setup_ubuntu -n "not __fish_seen_subcommand_from $__setup_ubuntu_subs" -a upgrade -d 'Run upgrade() for modules'
complete -c setup_ubuntu -n "not __fish_seen_subcommand_from $__setup_ubuntu_subs" -a verify  -d 'Run verify() for modules'
complete -c setup_ubuntu -n "not __fish_seen_subcommand_from $__setup_ubuntu_subs" -a list    -d 'List registered modules'
complete -c setup_ubuntu -n "not __fish_seen_subcommand_from $__setup_ubuntu_subs" -a show    -d "Print a module's metadata"
complete -c setup_ubuntu -n "not __fish_seen_subcommand_from $__setup_ubuntu_subs" -a detect  -d 'Print host environment'
complete -c setup_ubuntu -n "not __fish_seen_subcommand_from $__setup_ubuntu_subs" -a search  -d 'Search modules by keyword'
complete -c setup_ubuntu -n "not __fish_seen_subcommand_from $__setup_ubuntu_subs" -a doctor  -d 'Compare state vs system'
complete -c setup_ubuntu -n "not __fish_seen_subcommand_from $__setup_ubuntu_subs" -a config  -d 'Read/write config.ini'
complete -c setup_ubuntu -n "not __fish_seen_subcommand_from $__setup_ubuntu_subs" -a sync    -d 'Push/pull state over SSH'
complete -c setup_ubuntu -n "not __fish_seen_subcommand_from $__setup_ubuntu_subs" -a export  -d 'Export sync section of state'
complete -c setup_ubuntu -n "not __fish_seen_subcommand_from $__setup_ubuntu_subs" -a import  -d 'Import a state payload'
complete -c setup_ubuntu -n "not __fish_seen_subcommand_from $__setup_ubuntu_subs" -a help    -d 'Show help'
complete -c setup_ubuntu -n "not __fish_seen_subcommand_from $__setup_ubuntu_subs" -a version -d 'Show tool version'

# ── Module names for the module-taking subcommands ───────────────────────────
complete -c setup_ubuntu -n '__fish_seen_subcommand_from install remove purge upgrade verify show' -f -a '(__setup_ubuntu_modules)' -d Module

# ── Global flags (valid at any position) ─────────────────────────────────────
complete -c setup_ubuntu -l dry-run  -d 'Print intended actions without executing'
complete -c setup_ubuntu -s y -l yes  -d 'Assume yes to interactive prompts'
complete -c setup_ubuntu -l no-deps  -d 'Skip dependency resolution'
complete -c setup_ubuntu -s v -l verbose -d 'Stream child command output live'
complete -c setup_ubuntu -l quiet    -d 'Suppress progress lines'
complete -c setup_ubuntu -l json     -d 'Machine-readable output'
complete -c setup_ubuntu -l installed -d 'With list: show installed modules'
complete -c setup_ubuntu -l color -d 'ANSI color mode' -x -a 'auto always never'
