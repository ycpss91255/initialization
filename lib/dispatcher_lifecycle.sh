#!/usr/bin/env bash
# lib/dispatcher_lifecycle.sh — mutation / lifecycle + doctor dispatch
#
# Extracted from lib/dispatcher.sh (architecture-review E1). This cluster fans
# out to the runner (lib/runner.sh) for the phases that actually change the
# host, plus the read-mostly diagnostic (`doctor`) that mirrors state.json
# against system reality.
#
#   _dispatcher_lifecycle              install | remove | purge
#   _dispatcher_upgrade               upgrade [<module>...]
#   _dispatcher_verify                verify  [<module>...]
#   _dispatcher_doctor_validate_modules  doctor --validate-modules (PRD §9.1)
#   _dispatcher_doctor_drift          doctor state-drift report ([<module>...])
#   _dispatcher_doctor                doctor (drift + module doctor() overrides)
#
# Sourced by lib/dispatcher.sh; not an executable script.

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    printf "Warn: %s is a library, not a executable script.\n" "${BASH_SOURCE[0]##*/}"
    return 0 2>/dev/null
fi

# ── install / remove / purge ─────────────────────────────────────────────────

_dispatcher_lifecycle() {
    local _phase="${1:?_dispatcher_lifecycle needs <phase>}"  # install|remove|purge
    shift

    local -a _modules=()
    local _arg
    for _arg in "$@"; do
        case "${_arg}" in
            -y|--yes)     export INIT_UBUNTU_YES=true ;;
            --dry-run)    export INIT_UBUNTU_DRY_RUN=true ;;
            --no-deps)    export INIT_UBUNTU_NO_DEPS=true ;;
            --verbose)    export INIT_UBUNTU_VERBOSE=true ;;
            --quiet)
                # PRD §7.7.1: no progress lines; only warn/error remain.
                export INIT_UBUNTU_QUIET=true
                export LOG_LEVEL=WARN
                ;;
            --with-orphans|--base|--recommended|--all-base|--category=*|--install-target=*|--force|--profile=*)
                printf "[dispatcher] WARN: %s is stubbed; ignoring\n" "${_arg}" >&2
                ;;
            -*)
                printf "[dispatcher] ERROR: unknown flag %s\n" "${_arg}" >&2
                return 2
                ;;
            *)
                _modules+=("${_arg}")
                ;;
        esac
    done

    if [[ "${#_modules[@]}" -eq 0 ]]; then
        printf "[dispatcher] ERROR: %s requires at least one <module>\n" "${_phase}" >&2
        return 2
    fi

    local -a _order=()
    if [[ "${INIT_UBUNTU_NO_DEPS}" == "true" ]]; then
        _order=("${_modules[@]}")
    else
        # PRD §7.4: the resolver returns 2 (unknown module) / 5 (dep cycle or
        # CONFLICTS_WITH) on failure. setup_ubuntu.sh runs under
        # `set -euo pipefail; shopt -s inherit_errexit`, so a bare command
        # substitution would abort the whole script with status 1 before we
        # could read $? — masking the real 2/5 to a generic 1. The `|| _rc=$?`
        # tail both suspends errexit for the substitution AND preserves the
        # resolver's real status (unlike `if ! ...`, where the negation resets
        # $? to 0 inside the branch), so we can propagate 2/5 verbatim.
        local _resolved _rc=0
        _resolved="$(resolver_resolve "${_modules[@]}")" || _rc=$?
        if [[ "${_rc}" -ne 0 ]]; then
            return "${_rc}"
        fi
        local _line
        while IFS= read -r _line; do
            [[ -n "${_line}" ]] && _order+=("${_line}")
        done <<< "${_resolved}"
    fi

    # Plan + confirm (PRD §7.2, 2026-06-06): without -y, print the resolved
    # plan after dep resolution and ask `Proceed? [Y/n]` (install defaults
    # to yes). Non-tty stdin has nobody to answer, so the default applies.
    # --dry-run executes nothing, so it never prompts.
    if [[ "${_phase}" == "install" \
          && "${INIT_UBUNTU_DRY_RUN}" != "true" \
          && "${INIT_UBUNTU_YES}" != "true" ]]; then
        local -a _plan_deps=()
        local _n
        for _n in "${_order[@]}"; do
            [[ " ${_modules[*]} " == *" ${_n} "* ]] && continue
            _plan_deps+=("${_n}")
        done
        local _plan; _plan="$(i18n_t DISPATCHER_I18N will_install "${_modules[*]}")"
        if [[ "${#_plan_deps[@]}" -gt 0 ]]; then
            local _dep_word="deps"
            [[ "${#_plan_deps[@]}" -eq 1 ]] && _dep_word="dep"
            local _dep_csv
            printf -v _dep_csv '%s, ' "${_plan_deps[@]}"
            _plan+=" + ${#_plan_deps[@]} ${_dep_word} (${_dep_csv%, })"
        fi
        printf '%s\n' "${_plan}"
        printf '%s' "$(i18n_t DISPATCHER_I18N proceed_yn)"
        local _ans=""
        if [[ -t 0 ]]; then
            read -r _ans || _ans=""
        else
            printf '\n'
        fi
        case "${_ans}" in
            [nN]*)
                printf '%s\n' "$(i18n_t DISPATCHER_I18N aborted)"
                return 1
                ;;
        esac
    fi

    # Refuse root only when we'll actually mutate the system (PRD §10).
    # Resolved AFTER resolver so unknown-module / cycle errors still surface
    # their own exit codes (2 / 5) rather than getting masked by exit 4.
    # Dry-run + read-only paths stay root-safe so CI and bats can drive them.
    if [[ "${INIT_UBUNTU_DRY_RUN}" != "true" && "${EUID:-0}" -eq 0 ]]; then
        printf "[dispatcher] ERROR: do not run %s as root. Re-run as a regular user; sudo will be requested per-module.\n" "${_phase}" >&2
        return 4
    fi

    if [[ "${INIT_UBUNTU_DRY_RUN}" == "true" ]]; then
        printf "[dispatcher] DRY-RUN: would %s in this order:\n" "${_phase}"
        local _n
        for _n in "${_order[@]}"; do
            printf "  - %s\n" "${_n}"
        done
        return 0
    fi

    # Mark user-requested top-level modules so runner can flag them as
    # manual=true in state.json. Space-padded for substring match.
    export INIT_UBUNTU_REQUESTED_MODULES=" ${_modules[*]} "

    case "${_phase}" in
        install) runner_install "${_order[@]}" ;;
        remove)  runner_remove  "${_order[@]}" ;;
        purge)   runner_purge   "${_order[@]}" ;;
    esac
}

# ── upgrade / verify ─────────────────────────────────────────────────────────

_dispatcher_upgrade() {
    # upgrade = re-run install() for the named modules (or every installed
    # module if no names given). Real install path; refuses root same as
    # _dispatcher_lifecycle (BUT only when we'd actually call runner).
    local -a _modules=()
    local _arg
    for _arg in "$@"; do
        case "${_arg}" in
            -y|--yes) export INIT_UBUNTU_YES=true ;;
            --dry-run) export INIT_UBUNTU_DRY_RUN=true ;;
            --verbose) export INIT_UBUNTU_VERBOSE=true ;;
            --quiet)
                export INIT_UBUNTU_QUIET=true
                export LOG_LEVEL=WARN
                ;;
            -*) printf "[dispatcher] ERROR: unknown flag %s\n" "${_arg}" >&2; return 2 ;;
            *) _modules+=("${_arg}") ;;
        esac
    done

    if [[ "${#_modules[@]}" -eq 0 ]]; then
        local _line
        while IFS= read -r _line; do
            [[ -n "${_line}" ]] && _modules+=("${_line}")
        done < <(state_list_installed)
    fi

    if [[ "${#_modules[@]}" -eq 0 ]]; then
        printf "[dispatcher] nothing recorded as installed; nothing to upgrade\n"
        return 0
    fi

    log_info "[dispatcher] upgrading ${#_modules[@]} module(s): ${_modules[*]}"

    if [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]]; then
        printf "[dispatcher] DRY-RUN: would upgrade in this order:\n"
        local _n
        for _n in "${_modules[@]}"; do
            printf "  - %s\n" "${_n}"
        done
        return 0
    fi

    # Plan + confirm (PRD §7.6): upgrade keeps the conservative [y/N]
    # default (unlike install's [Y/n]). Non-tty stdin has nobody to
    # answer, so the default (no) applies and the run aborts.
    if [[ "${INIT_UBUNTU_YES}" != "true" ]]; then
        printf '%s\n' "$(i18n_t DISPATCHER_I18N will_upgrade "${#_modules[@]}" "${_modules[*]}")"
        printf '%s' "$(i18n_t DISPATCHER_I18N proceed_ny)"
        local _ans=""
        if [[ -t 0 ]]; then
            read -r _ans || _ans=""
        else
            printf '\n'
        fi
        case "${_ans}" in
            [yY]*) ;;
            *)
                printf '%s\n' "$(i18n_t DISPATCHER_I18N aborted)"
                return 1
                ;;
        esac
    fi

    # Real run: refuse root (PRD §10). Check is HERE so dry-run + empty
    # paths above stay root-safe for CI / bats.
    if [[ "${EUID:-0}" -eq 0 ]]; then
        printf "[dispatcher] ERROR: do not run upgrade as root.\n" >&2
        return 4
    fi

    runner_upgrade "${_modules[@]}"
}

_dispatcher_verify() {
    # verify = run verify() for the named modules (or every installed module
    # if no names given). Read-mostly; modules typically just confirm
    # is_installed + run TEST_VERIFY_CMD. Does not refuse root because
    # verify is safe to invoke as root (no apt mutation).
    local -a _modules=()
    local _arg
    for _arg in "$@"; do
        case "${_arg}" in
            --dry-run) export INIT_UBUNTU_DRY_RUN=true ;;
            -*) printf "[dispatcher] ERROR: unknown flag %s\n" "${_arg}" >&2; return 2 ;;
            *) _modules+=("${_arg}") ;;
        esac
    done

    if [[ "${#_modules[@]}" -eq 0 ]]; then
        local _line
        while IFS= read -r _line; do
            [[ -n "${_line}" ]] && _modules+=("${_line}")
        done < <(state_list_installed)
    fi

    if [[ "${#_modules[@]}" -eq 0 ]]; then
        printf "[dispatcher] nothing recorded as installed; nothing to verify\n"
        return 0
    fi

    log_info "[dispatcher] verifying ${#_modules[@]} module(s): ${_modules[*]}"

    if [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]]; then
        printf "[dispatcher] DRY-RUN: would verify in this order:\n"
        local _n
        for _n in "${_modules[@]}"; do
            printf "  - %s\n" "${_n}"
        done
        return 0
    fi

    runner_verify "${_modules[@]}"
}

# ── doctor ───────────────────────────────────────────────────────────────────

# doctor --validate-modules (PRD §9.1 / §7.4 / AC-24): lint every registered
# module's metadata. Each module must declare a name + category, every
# DEPENDS_ON entry must resolve through the registry, and every CONFLICTS_WITH
# entry must name a real module. Any invalid metadata / unresolvable dep is an
# argument-class error → exit 2 (NOT the drift-report 0/1 of plain doctor).
_dispatcher_doctor_validate_modules() {
    if ! declare -F registry_list_names >/dev/null 2>&1; then
        printf "[dispatcher] ERROR: registry not loaded\n" >&2
        return 1
    fi

    printf "%-30s  %s\n" "MODULE" "METADATA"
    local _names; _names="$(registry_list_names)"
    local _invalid=0
    local _n _cat _deps _conflicts _c
    local -a _conflict_arr
    if [[ -n "${_names}" ]]; then
        while IFS= read -r _n; do
            [[ -n "${_n}" ]] || continue
            _cat="$(registry_get_field "${_n}" category)"
            _deps="$(registry_get_field "${_n}" deps)"
            _conflicts="$(registry_get_field "${_n}" conflicts)"

            if [[ -z "${_cat}" ]]; then
                printf "%-30s  %s\n" "${_n}" "INVALID (missing category)"
                _invalid=$((_invalid + 1))
                continue
            fi

            # DEPENDS_ON must resolve (resolver returns 2 unknown / 5 cycle).
            if ! resolver_resolve "${_n}" >/dev/null 2>&1; then
                printf "%-30s  %s\n" "${_n}" "INVALID (unresolvable DEPENDS_ON / dep conflict)"
                _invalid=$((_invalid + 1))
                continue
            fi

            # CONFLICTS_WITH must name real modules.
            local _bad_conflict=""
            if [[ -n "${_conflicts}" ]]; then
                read -r -a _conflict_arr <<< "${_conflicts}"
                for _c in "${_conflict_arr[@]}"; do
                    [[ -z "${_c}" ]] && continue
                    if ! registry_has "${_c}"; then
                        _bad_conflict="${_c}"
                        break
                    fi
                done
            fi
            if [[ -n "${_bad_conflict}" ]]; then
                printf "%-30s  %s\n" "${_n}" "INVALID (CONFLICTS_WITH unknown module ${_bad_conflict})"
                _invalid=$((_invalid + 1))
                continue
            fi

            printf "%-30s  %s\n" "${_n}" "OK"
        done <<< "${_names}"
    fi

    if [[ "${_invalid}" -gt 0 ]]; then
        printf "\n[dispatcher] doctor --validate-modules: %s module(s) have invalid metadata\n" "${_invalid}" >&2
        return 2
    fi
    printf "\n[dispatcher] doctor --validate-modules: all module metadata is valid.\n"
}

# _dispatcher_doctor_drift [<module>...]: the state.json-vs-reality report.
# Iterates every module state records as installed, sources each in a fresh
# subshell to run is_installed, and prints a STATE-RECORD vs SYSTEM-ACTUAL
# table. An optional positional filter restricts the table to the named modules
# (intersected with what state records installed) — `doctor <module>` uses it.
# Returns 1 when any drift item is found, 0 when state and host agree.
_dispatcher_doctor_drift() {
    local _filter_str=""
    [[ "$#" -gt 0 ]] && _filter_str=" $* "

    printf "%-30s  %-15s  %-15s  %s\n" "MODULE" "STATE-RECORD" "SYSTEM-ACTUAL" "STATUS"
    local _names; _names="$(state_list_installed)"
    local _issues=0
    local _n _file _actual _status
    if [[ -n "${_names}" ]]; then
        while IFS= read -r _n; do
            [[ -n "${_n}" ]] || continue
            # Scope to the named modules when a filter was supplied.
            [[ -n "${_filter_str}" && "${_filter_str}" != *" ${_n} "* ]] && continue
            _file="$(registry_get_field "${_n}" file)"
            if [[ -z "${_file}" ]]; then
                _actual="not-registered"
                _status="STALE (no module file)"
                _issues=$((_issues + 1))
            elif (
                # shellcheck source=/dev/null  # module path is dynamic; static resolution impossible — https://www.shellcheck.net/wiki/SC1090
                bash --noprofile --norc -c "
                    source '${LIB_DIR}/logger.sh' >/dev/null 2>&1
                    source '${LIB_DIR}/general.sh' >/dev/null 2>&1
                    source '${LIB_DIR}/module_helper.sh' >/dev/null 2>&1
                    source '${_file}'
                    is_installed
                " >/dev/null 2>&1
            ); then
                _actual="installed"
                _status="OK"
            else
                _actual="missing"
                _status="DRIFTED (state says yes, host says no)"
                _issues=$((_issues + 1))
            fi
            printf "%-30s  %-15s  %-15s  %s\n" "${_n}" "installed" "${_actual}" "${_status}"
        done <<< "${_names}"
    fi

    if [[ "${_issues}" -gt 0 ]]; then
        printf "\n[dispatcher] doctor found %s drift / inconsistency item(s)\n" "${_issues}" >&2
        printf "[dispatcher] use 'doctor --fix' (planned for 0.3.0) to auto-resolve\n" >&2
        # Diag class (PRD §7.4): 0 = pass, 1 = fail (7 reserved for network).
        return 1
    fi
    printf "\n[dispatcher] doctor: state.json and system are consistent.\n"
    return 0
}

_dispatcher_doctor() {
    # PRD §9.1 / AC-24: `--validate-modules` runs the metadata linter instead
    # of the state-drift report. Parse argv so the flag is honored; an unknown
    # flag is an argument error (exit 2). Positional args name specific modules
    # to diagnose (else every installed module).
    local -a _requested=()
    local _arg
    for _arg in "$@"; do
        case "${_arg}" in
            --validate-modules)
                _dispatcher_doctor_validate_modules
                return $?
                ;;
            --fix)
                printf "[dispatcher] WARN: %s is stubbed; ignoring\n" "${_arg}" >&2
                ;;
            -*)
                printf "[dispatcher] ERROR: unknown doctor flag %s\n" "${_arg}" >&2
                return 2
                ;;
            *)
                _requested+=("${_arg}")
                ;;
        esac
    done

    if ! declare -F state_list_installed >/dev/null 2>&1; then
        printf "[dispatcher] ERROR: state lib not loaded\n" >&2
        return 1
    fi

    # Named modules must resolve through the registry (argument-class error).
    local _m
    for _m in ${_requested[@]+"${_requested[@]}"}; do
        if declare -F registry_has >/dev/null 2>&1 && ! registry_has "${_m}"; then
            printf "[dispatcher] ERROR: unknown module '%s'\n" "${_m}" >&2
            return 2
        fi
    done

    # Target set: the named modules, else every module recorded installed.
    local -a _targets=()
    if [[ "${#_requested[@]}" -gt 0 ]]; then
        _targets=("${_requested[@]}")
    else
        local _line
        while IFS= read -r _line; do
            [[ -n "${_line}" ]] && _targets+=("${_line}")
        done < <(state_list_installed)
    fi

    # Part 1 (PRESERVED): the state-drift report, scoped to the target set.
    local _drift_rc=0
    _dispatcher_doctor_drift ${_targets[@]+"${_targets[@]}"} || _drift_rc=$?

    # Part 2 (F1 / ADR-0002 / ADR-0009): AUGMENT the drift report by invoking
    # each target module's doctor() override through the runner. This is the
    # wiring the templates promise — without it the overrides were dead code.
    local _doctor_rc=0
    if declare -F runner_doctor >/dev/null 2>&1; then
        runner_doctor ${_targets[@]+"${_targets[@]}"} || _doctor_rc=$?
    fi

    # Diag class (PRD §7.4): 0 = pass, 1 = fail. Fail if EITHER half flags.
    if [[ "${_drift_rc}" -ne 0 || "${_doctor_rc}" -ne 0 ]]; then
        return 1
    fi
    return 0
}
