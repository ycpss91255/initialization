#!/usr/bin/env bash
# template/tool.template.sh — skeleton for a ONE-OFF bash tool under tool/
#
# ── When to use this template ────────────────────────────────────────────────
#   Use this for a genuine ONE-OFF script that lives in tool/ (e.g. a personal
#   host tweak, a machine-specific sync, a "run this once" fix). It is NOT a
#   module: it has no is_installed/install/upgrade/remove/purge lifecycle, is
#   not resolved by the engine, and carries no state.json entry.
#
#   If the thing you are building is REUSABLE (other machines / other users
#   would want it), it belongs as a real module — promote it per PRD §6.5/§6.6
#   and copy one of template/module-{apt,github-release,config,custom}.template.sh
#   instead. Do not grow a tool/ script into a pseudo-module.
#
# ── Contract this skeleton guarantees (see doc/guide/small-tool-template.md) ──
#   * Exit-code contract (mirrors the module CLI 0=ok / 2=usage-error):
#         -h | --help   -> print usage to stdout, exit 0
#         (no args)     -> perform the work
#         unknown flag  -> print usage to stderr, exit 2
#   * `set -euo pipefail` — ADR-0007 "always-act" family: a tool performs side
#     effects and any intermediate failure must abort the whole run. (Contrast
#     the exit-code-CONTRACT scripts — hooks, release-tag.sh — which default to
#     `set -uo` so a probe returning 1 does not abort. A tool is not a probe.)
#   * `--dry-run` — print what WOULD change and mutate nothing.
#   * Idempotent, grep-guarded work — safe to re-run; only acts when the
#     desired state is absent.
#   * NO host package installs. A one-off tool must never apt-get/dpkg/snap
#     install on the host (repo hard rule #2). Configure, copy, toggle — do
#     not install packages. If you need a package, that is a module.
#
# ── Authoring steps ──────────────────────────────────────────────────────────
#   1. cp template/tool.template.sh tool/<your-name>.sh   (kebab-case name)
#   2. Fill in TOOL_NAME + TOOL_SUMMARY and the usage() body.
#   3. Replace do_work() with the real, grep-guarded, dry-run-aware work.
#   4. cp test/unit/tool_template_spec.bats -> a spec for your tool and adapt
#      the 3 canonical cases (--help=0, unknown=2, --dry-run mutates nothing).
#   5. Run: just -f justfile.ci test-unit   (Docker-only; ADR-0004)

set -euo pipefail
shopt -s inherit_errexit &>/dev/null || true

# ── Identity ─────────────────────────────────────────────────────────────────
TOOL_NAME="tool-template"                                # TODO: your kebab-case tool name
TOOL_SUMMARY="one-line summary of what this tool does"   # TODO

# ── Logger ───────────────────────────────────────────────────────────────────
# Prefer the live repo logger (lib/logger.sh) for log_info/log_warn/log_error.
# It is optional: if it cannot be found (tool copied out of the repo), fall
# back to minimal stderr shims so the tool still runs. REPO_ROOT / LIB_DIR env
# overrides let a test point at the real lib without a fixed relative path.
_TOOL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
_LIB_DIR="${LIB_DIR:-${REPO_ROOT:+${REPO_ROOT}/lib}}"
_LIB_DIR="${_LIB_DIR:-${_TOOL_DIR}/../lib}"
if [[ -r "${_LIB_DIR}/logger.sh" ]]; then
    # shellcheck source=../lib/logger.sh
    source "${_LIB_DIR}/logger.sh"
fi
if ! declare -F log_info >/dev/null 2>&1; then
    log_info()  { printf '[INFO]  %s\n' "$*" >&2; }
    log_warn()  { printf '[WARN]  %s\n' "$*" >&2; }
    log_error() { printf '[ERROR] %s\n' "$*" >&2; }
fi

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${TOOL_NAME} — ${TOOL_SUMMARY}

Usage:
  ${TOOL_NAME}              run the tool (idempotent)
  ${TOOL_NAME} --dry-run    show what would change, mutate nothing
  ${TOOL_NAME} -h|--help    show this help and exit

Exit codes:
  0  success (or --help)
  2  usage error (unknown argument)

Notes:
  * Idempotent: safe to re-run; only acts when the desired state is absent.
  * Never installs host packages (that would make this a module, not a tool).
EOF
}

# ── Work ─────────────────────────────────────────────────────────────────────
# Reference example: ensure a marker line exists in a target file. This is a
# real, grep-guarded, dry-run-aware, idempotent operation you REPLACE with your
# own. TOOL_TEMPLATE_TARGET lets the bats spec redirect the write to a scratch
# file; a real tool hardcodes its own path and drops the env indirection.
TARGET_FILE="${TOOL_TEMPLATE_TARGET:-${HOME}/.config/init_ubuntu/tool-template.marker}"
MARKER_LINE="managed-by-init-ubuntu"

do_work() {
    local dry_run="$1"

    # grep-guarded idempotency: nothing to do when the desired state is present.
    if [[ -f "${TARGET_FILE}" ]] && grep -qxF "${MARKER_LINE}" "${TARGET_FILE}" 2>/dev/null; then
        log_info "${TOOL_NAME}: already applied to ${TARGET_FILE}; nothing to do"
        return 0
    fi

    if [[ "${dry_run}" == "true" ]]; then
        log_info "${TOOL_NAME}: [DRY-RUN] would add '${MARKER_LINE}' to ${TARGET_FILE}"
        return 0
    fi

    mkdir -p -- "$(dirname -- "${TARGET_FILE}")"
    printf '%s\n' "${MARKER_LINE}" >>"${TARGET_FILE}"
    log_info "${TOOL_NAME}: applied '${MARKER_LINE}' to ${TARGET_FILE}"
}

# ── Entry ────────────────────────────────────────────────────────────────────
main() {
    local dry_run="false"
    while (($#)); do
        case "$1" in
            -h | --help)
                usage
                return 0
                ;;
            -n | --dry-run)
                dry_run="true"
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

    do_work "${dry_run}"
}

main "$@"
