#!/usr/bin/env bash
# lib/dispatcher_state_io.sh — state / config persistence subcommands
#
# Extracted from lib/dispatcher.sh (architecture-review E1). This cluster moves
# state.json and config.ini across machines and disk:
#
#   _dispatcher_status   status (deprecated alias → list --installed)
#   _dispatcher_export   export <file> (state.json synced sections)
#   _dispatcher_import   import <file> (ADR-0013 conflict pipeline)
#   _dispatcher_config   config set|get|unset|show
#   _dispatcher_sync     sync <user@host> [--pull]
#
# import fans back out to _dispatcher_lifecycle (lib/dispatcher_lifecycle.sh)
# and sync fans out to _dispatcher_import; both resolve at call time in the
# shared function namespace. Sourced by lib/dispatcher.sh; not executable.

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    printf "Warn: %s is a library, not a executable script.\n" "${BASH_SOURCE[0]##*/}"
    return 0 2>/dev/null
fi

# ── status (deprecated) ──────────────────────────────────────────────────────

# status — deprecated alias (PRD §7.2): warn on stderr, forward to
# `list --installed`. Flag validation is delegated to _dispatcher_list.
_dispatcher_status() {
    printf "[dispatcher] WARN: 'status' is deprecated; use 'list --installed' instead (forwarding)\n" >&2
    _dispatcher_list --installed "$@"
}

# ── export / import ──────────────────────────────────────────────────────────

_dispatcher_export() {
    local _out=""
    local -a _passthrough=()
    local _arg
    for _arg in "$@"; do
        case "${_arg}" in
            --modules=*) _passthrough+=("${_arg}") ;;
            -*) printf "[dispatcher] ERROR: unknown flag %s\n" "${_arg}" >&2; return 2 ;;
            *)
                if [[ -z "${_out}" ]]; then
                    _out="${_arg}"
                else
                    printf "[dispatcher] ERROR: export takes one <out-file>\n" >&2
                    return 2
                fi
                ;;
        esac
    done
    if [[ -z "${_out}" ]]; then
        printf "[dispatcher] ERROR: export needs <out-file>\n" >&2
        return 2
    fi

    state_io_export "${_out}" "${_passthrough[@]}"
    local _rc=$?
    if [[ "${_rc}" -eq 0 ]]; then
        printf "[dispatcher] state exported to %s\n" "${_out}"
    fi
    return "${_rc}"
}

# import — ADR-0013 conflict pipeline, same rules as `sync --pull`:
# dry-run by default (print the plan, write nothing), `--apply` commits.
# Union of modules, remote-wins on version/depends_on, `manual` sticky to
# true. The payload's `local` sections are never applied (ADR-0018); the
# receiver rebuilds `local` via its own install pipeline.
_dispatcher_import() {
    local _in=""
    local _apply="false"
    local _dry="false"
    local _arg
    for _arg in "$@"; do
        case "${_arg}" in
            -y|--yes) export INIT_UBUNTU_YES=true ;;
            --apply) _apply="true" ;;
            --dry-run) _dry="true" ;;
            -*) printf "[dispatcher] ERROR: unknown flag %s\n" "${_arg}" >&2; return 2 ;;
            *)
                if [[ -z "${_in}" ]]; then
                    _in="${_arg}"
                else
                    printf "[dispatcher] ERROR: import takes one <in-file>\n" >&2
                    return 2
                fi
                ;;
        esac
    done
    if [[ -z "${_in}" ]]; then
        printf "[dispatcher] ERROR: import needs <in-file>\n" >&2
        return 2
    fi
    # Dry-run is the default; an explicit --dry-run (flag or global env)
    # always wins over --apply.
    [[ "${_dry}" == "true" || "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]] && _apply="false"

    if ! declare -F state_io_import_plan >/dev/null 2>&1; then
        printf "[dispatcher] ERROR: state_io lib not loaded\n" >&2
        return 1
    fi

    local _plan _rc
    _plan="$(state_io_import_plan "${_in}")"
    _rc=$?
    if [[ "${_rc}" -ne 0 ]]; then
        return "${_rc}"
    fi

    local _source
    _source="$(jq -r 'if .source_host then ((.source_user // "?") + "@" + .source_host) else "local file" end' \
        "${_in}" 2>/dev/null || printf 'local file')"

    printf "IMPORT DIFF (source: %s)\n" "${_source}"
    jq -r '.[]
        | if .action == "install" then
            "  + \(.name)\tinstall\t\(.remote_version)\tmanual=\(.synced.manual // false)"
          elif .action == "upgrade" then
            "  ~ \(.name)\tupgrade\t\(.local_version) -> \(.remote_version)"
          elif .action == "flag-manual" then
            "  * \(.name)\tmanual\tflag manual=true (sticky)"
          elif .action == "keep" then
            "  = \(.name)\tkeep\t\(.local_version)\t(local only)"
          elif .action == "noop" then
            "  = \(.name)\tup-to-date\t\(.local_version)"
          else
            "  ! \(.name)\tskip\t\(.reason)"
          end' <<< "${_plan}"

    if [[ "${_apply}" != "true" ]]; then
        printf "\n[dispatcher] dry-run (default): nothing was changed. Re-run with --apply to commit.\n"
        return 0
    fi

    # Modules that need a real lifecycle run on this machine.
    local -a _installs=() _upgrades=()
    local _n
    while IFS= read -r _n; do
        [[ -n "${_n}" ]] && _installs+=("${_n}")
    done < <(jq -r '.[] | select(.action == "install") | .name' <<< "${_plan}")
    while IFS= read -r _n; do
        [[ -n "${_n}" ]] && _upgrades+=("${_n}")
    done < <(jq -r '.[] | select(.action == "upgrade") | .name' <<< "${_plan}")

    # Refuse root only when we'll actually mutate the system (PRD §10);
    # a flag-manual-only apply is a pure state.json write and stays
    # root-safe for CI / bats.
    if [[ "$(( ${#_installs[@]} + ${#_upgrades[@]} ))" -gt 0 && "${EUID:-0}" -eq 0 ]]; then
        printf "[dispatcher] ERROR: do not run import --apply as root. Re-run as a regular user; sudo will be requested per-module.\n" >&2
        return 4
    fi

    # ADR-0013 --apply: each affected module runs through the normal
    # install / upgrade lifecycle, then the merged synced sections land in
    # state.json (remote-wins). Partial failure → exit 6 (PRD §7.4).
    local _lifecycle_rc=0
    if [[ "${#_installs[@]}" -gt 0 ]]; then
        _dispatcher_lifecycle install "${_installs[@]}" || _lifecycle_rc=$?
    fi
    if [[ "${#_upgrades[@]}" -gt 0 ]] && declare -F runner_upgrade >/dev/null 2>&1; then
        runner_upgrade "${_upgrades[@]}" || _lifecycle_rc=$?
    fi

    # Never let state.json claim an install that did not land: any
    # install-entry module still missing from state is excluded from the
    # state merge.
    local _skip_csv=""
    for _n in "${_installs[@]}"; do
        if ! state_is_recorded "${_n}"; then
            _skip_csv="${_skip_csv:+${_skip_csv},}${_n}"
        fi
    done

    # Hand the pre-lifecycle plan to the apply phase: the install runs
    # above already changed local state, so recomputing the plan here
    # would shift the actions (install→upgrade/noop) and lose remote-wins.
    local _plan_file
    _plan_file="$(mktemp /tmp/init_ubuntu_import_plan.XXXXXX.json)"
    printf '%s\n' "${_plan}" > "${_plan_file}"

    local -a _apply_args=("${_in}" "--plan=${_plan_file}")
    [[ -n "${_skip_csv}" ]] && _apply_args+=("--skip=${_skip_csv}")
    state_io_import_apply "${_apply_args[@]}"
    local _apply_rc=$?
    rm -f "${_plan_file}"
    [[ "${_apply_rc}" -ne 0 ]] && return 1

    if [[ "${_lifecycle_rc}" -ne 0 ]]; then
        printf "[dispatcher] import applied with partial failures\n" >&2
        return 6
    fi
    printf "[dispatcher] import applied.\n"
    return 0
}

# ── config ───────────────────────────────────────────────────────────────────

_dispatcher_config() {
    local _action="${1:-}"; shift || true
    case "${_action}" in
        set)
            if [[ "$#" -lt 2 ]]; then
                printf "[dispatcher] ERROR: config set needs <section.key> <value>\n" >&2
                return 2
            fi
            config_set "$@"
            ;;
        get)
            if [[ "$#" -lt 1 ]]; then
                printf "[dispatcher] ERROR: config get needs <section.key>\n" >&2
                return 2
            fi
            config_get "$@"
            ;;
        unset)
            if [[ "$#" -lt 1 ]]; then
                printf "[dispatcher] ERROR: config unset needs <section.key>\n" >&2
                return 2
            fi
            config_unset "$@"
            ;;
        show|"")
            config_show "$@"
            ;;
        *)
            # `config load` was removed (Q6/Q38): config-drop modules go
            # through the normal install pipeline (e.g. `install git-config`).
            printf "[dispatcher] ERROR: unknown config action '%s' (try set/get/unset/show)\n" "${_action}" >&2
            return 2
            ;;
    esac
}

# ── sync ─────────────────────────────────────────────────────────────────────

_dispatcher_sync() {
    local _target=""
    local _pull="false"
    local _apply="false"
    local -a _passthrough=()
    local _arg
    for _arg in "$@"; do
        case "${_arg}" in
            --pull) _pull="true" ;;
            --apply) _apply="true" ;;
            --modules=*|--include-config|--dry-run) _passthrough+=("${_arg}") ;;
            -*) printf "[dispatcher] ERROR: unknown sync flag %s\n" "${_arg}" >&2; return 2 ;;
            *)
                if [[ -z "${_target}" ]]; then
                    _target="${_arg}"
                else
                    printf "[dispatcher] ERROR: sync takes one <user@host>\n" >&2
                    return 2
                fi
                ;;
        esac
    done
    if [[ -z "${_target}" ]]; then
        printf "[dispatcher] ERROR: sync needs <user@host>\n" >&2
        return 2
    fi

    if [[ "${_pull}" == "true" ]]; then
        # sync_pull prints a temp file path on stdout (the downloaded
        # payload) which we feed into the local import pipeline —
        # ADR-0013: dry-run by default, --apply commits.
        local _payload
        _payload="$(sync_pull "${_target}" "${_passthrough[@]}")"
        local _rc=$?
        if [[ "${_rc}" -ne 0 ]]; then return "${_rc}"; fi
        if [[ -n "${_payload}" && -f "${_payload}" ]]; then
            local -a _import_args=("${_payload}")
            [[ "${_apply}" == "true" ]] && _import_args+=("--apply")
            _dispatcher_import "${_import_args[@]}"
            _rc=$?
            rm -f "${_payload}"
            return "${_rc}"
        fi
    else
        # Push defaults to dry-run on the remote side too (ADR-0013):
        # without --apply the remote prints its diff back over ssh.
        [[ "${_apply}" == "true" ]] && _passthrough+=("--apply")
        sync_push "${_target}" "${_passthrough[@]}"
    fi
}
