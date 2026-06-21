#!/usr/bin/env bash
# shellcheck disable=SC2034  # module metadata vars (NAME / DESCRIPTION / CATEGORY / TAGS / ...) consumed by engine post-source — https://www.shellcheck.net/wiki/SC2034
# module/ssh-config.module.sh — personal ~/.ssh/config drop

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
