#!/usr/bin/env bash
# module/yazi.module.sh — yazi, a blazing-fast TUI file manager  [archetype: github-release]
#
# Migrated from module/submodule/yazi.sh (issue #60, PRD §6.3.3 Batch C).
# Legacy installed the GitHub release zip to /opt/yazi, symlinked
# /usr/local/bin/yazi, and appended a guarded `alias yz='yazi'` to
# ~/.bashrc / ~/.zshrc. This module keeps that behavior; the alias targets
# yazi itself (the issue #1 copy-paste bug aliased cat instead).
#
# Upstream ships a ZIP (yazi-x86_64-unknown-linux-gnu.zip), not a tarball,
# so install/upgrade override the archetype fetch with a zip-aware one
# (super-call pattern, doc/guide/archetype-cookbook.md). Sidecar lifecycle
# per ADR-0001 / module-spec §4.7.4: written on install/upgrade success,
# deleted on remove/purge; state.json is engine-only.
#
# Standalone usage:
#   bash module/yazi.module.sh install [--dry-run]
#   bash module/yazi.module.sh upgrade / remove / purge / verify / doctor
#   bash module/yazi.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/yazi.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install yazi

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
NAME="yazi"
VERSION_PROVIDED="latest"
CATEGORY="optional"
TAGS=("filemgr")
HOMEPAGE="https://github.com/sxyazi/yazi"
declare -gA DESCRIPTION=(
    [en]="yazi — blazing-fast TUI file manager + shell alias yz='yazi'"
    [zh-TW]="yazi — 高速終端機檔案管理器 + shell alias yz='yazi'"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="alias yz='yazi' appended to ~/.bashrc / ~/.zshrc — re-source your rc or restart the shell."
    [zh-TW]="已將 alias yz='yazi' 加入 ~/.bashrc / ~/.zshrc — 請重新 source rc 或重啟 shell。"
)
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl")
DEPENDS_ON=()
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="command -v yazi && yazi --version"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}" "${HOMEPAGE}" \
    "${CONFLICTS_WITH[*]:-}" "${SUPPORTED_PLATFORMS[*]:-}" \
    "${SUPPORTED_UBUNTU[*]:-}" "${RISK_LEVEL}" "${REBOOT_REQUIRED}"

# ── Archetype B — GitHub release (zip variant) ──────────────────────────────
# Upstream asset is version-less and zip-formatted; it extracts to a single
# top-level dir of the same base name (flattened into INSTALL_DIR below).
GITHUB_REPO="sxyazi/yazi"
GITHUB_ASSET_PATTERN="yazi-x86_64-unknown-linux-gnu.zip"
INSTALL_DIR="/opt/yazi"
BIN_NAME="yazi"
BIN_LINK="/usr/local/bin/yazi"
USE_SUDO=true
CONFIG_PATHS=(
    "${HOME}/.config/yazi"
)
module_use_github_release_archetype

# detect: only the x86_64 gnu zip is wired.
detect() {
    [[ "$(uname -m)" == "x86_64" ]]
}

# is_recommended: recommend when missing.
is_recommended() {
    ! is_installed
}

# is_outdated: compare the Sidecar version against the latest release tag.
# No Sidecar -> unknown -> report "not outdated" without hitting the network.
is_outdated() {
    local _local="" _remote=""
    _local="$(module_sidecar_get_version "${NAME}" 2>/dev/null)" || return 1
    [[ -n "${_local}" ]] || return 1
    get_github_pkg_latest_version _remote "${GITHUB_REPO}" 2>/dev/null || return 1
    [[ -n "${_remote}" && "${_local}" != "${_remote}" ]]
}

# doctor: binary present + runnable; heal a missing Sidecar (ADR-0001 says
# is_installed=true should imply the Sidecar exists).
doctor() {
    if ! is_installed; then
        log_warn "[${NAME}] doctor: yazi is not installed"
        return 1
    fi
    if ! _yazi_run_bin --version >/dev/null 2>&1; then
        log_warn "[${NAME}] doctor: yazi is present but not runnable"
        return 1
    fi
    if ! module_sidecar_get_version "${NAME}" >/dev/null 2>&1; then
        log_warn "[${NAME}] doctor: Sidecar missing — rewriting it"
        module_sidecar_write "${NAME}" "$(_yazi_local_version)"
    fi
    return 0
}

# ── Private helpers ─────────────────────────────────────────────────────────

# Run the installed binary: prefer BIN_LINK, fall back to PATH lookup.
_yazi_run_bin() {
    local _bin="${BIN_LINK:-/usr/local/bin/yazi}"
    [[ -x "${_bin}" ]] || _bin="${BIN_NAME:-yazi}"
    "${_bin}" "$@"
}

_yazi_local_version() {
    local _v=""
    _v="$(_yazi_run_bin --version 2>/dev/null \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)" || true
    printf '%s' "${_v:-unknown}"
}
