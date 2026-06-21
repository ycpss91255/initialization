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

# i18n_t (issue #185) lives in lib/i18n.sh. The entrypoint sources it before
# dispatching, but make this lib self-sufficient (unit specs source runner.sh
# directly) by loading it on demand when the helper is not yet defined.
if ! declare -F i18n_t >/dev/null 2>&1; then
    # shellcheck source=lib/i18n.sh
    source "${BASH_SOURCE[0]%/*}/i18n.sh"
fi

# ── i18n: user-facing strings (issue #185 Phase 2) ──────────────────────────
# Human-readable progress / summary / failure-dump strings rendered via
# i18n_t (lib/i18n.sh). log_* output stays English; only stdout/stderr lines
# a human reads are localized here. en values are byte-identical to the
# pre-i18n literals. zh-TW uses full-width punctuation.
# kcov-exclude-start (i18n data table; excluded from coverage — kcov counts each entry line as uncoverable, issue #185)
declare -gA RUNNER_I18N=(
    # Phase verb forms (gerund / past) used inside progress lines.
    ["en.gerund.install"]="installing"
    ["zh-TW.gerund.install"]="安裝中"
    ["en.gerund.remove"]="removing"
    ["zh-TW.gerund.remove"]="移除中"
    ["en.gerund.purge"]="purging"
    ["zh-TW.gerund.purge"]="清除中"
    ["en.gerund.upgrade"]="upgrading"
    ["zh-TW.gerund.upgrade"]="升級中"
    ["en.gerund.verify"]="verifying"
    ["zh-TW.gerund.verify"]="驗證中"
    ["en.past.install"]="installed"
    ["zh-TW.past.install"]="已安裝"
    ["en.past.remove"]="removed"
    ["zh-TW.past.remove"]="已移除"
    ["en.past.purge"]="purged"
    ["zh-TW.past.purge"]="已清除"
    ["en.past.upgrade"]="upgraded"
    ["zh-TW.past.upgrade"]="已升級"
    ["en.past.verify"]="verified"
    ["zh-TW.past.verify"]="已驗證"
    # Progress lines (per-module start / per-module success).
    # {0}=index {1}=total {2}=module {3}=gerund
    ["en.progress_start"]="[{0}/{1}] {2}: {3}..."
    ["zh-TW.progress_start"]="[{0}/{1}] {2}：{3}…"
    # {0}=module {1}=past-verb {2}=duration-seconds
    ["en.progress_done"]="  ✔ {0} {1} ({2}s)"
    ["zh-TW.progress_done"]="  ✔ {0} {1}（{2} 秒）"
    # Failure dump: human header above the captured tail. {0}=module
    ["en.fail_tail_header"]="  ── last ~20 lines of {0} output ──"
    ["zh-TW.fail_tail_header"]="  ── {0} 輸出的最後約 20 行 ──"
    # Session-end "Action required" block header.
    ["en.action_required_header"]="── Action required ─────────────────────"
    ["zh-TW.action_required_header"]="── 需要採取的動作 ─────────────────────"
)
# kcov-exclude-end
# RUNNER_I18N is consumed by i18n_t via a nameref on the table NAME passed as a
# bareword argument — static analysis cannot follow that indirection, so make
# the read explicit here to keep shellcheck honest (no disable directive).
: "${RUNNER_I18N[@]+x}"

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
    # environment.sh may not be loaded (e.g. minimal bats engine); degrade
    # to null rather than erroring out.
    declare -F environment_field >/dev/null 2>&1 || return 0
    environment_field gpu.vendor 2>/dev/null || true
}

# ── Internal: progress rendering helpers (PRD §7.7.1) ───────────────────────

# Localized verb forms for the human-readable progress lines (issue #185).
# Known phases resolve via RUNNER_I18N; unknown phases keep the programmatic
# English fallback (no table entry to localize).
_runner_phase_gerund() {
    case "${1}" in
        install|remove|purge|upgrade|verify)
            i18n_t RUNNER_I18N "gerund.${1}" ;;
        *)  printf '%sing' "${1}" ;;
    esac
}

_runner_phase_past() {
    case "${1}" in
        install|remove|purge|upgrade|verify)
            i18n_t RUNNER_I18N "past.${1}" ;;
        *)  printf '%sed' "${1}" ;;
    esac
}

# Progress lines print unless --quiet (PRD §7.7.1: quiet keeps warn/error only).
_runner_progress() {
    [[ "${INIT_UBUNTU_QUIET:-false}" == "true" ]] && return 0
    printf '%s\n' "$*"
}

# ── Internal: run one phase (install/remove/purge) for one module ────────────

# Per-trace monotonic counter backing span_id (`<phase>_<module>_NNN`).
_RUNNER_SPAN_SEQ=0

# Modules whose phase succeeded earlier in the CURRENT batch — backs the
# ADR-0010 depends_on snapshot ("deps actually installed this session").
# Reset by _runner_run_batch; filled by its loop after each success.
declare -gA _RUNNER_SESSION_OK=()

# _runner_dep_snapshot <module>
#   Print <module>'s forward-dep snapshot as csv (ADR-0010, issue #93):
#   the resolver's transitive dep closure minus the module itself, kept
#   only where the dep actually completed install earlier in this session
#   (topo order guarantees deps run before their dependents). --no-deps
#   prints nothing — the snapshot reflects reality, not metadata intent.
#   Degrades to empty when the resolver is not loaded (minimal engines).
_runner_dep_snapshot() {
    local _name="${1:?_runner_dep_snapshot needs <module>}"
    [[ "${INIT_UBUNTU_NO_DEPS:-false}" == "true" ]] && return 0
    declare -F resolver_collect_transitive >/dev/null 2>&1 || return 0

    local _dep _csv=""
    while IFS= read -r _dep; do
        [[ -z "${_dep}" || "${_dep}" == "${_name}" ]] && continue
        [[ -n "${_RUNNER_SESSION_OK[${_dep}]:-}" ]] || continue
        _csv+="${_dep},"
    done < <(resolver_collect_transitive "${_name}" | sort)
    printf '%s' "${_csv%,}"
}

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

    # Per-module child-output buffer (PRD §7.7.1): exec_cmd appends captured
    # child stdout/stderr here so the failure path can dump the last ~20
    # lines. Capture mode is enabled for the module sub-shell only.
    local _cmd_log
    _cmd_log="$(mktemp)"

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
        export INIT_UBUNTU_CMD_CAPTURE=true
        export INIT_UBUNTU_CMD_OUTPUT_FILE="${_cmd_log}"
        set -euo pipefail
        # shellcheck source=/dev/null  # module path is dynamic; static resolution impossible — https://www.shellcheck.net/wiki/SC1090
        source "${_file}"
        if ! declare -F "${_phase}" >/dev/null 2>&1; then
            log_error "[${_name}] module does not define ${_phase}() — aborting"
            exit 1
        fi
        # Capture the phase's exit code explicitly: the whole call tree sits
        # under `if _runner_run_phase` in _runner_run_batch, so `set -e` is
        # suspended here (POSIX: -e is ignored in tested contexts) and the
        # emit block below must not overwrite the subshell's exit status.
        _phase_rc=0
        "${_phase}" || _phase_rc=$?
        # Sidecar at the phase-invocation layer (refines ADR-0001: WHERE the
        # write happens). After a successful Action-class phase, the wrapper —
        # not the module's install()/remove() — records/removes the Sidecar via
        # module_provided_version. Runs inside the module sub-shell so the
        # module's archetype defaults / overrides are in scope. Co-located with
        # the action_required emit below; no-op on dry-run + read-only phases.
        if [[ "${_phase_rc}" -eq 0 ]] \
            && declare -F _module_sidecar_after_phase >/dev/null 2>&1; then
            _module_sidecar_after_phase "${_phase}" "${_name}"
        fi
        # After a successful install, emit action_required events (PRD
        # §7.7.2 / module-spec §4.10) while the module arrays are in scope.
        # The session-end "Action required" block is derived from these.
        if [[ "${_phase_rc}" -eq 0 && "${_phase}" == "install" ]]; then
            if declare -F module_emit_post_install >/dev/null 2>&1; then
                module_emit_post_install
            fi
            if declare -F module_emit_reboot_required >/dev/null 2>&1; then
                module_emit_reboot_required
            fi
        fi
        exit "${_phase_rc}"
    )
    local _rc=$?

    _end_ts="$(date +%s)"
    _duration=$(( _end_ts - _start_ts ))

    if [[ "${_rc}" -eq 0 ]]; then
        log_event info "${_name}" "${_phase}_done" "duration_s=${_duration}"
        _runner_progress "$(i18n_t RUNNER_I18N progress_done \
            "${_name}" "$(_runner_phase_past "${_phase}")" "${_duration}")"
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
                    # depends_on snapshot (ADR-0010, #93): resolved deps that
                    # actually installed this session; [] under --no-deps.
                    state_record_install "${_name}" "${_manual}" \
                        "${VERSION_PROVIDED:-unknown}" \
                        "$(_runner_dep_snapshot "${_name}")" || \
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
        # Failure dump (PRD §7.7.1): last ~20 lines of the module's captured
        # child output + trace_id + log path. Error-class output — printed
        # to stderr and NOT silenced by --quiet.
        if [[ -s "${_cmd_log}" ]]; then
            printf '%s\n' "$(i18n_t RUNNER_I18N fail_tail_header "${_name}")" >&2
            tail -n 20 "${_cmd_log}" >&2
        fi
        printf '  trace_id=%s\n' "${INIT_UBUNTU_TRACE_ID:-unknown}" >&2
        if [[ -n "${INIT_UBUNTU_LOG_FILE:-}" ]]; then
            printf '  log: %s\n' "${INIT_UBUNTU_LOG_FILE}" >&2
        fi
    fi

    rm -f "${_cmd_log}"
    unset INIT_UBUNTU_SPAN_ID
    return "${_rc}"
}

# ── Session-end "Action required" aggregation (PRD §7.7.2, AC-35) ───────────
#
# Derives the human-readable block from this session's `action_required`
# JSONL events (filtered by trace_id). The events are the single source of
# truth: `jq 'select(.body=="action_required")'` over the session log yields
# exactly the same module + message content. Pure bash parsing (no jq
# dependency on the host); the line format is our own log_event writer's.
_runner_render_action_required() {
    [[ -n "${INIT_UBUNTU_LOG_FILE:-}" && -f "${INIT_UBUNTU_LOG_FILE}" ]] || return 0

    local _trace="${INIT_UBUNTU_TRACE_ID:-}"
    local _re_svc='"service\.name":"([^"]*)"'
    local _re_kind='"kind":"([^"]*)"'
    local _re_msg='"message":"([^"]*)"'
    local _line _svc _kind _msg _header_done="false"

    while IFS= read -r _line; do
        [[ "${_line}" == *'"body":"action_required"'* ]] || continue
        if [[ -n "${_trace}" && "${_line}" != *"\"trace_id\":\"${_trace}\""* ]]; then
            continue
        fi
        _svc=""; _kind=""; _msg=""
        [[ "${_line}" =~ ${_re_svc} ]]  && _svc="${BASH_REMATCH[1]}"
        [[ "${_line}" =~ ${_re_kind} ]] && _kind="${BASH_REMATCH[1]}"
        [[ "${_line}" =~ ${_re_msg} ]]  && _msg="${BASH_REMATCH[1]}"
        if [[ "${_header_done}" == "false" ]]; then
            printf '\n%s\n' "$(i18n_t RUNNER_I18N action_required_header)"
            _header_done="true"
        fi
        case "${_kind}" in
            reboot) printf '⚠ %s\n' "${_msg}" ;;
            *)      printf '%s:  %s\n' "${_svc}" "${_msg}" ;;
        esac
    done < "${INIT_UBUNTU_LOG_FILE}"
    return 0
}

# ── Public: orchestrators for each phase ─────────────────────────────────────

# Map a phase to its PRD §7.4 lifecycle-class failure code:
#   Action class (install/upgrade/remove/purge) → 6 (partial module failure)
#   Diag   class (verify/doctor)               → 1 (general fail; §7.4 reserves
#                                                    7 for the network subcase)
# A wrong mapping leaks the Action-class code 6 out of the Diag subcommands.
_runner_fail_code() {
    case "${1}" in
        verify|doctor) printf '1' ;;
        *)             printf '6' ;;
    esac
}

_runner_run_batch() {
    local _phase="${1:?_runner_run_batch needs <phase>}"
    shift
    local -a _modules=("$@")
    local _fail_code
    _fail_code="$(_runner_fail_code "${_phase}")"

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

    # Fresh per-session success set (ADR-0010 depends_on snapshot, #93).
    _RUNNER_SESSION_OK=()

    local _name _rc _failures=0 _ok=0
    local _idx=0 _total="${#_modules[@]}"
    for _name in "${_modules[@]}"; do
        _idx=$(( _idx + 1 ))
        _runner_progress "$(i18n_t RUNNER_I18N progress_start \
            "${_idx}" "${_total}" "${_name}" "$(_runner_phase_gerund "${_phase}")")"
        if _runner_run_phase "${_phase}" "${_name}"; then
            _ok=$(( _ok + 1 ))
            _RUNNER_SESSION_OK["${_name}"]=1
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
    [[ "${_failures}" -gt 0 ]] && _exit_code="${_fail_code}"
    log_event info "" "session_end" \
        "phase=${_phase}" \
        "exit_code=${_exit_code}" \
        "ok=${_ok}" \
        "skipped=0" \
        "failed=${_failures}"

    # End-of-session "Action required" block (PRD §7.7.2, AC-35). Derived
    # from this session's events; action-class output, so it is NOT
    # silenced by --quiet.
    _runner_render_action_required

    # Session-end log retention (PRD §10.2, AC-33): prune the JSONL log dir
    # after session_end so the active file (newest mtime) is never a victim.
    logger_prune_logs

    if [[ "${_failures}" -gt 0 ]]; then
        log_error "[runner] ${_failures} module(s) failed during ${_phase}; ${_ok} succeeded."
        return "${_fail_code}"
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
