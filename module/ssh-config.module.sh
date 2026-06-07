#!/usr/bin/env bash
# shellcheck disable=SC2034  # module metadata vars (NAME / DESCRIPTION / CATEGORY / TAGS / ...) consumed by engine post-source — https://www.shellcheck.net/wiki/SC2034
# module/ssh-config.module.sh — personal ~/.ssh/config drop

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
NAME="ssh-config"
VERSION_PROVIDED="1.0"
CATEGORY="optional"
TAGS=("config" "ssh" "dotfile")
HOMEPAGE=""
declare -gA DESCRIPTION=(
    [en]="Personal ~/.ssh/config templates (per-host alias and key map)"
    [zh-TW]="個人 ~/.ssh/config(各 host alias 與金鑰對應)"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Place private keys under ~/.ssh/ and verify file modes are 600."
    [zh-TW]="請將私鑰放入 ~/.ssh/ 並確認檔案權限為 600。"
)
declare -gA WARN_MESSAGE=(
    [en]="Existing ~/.ssh/config will be overwritten (backup is made if present)."
    [zh-TW]="既有 ~/.ssh/config 會被覆寫(會先備份)。"
)
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl" "container" "vm")
DEPENDS_ON=()
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=true
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="user-home"
TEST_VERIFY_CMD="[ -r \"${HOME}/.ssh/config\" ]"

# ── Archetype C — config drop ────────────────────────────────────────────────
CONFIG_TEMPLATE_SRC="${MODULE_DIR:-${BASH_SOURCE[0]%/*}}/config/ssh_config"
CONFIG_DEST="${HOME}/.ssh/config"
CONFIG_MARKER="# init_ubuntu managed"
CONFIG_MODE="600"
CONFIG_DIR_MODE="700"
module_use_config_archetype

# ── Required hooks ───────────────────────────────────────────────────────────
detect() {
    return 0
}
is_recommended() {
    ! is_installed
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
