#!/usr/bin/env bash
# module/curl.module.sh — curl — command-line tool for transferring data with URLs (apt curl package)  [archetype: apt]
#
# Split out of the former apt-essentials bundle (ADR-0026): each base tool
# is now an independently installable / removable module. Ubuntu ships the
# `curl` package; the binary is `curl`.
#
# Standalone usage:
#   bash module/curl.module.sh install [--dry-run]
#   bash module/curl.module.sh upgrade / remove / purge / verify
#   bash module/curl.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/curl.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install curl

# ── Dual-mode header ────────────────────────────────────────────────────────
MODULE_STANDALONE="true"
[[ "${BASH_SOURCE[0]:-}" != "${0:-}" ]] && MODULE_STANDALONE="false"
if [[ "${MODULE_STANDALONE}" == "true" ]]; then
    set -euo pipefail
    shopt -s inherit_errexit 2>/dev/null || true
    MODULE_DIR="${MODULE_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-}")" && pwd -P)}"
    REPO_ROOT="${REPO_ROOT:-$(cd -- "${MODULE_DIR}/.." && pwd -P)}"
    LIB_DIR="${LIB_DIR:-${REPO_ROOT}/lib}"
    export MODULE_DIR REPO_ROOT LIB_DIR
    # shellcheck source=../lib/logger.sh
    source "${LIB_DIR}/logger.sh"
    # shellcheck source=../lib/general.sh
    source "${LIB_DIR}/general.sh"
    # shellcheck source=../lib/module_helper.sh
    source "${LIB_DIR}/module_helper.sh"
fi

# ── Metadata (doc/module-spec.md §3) ────────────────────────────────────────
NAME="curl"
VERSION_PROVIDED="apt-managed"
CATEGORY="base"
TAGS=("http")
HOMEPAGE="https://curl.se/"
declare -gA DESCRIPTION=(
    [en]="curl — command-line tool for transferring data with URLs (apt curl package)"
    [zh-TW]="curl — 透過 URL 傳輸資料的命令列工具(apt curl 套件)"
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
TEST_VERIFY_CMD="command -v curl && curl --version | head -n1"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# ── Archetype A — apt ───────────────────────────────────────────────────────
APT_PKGS=("curl")
APT_PPA=""
CONFIG_PATHS=()
module_use_apt_archetype

# Override install/upgrade (super-call pattern, archetype-cookbook §A):
# chain to the apt default, then record the version Sidecar (ADR-0001).
install() {
    module_default_apt_install || return $?
    [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]] && return 0
    module_sidecar_write "${NAME}" "$(_curl_pkg_version)"
}

upgrade() {
    module_default_apt_upgrade || return $?
    [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]] && return 0
    module_sidecar_write "${NAME}" "$(_curl_pkg_version)"
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
        log_warn "[${NAME}] doctor: curl is not installed"
        return 1
    fi
    local _bin
    _bin="$(command -v curl 2>/dev/null)" || {
        log_warn "[${NAME}] doctor: curl binary not found on PATH"
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
_curl_pkg_version() {
    local _ver=""
    _ver="$(dpkg-query -W -f='${Version}' curl 2>/dev/null)" || _ver=""
    printf '%s' "${_ver:-apt-managed}"
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
