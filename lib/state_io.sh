#!/usr/bin/env bash
# lib/state_io.sh — import / export the install state across machines
#
# Per PRD §3.5 (sync payload schema), §3.6 (import/export), §18.1 (Q-A8
# import/export promoted to v0.1).
#
# Public API:
#   state_io_export <out-file> [--modules=<csv>]
#     Emit a payload.json describing the locally-installed modules. Schema:
#       {
#         "version": "<state schema version>",
#         "source_host": "<hostname>",
#         "source_user": "<USER>",
#         "exported_at": "<ISO 8601>",
#         "modules": [{"name": "...", "manual": true|false}, ...],
#         "include_config": false
#       }
#     Without --modules, every entry in state.json's installed{} ships.
#     With --modules=a,b,c, only those names ship (sorted).
#
#   state_io_payload_modules <in-file>
#     Read a payload.json and print the module names ON STDOUT, one per
#     line, in payload order. The caller (dispatcher) is responsible for
#     handing those names to runner_install. This split keeps state_io
#     free of dependency on runner; tests can verify the read path in
#     isolation.
#
#   state_io_import <in-file>
#     Alias for state_io_payload_modules (v0.1 keeps them equivalent;
#     later phases may diverge if we need to forward manual-flag etc.).
#
# Dependencies: jq (same as lib/state.sh).

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    printf "Warn: %s is a library, not a executable script.\n" "${BASH_SOURCE[0]##*/}"
    return 0 2>/dev/null
fi

readonly STATE_IO_SCHEMA_VERSION="0.1.0"

_state_io_require_jq() {
    if ! command -v jq >/dev/null 2>&1; then
        printf "[state_io] ERROR: jq not found. Install via 'apt-essentials' module.\n" >&2
        return 1
    fi
}

_state_io_iso8601() {
    if date --version >/dev/null 2>&1; then
        date -Iseconds
    else
        date +%Y-%m-%dT%H:%M:%S%z
    fi
}

# Internal: build the JSON modules array from selected names. Each element
# carries its `manual` flag pulled from state.json. Caller has already
# validated state.json exists.
_state_io_modules_array() {
    local _state_path="$1"; shift
    local -a _names=("$@")

    if [[ "${#_names[@]}" -eq 0 ]]; then
        printf '[]'
        return 0
    fi

    local _names_json
    _names_json="$(printf '%s\n' "${_names[@]}" | jq -R . | jq -s .)"

    jq --argjson names "${_names_json}" '
        .installed
        | to_entries
        | map(select(.key as $n | $names | index($n)))
        | sort_by(.key)
        | map({ name: .key, manual: (.value.manual // false) })
    ' "${_state_path}"
}

# ── Public: export ──────────────────────────────────────────────────────────

state_io_export() {
    _state_io_require_jq || return 1

    local _out=""
    local _filter_csv=""
    local _arg
    for _arg in "$@"; do
        case "${_arg}" in
            --modules=*) _filter_csv="${_arg#*=}" ;;
            -*) printf "[state_io] ERROR: unknown flag %s\n" "${_arg}" >&2; return 2 ;;
            *)
                if [[ -z "${_out}" ]]; then
                    _out="${_arg}"
                else
                    printf "[state_io] ERROR: too many positional args\n" >&2
                    return 2
                fi
                ;;
        esac
    done
    if [[ -z "${_out}" ]]; then
        printf "[state_io] ERROR: state_io_export needs <out-file>\n" >&2
        return 2
    fi

    if ! declare -F state_get_path >/dev/null 2>&1; then
        printf "[state_io] ERROR: lib/state.sh not loaded (state_get_path missing)\n" >&2
        return 1
    fi

    local _state_path; _state_path="$(state_get_path)"

    # Resolve module name list.
    local -a _names=()
    if [[ -n "${_filter_csv}" ]]; then
        local IFS=','
        # shellcheck disable=SC2206
        _names=(${_filter_csv})
    elif [[ -f "${_state_path}" ]]; then
        local _line
        while IFS= read -r _line; do
            [[ -n "${_line}" ]] && _names+=("${_line}")
        done < <(jq -r '.installed | keys[]' "${_state_path}" 2>/dev/null)
    fi

    local _modules_json
    if [[ -f "${_state_path}" ]]; then
        _modules_json="$(_state_io_modules_array "${_state_path}" "${_names[@]}")"
    else
        _modules_json='[]'
    fi

    local _host; _host="$(hostname 2>/dev/null || echo unknown)"
    local _user="${USER:-unknown}"
    local _ts; _ts="$(_state_io_iso8601)"

    jq -n \
        --arg version "${STATE_IO_SCHEMA_VERSION}" \
        --arg host "${_host}" \
        --arg user "${_user}" \
        --arg ts "${_ts}" \
        --argjson modules "${_modules_json}" \
        '{
            version: $version,
            source_host: $host,
            source_user: $user,
            exported_at: $ts,
            modules: $modules,
            include_config: false
        }' > "${_out}"
}

# ── Public: read payload → list module names ───────────────────────────────

state_io_payload_modules() {
    _state_io_require_jq || return 1
    local _in="${1:?state_io_payload_modules needs <in-file>}"

    if [[ ! -f "${_in}" ]]; then
        printf "[state_io] ERROR: payload file not found: %s\n" "${_in}" >&2
        return 2
    fi

    # Reject incompatible major versions defensively.
    local _payload_version
    _payload_version="$(jq -r '.version // empty' "${_in}" 2>/dev/null)"
    if [[ -z "${_payload_version}" ]]; then
        printf "[state_io] ERROR: payload missing 'version' field: %s\n" "${_in}" >&2
        return 2
    fi
    if [[ "${_payload_version%%.*}" != "0" ]]; then
        printf "[state_io] ERROR: payload schema version %s is not supported by this tool\n" \
            "${_payload_version}" >&2
        return 2
    fi

    jq -r '.modules[].name' "${_in}"
}

state_io_import() {
    state_io_payload_modules "$@"
}
