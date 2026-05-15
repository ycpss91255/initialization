#!/usr/bin/env bash
# lib/state.sh — state.json read / write with flock
#
# Per PRD §10.1 (state schema) and docs/architecture.md §6 (state cache vs
# real system state).
#
# Public API:
#   state_get_path
#     Print the absolute path to state.json the engine will use.
#
#   state_init
#     Ensure state.json exists with the minimum {"version":"0.1.0","installed":{}}
#     skeleton. Idempotent. Creates parent dirs.
#
#   state_record_install <name> [<manual=true|false>] [<version_provided>]
#     Set installed[<name>] = { version_provided, installed_at, installed_by,
#     manual }. Default manual=false (i.e. installed as a dep). Default
#     version_provided="unknown".
#
#   state_record_remove <name>
#     Drop installed[<name>] from state.json. Idempotent (no-op if absent).
#
#   state_is_recorded <name>
#     Exit 0 if installed[<name>] exists, 1 otherwise.
#
#   state_list_installed [--manual-only]
#     Print one module name per line (sorted). With --manual-only, only the
#     entries where manual=true.
#
#   state_get_field <name> <field>
#     field ∈ {version_provided, installed_at, installed_by, manual}.
#     Prints the value on stdout. Empty if module or field missing.
#
# Dependencies: jq (in apt-essentials APT_PKGS; in test-tools image).
# Concurrency: flock on ${state_dir}/.state.lock for every write.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    printf "Warn: %s is a library, not a executable script.\n" "${BASH_SOURCE[0]##*/}"
    return 0 2>/dev/null
fi

readonly STATE_SCHEMA_VERSION="0.1.0"
readonly STATE_INSTALLED_BY_DEFAULT="init_ubuntu@${INIT_UBUNTU_VERSION:-0.1.0-draft}"

# ── Path resolution ─────────────────────────────────────────────────────────

state_get_path() {
    local _dir="${INIT_UBUNTU_STATE_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/init_ubuntu}"
    printf '%s/state.json' "${_dir}"
}

_state_lock_path() {
    local _dir="${INIT_UBUNTU_STATE_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/init_ubuntu}"
    printf '%s/.state.lock' "${_dir}"
}

# ── jq check ────────────────────────────────────────────────────────────────

_state_require_jq() {
    if ! command -v jq >/dev/null 2>&1; then
        printf "[state] ERROR: jq not found. Install via 'apt-essentials' module or apt-get install jq.\n" >&2
        return 1
    fi
}

# ── ISO 8601 timestamp ──────────────────────────────────────────────────────

_state_iso8601() {
    if date --version >/dev/null 2>&1; then
        date -Iseconds          # GNU date
    else
        date +%Y-%m-%dT%H:%M:%S%z
    fi
}

# ── init ────────────────────────────────────────────────────────────────────

state_init() {
    _state_require_jq || return 1

    local _path; _path="$(state_get_path)"
    local _dir; _dir="$(dirname "${_path}")"

    mkdir -p "${_dir}"
    if [[ ! -f "${_path}" ]]; then
        printf '{"version":"%s","installed":{}}\n' "${STATE_SCHEMA_VERSION}" > "${_path}"
    fi
}

# ── lock helper ─────────────────────────────────────────────────────────────
#
# Usage:
#   _state_locked_write '<jq-filter>'
# Reads state.json, applies the jq filter, writes back atomically while
# holding an exclusive flock on .state.lock.

_state_locked_write() {
    local _filter="$1"
    state_init || return 1

    local _path; _path="$(state_get_path)"
    local _lock; _lock="$(_state_lock_path)"
    local _tmp; _tmp="$(mktemp "${_path}.XXXXXX")"

    (
        flock -x 9 || { printf "[state] ERROR: could not acquire lock\n" >&2; exit 1; }
        if jq "${_filter}" "${_path}" > "${_tmp}"; then
            mv "${_tmp}" "${_path}"
        else
            rm -f "${_tmp}"
            printf "[state] ERROR: jq filter failed: %s\n" "${_filter}" >&2
            exit 1
        fi
    ) 9>"${_lock}"
}

# ── public write API ────────────────────────────────────────────────────────

state_record_install() {
    local _name="${1:?state_record_install needs <name>}"
    local _manual="${2:-false}"
    local _version="${3:-unknown}"
    local _ts; _ts="$(_state_iso8601)"
    local _by="${STATE_INSTALLED_BY_DEFAULT}"

    # Normalize manual to a JSON bool.
    case "${_manual,,}" in
        true|1|yes) _manual="true" ;;
        *) _manual="false" ;;
    esac

    _state_locked_write \
        ".installed[\"${_name}\"] = {
             \"version_provided\": \"${_version}\",
             \"installed_at\": \"${_ts}\",
             \"installed_by\": \"${_by}\",
             \"manual\": ${_manual}
         }"
}

state_record_remove() {
    local _name="${1:?state_record_remove needs <name>}"
    _state_locked_write "del(.installed[\"${_name}\"])"
}

# ── public read API ─────────────────────────────────────────────────────────

state_is_recorded() {
    _state_require_jq || return 1
    local _name="${1:?state_is_recorded needs <name>}"
    local _path; _path="$(state_get_path)"
    [[ -f "${_path}" ]] || return 1
    jq -e --arg n "${_name}" '.installed | has($n)' "${_path}" >/dev/null
}

state_list_installed() {
    _state_require_jq || return 1
    local _manual_only="false"
    if [[ "${1:-}" == "--manual-only" ]]; then
        _manual_only="true"
    fi
    local _path; _path="$(state_get_path)"
    [[ -f "${_path}" ]] || return 0
    if [[ "${_manual_only}" == "true" ]]; then
        jq -r '.installed | to_entries[] | select(.value.manual == true) | .key' "${_path}" | sort
    else
        jq -r '.installed | keys[]' "${_path}" | sort
    fi
}

state_get_field() {
    _state_require_jq || return 1
    local _name="${1:?state_get_field needs <name>}"
    local _field="${2:?state_get_field needs <field>}"
    local _path; _path="$(state_get_path)"
    [[ -f "${_path}" ]] || return 0
    jq -r --arg n "${_name}" --arg f "${_field}" '
        .installed[$n][$f] // empty
    ' "${_path}"
}
