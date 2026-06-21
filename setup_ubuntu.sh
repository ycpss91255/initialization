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

# Root rejection is enforced inside lib/dispatcher.sh _dispatcher_lifecycle
# only for non-dry-run install/remove/purge. Read-only subcommands
# (list / show / help / version / detect) and --dry-run are root-safe so
# bats can run them under the test container's default user.

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
# shellcheck source=lib/color.sh
source "${LIB_DIR}/color.sh"

# ANSI color auto-detection (PRD §5.1 / §7.5, AC-16): decide once at startup
# (off when piped / NO_COLOR / TERM=dumb / background). An explicit
# --color=<mode> flag re-runs color_init inside dispatcher_dispatch.
color_init auto

# shellcheck source=lib/logger.sh
source "${LIB_DIR}/logger.sh"

# Session-level trace id (W3C Trace Context, ADR-0006): generated once per
# setup_ubuntu invocation and exported so every sub-shell (runner module
# sub-shells included) tags its JSONL events with the same trace_id.
_logger_ensure_trace_id

# shellcheck source=lib/general.sh
source "${LIB_DIR}/general.sh"
# shellcheck source=lib/preflight.sh
source "${LIB_DIR}/preflight.sh"
# shellcheck source=lib/i18n.sh
source "${LIB_DIR}/i18n.sh"
# shellcheck source=lib/environment.sh
source "${LIB_DIR}/environment.sh"
# shellcheck source=lib/state.sh
source "${LIB_DIR}/state.sh"
# shellcheck source=lib/state_migrate.sh
source "${LIB_DIR}/state_migrate.sh"
# shellcheck source=lib/state_io.sh
source "${LIB_DIR}/state_io.sh"
# shellcheck source=lib/config.sh
source "${LIB_DIR}/config.sh"
# shellcheck source=lib/sync.sh
source "${LIB_DIR}/sync.sh"
# shellcheck source=lib/registry.sh
source "${LIB_DIR}/registry.sh"
# shellcheck source=lib/resolver.sh
source "${LIB_DIR}/resolver.sh"
# module_helper.sh defines the archetype macros (module_use_*_archetype) and
# lifecycle helpers (module_dryrun_guard / module_skip_if_installed / the
# github-release fetch helper). The runner sources each module in a subshell
# that INHERITS these from this parent shell (lib/runner.sh), so they MUST be
# loaded here — otherwise a real (non-dry-run) install of any archetype module
# dies with `module_use_*_archetype: command not found`. (dry-run is dispatcher
# plan-only and never reaches the runner, which is why this went unnoticed.)
# shellcheck source=lib/module_helper.sh
source "${LIB_DIR}/module_helper.sh"
# shellcheck source=lib/runner.sh
source "${LIB_DIR}/runner.sh"
# shellcheck source=lib/dispatcher.sh
source "${LIB_DIR}/dispatcher.sh"

# ── Self-deps preflight (PRD §3.4, AC-34) ───────────────────────────────────
# Must run before anything that shells out to jq (state / config /
# environment). help / version paths are exempt inside preflight_self_deps.
preflight_self_deps "$@" || exit $?

# ── Compute & export form_factor for module sub-shells ──────────────────────
# Modules' is_recommended() and platform-aware install() read this. We
# export once at startup so all sub-shells inherit a consistent value.
platform_export_env "" || true

# ── Initialize state.json + config.ini (both idempotent) ──────────────────
state_init || true
# Forward-only schema migration (ADR-0008): bring an older state.json up to
# the current STATE_SCHEMA_VERSION before any read path touches it. A failed
# migration is fatal (it leaves the original file + a .bak untouched).
state_migrate_run || exit 1
config_init || true

# ── Resolve INIT_UBUNTU_LANG (env > config.ini > auto-detect from $LANG) ────
i18n_resolve_init_ubuntu_lang

# ── Load module registry (silent on missing module/ dir) ─────────────────────
registry_load_all "${MODULE_DIR}" || true

# ── Dispatch ─────────────────────────────────────────────────────────────────
dispatcher_dispatch "$@"
