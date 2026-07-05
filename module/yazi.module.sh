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

# Override install/upgrade: the archetype fetch only understands gzip
# tarballs, while yazi ships a zip — swap in the zip-aware fetch, then add
# the legacy `alias yz='yazi'` drop. The phase-invocation wrapper writes the
# Sidecar via module_provided_version (overridden below to report the parsed
# binary version, since yazi's zip asset is version-less).
module_provided_version() { _yazi_local_version; }

install() {
    module_dryrun_guard install \
        "fetch ${GITHUB_REPO} latest zip -> ${INSTALL_DIR}, symlink ${BIN_LINK}, append yz alias" \
        && return 0
    module_skip_if_installed && return 0
    _yazi_fetch_and_install || return $?
    _yazi_add_alias
}

upgrade() {
    module_dryrun_guard upgrade "force re-download ${GITHUB_REPO} latest zip" \
        && return 0
    _yazi_fetch_and_install || return $?
    _yazi_add_alias
}

# remove keeps user config (the rc alias survives a remove; spec §4.1);
# inherit the macro default (the wrapper removes the Sidecar).

# purge also strips the alias lines from ~/.bashrc / ~/.zshrc.
purge() {
    module_default_github_release_purge || return $?
    [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]] && return 0
    _yazi_remove_alias
}

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
        log_warn "[${NAME}] doctor: Sidecar missing (ADR-0001 drift; re-run install/upgrade to heal)"
    fi
    return 0
}

# ── Private helpers ─────────────────────────────────────────────────────────

# Guarded alias line; the legacy issue #1 copy-paste aliased cat — the
# alias must target yazi itself (yz='yazi').
YAZI_ALIAS_LINE="command -v yazi &>/dev/null && alias yz='yazi'"

# Zip-aware fetch: download the release zip, validate, extract into
# INSTALL_DIR, flatten the single top-level dir, symlink BIN_LINK.
_yazi_fetch_and_install() {
    : "${GITHUB_REPO:?[${NAME:-?}] GITHUB_REPO required}"
    : "${GITHUB_ASSET_PATTERN:?[${NAME:-?}] GITHUB_ASSET_PATTERN required}"
    : "${INSTALL_DIR:?[${NAME:-?}] INSTALL_DIR required}"
    local _bin_link="${BIN_LINK:-/usr/local/bin/${BIN_NAME:-yazi}}"
    local _sudo=""
    [[ "${USE_SUDO:-true}" == "true" ]] && _sudo="sudo"

    if ! command -v unzip >/dev/null 2>&1; then
        log_error "[${NAME}] 'unzip' is required to install yazi (sudo apt-get install unzip)"
        return 1
    fi

    local _ver=""
    if declare -F get_github_pkg_latest_version >/dev/null 2>&1; then
        get_github_pkg_latest_version _ver "${GITHUB_REPO}" \
            || log_warn "[${NAME}] could not detect latest version (continuing)"
    fi
    [[ -n "${_ver}" ]] && log_info "[${NAME}] target: ${GITHUB_REPO} v${_ver}"

    local _url _tmp
    _url="https://github.com/${GITHUB_REPO}/releases/latest/download/${GITHUB_ASSET_PATTERN}"
    _tmp="$(mktemp 2>/dev/null || printf '/tmp/%s-%s' "${NAME}" "$$")"
    log_info "[${NAME}] download ${_url}"
    if ! curl -fsSL --retry 3 -o "${_tmp}" "${_url}"; then
        log_error "[${NAME}] download failed: ${_url}"
        rm -f "${_tmp}"
        return 1
    fi
    # Magic-byte check (zip = "PK"); dependency-free unlike file(1).
    if [[ "$(head -c2 "${_tmp}" 2>/dev/null)" != "PK" ]]; then
        log_error "[${NAME}] downloaded file is not a zip archive: ${_tmp}"
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
    # SR-02: traversal-guarded unzip (shared helper rejects '..'/absolute members).
    if ! _module_safe_unzip_extract "${_tmp}" "${INSTALL_DIR}" "${_sudo}"; then
        log_error "[${NAME}] unzip failed for ${_tmp}"
        rm -f "${_tmp}"
        return 1
    fi
    rm -f "${_tmp}"
    # The zip extracts to a single top-level dir named after the asset base
    # (yazi-x86_64-unknown-linux-gnu/) — flatten it into INSTALL_DIR.
    local _top="${INSTALL_DIR}/${GITHUB_ASSET_PATTERN%.zip}"
    if [[ -d "${_top}" ]]; then
        ${_sudo} sh -c "mv '${_top}'/* '${INSTALL_DIR}/' && rmdir '${_top}'"
    fi
    ${_sudo} ln -sfn "${INSTALL_DIR}/${BIN_NAME}" "${_bin_link}"
    log_info "[${NAME}] installed ${BIN_NAME}${_ver:+ v${_ver}} -> ${_bin_link}"
}

# Append the guarded alias line to every EXISTING shell rc file; never
# create rc files that the user does not have.
_yazi_add_alias() {
    local _shell _rc
    for _shell in bash zsh; do
        _rc="${HOME}/.${_shell}rc"
        [[ -f "${_rc}" ]] || continue
        grep -qF "${YAZI_ALIAS_LINE}" "${_rc}" && continue
        printf '%s\n' "${YAZI_ALIAS_LINE}" >> "${_rc}"
        log_info "[${NAME}] added yz alias to ${_rc}"
    done
    return 0
}

# Strip exactly the managed alias line from the rc files (purge).
_yazi_remove_alias() {
    local _shell _rc
    for _shell in bash zsh; do
        _rc="${HOME}/.${_shell}rc"
        [[ -f "${_rc}" ]] || continue
        grep -qF "${YAZI_ALIAS_LINE}" "${_rc}" || continue
        grep -vF "${YAZI_ALIAS_LINE}" "${_rc}" > "${_rc}.yazi-tmp" || true
        mv "${_rc}.yazi-tmp" "${_rc}"
        log_info "[${NAME}] removed yz alias from ${_rc}"
    done
    return 0
}

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

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
