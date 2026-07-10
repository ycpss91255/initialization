#!/usr/bin/env bash
# lib/tool_bootstrap.sh — shared bootstrap for one-off tools (tool/<name>.sh).
#
# One-off tools used to each re-implement the same header: strict mode, locate
# the repo lib dir, source (or shim) the logger, parse --help/--dry-run/unknown,
# and hand-roll a grep-guarded idempotent edit. That boilerplate is centralized
# here so a tool collapses to: source this bootstrap, define usage() + do_work(),
# call tool_main "$@".
#
# Family (ADR-0007): tools are ALWAYS-ACT scripts — they perform side effects
# and any intermediate failure must abort the whole run. So tool_bootstrap flips
# on `set -euo pipefail` + `shopt -s inherit_errexit`. (Contrast the exit-code-
# CONTRACT scripts — hooks, release-tag.sh — which use `set -uo` so a probe that
# returns 1 does not abort; that family is served by lib/hook_bootstrap.sh.)
#
# Public API (all prefixed `tool_`):
#   tool_bootstrap                 strict mode + LIB_DIR/REPO_ROOT + logger
#   tool_main "$@"                 standard CLI: --help/-h, --dry-run/-n, unknown
#   tool_is_dry_run                predicate: is --dry-run in effect?
#   tool_ensure_line <file> <line> idempotent, grep-guarded, dry-run-aware edit
#   tool_run <command-string>      dry-run-aware, host-install-guarded executor
#
# Required by tool_main (the tool file defines these two):
#   usage()      print the tool's own help to stdout
#   do_work()    the real, idempotent, dry-run-aware work
#
# Self-location: this file lives in lib/, so it derives LIB_DIR from its OWN
# ${BASH_SOURCE[0]} (env LIB_DIR/REPO_ROOT take precedence so tests can point at
# a relocated lib). No side effects at source time — call tool_bootstrap.

# Standard library guard: refuse to run as an executable script.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    printf "Warn: %s is a library, not an executable script.\n" "${BASH_SOURCE[0]##*/}"
    printf "Source it from a tool, e.g.: source \"%s\"\n" "${BASH_SOURCE[0]:-}"
    return 0 2>/dev/null
fi

# Dry-run flag (tool_main sets it from --dry-run/-n; env override for tests).
TOOL_DRY_RUN="${TOOL_DRY_RUN:-false}"

# Fallback logger shims — installed only when no logger is loaded yet (a tool
# copied out of the repo, where lib/logger.sh cannot be found). tool_bootstrap
# sources the real lib/logger.sh when available, which overrides these. Defined
# at top level (not inside a function) so they read as the library's own API.
if ! declare -F log_info >/dev/null 2>&1; then
    log_info()  { printf '[INFO]  %s\n' "$*" >&2; }
    log_warn()  { printf '[WARN]  %s\n' "$*" >&2; }
    log_error() { printf '[ERROR] %s\n' "$*" >&2; }
    log_fatal() { printf '[FATAL] %s\n' "$*" >&2; exit 1; }
fi

# tool_bootstrap — always-act strict mode, path resolution, logger.
#   1. set -euo pipefail; shopt -s inherit_errexit.
#   2. Resolve + export LIB_DIR (self-located) and REPO_ROOT (env override wins).
#   3. Source lib/logger.sh for log_info/log_warn/log_error/log_fatal; when the
#      logger cannot be found (tool copied out of the repo), the top-level
#      fallback shims defined above keep those names working.
tool_bootstrap() {
    set -euo pipefail
    shopt -s inherit_errexit 2>/dev/null || true

    local _self_lib
    _self_lib="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-}")" && pwd -P)"
    LIB_DIR="${LIB_DIR:-${_self_lib}}"
    REPO_ROOT="${REPO_ROOT:-$(cd -- "${LIB_DIR}/.." && pwd -P)}"
    export LIB_DIR REPO_ROOT

    # The real repo logger overrides the top-level fallback shims when present.
    if [[ -r "${LIB_DIR}/logger.sh" ]]; then
        # shellcheck source=logger.sh
        source "${LIB_DIR}/logger.sh"
    fi
}

# tool_is_dry_run — 0 when --dry-run/-n was passed (or TOOL_DRY_RUN=true).
tool_is_dry_run() {
    [[ "${TOOL_DRY_RUN:-false}" == "true" ]]
}

# tool_main "$@" — the standard one-off-tool CLI, mirroring the module CLI's
# 0=ok / 2=usage-error contract:
#   -h | --help    -> usage (stdout); return 0
#   -n | --dry-run -> set the dry-run flag
#   --             -> end option parsing; remaining args pass to do_work
#   anything else  -> usage (stderr); return 2
# then invokes the tool-provided do_work with any post-`--` arguments.
tool_main() {
    while (($#)); do
        case "$1" in
            -h | --help)
                usage
                return 0
                ;;
            -n | --dry-run)
                TOOL_DRY_RUN="true"
                shift
                ;;
            --)
                shift
                break
                ;;
            *)
                usage >&2
                return 2
                ;;
        esac
    done

    do_work "$@"
}

# tool_ensure_line <file> <line> — idempotently ensure <line> is present in
# <file> exactly once. grep-guarded (no-op when already present), dry-run-aware
# (logs intent, writes nothing under --dry-run), and creates the parent dir +
# file when absent. Safe to re-run.
tool_ensure_line() {
    local _file="${1:?tool_ensure_line needs <file>}"
    local _line="${2:?tool_ensure_line needs <line>}"

    if [[ -f "${_file}" ]] && grep -qxF -- "${_line}" "${_file}" 2>/dev/null; then
        log_info "tool_ensure_line: '${_line}' already present in ${_file}; nothing to do"
        return 0
    fi

    if tool_is_dry_run; then
        log_info "tool_ensure_line: [DRY-RUN] would add '${_line}' to ${_file}"
        return 0
    fi

    mkdir -p -- "$(dirname -- "${_file}")"
    printf '%s\n' "${_line}" >>"${_file}"
    log_info "tool_ensure_line: added '${_line}' to ${_file}"
}

# tool_run <command-string> — dry-run-aware, guarded command executor.
#   * Refuses host package-manager mutations (apt / apt-get / dpkg / snap
#     install|remove|purge|upgrade|reinstall): that is a MODULE, not a tool
#     (repo hard rule #2). Returns 1 so `set -e` aborts the run.
#   * Under --dry-run, prints the command it WOULD run and returns 0.
#   * Otherwise evaluates the command string.
tool_run() {
    local _cmd="${1:?tool_run needs <command-string>}"

    if [[ "${_cmd}" =~ (^|[[:space:]\;\|\&])(sudo[[:space:]]+)?(apt|apt-get|dpkg|snap)[[:space:]]+(install|remove|purge|upgrade|reinstall) ]]; then
        log_error "tool_run: refusing host package install/removal: ${_cmd}"
        log_error "tool_run: a one-off tool must not install host packages — write a module instead (hard rule #2)."
        return 1
    fi

    if tool_is_dry_run; then
        log_info "tool_run: [DRY-RUN] would run: ${_cmd}"
        return 0
    fi

    log_info "tool_run: ${_cmd}"
    eval "${_cmd}"
}
