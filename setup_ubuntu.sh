#!/usr/bin/env bash
# setup_ubuntu.sh — init_ubuntu CLI entry point
#
# Thin dispatcher: sources lib/* helpers, loads the module registry, then
# routes to lib/dispatcher.sh based on argv.
#
# Lineage: replaces the monolithic Phase 0 setup_ubuntu.sh which sourced
# modules/setup_<topic>.sh directly. Those legacy scripts remain on disk
# until Phase 7 (module migration) where each becomes modules/<n>.module.sh.

set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true

# Root rejection is enforced inside lib/dispatcher.sh _dispatcher_lifecycle
# only for non-dry-run install/remove/purge. Read-only subcommands
# (list / show / help / version / detect) and --dry-run are root-safe so
# bats can run them under the test container's default user.

# ── Path resolution ──────────────────────────────────────────────────────────
SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
export REPO_ROOT="${SCRIPT_PATH}"
export LIB_DIR="${REPO_ROOT}/lib"
export MODULE_DIR="${REPO_ROOT}/modules"
export TEMPLATE_DIR="${REPO_ROOT}/templates"

# ── Defaults for logging / env-driven flags ──────────────────────────────────
export USER="${USER:-"$(whoami)"}"
export HOME="${HOME:-"/home/${USER}"}"
export LOG_LEVEL="${LOG_LEVEL:-INFO}"
export LOG_COLOR="${LOG_COLOR:-true}"

# ── Source engine ────────────────────────────────────────────────────────────
# shellcheck disable=SC1091  # dynamic source path ($VAR resolved at runtime) — https://www.shellcheck.net/wiki/SC1091
source "${LIB_DIR}/logger.sh"
# shellcheck disable=SC1091  # dynamic source path ($VAR resolved at runtime) — https://www.shellcheck.net/wiki/SC1091
source "${LIB_DIR}/general.sh"
# shellcheck disable=SC1091  # dynamic source path ($VAR resolved at runtime) — https://www.shellcheck.net/wiki/SC1091
source "${LIB_DIR}/i18n.sh"
# shellcheck disable=SC1091  # dynamic source path ($VAR resolved at runtime) — https://www.shellcheck.net/wiki/SC1091
source "${LIB_DIR}/detect.sh"
# shellcheck disable=SC1091  # dynamic source path ($VAR resolved at runtime) — https://www.shellcheck.net/wiki/SC1091
source "${LIB_DIR}/platform.sh"
# shellcheck disable=SC1091  # dynamic source path ($VAR resolved at runtime) — https://www.shellcheck.net/wiki/SC1091
source "${LIB_DIR}/state.sh"
# shellcheck disable=SC1091  # dynamic source path ($VAR resolved at runtime) — https://www.shellcheck.net/wiki/SC1091
source "${LIB_DIR}/state_io.sh"
# shellcheck disable=SC1091  # dynamic source path ($VAR resolved at runtime) — https://www.shellcheck.net/wiki/SC1091
source "${LIB_DIR}/config.sh"
# shellcheck disable=SC1091  # dynamic source path ($VAR resolved at runtime) — https://www.shellcheck.net/wiki/SC1091
source "${LIB_DIR}/sync.sh"
# shellcheck disable=SC1091  # dynamic source path ($VAR resolved at runtime) — https://www.shellcheck.net/wiki/SC1091
source "${LIB_DIR}/registry.sh"
# shellcheck disable=SC1091  # dynamic source path ($VAR resolved at runtime) — https://www.shellcheck.net/wiki/SC1091
source "${LIB_DIR}/resolver.sh"
# shellcheck disable=SC1091  # dynamic source path ($VAR resolved at runtime) — https://www.shellcheck.net/wiki/SC1091
source "${LIB_DIR}/runner.sh"
# shellcheck disable=SC1091  # dynamic source path ($VAR resolved at runtime) — https://www.shellcheck.net/wiki/SC1091
source "${LIB_DIR}/dispatcher.sh"

# ── Compute & export form_factor for module sub-shells ──────────────────────
# Modules' is_recommended() and platform-aware install() read this. We
# export once at startup so all sub-shells inherit a consistent value.
platform_export_env || true

# ── Initialize state.json + config.ini (both idempotent) ──────────────────
state_init || true
config_init || true

# ── Resolve INIT_UBUNTU_LANG (env > config.ini > auto-detect from $LANG) ────
i18n_resolve_init_ubuntu_lang

# ── Load module registry (silent on missing modules/ dir) ─────────────────────
registry_load_all "${MODULE_DIR}" || true

# ── Dispatch ─────────────────────────────────────────────────────────────────
dispatcher_dispatch "$@"
