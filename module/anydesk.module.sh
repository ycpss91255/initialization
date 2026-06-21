#!/usr/bin/env bash
# module/anydesk.module.sh — AnyDesk remote desktop  [archetype: apt (vendor repo)]
#
# Migrated from module/anydesk.sh (v1 one-off keyring + sources script) to the
# v2 contract (doc/module-spec.md) on the apt archetype with a vendor repo:
# AnyDesk is not in the Ubuntu archive, so install() first wires the upstream
# signing key under /etc/apt/keyrings and the deb.anydesk.com source, then
# chains to the apt default. Desktop-only (SUPPORTED_PLATFORMS, Q49).
#
# Standalone usage:
#   bash module/anydesk.module.sh install [--dry-run]
#   bash module/anydesk.module.sh upgrade / remove / purge / verify
#   bash module/anydesk.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/anydesk.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install anydesk

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
NAME="anydesk"
VERSION_PROVIDED="apt-managed"
CATEGORY="optional"
TAGS=("remote")
HOMEPAGE="https://anydesk.com/"
declare -gA DESCRIPTION=(
    [en]="AnyDesk — remote desktop client (upstream apt repository)"
    [zh-TW]="AnyDesk — 遠端桌面用戶端(官方 apt 軟體源)"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Launch 'anydesk' from a desktop session. Configure unattended access in AnyDesk settings if you need inbound connections."
    [zh-TW]="於桌面工作階段執行 'anydesk'。若需要被動連入,請在 AnyDesk 設定中啟用無人值守存取。"
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
TEST_VERIFY_CMD="command -v anydesk && anydesk --version"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# ── Archetype A — apt (vendor repo) ─────────────────────────────────────────
APT_PKGS=("anydesk")
APT_PPA=""
CONFIG_PATHS=("${HOME}/.anydesk")
# Vendor repo wiring (legacy module/anydesk.sh, AnyDesk install docs):
ANYDESK_KEY_URL="https://keys.anydesk.com/repos/DEB-GPG-KEY"
ANYDESK_REPO_URL="https://deb.anydesk.com"
ANYDESK_KEYRING="/etc/apt/keyrings/anydesk.gpg"
ANYDESK_APT_LIST="/etc/apt/sources.list.d/anydesk.list"
module_use_apt_archetype

# Override install (super-call pattern, archetype-cookbook §A hybrid):
# wire the vendor key + source first, then chain to the apt default and
# record the version Sidecar (ADR-0001; module_sidecar_* helpers are
# dry-run-safe, the explicit guard just skips the pointless dpkg-query).
install() {
    module_dryrun_guard install \
        "anydesk vendor apt repo (${ANYDESK_REPO_URL}) + apt-install ${APT_PKGS[*]}" \
        && return 0
    module_skip_if_installed && return 0
    have_sudo_access 2>/dev/null \
        || { log_error "[${NAME}] sudo required for anydesk install"; return 1; }
    _anydesk_setup_apt_repo || return $?
    module_default_apt_install || return $?
    module_sidecar_write "${NAME}" "$(_anydesk_pkg_version)"
}

upgrade() {
    module_default_apt_upgrade || return $?
    [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]] && return 0
    module_sidecar_write "${NAME}" "$(_anydesk_pkg_version)"
}

# Override remove/purge: apt default handles packages/config, then drop
# the Sidecar — "what version is installed" is state, not user config.
# remove keeps the vendor repo wiring (re-install stays cheap); purge
# also unhooks the apt source + keyring.
remove() {
    module_default_apt_remove || return $?
    module_sidecar_remove "${NAME}"
}

purge() {
    module_default_apt_purge || return $?
    module_sidecar_remove "${NAME}"
    [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]] && return 0
    _anydesk_remove_apt_repo
}

detect() {
    command -v apt-get >/dev/null 2>&1
}

# Desktop-only recommendation gate (Q49, doc/module-spec.md §4.3.1):
# a remote desktop client is pointless on headless / SBC form factors.
is_recommended() {
    case "${INIT_UBUNTU_FORM_FACTOR:-}" in
        desktop)
            ! is_installed
            ;;
        *)
            return 1
            ;;
    esac
}

# doctor: health check — package installed, binary runnable, Sidecar present.
doctor() {
    if ! is_installed; then
        log_warn "[${NAME}] doctor: anydesk is not installed"
        return 1
    fi
    local _bin
    _bin="$(command -v anydesk 2>/dev/null)" || {
        log_warn "[${NAME}] doctor: anydesk binary not found on PATH"
        return 1
    }
    if ! "${_bin}" --version >/dev/null 2>&1; then
        log_warn "[${NAME}] doctor: ${_bin} --version failed"
        return 1
    fi
    module_sidecar_get_version "${NAME}" >/dev/null 2>&1 \
        || log_warn "[${NAME}] doctor: sidecar missing (installed outside init_ubuntu?)"
    return 0
}

# ── Private helpers ─────────────────────────────────────────────────────────

# Wire the AnyDesk signing key + apt source. Idempotent: an existing
# keyring is kept as-is (re-running install never re-downloads the key),
# and the sources line is rewritten in place.
_anydesk_setup_apt_repo() {
    log_info "[${NAME}] adding AnyDesk apt key + source"
    sudo mkdir -p "$(dirname -- "${ANYDESK_KEYRING}")"
    sudo chmod 0755 "$(dirname -- "${ANYDESK_KEYRING}")"
    if [[ ! -f "${ANYDESK_KEYRING}" ]]; then
        # gpg --dearmor runs unprivileged and streams to stdout; only the
        # keyring write needs root (sudo tee).
        if ! curl -fsSL "${ANYDESK_KEY_URL}" | gpg --dearmor \
            | sudo tee "${ANYDESK_KEYRING}" > /dev/null; then
            log_error "[${NAME}] failed to fetch/dearmor key from ${ANYDESK_KEY_URL}"
            return 1
        fi
        # _apt must be able to read the keyring, or apt fails with NO_PUBKEY.
        sudo chmod 0644 "${ANYDESK_KEYRING}"
    fi
    sudo mkdir -p "$(dirname -- "${ANYDESK_APT_LIST}")"
    printf 'deb [signed-by=%s] %s all main\n' \
        "${ANYDESK_KEYRING}" "${ANYDESK_REPO_URL}" \
        | sudo tee "${ANYDESK_APT_LIST}" > /dev/null
}

# Drop the vendor apt source + keyring (purge only). Best effort: without
# sudo we leave the files in place and keep purge's exit code at 0.
_anydesk_remove_apt_repo() {
    if ! have_sudo_access 2>/dev/null; then
        log_warn "[${NAME}] no sudo: leaving AnyDesk apt source + keyring in place"
        return 0
    fi
    log_info "[${NAME}] removing AnyDesk apt source + keyring"
    sudo rm -f "${ANYDESK_APT_LIST}" "${ANYDESK_KEYRING}"
}

# Version string for the Sidecar: dpkg-reported package version, falling
# back to the literal "apt-managed" when dpkg has no answer.
_anydesk_pkg_version() {
    local _ver=""
    _ver="$(dpkg-query -W -f='${Version}' anydesk 2>/dev/null)" || _ver=""
    printf '%s' "${_ver:-apt-managed}"
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
