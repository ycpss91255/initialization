#!/usr/bin/env bash
# module/fdfind.module.sh — fd (fdfind): fast find alternative  [archetype: apt]
#
# Migrated from module/submodule/fdfind.sh (v1 GitHub tarball install) to the
# v2 contract (doc/module-spec.md) on the apt archetype: Ubuntu ships fd as
# the `fd-find` package whose binary is `fdfind` (the `fd` name is taken by
# another package). Also a neovim dependency (telescope file finding).
#
# Standalone usage:
#   bash module/fdfind.module.sh install [--dry-run]
#   bash module/fdfind.module.sh upgrade / remove / purge / verify
#   bash module/fdfind.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/fdfind.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install fdfind

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
NAME="fdfind"
VERSION_PROVIDED="apt-managed"
CATEGORY="optional"
TAGS=("cli-essentials")
HOMEPAGE="https://github.com/sharkdp/fd"
declare -gA DESCRIPTION=(
    [en]="fd (fdfind) — fast, user-friendly alternative to find (apt fd-find)"
    [zh-TW]="fd(fdfind)— 快速好用的 find 替代工具(apt fd-find 套件)"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Ubuntu names the binary 'fdfind' ('fd' is taken by another package). Add 'alias fd=fdfind' to your shell rc for the short name."
    [zh-TW]="Ubuntu 將執行檔命名為 'fdfind'('fd' 已被其他套件占用)。想用短名稱可在 shell rc 加上 'alias fd=fdfind'。"
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
TEST_VERIFY_CMD="command -v fdfind && fdfind --version"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# ── Archetype A — apt ───────────────────────────────────────────────────────
APT_PKGS=("fd-find")
APT_PPA=""
CONFIG_PATHS=("${HOME}/.config/fd")
module_use_apt_archetype

# Override install/upgrade (super-call pattern, archetype-cookbook §A):
# chain to the apt default, then record the version Sidecar (ADR-0001;
# module_sidecar_* helpers are dry-run-safe, the explicit guard just
# skips the pointless dpkg-query).
install() {
    module_default_apt_install || return $?
    [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]] && return 0
    module_sidecar_write "${NAME}" "$(_fdfind_pkg_version)"
}

upgrade() {
    module_default_apt_upgrade || return $?
    [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]] && return 0
    module_sidecar_write "${NAME}" "$(_fdfind_pkg_version)"
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
        log_warn "[${NAME}] doctor: fd-find is not installed"
        return 1
    fi
    local _bin
    _bin="$(command -v fdfind 2>/dev/null)" || {
        log_warn "[${NAME}] doctor: fdfind binary not found on PATH"
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
_fdfind_pkg_version() {
    local _ver=""
    _ver="$(dpkg-query -W -f='${Version}' fd-find 2>/dev/null)" || _ver=""
    printf '%s' "${_ver:-apt-managed}"
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
