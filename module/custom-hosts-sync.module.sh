#!/usr/bin/env bash
# shellcheck disable=SC2034  # module metadata vars (NAME / DESCRIPTION / CATEGORY / TAGS / ...) consumed by engine post-source — https://www.shellcheck.net/wiki/SC2034
# module/custom-hosts-sync.module.sh — keep custom /etc/hosts entries from being
# reverted by the F5 BIG-IP Edge VPN client (svpn)  [archetype: custom]
#
# svpn snapshots /etc/hosts on connect and restores it wholesale on
# disconnect/reboot, silently reverting any name->IP mapping you added after
# the snapshot. A systemd .path unit watches /etc/hosts (and the user master
# list) and re-merges the user-maintained list into a managed block whenever
# either changes. The master list lives in the user's home; the sync script
# and systemd units are deployed to system paths with the user's home
# substituted into the __USER_HOME__ placeholder at install time.

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
NAME="custom-hosts-sync"
VERSION_PROVIDED="1.0"
CATEGORY="optional"
TAGS=("network" "vpn" "hosts")
HOMEPAGE=""
declare -gA DESCRIPTION=(
    [en]="Keep custom /etc/hosts entries from being reverted by the F5 VPN (svpn)"
    [zh-TW]="避免自訂 /etc/hosts 條目被 F5 VPN(svpn)還原"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Edit ONLY ~/.config/hosts-custom/hosts.custom; changes sync into /etc/hosts on save."
    [zh-TW]="只需編輯 ~/.config/hosts-custom/hosts.custom;存檔即同步進 /etc/hosts。"
)
declare -gA WARN_MESSAGE=(
    [en]="Installs a systemd path unit and manages a block inside /etc/hosts."
    [zh-TW]="會安裝 systemd path 單元,並管理 /etc/hosts 內的一段區塊。"
)
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "vm")
DEPENDS_ON=()
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="medium"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="[ -x /usr/local/bin/sync-custom-hosts ]"

# ── Archetype D data — deployed paths ───────────────────────────────────────
CHS_SRC_DIR="${MODULE_DIR:-${BASH_SOURCE[0]%/*}}/config/custom-hosts-sync"
CHS_SCRIPT="/usr/local/bin/sync-custom-hosts"
CHS_SERVICE="/etc/systemd/system/custom-hosts-sync.service"
CHS_PATH_UNIT="/etc/systemd/system/custom-hosts-sync.path"

# ── Lifecycle ───────────────────────────────────────────────────────────────
is_installed() {
    [[ -x "${CHS_SCRIPT}" ]] \
        && [[ -f "${CHS_SERVICE}" ]] \
        && [[ -f "${CHS_PATH_UNIT}" ]]
}

detect() {
    # systemd path units are the whole mechanism; skip hosts without systemctl.
    command -v systemctl >/dev/null 2>&1
}

is_recommended() {
    is_installed && return 1
    # Niche: only relevant when the F5 BIG-IP Edge client (svpn) is present.
    command -v svpn >/dev/null 2>&1
}

_chs_deploy_files() {
    # Substitute the real home into the __USER_HOME__ placeholders (systemd does
    # not expand env vars in PathChanged=, and a system unit's %h is /root), then
    # deploy the sync script + both units. Shared by install() and upgrade().
    local _home="${HOME}"
    log_info "[${NAME}] installing ${CHS_SCRIPT}"
    sed "s#__USER_HOME__#${_home}#g" "${CHS_SRC_DIR}/sync-custom-hosts" \
        | sudo tee "${CHS_SCRIPT}" >/dev/null
    sudo chmod 0755 "${CHS_SCRIPT}"

    log_info "[${NAME}] installing systemd units"
    sudo cp "${CHS_SRC_DIR}/custom-hosts-sync.service" "${CHS_SERVICE}"
    sudo chmod 0644 "${CHS_SERVICE}"
    sed "s#__USER_HOME__#${_home}#g" "${CHS_SRC_DIR}/custom-hosts-sync.path" \
        | sudo tee "${CHS_PATH_UNIT}" >/dev/null
    sudo chmod 0644 "${CHS_PATH_UNIT}"

    log_info "[${NAME}] enabling custom-hosts-sync.service + .path"
    sudo systemctl daemon-reload
    sudo systemctl enable --now custom-hosts-sync.service
    sudo systemctl enable --now custom-hosts-sync.path
}

install() {
    module_dryrun_guard install "seed ~/.config/hosts-custom/hosts.custom + deploy ${CHS_SCRIPT} + custom-hosts-sync.{service,path} + enable path unit" && return 0
    module_skip_if_installed && return 0

    have_sudo_access 2>/dev/null \
        || { log_error "[${NAME}] sudo required to install systemd units"; return 1; }

    local _master_dir="${HOME}/.config/hosts-custom"
    local _master="${_master_dir}/hosts.custom"

    # Seed the user master list (the only file the user edits). Never clobber an
    # existing list, and keep it user-owned (no sudo).
    log_info "[${NAME}] seeding master list ${_master}"
    mkdir -p "${_master_dir}"
    if [[ ! -f "${_master}" ]]; then
        cp "${CHS_SRC_DIR}/hosts.custom.example" "${_master}"
        chmod 0644 "${_master}"
    fi

    _chs_deploy_files
}

upgrade() {
    module_dryrun_guard upgrade "re-deploy ${CHS_SCRIPT} + systemd units" && return 0
    have_sudo_access 2>/dev/null \
        || { log_error "[${NAME}] sudo required to upgrade"; return 1; }
    log_info "[${NAME}] re-deploying tracked files"
    _chs_deploy_files
}

remove() {
    module_dryrun_guard remove "disable + remove systemd units + ${CHS_SCRIPT} (keeps master list)" && return 0
    module_skip_if_not_installed && return 0

    have_sudo_access 2>/dev/null \
        || { log_error "[${NAME}] sudo required to remove systemd units"; return 1; }

    log_info "[${NAME}] disabling custom-hosts-sync.path + .service"
    sudo systemctl disable --now custom-hosts-sync.path 2>/dev/null || true
    sudo systemctl disable --now custom-hosts-sync.service 2>/dev/null || true
    sudo rm -f "${CHS_PATH_UNIT}" "${CHS_SERVICE}" "${CHS_SCRIPT}"
    sudo systemctl daemon-reload 2>/dev/null || true
}

purge() {
    module_dryrun_guard purge "remove units/script + wipe ${HOME}/.config/hosts-custom" && return 0
    remove
    log_info "[${NAME}] removing ${HOME}/.config/hosts-custom"
    rm -rf "${HOME}/.config/hosts-custom"
}

verify() {
    module_default_verify
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
