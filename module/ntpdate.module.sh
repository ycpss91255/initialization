#!/usr/bin/env bash
# module/ntpdate.module.sh — ntpdate — legacy one-shot NTP time sync  [archetype: apt]
#
# ntpdate is a LEGACY tool: modern Ubuntu keeps the clock in sync with
# systemd-timesyncd (or chrony) out of the box, so most machines do NOT need
# this package. It exists here because the `dual_system_time_sync` one-off tool
# (tool/dual_system_time_sync.sh, ADR-0029) drives `ntpdate` for a single
# forced sync before writing the RTC in localtime on dual-boot Windows/Linux
# machines. That tool refuses to install host packages itself (repo hard rule
# #2), so this module provisions the `ntpdate` package for it.
#
# Ubuntu ships the `ntpdate` package; the binary is `ntpdate`.
#
# Standalone usage:
#   bash module/ntpdate.module.sh install [--dry-run]
#   bash module/ntpdate.module.sh upgrade / remove / purge / verify
#   bash module/ntpdate.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/ntpdate.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install ntpdate

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
NAME="ntpdate"
VERSION_PROVIDED="apt-managed"
CATEGORY="optional"
TAGS=("time")
HOMEPAGE="https://manpages.ubuntu.com/manpages/noble/man8/ntpdate.8.html"
declare -gA DESCRIPTION=(
    [en]="ntpdate — legacy one-shot NTP time sync (used by dual_system_time_sync)"
    [zh-TW]="ntpdate — 舊式一次性 NTP 對時工具(供 dual_system_time_sync 使用)"
)
declare -gA POST_INSTALL_MESSAGE=()
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl")
DEPENDS_ON=()
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="command -v ntpdate"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# ── Archetype A — apt ───────────────────────────────────────────────────────
APT_PKGS=("ntpdate")
APT_PPA=""
CONFIG_PATHS=()
module_use_apt_archetype

# ── Required hooks (detect + is_recommended stay module-specific) ────────────
detect() {
    command -v apt-get >/dev/null 2>&1
}

# ntpdate is a legacy special-purpose tool; it is never part of Quick Setup.
# Install it explicitly (or as a prerequisite of dual_system_time_sync).
is_recommended() {
    return 1
}

# ── Real doctor (overrides the archetype default) ───────────────────────────
# The default archetype doctor delegates to verify(); ntpdate ships a concrete
# probe: the package must be installed AND the `ntpdate` binary must resolve on
# PATH (that binary is exactly what dual_system_time_sync invokes).
doctor() {
    if ! is_installed; then
        log_warn "[${NAME}] doctor: ntpdate is not installed"
        return 1
    fi
    if ! command -v ntpdate >/dev/null 2>&1; then
        log_warn "[${NAME}] doctor: package present but the ntpdate binary is not on PATH"
        return 1
    fi
    return 0
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
