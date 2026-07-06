#!/usr/bin/env bash
# shellcheck disable=SC2034  # module metadata vars (NAME / DESCRIPTION / CATEGORY / TAGS / ...) consumed by engine post-source — https://www.shellcheck.net/wiki/SC2034
# module/tmux.module.sh — tmux + tmux-powerline config

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
    [en]="Run 'tmux source ~/.config/tmux/tmux.conf' inside an existing session to reload."
    [zh-TW]="在現有 session 內執行 'tmux source ~/.config/tmux/tmux.conf' 以重新載入設定。"
)
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl")
DEPENDS_ON=("git" "curl")
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
    module_dryrun_guard install "drop tmux config to ${HOME}/.config/tmux/tmux.conf + tmux-powerline" && return 0
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
    # Modern tmux reads the XDG path first; tmux.conf's own source-file reload
    # binding also targets ~/.config/tmux/tmux.conf, so install must write
    # there (not the legacy ~/.tmux.conf) or repo and host diverge (issue #138).
    local _dest_dir="${HOME}/.config/tmux"
    [[ -d "${_src}" ]] || { log_warn "[${NAME}] tmux config dir missing: ${_src}"; return 0; }
    mkdir -p "${_dest_dir}"
    if [[ -f "${_dest_dir}/tmux.conf" ]] && declare -F backup_file >/dev/null 2>&1; then
        backup_file "${_dest_dir}/tmux.conf" || true
    fi
    cp "${_src}/tmux.conf" "${_dest_dir}/tmux.conf"
    if [[ -d "${_src}/tmux-powerline" ]]; then
        mkdir -p "${HOME}/.tmux"
        cp -r "${_src}/tmux-powerline" "${HOME}/.tmux/"
    fi
    log_info "[${NAME}] dropped tmux config -> ${_dest_dir}/tmux.conf"
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
