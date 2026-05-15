#!/usr/bin/env bash
# lib/runner.sh — execute module lifecycle (install / remove / purge)
#
# Per doc/architecture.md §3.1 sequence and doc/module-spec.md §4 contract.
#
# Public API:
#   runner_install <module> [<module> ...]
#   runner_remove  <module> [<module> ...]
#   runner_purge   <module> [<module> ...]
#     Source each module in an isolated sub-shell that pre-loads lib/logger.sh
#     and lib/general.sh, then call its install() / remove() / purge()
#     respectively. Iterates in the order given (caller is expected to have
#     already topo-sorted via resolver_resolve).
#
#     Honors:
#       INIT_UBUNTU_DRY_RUN     (true/false; default false)
#       INIT_UBUNTU_INSTALL_TARGET (sudo/user-home/auto)
#       INIT_UBUNTU_LOG_FILE    (JSONL output, see lib/logger.sh)
#
#     Emits JSONL events:
#       session_start / session_end (engine layer, module=null)
#       <phase>_start / <phase>_done / <phase>_failed (per module)
#
#     Return code:
#       0 — every module succeeded (or was already in desired state)
#       6 — at least one module failed (per PRD §7.4)

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    printf "Warn: %s is a library, not a executable script.\n" "${BASH_SOURCE[0]##*/}"
    return 0 2>/dev/null
fi

# ── Internal: run one phase (install/remove/purge) for one module ────────────

_runner_run_phase() {
    local _phase="${1:?_runner_run_phase needs <phase>}"   # install|remove|purge
    local _name="${2:?_runner_run_phase needs <module>}"
    local _file="${MODULES_NAME[${_name}]:-}"

    if [[ -z "${_file}" ]]; then
        printf "[runner] ERROR: unknown module %s\n" "${_name}" >&2
        log_event error "${_name}" "${_phase}_failed" "reason=not-registered"
        return 1
    fi

    log_event info "${_name}" "${_phase}_start" \
        "dry_run=${INIT_UBUNTU_DRY_RUN:-false}" \
        "install_target=${INIT_UBUNTU_INSTALL_TARGET:-auto}"
    log_info "[${_name}] Starting ${_phase}..."

    local _lib_dir="${LIB_DIR:-${REPO_ROOT:-.}/lib}"
    local _start_ts _end_ts _duration
    _start_ts="$(date +%s)"

    # Sub-shell isolation: re-source helpers, then module, then call the
    # phase function. Forwards INIT_UBUNTU_* env vars via the parent process.
    INIT_UBUNTU_CURRENT_MODULE="${_name}" \
    bash --noprofile --norc -c "
        set -euo pipefail
        # shellcheck disable=SC1090
        source '${_lib_dir}/logger.sh'
        # shellcheck disable=SC1090
        source '${_lib_dir}/general.sh'
        # shellcheck disable=SC1090
        source '${_lib_dir}/module_helper.sh'
        # The module's dual-mode header detects \$0 != \$BASH_SOURCE[0] and
        # skips its own standalone-mode source block, so we don't re-source
        # the helpers above (idempotent if it did).
        # shellcheck disable=SC1090
        source '${_file}'
        if ! declare -F '${_phase}' >/dev/null 2>&1; then
            log_error '[${_name}] module does not define ${_phase}() — aborting'
            exit 1
        fi
        ${_phase}
    "
    local _rc=$?

    _end_ts="$(date +%s)"
    _duration=$(( _end_ts - _start_ts ))

    if [[ "${_rc}" -eq 0 ]]; then
        log_event info "${_name}" "${_phase}_done" "duration_s=${_duration}"
        log_info "[${_name}] ${_phase} completed (${_duration}s)"
        # Mirror successful lifecycle to state.json (unless dry-run).
        # Manual flag: true if the user named this module explicitly via
        # the CLI; false if it landed here as a transitive dep. dispatcher
        # exports INIT_UBUNTU_REQUESTED_MODULES (space-padded for substring
        # match) before invoking the runner.
        if [[ "${INIT_UBUNTU_DRY_RUN:-false}" != "true" ]] \
            && declare -F state_record_install >/dev/null 2>&1; then
            case "${_phase}" in
                install)
                    local _manual="false"
                    if [[ " ${INIT_UBUNTU_REQUESTED_MODULES:-} " == *" ${_name} "* ]]; then
                        _manual="true"
                    fi
                    state_record_install "${_name}" "${_manual}" "${VERSION_PROVIDED:-unknown}" || \
                        log_warn "[${_name}] state_record_install failed (continuing)"
                    ;;
                remove|purge)
                    state_record_remove "${_name}" || \
                        log_warn "[${_name}] state_record_remove failed (continuing)"
                    ;;
            esac
        fi
    else
        log_event error "${_name}" "${_phase}_failed" \
            "duration_s=${_duration}" "exit_code=${_rc}"
        log_error "[${_name}] ${_phase} failed (exit=${_rc}, ${_duration}s)"
    fi

    return "${_rc}"
}

# ── Public: orchestrators for each phase ─────────────────────────────────────

_runner_run_batch() {
    local _phase="${1:?_runner_run_batch needs <phase>}"
    shift
    local -a _modules=("$@")

    if [[ "${#_modules[@]}" -eq 0 ]]; then
        log_info "[runner] No modules to ${_phase}."
        return 0
    fi

    log_event info "" "session_start" \
        "phase=${_phase}" \
        "module_count=${#_modules[@]}" \
        "dry_run=${INIT_UBUNTU_DRY_RUN:-false}"

    local _name _rc _failures=0 _ok=0
    for _name in "${_modules[@]}"; do
        if _runner_run_phase "${_phase}" "${_name}"; then
            _ok=$(( _ok + 1 ))
        else
            _rc=$?
            _failures=$(( _failures + 1 ))
            log_warn "[runner] Continuing despite failure of '${_name}' (rc=${_rc})"
        fi
    done

    log_event info "" "session_end" \
        "phase=${_phase}" \
        "ok=${_ok}" \
        "failed=${_failures}"

    if [[ "${_failures}" -gt 0 ]]; then
        log_error "[runner] ${_failures} module(s) failed during ${_phase}; ${_ok} succeeded."
        return 6
    fi
    log_info "[runner] ${_phase} batch complete: ${_ok} module(s) processed."
    return 0
}

runner_install() { _runner_run_batch install "$@"; }
runner_remove()  { _runner_run_batch remove  "$@"; }
runner_purge()   { _runner_run_batch purge   "$@"; }
