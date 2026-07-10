#!/usr/bin/env bats
# test/unit/module/kvm_spec.bats — module/kvm.module.sh
#
# KVM / libvirt / QEMU virtualization stack (issue #310). Apt archetype-A module
# with two overrides: install() adds the invoking user to libvirt + kvm groups,
# and doctor() probes virsh reachability + kvm-ok acceleration. Mirrors the htop
# archetype-A spec (smoke / metadata / lifecycle dry-run / no-side-fx /
# idempotency / standalone CLI / sidecar lifecycle) plus kvm-specific cases.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
}

teardown() {
    teardown_test_env
}

_load_module() {
    # shellcheck source=../../../lib/logger.sh
    source "${LIB_DIR}/logger.sh"
    # shellcheck source=../../../lib/general.sh
    source "${LIB_DIR}/general.sh"
    # shellcheck source=../../../lib/module_helper.sh
    source "${LIB_DIR}/module_helper.sh"
    # shellcheck source=../../../module/kvm.module.sh
    source "${MODULE_DIR}/kvm.module.sh"
}

_standalone_module() {
    bash "${MODULE_DIR}/kvm.module.sh" "$@"
}

# ── Controllable mocks ───────────────────────────────────────────────────────

_mock_is_installed() {
    is_installed() { return "${MOCK_IS_INSTALLED_RC:-0}"; }
}

_mock_dpkg() {
    dpkg() {
        [[ -n "${MOCK_DPKG_OUTPUT:-}" ]] && printf '%s\n' "${MOCK_DPKG_OUTPUT}"
        return "${MOCK_DPKG_RC:-0}"
    }
}

_mock_apt_defaults() {
    module_default_apt_install() { return "${MOCK_APT_INSTALL_RC:-0}"; }
    module_default_apt_upgrade() { return "${MOCK_APT_UPGRADE_RC:-0}"; }
    module_default_apt_remove()  { return "${MOCK_APT_REMOVE_RC:-0}"; }
    module_default_apt_purge()   { return "${MOCK_APT_PURGE_RC:-0}"; }
}

_mock_dpkg_query() {
    dpkg-query() {
        [[ -n "${MOCK_PKG_VERSION:-}" ]] || return 1
        printf '%s' "${MOCK_PKG_VERSION}"
    }
}

_mock_apt_list() {
    apt() { printf '%s' "${MOCK_APT_UPGRADABLE:-}"; }
}

# have_sudo_access mock: MOCK_SUDO_ACCESS_RC (0 = sudo available). Prints a
# marker so a test can assert the group-add path did / did not probe for sudo.
_mock_have_sudo() {
    have_sudo_access() { printf 'SUDO_CHECKED\n'; return "${MOCK_SUDO_ACCESS_RC:-0}"; }
}

# sudo mock: record the argv the group-add would have run under sudo.
_mock_sudo_record() {
    sudo() { printf 'SUDO %s\n' "$*"; }
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "kvm module file parses (bash -n)" {
    run bash -n "${MODULE_DIR}/kvm.module.sh"
    assert_success
}

@test "kvm module sources cleanly in engine mode (MODULE_STANDALONE=false)" {
    _load_module
    [[ "${MODULE_STANDALONE}" == "false" ]]
}

@test "kvm module defines all 10 lifecycle functions" {
    _load_module
    local _fn
    for _fn in detect is_recommended is_installed install upgrade \
               remove purge verify is_outdated doctor; do
        declare -F "${_fn}" >/dev/null || {
            printf 'missing lifecycle function: %s\n' "${_fn}" >&2
            return 1
        }
    done
}

# ── Metadata sanity ──────────────────────────────────────────────────────────

@test "kvm module declares NAME=kvm" {
    _load_module
    [[ "${NAME}" == "kvm" ]]
}

@test "kvm module CATEGORY=optional" {
    _load_module
    [[ "${CATEGORY}" == "optional" ]]
}

@test "kvm module TAGS contains virtualization" {
    _load_module
    [[ " ${TAGS[*]} " == *" virtualization "* ]]
}

@test "kvm module DEPENDS_ON is empty" {
    _load_module
    [[ "${#DEPENDS_ON[@]}" -eq 0 ]]
}

@test "kvm DESCRIPTION is associative with en + zh-TW entries" {
    _load_module
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ -n "${DESCRIPTION[en]}" ]]
    [[ -n "${DESCRIPTION[zh-TW]}" ]]
}

@test "kvm module_get_description returns language-specific text + en fallback" {
    _load_module
    [[ -n "$(module_get_description en)" ]]
    [[ "$(module_get_description zh-TW)" == *"虛擬化"* ]]
    [[ "$(module_get_description xx)" == "$(module_get_description en)" ]]
}

@test "kvm POST_INSTALL_MESSAGE mentions the re-login / newgrp requirement" {
    _load_module
    [[ "${POST_INSTALL_MESSAGE[en]}" == *"newgrp libvirt"* ]]
    [[ "${POST_INSTALL_MESSAGE[en]}" == *"Re-login"* ]]
}

@test "kvm SUPPORTED_UBUNTU includes 22.04 24.04 26.04" {
    _load_module
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 22.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 24.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 26.04 "* ]]
}

@test "kvm SUPPORTED_PLATFORMS covers desktop + server only" {
    _load_module
    [[ " ${SUPPORTED_PLATFORMS[*]} " == *" desktop "* ]]
    [[ " ${SUPPORTED_PLATFORMS[*]} " == *" server "* ]]
    [[ " ${SUPPORTED_PLATFORMS[*]} " != *" container "* ]]
}

@test "kvm module RISK_LEVEL=low and VERSION_PROVIDED=apt-managed" {
    _load_module
    [[ "${RISK_LEVEL}" == "low" ]]
    [[ "${VERSION_PROVIDED}" == "apt-managed" ]]
}

@test "kvm archetype data installs the full libvirt/qemu stack" {
    _load_module
    local _p
    for _p in qemu-kvm libvirt-daemon-system libvirt-clients \
              bridge-utils virt-manager ovmf; do
        [[ " ${APT_PKGS[*]} " == *" ${_p} "* ]] || {
            printf 'missing apt package: %s\n' "${_p}" >&2
            return 1
        }
    done
    [[ -z "${APT_PPA}" ]]
}

# ── is_installed ─────────────────────────────────────────────────────────────

@test "is_installed returns nonzero when dpkg does not report the stack" {
    _load_module
    MOCK_DPKG_RC=1
    _mock_dpkg
    run is_installed
    assert_failure
}

@test "is_installed returns zero when dpkg reports all packages as ii" {
    _load_module
    MOCK_DPKG_OUTPUT='ii  pkg  99.9.9  amd64  pkg'
    _mock_dpkg
    run is_installed
    assert_success
}

# ── Lifecycle dry-run ────────────────────────────────────────────────────────

@test "install in dry-run mode is a no-op" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "upgrade in dry-run mode is a no-op" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run upgrade
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "remove in dry-run mode is a no-op" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run remove
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "purge in dry-run mode is a no-op" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run purge
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "verify in dry-run mode is a no-op" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run verify
    assert_success
    assert_output --partial "DRY-RUN"
}

# ── No side effects under dry-run ────────────────────────────────────────────

@test "dry-run install writes nothing under the state dir" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/kvm" ]]
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/state.json" ]]
}

@test "standalone dry-run install creates no files in a scratch HOME" {
    local _home="${INIT_UBUNTU_TEST_SCRATCH}/home"
    mkdir -p "${_home}"
    HOME="${_home}" XDG_STATE_HOME="${_home}/.local/state" \
        run _standalone_module install --dry-run
    assert_success
    local _leftover
    _leftover="$(find "${_home}" -mindepth 1 2>/dev/null)"
    [[ -z "${_leftover}" ]]
}

# ── install override: libvirt + kvm group-add ────────────────────────────────

@test "install runs apt then adds the user to the virt groups" {
    _load_module
    _mock_apt_defaults
    _mock_have_sudo
    _mock_sudo_record
    MOCK_PKG_VERSION="1.2.3"
    _mock_dpkg_query
    run install
    assert_success
    # apt returned 0, so the group-add ran after it (a non-zero apt would abort
    # install before this line); the sudo mock records the usermod call.
    assert_output --partial "usermod -aG libvirt,kvm"
}

@test "install without sudo warns instead of failing" {
    _load_module
    _mock_apt_defaults
    MOCK_SUDO_ACCESS_RC=1
    _mock_have_sudo
    MOCK_PKG_VERSION="1.2.3"
    _mock_dpkg_query
    run install
    assert_success
    assert_output --partial "no sudo"
    assert_output --partial "usermod -aG libvirt,kvm"
}

@test "install skips the group-add entirely under dry-run" {
    _load_module
    _mock_apt_defaults
    _mock_have_sudo
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    refute_output --partial "SUDO_CHECKED"
}

# ── Sidecar lifecycle (ADR-0001) ─────────────────────────────────────────────

@test "install writes the sidecar with the dpkg-reported version" {
    _load_module
    _mock_apt_defaults
    MOCK_SUDO_ACCESS_RC=1
    _mock_have_sudo
    MOCK_PKG_VERSION="1:8.2.1"
    _mock_dpkg_query
    module_standalone_main install
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/kvm" ]]
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/kvm")" == "1:8.2.1" ]]
}

@test "install sidecar falls back to apt-managed when dpkg-query is empty" {
    _load_module
    _mock_apt_defaults
    MOCK_SUDO_ACCESS_RC=1
    _mock_have_sudo
    MOCK_PKG_VERSION=""
    _mock_dpkg_query
    module_standalone_main install
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/kvm")" == "apt-managed" ]]
}

@test "install never touches state.json (ADR-0001)" {
    _load_module
    printf '{"version":"0.2.0","installed":{}}\n' \
        > "${INIT_UBUNTU_STATE_DIR}/state.json"
    local _before; _before="$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")"
    _mock_apt_defaults
    MOCK_SUDO_ACCESS_RC=1
    _mock_have_sudo
    MOCK_PKG_VERSION="1.2.3"
    _mock_dpkg_query
    module_standalone_main install
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")" == "${_before}" ]]
}

@test "failed apt install leaves no sidecar behind (ADR-0015)" {
    _load_module
    _mock_apt_defaults
    MOCK_APT_INSTALL_RC=1
    run module_standalone_main install
    assert_failure
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/kvm" ]]
}

@test "upgrade refreshes the sidecar version" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.0.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/kvm"
    _mock_apt_defaults
    MOCK_PKG_VERSION="1.2.3"
    _mock_dpkg_query
    module_standalone_main upgrade
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/kvm")" == "1.2.3" ]]
}

@test "remove deletes the sidecar" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.0.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/kvm"
    _mock_apt_defaults
    module_standalone_main remove
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/kvm" ]]
}

@test "purge deletes the sidecar" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.0.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/kvm"
    _mock_apt_defaults
    module_standalone_main purge
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/kvm" ]]
}

# ── Idempotency ──────────────────────────────────────────────────────────────

@test "install short-circuits when is_installed returns 0 (idempotency)" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    MOCK_PKG_VERSION="1.2.3"
    _mock_dpkg_query
    run install
    assert_success
    assert_output --partial "already installed"
}

@test "install twice with apt mocked exits 0 both times" {
    _load_module
    _mock_apt_defaults
    MOCK_SUDO_ACCESS_RC=1
    _mock_have_sudo
    MOCK_PKG_VERSION="1.2.3"
    _mock_dpkg_query
    run install
    assert_success
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    run install
    assert_success
}

@test "remove is idempotent — second run still exits 0" {
    _load_module
    _mock_apt_defaults
    run remove
    assert_success
    run remove
    assert_success
}

# ── verify / doctor / is_outdated ────────────────────────────────────────────

@test "verify fails when not installed" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    run verify
    assert_failure
}

@test "verify passes when installed and TEST_VERIFY_CMD succeeds" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    TEST_VERIFY_CMD="true"
    run verify
    assert_success
}

@test "doctor fails when not installed" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    run doctor
    assert_failure
}

@test "doctor fails when virsh is not on PATH" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/empty-bin"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/empty-bin" run doctor
    assert_failure
    assert_output --partial "virsh not on PATH"
}

@test "doctor fails when 'virsh list --all' errors" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    printf '#!/usr/bin/env bash\nexit 1\n' > "${INIT_UBUNTU_TEST_SCRATCH}/bin/virsh"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/virsh"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run doctor
    assert_failure
    assert_output --partial "virsh list --all"
}

@test "doctor passes when virsh works and kvm-ok reports acceleration" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${INIT_UBUNTU_TEST_SCRATCH}/bin/virsh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${INIT_UBUNTU_TEST_SCRATCH}/bin/kvm-ok"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/virsh" "${INIT_UBUNTU_TEST_SCRATCH}/bin/kvm-ok"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run doctor
    assert_success
    assert_output --partial "acceleration available"
}

@test "doctor still passes (with a warning) when kvm-ok reports no acceleration" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${INIT_UBUNTU_TEST_SCRATCH}/bin/virsh"
    printf '#!/usr/bin/env bash\nexit 1\n' > "${INIT_UBUNTU_TEST_SCRATCH}/bin/kvm-ok"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/virsh" "${INIT_UBUNTU_TEST_SCRATCH}/bin/kvm-ok"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run doctor
    assert_success
    assert_output --partial "acceleration unavailable"
}

@test "is_outdated returns zero when apt reports a stack package upgradable" {
    _load_module
    MOCK_APT_UPGRADABLE='qemu-kvm/noble-updates 1.2.3 amd64 [upgradable from: 1.2.2]'
    _mock_apt_list
    run is_outdated
    assert_success
}

@test "is_outdated returns nonzero when no stack package is upgradable" {
    _load_module
    MOCK_APT_UPGRADABLE='some-other-pkg/noble 1.0 amd64 [upgradable from: 0.9]'
    _mock_apt_list
    run is_outdated
    assert_failure
}

# ── is_recommended ───────────────────────────────────────────────────────────

@test "is_recommended is nonzero when already installed on desktop" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    INIT_UBUNTU_FORM_FACTOR=desktop run is_recommended
    assert_failure
}

@test "is_recommended is zero when not installed on desktop" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    INIT_UBUNTU_FORM_FACTOR=desktop run is_recommended
    assert_success
}

@test "is_recommended is zero when not installed on server" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    INIT_UBUNTU_FORM_FACTOR=server run is_recommended
    assert_success
}

@test "is_recommended is nonzero inside a container form factor" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    INIT_UBUNTU_FORM_FACTOR=container run is_recommended
    assert_failure
}

# ── detect ───────────────────────────────────────────────────────────────────

@test "detect succeeds when apt-get is available" {
    _load_module
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    printf '#!/bin/sh\nexit 0\n' > "${INIT_UBUNTU_TEST_SCRATCH}/bin/apt-get"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/apt-get"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run detect
    assert_success
}

@test "detect fails when apt-get is not on PATH" {
    _load_module
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/empty-bin"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/empty-bin" run detect
    assert_failure
}

# ── Dual-mode standalone CLI ─────────────────────────────────────────────────

@test "standalone: with no args prints usage + exits 2" {
    run _standalone_module
    assert_failure 2
    assert_output --partial "Usage:"
}

@test "standalone: --help shows phases" {
    run _standalone_module --help
    assert_success
    assert_output --partial "install"
    assert_output --partial "remove"
    assert_output --partial "purge"
}

@test "standalone: --version prints NAME + VERSION_PROVIDED" {
    run _standalone_module --version
    assert_success
    assert_output --partial "kvm"
}

@test "standalone: unknown phase returns exit 2" {
    run _standalone_module nope
    assert_failure 2
}

@test "standalone: info prints metadata" {
    run _standalone_module info
    assert_success
    assert_output --partial "name:        kvm"
    assert_output --partial "category:    optional"
}

@test "standalone: info --lang=zh-TW prints localized description" {
    run _standalone_module info --lang=zh-TW
    assert_success
    assert_output --partial "虛擬化"
}

@test "standalone: status reports installed + outdated fields" {
    run _standalone_module status
    assert_success
    assert_output --partial "installed:"
    assert_output --partial "outdated:"
}

# ── AC-25: all 10 phases runnable, never "not implemented" exit 2 ────────────

@test "standalone: install --dry-run exits 0 with DRY-RUN output" {
    run _standalone_module install --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "standalone: detect is implemented (exit != 2)" {
    run _standalone_module detect
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "standalone: is-installed is implemented (exit != 2)" {
    run _standalone_module is-installed
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "standalone: doctor is implemented (exit != 2)" {
    run _standalone_module doctor
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}
