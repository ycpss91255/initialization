#!/usr/bin/env bash
# shellcheck disable=SC2034  # module metadata vars (NAME / DESCRIPTION / CATEGORY / TAGS / ...) consumed by engine post-source — https://www.shellcheck.net/wiki/SC2034
# module/eza.module.sh — eza, a modern `ls` replacement  [archetype: github-release]
#
# Migrated from module/submodule/eza.sh (issue #51, PRD §6.3.1 Batch B).
# Legacy installed the GitHub release tarball to /opt/eza, symlinked
# /usr/local/bin/eza, and appended `alias ls='eza'` to ~/.bashrc / ~/.zshrc.
# This module keeps that behavior on top of the github-release archetype
# (super-call pattern) and adds Sidecar bookkeeping per ADR-0001.
#
# Standalone usage:
#   bash module/eza.module.sh install [--dry-run]
#   bash module/eza.module.sh upgrade / remove / purge / verify / doctor
#   bash module/eza.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/eza.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install eza

# ── BEGIN: shared-bootstrap ─────────────────────────────────────────────────
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
# ── END: shared-bootstrap ───────────────────────────────────────────────────

# ── BEGIN: shared-metadata ──────────────────────────────────────────────────
NAME="eza"
VERSION_PROVIDED="latest"
CATEGORY="optional"
TAGS=("cli-essentials")
HOMEPAGE="https://github.com/eza-community/eza"

declare -gA DESCRIPTION=(
    [en]="Modern ls replacement (eza) + shell alias ls='eza'"
    [zh-TW]="現代化 ls 替代工具(eza)+ shell alias ls='eza'"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="alias ls='eza' appended to ~/.bashrc / ~/.zshrc — re-source your rc or restart the shell."
    [zh-TW]="已將 alias ls='eza' 加入 ~/.bashrc / ~/.zshrc — 請重新 source rc 或重啟 shell。"
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

TEST_VERIFY_CMD="command -v eza && eza --version"
# ── END: shared-metadata ────────────────────────────────────────────────────

# ── BEGIN: archetype-data ───────────────────────────────────────────────────
# Archetype B: GitHub-release tarball (matches the legacy install method).
GITHUB_REPO="eza-community/eza"
GITHUB_ASSET_PATTERN="eza_x86_64-unknown-linux-gnu.tar.gz"
INSTALL_DIR="/opt/eza"
BIN_NAME="eza"
BIN_PATH_IN_TAR="eza"          # tarball ships the binary at archive root
BIN_LINK="/usr/local/bin/eza"
STRIP_COMPONENTS=1             # strips the leading "./" (same as legacy)
USE_SUDO=true
CONFIG_PATHS=()                # alias lines are cleaned by purge() below
module_use_github_release_archetype
# ── END: archetype-data ─────────────────────────────────────────────────────

# Super-call overrides: archetype handles the binary; we add the legacy
# `alias ls='eza'` drop. The phase-invocation wrapper writes the Sidecar via
# module_provided_version (overridden below to report the parsed binary
# version, since eza has no version-bearing resolver var).
module_provided_version() { _eza_local_version; }

install() {
    module_default_github_release_install || return $?
    [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]] && return 0
    _eza_add_ls_alias
}

upgrade() {
    module_default_github_release_upgrade || return $?
    [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]] && return 0
    _eza_add_ls_alias
}

# remove keeps user config (the rc alias survives a remove; spec §4.1);
# inherit the macro default (the wrapper removes the Sidecar).

# purge also strips the alias lines from ~/.bashrc / ~/.zshrc.
purge() {
    module_default_github_release_purge || return $?
    [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]] && return 0
    _eza_remove_ls_alias
}

# detect: the wired asset is the x86_64 gnu tarball — only offer it there.
detect() {
    [[ "$(uname -m)" == "x86_64" ]]
}

# is_recommended: cli-essentials are strongly recommended when missing.
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
        log_warn "[${NAME}] doctor: eza is not installed"
        return 1
    fi
    if ! _eza_run_bin --version >/dev/null 2>&1; then
        log_warn "[${NAME}] doctor: eza is present but not runnable"
        return 1
    fi
    if ! module_sidecar_get_version "${NAME}" >/dev/null 2>&1; then
        log_warn "[${NAME}] doctor: Sidecar missing (ADR-0001 drift; re-run install/upgrade to heal)"
    fi
    return 0
}

# ── Private helpers ─────────────────────────────────────────────────────────
EZA_ALIAS_LINE="command -v eza &>/dev/null && alias ls='eza'"

# Run the installed binary: prefer BIN_LINK, fall back to PATH lookup.
_eza_run_bin() {
    local _bin="${BIN_LINK:-/usr/local/bin/eza}"
    [[ -x "${_bin}" ]] || _bin="${BIN_NAME:-eza}"
    "${_bin}" "$@"
}

_eza_local_version() {
    local _v=""
    _v="$(_eza_run_bin --version 2>/dev/null \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)" || true
    printf '%s' "${_v:-unknown}"
}

_eza_add_ls_alias() {
    local _shell _rc
    for _shell in bash zsh; do
        _rc="${HOME}/.${_shell}rc"
        [[ -f "${_rc}" ]] || continue
        grep -qF "${EZA_ALIAS_LINE}" "${_rc}" && continue
        printf '%s\n' "${EZA_ALIAS_LINE}" >> "${_rc}"
        log_info "[${NAME}] added ls alias to ${_rc}"
    done
    return 0
}

_eza_remove_ls_alias() {
    local _shell _rc
    for _shell in bash zsh; do
        _rc="${HOME}/.${_shell}rc"
        [[ -f "${_rc}" ]] || continue
        grep -qF "${EZA_ALIAS_LINE}" "${_rc}" || continue
        grep -vF "${EZA_ALIAS_LINE}" "${_rc}" > "${_rc}.eza-tmp" || true
        mv "${_rc}.eza-tmp" "${_rc}"
        log_info "[${NAME}] removed ls alias from ${_rc}"
    done
    return 0
}

# ── BEGIN: shared-footer ────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
# ── END: shared-footer ──────────────────────────────────────────────────────
