#!/usr/bin/env bash
# module/lazydocker.module.sh — lazydocker Docker TUI  [archetype: github-release]
#
# Migrated from module/submodule/lazydocker.sh to the v2 module contract
# (doc/module-spec.md). Upstream tarball assets embed the version in the
# file name (lazydocker_<ver>_Linux_<arch>.tar.gz), so install/upgrade
# override the archetype defaults with a version-aware fetch; the rest of
# the lifecycle comes from module_use_github_release_archetype
# (super-call pattern, doc/guide/archetype-cookbook.md).

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
NAME="lazydocker"
VERSION_PROVIDED="latest"
CATEGORY="optional"
TAGS=("cli-essentials")
HOMEPAGE="https://github.com/jesseduffield/lazydocker"
declare -gA DESCRIPTION=(
    [en]="lazydocker — terminal UI (TUI) for Docker and docker compose"
    [zh-TW]="lazydocker — Docker 與 docker compose 的終端機 TUI"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Run 'lazydocker' inside a terminal. Requires a running Docker daemon."
    [zh-TW]="在終端機執行 'lazydocker';需要 Docker daemon 正在運行。"
)
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl")
DEPENDS_ON=("docker")
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="command -v lazydocker && lazydocker --version"

# Engine consumes these metadata vars after source (lib/registry.sh /
# lib/runner.sh / module_standalone_info) — reference them here so the
# file is self-contained for static analysis.
: "${VERSION_PROVIDED}" "${CATEGORY}" "${TAGS[*]}" "${HOMEPAGE}" \
  "${DESCRIPTION[en]:-}" "${POST_INSTALL_MESSAGE[en]:-}" "${WARN_MESSAGE[en]:-}" \
  "${SUPPORTED_UBUNTU[*]}" "${SUPPORTED_PLATFORMS[*]}" "${DEPENDS_ON[*]}" \
  "${CONFLICTS_WITH[*]:-}" "${SUPPORTS_USER_HOME}" "${RISK_LEVEL}" \
  "${REBOOT_REQUIRED}" "${INSTALL_TARGET_DEFAULT}" "${TEST_VERIFY_CMD}"

# ── Archetype B — GitHub release ────────────────────────────────────────────
GITHUB_REPO="jesseduffield/lazydocker"
GITHUB_ASSET_PATTERN="lazydocker_<ver>_Linux_<arch>.tar.gz"   # resolved per release
INSTALL_DIR="/opt/lazydocker"
BIN_NAME="lazydocker"
BIN_PATH_IN_TAR="lazydocker"          # tarball has the binary at its root
BIN_LINK="/usr/local/bin/lazydocker"
STRIP_COMPONENTS=0
USE_SUDO=true
CONFIG_PATHS=("${HOME}/.config/lazydocker")
: "${GITHUB_ASSET_PATTERN}" "${BIN_PATH_IN_TAR}" "${STRIP_COMPONENTS}" "${USE_SUDO}"
module_use_github_release_archetype

# Overrides: upstream asset names embed the version, so the archetype's
# stable-URL fetch does not apply. install/upgrade use the version-aware
# fetch below and maintain the Sidecar (ADR-0001); remove/purge chain to
# the archetype defaults, then drop the Sidecar.
install() {
    module_dryrun_guard install \
        "fetch ${GITHUB_REPO} latest -> ${INSTALL_DIR}, symlink ${BIN_LINK}, write sidecar" \
        && return 0
    module_skip_if_installed && return 0
    _lazydocker_fetch_and_install || return $?
    module_sidecar_write "${NAME}" "${LAZYDOCKER_RESOLVED_VERSION:-latest}"
}

upgrade() {
    module_dryrun_guard upgrade \
        "re-download ${GITHUB_REPO} latest + refresh sidecar" \
        && return 0
    _lazydocker_fetch_and_install || return $?
    module_sidecar_write "${NAME}" "${LAZYDOCKER_RESOLVED_VERSION:-latest}"
}

remove() {
    module_dryrun_guard remove \
        "rm ${INSTALL_DIR} + ${BIN_LINK} + sidecar" \
        && return 0
    module_skip_if_not_installed && return 0
    module_default_github_release_remove || return $?
    module_sidecar_remove "${NAME}"
}

purge() {
    module_dryrun_guard purge \
        "rm ${INSTALL_DIR} + ${BIN_LINK} + CONFIG_PATHS + sidecar" \
        && return 0
    module_default_github_release_purge || return $?
    module_sidecar_remove "${NAME}"
}

# ── Hand-written hooks ──────────────────────────────────────────────────────
detect() {
    [[ "$(uname -s)" == "Linux" ]] && _lazydocker_asset_arch >/dev/null
}

is_recommended() {
    # Only meaningful next to a Docker install; lazydocker is a docker TUI.
    is_installed && return 1
    command -v docker >/dev/null 2>&1
}

is_outdated() {
    is_installed || return 1
    local _local="" _remote=""
    _local="$(module_sidecar_get_version "${NAME}" 2>/dev/null || true)"
    if declare -F get_github_pkg_latest_version >/dev/null 2>&1; then
        get_github_pkg_latest_version _remote "${GITHUB_REPO}" 2>/dev/null || true
    fi
    [[ -n "${_remote}" && "${_local}" != "${_remote}" ]]
}

doctor() {
    if ! is_installed; then
        log_warn "[${NAME}] doctor: lazydocker not installed"
        return 1
    fi
    if ! "${BIN_NAME}" --version >/dev/null 2>&1; then
        log_warn "[${NAME}] doctor: '${BIN_NAME} --version' failed"
        return 1
    fi
    if ! command -v docker >/dev/null 2>&1; then
        log_warn "[${NAME}] doctor: docker CLI not found — lazydocker needs the docker daemon"
        return 1
    fi
    log_info "[${NAME}] doctor: OK"
    return 0
}

# ── Private helpers ─────────────────────────────────────────────────────────
# Map `uname -m` to the arch token used in upstream release asset names.
_lazydocker_asset_arch() {
    case "$(uname -m)" in
        x86_64)         printf 'x86_64' ;;
        aarch64|arm64)  printf 'arm64' ;;
        armv7l)         printf 'armv7' ;;
        armv6l)         printf 'armv6' ;;
        *)              return 1 ;;
    esac
}

# Resolve latest release, download the versioned tarball, extract to
# INSTALL_DIR, symlink BIN_LINK. Sets LAZYDOCKER_RESOLVED_VERSION on success.
_lazydocker_fetch_and_install() {
    have_sudo_access 2>/dev/null \
        || { log_error "[${NAME}] sudo required to install to ${INSTALL_DIR}"; return 1; }

    local _arch=""
    _arch="$(_lazydocker_asset_arch)" \
        || { log_error "[${NAME}] unsupported architecture: $(uname -m)"; return 1; }

    local _ver=""
    get_github_pkg_latest_version _ver "${GITHUB_REPO}" \
        || { log_error "[${NAME}] cannot resolve latest ${GITHUB_REPO} release"; return 1; }
    [[ -n "${_ver}" ]] \
        || { log_error "[${NAME}] empty version from ${GITHUB_REPO} release lookup"; return 1; }

    local _asset="lazydocker_${_ver}_Linux_${_arch}.tar.gz"
    local _url="https://github.com/${GITHUB_REPO}/releases/download/v${_ver}/${_asset}"
    local _tmp=""
    _tmp="$(mktemp --suffix=.tar.gz 2>/dev/null || mktemp)"

    log_info "[${NAME}] download ${_url}"
    if ! curl -fsSL --retry 3 -o "${_tmp}" "${_url}"; then
        log_error "[${NAME}] download failed: ${_url}"
        rm -f "${_tmp}"
        return 1
    fi
    if ! file "${_tmp}" 2>/dev/null | grep -q 'gzip compressed'; then
        log_error "[${NAME}] downloaded file is not gzip: ${_tmp}"
        rm -f "${_tmp}"
        return 1
    fi

    if [[ -e "${INSTALL_DIR}" ]]; then
        if declare -F backup_file >/dev/null 2>&1; then
            backup_file "${INSTALL_DIR}" || true
        fi
        sudo rm -rf "${INSTALL_DIR}"
    fi
    sudo mkdir -p "${INSTALL_DIR}"
    sudo tar -C "${INSTALL_DIR}" --strip-components="${STRIP_COMPONENTS}" -xzf "${_tmp}"
    rm -f "${_tmp}"
    sudo ln -sfn "${INSTALL_DIR}/${BIN_PATH_IN_TAR}" "${BIN_LINK}"

    LAZYDOCKER_RESOLVED_VERSION="${_ver}"
    log_info "[${NAME}] installed ${BIN_NAME} v${_ver} -> ${BIN_LINK}"
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
