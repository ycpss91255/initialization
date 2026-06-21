#!/usr/bin/env bash
# module/wget.module.sh — wget — non-interactive network downloader (apt wget package)  [archetype: apt]
#
# Split out of the former apt-essentials bundle (ADR-0026): each base tool
# is now an independently installable / removable module. Ubuntu ships the
# `wget` package; the binary is `wget`.
#
# Standalone usage:
#   bash module/wget.module.sh install [--dry-run]
#   bash module/wget.module.sh upgrade / remove / purge / verify
#   bash module/wget.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/wget.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install wget

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
NAME="wget"
VERSION_PROVIDED="apt-managed"
CATEGORY="base"
TAGS=("http")
HOMEPAGE="https://www.gnu.org/software/wget/"
declare -gA DESCRIPTION=(
    [en]="wget — non-interactive network downloader (apt wget package)"
    [zh-TW]="wget — 非互動式網路下載工具(apt wget 套件)"
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
TEST_VERIFY_CMD="command -v wget && wget --version | head -n1"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# ── Archetype A — apt ───────────────────────────────────────────────────────
APT_PKGS=("wget")
APT_PPA=""
CONFIG_PATHS=()
module_use_apt_archetype

# Override install/upgrade (super-call pattern, archetype-cookbook §A):
# chain to the apt default, then record the version Sidecar (ADR-0001).
install() {
    module_default_apt_install || return $?
    [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]] && return 0
    module_sidecar_write "${NAME}" "$(_wget_pkg_version)"
}

upgrade() {
    module_default_apt_upgrade || return $?
    [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]] && return 0
    module_sidecar_write "${NAME}" "$(_wget_pkg_version)"
}

remove() {
    module_default_apt_remove || return $?
    module_sidecar_remove "${NAME}"
}

purge() {
    module_default_apt_purge || return $?
    module_sidecar_remove "${NAME}"
}

detect() {
    command -v apt-get >/dev/null 2>&1
}

is_recommended() {
    ! is_installed
}

# doctor: health check — package installed, binary runnable, Sidecar present.
doctor() {
    if ! is_installed; then
        log_warn "[${NAME}] doctor: wget is not installed"
        return 1
    fi
    local _bin
    _bin="$(command -v wget 2>/dev/null)" || {
        log_warn "[${NAME}] doctor: wget binary not found on PATH"
        return 1
    }
    if ! "${_bin}" --version >/dev/null 2>&1; then
        log_warn "[${NAME}] doctor: ${_bin} --version failed"
        return 1
    fi
    module_sidecar_get_version "${NAME}" >/dev/null 2>&1 \
        || log_warn "[${NAME}] doctor: sidecar missing (installed outside init_ubuntu?)"
    return 0
}

# ── Private helpers ─────────────────────────────────────────────────────────

# Version string for the Sidecar: dpkg-reported package version, falling
# back to the literal "apt-managed" when dpkg has no answer.
_wget_pkg_version() {
    local _ver=""
    _ver="$(dpkg-query -W -f='${Version}' wget 2>/dev/null)" || _ver=""
    printf '%s' "${_ver:-apt-managed}"
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
