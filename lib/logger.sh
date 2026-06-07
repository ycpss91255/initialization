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

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
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
    # Explicit --color override (lib/color.sh, PRD §7.5): `always` forces
    # color even when piped; `never` strips it even on a tty.
    case "${INIT_UBUNTU_COLOR_MODE:-}" in
        always) return 0 ;;
        never)  return 1 ;;
    esac
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

# ── JSONL structured event log (PRD §10.2, ADR-0006) ────────────────────────
#
# Schema mirrors the OpenTelemetry Logs Data Model + W3C Trace Context
# (field names only — no OTel SDK):
#
#   {"timestamp":"2026-05-13T14:22:33.123456Z","severity_text":"INFO",
#    "body":"install_start","trace_id":"<session-uuid>",
#    "span_id":"install_docker_001",
#    "attributes":{"service.name":"docker","dry_run":false}}
#
# Usage:
#   log_event <severity> <service-or-empty> <body> [key=value ...]
#
# Behavior:
#   - No-op when $INIT_UBUNTU_LOG_FILE is unset/empty
#   - Emits one JSON object per line to the file (JSONL)
#   - `timestamp`: ISO 8601, UTC, microsecond precision
#   - `severity_text`: UPPERCASE enum (DEBUG/INFO/WARN/ERROR/FATAL)
#   - `body`: event-code enum (install_start / cmd_exec / ... — never
#     free-text sentences)
#   - `trace_id`: session-level; read from $INIT_UBUNTU_TRACE_ID
#     (self-generated + exported on first use when unset)
#   - `span_id`: module×lifecycle-level; read from $INIT_UBUNTU_SPAN_ID
#     (lib/runner.sh manages it); null when unset
#   - `attributes`: business payload container; `service.name` is the
#     module name, or "engine" for engine-level events (empty arg)
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

# Ensure a session-level trace id exists (W3C Trace Context, ADR-0006).
# setup_ubuntu.sh calls this eagerly at entry so every sub-shell inherits
# one id; log_event also calls it lazily as a safety net for standalone use.
_logger_ensure_trace_id() {
    [[ -n "${INIT_UBUNTU_TRACE_ID:-}" ]] && return 0

    local _id=""
    if command -v uuidgen >/dev/null 2>&1; then
        _id="$(uuidgen)"
    elif [[ -r /proc/sys/kernel/random/uuid ]]; then
        _id="$(< /proc/sys/kernel/random/uuid)"
    else
        _id="$(date +%s%N)"   # nanosecond unix time, last-resort fallback
    fi
    export INIT_UBUNTU_TRACE_ID="${_id}"
}

# ISO 8601 timestamp: UTC, microsecond precision (ADR-0006).
_logger_utc_timestamp() {
    local _ts
    _ts="$(date -u +%Y-%m-%dT%H:%M:%S.%6NZ 2>/dev/null)" || _ts=""
    if [[ -z "${_ts}" || "${_ts}" == *%* ]]; then
        # busybox / BSD date: no %N support — pad zero microseconds
        _ts="$(date -u +%Y-%m-%dT%H:%M:%S.000000Z)"
    fi
    printf '%s' "${_ts}"
}

function log_event() {
    [[ -z "${INIT_UBUNTU_LOG_FILE:-}" ]] && return 0

    local _severity="${1:-info}"; shift || true
    local _service="${1:-}";      shift || true
    local _body="${1:-?}";        shift || true

    _logger_ensure_trace_id

    local _ts
    _ts="$(_logger_utc_timestamp)"

    # Engine-level events (empty service arg) log as service.name="engine"
    # per PRD §10.2.
    [[ -z "${_service}" ]] && _service="engine"

    local _span_json="null"
    if [[ -n "${INIT_UBUNTU_SPAN_ID:-}" ]]; then
        _span_json="\"$(_json_escape "${INIT_UBUNTU_SPAN_ID}")\""
    fi

    local _line
    _line="{"
    _line+="\"timestamp\":\"${_ts}\","
    _line+="\"severity_text\":\"$(_json_escape "${_severity^^}")\","
    _line+="\"body\":\"$(_json_escape "${_body}")\","
    _line+="\"trace_id\":\"$(_json_escape "${INIT_UBUNTU_TRACE_ID}")\","
    _line+="\"span_id\":${_span_json},"
    _line+="\"attributes\":{\"service.name\":\"$(_json_escape "${_service}")\""

    local _kv _k _v
    for _kv in "$@"; do
        _k="${_kv%%=*}"
        _v="${_kv#*=}"
        [[ -z "${_k}" ]] && continue
        _line+=",\"$(_json_escape "${_k}")\":$( _json_value "${_v}" )"
    done

    _line+="}}"

    printf '%s\n' "${_line}" >> "${INIT_UBUNTU_LOG_FILE}"
}

# ── Session-end log retention (PRD §10.2, AC-33) ─────────────────────────────
#
# logrotate-like retention for the JSONL log directory, with no external
# dependency (pure bash + stat/sort from coreutils):
#
#   - keep at most INIT_UBUNTU_LOG_RETENTION_FILES (default 100) `.jsonl`
#   - keep none older than INIT_UBUNTU_LOG_RETENTION_DAYS (default 30) days
#   - when either limit is exceeded, delete from the oldest (mtime)
#
# Boundaries are inclusive on the keep side: exactly 100 files and a file
# exactly 30 days old are both kept.

# Default retention limits (PRD §10.2; env-overridable for tests).
export INIT_UBUNTU_LOG_RETENTION_DAYS="${INIT_UBUNTU_LOG_RETENTION_DAYS:-30}"
export INIT_UBUNTU_LOG_RETENTION_FILES="${INIT_UBUNTU_LOG_RETENTION_FILES:-100}"

# logger_prune_logs [<dir>]
#   <dir> defaults to the directory of $INIT_UBUNTU_LOG_FILE, falling back
#   to ${XDG_STATE_HOME:-$HOME/.local/state}/init_ubuntu/logs.
#   The active $INIT_UBUNTU_LOG_FILE itself is never deleted.
#   Emits one engine-level `log_pruned` OTel event (schema per ADR-0006)
#   carrying the deleted count when anything was removed.
#   Missing or empty directory is a silent no-op (returns 0).
function logger_prune_logs() {
    local _dir="${1:-}"
    if [[ -z "${_dir}" ]]; then
        if [[ -n "${INIT_UBUNTU_LOG_FILE:-}" ]]; then
            case "${INIT_UBUNTU_LOG_FILE}" in
                */*) _dir="${INIT_UBUNTU_LOG_FILE%/*}" ;;
                *)   _dir="." ;;
            esac
        else
            _dir="${XDG_STATE_HOME:-${HOME}/.local/state}/init_ubuntu/logs"
        fi
    fi
    [[ -d "${_dir}" ]] || return 0

    local _days="${INIT_UBUNTU_LOG_RETENTION_DAYS:-30}"
    local _max_files="${INIT_UBUNTU_LOG_RETENTION_FILES:-100}"
    local _max_age_min=$(( _days * 24 * 60 ))
    local _deleted=0

    # List candidates oldest-first as "<epoch-mtime>\t<path>" lines.
    # Portable glob + stat instead of `find -printf` (GNU-only; the bats
    # image ships busybox find, which lacks it). Whole-minute age keeps
    # the 30-day boundary keep-side inclusive, like `find -mmin +N`.
    local _now _entry _mtime _f
    local -a _files=() _mtimes=()
    _now="$(date +%s)"
    while IFS= read -r _entry; do
        [[ -z "${_entry}" ]] && continue
        _mtimes+=("${_entry%%$'\t'*}")
        _files+=("${_entry#*$'\t'}")
    done < <(
        for _f in "${_dir}"/*.jsonl; do
            [[ -f "${_f}" ]] || continue
            printf '%s\t%s\n' "$(stat -c %Y -- "${_f}")" "${_f}"
        done | sort -n
    )

    # Delete from the oldest when either rule fires:
    #   Rule 1 — age:   strictly older than _days (whole minutes)
    #   Rule 2 — count: the first (total - _max_files) entries
    # The active log file is never a victim.
    local _total="${#_files[@]}"
    local _excess=$(( _total > _max_files ? _total - _max_files : 0 ))
    local _idx
    for (( _idx = 0; _idx < _total; _idx++ )); do
        _f="${_files[_idx]}"
        _mtime="${_mtimes[_idx]}"
        [[ "${_f}" == "${INIT_UBUNTU_LOG_FILE:-}" ]] && continue
        if [[ "${_idx}" -lt "${_excess}" ]] || \
           [[ "$(( (_now - _mtime) / 60 ))" -gt "${_max_age_min}" ]]; then
            rm -f -- "${_f}" && _deleted=$(( _deleted + 1 ))
        fi
    done

    if [[ "${_deleted}" -gt 0 ]]; then
        log_event info "" "log_pruned" \
            "deleted_count=${_deleted}" \
            "retention_days=${_days}" \
            "retention_max_files=${_max_files}"
    fi
    return 0
}

# ── Initialize colors ────────────────────────────────────────────────────────

_support_color
