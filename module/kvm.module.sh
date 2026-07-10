#!/usr/bin/env bash
# module/kvm.module.sh — KVM / libvirt / QEMU virtualization stack  [archetype: apt]
#
# Installs the libvirt/QEMU virtualization host stack (qemu-kvm,
# libvirt-daemon-system, libvirt-clients, bridge-utils, virt-manager, ovmf) and
# adds the invoking user to the libvirt + kvm groups. Uses the apt archetype for
# the six lifecycle mutation phases; overrides install() for the group-add and
# doctor() for the virsh / kvm-ok runtime health probe (doc/module-spec.md
# §3.2.1 note: modules with a group requirement MUST override doctor()).
#
# Standalone usage:
#   bash module/kvm.module.sh install [--dry-run]
#   bash module/kvm.module.sh upgrade / remove / purge / verify / doctor
#   bash module/kvm.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/kvm.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install kvm

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
NAME="kvm"
VERSION_PROVIDED="apt-managed"
CATEGORY="optional"
TAGS=("virtualization" "vm")
HOMEPAGE="https://ubuntu.com/server/docs/virtualization-libvirt"
declare -gA DESCRIPTION=(
    [en]="KVM / libvirt / QEMU virtualization stack + virt-manager"
    [zh-TW]="KVM / libvirt / QEMU 虛擬化套件 + virt-manager"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Added to libvirt + kvm groups. Re-login or run 'newgrp libvirt' for it to take effect."
    [zh-TW]="已加入 libvirt + kvm 群組。重新登入或執行 'newgrp libvirt' 讓群組生效。"
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
TEST_VERIFY_CMD="command -v virsh"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# ── Archetype A — apt ───────────────────────────────────────────────────────
APT_PKGS=(
    "qemu-kvm"
    "libvirt-daemon-system"
    "libvirt-clients"
    "bridge-utils"
    "virt-manager"
    "ovmf"
)
APT_PPA=""
CONFIG_PATHS=("${HOME}/.config/libvirt")
module_use_apt_archetype

# ── Overrides ───────────────────────────────────────────────────────────────
# install: apt-install the stack, then add the invoking user to libvirt + kvm.
install() {
    module_default_apt_install || return $?
    module_dryrun_guard install "usermod -aG libvirt,kvm <user>" && return 0
    _add_user_to_virt_groups
}

# doctor: baseline is_installed + virsh reachability + kvm-ok acceleration probe.
# Group requirement means the archetype's is_installed-only doctor is not enough
# (doc/module-spec.md §3.2.1 note).
doctor() {
    is_installed 2>/dev/null || { log_warn "[${NAME}] doctor: not installed"; return 1; }

    if command -v virsh >/dev/null 2>&1; then
        if ! virsh list --all >/dev/null 2>&1; then
            log_warn "[${NAME}] doctor: 'virsh list --all' failed"
            return 1
        fi
    else
        log_warn "[${NAME}] doctor: virsh not on PATH"
        return 1
    fi

    # kvm-ok (cpu-checker) is hardware-dependent; a nested/VM host may lack
    # acceleration. Report but do not hard-fail the health check on it.
    if command -v kvm-ok >/dev/null 2>&1; then
        if kvm-ok >/dev/null 2>&1; then
            log_info "[${NAME}] doctor: KVM acceleration available"
        else
            log_warn "[${NAME}] doctor: kvm-ok reports acceleration unavailable"
        fi
    else
        log_info "[${NAME}] doctor: kvm-ok not installed (skipping acceleration probe)"
    fi
    return 0
}

# ── Required hooks (detect + is_recommended stay module-specific) ────────────
detect() {
    command -v apt-get >/dev/null 2>&1
}

is_recommended() {
    case "${INIT_UBUNTU_FORM_FACTOR:-}" in
        desktop | server)
            ! is_installed
            ;;
        *)
            return 1
            ;;
    esac
}

# ── Private helpers ─────────────────────────────────────────────────────────
_add_user_to_virt_groups() {
    local _user="${USER:-$(id -un)}"
    if ! have_sudo_access 2>/dev/null; then
        log_warn "[${NAME}] no sudo: run 'sudo usermod -aG libvirt,kvm ${_user}' manually"
        return 0
    fi
    log_info "[${NAME}] adding ${_user} to libvirt + kvm groups"
    sudo usermod -aG libvirt,kvm "${_user}" \
        || log_warn "[${NAME}] usermod failed; add ${_user} to libvirt,kvm manually"
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
