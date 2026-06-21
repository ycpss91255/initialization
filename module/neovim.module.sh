#!/usr/bin/env bash
# shellcheck disable=SC2034  # module metadata vars (NAME / DESCRIPTION / CATEGORY / TAGS / ...) consumed by engine post-source — https://www.shellcheck.net/wiki/SC2034
# module/neovim.module.sh — Neovim editor (GitHub release) + nvimdots config

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

# ── Metadata ────────────────────────────────────────────────────────────────
NAME="neovim"
VERSION_PROVIDED="latest"
CATEGORY="recommended"
TAGS=("editor" "cli")
HOMEPAGE="https://neovim.io/"
declare -gA DESCRIPTION=(
    [en]="Neovim editor + nvimdots personal config"
    [zh-TW]="Neovim 編輯器 + nvimdots 個人設定"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="First launch will sync plugins via lazy.nvim — wait a moment before using."
    [zh-TW]="首次啟動會由 lazy.nvim 同步 plugin,請稍候完成。"
)
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl")
DEPENDS_ON=("curl" "git-config")
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="command -v nvim && nvim --version | head -n1"

# ── Archetype B — GitHub release ────────────────────────────────────────────
GITHUB_REPO="neovim/neovim"
GITHUB_ASSET_PATTERN="nvim-linux-x86_64.tar.gz"
INSTALL_DIR="/opt/nvim"
BIN_NAME="nvim"
BIN_LINK="/usr/local/bin/nvim"
STRIP_COMPONENTS=1
USE_SUDO=true
CONFIG_PATHS=(
    "${HOME}/.config/nvim"
    "${HOME}/.local/share/nvim"
    "${HOME}/.cache/nvim"
)
module_use_github_release_archetype

# Override install: archetype handles binary, then drop nvimdots config.
install() {
    module_default_github_release_install || return $?
    _install_nvimdots_config
}

detect() {
    [[ "$(uname -m)" == "x86_64" ]]
}
is_recommended() {
    ! is_installed
}

# ── Private helpers ─────────────────────────────────────────────────────────
_install_nvimdots_config() {
    if [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]]; then
        log_info "[${NAME}] [DRY-RUN] would drop nvimdots config to ~/.config/nvim"
        return 0
    fi
    local _src="${MODULE_DIR:-${BASH_SOURCE[0]%/*}}/config/neovim"
    [[ -d "${_src}" ]] || { log_warn "[${NAME}] neovim config dir missing: ${_src}"; return 0; }
    if [[ -d "${HOME}/.config/nvim" ]] && declare -F backup_file >/dev/null 2>&1; then
        backup_file "${HOME}/.config/nvim" || true
    fi
    mkdir -p "${HOME}/.config"
    cp -r "${_src}" "${HOME}/.config/nvim"
    log_info "[${NAME}] dropped nvim config -> ${HOME}/.config/nvim"
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
