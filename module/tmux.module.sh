#!/usr/bin/env bash
# shellcheck disable=SC2034  # module metadata vars (NAME / DESCRIPTION / CATEGORY / TAGS / ...) consumed by engine post-source — https://www.shellcheck.net/wiki/SC2034
# module/tmux.module.sh — tmux + tmux-powerline config

# ── Dual-mode header ────────────────────────────────────────────────────────
MODULE_STANDALONE="true"
[[ "${BASH_SOURCE[0]:-}" != "${0:-}" ]] && MODULE_STANDALONE="false"
if [[ "${MODULE_STANDALONE}" == "true" ]]; then
    set -euo pipefail
    shopt -s inherit_errexit 2>/dev/null || true
    MODULE_DIR="${MODULE_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-}")" && pwd -P)}"
    REPO_ROOT="${REPO_ROOT:-$(cd -- "${MODULE_DIR}/.." && pwd -P)}"
    LIB_DIR="${LIB_DIR:-${REPO_ROOT}/lib}"
    # shellcheck source=../lib/logger.sh
    source "${LIB_DIR}/logger.sh"
    # shellcheck source=../lib/general.sh
    source "${LIB_DIR}/general.sh"
    # shellcheck source=../lib/module_helper.sh
    source "${LIB_DIR}/module_helper.sh"
fi

# ── Metadata ────────────────────────────────────────────────────────────────
NAME="tmux"
VERSION_PROVIDED="apt-managed"
CATEGORY="recommended"
TAGS=("terminal" "multiplexer")
HOMEPAGE="https://github.com/tmux/tmux"
declare -gA DESCRIPTION=(
    [en]="Terminal multiplexer + powerline config"
    [zh-TW]="終端機 multiplexer + powerline 主題"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Run 'tmux source ~/.tmux.conf' inside an existing session to reload."
    [zh-TW]="在現有 session 內執行 'tmux source ~/.tmux.conf' 以重新載入設定。"
)
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl")
DEPENDS_ON=("apt-essentials")
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="command -v tmux && tmux -V"

# ── Archetype A — apt + override install to drop config too ─────────────────
APT_PKGS=("tmux")
APT_PPA=""
CONFIG_PATHS=(
    "${HOME}/.tmux.conf"
    "${HOME}/.config/tmux"
    "${HOME}/.tmux"
)
module_use_apt_archetype

# Override install: archetype install pkgs, then drop config.
install() {
    module_default_apt_install || return $?
    module_dryrun_guard install "drop tmux config to ${HOME}/.tmux.conf + tmux-powerline" && return 0
    _install_tmux_config
}

# Override update too — re-drop config to track upstream changes.
upgrade() {
    module_default_apt_upgrade || return $?
    module_dryrun_guard upgrade "re-drop tmux config" && return 0
    _install_tmux_config
}

detect() {
    command -v apt-get >/dev/null 2>&1
}
is_recommended() {
    ! is_installed
}

# ── Private helpers ─────────────────────────────────────────────────────────
_install_tmux_config() {
    local _src="${MODULE_DIR:-${BASH_SOURCE[0]%/*}}/config/tmux"
    [[ -d "${_src}" ]] || { log_warn "[${NAME}] tmux config dir missing: ${_src}"; return 0; }
    if [[ -f "${HOME}/.tmux.conf" ]] && declare -F backup_file >/dev/null 2>&1; then
        backup_file "${HOME}/.tmux.conf" || true
    fi
    cp "${_src}/tmux.conf" "${HOME}/.tmux.conf"
    if [[ -d "${_src}/tmux-powerline" ]]; then
        mkdir -p "${HOME}/.tmux"
        cp -r "${_src}/tmux-powerline" "${HOME}/.tmux/"
    fi
    log_info "[${NAME}] dropped tmux config -> ${HOME}/.tmux.conf"
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
