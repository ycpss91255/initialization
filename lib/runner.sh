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
#     Emits JSONL events (OTel-aligned schema, ADR-0006 / PRD §10.2):
#       session_start / session_end (engine layer, service.name="engine";
#         session_start carries an env snapshot, session_end carries
#         exit_code + ok/skipped/failed stats)
#       <phase>_start / <phase>_done / <phase>_failed (per module)
#     Each (phase, module) pair gets a span_id (`<phase>_<module>_NNN`,
#     per-trace monotonic counter) exported as INIT_UBUNTU_SPAN_ID so
#     log_event calls inside the module sub-shell inherit it.
#
#     Return code:
#       0 — every module succeeded (or was already in desired state)
#       6 — at least one module failed (per PRD §7.4)

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    printf "Warn: %s is a library, not a executable script.\n" "${BASH_SOURCE[0]##*/}"
    return 0 2>/dev/null
fi

# ── Internal: env snapshot helpers for session_start (PRD §10.2) ────────────

_runner_snapshot_os() {
    [[ -r /etc/os-release ]] || return 0
    (
        # shellcheck source=/dev/null  # /etc/os-release path is host-dependent
        . /etc/os-release
        [[ -n "${ID:-}" ]] && printf '%s%s' "${ID}" "${VERSION_ID:+-${VERSION_ID}}"
    )
}

_runner_snapshot_gpu() {
    # detect.sh may not be loaded (e.g. minimal bats engine); degrade to null.
    declare -F detect_get_field >/dev/null 2>&1 || return 0
    detect_get_field gpu.vendor 2>/dev/null || true
}

# ── Internal: run one phase (install/remove/purge) for one module ────────────

# Per-trace monotonic counter backing span_id (`<phase>_<module>_NNN`).
_RUNNER_SPAN_SEQ=0

_runner_run_phase() {
    local _phase="${1:?_runner_run_phase needs <phase>}"   # install|remove|purge
    local _name="${2:?_runner_run_phase needs <module>}"
    local _file="${MODULES_NAME[${_name}]:-}"

    # span_id covers the whole (phase, module) lifecycle operation —
    # exported so log_event calls inside the module sub-shell inherit it.
    _RUNNER_SPAN_SEQ=$(( ${_RUNNER_SPAN_SEQ:-0} + 1 ))
    printf -v INIT_UBUNTU_SPAN_ID '%s_%s_%03d' \
        "${_phase}" "${_name}" "${_RUNNER_SPAN_SEQ}"
    export INIT_UBUNTU_SPAN_ID

    if [[ -z "${_file}" ]]; then
        printf "[runner] ERROR: unknown module %s\n" "${_name}" >&2
        log_event error "${_name}" "${_phase}_failed" "reason=not-registered"
        unset INIT_UBUNTU_SPAN_ID
        return 1
    fi

    log_event info "${_name}" "${_phase}_start" \
        "dry_run=${INIT_UBUNTU_DRY_RUN:-false}" \
        "install_target=${INIT_UBUNTU_INSTALL_TARGET:-auto}"
    log_info "[${_name}] Starting ${_phase}..."

    local _lib_dir="${LIB_DIR:-${REPO_ROOT:-.}/lib}"
    local _start_ts _end_ts _duration
    _start_ts="$(date +%s)"

    # Sub-shell isolation via `(...)` fork (not `bash -c`). Module side-effects
    # (declare, set, cd, alias, export, traps) stay scoped to the subshell.
    # `(...)` is chosen over `bash -c "..."` because the latter launches a
    # fresh bash process where $BASH_SOURCE / $FUNCNAME start unbound — under
    # `set -u`, kcov-instrumented bash trips on its own coverage hooks
    # (ptrace reads BASH_SOURCE on every command for line attribution). The
    # fork-style subshell inherits these arrays from the parent shell,
    # keeping `set -u` safe and coverage instrumentation happy.
    #
    # Parent shell is expected to have logger.sh / general.sh / module_helper.sh
    # already sourced (setup_ubuntu.sh or bats `_load_engine` do this).
    (
        export INIT_UBUNTU_CURRENT_MODULE="${_name}"
        set -euo pipefail
        # shellcheck source=/dev/null  # module path is dynamic; static resolution impossible — https://www.shellcheck.net/wiki/SC1090
        source "${_file}"
        if ! declare -F "${_phase}" >/dev/null 2>&1; then
            log_error "[${_name}] module does not define ${_phase}() — aborting"
            exit 1
        fi
        "${_phase}"
    )
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
                upgrade)
                    if declare -F state_record_upgrade >/dev/null 2>&1; then
                        state_record_upgrade "${_name}" "${VERSION_PROVIDED:-unknown}" || \
                            log_warn "[${_name}] state_record_upgrade failed (continuing)"
                    fi
                    ;;
                verify)
                    if declare -F state_record_verify >/dev/null 2>&1; then
                        state_record_verify "${_name}" || \
                            log_warn "[${_name}] state_record_verify failed (continuing)"
                    fi
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

    unset INIT_UBUNTU_SPAN_ID
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

    # session_start carries an env-detection snapshot (PRD §10.2).
    log_event info "" "session_start" \
        "phase=${_phase}" \
        "module_count=${#_modules[@]}" \
        "dry_run=${INIT_UBUNTU_DRY_RUN:-false}" \
        "form_factor=${INIT_UBUNTU_FORM_FACTOR:-}" \
        "os=$(_runner_snapshot_os)" \
        "arch=$(uname -m)" \
        "gpu=$(_runner_snapshot_gpu)"

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

    # session_end carries the batch exit code + ok/skipped/failed stats
    # (PRD §10.2). The runner has no skip path yet, so skipped is always 0
    # until a skip-producing feature (e.g. compat filtering) lands.
    local _exit_code=0
    [[ "${_failures}" -gt 0 ]] && _exit_code=6
    log_event info "" "session_end" \
        "phase=${_phase}" \
        "exit_code=${_exit_code}" \
        "ok=${_ok}" \
        "skipped=0" \
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
runner_upgrade() { _runner_run_batch upgrade "$@"; }
runner_verify()  { _runner_run_batch verify  "$@"; }
runner_doctor()  { _runner_run_batch doctor  "$@"; }
