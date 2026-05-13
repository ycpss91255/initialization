#!/usr/bin/env bash
# lib/logger.sh — init_ubuntu logger
#
# Lineage: copied from module/function/logger.sh (kept identical to preserve
# behavior for existing module/setup_*.sh which still sources the old path).
# Phase 7 will delete module/function/logger.sh in favor of this.
#
# Extensions vs upstream (init_ubuntu addition):
#   - log_event() emits JSONL structured log entries to $INIT_UBUNTU_LOG_FILE
#     (no-op when env var unset; see PRD §10.2 schema)
#
# Note: this library does NOT declare `set -euo pipefail` at top level —
# the original module/function/logger.sh did, but that leaks strict mode
# into every caller and forces them to fight bash's `set -u` rules. The
# convention in lib/ is: callers (setup_ubuntu.sh, bats test, module
# sub-shells) set strict mode themselves.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    printf "Warn: %s is a library, not a executable script.\n" "${BASH_SOURCE[0]##*/}"
    printf "To learn how to use it, please refer to '%s'\n" "../../test/unit/logger_spec.bats"
    return 0 2>/dev/null
fi

[[ -n "${TTY_COLORS_READY:-}" ]] && return 0

export LOG_LEVEL="${LOG_LEVEL:-INFO}"
export LOG_COLOR="${LOG_COLOR:-true}"

export TTY_COLORS_READY=""

# ── Color setup ──────────────────────────────────────────────────────────────

# Support color output in the terminal
function _support_color() {
    function _esc() {
        local out="${1:?"${FUNCNAME[0]} need outvar."}"; shift
        printf -v "${out}" "\033[%sm" "$1"
    }

    function _bold() {
        local out="${1:?"${FUNCNAME[0]} need outvar."}"; shift
        _esc "${out}" "1;$1"
    }

    local -a _names=(RED GREEN YELLOW BLUE MAGENTA CYAN WHITE)
    local -a _codes=(31  32    33     34   35      36   37)
    local _i=""

    for _i in "${!_names[@]}"; do
        _esc "TTY_CLR_${_names[_i]}"  "22;${_codes[_i]}"
        _bold "TTY_BOLD_${_names[_i]}" "${_codes[_i]}"
    done

    _esc "TTY_CLR_RESET" "0"

    TTY_COLORS_READY="true"
}

# ── Level + FD plumbing ──────────────────────────────────────────────────────

function _logger_level_to_num() {
    local -n _outvar="${1:?"${FUNCNAME[0]} need outvar."}"; shift
    local _level="${1:?"${FUNCNAME[0]} need level."}"

    case "${_level^^}" in
        DEBUG) _outvar=10 ;; INFO)  _outvar=20 ;; WARN) _outvar=30 ;;
        ERROR) _outvar=40 ;; FATAL) _outvar=50 ;; *)    _outvar=20 ;;
    esac
}

function _logger_should_print() {
    local _level="${1:?"${FUNCNAME[0]} need level."}"
    local _target="" _default=""
    _logger_level_to_num _target "${_level}"
    _logger_level_to_num _default "${LOG_LEVEL:-INFO}"

    if [[ "${_target}" -ge "${_default}" ]]; then
        return 0
    else
        return 1
    fi
}

function _logger_fd_for_level() {
    local -n _outvar="${1:?"${FUNCNAME[0]} need outvar"}"; shift
    local _level="${1:?"${FUNCNAME[0]} need level"}"

    case "${_level^^}" in
        DEBUG|INFO)       _outvar="1" ;;  # stdout
        WARN|ERROR|FATAL) _outvar="2" ;;  # stderr
        *)                _outvar="1" ;;
    esac
}

function _logger_header_color() {
    local -n _outvar="${1:?"${FUNCNAME[0]} need outvar."}"; shift
    local _level="${1:?"${FUNCNAME[0]} need level."}"
    local _reset="${TTY_CLR_RESET:-}" _color=""

    case "${_level^^}" in
        DEBUG) _color="${TTY_CLR_BLUE}"   ;;
        INFO)  _color="${TTY_CLR_GREEN}"  ;;
        WARN)  _color="${TTY_CLR_YELLOW}" ;;
        ERROR) _color="${TTY_CLR_RED}"    ;;
        FATAL) _color="${TTY_BOLD_RED}"   ;;
        *)     _color="${TTY_CLR_RESET}"  ;;
    esac

    _outvar="${_color}${_level}${_reset}"
}

function _logger_color_control() {
    local _fd="${1:?"${FUNCNAME[0]} need fd."}";
    if { [[ -t 1 && "${_fd}" -eq 1 ]] || [[ -t 2 && "${_fd}" -eq 2 ]]; } && \
    [[ "${LOG_COLOR}" != "false" ]]; then
        return 0
    else
        return 1
    fi
}

function _logger_formatter() {
    local _level="${1:?${FUNCNAME[0]} need level.}"; shift
    local _fd="${1:?${FUNCNAME[0]} need fd.}"; shift

    local _date="" _funcname="" _source=""
    _date="$(date +"%y-%m-%d %H:%M:%S")"
    # Use :-unknown defaults; call stack may be shallow when log_* is invoked
    # from `bash -c "..."` or directly under bats `run`, so BASH_SOURCE[3] /
    # FUNCNAME[3] can be unbound under `set -u`.
    _source="${BASH_SOURCE[3]:-unknown}"
    _source="${_source##*/}"
    _funcname=${FUNCNAME[3]:-main}

    printf "%s [%s] [%s] [%s] %s\n" \
        "${_date}" \
        "${_source%.*}" \
        "${_funcname}" \
        "${_level}" \
        "$*" >&"${_fd}"
}

function _logger_print() {
    local _level="${1:?"${FUNCNAME[0]} need level."}"
    local _level_str="${1:?"${FUNCNAME[0]} need level."}"; shift
    local _level_fd=""

    _logger_should_print "${_level}" || return 0

    _logger_fd_for_level _level_fd "${_level}"

    _logger_color_control "${_level_fd}" && \
     _logger_header_color _level_str "${_level}"

    _logger_formatter "${_level_str}" "${_level_fd}" "$*"

    # Mirror to JSONL log file if enabled (PRD §10.2)
    if [[ -n "${INIT_UBUNTU_LOG_FILE:-}" ]]; then
        local _module="${INIT_UBUNTU_CURRENT_MODULE:-}"
        log_event "${_level,,}" "${_module}" "message" "msg=$*"
    fi
}

# ── Public API ───────────────────────────────────────────────────────────────

function log_debug() { _logger_print "DEBUG" "$*"; }
function log_info()  { _logger_print "INFO"  "$*"; }
function log_warn()  { _logger_print "WARN"  "$*"; }
function log_error() { _logger_print "ERROR" "$*"; }
function log_fatal() { _logger_print "FATAL" "$*"; exit 1; }

# ── JSONL structured event log (PRD §10.2) ───────────────────────────────────
#
# Usage:
#   log_event <level> <module-or-empty> <event> [key=value ...]
#
# Behavior:
#   - No-op when $INIT_UBUNTU_LOG_FILE is unset/empty
#   - Emits one JSON object per line to the file (JSONL)
#   - ISO 8601 timestamp (e.g. 2026-05-13T14:22:33+08:00)
#   - Numeric-looking values emitted as numbers; true/false emitted as
#     bare booleans; everything else JSON-string-quoted
#
# Example:
#   log_event info docker install_start \
#       version=apt-managed install_target=sudo dry_run=false

_json_escape() {
    local _s="$1"
    _s="${_s//\\/\\\\}"
    _s="${_s//\"/\\\"}"
    _s="${_s//$'\n'/\\n}"
    _s="${_s//$'\r'/\\r}"
    _s="${_s//$'\t'/\\t}"
    printf '%s' "${_s}"
}

_json_value() {
    local _v="$1"
    if [[ -z "${_v}" ]]; then
        printf 'null'
    elif [[ "${_v}" == "true" || "${_v}" == "false" ]]; then
        printf '%s' "${_v}"
    elif [[ "${_v}" =~ ^-?[0-9]+$ ]] || [[ "${_v}" =~ ^-?[0-9]+\.[0-9]+$ ]]; then
        printf '%s' "${_v}"
    else
        printf '"%s"' "$(_json_escape "${_v}")"
    fi
}

function log_event() {
    [[ -z "${INIT_UBUNTU_LOG_FILE:-}" ]] && return 0

    local _level="${1:-info}"; shift || true
    local _module="${1:-}";    shift || true
    local _event="${1:-?}";    shift || true

    local _ts
    if date --version >/dev/null 2>&1; then
        _ts="$(date -Iseconds)"                  # GNU date
    else
        _ts="$(date +%Y-%m-%dT%H:%M:%S%z)"       # busybox / BSD fallback
    fi

    local _line
    _line="{"
    _line+="\"ts\":\"${_ts}\","
    _line+="\"level\":\"$(_json_escape "${_level}")\","
    _line+="\"module\":$( _json_value "${_module}" ),"
    _line+="\"event\":\"$(_json_escape "${_event}")\""

    local _kv _k _v
    for _kv in "$@"; do
        _k="${_kv%%=*}"
        _v="${_kv#*=}"
        [[ -z "${_k}" ]] && continue
        _line+=",\"$(_json_escape "${_k}")\":$( _json_value "${_v}" )"
    done

    _line+="}"

    printf '%s\n' "${_line}" >> "${INIT_UBUNTU_LOG_FILE}"
}

# ── Initialize colors ────────────────────────────────────────────────────────

_support_color
