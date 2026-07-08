#!/usr/bin/env bash
# shellcheck disable=SC2034  # module metadata vars (NAME / DESCRIPTION / CATEGORY / TAGS / ...) consumed by engine post-source — https://www.shellcheck.net/wiki/SC2034
# module/nas-mount.module.sh — CIFS/SMB NAS auto-mount (cifs-utils + autofs)  [archetype: custom (hand-written)]
#
# Installs the SMB/CIFS mount driver (cifs-utils), the on-demand automounter
# (autofs), and the discovery/check tool (smbclient). When the site-specific
# NAS parameters are provided via environment (never hardcoded in the repo),
# install() also wires an autofs indirect map so the share mounts on access.
#
# Configuration is read at RUNTIME from environment variables so no personal
# host / user / credential ever lands in version control:
#
#   INIT_UBUNTU_NAS_HOST         NAS hostname or IP (e.g. 192.168.1.10)
#   INIT_UBUNTU_NAS_SHARE        SMB share name (e.g. media)
#   INIT_UBUNTU_NAS_USER         SMB username
#   INIT_UBUNTU_NAS_PASSWORD     SMB password (optional; used only to GENERATE
#                                the credentials file when it does not exist)
#   INIT_UBUNTU_NAS_MOUNT_BASE   autofs base dir (default: /mnt/nas)
#   INIT_UBUNTU_NAS_CREDENTIALS  credentials file path
#                                (default: /etc/init_ubuntu/nas-mount/credentials)
#
# The credentials file is kept out of the repo and forced to chmod 600. If it
# already exists it is reused as-is (bring-your-own credentials / keyring). If
# it is missing and INIT_UBUNTU_NAS_PASSWORD is set, the module generates it.
# When the NAS parameters are absent, install() still installs the packages
# and prints a hint — the automounter is left un-wired.
#
# Standalone usage:
#   bash module/nas-mount.module.sh install [--dry-run]
#   bash module/nas-mount.module.sh upgrade / remove / purge / verify
#   bash module/nas-mount.module.sh detect / is-installed / is-recommended
#   bash module/nas-mount.module.sh info / status
#
# Engine usage:
#   setup_ubuntu install nas-mount

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

# ── Metadata (doc/module-spec.md §3) ───────────────────────────────────────
NAME="nas-mount"
VERSION_PROVIDED="apt-managed"
CATEGORY="optional"
TAGS=("network" "storage")
HOMEPAGE="https://wiki.samba.org/index.php/LinuxCIFS_utils"
declare -gA DESCRIPTION=(
    [en]="NAS CIFS/SMB auto-mount (cifs-utils + autofs + smbclient)"
    [zh-TW]="NAS CIFS/SMB 自動掛載(cifs-utils + autofs + smbclient)"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Set INIT_UBUNTU_NAS_HOST/SHARE/USER (+ a chmod-600 credentials file or INIT_UBUNTU_NAS_PASSWORD) and re-run install to wire the autofs mount."
    [zh-TW]="設定 INIT_UBUNTU_NAS_HOST/SHARE/USER(以及 chmod 600 的憑證檔或 INIT_UBUNTU_NAS_PASSWORD)後重新 install 以掛上 autofs。"
)
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server")
DEPENDS_ON=()
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="command -v mount.cifs && command -v smbclient"

# ── Custom archetype data ───────────────────────────────────────────────────
APT_PKGS=("cifs-utils" "autofs" "smbclient")
# System files the automounter wiring owns (removed on purge).
NAS_MASTER_MAP="/etc/auto.master.d/nas-mount.autofs"
NAS_MAP_FILE="/etc/auto.nas-mount"

# ── Config accessors (runtime env; no hardcoded personal data) ──────────────
_nas_mount_base()   { printf '%s' "${INIT_UBUNTU_NAS_MOUNT_BASE:-/mnt/nas}"; }
_nas_cred_file()    { printf '%s' "${INIT_UBUNTU_NAS_CREDENTIALS:-/etc/init_ubuntu/nas-mount/credentials}"; }

# 0 = the mandatory NAS parameters are all present.
_nas_configured() {
    [[ -n "${INIT_UBUNTU_NAS_HOST:-}" \
        && -n "${INIT_UBUNTU_NAS_SHARE:-}" \
        && -n "${INIT_UBUNTU_NAS_USER:-}" ]]
}

# ── Lifecycle ───────────────────────────────────────────────────────────────
detect() {
    command -v lsb_release >/dev/null 2>&1 && \
        [[ "$(lsb_release -is 2>/dev/null)" == "Ubuntu" ]]
}

# NAS mounts need site-specific credentials, so never auto-select in Quick
# Setup — the user opts in explicitly.
is_recommended() {
    return 1
}

is_installed() {
    local _p
    for _p in "${APT_PKGS[@]}"; do
        # smbclient is a helper tool, not a hard mount-driver requirement.
        [[ "${_p}" == "smbclient" ]] && continue
        dpkg -l "${_p}" 2>/dev/null | grep -q "^ii" || return 1
    done
    return 0
}

install() {
    module_dryrun_guard install "apt-install ${APT_PKGS[*]} + optional autofs NAS wiring" && return 0
    module_skip_if_installed && return 0

    have_sudo_access 2>/dev/null \
        || { log_error "[${NAME}] sudo required for ${NAME} install"; return 1; }

    log_info "[${NAME}] apt-get update + install ${APT_PKGS[*]}"
    sudo apt-get update
    sudo apt-get install -y "${APT_PKGS[@]}"

    _nas_wire_autofs
}

upgrade() {
    module_dryrun_guard upgrade "apt-get install --only-upgrade ${APT_PKGS[*]}" && return 0
    if ! is_installed; then
        log_info "[${NAME}] not installed yet — running install instead"
        install
        return $?
    fi
    have_sudo_access 2>/dev/null || { log_error "[${NAME}] sudo required"; return 1; }
    sudo apt-get update -qq || log_warn "[${NAME}] apt-get update failed (continuing)"
    sudo apt-get install --only-upgrade -y "${APT_PKGS[@]}"
}

remove() {
    module_dryrun_guard remove "unwire autofs + apt-remove ${APT_PKGS[*]}" && return 0
    module_skip_if_not_installed && return 0
    _nas_unwire_autofs
    log_info "[${NAME}] apt-get remove ${APT_PKGS[*]}"
    sudo apt-get remove -y "${APT_PKGS[@]}" || true
}

purge() {
    module_dryrun_guard purge "apt-purge ${APT_PKGS[*]} + wipe autofs maps + credentials" && return 0
    _nas_unwire_autofs
    log_info "[${NAME}] apt-get purge ${APT_PKGS[*]}"
    sudo apt-get purge -y "${APT_PKGS[@]}" 2>/dev/null || true
    local _cred; _cred="$(_nas_cred_file)"
    log_info "[${NAME}] removing credentials: ${_cred}"
    sudo rm -f "${_cred}"
    sudo rmdir "$(dirname "${_cred}")" 2>/dev/null || true
}

verify() {
    module_default_verify
}

# ── Private helpers ─────────────────────────────────────────────────────────
# Write the credentials file (chmod 600) when it is missing and a password was
# provided. An already-present file is reused untouched (bring-your-own creds).
_nas_ensure_credentials() {
    local _cred; _cred="$(_nas_cred_file)"
    if [[ -f "${_cred}" ]]; then
        log_info "[${NAME}] reusing existing credentials file: ${_cred}"
        sudo chmod 600 "${_cred}"
        return 0
    fi
    if [[ -z "${INIT_UBUNTU_NAS_PASSWORD:-}" ]]; then
        log_warn "[${NAME}] no credentials file at ${_cred} and INIT_UBUNTU_NAS_PASSWORD unset — skipping autofs wiring"
        return 1
    fi
    log_info "[${NAME}] generating credentials file: ${_cred}"
    sudo mkdir -p "$(dirname "${_cred}")"
    sudo chmod 700 "$(dirname "${_cred}")"
    printf 'username=%s\npassword=%s\n' \
        "${INIT_UBUNTU_NAS_USER}" "${INIT_UBUNTU_NAS_PASSWORD}" \
        | sudo tee "${_cred}" > /dev/null
    sudo chmod 600 "${_cred}"
}

# Wire the autofs indirect map for the configured share. No-op (with a hint)
# when the NAS parameters are absent.
_nas_wire_autofs() {
    if ! _nas_configured; then
        log_info "[${NAME}] NAS parameters unset — packages installed, automounter not wired"
        return 0
    fi
    _nas_ensure_credentials || return 0

    local _base _cred _uid _gid
    _base="$(_nas_mount_base)"
    _cred="$(_nas_cred_file)"
    _uid="$(id -u "${USER}" 2>/dev/null || id -u)"
    _gid="$(id -g "${USER}" 2>/dev/null || id -g)"

    log_info "[${NAME}] wiring autofs map for ${INIT_UBUNTU_NAS_HOST}/${INIT_UBUNTU_NAS_SHARE} -> ${_base}/${INIT_UBUNTU_NAS_SHARE}"
    sudo mkdir -p "${_base}" "$(dirname "${NAS_MASTER_MAP}")"
    printf '%s %s --ghost --timeout=60\n' "${_base}" "${NAS_MAP_FILE}" \
        | sudo tee "${NAS_MASTER_MAP}" > /dev/null
    printf '%s -fstype=cifs,rw,credentials=%s,uid=%s,gid=%s,iocharset=utf8 ://%s/%s\n' \
        "${INIT_UBUNTU_NAS_SHARE}" "${_cred}" "${_uid}" "${_gid}" \
        "${INIT_UBUNTU_NAS_HOST}" "${INIT_UBUNTU_NAS_SHARE}" \
        | sudo tee "${NAS_MAP_FILE}" > /dev/null

    _nas_reload_autofs
}

_nas_unwire_autofs() {
    log_info "[${NAME}] removing autofs maps: ${NAS_MASTER_MAP} ${NAS_MAP_FILE}"
    sudo rm -f "${NAS_MASTER_MAP}" "${NAS_MAP_FILE}"
    _nas_reload_autofs
}

_nas_reload_autofs() {
    if command -v systemctl >/dev/null 2>&1; then
        sudo systemctl reload autofs 2>/dev/null \
            || sudo systemctl restart autofs 2>/dev/null \
            || log_warn "[${NAME}] could not reload autofs (start it manually)"
    else
        log_warn "[${NAME}] systemctl unavailable — reload autofs manually"
    fi
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
