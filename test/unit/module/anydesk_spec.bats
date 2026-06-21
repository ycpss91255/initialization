#!/usr/bin/env bats
# test/unit/module/anydesk_spec.bats — module/anydesk.module.sh
#
# Per Q29: smoke / metadata / lifecycle dry-run / no-side-fx / idempotency /
# standalone CLI / module-specific (apt vendor-repo archetype, sidecar
# lifecycle ADR-0001, desktop-only platform gate Q49).

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
    # shellcheck source=../../../module/anydesk.module.sh
    source "${MODULE_DIR}/anydesk.module.sh"
}

# _standalone_module runs the module as a self-contained CLI (the same
# entry users hit when they type `bash module/anydesk.module.sh ...`).
_standalone_module() {
    bash "${MODULE_DIR}/anydesk.module.sh" "$@"
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
#   MOCK_DPKG_OUTPUT (line printed, e.g. "ii  anydesk ...") / MOCK_DPKG_RC.
_mock_dpkg() {
    dpkg() {
        [[ -n "${MOCK_DPKG_OUTPUT:-}" ]] && printf '%s\n' "${MOCK_DPKG_OUTPUT}"
        return "${MOCK_DPKG_RC:-0}"
    }
}

# apt archetype default mocks: MOCK_APT_<PHASE>_RC (default 0 = success),
# plus the anydesk-specific install collaborators (sudo probe + vendor
# repo setup: MOCK_SUDO_RC / MOCK_REPO_SETUP_RC).
_mock_apt_defaults() {
    module_default_apt_install() { return "${MOCK_APT_INSTALL_RC:-0}"; }
    module_default_apt_upgrade() { return "${MOCK_APT_UPGRADE_RC:-0}"; }
    module_default_apt_remove()  { return "${MOCK_APT_REMOVE_RC:-0}"; }
    module_default_apt_purge()   { return "${MOCK_APT_PURGE_RC:-0}"; }
    have_sudo_access()           { return "${MOCK_SUDO_RC:-0}"; }
    _anydesk_setup_apt_repo()    { return "${MOCK_REPO_SETUP_RC:-0}"; }
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

# Vendor-repo toolchain mocks for exercising _anydesk_setup_apt_repo
# against scratch paths: pass-through sudo, fake curl (MOCK_CURL_BODY,
# optional call log at MOCK_CURL_LOG), gpg that passes stdin through
# (the module pipes `gpg --dearmor` into `sudo tee`).
_mock_repo_tools() {
    sudo() { "$@"; }
    have_sudo_access() { return 0; }
    curl() {
        [[ -n "${MOCK_CURL_LOG:-}" ]] && printf 'curl %s\n' "$*" >> "${MOCK_CURL_LOG}"
        printf '%s' "${MOCK_CURL_BODY:-FAKE-ARMORED-KEY}"
    }
    gpg() { cat; }
}

# Point the vendor repo file paths into the per-test scratch dir.
_scratch_repo_paths() {
    ANYDESK_KEYRING="${INIT_UBUNTU_TEST_SCRATCH}/keyrings/anydesk.gpg"
    ANYDESK_APT_LIST="${INIT_UBUNTU_TEST_SCRATCH}/sources.list.d/anydesk.list"
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "anydesk module file parses (bash -n)" {
    run bash -n "${MODULE_DIR}/anydesk.module.sh"
    assert_success
}

@test "anydesk module sources cleanly in engine mode (MODULE_STANDALONE=false)" {
    _load_module
    [[ "${MODULE_STANDALONE}" == "false" ]]
}

@test "anydesk module defines all 10 lifecycle functions" {
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

@test "anydesk module declares NAME=anydesk" {
    _load_module
    [[ "${NAME}" == "anydesk" ]]
}

@test "anydesk module CATEGORY=optional" {
    _load_module
    [[ "${CATEGORY}" == "optional" ]]
}

@test "anydesk module TAGS contains remote" {
    _load_module
    [[ " ${TAGS[*]} " == *" remote "* ]]
}

@test "anydesk DEPENDS_ON is exactly curl (module names only, Q39)" {
    _load_module
    [[ "${#DEPENDS_ON[@]}" -eq 1 ]]
    [[ "${DEPENDS_ON[0]}" == "curl" ]]
}

@test "anydesk SUPPORTED_PLATFORMS is desktop-only (Q49)" {
    _load_module
    [[ "${#SUPPORTED_PLATFORMS[@]}" -eq 1 ]]
    [[ "${SUPPORTED_PLATFORMS[0]}" == "desktop" ]]
}

@test "anydesk DESCRIPTION is associative with en + zh-TW entries" {
    _load_module
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ -n "${DESCRIPTION[en]}" ]]
    [[ -n "${DESCRIPTION[zh-TW]}" ]]
}

@test "anydesk module_get_description returns language-specific text" {
    _load_module
    [[ "$(module_get_description en)" == *"AnyDesk"* ]]
    [[ -n "$(module_get_description zh-TW)" ]]
    # Unknown language falls back to en.
    [[ "$(module_get_description xx)" == "$(module_get_description en)" ]]
}

@test "anydesk SUPPORTED_UBUNTU includes 22.04 24.04 26.04" {
    _load_module
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 22.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 24.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 26.04 "* ]]
}

@test "anydesk module RISK_LEVEL=low" {
    _load_module
    [[ "${RISK_LEVEL}" == "low" ]]
}

@test "anydesk module VERSION_PROVIDED=apt-managed" {
    _load_module
    [[ "${VERSION_PROVIDED}" == "apt-managed" ]]
}

@test "anydesk HOMEPAGE points at anydesk.com" {
    _load_module
    [[ "${HOMEPAGE}" == *"anydesk.com"* ]]
}

@test "anydesk archetype data installs the anydesk apt package" {
    _load_module
    [[ " ${APT_PKGS[*]} " == *" anydesk "* ]]
}

@test "anydesk vendor repo constants match the upstream deb source" {
    _load_module
    [[ "${ANYDESK_KEY_URL}" == "https://keys.anydesk.com/repos/DEB-GPG-KEY" ]]
    [[ "${ANYDESK_REPO_URL}" == "https://deb.anydesk.com" ]]
    [[ "${ANYDESK_KEYRING}" == "/etc/apt/keyrings/anydesk.gpg" ]]
    [[ "${ANYDESK_APT_LIST}" == "/etc/apt/sources.list.d/anydesk.list" ]]
}

# ── is_installed: relies on dpkg ─────────────────────────────────────────────

@test "is_installed returns nonzero when dpkg does not report anydesk" {
    _load_module
    MOCK_DPKG_RC=1
    _mock_dpkg
    run is_installed
    assert_failure
}

@test "is_installed returns zero when dpkg reports anydesk as ii" {
    _load_module
    MOCK_DPKG_OUTPUT='ii  anydesk  6.4.0  amd64  remote desktop client'
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
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/anydesk" ]]
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/state.json" ]]
}

@test "dry-run purge leaves existing vendor repo files in place" {
    _load_module
    _scratch_repo_paths
    mkdir -p "$(dirname -- "${ANYDESK_KEYRING}")" "$(dirname -- "${ANYDESK_APT_LIST}")"
    printf 'KEY\n' > "${ANYDESK_KEYRING}"
    printf 'deb ...\n' > "${ANYDESK_APT_LIST}"
    INIT_UBUNTU_DRY_RUN=true run purge
    assert_success
    [[ -f "${ANYDESK_KEYRING}" ]]
    [[ -f "${ANYDESK_APT_LIST}" ]]
}

@test "dry-run remove leaves an existing sidecar in place" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '6.4.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/anydesk"
    INIT_UBUNTU_DRY_RUN=true run remove
    assert_success
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/anydesk" ]]
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

# ── Vendor apt repo setup (module-specific) ──────────────────────────────────

@test "_anydesk_setup_apt_repo writes the keyring and the sources list" {
    _load_module
    _scratch_repo_paths
    _mock_repo_tools
    run _anydesk_setup_apt_repo
    assert_success
    [[ -f "${ANYDESK_KEYRING}" ]]
    [[ "$(cat "${ANYDESK_KEYRING}")" == "FAKE-ARMORED-KEY" ]]
    [[ -f "${ANYDESK_APT_LIST}" ]]
}

@test "_anydesk_setup_apt_repo sources line pins signed-by to the keyring" {
    _load_module
    _scratch_repo_paths
    _mock_repo_tools
    _anydesk_setup_apt_repo
    run cat "${ANYDESK_APT_LIST}"
    assert_output --partial "deb [signed-by=${ANYDESK_KEYRING}]"
    assert_output --partial "https://deb.anydesk.com all main"
}

@test "_anydesk_setup_apt_repo skips the key download when the keyring exists" {
    _load_module
    _scratch_repo_paths
    _mock_repo_tools
    MOCK_CURL_LOG="${INIT_UBUNTU_TEST_SCRATCH}/curl.log"
    mkdir -p "$(dirname -- "${ANYDESK_KEYRING}")"
    printf 'EXISTING-KEY' > "${ANYDESK_KEYRING}"
    run _anydesk_setup_apt_repo
    assert_success
    [[ ! -s "${MOCK_CURL_LOG}" ]]
    [[ "$(cat "${ANYDESK_KEYRING}")" == "EXISTING-KEY" ]]
}

@test "install fails (and writes no sidecar) when the repo setup fails" {
    _load_module
    _mock_apt_defaults
    MOCK_REPO_SETUP_RC=1
    run install
    assert_failure
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/anydesk" ]]
}

@test "install fails when sudo is unavailable" {
    _load_module
    _mock_apt_defaults
    MOCK_SUDO_RC=1
    run install
    assert_failure
    assert_output --partial "sudo"
}

@test "purge removes the vendor keyring and sources list" {
    _load_module
    _scratch_repo_paths
    _mock_repo_tools
    _mock_apt_defaults
    mkdir -p "$(dirname -- "${ANYDESK_KEYRING}")" "$(dirname -- "${ANYDESK_APT_LIST}")"
    printf 'KEY\n' > "${ANYDESK_KEYRING}"
    printf 'deb ...\n' > "${ANYDESK_APT_LIST}"
    run purge
    assert_success
    [[ ! -e "${ANYDESK_KEYRING}" ]]
    [[ ! -e "${ANYDESK_APT_LIST}" ]]
}

@test "purge without sudo still exits 0 and leaves the repo files" {
    _load_module
    _scratch_repo_paths
    _mock_apt_defaults
    MOCK_SUDO_RC=1
    mkdir -p "$(dirname -- "${ANYDESK_KEYRING}")" "$(dirname -- "${ANYDESK_APT_LIST}")"
    printf 'KEY\n' > "${ANYDESK_KEYRING}"
    printf 'deb ...\n' > "${ANYDESK_APT_LIST}"
    run purge
    assert_success
    [[ -f "${ANYDESK_KEYRING}" ]]
    [[ -f "${ANYDESK_APT_LIST}" ]]
}

@test "remove keeps the vendor repo files (only purge drops them)" {
    _load_module
    _scratch_repo_paths
    _mock_repo_tools
    _mock_apt_defaults
    mkdir -p "$(dirname -- "${ANYDESK_KEYRING}")" "$(dirname -- "${ANYDESK_APT_LIST}")"
    printf 'KEY\n' > "${ANYDESK_KEYRING}"
    printf 'deb ...\n' > "${ANYDESK_APT_LIST}"
    run remove
    assert_success
    [[ -f "${ANYDESK_KEYRING}" ]]
    [[ -f "${ANYDESK_APT_LIST}" ]]
}

# ── Sidecar lifecycle (ADR-0001) ─────────────────────────────────────────────

@test "install writes the sidecar with the dpkg-reported version" {
    _load_module
    _mock_apt_defaults
    MOCK_PKG_VERSION="6.4.0"
    _mock_dpkg_query
    install
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/anydesk" ]]
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/anydesk")" == "6.4.0" ]]
}

@test "install sidecar falls back to apt-managed when dpkg-query is empty" {
    _load_module
    _mock_apt_defaults
    MOCK_PKG_VERSION=""
    _mock_dpkg_query
    install
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/anydesk")" == "apt-managed" ]]
}

@test "install never touches state.json (ADR-0001 / AC-23 pattern)" {
    _load_module
    printf '{"schema_version":"0.1.0","installed":{}}\n' \
        > "${INIT_UBUNTU_STATE_DIR}/state.json"
    local _before; _before="$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")"
    _mock_apt_defaults
    MOCK_PKG_VERSION="6.4.0"
    _mock_dpkg_query
    install
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")" == "${_before}" ]]
}

@test "failed apt install leaves no sidecar behind (ADR-0015)" {
    _load_module
    MOCK_APT_INSTALL_RC=1
    _mock_apt_defaults
    run install
    assert_failure
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/anydesk" ]]
}

@test "upgrade refreshes the sidecar version" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '6.3.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/anydesk"
    _mock_apt_defaults
    MOCK_PKG_VERSION="6.4.0"
    _mock_dpkg_query
    upgrade
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/anydesk")" == "6.4.0" ]]
}

@test "remove deletes the sidecar" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '6.4.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/anydesk"
    _mock_apt_defaults
    remove
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/anydesk" ]]
}

@test "purge deletes the sidecar" {
    _load_module
    _scratch_repo_paths
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '6.4.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/anydesk"
    _mock_apt_defaults
    _mock_repo_tools
    purge
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/anydesk" ]]
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
    MOCK_PKG_VERSION="6.4.0"
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

@test "doctor passes when the anydesk binary answers --version" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    printf '#!/usr/bin/env bash\nprintf "anydesk 6.4.0\\n"\n' \
        > "${INIT_UBUNTU_TEST_SCRATCH}/bin/anydesk"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/anydesk"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run doctor
    assert_success
}

@test "is_outdated returns zero when apt reports anydesk upgradable" {
    _load_module
    MOCK_APT_UPGRADABLE='anydesk/all 6.4.1 amd64 [upgradable from: 6.4.0]'
    _mock_apt_list
    run is_outdated
    assert_success
}

@test "is_outdated returns nonzero when anydesk is not in the upgradable list" {
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

# ── is_recommended (desktop-only gate, Q49 / module-spec §4.3.1) ─────────────

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
    assert_output --partial "anydesk"
}

@test "standalone: unknown phase returns exit 2" {
    run _standalone_module nope
    assert_failure 2
}

@test "standalone: info prints metadata" {
    run _standalone_module info
    assert_success
    assert_output --partial "name:        anydesk"
    assert_output --partial "category:    optional"
    assert_output --partial "remote"
}

@test "standalone: info shows the desktop-only platform gate" {
    run _standalone_module info
    assert_success
    assert_output --partial "platforms:   desktop"
}

@test "standalone: info --lang=zh-TW prints localized description" {
    run _standalone_module info --lang=zh-TW
    assert_success
    assert_output --partial "遠端桌面"
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
