#!/usr/bin/env bash
# shellcheck disable=SC2034  # module metadata vars (NAME / DESCRIPTION / CATEGORY / TAGS / ...) consumed by engine post-source — https://www.shellcheck.net/wiki/SC2034
# module/batcat.module.sh — bat: cat clone with syntax highlighting  [archetype: apt]
#
# Migrated from module/submodule/batcat.sh (v1, GitHub-release tarball) to
# the v2 contract (doc/module-spec.md) on the apt archetype: Ubuntu ships
# the `bat` package in universe, but installs the binary as `batcat`
# (name clash with bacula's `bat`). The module therefore:
#   - apt-installs the `bat` package (archetype A skeleton)
#   - appends guarded `alias cat='batcat'` / `alias bat='batcat'` lines to
#     existing ~/.bashrc / ~/.zshrc (the issue #1 bug class: the alias
#     target must match the real binary — batcat — see the unit spec)
#   - writes/removes the version Sidecar per ADR-0001 (standalone never
#     touches state.json)
#
# Standalone usage:
#   bash module/batcat.module.sh install [--dry-run]
#   bash module/batcat.module.sh upgrade / remove / purge / verify / doctor
#   bash module/batcat.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/batcat.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install batcat

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
NAME="batcat"
VERSION_PROVIDED="apt-managed"
CATEGORY="optional"
TAGS=("cli-essentials")
HOMEPAGE="https://github.com/sharkdp/bat"
declare -gA DESCRIPTION=(
    [en]="bat — cat clone with syntax highlighting (Ubuntu binary: batcat)"
    [zh-TW]="bat — 帶語法上色的 cat 替代品(Ubuntu 執行檔名為 batcat)"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Open a new shell (or 'source ~/.bashrc') to pick up the cat/bat aliases."
    [zh-TW]="開新 shell(或執行 'source ~/.bashrc')以啟用 cat/bat alias。"
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
TEST_VERIFY_CMD="command -v batcat && batcat --version"
# install() appends alias lines to ~/.bashrc / ~/.zshrc — legacy dotfiles
# whose paths cannot move under ~/.config (doc/module-spec.md §6.1).
LEGACY_DOTFILE=true

# ── Archetype A — apt ───────────────────────────────────────────────────────
APT_PKGS=(bat)
APT_PPA=""
CONFIG_PATHS=("${HOME}/.config/bat")
module_use_apt_archetype

# Alias lines appended to shell rc files. The apt package is `bat` but the
# Ubuntu binary is `batcat` — both the `command -v` guard and the alias
# TARGET must say batcat (issue #1 copy-paste bug class). The trailing
# marker lets purge strip exactly these lines.
_BATCAT_ALIAS_LINES=(
    "command -v batcat >/dev/null 2>&1 && alias cat='batcat'  # init_ubuntu:batcat"
    "command -v batcat >/dev/null 2>&1 && alias bat='batcat'  # init_ubuntu:batcat"
)

# Override install: archetype apt-installs, then drop aliases + Sidecar.
install() {
    module_default_apt_install || return $?
    module_dryrun_guard install "append cat/bat aliases to shell rc files + write sidecar" \
        && return 0
    _batcat_add_aliases
    module_sidecar_write "${NAME}" "$(_batcat_pkg_version)"
}

# Override upgrade: archetype upgrades, then refresh the Sidecar version.
upgrade() {
    module_default_apt_upgrade || return $?
    module_dryrun_guard upgrade "refresh sidecar version" && return 0
    module_sidecar_write "${NAME}" "$(_batcat_pkg_version)"
}

# Override remove: apt-remove keeps user config (alias lines stay — they
# are guarded by `command -v batcat`), but the Sidecar is state, not
# config, so it goes (doc/module-spec.md §4.7.4).
remove() {
    module_default_apt_remove || return $?
    [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]] && return 0
    module_sidecar_remove "${NAME}"
}

# Override purge: archetype purges pkg + CONFIG_PATHS, then strip the
# alias lines and drop the Sidecar.
purge() {
    module_default_apt_purge || return $?
    [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]] && return 0
    _batcat_remove_aliases
    module_sidecar_remove "${NAME}"
}

detect() {
    command -v apt-get >/dev/null 2>&1
}

is_recommended() {
    ! is_installed
}

# doctor: health check — package installed, binary runnable, Sidecar present.
doctor() {
    if ! is_installed; then
        log_warn "[${NAME}] doctor: bat package is not installed"
        return 1
    fi
    if ! command -v batcat >/dev/null 2>&1; then
        log_warn "[${NAME}] doctor: batcat binary not found on PATH"
        return 1
    fi
    if ! batcat --version >/dev/null 2>&1; then
        log_warn "[${NAME}] doctor: batcat --version failed"
        return 1
    fi
    [[ -f "$(module_sidecar_path "${NAME}")" ]] \
        || log_warn "[${NAME}] doctor: sidecar missing (installed outside init_ubuntu?)"
    return 0
}

# ── Private helpers ─────────────────────────────────────────────────────────

# Installed package version from dpkg; falls back to the metadata default
# when dpkg has no record (e.g. mocked install in tests).
_batcat_pkg_version() {
    local _ver
    _ver="$(dpkg-query -W -f='${Version}' bat 2>/dev/null || true)"
    printf '%s' "${_ver:-apt-managed}"
}

# Append the guarded alias lines to every EXISTING shell rc file; never
# creates rc files, never duplicates lines (idempotent).
_batcat_add_aliases() {
    local _rc _line
    for _rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
        [[ -f "${_rc}" ]] || continue
        for _line in "${_BATCAT_ALIAS_LINES[@]}"; do
            if ! grep -qF "${_line}" "${_rc}"; then
                printf '%s\n' "${_line}" >> "${_rc}"
                log_info "[${NAME}] added alias to ${_rc}: ${_line%%  #*}"
            fi
        done
    done
    return 0
}

# Strip exactly the marked alias lines from the rc files (purge).
_batcat_remove_aliases() {
    local _rc
    for _rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
        [[ -f "${_rc}" ]] || continue
        sed -i '/# init_ubuntu:batcat$/d' "${_rc}"
        log_info "[${NAME}] removed managed alias lines from ${_rc}"
    done
    return 0
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
