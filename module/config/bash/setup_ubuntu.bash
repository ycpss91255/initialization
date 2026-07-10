# setup_ubuntu.bash — Bash programmable completion for the setup_ubuntu CLI.
#
# Issue #166. Level 1 completes subcommands (and global flags for a dashed
# word); the module-taking subcommands (install / remove / purge / upgrade /
# verify / show) complete module NAMES pulled live from `setup_ubuntu list`,
# so completion always tracks the registry rather than a hardcoded list.
#
# Deploy: source this file from ~/.bashrc, or drop it into a bash-completion
# search directory, e.g.
#   ~/.local/share/bash-completion/completions/setup_ubuntu
#
# `just install <TAB>` is intentionally NOT covered: `just` only completes
# recipe names, not recipe *args (see issue #166). Run `setup_ubuntu install
# <TAB>` directly to get module completion.

# Module names come straight from the catalog: `setup_ubuntu list` prints a
# "NAME CATEGORY TAGS" header then one row per module; column 1 (minus the
# header) is the name set. Failures (missing binary, empty registry) degrade
# to empty output so completion never breaks.
_setup_ubuntu_modules() {
    setup_ubuntu list 2>/dev/null | awk 'NR > 1 { print $1 }'
}

_setup_ubuntu() {
    local cur subcommands module_subcommands global_flags
    cur="${COMP_WORDS[COMP_CWORD]}"

    subcommands="install remove purge upgrade verify list show detect \
search doctor config sync export import help version"
    module_subcommands="install remove purge upgrade verify show"
    global_flags="--help --version --dry-run --yes --no-deps --verbose \
--quiet --json --installed --category= --tag= \
--color=auto --color=always --color=never"

    # Locate the active subcommand: the first non-flag word between argv[0]
    # and the word currently under the cursor.
    local i word subcommand=""
    for (( i = 1; i < COMP_CWORD; i++ )); do
        word="${COMP_WORDS[i]}"
        [[ "${word}" == -* ]] && continue
        subcommand="${word}"
        break
    done

    # No subcommand chosen yet → complete subcommands, or global flags when the
    # current word is dashed.
    if [[ -z "${subcommand}" ]]; then
        if [[ "${cur}" == -* ]]; then
            mapfile -t COMPREPLY < <(compgen -W "${global_flags}" -- "${cur}")
        else
            mapfile -t COMPREPLY < <(compgen -W "${subcommands}" -- "${cur}")
        fi
        return 0
    fi

    # A dashed word anywhere after the subcommand completes global flags.
    if [[ "${cur}" == -* ]]; then
        mapfile -t COMPREPLY < <(compgen -W "${global_flags}" -- "${cur}")
        return 0
    fi

    # Module-taking subcommands complete module names from the live catalog;
    # everything else offers no positional completion.
    case " ${module_subcommands} " in
        *" ${subcommand} "*)
            mapfile -t COMPREPLY < <(compgen -W "$(_setup_ubuntu_modules)" -- "${cur}")
            ;;
        *)
            COMPREPLY=()
            ;;
    esac
    return 0
}

complete -F _setup_ubuntu setup_ubuntu
