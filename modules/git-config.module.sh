#!/usr/bin/env bash
# shellcheck disable=SC2034  # module metadata vars (NAME / DESCRIPTION / CATEGORY / TAGS / ...) consumed by engine post-source — https://www.shellcheck.net/wiki/SC2034
# modules/git-config.module.sh — personal ~/.gitconfig drop

# ── Dual-mode header ────────────────────────────────────────────────────────
MODULE_STANDALONE="true"
[[ "${BASH_SOURCE[0]:-}" != "${0:-}" ]] && MODULE_STANDALONE="false"
if [[ "${MODULE_STANDALONE}" == "true" ]]; then
    set -euo pipefail
    shopt -s inherit_errexit 2>/dev/null || true
    MODULE_DIR="${MODULE_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-}")" && pwd -P)}"
    REPO_ROOT="${REPO_ROOT:-$(cd -- "${MODULE_DIR}/.." && pwd -P)}"
    LIB_DIR="${LIB_DIR:-${REPO_ROOT}/lib}"
    # shellcheck disable=SC1091
    source "${LIB_DIR}/logger.sh"
    # shellcheck disable=SC1091
    source "${LIB_DIR}/general.sh"
    # shellcheck disable=SC1091
    source "${LIB_DIR}/module_helper.sh"
fi

# ── Metadata ────────────────────────────────────────────────────────────────
NAME="git-config"
VERSION_PROVIDED="1.0"
CATEGORY="recommended"
TAGS=("config" "git" "dotfile")
HOMEPAGE=""
declare -gA DESCRIPTION=(
    [en]="Personal ~/.gitconfig (aliases, delta diff, rebase pull, ...)"
    [zh-TW]="個人 ~/.gitconfig 設定(alias / delta diff / rebase pull...)"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Edit ~/.gitconfig and set [user] name + email before committing."
    [zh-TW]="首次使用前請編輯 ~/.gitconfig 加入 [user] 的 name 與 email。"
)
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl" "container" "vm")
DEPENDS_ON=("apt-essentials")
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=true
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="user-home"
TEST_VERIFY_CMD="git config --global --list >/dev/null"

# ── Archetype C — config drop ────────────────────────────────────────────────
CONFIG_TEMPLATE_SRC="${MODULE_DIR:-${BASH_SOURCE[0]%/*}}/config/git_config"
CONFIG_DEST="${HOME}/.gitconfig"
CONFIG_MARKER="# init_ubuntu managed"
CONFIG_MODE="644"
module_use_config_archetype

# ── Required hooks ───────────────────────────────────────────────────────────
detect() {
    command -v git >/dev/null 2>&1
}
is_recommended() {
    ! is_installed
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
