#!/usr/bin/env bash
# shellcheck disable=SC2034  # module metadata vars (NAME / DESCRIPTION / CATEGORY / TAGS / ...) consumed by engine post-source — https://www.shellcheck.net/wiki/SC2034
# modules/shell.module.sh — shell session basics (ssh client, keychain, xclip)

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
NAME="shell"
VERSION_PROVIDED="apt-managed"
CATEGORY="recommended"
TAGS=("shell" "core")
HOMEPAGE=""
declare -gA DESCRIPTION=(
    [en]="Shell session basics: ssh client, keychain, xclip"
    [zh-TW]="Shell 基礎工具:ssh client / keychain / xclip"
)
declare -gA POST_INSTALL_MESSAGE=()
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl")
DEPENDS_ON=("apt-essentials")
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="command -v ssh && command -v keychain"

# ── Archetype A ─────────────────────────────────────────────────────────────
APT_PKGS=(
    "ssh"
    "keychain"
    "xclip"
)
APT_PPA=""
CONFIG_PATHS=()
module_use_apt_archetype

# ── Required hooks ──────────────────────────────────────────────────────────
detect() {
    command -v apt-get >/dev/null 2>&1
}
is_recommended() {
    ! is_installed
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
