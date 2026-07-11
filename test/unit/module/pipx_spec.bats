#!/usr/bin/env bats
# test/unit/module/pipx_spec.bats — module/pipx.module.sh
#
# Foundation apt module for the small-tools modularization program: pipx, the
# isolated Python-app installer. Archetype A (apt) with super-call install/
# upgrade overrides that run `pipx ensurepath`, and a doctor() that probes
# `pipx --version`. DEPENDS_ON=("python3"). Mirrors the build-essential
# archetype-A spec plus the ensurepath seam.

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
    # shellcheck source=../../../module/pipx.module.sh
    source "${MODULE_DIR}/pipx.module.sh"
}

_standalone_module() {
    bash "${MODULE_DIR}/pipx.module.sh" "$@"
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

# pipx-execution seam: records argv into MOCK_PIPX_LOG (one line per call).
_mock_pipx_seam() {
    MOCK_PIPX_LOG="${INIT_UBUNTU_TEST_SCRATCH}/pipx.log"
    : > "${MOCK_PIPX_LOG}"
    _pipx() {
        printf '%s\n' "$*" >> "${MOCK_PIPX_LOG}"
        return "${MOCK_PIPX_RC:-0}"
    }
}

# Put a fake pipx answering --version on PATH (exit code = $1, default 0) so
# `command -v pipx` in _pipx_ensurepath / doctor resolves.
_fake_pipx_bin() {
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    printf '#!/usr/bin/env bash\nprintf "1.4.3\\n"\nexit %s\n' "${1:-0}" \
        > "${INIT_UBUNTU_TEST_SCRATCH}/bin/pipx"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/pipx"
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "pipx module file parses (bash -n)" {
    run bash -n "${MODULE_DIR}/pipx.module.sh"
    assert_success
}

@test "pipx module sources cleanly in engine mode" {
    _load_module
    [[ "${MODULE_STANDALONE}" == "false" ]]
}

@test "pipx module defines all 10 lifecycle functions" {
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

@test "pipx module declares NAME=pipx" {
    _load_module
    [[ "${NAME}" == "pipx" ]]
}

@test "pipx module CATEGORY=base" {
    _load_module
    [[ "${CATEGORY}" == "base" ]]
}

@test "pipx module TAGS contains python" {
    _load_module
    [[ " ${TAGS[*]} " == *" python "* ]]
}

@test "pipx module DEPENDS_ON contains python3" {
    _load_module
    [[ " ${DEPENDS_ON[*]} " == *" python3 "* ]]
}

@test "pipx DESCRIPTION is associative with en + zh-TW entries" {
    _load_module
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ -n "${DESCRIPTION[en]}" ]]
    [[ -n "${DESCRIPTION[zh-TW]}" ]]
}

@test "pipx module_get_description returns text + en fallback" {
    _load_module
    [[ "$(module_get_description en)" == *"pipx"* ]]
    [[ -n "$(module_get_description zh-TW)" ]]
    [[ "$(module_get_description xx)" == "$(module_get_description en)" ]]
}

@test "pipx POST_INSTALL_MESSAGE mentions ensurepath / PATH" {
    _load_module
    [[ "$(module_get_post_install_message en)" == *"ensurepath"* ]]
    [[ -n "$(module_get_post_install_message zh-TW)" ]]
}

@test "pipx SUPPORTED_UBUNTU includes 22.04 24.04 26.04" {
    _load_module
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 22.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 24.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 26.04 "* ]]
}

@test "pipx RISK_LEVEL=low and VERSION_PROVIDED=apt-managed" {
    _load_module
    [[ "${RISK_LEVEL}" == "low" ]]
    [[ "${VERSION_PROVIDED}" == "apt-managed" ]]
}

@test "pipx archetype data installs the pipx apt package" {
    _load_module
    [[ " ${APT_PKGS[*]} " == *" pipx "* ]]
    [[ "${#APT_PKGS[@]}" -eq 1 ]]
    [[ -z "${APT_PPA}" ]]
}

@test "pipx TEST_VERIFY_CMD exercises the pipx binary" {
    _load_module
    [[ "${TEST_VERIFY_CMD}" == *"pipx"* ]]
}

# ── is_installed ─────────────────────────────────────────────────────────────

@test "is_installed returns nonzero when dpkg does not report pipx" {
    _load_module
    MOCK_DPKG_RC=1
    _mock_dpkg
    run is_installed
    assert_failure
}

@test "is_installed returns zero when dpkg reports pipx as ii" {
    _load_module
    MOCK_DPKG_OUTPUT='ii  pipx  1.4.3-1  all  install/run Python applications'
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
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/pipx" ]]
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/state.json" ]]
}

@test "dry-run install never runs pipx ensurepath" {
    _load_module
    _mock_pipx_seam
    _fake_pipx_bin
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" \
        INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    [[ ! -s "${MOCK_PIPX_LOG}" ]]
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

# ── install / upgrade: apt + ensurepath super-call (archetype core) ──────────

@test "install runs pipx ensurepath after the apt install" {
    _load_module
    _mock_apt_defaults
    _mock_pipx_seam
    _fake_pipx_bin
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" install
    grep -q '^ensurepath$' "${MOCK_PIPX_LOG}"
}

@test "install skips ensurepath when pipx is not on PATH (best-effort)" {
    _load_module
    _mock_apt_defaults
    _mock_pipx_seam
    # No pipx bin on PATH -> _pipx_ensurepath short-circuits, install still ok.
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/empty-bin:${PATH}" run install
    assert_success
    [[ ! -s "${MOCK_PIPX_LOG}" ]]
}

@test "install propagates a failed apt install" {
    _load_module
    MOCK_APT_INSTALL_RC=1
    _mock_apt_defaults
    _mock_pipx_seam
    run install
    assert_failure
}

@test "upgrade runs pipx ensurepath after the apt upgrade" {
    _load_module
    _mock_apt_defaults
    _mock_pipx_seam
    _fake_pipx_bin
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" upgrade
    grep -q '^ensurepath$' "${MOCK_PIPX_LOG}"
}

@test "install tolerates a failed pipx ensurepath (warns, still succeeds)" {
    _load_module
    _mock_apt_defaults
    MOCK_PIPX_RC=1
    _mock_pipx_seam
    _fake_pipx_bin
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run install
    assert_success
    assert_output --partial "ensurepath"
}

# ── Sidecar lifecycle (ADR-0001) ─────────────────────────────────────────────

@test "install writes the sidecar with the dpkg-reported version" {
    _load_module
    _mock_apt_defaults
    MOCK_PKG_VERSION="1.4.3-1"
    _mock_dpkg_query
    module_standalone_main install
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/pipx" ]]
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/pipx")" == "1.4.3-1" ]]
}

@test "install sidecar falls back to apt-managed when dpkg-query is empty" {
    _load_module
    _mock_apt_defaults
    MOCK_PKG_VERSION=""
    _mock_dpkg_query
    module_standalone_main install
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/pipx")" == "apt-managed" ]]
}

@test "install never touches state.json (ADR-0001)" {
    _load_module
    printf '{"version":"0.2.0","installed":{}}\n' \
        > "${INIT_UBUNTU_STATE_DIR}/state.json"
    local _before; _before="$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")"
    _mock_apt_defaults
    MOCK_PKG_VERSION="1.4.3-1"
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
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/pipx" ]]
}

@test "remove deletes the sidecar" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.4.3\n' > "${INIT_UBUNTU_STATE_DIR}/versions/pipx"
    _mock_apt_defaults
    module_standalone_main remove
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/pipx" ]]
}

@test "purge deletes the sidecar" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.4.3\n' > "${INIT_UBUNTU_STATE_DIR}/versions/pipx"
    _mock_apt_defaults
    module_standalone_main purge
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/pipx" ]]
}

# ── Idempotency ──────────────────────────────────────────────────────────────

@test "install short-circuits when is_installed returns 0 (idempotency)" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    MOCK_PKG_VERSION="1.4.3-1"
    _mock_dpkg_query
    run install
    assert_success
    assert_output --partial "already installed"
}

@test "remove is idempotent — second run still exits 0" {
    _load_module
    _mock_apt_defaults
    run remove
    assert_success
    run remove
    assert_success
}

# ── verify / doctor (real pipx --version probe) ──────────────────────────────

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

@test "doctor passes when pipx answers --version" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    _fake_pipx_bin 0
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run doctor
    assert_success
}

@test "doctor fails when pipx --version errors out" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    _fake_pipx_bin 1
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run doctor
    assert_failure
    assert_output --partial "pipx --version"
}

# ── is_recommended / detect ──────────────────────────────────────────────────

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
    assert_output --partial "pipx"
}

@test "standalone: unknown phase returns exit 2" {
    run _standalone_module nope
    assert_failure 2
}

@test "standalone: info prints metadata + depends_on" {
    run _standalone_module info
    assert_success
    assert_output --partial "name:        pipx"
    assert_output --partial "category:    base"
    assert_output --partial "depends_on:  python3"
}

@test "standalone: info --lang=zh-TW prints localized description" {
    run _standalone_module info --lang=zh-TW
    assert_success
    assert_output --partial "隔離"
}

@test "standalone: status reports installed + outdated fields" {
    run _standalone_module status
    assert_success
    assert_output --partial "installed:"
    assert_output --partial "outdated:"
}

# ── AC-25 ─────────────────────────────────────────────────────────────────────

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
