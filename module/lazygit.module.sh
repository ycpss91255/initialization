#!/usr/bin/env bash
# module/lazygit.module.sh — lazygit git TUI (GitHub release archetype)
#
# Migrated from module/submodule/lazygit.sh (issue #48, PRD §6.3.1 Batch B).
# Upstream tarballs are versioned (lazygit_<ver>_Linux_x86_64.tar.gz), so
# install/upgrade resolve the latest tag first, then delegate to the
# archetype default fetch (super-call pattern, doc/guide/archetype-cookbook.md).
# Sidecar lifecycle per ADR-0001 / module-spec §4.7.4: written on
# install/upgrade success, deleted on remove/purge; state.json is engine-only.

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

# ── Metadata (doc/module-spec.md §3) ────────────────────────────────────────
NAME="lazygit"
VERSION_PROVIDED="latest"
CATEGORY="optional"
TAGS=("cli-essentials")
HOMEPAGE="https://github.com/jesseduffield/lazygit"
declare -gA DESCRIPTION=(
    [en]="lazygit — terminal UI for git commands"
    [zh-TW]="lazygit — git 指令的終端機操作介面"
)
declare -gA POST_INSTALL_MESSAGE=()
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl")
DEPENDS_ON=("curl" "git")
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="command -v lazygit && lazygit --version | head -n1"

# ── Archetype B — GitHub release ────────────────────────────────────────────
GITHUB_REPO="jesseduffield/lazygit"
# Asset name is version-dependent; resolved at run time by
# _lazygit_resolve_asset_pattern (placeholder keeps the archetype data
# contract complete for `info` / dry-run output).
GITHUB_ASSET_PATTERN="lazygit_<latest>_Linux_x86_64.tar.gz"
INSTALL_DIR="/opt/lazygit"
BIN_NAME="lazygit"
BIN_PATH_IN_TAR="lazygit"   # tarball is flat: binary at archive root
BIN_LINK="/usr/local/bin/lazygit"
STRIP_COMPONENTS=0
USE_SUDO=true
CONFIG_PATHS=(
    "${HOME}/.config/lazygit"
)
module_use_github_release_archetype

# Override install/upgrade: resolve the versioned asset name first, then
# super-call the archetype fetch; write the Sidecar on success (ADR-0001).
install() {
    module_dryrun_guard install \
        "fetch ${GITHUB_REPO} latest -> ${INSTALL_DIR}, symlink ${BIN_LINK}" \
        && return 0
    module_skip_if_installed && return 0
    _lazygit_resolve_asset_pattern || return $?
    _module_github_release_fetch_and_install || return $?
    module_sidecar_write "${NAME}" "${_LAZYGIT_TARGET_VERSION:-unknown}"
}

upgrade() {
    module_dryrun_guard upgrade "force re-download ${GITHUB_REPO} latest" \
        && return 0
    _lazygit_resolve_asset_pattern || return $?
    _module_github_release_fetch_and_install || return $?
    module_sidecar_write "${NAME}" "${_LAZYGIT_TARGET_VERSION:-unknown}"
}

remove() {
    module_dryrun_guard remove \
        "rm ${INSTALL_DIR} + ${BIN_LINK} + Sidecar" \
        && return 0
    module_default_github_release_remove || return $?
    module_sidecar_remove "${NAME}"
}

purge() {
    module_dryrun_guard purge \
        "rm ${INSTALL_DIR} + ${BIN_LINK} + Sidecar + CONFIG_PATHS" \
        && return 0
    module_default_github_release_purge || return $?
    module_sidecar_remove "${NAME}"
}

detect() {
    # Upstream only ships a Linux_x86_64 tarball we can consume.
    [[ "$(uname -m)" == "x86_64" ]]
}

is_recommended() {
    ! is_installed
}

# is_outdated — compare Sidecar (or binary-reported) version against the
# latest GitHub release tag (doc/guide/archetype-cookbook.md, Archetype B).
is_outdated() {
    is_installed || return 1
    local _local="" _remote=""
    _local="$(_lazygit_installed_version)" || _local=""
    if declare -F get_github_pkg_latest_version >/dev/null 2>&1; then
        get_github_pkg_latest_version _remote "${GITHUB_REPO}" 2>/dev/null \
            || _remote=""
    fi
    [[ -n "${_remote}" && "${_local}" != "${_remote}" ]]
}

# doctor — metadata contract self-check + Sidecar invariant
# (module-spec §4.7.4: is_installed ⟷ Sidecar exists).
doctor() {
    local _ok=0
    if ! _lazygit_metadata_selfcheck; then
        log_warn "[${NAME}] doctor: metadata contract check failed"
        _ok=1
    fi
    local _sidecar
    _sidecar="$(module_sidecar_path "${NAME}")"
    if is_installed; then
        if [[ ! -f "${_sidecar}" ]]; then
            log_warn "[${NAME}] doctor: installed but Sidecar missing (ADR-0001 drift; re-run install/upgrade to heal)"
            _ok=1
        fi
    else
        if [[ -e "${_sidecar}" ]]; then
            log_warn "[${NAME}] doctor: Sidecar present but ${BIN_NAME} not installed (ADR-0001 drift; rm ${_sidecar} or reinstall)"
            _ok=1
        fi
    fi
    return "${_ok}"
}

# ── Private helpers ─────────────────────────────────────────────────────────

# Resolve the latest release tag and materialise the versioned asset name
# into GITHUB_ASSET_PATTERN for the archetype fetch.
_lazygit_resolve_asset_pattern() {
    local _ver=""
    if declare -F get_github_pkg_latest_version >/dev/null 2>&1; then
        get_github_pkg_latest_version _ver "${GITHUB_REPO}" || _ver=""
    fi
    if [[ -z "${_ver}" ]]; then
        log_error "[${NAME}] could not resolve latest ${GITHUB_REPO} version"
        return 1
    fi
    GITHUB_ASSET_PATTERN="lazygit_${_ver}_Linux_x86_64.tar.gz"
    _LAZYGIT_TARGET_VERSION="${_ver}"
}

# Installed version: Sidecar first (fast, offline, module_sidecar_* shared
# helpers), fall back to parsing `lazygit --version` (pre-Sidecar installs).
_lazygit_installed_version() {
    if module_sidecar_get_version "${NAME}" 2>/dev/null; then
        return 0
    fi
    local _bin="${BIN_LINK:-/usr/local/bin/${BIN_NAME}}"
    [[ -x "${_bin}" ]] || _bin="${BIN_NAME}"
    "${_bin}" --version 2>/dev/null \
        | sed -n 's/.*version=\([^,]*\),.*/\1/p' \
        || true
}

# Engine-contract assertions (also exercised by `doctor`): every metadata
# field the engine consumes post-source must be declared and well-formed.
_lazygit_metadata_selfcheck() {
    [[ -n "${DESCRIPTION[en]:-}" ]] || return 1
    [[ "${#POST_INSTALL_MESSAGE[@]}" -ge 0 ]] || return 1
    [[ "${#WARN_MESSAGE[@]}" -ge 0 ]] || return 1
    [[ "${SUPPORTS_USER_HOME}" == "true" || "${SUPPORTS_USER_HOME}" == "false" ]] || return 1
    [[ "${INSTALL_TARGET_DEFAULT}" == "sudo" || "${INSTALL_TARGET_DEFAULT}" == "user-home" || "${INSTALL_TARGET_DEFAULT}" == "auto" ]] || return 1
    return 0
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
