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
# ── What the shared bootstrap gives you (lib/tool_bootstrap.sh) ───────────────
#   Sourcing lib/tool_bootstrap.sh + calling tool_bootstrap establishes, with
#   near-zero boilerplate:
#     * `set -euo pipefail` + `shopt -s inherit_errexit` — the ADR-0007
#       *always-act* family (a tool performs side effects; any intermediate
#       failure must abort). Contrast the exit-code-CONTRACT scripts (hooks,
#       release-tag.sh) on `set -uo`. A tool is not a probe.
#     * LIB_DIR / REPO_ROOT resolution + the repo logger (log_info/warn/error).
#     * tool_main "$@"  — the -h|--help (usage; exit 0) / --dry-run|-n /
#       unknown-arg (usage >&2; exit 2) CLI, mirroring the module CLI's
#       0=ok / 2=usage-error contract.
#     * tool_ensure_line — grep-guarded, dry-run-aware, idempotent line-ensure.
#     * tool_run — a dry-run-aware executor that REFUSES host package installs
#       (repo hard rule #2: needing a package means writing a module, not a tool).
#
# ── Authoring steps ──────────────────────────────────────────────────────────
#   1. cp template/tool.template.sh tool/<your-name>.sh   (kebab-case name)
#   2. Fill in TOOL_NAME + TOOL_SUMMARY and the usage() body.
#   3. Replace do_work() with the real, grep-guarded, dry-run-aware work
#      (use tool_ensure_line / tool_run; read tool_is_dry_run when you branch).
#   4. cp template/test-tool.template.bats test/unit/tool/<name>_spec.bats and
#      adapt the 3 canonical cases (--help=0, unknown=2, --dry-run mutates
#      nothing).
#   5. Run: just -f justfile.ci test-unit   (Docker-only; ADR-0004)

# Locate + load the shared tool bootstrap. LIB_DIR / REPO_ROOT env overrides let
# a test point at the real lib; the fallback walks up from this script's own dir
# (tool/ -> ../lib).
# shellcheck source=../lib/tool_bootstrap.sh
source "${LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd -P)}/tool_bootstrap.sh"
tool_bootstrap

# ── Identity ─────────────────────────────────────────────────────────────────
TOOL_NAME="tool-template"                                # TODO: your kebab-case tool name
TOOL_SUMMARY="one-line summary of what this tool does"   # TODO

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
# Reference example: ensure a marker line exists in a target file — a real,
# grep-guarded, dry-run-aware, idempotent operation you REPLACE with your own.
# TOOL_TEMPLATE_TARGET lets the conformance spec redirect the write to a scratch
# file; a real tool hardcodes its own path and drops the env indirection.
TARGET_FILE="${TOOL_TEMPLATE_TARGET:-${HOME}/.config/init_ubuntu/tool-template.marker}"
MARKER_LINE="managed-by-init-ubuntu"

do_work() {
    tool_ensure_line "${TARGET_FILE}" "${MARKER_LINE}"
}

# ── Entry ────────────────────────────────────────────────────────────────────
tool_main "$@"
