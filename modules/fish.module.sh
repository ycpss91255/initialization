#!/usr/bin/env bash
# shellcheck disable=SC2034  # module metadata vars (NAME / DESCRIPTION / CATEGORY / TAGS / ...) consumed by engine post-source — https://www.shellcheck.net/wiki/SC2034
# modules/fish.module.sh — fish shell 4 + fisher plugins + user config

# ── Dual-mode header ────────────────────────────────────────────────────────
MODULE_STANDALONE="true"
[[ "${BASH_SOURCE[0]:-}" != "${0:-}" ]] && MODULE_STANDALONE="false"
if [[ "${MODULE_STANDALONE}" == "true" ]]; then
    set -euo pipefail
    shopt -s inherit_errexit 2>/dev/null || true
    MODULE_DIR="${MODULE_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-}")" && pwd -P)}"
    REPO_ROOT="${REPO_ROOT:-$(cd -- "${MODULE_DIR}/.." && pwd -P)}"
    LIB_DIR="${LIB_DIR:-${REPO_ROOT}/lib}"
    # shellcheck disable=SC1091  # dynamic source path ($VAR resolved at runtime) — https://www.shellcheck.net/wiki/SC1091
    source "${LIB_DIR}/logger.sh"
    # shellcheck disable=SC1091  # dynamic source path ($VAR resolved at runtime) — https://www.shellcheck.net/wiki/SC1091
    source "${LIB_DIR}/general.sh"
    # shellcheck disable=SC1091  # dynamic source path ($VAR resolved at runtime) — https://www.shellcheck.net/wiki/SC1091
    source "${LIB_DIR}/module_helper.sh"
fi

# ── Metadata ────────────────────────────────────────────────────────────────
NAME="fish"
VERSION_PROVIDED="ppa-managed"
CATEGORY="recommended"
TAGS=("shell" "fish")
HOMEPAGE="https://fishshell.com/"
declare -gA DESCRIPTION=(
    [en]="fish shell 4 + fisher plugins + tide prompt + user config"
    [zh-TW]="fish shell 4 + fisher plugins + tide prompt + 個人設定"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Default shell switched to fish. Open a new terminal to start using it."
    [zh-TW]="預設 shell 已切換到 fish,請打開新終端機開始使用。"
)
declare -gA WARN_MESSAGE=(
    [en]="install runs 'chsh -s fish' for the current user."
    [zh-TW]="install 會執行 'chsh -s fish' 切換預設 shell。"
)
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl")
DEPENDS_ON=("apt-essentials" "shell")
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="medium"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="command -v fish && fish --version"

APT_PKGS=("fish" "xclip")
APT_PPA="ppa:fish-shell/release-4"
CONFIG_PATHS=("${HOME}/.config/fish")

module_use_apt_archetype

# Override install: archetype adds PPA + installs pkgs, then drop config +
# install fisher plugins + chsh.
install() {
    module_default_apt_install || return $?
    module_dryrun_guard install "drop fish config + install fisher plugins + chsh" && return 0
    _install_fish_config
    _install_fisher_plugins
    _switch_default_shell_to_fish
}

upgrade() {
    module_default_apt_upgrade || return $?
    module_dryrun_guard upgrade "re-install fisher plugins" && return 0
    _install_fisher_plugins
}

detect() {
    command -v apt-get >/dev/null 2>&1
}
is_recommended() {
    ! is_installed
}

# ── Private helpers ─────────────────────────────────────────────────────────
_install_fish_config() {
    local _src="${MODULE_DIR:-${BASH_SOURCE[0]%/*}}/config/fish"
    [[ -d "${_src}" ]] || { log_warn "[${NAME}] fish config dir missing: ${_src}"; return 0; }
    if [[ -d "${HOME}/.config/fish" ]] && declare -F backup_file >/dev/null 2>&1; then
        backup_file "${HOME}/.config/fish" || true
    fi
    mkdir -p "${HOME}/.config"
    cp -r "${_src}" "${HOME}/.config/fish"
    log_info "[${NAME}] dropped fish config -> ${HOME}/.config/fish"
}

_install_fisher_plugins() {
    command -v fish >/dev/null 2>&1 || { log_warn "[${NAME}] fish not on PATH yet"; return 0; }
    local _fisher_url="https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish"
    fish -c "curl -fsSL --retry 3 '${_fisher_url}' | source && fisher install jorgebucaran/fisher" \
        || { log_warn "[${NAME}] fisher bootstrap failed"; return 0; }
    fish -c "fisher install \
        jorgebucaran/autopair.fish \
        markcial/upto \
        edc/bass \
        kidonng/zoxide.fish \
        PatrickF1/fzf.fish \
        IlanCosman/tide@v6 \
        meaningful-ooo/sponge \
        2m/fish-history-merge \
        oh-my-fish/plugin-pj" || log_warn "[${NAME}] fisher install plugins partial fail"
}

_switch_default_shell_to_fish() {
    local _fish_path
    _fish_path="$(command -v fish 2>/dev/null || true)"
    [[ -n "${_fish_path}" ]] || { log_warn "[${NAME}] fish missing — cannot chsh"; return 0; }
    if have_sudo_access 2>/dev/null; then
        sudo chsh -s "${_fish_path}" "${USER}" \
            || log_warn "[${NAME}] chsh failed; user must run it manually"
    else
        log_warn "[${NAME}] no sudo: cannot chsh; run 'chsh -s ${_fish_path}' manually"
    fi
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
