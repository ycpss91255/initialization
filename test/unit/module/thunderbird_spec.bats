#!/usr/bin/env bats
# test/unit/module/thunderbird_spec.bats — module/thunderbird.module.sh
#
# Per doc/module-spec.md §7: smoke / metadata / lifecycle dry-run / no-side-fx /
# idempotency / standalone CLI / module-specific (apt PPA archetype + apt pin,
# sidecar lifecycle ADR-0001, desktop-only platform gate, PPA + pin teardown on
# remove, real doctor — small-tools modularization program).

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
    # shellcheck source=../../../module/thunderbird.module.sh
    source "${MODULE_DIR}/thunderbird.module.sh"
}

# _standalone_module runs the module as a self-contained CLI (the same entry
# users hit when they type `bash module/thunderbird.module.sh ...`).
_standalone_module() {
    bash "${MODULE_DIR}/thunderbird.module.sh" "$@"
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

# apt archetype default mocks + install collaborators (sudo probe + pin write:
# MOCK_SUDO_RC / MOCK_PIN_RC).
_mock_apt_defaults() {
    module_default_apt_install() { return "${MOCK_APT_INSTALL_RC:-0}"; }
    module_default_apt_upgrade() { return "${MOCK_APT_UPGRADE_RC:-0}"; }
    module_default_apt_remove()  { return "${MOCK_APT_REMOVE_RC:-0}"; }
    module_default_apt_purge()   { return "${MOCK_APT_PURGE_RC:-0}"; }
    have_sudo_access()           { return "${MOCK_SUDO_RC:-0}"; }
    _thunderbird_write_apt_pin() { return "${MOCK_PIN_RC:-0}"; }
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

# PPA + pin teardown toolchain: pass-through sudo, forced sudo access, and a
# no-op apt-add-repository so the real binary (absent in the container) never
# runs. eval-defined so shellcheck skips reachability analysis (SC2317).
_mock_repo_tools() {
    eval 'sudo() { "$@"; }'
    eval 'have_sudo_access() { return 0; }'
    eval 'apt-add-repository() { return 0; }'
    eval 'apt-get() { return 0; }'
}

# Point the apt pin file into the per-test scratch dir.
_scratch_pin_path() {
    THUNDERBIRD_APT_PIN="${INIT_UBUNTU_TEST_SCRATCH}/preferences.d/mozillateamppa"
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "thunderbird module file parses (bash -n)" {
    run bash -n "${MODULE_DIR}/thunderbird.module.sh"
    assert_success
}

@test "thunderbird module sources cleanly in engine mode (MODULE_STANDALONE=false)" {
    _load_module
    [[ "${MODULE_STANDALONE}" == "false" ]]
}

@test "thunderbird module defines all 10 lifecycle functions" {
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

@test "thunderbird module declares NAME=thunderbird" {
    _load_module
    [[ "${NAME}" == "thunderbird" ]]
}

@test "thunderbird module CATEGORY=optional" {
    _load_module
    [[ "${CATEGORY}" == "optional" ]]
}

@test "thunderbird module TAGS contains email" {
    _load_module
    [[ " ${TAGS[*]} " == *" email "* ]]
}

@test "thunderbird SUPPORTED_PLATFORMS is desktop-only" {
    _load_module
    [[ "${#SUPPORTED_PLATFORMS[@]}" -eq 1 ]]
    [[ "${SUPPORTED_PLATFORMS[0]}" == "desktop" ]]
}

@test "thunderbird DESCRIPTION is associative with en + zh-TW entries" {
    _load_module
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ -n "${DESCRIPTION[en]}" ]]
    [[ -n "${DESCRIPTION[zh-TW]}" ]]
}

@test "thunderbird module_get_description returns language-specific text" {
    _load_module
    [[ "$(module_get_description en)" == *"Thunderbird"* ]]
    [[ -n "$(module_get_description zh-TW)" ]]
    [[ "$(module_get_description xx)" == "$(module_get_description en)" ]]
}

@test "thunderbird SUPPORTED_UBUNTU includes 22.04 24.04 26.04" {
    _load_module
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 22.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 24.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 26.04 "* ]]
}

@test "thunderbird module RISK_LEVEL=low" {
    _load_module
    [[ "${RISK_LEVEL}" == "low" ]]
}

@test "thunderbird module VERSION_PROVIDED=ppa-managed" {
    _load_module
    [[ "${VERSION_PROVIDED}" == "ppa-managed" ]]
}

@test "thunderbird HOMEPAGE points at thunderbird.net" {
    _load_module
    [[ "${HOMEPAGE}" == *"thunderbird.net"* ]]
}

@test "thunderbird archetype installs the thunderbird apt package via the PPA" {
    _load_module
    [[ " ${APT_PKGS[*]} " == *" thunderbird "* ]]
    [[ "${APT_PPA}" == "ppa:mozillateam/ppa" ]]
}

@test "thunderbird TEST_VERIFY_CMD checks the thunderbird binary" {
    _load_module
    [[ "${TEST_VERIFY_CMD}" == *"command -v thunderbird"* ]]
}

@test "thunderbird apt pin targets preferences.d" {
    _load_module
    [[ "${THUNDERBIRD_APT_PIN}" == "/etc/apt/preferences.d/mozillateamppa" ]]
}

@test "thunderbird CONFIG_PATHS targets the user profile dir for purge" {
    _load_module
    [[ " ${CONFIG_PATHS[*]} " == *" ${HOME}/.thunderbird "* ]]
}

# ── is_installed: relies on dpkg ─────────────────────────────────────────────

@test "is_installed returns nonzero when dpkg does not report thunderbird" {
    _load_module
    MOCK_DPKG_RC=1
    _mock_dpkg
    run is_installed
    assert_failure
}

@test "is_installed returns zero when dpkg reports thunderbird as ii" {
    _load_module
    MOCK_DPKG_OUTPUT='ii  thunderbird  1:115  amd64  email client'
    _mock_dpkg
    run is_installed
    assert_success
}

# ── Lifecycle dry-run (AC-12 pattern) ────────────────────────────────────────

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
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/thunderbird" ]]
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/state.json" ]]
}

@test "dry-run remove leaves an existing apt pin in place" {
    _load_module
    _scratch_pin_path
    mkdir -p "$(dirname -- "${THUNDERBIRD_APT_PIN}")"
    printf 'Pin-Priority: 1001\n' > "${THUNDERBIRD_APT_PIN}"
    INIT_UBUNTU_DRY_RUN=true run remove
    assert_success
    [[ -f "${THUNDERBIRD_APT_PIN}" ]]
}

@test "dry-run remove leaves an existing sidecar in place" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1:115\n' > "${INIT_UBUNTU_STATE_DIR}/versions/thunderbird"
    INIT_UBUNTU_DRY_RUN=true run remove
    assert_success
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/thunderbird" ]]
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

# ── apt pin write + teardown (module-specific) ───────────────────────────────

@test "_thunderbird_write_apt_pin writes a priority-1001 pin for the Mozilla Team PPA" {
    _load_module
    _scratch_pin_path
    _mock_repo_tools
    run _thunderbird_write_apt_pin
    assert_success
    [[ -f "${THUNDERBIRD_APT_PIN}" ]]
    run cat "${THUNDERBIRD_APT_PIN}"
    assert_output --partial "Package: thunderbird*"
    assert_output --partial "Pin: release o=LP-PPA-mozillateam"
    assert_output --partial "Pin-Priority: 1001"
}

@test "install fails when sudo is unavailable" {
    _load_module
    _mock_apt_defaults
    MOCK_SUDO_RC=1
    run install
    assert_failure
    assert_output --partial "sudo"
}

@test "install fails (and writes no sidecar) when the pin write fails" {
    _load_module
    _mock_apt_defaults
    MOCK_PIN_RC=1
    run module_standalone_main install
    assert_failure
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/thunderbird" ]]
}

@test "remove drops the apt pin (clean uninstall)" {
    _load_module
    _scratch_pin_path
    _mock_repo_tools
    _mock_apt_defaults
    mkdir -p "$(dirname -- "${THUNDERBIRD_APT_PIN}")"
    printf 'Pin-Priority: 1001\n' > "${THUNDERBIRD_APT_PIN}"
    run remove
    assert_success
    [[ ! -e "${THUNDERBIRD_APT_PIN}" ]]
}

@test "remove without sudo still exits 0 and leaves the pin" {
    _load_module
    _scratch_pin_path
    _mock_apt_defaults
    MOCK_SUDO_RC=1
    mkdir -p "$(dirname -- "${THUNDERBIRD_APT_PIN}")"
    printf 'Pin-Priority: 1001\n' > "${THUNDERBIRD_APT_PIN}"
    run remove
    assert_success
    [[ -f "${THUNDERBIRD_APT_PIN}" ]]
}

@test "purge drops the apt pin and clears the user profile" {
    _load_module
    _scratch_pin_path
    _mock_repo_tools
    local _cfg="${INIT_UBUNTU_TEST_SCRATCH}/home/.thunderbird"
    CONFIG_PATHS=("${_cfg}")
    mkdir -p "${_cfg}" "$(dirname -- "${THUNDERBIRD_APT_PIN}")"
    printf 'profiles.ini\n' > "${_cfg}/profiles.ini"
    printf 'Pin-Priority: 1001\n' > "${THUNDERBIRD_APT_PIN}"
    run purge
    assert_success
    [[ ! -e "${THUNDERBIRD_APT_PIN}" ]]
    [[ ! -e "${_cfg}" ]]
}

# ── Sidecar lifecycle (ADR-0001) ─────────────────────────────────────────────

@test "install writes the sidecar with the dpkg-reported version" {
    _load_module
    _mock_apt_defaults
    MOCK_PKG_VERSION="1:115.14.0"
    _mock_dpkg_query
    module_standalone_main install
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/thunderbird" ]]
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/thunderbird")" == "1:115.14.0" ]]
}

@test "install sidecar falls back to VERSION_PROVIDED when dpkg-query is empty" {
    _load_module
    _mock_apt_defaults
    MOCK_PKG_VERSION=""
    _mock_dpkg_query
    module_standalone_main install
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/thunderbird")" == "ppa-managed" ]]
}

@test "install never touches state.json (ADR-0001 / AC-23 pattern)" {
    _load_module
    printf '{"schema_version":"0.1.0","installed":{}}\n' \
        > "${INIT_UBUNTU_STATE_DIR}/state.json"
    local _before; _before="$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")"
    _mock_apt_defaults
    MOCK_PKG_VERSION="1:115.14.0"
    _mock_dpkg_query
    module_standalone_main install
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")" == "${_before}" ]]
}

@test "failed apt install leaves no sidecar behind (ADR-0015)" {
    _load_module
    MOCK_APT_INSTALL_RC=1
    _mock_apt_defaults
    run module_standalone_main install
    assert_failure
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/thunderbird" ]]
}

@test "upgrade refreshes the sidecar version" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1:115.13.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/thunderbird"
    _mock_apt_defaults
    MOCK_PKG_VERSION="1:115.14.0"
    _mock_dpkg_query
    module_standalone_main upgrade
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/thunderbird")" == "1:115.14.0" ]]
}

@test "remove deletes the sidecar" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1:115.14.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/thunderbird"
    _mock_apt_defaults
    _mock_repo_tools
    module_standalone_main remove
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/thunderbird" ]]
}

@test "purge deletes the sidecar" {
    _load_module
    _scratch_pin_path
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1:115.14.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/thunderbird"
    _mock_apt_defaults
    _mock_repo_tools
    module_standalone_main purge
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/thunderbird" ]]
}

# ── Idempotency (AC-5 pattern) ───────────────────────────────────────────────

@test "install short-circuits when is_installed returns 0 (idempotency)" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    run install
    assert_success
    assert_output --partial "already installed"
}

@test "install twice with apt mocked exits 0 both times" {
    _load_module
    _mock_apt_defaults
    MOCK_PKG_VERSION="1:115.14.0"
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
    _mock_repo_tools
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

@test "doctor fails when the thunderbird binary is not on PATH" {
    _load_module
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/empty-bin"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/empty-bin" run doctor
    assert_failure
}

@test "doctor passes when the thunderbird binary is on PATH" {
    _load_module
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    printf '#!/usr/bin/env bash\nprintf "Thunderbird 115.14.0\\n"\n' \
        > "${INIT_UBUNTU_TEST_SCRATCH}/bin/thunderbird"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/thunderbird"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run doctor
    assert_success
}

@test "is_outdated returns zero when apt reports thunderbird upgradable" {
    _load_module
    MOCK_APT_UPGRADABLE='thunderbird/jammy 1:115.14.0 amd64 [upgradable from: 1:115.13.0]'
    _mock_apt_list
    run is_outdated
    assert_success
}

@test "is_outdated returns nonzero when thunderbird is not in the upgradable list" {
    _load_module
    MOCK_APT_UPGRADABLE='some-other-pkg/noble 1.0 amd64 [upgradable from: 0.9]'
    _mock_apt_list
    run is_outdated
    assert_failure
}

@test "is_outdated returns nonzero when apt output is empty" {
    _load_module
    MOCK_APT_UPGRADABLE=""
    _mock_apt_list
    run is_outdated
    assert_failure
}

# ── is_recommended (desktop-only gate) ───────────────────────────────────────

@test "is_recommended is zero on desktop when not installed" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    INIT_UBUNTU_FORM_FACTOR=desktop run is_recommended
    assert_success
}

@test "is_recommended is nonzero on desktop when already installed" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    INIT_UBUNTU_FORM_FACTOR=desktop run is_recommended
    assert_failure
}

@test "is_recommended is nonzero on headless form factors (server / wsl)" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    INIT_UBUNTU_FORM_FACTOR=server run is_recommended
    assert_failure
    INIT_UBUNTU_FORM_FACTOR=wsl run is_recommended
    assert_failure
}

@test "is_recommended is nonzero when the form factor is unknown or unset" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    INIT_UBUNTU_FORM_FACTOR='' run is_recommended
    assert_failure
    INIT_UBUNTU_FORM_FACTOR=rpi-5 run is_recommended
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
    assert_output --partial "thunderbird"
}

@test "standalone: unknown phase returns exit 2" {
    run _standalone_module nope
    assert_failure 2
}

@test "standalone: info prints metadata" {
    run _standalone_module info
    assert_success
    assert_output --partial "name:        thunderbird"
    assert_output --partial "category:    optional"
    assert_output --partial "email"
}

@test "standalone: info shows the desktop-only platform gate" {
    run _standalone_module info
    assert_success
    assert_output --partial "platforms:   desktop"
}

@test "standalone: info --lang=zh-TW prints localized description" {
    run _standalone_module info --lang=zh-TW
    assert_success
    assert_output --partial "電子郵件"
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

@test "standalone: upgrade --dry-run exits 0" {
    run _standalone_module upgrade --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "standalone: remove --dry-run exits 0" {
    run _standalone_module remove --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "standalone: purge --dry-run exits 0" {
    run _standalone_module purge --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "standalone: verify --dry-run exits 0" {
    run _standalone_module verify --dry-run
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

@test "standalone: is-recommended is implemented (exit != 2)" {
    run _standalone_module is-recommended
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "standalone: is-outdated is implemented (exit != 2)" {
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    printf '#!/bin/sh\nexit 0\n' > "${INIT_UBUNTU_TEST_SCRATCH}/bin/apt"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/apt"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run _standalone_module is-outdated
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "standalone: doctor is implemented (exit != 2)" {
    run _standalone_module doctor
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}
