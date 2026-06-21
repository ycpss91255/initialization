#!/usr/bin/env bats
# test/unit/module/shell_spec.bats — module/shell.module.sh
#
# Per Q29: smoke / metadata / lifecycle dry-run / no-side-fx / idempotency /
# standalone CLI / module-specific (apt archetype, multi-package set,
# sidecar + state semantics ADR-0001).
#
# shell is a bare Archetype-A module: ssh + keychain + xclip via apt, no
# lifecycle overrides beyond detect/is_recommended, and no doctor() —
# the standalone CLI reports doctor as not implemented (exit 2).

bats_require_minimum_version 1.5.0

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
    # shellcheck source=../../../module/shell.module.sh
    source "${MODULE_DIR}/shell.module.sh"
}

# _standalone_module runs the module as a self-contained CLI (the same
# entry users hit when they type `bash module/shell.module.sh ...`).
_standalone_module() {
    bash "${MODULE_DIR}/shell.module.sh" "$@"
}

# ── Controllable mocks ───────────────────────────────────────────────────────
# Each shadowed function is defined exactly once and parameterized via
# MOCK_* variables, so every definition stays reachable for the linter
# (avoids SC2317 without disable directives).

# is_installed mock: MOCK_IS_INSTALLED_RC (0 = installed, 1 = not).
_mock_is_installed() {
    is_installed() { return "${MOCK_IS_INSTALLED_RC:-0}"; }
}

# dpkg mock for module_default_apt_is_installed. Called per package as
# `dpkg -l <pkg>` ($2 = pkg). MOCK_DPKG_RC=1 fails every package;
# MOCK_DPKG_MISSING=<pkg> fails only that one (partial-install scenario).
_mock_dpkg() {
    dpkg() {
        local _pkg="${2:-}"
        [[ "${MOCK_DPKG_RC:-0}" -eq 0 ]] || return "${MOCK_DPKG_RC}"
        if [[ -n "${MOCK_DPKG_MISSING:-}" && "${_pkg}" == "${MOCK_DPKG_MISSING}" ]]; then
            return 1
        fi
        printf 'ii  %s  1.0-1  amd64  mocked package\n' "${_pkg}"
    }
}

# apt archetype default mocks: MOCK_APT_<PHASE>_RC (default 0 = success).
_mock_apt_defaults() {
    module_default_apt_install() { return "${MOCK_APT_INSTALL_RC:-0}"; }
    module_default_apt_upgrade() { return "${MOCK_APT_UPGRADE_RC:-0}"; }
    module_default_apt_remove()  { return "${MOCK_APT_REMOVE_RC:-0}"; }
    module_default_apt_purge()   { return "${MOCK_APT_PURGE_RC:-0}"; }
}

# apt mock for module_default_apt_is_outdated: MOCK_APT_UPGRADABLE
# (full `apt list --upgradable` output to emit; empty = no output).
_mock_apt_list() {
    apt() { printf '%s' "${MOCK_APT_UPGRADABLE:-}"; }
}

# sudo-access mock: MOCK_SUDO_RC (0 = have sudo, 1 = no sudo).
_mock_have_sudo_access() {
    have_sudo_access() { return "${MOCK_SUDO_RC:-0}"; }
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "shell module file parses (bash -n)" {
    run bash -n "${MODULE_DIR}/shell.module.sh"
    assert_success
}

@test "shell module sources cleanly in engine mode (MODULE_STANDALONE=false)" {
    _load_module
    [[ "${MODULE_STANDALONE}" == "false" ]]
}

@test "shell module defines all 10 lifecycle functions (ADR-0002)" {
    _load_module
    local _fn
    for _fn in detect is_recommended is_installed install upgrade \
               remove purge verify is_outdated doctor; do
        declare -F "${_fn}" >/dev/null || {
            printf 'missing lifecycle function: %s\n' "${_fn}" >&2
            return 1
        }
    done
    # doctor is now wired by the apt archetype macro (module_default_doctor).
}

# ── Metadata sanity ──────────────────────────────────────────────────────────

@test "shell module declares NAME=shell" {
    _load_module
    [[ "${NAME}" == "shell" ]]
}

@test "shell module CATEGORY=recommended" {
    _load_module
    [[ "${CATEGORY}" == "recommended" ]]
}

@test "shell module TAGS contains shell and core" {
    _load_module
    [[ " ${TAGS[*]} " == *" shell "* ]]
    [[ " ${TAGS[*]} " == *" core "* ]]
}

@test "shell module depends on git + curl" {
    _load_module
    [[ " ${DEPENDS_ON[*]} " == *" git "* ]]
    [[ " ${DEPENDS_ON[*]} " == *" curl "* ]]
}

@test "shell module CONFLICTS_WITH is empty" {
    _load_module
    [[ "${#CONFLICTS_WITH[@]}" -eq 0 ]]
}

@test "shell DESCRIPTION is associative with en + zh-TW entries" {
    _load_module
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ -n "${DESCRIPTION[en]}" ]]
    [[ -n "${DESCRIPTION[zh-TW]}" ]]
}

@test "shell module_get_description returns language-specific text" {
    _load_module
    [[ "$(module_get_description en)" == *"ssh"* ]]
    [[ -n "$(module_get_description zh-TW)" ]]
    # Unknown language falls back to en.
    [[ "$(module_get_description xx)" == "$(module_get_description en)" ]]
}

@test "shell SUPPORTED_UBUNTU includes 22.04 24.04 26.04" {
    _load_module
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 22.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 24.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 26.04 "* ]]
}

@test "shell SUPPORTED_PLATFORMS covers desktop server wsl" {
    _load_module
    [[ " ${SUPPORTED_PLATFORMS[*]} " == *" desktop "* ]]
    [[ " ${SUPPORTED_PLATFORMS[*]} " == *" server "* ]]
    [[ " ${SUPPORTED_PLATFORMS[*]} " == *" wsl "* ]]
}

@test "shell module RISK_LEVEL=low and REBOOT_REQUIRED=false" {
    _load_module
    [[ "${RISK_LEVEL}" == "low" ]]
    [[ "${REBOOT_REQUIRED}" == "false" ]]
}

@test "shell module VERSION_PROVIDED=apt-managed" {
    _load_module
    [[ "${VERSION_PROVIDED}" == "apt-managed" ]]
}

@test "shell module SUPPORTS_USER_HOME=false and INSTALL_TARGET_DEFAULT=sudo" {
    _load_module
    [[ "${SUPPORTS_USER_HOME}" == "false" ]]
    [[ "${INSTALL_TARGET_DEFAULT}" == "sudo" ]]
}

@test "shell archetype data installs ssh + keychain + xclip (no PPA)" {
    _load_module
    [[ "${#APT_PKGS[@]}" -eq 3 ]]
    [[ " ${APT_PKGS[*]} " == *" ssh "* ]]
    [[ " ${APT_PKGS[*]} " == *" keychain "* ]]
    [[ " ${APT_PKGS[*]} " == *" xclip "* ]]
    [[ -z "${APT_PPA}" ]]
}

@test "shell declares no POST_INSTALL_MESSAGE" {
    _load_module
    [[ -z "$(module_get_post_install_message en)" ]]
}

# ── is_installed: multi-package, relies on dpkg ──────────────────────────────

@test "is_installed returns nonzero when dpkg reports no package" {
    _load_module
    MOCK_DPKG_RC=1
    _mock_dpkg
    run is_installed
    assert_failure
}

@test "is_installed returns zero when dpkg reports all three packages as ii" {
    _load_module
    _mock_dpkg
    run is_installed
    assert_success
}

@test "is_installed returns nonzero when one package (xclip) is missing" {
    _load_module
    MOCK_DPKG_MISSING="xclip"
    _mock_dpkg
    run is_installed
    assert_failure
}

# ── Lifecycle dry-run (AC-12 pattern) ────────────────────────────────────────

@test "install in dry-run mode is a no-op" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "install dry-run names all three packages" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    assert_output --partial "ssh keychain xclip"
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
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/shell" ]]
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/state.json" ]]
}

@test "dry-run remove leaves an existing sidecar in place" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf 'apt-managed\n' > "${INIT_UBUNTU_STATE_DIR}/versions/shell"
    INIT_UBUNTU_DRY_RUN=true run remove
    assert_success
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/shell" ]]
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

# ── Sidecar / state semantics (ADR-0001) ─────────────────────────────────────

@test "install never touches state.json (ADR-0001 / AC-23 pattern)" {
    _load_module
    printf '{"schema_version":"0.1.0","installed":{}}\n' \
        > "${INIT_UBUNTU_STATE_DIR}/state.json"
    local _before; _before="$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")"
    _mock_apt_defaults
    install
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")" == "${_before}" ]]
}

@test "archetype-default install writes no sidecar (version stays apt-managed)" {
    # shell relies on the bare apt archetype: no install override, so no
    # per-module version sidecar is recorded (VERSION_PROVIDED=apt-managed).
    _load_module
    _mock_apt_defaults
    run install
    assert_success
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/shell" ]]
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
    run install
    assert_success
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    run install
    assert_success
}

@test "remove is a no-op when not installed (module_skip_if_not_installed)" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    run remove
    assert_success
    assert_output --partial "not installed; nothing to do"
}

@test "remove is idempotent — second run still exits 0" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    run remove
    assert_success
    run remove
    assert_success
}

# ── apt archetype routing ────────────────────────────────────────────────────

@test "upgrade falls back to install when not installed" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    install() { log_info "[${NAME}] mock install ran"; }
    run upgrade
    assert_success
    assert_output --partial "running install instead"
    assert_output --partial "mock install ran"
}

@test "install without sudo fails and lists all three packages" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    MOCK_SUDO_RC=1
    _mock_have_sudo_access
    run install
    assert_failure
    assert_output --partial "no sudo"
    assert_output --partial "ssh keychain xclip"
}

# ── verify / is_outdated ─────────────────────────────────────────────────────

@test "verify fails when not installed" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    run verify
    assert_failure
}

@test "verify passes when installed and ssh + keychain are on PATH" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    local _b
    for _b in ssh keychain; do
        printf '#!/bin/sh\nexit 0\n' > "${INIT_UBUNTU_TEST_SCRATCH}/bin/${_b}"
        chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/${_b}"
    done
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run verify
    assert_success
}

@test "verify fails when TEST_VERIFY_CMD fails" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    TEST_VERIFY_CMD="false"
    run verify
    assert_failure
}

@test "is_outdated returns zero when apt reports ssh upgradable" {
    _load_module
    MOCK_APT_UPGRADABLE='ssh/noble-updates 1:9.6p1-3ubuntu14 all [upgradable from: 1:9.6p1-3ubuntu13]'
    _mock_apt_list
    run is_outdated
    assert_success
}

@test "is_outdated returns zero when only xclip is upgradable (any of 3)" {
    _load_module
    MOCK_APT_UPGRADABLE='xclip/noble 0.13-3 amd64 [upgradable from: 0.13-2]'
    _mock_apt_list
    run is_outdated
    assert_success
}

@test "is_outdated returns nonzero when no shell package is in the list" {
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

# ── is_recommended ───────────────────────────────────────────────────────────

@test "is_recommended is nonzero when already installed" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    run is_recommended
    assert_failure
}

@test "is_recommended is zero when not installed" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    run is_recommended
    assert_success
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
    assert_output --partial "shell"
    assert_output --partial "apt-managed"
}

@test "standalone: unknown phase returns exit 2" {
    run _standalone_module nope
    assert_failure 2
}

@test "standalone: info prints metadata" {
    run _standalone_module info
    assert_success
    assert_output --partial "name:        shell"
    assert_output --partial "category:    recommended"
    assert_output --partial "depends_on:  git curl"
}

@test "standalone: info --lang=zh-TW prints localized description" {
    run _standalone_module info --lang=zh-TW
    assert_success
    assert_output --partial "基礎工具"
}

@test "standalone: status reports installed + outdated fields" {
    run _standalone_module status
    assert_success
    assert_output --partial "installed:"
    assert_output --partial "outdated:"
}

# ── AC-25: phases runnable via standalone CLI ────────────────────────────────

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
    # Fake `apt` on PATH: the test container has no apt, and a bare
    # command-not-found (127) would trip bats' BW01 warning.
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    printf '#!/bin/sh\nexit 0\n' > "${INIT_UBUNTU_TEST_SCRATCH}/bin/apt"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/apt"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run _standalone_module is-outdated
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "standalone: doctor is implemented (default = is_installed; exit != 2)" {
    # doctor is now the apt archetype default (module_default_doctor); shell is
    # not installed in the test env, so it returns 1, never the old exit-2 gap.
    run _standalone_module doctor
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}
