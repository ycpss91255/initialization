#!/usr/bin/env bash
# shellcheck disable=SC2034  # module metadata vars (NAME / DESCRIPTION / CATEGORY / TAGS / ...) consumed by engine post-source — https://www.shellcheck.net/wiki/SC2034
# module/fzf.module.sh — fzf command-line fuzzy finder  [archetype: github-release]
#
# Migrated from module/submodule/fzf.sh (v1) to the v2 contract
# (doc/module-spec.md). Upstream ships prebuilt single-binary tarballs per
# release (e.g. fzf-0.73.1-linux_amd64.tar.gz), so the asset name is
# version- and arch-dependent — install/upgrade override the archetype
# default fetch to resolve the latest tag first (super-call pattern,
# doc/guide/archetype-cookbook.md §B).
#
# Standalone usage:
#   bash module/fzf.module.sh install [--dry-run]
#   bash module/fzf.module.sh upgrade / remove / purge / verify
#   bash module/fzf.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/fzf.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install fzf

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

# ── Metadata ────────────────────────────────────────────────────────────────
NAME="fzf"
VERSION_PROVIDED="latest"
CATEGORY="optional"
TAGS=("cli-essentials")
HOMEPAGE="https://github.com/junegunn/fzf"
declare -gA DESCRIPTION=(
    [en]="fzf command-line fuzzy finder (single-binary GitHub release)"
    [zh-TW]="fzf 命令列模糊搜尋工具(GitHub release 單一執行檔)"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Shell key bindings (CTRL-T / CTRL-R / ALT-C) need 'eval \"\$(fzf --bash)\"' (or --zsh/--fish) in your shell rc."
    [zh-TW]="Shell 快捷鍵(CTRL-T / CTRL-R / ALT-C)需在 shell rc 加入 'eval \"\$(fzf --bash)\"'(或 --zsh/--fish)。"
)
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl")
DEPENDS_ON=("apt-essentials")
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="command -v fzf && fzf --version"

# ── Archetype B — GitHub release ────────────────────────────────────────────
GITHUB_REPO="junegunn/fzf"
# Real asset name is versioned (fzf-<ver>-linux_<arch>.tar.gz); resolved at
# fetch time by _fzf_fetch_and_install. Kept for metadata/debug display.
GITHUB_ASSET_PATTERN="fzf-<version>-linux_<arch>.tar.gz"
INSTALL_DIR="/opt/fzf"
BIN_NAME="fzf"
BIN_PATH_IN_TAR="fzf"          # tarball contains the bare binary at its root
BIN_LINK="/usr/local/bin/fzf"
STRIP_COMPONENTS=0
USE_SUDO=true
CONFIG_PATHS=("${HOME}/.fzf")  # legacy v1 git-clone install dir
module_use_github_release_archetype

# Override install/upgrade: resolve latest tag, download the versioned
# asset, then record the Sidecar (ADR-0001) on success.
install() {
    module_dryrun_guard install \
        "fetch ${GITHUB_REPO} latest -> ${INSTALL_DIR}, symlink ${BIN_LINK}, write sidecar" \
        && return 0
    module_skip_if_installed && return 0
    _fzf_fetch_and_install || return $?
    _fzf_sidecar_write "${FZF_RESOLVED_VERSION:-unknown}"
}

upgrade() {
    module_dryrun_guard upgrade "re-download ${GITHUB_REPO} latest, refresh sidecar" \
        && return 0
    _fzf_fetch_and_install || return $?
    _fzf_sidecar_write "${FZF_RESOLVED_VERSION:-unknown}"
}

# Override remove/purge: archetype handles files, then drop the Sidecar.
remove() {
    module_default_github_release_remove || return $?
    [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]] && return 0
    _fzf_sidecar_remove
}

purge() {
    module_default_github_release_purge || return $?
    [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]] && return 0
    _fzf_sidecar_remove
}

detect() {
    _fzf_arch >/dev/null 2>&1
}

is_recommended() {
    ! is_installed
}

# is_outdated: compare the Sidecar version against the latest release tag.
# No Sidecar (not installed, or installed outside init_ubuntu) = not outdated.
is_outdated() {
    local _sidecar _local _remote
    _sidecar="$(_fzf_sidecar_path)"
    [[ -f "${_sidecar}" ]] || return 1
    _local="$(tr -d '[:space:]' < "${_sidecar}")"
    _remote="$(
        _v=""
        get_github_pkg_latest_version _v "${GITHUB_REPO}" 2>/dev/null || true
        printf '%s' "${_v:-}"
    )"
    [[ -n "${_remote}" && "${_local}" != "${_remote}" ]]
}

# doctor: health check — binary present, runnable, Sidecar consistent.
doctor() {
    if ! is_installed; then
        log_warn "[${NAME}] doctor: fzf is not installed"
        return 1
    fi
    local _bin="${BIN_LINK:-/usr/local/bin/fzf}"
    [[ -x "${_bin}" ]] || _bin="$(command -v "${BIN_NAME}" 2>/dev/null)" || {
        log_warn "[${NAME}] doctor: fzf binary not found on PATH"
        return 1
    }
    if ! "${_bin}" --version >/dev/null 2>&1; then
        log_warn "[${NAME}] doctor: ${_bin} --version failed"
        return 1
    fi
    [[ -f "$(_fzf_sidecar_path)" ]] \
        || log_warn "[${NAME}] doctor: sidecar missing (installed outside init_ubuntu?)"
    return 0
}

# ── Private helpers ─────────────────────────────────────────────────────────

# Map `uname -m` to fzf's release asset arch suffix.
_fzf_arch() {
    case "$(uname -m)" in
        x86_64)         printf 'amd64' ;;
        aarch64|arm64)  printf 'arm64' ;;
        armv7l)         printf 'armv7' ;;
        *)              return 1 ;;
    esac
}

# Sidecar path per ADR-0001: ${XDG_STATE_HOME}/init_ubuntu/versions/<name>.
# Honors INIT_UBUNTU_STATE_DIR (engine/test override), like lib/state.sh.
_fzf_sidecar_path() {
    local _dir="${INIT_UBUNTU_STATE_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/init_ubuntu}"
    printf '%s/versions/%s' "${_dir}" "${NAME}"
}

_fzf_sidecar_write() {
    local _ver="${1:-unknown}"
    local _path; _path="$(_fzf_sidecar_path)"
    mkdir -p "${_path%/*}"
    printf '%s\n' "${_ver}" > "${_path}"
    log_info "[${NAME}] sidecar: ${_path} = ${_ver}"
}

_fzf_sidecar_remove() {
    rm -f "$(_fzf_sidecar_path)"
    return 0
}

# Resolve the latest release tag, download the versioned tarball, extract
# the single binary to INSTALL_DIR and symlink BIN_LINK. Exports the
# resolved version via FZF_RESOLVED_VERSION for the Sidecar write.
_fzf_fetch_and_install() {
    local _arch _ver _tmp _url
    _arch="$(_fzf_arch)" || {
        log_error "[${NAME}] unsupported architecture: $(uname -m)"
        return 1
    }
    # Subshell capture: get_github_pkg_latest_version may log_fatal (exit)
    # on API failure — contain it so engine mode survives (spec §4.7.1).
    _ver="$(
        _v=""
        get_github_pkg_latest_version _v "${GITHUB_REPO}" 2>/dev/null || true
        printf '%s' "${_v:-}"
    )"
    [[ -n "${_ver}" ]] || {
        log_error "[${NAME}] could not resolve latest ${GITHUB_REPO} release"
        return 1
    }
    # Tag carries a leading v (v0.73.1); asset name uses the bare version.
    _url="https://github.com/${GITHUB_REPO}/releases/download/v${_ver}/fzf-${_ver}-linux_${_arch}.tar.gz"

    local _sudo=""
    [[ "${USE_SUDO:-true}" == "true" ]] && _sudo="sudo"

    _tmp="$(mktemp 2>/dev/null || printf '/tmp/%s-%s.tar.gz' "${NAME}" "$$")"
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
        ${_sudo} rm -rf "${INSTALL_DIR}"
    fi
    ${_sudo} mkdir -p "${INSTALL_DIR}"
    ${_sudo} tar -C "${INSTALL_DIR}" -xzf "${_tmp}"
    rm -f "${_tmp}"
    ${_sudo} ln -sfn "${INSTALL_DIR}/${BIN_PATH_IN_TAR}" "${BIN_LINK}"
    FZF_RESOLVED_VERSION="${_ver}"
    log_info "[${NAME}] installed fzf v${_ver} -> ${BIN_LINK}"
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
