#!/usr/bin/env bash
# lib/state.sh — state.json read / write with flock
#
# Per PRD §10.1 (state schema) and doc/architecture.md §6 (state cache vs
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
#   state_validate_file
#     Guard against corrupt state.json (PRD §10.1). Returns 0 when the file
#     is absent or parses as a JSON object. Otherwise quarantines it
#     (mv → state.json.corrupt.<ts>), prints recovery guidance, returns 1.
#     NEVER silently rebuilds — manual / dep data must not be lost.
#     Automated repair belongs to `doctor --fix` (0.3.0), out of scope here.
#
# Dependencies: jq (in apt-essentials APT_PKGS; in test-tools image).
# Concurrency: flock on ${state_dir}/.state.lock for every write.
#   Contention prints a one-line wait notice; after
#   ${INIT_UBUNTU_LOCK_TIMEOUT:-30}s the writer gives up with exit code 1
#   and prints the lock holder info (PID / lock file path).

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
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

# ── corruption guard (PRD §10.1) ─────────────────────────────────────────────
#
# state_validate_file
#   Quarantine-then-fail on corrupt state.json. A valid state file must parse
#   as a JSON object; anything else (truncated JSON, garbage, top-level null)
#   is moved aside to state.json.corrupt.<ts> and the caller gets exit 1 with
#   recovery guidance. We never rebuild in place: a silent rebuild would drop
#   the manual flags and dep snapshot data the user cannot reconstruct.

state_validate_file() {
    _state_require_jq || return 1
    local _path; _path="$(state_get_path)"
    [[ -f "${_path}" ]] || return 0
    if jq -e 'type == "object"' "${_path}" >/dev/null 2>&1; then
        return 0
    fi

    local _ts; _ts="$(date +%Y%m%d-%H%M%S)"
    local _quarantine="${_path}.corrupt.${_ts}"
    mv "${_path}" "${_quarantine}"
    {
        printf "[state] ERROR: %s is corrupt (not a valid JSON object)\n" "${_path}"
        printf "[state] quarantined to: %s\n" "${_quarantine}"
        printf "[state] recovery:\n"
        printf "[state]   - re-run install: modules are idempotent, records will be rebuilt; or\n"
        printf "[state]   - manually fix the quarantined file, then rename it back to state.json\n"
        printf "[state] state.json is never rebuilt silently (manual / dep data must not be lost);\n"
        printf "[state] automated repair is 'doctor --fix' (planned for 0.3.0)\n"
    } >&2
    return 1
}

# ── init ────────────────────────────────────────────────────────────────────

state_init() {
    _state_require_jq || return 1
    state_validate_file || return 1

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
#
# Contention UX (PRD §10.1): a contended writer prints a one-line wait
# notice, waits up to ${INIT_UBUNTU_LOCK_TIMEOUT:-30}s, then gives up with
# exit code 1 printing the holder info (PID / lock file path). The holder
# PID is published to <lock>.pid by whichever writer holds the lock.

readonly STATE_LOCK_TIMEOUT_DEFAULT=30

# _state_flock_acquire <timeout-secs>
#   Acquire an exclusive flock on fd 9 (the caller must have opened fd 9 on
#   the .state.lock path in append mode — append so the lock file is never
#   truncated). The lock path is re-derived here via _state_lock_path.
_state_flock_acquire() {
    local _timeout="$1"
    local _lock; _lock="$(_state_lock_path)"
    local _holder

    if flock -xn 9; then
        return 0
    fi

    _holder="$(cat "${_lock}.pid" 2>/dev/null)"
    printf "[state] waiting for state lock %s (held by PID %s, timeout %ss)\n" \
        "${_lock}" "${_holder:-unknown}" "${_timeout}" >&2

    # Timed wait via non-blocking retry: BusyBox flock (test-tools image)
    # has no `-w <secs>`, so poll `flock -n` until the deadline instead.
    local _deadline=$(( SECONDS + _timeout ))
    while (( SECONDS < _deadline )); do
        sleep 0.2
        if flock -xn 9; then
            return 0
        fi
    done

    _holder="$(cat "${_lock}.pid" 2>/dev/null)"
    {
        printf "[state] ERROR: timed out after %ss waiting for state lock\n" "${_timeout}"
        printf "[state] lock file: %s\n" "${_lock}"
        printf "[state] lock holder PID: %s\n" "${_holder:-unknown}"
    } >&2
    return 1
}

_state_locked_write() {
    local _filter="$1"
    state_init || return 1

    local _path; _path="$(state_get_path)"
    local _lock; _lock="$(_state_lock_path)"
    local _timeout="${INIT_UBUNTU_LOCK_TIMEOUT:-${STATE_LOCK_TIMEOUT_DEFAULT}}"
    local _tmp; _tmp="$(mktemp "${_path}.XXXXXX")"
    local _rc

    (
        _state_flock_acquire "${_timeout}" || exit 1
        printf '%s' "${BASHPID}" > "${_lock}.pid"
        if jq "${_filter}" "${_path}" > "${_tmp}"; then
            mv "${_tmp}" "${_path}"
        else
            printf "[state] ERROR: jq filter failed: %s\n" "${_filter}" >&2
            exit 1
        fi
        rm -f "${_lock}.pid"
    ) 9>>"${_lock}"
    _rc=$?
    rm -f "${_tmp}"
    return "${_rc}"
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

# state_record_upgrade <name> <version>
#   Updates an existing installed entry's version_provided + last_upgraded_at.
#   No-op (jq |= leaves untouched) if the module is not in .installed —
#   upgrade is meant to run on already-installed modules; engine refuses
#   upgrade for absent ones at the dispatcher layer.
state_record_upgrade() {
    local _name="${1:?state_record_upgrade needs <name>}"
    local _version="${2:-unknown}"
    local _ts; _ts="$(_state_iso8601)"

    _state_locked_write \
        ".installed[\"${_name}\"] |= (
             if . == null then null
             else . + {
                 \"version_provided\": \"${_version}\",
                 \"last_upgraded_at\": \"${_ts}\"
             }
             end
         )"
}

# state_record_verify <name>
#   Stamps last_verified_at on an existing installed entry. No-op when the
#   module is not in .installed (verify on uninstalled is a CLI-layer error,
#   but the state write should still degrade gracefully).
state_record_verify() {
    local _name="${1:?state_record_verify needs <name>}"
    local _ts; _ts="$(_state_iso8601)"

    _state_locked_write \
        ".installed[\"${_name}\"] |= (
             if . == null then null
             else . + { \"last_verified_at\": \"${_ts}\" }
             end
         )"
}

# ── public read API ─────────────────────────────────────────────────────────

state_is_recorded() {
    _state_require_jq || return 1
    state_validate_file || return 1
    local _name="${1:?state_is_recorded needs <name>}"
    local _path; _path="$(state_get_path)"
    [[ -f "${_path}" ]] || return 1
    jq -e --arg n "${_name}" '.installed | has($n)' "${_path}" >/dev/null
}

state_list_installed() {
    _state_require_jq || return 1
    state_validate_file || return 1
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
    state_validate_file || return 1
    local _name="${1:?state_get_field needs <name>}"
    local _field="${2:?state_get_field needs <field>}"
    local _path; _path="$(state_get_path)"
    [[ -f "${_path}" ]] || return 0
    jq -r --arg n "${_name}" --arg f "${_field}" '
        .installed[$n][$f] // empty
    ' "${_path}"
}
