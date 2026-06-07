#!/usr/bin/env bash
# module/ripgrep.module.sh — ripgrep (rg): fast grep alternative  [archetype: apt]
#
# New module (PRD §6.3.1, Q41): referenced by the neovim dep chain
# (telescope live-grep) but previously missing from the catalog. Ubuntu
# ships the `ripgrep` package in universe; the binary is `rg`.
#
# Standalone usage:
#   bash module/ripgrep.module.sh install [--dry-run]
#   bash module/ripgrep.module.sh upgrade / remove / purge / verify
#   bash module/ripgrep.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/ripgrep.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install ripgrep

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
NAME="ripgrep"
VERSION_PROVIDED="apt-managed"
CATEGORY="optional"
TAGS=("cli-essentials")
HOMEPAGE="https://github.com/BurntSushi/ripgrep"
declare -gA DESCRIPTION=(
    [en]="ripgrep (rg) — fast, recursive grep alternative (apt ripgrep package)"
    [zh-TW]="ripgrep(rg)— 快速的遞迴 grep 替代工具(apt ripgrep 套件)"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="The binary is 'rg'. Optional config: set RIPGREP_CONFIG_PATH to a ripgreprc file."
    [zh-TW]="執行檔名為 'rg'。選用設定:將 RIPGREP_CONFIG_PATH 指向 ripgreprc 檔案。"
)
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl" "container" "vm")
DEPENDS_ON=()
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="command -v rg && rg --version"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# ── Archetype A — apt ───────────────────────────────────────────────────────
APT_PKGS=("ripgrep")
APT_PPA=""
CONFIG_PATHS=("${HOME}/.config/ripgrep")
module_use_apt_archetype

# Override install/upgrade (super-call pattern, archetype-cookbook §A):
# chain to the apt default, then record the version Sidecar (ADR-0001;
# module_sidecar_* helpers are dry-run-safe, the explicit guard just
# skips the pointless dpkg-query).
install() {
    module_default_apt_install || return $?
    [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]] && return 0
    module_sidecar_write "${NAME}" "$(_ripgrep_pkg_version)"
}

upgrade() {
    module_default_apt_upgrade || return $?
    [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]] && return 0
    module_sidecar_write "${NAME}" "$(_ripgrep_pkg_version)"
}

# Override remove/purge: apt default handles packages/config, then drop
# the Sidecar — "what version is installed" is state, not user config.
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
        log_warn "[${NAME}] doctor: ripgrep is not installed"
        return 1
    fi
    local _bin
    _bin="$(command -v rg 2>/dev/null)" || {
        log_warn "[${NAME}] doctor: rg binary not found on PATH"
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
_ripgrep_pkg_version() {
    local _ver=""
    _ver="$(dpkg-query -W -f='${Version}' ripgrep 2>/dev/null)" || _ver=""
    printf '%s' "${_ver:-apt-managed}"
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
