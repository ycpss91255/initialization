#!/usr/bin/env bash
# setup_ubuntu.sh — init_ubuntu CLI entry point
#
# Thin dispatcher: sources lib/* helpers, loads the module registry, then
# routes to lib/dispatcher.sh based on argv.
#
# Lineage: replaces the monolithic Phase 0 setup_ubuntu.sh which sourced
# module/setup_<topic>.sh directly. Those legacy scripts remain on disk
# until Phase 7 (module migration) where each becomes module/<n>.module.sh.

set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true

# ── Refuse to run as root (PRD §10) ──────────────────────────────────────────
if [[ "${EUID:-0}" -eq 0 ]]; then
    printf "ERROR: Do not run setup_ubuntu as root.\n" >&2
    printf "Run as a regular user; sudo will be requested per-module.\n" >&2
    exit 4
fi

# ── Path resolution ──────────────────────────────────────────────────────────
SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
export REPO_ROOT="${SCRIPT_PATH}"
export LIB_DIR="${REPO_ROOT}/lib"
export MODULE_DIR="${REPO_ROOT}/module"
export TEMPLATE_DIR="${REPO_ROOT}/template"

# ── Defaults for logging / env-driven flags ──────────────────────────────────
export USER="${USER:-"$(whoami)"}"
export HOME="${HOME:-"/home/${USER}"}"
export LOG_LEVEL="${LOG_LEVEL:-INFO}"
export LOG_COLOR="${LOG_COLOR:-true}"

# ── Source engine ────────────────────────────────────────────────────────────
# shellcheck disable=SC1091
source "${LIB_DIR}/logger.sh"
# shellcheck disable=SC1091
source "${LIB_DIR}/general.sh"
# shellcheck disable=SC1091
source "${LIB_DIR}/registry.sh"
# shellcheck disable=SC1091
source "${LIB_DIR}/resolver.sh"
# shellcheck disable=SC1091
source "${LIB_DIR}/runner.sh"
# shellcheck disable=SC1091
source "${LIB_DIR}/dispatcher.sh"

# ── Load module registry (silent on missing module/ dir) ─────────────────────
registry_load_all "${MODULE_DIR}" || true

# ── Dispatch ─────────────────────────────────────────────────────────────────
dispatcher_dispatch "$@"
