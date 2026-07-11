#!/usr/bin/env bash
# module/bmon.module.sh — bmon — bandwidth monitor (apt bmon package)  [archetype: apt]
#
# Part of the small-tools modularization program: each monitoring tool is an
# independently installable / removable module. Ubuntu ships the `bmon`
# package; the binary is `bmon`.
#
# Standalone usage:
#   bash module/bmon.module.sh install [--dry-run]
#   bash module/bmon.module.sh upgrade / remove / purge / verify / doctor
#   bash module/bmon.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/bmon.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install bmon

# ── Dual-mode header ────────────────────────────────────────────────────────
MODULE_STANDALONE="true"
[[ "${BASH_SOURCE[0]:-}" != "${0:-}" ]] && MODULE_STANDALONE="false"
if [[ "${MODULE_STANDALONE}" == "true" ]]; then
    # shellcheck source=../lib/module_bootstrap.sh
    source "${LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd -P)}/module_bootstrap.sh"
    module_bootstrap
fi
# Static-analysis hint (never executed: the guard is always false; wrapped in
# kcov-exclude so the dead line is not counted against coverage). module_bootstrap
# sources the lib helpers at runtime, but shellcheck cannot trace that 2-level
# dynamic source — this guarded line lets `shellcheck -x` follow module_helper.sh
# so it sees the metadata + archetype vars below are used externally (avoids SC2034).
# kcov-exclude-start
# shellcheck source=../lib/module_helper.sh
[[ -n "${__module_lint_hint:-}" ]] && source "${LIB_DIR}/module_helper.sh"
# kcov-exclude-end

# ── Metadata (doc/module-spec.md §3) ────────────────────────────────────────
NAME="bmon"
VERSION_PROVIDED="apt-managed"
CATEGORY="optional"
TAGS=("monitoring")
HOMEPAGE="https://github.com/tgraf/bmon"
declare -gA DESCRIPTION=(
    [en]="bmon — bandwidth monitor (real-time per-interface traffic, apt bmon package)"
    [zh-TW]="bmon — 頻寬監視工具(即時各介面網路流量,apt bmon 套件)"
)
declare -gA POST_INSTALL_MESSAGE=()
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl" "container" "vm")
DEPENDS_ON=()
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="command -v bmon && bmon -V"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# ── Archetype A — apt ───────────────────────────────────────────────────────
APT_PKGS=("bmon")
APT_PPA=""
CONFIG_PATHS=()
module_use_apt_archetype

# ── Required hooks (detect + is_recommended stay module-specific) ────────────
detect() {
    command -v apt-get >/dev/null 2>&1
}

is_recommended() {
    ! is_installed
}

# doctor: real runtime health — the tool must be installed AND actually run
# (`bmon -V` prints the version and exits). Warns (read-only) on Sidecar
# drift (ADR-0001).
doctor() {
    module_dryrun_guard doctor "is_installed + bmon -V + Sidecar consistency" \
        && return 0
    is_installed || { log_warn "[${NAME}] doctor: bmon is not installed"; return 1; }
    bmon -V >/dev/null 2>&1 \
        || { log_warn "[${NAME}] doctor: bmon is present but not runnable"; return 1; }
    if ! module_sidecar_get_version "${NAME}" >/dev/null 2>&1; then
        log_warn "[${NAME}] doctor: Sidecar missing (ADR-0001 drift; re-run install/upgrade to heal)"
    fi
    return 0
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
