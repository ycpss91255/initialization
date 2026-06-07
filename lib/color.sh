#!/usr/bin/env bash
# lib/color.sh — ANSI color detection + palette (PRD §5.1 / §7.5, M8, AC-16)
#
# Decides once whether ANSI color output is appropriate and exposes that
# decision to every consumer (CLI surfaces, lib/logger.sh, modules).
#
# Public API:
#   color_init [auto|always|never]
#       Compute the color decision (default mode: auto) and populate the
#       CLR_* palette. Exports:
#         INIT_UBUNTU_COLOR_MODE  — requested mode (auto|always|never)
#         COLOR_ENABLED           — "true" | "false" (the decision)
#         LOG_COLOR               — kept in sync for lib/logger.sh
#       Returns 2 on an unknown mode (PRD §7.4 usage error).
#   color_enabled
#       Returns 0 when color is on, 1 otherwise.
#   colorize <NAME> <text...>
#       Print <text> wrapped in ${CLR_<NAME>}..${CLR_RESET} when color is
#       on; plain <text> otherwise. <NAME> is e.g. RED / BOLD_GREEN.
#
# Palette variables (empty strings when color is off, so they are always
# safe to interpolate):
#   CLR_RED CLR_GREEN CLR_YELLOW CLR_BLUE CLR_MAGENTA CLR_CYAN CLR_WHITE
#   CLR_BOLD_RED ... CLR_BOLD_WHITE
#   CLR_RESET
#
# Auto-detection (mode=auto) turns color OFF when any of these hold:
#   - stdout is not a tty (piped / redirected, AC-16)
#   - $NO_COLOR is set non-empty (https://no-color.org)
#   - $TERM is "dumb" (or empty)
#   - the process runs as a background job (its process group is not the
#     terminal's foreground process group)

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    printf "Warn: %s is a library, not an executable script.\n" "${BASH_SOURCE[0]##*/}"
    return 0 2>/dev/null
fi

# ── Detection ────────────────────────────────────────────────────────────────

# _color_auto_detect — return 0 when auto mode should enable color.
_color_auto_detect() {
    # NO_COLOR convention: any non-empty value disables color.
    [[ -n "${NO_COLOR:-}" ]] && return 1

    # Dumb / unset terminal cannot render escapes.
    [[ -z "${TERM:-}" || "${TERM}" == "dumb" ]] && return 1

    # Piped or redirected stdout (AC-16: `setup_ubuntu list | cat`).
    [[ -t 1 ]] || return 1

    # Background job: our process group differs from the terminal's
    # foreground process group. `ps -o pgid/tpgid` is procps syntax;
    # busybox ps lacks it, so unreadable values skip the check.
    local _pgid="" _tpgid=""
    _pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d '[:space:]')" || _pgid=""
    _tpgid="$(ps -o tpgid= -p $$ 2>/dev/null | tr -d '[:space:]')" || _tpgid=""
    if [[ -n "${_pgid}" && -n "${_tpgid}" && "${_tpgid}" != "-1" \
          && "${_pgid}" != "${_tpgid}" ]]; then
        return 1
    fi

    return 0
}

# ── Palette ──────────────────────────────────────────────────────────────────

_COLOR_NAMES=(RED GREEN YELLOW BLUE MAGENTA CYAN WHITE)
_COLOR_CODES=(31  32    33     34   35      36   37)

# _color_set_palette <on|off> — fill or blank every CLR_* variable.
_color_set_palette() {
    local _on="${1:?"${FUNCNAME[0]} needs on|off"}"
    local _i
    for _i in "${!_COLOR_NAMES[@]}"; do
        if [[ "${_on}" == "on" ]]; then
            printf -v "CLR_${_COLOR_NAMES[_i]}"      '\033[22;%sm' "${_COLOR_CODES[_i]}"
            printf -v "CLR_BOLD_${_COLOR_NAMES[_i]}" '\033[1;%sm'  "${_COLOR_CODES[_i]}"
        else
            printf -v "CLR_${_COLOR_NAMES[_i]}"      ''
            printf -v "CLR_BOLD_${_COLOR_NAMES[_i]}" ''
        fi
    done
    if [[ "${_on}" == "on" ]]; then
        printf -v CLR_RESET '\033[0m'
    else
        CLR_RESET=""
    fi
    export CLR_RED CLR_GREEN CLR_YELLOW CLR_BLUE CLR_MAGENTA CLR_CYAN \
           CLR_WHITE CLR_BOLD_RED CLR_BOLD_GREEN CLR_BOLD_YELLOW \
           CLR_BOLD_BLUE CLR_BOLD_MAGENTA CLR_BOLD_CYAN CLR_BOLD_WHITE \
           CLR_RESET
}

# ── Public API ───────────────────────────────────────────────────────────────

color_init() {
    local _mode="${1:-auto}"

    case "${_mode}" in
        auto|always|never) ;;
        *)
            printf "[color] ERROR: invalid --color mode '%s' (want auto|always|never)\n" \
                "${_mode}" >&2
            return 2
            ;;
    esac

    local _on="off"
    case "${_mode}" in
        always) _on="on" ;;
        never)  _on="off" ;;
        auto)   _color_auto_detect && _on="on" ;;
    esac

    _color_set_palette "${_on}"

    if [[ "${_on}" == "on" ]]; then
        COLOR_ENABLED="true"
        LOG_COLOR="true"
    else
        COLOR_ENABLED="false"
        LOG_COLOR="false"
    fi
    INIT_UBUNTU_COLOR_MODE="${_mode}"
    export COLOR_ENABLED LOG_COLOR INIT_UBUNTU_COLOR_MODE
    return 0
}

color_enabled() {
    [[ "${COLOR_ENABLED:-false}" == "true" ]]
}

colorize() {
    local _name="${1:?"${FUNCNAME[0]} needs a color name (e.g. RED)"}"; shift
    if color_enabled; then
        local _var="CLR_${_name}"
        printf '%s%s%s\n' "${!_var:-}" "$*" "${CLR_RESET:-}"
    else
        printf '%s\n' "$*"
    fi
}
