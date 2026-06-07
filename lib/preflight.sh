#!/usr/bin/env bash
# lib/preflight.sh — self-deps preflight (PRD §3.4, AC-34)
#
# The tool's own machinery (state / config / detect) shells out to `jq`,
# and later phases need `curl` / `git` — but those packages ship inside
# the `apt-essentials` module. Chicken-and-egg: the entrypoint must check
# its own dependencies BEFORE dispatching anything that needs them.
#
# Behavior (PRD §3.4):
#   - missing + sudo available  → print an apt-style plan and ask ONCE
#     whether to `apt install` (automatic with -y / INIT_UBUNTU_YES=true)
#   - missing + no sudo         → fail fast, exit 4, print explicit
#     install guidance
#   - help / version            → never gated (they don't need jq)
#
# NOTE: installing the tool's own deps via apt here is allowed — this is
# NOT a module Action Phase (the "no host package installs" hard rule
# targets module install/upgrade/remove/purge).
#
# Public API:
#   preflight_self_deps <argv...>
#     argv is the untouched CLI argv (subcommand + flags). Returns:
#       0  deps satisfied / installed / not needed for this subcommand
#       1  user declined, no interactive answer, or apt install failed
#       4  deps missing and sudo unavailable (PRD §7.4)
#
# Internal probes `_preflight_has_cmd` / `_preflight_has_sudo` /
# `_preflight_apt_install` are deliberately small named functions so bats
# can override them with mocks (test/unit/preflight_spec.bats).

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    printf "Warn: %s is a library, not a executable script.\n" "${BASH_SOURCE[0]##*/}"
    return 0 2>/dev/null
fi

: "${INIT_UBUNTU_YES:=false}"

# The tool's own dependencies (PRD §3.4).
PREFLIGHT_SELF_DEPS=(jq curl git)

# ── Probes (overridable in tests) ────────────────────────────────────────────

_preflight_has_cmd() {
    command -v -- "$1" >/dev/null 2>&1
}

# 0 = we can escalate (root, passwordless sudo, or interactive sudo).
_preflight_has_sudo() {
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        return 0
    fi
    _preflight_has_cmd sudo || return 1
    if sudo -n true 2>/dev/null; then
        return 0
    fi
    # sudo exists but wants a password — only viable when a tty can prompt.
    [[ -t 0 ]]
}

_preflight_apt_install() {
    local -a _sudo=()
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        _sudo=(sudo)
    fi
    "${_sudo[@]}" apt-get update -qq \
        && "${_sudo[@]}" apt-get install -y --no-install-recommends -- "$@"
}

# ── Gating ───────────────────────────────────────────────────────────────────

# 0 = this argv needs jq/curl/git; 1 = it doesn't (help / version paths).
# Mirrors dispatcher_dispatch's pre-subcommand handling.
_preflight_subcommand_needs_deps() {
    case "${1:-}" in
        ""|help|version|-h|--help|--version) return 1 ;;
        *) return 0 ;;
    esac
}

# Print the missing self-deps, one per line (empty output = all present).
_preflight_missing_deps() {
    local _dep
    for _dep in "${PREFLIGHT_SELF_DEPS[@]}"; do
        _preflight_has_cmd "${_dep}" || printf '%s\n' "${_dep}"
    done
    return 0
}

# ── Main entry ───────────────────────────────────────────────────────────────

preflight_self_deps() {
    # At most once per run (exported so sub-shells inherit the guard).
    if [[ "${INIT_UBUNTU_PREFLIGHT_DONE:-false}" == "true" ]]; then
        return 0
    fi

    if ! _preflight_subcommand_needs_deps "${1:-}"; then
        return 0
    fi

    local -a _missing=()
    local _line
    while IFS= read -r _line; do
        [[ -n "${_line}" ]] && _missing+=("${_line}")
    done < <(_preflight_missing_deps)

    if [[ "${#_missing[@]}" -eq 0 ]]; then
        export INIT_UBUNTU_PREFLIGHT_DONE=true
        return 0
    fi

    printf "[preflight] missing tool dependencies: %s\n" "${_missing[*]}" >&2

    if ! _preflight_has_sudo; then
        printf "[preflight] ERROR: sudo is not available; cannot install them automatically.\n" >&2
        printf "[preflight] ask an administrator to run, then re-run this tool:\n" >&2
        printf "[preflight]   sudo apt-get install -y %s\n" "${_missing[*]}" >&2
        return 4
    fi

    # Yes-mode: env override or -y / --yes anywhere in argv.
    local _yes="${INIT_UBUNTU_YES}"
    local _arg
    for _arg in "$@"; do
        case "${_arg}" in
            -y|--yes) _yes=true ;;
        esac
    done

    if [[ "${_yes}" != "true" ]]; then
        printf "[preflight] the following packages will be installed via apt:\n"
        local _dep
        for _dep in "${_missing[@]}"; do
            printf "  - %s\n" "${_dep}"
        done
        # printf the prompt ourselves: `read -p` only writes to a tty, and
        # the answer must be readable from plain stdin (pipes included).
        printf "Proceed? [Y/n] "
        local _answer=""
        if ! read -r _answer; then
            printf "\n[preflight] ERROR: no interactive answer; re-run with -y to auto-install\n" >&2
            return 1
        fi
        case "${_answer}" in
            ""|y|Y|yes|YES|Yes) ;;
            *)
                printf "[preflight] aborted by user; install manually or re-run with -y\n" >&2
                return 1
                ;;
        esac
    fi

    if ! _preflight_apt_install "${_missing[@]}"; then
        printf "[preflight] ERROR: apt install failed for: %s\n" "${_missing[*]}" >&2
        return 1
    fi

    export INIT_UBUNTU_PREFLIGHT_DONE=true
    printf "[preflight] installed: %s\n" "${_missing[*]}"
    return 0
}
