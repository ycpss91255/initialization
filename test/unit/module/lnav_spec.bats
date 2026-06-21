#!/usr/bin/env bats
# test/unit/module/lnav_spec.bats — module/lnav.module.sh
#
# Per Q29: smoke / metadata / lifecycle dry-run / no-side-fx / idempotency /
# standalone CLI / module-specific (custom archetype: apt package + legacy
# lnav_pkg config bundle deploy, sidecar lifecycle ADR-0001).

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
    # shellcheck source=../../../module/lnav.module.sh
    source "${MODULE_DIR}/lnav.module.sh"
}

# _load_module_scratch_home points HOME at a per-test scratch dir BEFORE
# sourcing, so the module computes its config destination under scratch.
_load_module_scratch_home() {
    HOME="${INIT_UBUNTU_TEST_SCRATCH}/home"
    export HOME
    mkdir -p "${HOME}"
    _load_module
}

# _standalone_module runs the module as a self-contained CLI (the same
# entry users hit when they type `bash module/lnav.module.sh ...`).
_standalone_module() {
    bash "${MODULE_DIR}/lnav.module.sh" "$@"
}

# ── Controllable mocks ───────────────────────────────────────────────────────
# Each shadowed function is defined exactly once and parameterized via
# MOCK_* variables, so every definition stays reachable for the linter
# (avoids SC2317 without disable directives).

# is_installed mock: MOCK_IS_INSTALLED_RC (0 = installed, 1 = not).
_mock_is_installed() {
    is_installed() { return "${MOCK_IS_INSTALLED_RC:-0}"; }
}

# dpkg mock for module_default_apt_is_installed:
#   MOCK_DPKG_OUTPUT (line printed, e.g. "ii  lnav ...") / MOCK_DPKG_RC.
_mock_dpkg() {
    dpkg() {
        [[ -n "${MOCK_DPKG_OUTPUT:-}" ]] && printf '%s\n' "${MOCK_DPKG_OUTPUT}"
        return "${MOCK_DPKG_RC:-0}"
    }
}

# apt archetype default mocks: MOCK_APT_<PHASE>_RC (default 0 = success).
_mock_apt_defaults() {
    module_default_apt_install() { return "${MOCK_APT_INSTALL_RC:-0}"; }
    module_default_apt_upgrade() { return "${MOCK_APT_UPGRADE_RC:-0}"; }
    module_default_apt_remove()  { return "${MOCK_APT_REMOVE_RC:-0}"; }
    module_default_apt_purge()   { return "${MOCK_APT_PURGE_RC:-0}"; }
}

# dpkg-query mock for the sidecar version: MOCK_PKG_VERSION (empty = fail).
_mock_dpkg_query() {
    dpkg-query() {
        [[ -n "${MOCK_PKG_VERSION:-}" ]] || return 1
        printf '%s' "${MOCK_PKG_VERSION}"
    }
}

# apt mock for module_default_apt_is_outdated: MOCK_APT_UPGRADABLE
# (full `apt list --upgradable` output to emit; empty = no output).
_mock_apt_list() {
    apt() { printf '%s' "${MOCK_APT_UPGRADABLE:-}"; }
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "lnav module file parses (bash -n)" {
    run bash -n "${MODULE_DIR}/lnav.module.sh"
    assert_success
}

@test "lnav module sources cleanly in engine mode (MODULE_STANDALONE=false)" {
    _load_module
    [[ "${MODULE_STANDALONE}" == "false" ]]
}

@test "lnav module defines all 10 lifecycle functions" {
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

@test "lnav module declares NAME=lnav" {
    _load_module
    [[ "${NAME}" == "lnav" ]]
}

@test "lnav module CATEGORY=optional" {
    _load_module
    [[ "${CATEGORY}" == "optional" ]]
}

@test "lnav module TAGS contains logs" {
    _load_module
    [[ " ${TAGS[*]} " == *" logs "* ]]
}

@test "lnav module DEPENDS_ON is empty (issue #62 / Q39)" {
    _load_module
    [[ "${#DEPENDS_ON[@]}" -eq 0 ]]
}

@test "lnav DESCRIPTION is associative with en + zh-TW entries" {
    _load_module
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ -n "${DESCRIPTION[en]}" ]]
    [[ -n "${DESCRIPTION[zh-TW]}" ]]
}

@test "lnav module_get_description returns language-specific text" {
    _load_module
    [[ "$(module_get_description en)" == *"log"* ]]
    [[ -n "$(module_get_description zh-TW)" ]]
    # Unknown language falls back to en.
    [[ "$(module_get_description xx)" == "$(module_get_description en)" ]]
}

@test "lnav SUPPORTED_UBUNTU includes 22.04 24.04 26.04" {
    _load_module
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 22.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 24.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 26.04 "* ]]
}

@test "lnav module RISK_LEVEL=low" {
    _load_module
    [[ "${RISK_LEVEL}" == "low" ]]
}

@test "lnav module VERSION_PROVIDED=apt-managed" {
    _load_module
    [[ "${VERSION_PROVIDED}" == "apt-managed" ]]
}

@test "lnav HOMEPAGE points at lnav.org" {
    _load_module
    [[ "${HOMEPAGE}" == *"lnav.org"* ]]
}

@test "lnav archetype data installs the lnav apt package" {
    _load_module
    [[ " ${APT_PKGS[*]} " == *" lnav "* ]]
}

@test "lnav config bundle source points at the legacy lnav_pkg dir" {
    _load_module
    [[ "${LNAV_CONFIG_SRC}" == *"/config/lnav_pkg" ]]
    [[ -d "${LNAV_CONFIG_SRC}" ]]
    [[ -f "${LNAV_CONFIG_SRC}/config.json" ]]
}

@test "lnav config bundle destination is HOME/.config/lnav" {
    _load_module_scratch_home
    [[ "${LNAV_CONFIG_DEST}" == "${HOME}/.config/lnav" ]]
}

@test "lnav POST_INSTALL_MESSAGE mentions the config bundle" {
    _load_module
    [[ "$(module_get_post_install_message en)" == *"config"* ]]
    [[ -n "$(module_get_post_install_message zh-TW)" ]]
}

# ── is_installed: relies on dpkg ─────────────────────────────────────────────

@test "is_installed returns nonzero when dpkg does not report lnav" {
    _load_module
    MOCK_DPKG_RC=1
    _mock_dpkg
    run is_installed
    assert_failure
}

@test "is_installed returns zero when dpkg reports lnav as ii" {
    _load_module
    MOCK_DPKG_OUTPUT='ii  lnav  0.12.2  amd64  log file navigator'
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
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/lnav" ]]
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/state.json" ]]
}

@test "dry-run install deploys no config bundle into a scratch HOME" {
    _load_module_scratch_home
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    [[ ! -e "${HOME}/.config/lnav" ]]
}

@test "dry-run remove leaves an existing sidecar in place" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '0.12.2\n' > "${INIT_UBUNTU_STATE_DIR}/versions/lnav"
    INIT_UBUNTU_DRY_RUN=true run remove
    assert_success
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/lnav" ]]
}

@test "dry-run purge leaves a deployed config bundle in place" {
    _load_module_scratch_home
    mkdir -p "${HOME}/.config/lnav"
    printf '{}\n' > "${HOME}/.config/lnav/config.json"
    INIT_UBUNTU_DRY_RUN=true run purge
    assert_success
    [[ -f "${HOME}/.config/lnav/config.json" ]]
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

# ── Config bundle deploy (custom archetype half) ─────────────────────────────

@test "install deploys the lnav_pkg bundle into HOME/.config/lnav" {
    _load_module_scratch_home
    _mock_apt_defaults
    MOCK_PKG_VERSION="0.12.2"
    _mock_dpkg_query
    install
    [[ -f "${HOME}/.config/lnav/config.json" ]]
    [[ -f "${HOME}/.config/lnav/config/ui_settings.json" ]]
    [[ -f "${HOME}/.config/lnav/formats/installed/lidar_detection_pkg.json" ]]
}

@test "upgrade re-deploys the config bundle (repo copy wins)" {
    _load_module_scratch_home
    _mock_apt_defaults
    MOCK_PKG_VERSION="0.12.2"
    _mock_dpkg_query
    mkdir -p "${HOME}/.config/lnav"
    printf 'stale\n' > "${HOME}/.config/lnav/config.json"
    upgrade
    [[ "$(cat "${HOME}/.config/lnav/config.json")" != "stale" ]]
    grep -q '"theme"' "${HOME}/.config/lnav/config.json"
}

@test "install keeps user-added files alongside the bundle" {
    _load_module_scratch_home
    _mock_apt_defaults
    MOCK_PKG_VERSION="0.12.2"
    _mock_dpkg_query
    mkdir -p "${HOME}/.config/lnav/formats/installed"
    printf '{}\n' > "${HOME}/.config/lnav/formats/installed/user_format.json"
    install
    [[ -f "${HOME}/.config/lnav/formats/installed/user_format.json" ]]
    [[ -f "${HOME}/.config/lnav/formats/installed/lidar_detection_pkg.json" ]]
}

@test "remove keeps the deployed config bundle (remove vs purge)" {
    _load_module_scratch_home
    _mock_apt_defaults
    mkdir -p "${HOME}/.config/lnav"
    printf '{}\n' > "${HOME}/.config/lnav/config.json"
    remove
    [[ -f "${HOME}/.config/lnav/config.json" ]]
}

@test "purge wipes the deployed config bundle" {
    _load_module_scratch_home
    _mock_apt_defaults
    mkdir -p "${HOME}/.config/lnav/formats/installed"
    printf '{}\n' > "${HOME}/.config/lnav/config.json"
    purge
    [[ ! -e "${HOME}/.config/lnav" ]]
}

# ── Sidecar lifecycle (ADR-0001) ─────────────────────────────────────────────

@test "install writes the sidecar with the dpkg-reported version" {
    _load_module_scratch_home
    _mock_apt_defaults
    MOCK_PKG_VERSION="0.12.2"
    _mock_dpkg_query
    module_standalone_main install
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/lnav" ]]
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/lnav")" == "0.12.2" ]]
}

@test "install sidecar falls back to apt-managed when dpkg-query is empty" {
    _load_module_scratch_home
    _mock_apt_defaults
    MOCK_PKG_VERSION=""
    _mock_dpkg_query
    module_standalone_main install
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/lnav")" == "apt-managed" ]]
}

@test "install never touches state.json (ADR-0001 / AC-23 pattern)" {
    _load_module_scratch_home
    printf '{"schema_version":"0.1.0","installed":{}}\n' \
        > "${INIT_UBUNTU_STATE_DIR}/state.json"
    local _before; _before="$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")"
    _mock_apt_defaults
    MOCK_PKG_VERSION="0.12.2"
    _mock_dpkg_query
    module_standalone_main install
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")" == "${_before}" ]]
}

@test "failed apt install leaves no sidecar and no config bundle (ADR-0015)" {
    _load_module_scratch_home
    MOCK_APT_INSTALL_RC=1
    _mock_apt_defaults
    run module_standalone_main install
    assert_failure
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/lnav" ]]
    [[ ! -e "${HOME}/.config/lnav" ]]
}

@test "upgrade refreshes the sidecar version" {
    _load_module_scratch_home
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '0.11.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/lnav"
    _mock_apt_defaults
    MOCK_PKG_VERSION="0.12.2"
    _mock_dpkg_query
    module_standalone_main upgrade
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/lnav")" == "0.12.2" ]]
}

@test "remove deletes the sidecar" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '0.12.2\n' > "${INIT_UBUNTU_STATE_DIR}/versions/lnav"
    _mock_apt_defaults
    module_standalone_main remove
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/lnav" ]]
}

@test "purge deletes the sidecar" {
    _load_module_scratch_home
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '0.12.2\n' > "${INIT_UBUNTU_STATE_DIR}/versions/lnav"
    _mock_apt_defaults
    module_standalone_main purge
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/lnav" ]]
}

# ── Idempotency (AC-5 pattern) ───────────────────────────────────────────────

@test "install twice with apt mocked exits 0 both times" {
    _load_module_scratch_home
    _mock_apt_defaults
    MOCK_PKG_VERSION="0.12.2"
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

@test "doctor passes when the lnav binary answers -V" {
    _load_module_scratch_home
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    printf '#!/usr/bin/env bash\nprintf "lnav 0.12.2\\n"\n' \
        > "${INIT_UBUNTU_TEST_SCRATCH}/bin/lnav"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/lnav"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run doctor
    assert_success
}

@test "doctor warns (but passes) when the config bundle is missing" {
    _load_module_scratch_home
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    printf '#!/usr/bin/env bash\nprintf "lnav 0.12.2\\n"\n' \
        > "${INIT_UBUNTU_TEST_SCRATCH}/bin/lnav"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/lnav"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run doctor
    assert_success
    assert_output --partial "config bundle missing"
}

@test "doctor fails when the lnav binary is not on PATH" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/empty-bin"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/empty-bin" run doctor
    assert_failure
}

@test "is_outdated returns zero when apt reports lnav upgradable" {
    _load_module
    MOCK_APT_UPGRADABLE='lnav/noble-updates 0.12.2-1 amd64 [upgradable from: 0.12.0-1]'
    _mock_apt_list
    run is_outdated
    assert_success
}

@test "is_outdated returns nonzero when lnav is not in the upgradable list" {
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
    assert_output --partial "lnav"
}

@test "standalone: unknown phase returns exit 2" {
    run _standalone_module nope
    assert_failure 2
}

@test "standalone: info prints metadata" {
    run _standalone_module info
    assert_success
    assert_output --partial "name:        lnav"
    assert_output --partial "category:    optional"
    assert_output --partial "logs"
}

@test "standalone: info --lang=zh-TW prints localized description" {
    run _standalone_module info --lang=zh-TW
    assert_success
    assert_output --partial "日誌"
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
    # Fake `apt` on PATH: the test container has no apt, and a bare
    # command-not-found (127) would trip bats' BW01 warning.
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
