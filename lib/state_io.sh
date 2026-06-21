#!/usr/bin/env bash
# lib/state_io.sh — import / export the install state across machines
#
# Per PRD §7.2 (import/export subcommands), §10.1 (synced/local split),
# ADR-0018 (state.json synced/local split) and ADR-0013 (sync conflict
# resolution: dry-run default, union, remote-wins).
#
# Public API:
#   state_io_export <out-file> [--modules=<csv>]
#     Emit a payload.json describing the locally-installed modules. Only
#     the machine-portable `synced` section of each module ships — the
#     machine-specific `local` section NEVER leaves this host (ADR-0018).
#     Schema:
#       {
#         "version": "<payload schema version>",
#         "source_host": "<hostname>",
#         "source_user": "<USER>",
#         "exported_at": "<ISO 8601>",
#         "modules": [{"name": "...", "synced": {...}}, ...],
#         "include_config": false
#       }
#     Without --modules, every entry in state.json's installed{} ships.
#     With --modules=a,b,c, only those names ship (sorted).
#
#   state_io_payload_modules <in-file>
#     Validate a payload.json and print the module names on stdout, one
#     per line, in payload order.
#
#   state_io_import_plan <in-file>
#     ADR-0013 conflict pipeline, plan phase (no writes). Compares the
#     payload's synced sections against local state.json and prints a JSON
#     array of plan entries:
#       {"name", "action", "local_version", "remote_version", "synced"}
#     action ∈ install      remote-only, module exists in local catalog
#              skip         remote-only, no local module definition (+reason)
#              keep         local-only (union: never deleted)
#              noop         both sides, same version, no manual change
#              flag-manual  both sides, same version, manual sticky flip
#              upgrade      both sides, version diff (remote-wins on
#                           version_provided / depends_on; manual sticky)
#     `synced` is the section to write on apply (null for keep/noop/skip).
#     Catalog membership is asked from registry_has() when the registry is
#     loaded; without a registry every payload module counts as known.
#
#   state_io_import_apply <in-file> [--skip=<csv>] [--plan=<plan-file>]
#     Apply phase: write the plan's resulting synced sections to
#     state.json (install / upgrade / flag-manual entries). Without
#     --plan the plan is recomputed from <in-file>; the dispatcher passes
#     --plan with the pre-lifecycle plan so install runs in between do
#     not shift the computed actions. `local` sections from the payload
#     are NEVER applied — the receiver rebuilds `local` via its own
#     install pipeline (ADR-0018). --skip excludes modules whose install
#     lifecycle failed (so state never claims a module that did not land).
#
# Dependencies: jq (same as lib/state.sh); lib/state.sh must be loaded.

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    printf "Warn: %s is a library, not a executable script.\n" "${BASH_SOURCE[0]##*/}"
    return 0 2>/dev/null
fi

# 0.2.0: modules[] entries carry the full `synced` section (ADR-0018)
# instead of the 0.1.0 {name, manual} pairs.
readonly STATE_IO_SCHEMA_VERSION="0.2.0"

_state_io_require_jq() {
    if ! command -v jq >/dev/null 2>&1; then
        printf "[state_io] ERROR: jq not found. Install via the 'jq' module or apt-get install jq.\n" >&2
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

# Internal: validate a payload file (exists, parses, supported version).
_state_io_payload_validate() {
    local _in="$1"

    if [[ ! -f "${_in}" ]]; then
        printf "[state_io] ERROR: payload file not found: %s\n" "${_in}" >&2
        return 2
    fi
    if ! jq -e 'type == "object"' "${_in}" >/dev/null 2>&1; then
        printf "[state_io] ERROR: payload is not a JSON object: %s\n" "${_in}" >&2
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
}

# Internal: build the JSON modules array from selected names. Each element
# carries the module's `synced` section pulled from state.json — and only
# that (ADR-0018: `local` never ships). Caller has already validated
# state.json exists.
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
        | map({ name: .key, synced: (.value.synced // {}) })
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

    # Corruption guard (PRD §10.1): a corrupt state.json is quarantined by
    # lib/state.sh and the export fails fast — never export from garbage.
    if declare -F state_validate_file >/dev/null 2>&1; then
        state_validate_file || return 1
    fi

    # Resolve module name list.
    local -a _names=()
    if [[ -n "${_filter_csv}" ]]; then
        IFS=',' read -r -a _names <<< "${_filter_csv}"
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

    _state_io_payload_validate "${_in}" || return $?

    jq -r '.modules[].name' "${_in}"
}

# ── Public: import plan (ADR-0013 conflict pipeline) ────────────────────────

state_io_import_plan() {
    _state_io_require_jq || return 1
    local _in="${1:?state_io_import_plan needs <in-file>}"

    _state_io_payload_validate "${_in}" || return $?

    if ! declare -F state_get_path >/dev/null 2>&1; then
        printf "[state_io] ERROR: lib/state.sh not loaded (state_get_path missing)\n" >&2
        return 1
    fi
    if declare -F state_validate_file >/dev/null 2>&1; then
        state_validate_file || return 1
    fi

    local _state_path; _state_path="$(state_get_path)"
    local _local_installed='{}'
    if [[ -f "${_state_path}" ]]; then
        _local_installed="$(jq '.installed // {}' "${_state_path}")"
    fi

    # Catalog membership for payload names: ask the registry when loaded;
    # without a registry (state_io used standalone) every module is known.
    local _known_json='[]'
    local _n
    while IFS= read -r _n; do
        [[ -z "${_n}" ]] && continue
        if ! declare -F registry_has >/dev/null 2>&1 || registry_has "${_n}"; then
            _known_json="$(jq --arg n "${_n}" '. + [$n]' <<< "${_known_json}")"
        fi
    done < <(jq -r '.modules[].name' "${_in}")

    # Merge rules (ADR-0013): union of modules; remote wins on
    # version_provided / depends_on; `manual` is sticky to true. Only the
    # payload's `synced` sections are ever read — a smuggled `local`
    # section is ignored by construction.
    jq --argjson L "${_local_installed}" --argjson known "${_known_json}" '
        (.modules // [] | map({key: .name, value: (.synced // {})}) | from_entries) as $R
        | (($L | keys) + ($R | keys) | unique) as $names
        | [ $names[] as $n
            | (if $L[$n] == null then null else ($L[$n].synced // {}) end) as $ls
            | ($R[$n]) as $rs
            | if ($ls != null) and ($rs != null) then
                (($ls.manual == true) or ($rs.manual == true)) as $sticky
                | ($ls.version_provided // "unknown") as $lv
                | ($rs.version_provided // "unknown") as $rv
                | if $lv == $rv then
                    if ($ls.manual != true) and ($rs.manual == true) then
                        { name: $n, action: "flag-manual",
                          local_version: $lv, remote_version: $rv,
                          synced: ($ls + { manual: true }) }
                    else
                        { name: $n, action: "noop",
                          local_version: $lv, remote_version: $rv,
                          synced: null }
                    end
                  else
                    { name: $n, action: "upgrade",
                      local_version: $lv, remote_version: $rv,
                      synced: ($rs + { manual: $sticky }) }
                  end
              elif $ls != null then
                { name: $n, action: "keep",
                  local_version: ($ls.version_provided // "unknown"),
                  remote_version: null, synced: null }
              elif ($known | index($n)) != null then
                { name: $n, action: "install",
                  local_version: null,
                  remote_version: ($rs.version_provided // "unknown"),
                  synced: $rs }
              else
                { name: $n, action: "skip",
                  reason: "no local module definition",
                  local_version: null,
                  remote_version: ($rs.version_provided // "unknown"),
                  synced: null }
              end
          ]
    ' "${_in}"
}

# ── Public: import apply ─────────────────────────────────────────────────────

state_io_import_apply() {
    _state_io_require_jq || return 1

    local _in=""
    local _skip_csv=""
    local _plan_file=""
    local _arg
    for _arg in "$@"; do
        case "${_arg}" in
            --skip=*) _skip_csv="${_arg#*=}" ;;
            --plan=*) _plan_file="${_arg#*=}" ;;
            -*) printf "[state_io] ERROR: unknown flag %s\n" "${_arg}" >&2; return 2 ;;
            *)
                if [[ -z "${_in}" ]]; then
                    _in="${_arg}"
                else
                    printf "[state_io] ERROR: too many positional args\n" >&2
                    return 2
                fi
                ;;
        esac
    done
    if [[ -z "${_in}" ]]; then
        printf "[state_io] ERROR: state_io_import_apply needs <in-file>\n" >&2
        return 2
    fi

    local _plan
    if [[ -n "${_plan_file}" ]]; then
        if [[ ! -f "${_plan_file}" ]] || ! jq -e 'type == "array"' "${_plan_file}" >/dev/null 2>&1; then
            printf "[state_io] ERROR: --plan file missing or not a JSON array: %s\n" \
                "${_plan_file}" >&2
            return 2
        fi
        _plan="$(cat "${_plan_file}")"
    else
        _plan="$(state_io_import_plan "${_in}")" || return $?
    fi

    if ! declare -F state_set_synced >/dev/null 2>&1; then
        printf "[state_io] ERROR: lib/state.sh not loaded (state_set_synced missing)\n" >&2
        return 1
    fi

    local _skip=" ${_skip_csv//,/ } "
    local _rc=0
    local _entry _name _synced
    while IFS= read -r _entry; do
        [[ -z "${_entry}" ]] && continue
        _name="$(jq -r '.name' <<< "${_entry}")"
        if [[ "${_skip}" == *" ${_name} "* ]]; then
            printf "[state_io] %s: state write skipped (lifecycle did not complete)\n" \
                "${_name}" >&2
            continue
        fi
        _synced="$(jq -c '.synced' <<< "${_entry}")"
        if ! state_set_synced "${_name}" "${_synced}"; then
            printf "[state_io] ERROR: state write failed for %s\n" "${_name}" >&2
            _rc=1
        fi
    done < <(jq -c '.[] | select(.action == "install" or .action == "upgrade" or .action == "flag-manual")' \
        <<< "${_plan}")

    return "${_rc}"
}
