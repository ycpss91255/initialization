#!/usr/bin/env bash
# module/notion.module.sh — Notion desktop app (GitHub release archetype, .deb)
#
# New module (issue #65, PRD §6.3.3 Batch C, Q50 / #35). Replaces the legacy
# small-tools snap path (the snap is broken on 24.04). Upstream is the
# unofficial notion-electron client (anechunaev/notion-electron) which ships
# versioned .deb assets (Notion_Electron-<ver>-{amd64,arm64}.deb), so
# install/upgrade resolve the latest tag first, download the .deb, and hand
# it to `apt-get install ./<deb>` (apt resolves the package's dependencies,
# unlike dpkg -i). Sidecar lifecycle per ADR-0001 / module-spec §4.7.4:
# written on install/upgrade success, deleted on remove/purge; state.json is
# engine-only.

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
NAME="notion"
VERSION_PROVIDED="latest"
CATEGORY="optional"
TAGS=("notes")
HOMEPAGE="https://github.com/anechunaev/notion-electron"
declare -gA DESCRIPTION=(
    [en]="Notion desktop app (unofficial notion-electron .deb client)"
    [zh-TW]="Notion 桌面版(非官方 notion-electron .deb 客戶端)"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Launch 'notion-electron' from your app menu and sign in to your Notion workspace."
    [zh-TW]="從應用程式選單啟動 'notion-electron' 並登入你的 Notion 工作區。"
)
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop")
DEPENDS_ON=("curl")
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="dpkg -l notion-electron | grep -q '^ii'"

# ── Archetype B — GitHub release (consuming a .deb) ─────────────────────────
GITHUB_REPO="anechunaev/notion-electron"
# Asset name is version- and arch-dependent; resolved at run time by
# _notion_resolve_asset_pattern (placeholder keeps the archetype data
# contract complete for `info` / dry-run output).
GITHUB_ASSET_PATTERN="Notion_Electron-<latest>-<amd64|arm64>.deb"
# dpkg package name inside the .deb (electron-builder uses the npm name).
NOTION_DEB_PKG="notion-electron"
CONFIG_PATHS=(
    "${HOME}/.config/notion-electron"
)
module_use_github_release_archetype

# The archetype default lifecycle handles tarball-into-/opt installs; a .deb
# is owned by dpkg instead, so override everything except verify
# (module_default_verify = is_installed + TEST_VERIFY_CMD still applies).
is_installed() {
    dpkg -l "${NOTION_DEB_PKG}" 2>/dev/null | grep -q '^ii'
}

install() {
    module_dryrun_guard install \
        "download ${GITHUB_REPO} latest .deb -> apt-get install" \
        && return 0
    module_skip_if_installed && return 0
    _notion_resolve_asset_pattern || return $?
    _notion_fetch_and_install_deb || return $?
    module_sidecar_write "${NAME}" "${_NOTION_TARGET_VERSION:-unknown}"
}

upgrade() {
    module_dryrun_guard upgrade \
        "re-download ${GITHUB_REPO} latest .deb -> apt-get install" \
        && return 0
    _notion_resolve_asset_pattern || return $?
    _notion_fetch_and_install_deb || return $?
    module_sidecar_write "${NAME}" "${_NOTION_TARGET_VERSION:-unknown}"
}

remove() {
    module_dryrun_guard remove \
        "apt-get remove ${NOTION_DEB_PKG} + Sidecar" \
        && return 0
    _notion_pkg_remove remove || return $?
    module_sidecar_remove "${NAME}"
}

purge() {
    module_dryrun_guard purge \
        "apt-get purge ${NOTION_DEB_PKG} + Sidecar + CONFIG_PATHS" \
        && return 0
    _notion_pkg_remove purge || return $?
    local _p
    for _p in "${CONFIG_PATHS[@]:-}"; do
        [[ -n "${_p}" ]] || continue
        rm -rf "${_p}"
    done
    module_sidecar_remove "${NAME}"
}

detect() {
    # Needs apt to consume the .deb and an arch upstream actually ships.
    command -v apt-get >/dev/null 2>&1 || return 1
    _notion_deb_arch >/dev/null
}

is_recommended() {
    # Desktop-only GUI app (Q50): never pre-tick on non-desktop form factors.
    case "${INIT_UBUNTU_FORM_FACTOR:-desktop}" in
        desktop) ! is_installed ;;
        *) return 1 ;;
    esac
}

# is_outdated — compare Sidecar (or dpkg-reported) version against the
# latest GitHub release tag (doc/guide/archetype-cookbook.md, Archetype B).
is_outdated() {
    is_installed || return 1
    local _local="" _remote=""
    _local="$(_notion_installed_version)" || _local=""
    if declare -F get_github_pkg_latest_version >/dev/null 2>&1; then
        get_github_pkg_latest_version _remote "${GITHUB_REPO}" 2>/dev/null \
            || _remote=""
    fi
    _remote="$(_notion_normalize_version "${_remote}")"
    [[ -n "${_remote}" && "${_local}" != "${_remote}" ]]
}

# doctor — metadata contract self-check + Sidecar invariant
# (module-spec §4.7.4: is_installed ⟷ Sidecar exists).
doctor() {
    local _ok=0
    if ! _notion_metadata_selfcheck; then
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
            log_warn "[${NAME}] doctor: Sidecar present but ${NOTION_DEB_PKG} not installed (ADR-0001 drift; rm ${_sidecar} or reinstall)"
            _ok=1
        fi
    fi
    return "${_ok}"
}

# ── Private helpers ─────────────────────────────────────────────────────────

# Map uname -m to the Debian arch suffix upstream uses in its asset names.
_notion_deb_arch() {
    case "$(uname -m)" in
        x86_64)  printf 'amd64' ;;
        aarch64) printf 'arm64' ;;
        *) return 1 ;;
    esac
}

# Strip the upstream tag decoration (v2.1.0 -> 2.1.0).
_notion_normalize_version() {
    printf '%s' "${1#v}"
}

# Resolve the latest release tag and materialise the versioned, arch-specific
# .deb asset name into GITHUB_ASSET_PATTERN for the fetch.
_notion_resolve_asset_pattern() {
    local _arch _ver=""
    if ! _arch="$(_notion_deb_arch)"; then
        log_error "[${NAME}] unsupported architecture: $(uname -m)"
        return 1
    fi
    if declare -F get_github_pkg_latest_version >/dev/null 2>&1; then
        get_github_pkg_latest_version _ver "${GITHUB_REPO}" 2>/dev/null \
            || _ver=""
    fi
    _ver="$(_notion_normalize_version "${_ver}")"
    if [[ -z "${_ver}" ]]; then
        log_error "[${NAME}] could not resolve latest ${GITHUB_REPO} version"
        return 1
    fi
    GITHUB_ASSET_PATTERN="Notion_Electron-${_ver}-${_arch}.deb"
    _NOTION_TARGET_VERSION="${_ver}"
}

# Download the resolved .deb asset and apt-install it. apt (not dpkg -i)
# pulls the .deb's dependencies from the archive in the same transaction.
_notion_fetch_and_install_deb() {
    : "${GITHUB_REPO:?[${NAME}] GITHUB_REPO required}"
    : "${GITHUB_ASSET_PATTERN:?[${NAME}] GITHUB_ASSET_PATTERN required}"
    if ! have_sudo_access 2>/dev/null; then
        log_warn "[${NAME}] no sudo: cannot apt-get install the .deb"
        return 1
    fi
    local _url="https://github.com/${GITHUB_REPO}/releases/latest/download/${GITHUB_ASSET_PATTERN}"
    local _tmp
    _tmp="$(mktemp -d)" || return 1
    local _deb="${_tmp}/${GITHUB_ASSET_PATTERN}"
    log_info "[${NAME}] download ${_url}"
    if ! curl -fsSL --retry 3 -o "${_deb}" "${_url}"; then
        log_error "[${NAME}] download failed: ${_url}"
        rm -rf "${_tmp}"
        return 1
    fi
    if ! sudo apt-get install -y "${_deb}"; then
        log_error "[${NAME}] apt-get install ${GITHUB_ASSET_PATTERN} failed"
        rm -rf "${_tmp}"
        return 1
    fi
    rm -rf "${_tmp}"
}

# Remove/purge the dpkg-owned package. Tolerant on a clean system so
# remove/purge stay idempotent (module-spec: remove() MUST be idempotent).
_notion_pkg_remove() {
    local _mode="${1:-remove}"
    module_skip_if_not_installed && return 0
    if ! have_sudo_access 2>/dev/null; then
        log_warn "[${NAME}] no sudo: cannot ${_mode} ${NOTION_DEB_PKG}"
        return 1
    fi
    sudo apt-get "${_mode}" -y "${NOTION_DEB_PKG}" || true
}

# Installed version: Sidecar first (fast, offline, module_sidecar_* shared
# helpers), fall back to the dpkg-recorded version (pre-Sidecar installs).
_notion_installed_version() {
    if module_sidecar_get_version "${NAME}" 2>/dev/null; then
        return 0
    fi
    dpkg-query -W -f '${Version}' "${NOTION_DEB_PKG}" 2>/dev/null || true
}

# Engine-contract assertions (also exercised by `doctor`): every metadata
# field the engine consumes post-source must be declared and well-formed.
_notion_metadata_selfcheck() {
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
