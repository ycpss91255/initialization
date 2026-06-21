#!/usr/bin/env bats
# test/unit/module/qmk-firmware_spec.bats — module/qmk-firmware.module.sh
#
# Per Q29: smoke / metadata / lifecycle dry-run / no-side-fx / idempotency /
# standalone CLI / module-specific (custom archetype: apt prereqs + pipx CLI
# + qmk setup + personal keymap overlay; sidecar lifecycle ADR-0001).

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
    # shellcheck source=../../../module/qmk-firmware.module.sh
    source "${MODULE_DIR}/qmk-firmware.module.sh"
}

# _standalone_module runs the module as a self-contained CLI (the same
# entry users hit when they type `bash module/qmk-firmware.module.sh ...`).
_standalone_module() {
    bash "${MODULE_DIR}/qmk-firmware.module.sh" "$@"
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "qmk-firmware module file parses (bash -n)" {
    run bash -n "${MODULE_DIR}/qmk-firmware.module.sh"
    assert_success
}

@test "qmk-firmware module sources cleanly in engine mode (MODULE_STANDALONE=false)" {
    _load_module
    [[ "${MODULE_STANDALONE}" == "false" ]]
}

@test "qmk-firmware module defines all 10 lifecycle functions" {
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

@test "qmk-firmware module declares NAME=qmk-firmware" {
    _load_module
    [[ "${NAME}" == "qmk-firmware" ]]
}

@test "qmk-firmware module CATEGORY=optional" {
    _load_module
    [[ "${CATEGORY}" == "optional" ]]
}

@test "qmk-firmware module TAGS contains hardware" {
    _load_module
    [[ " ${TAGS[*]} " == *" hardware "* ]]
}

@test "qmk-firmware DEPENDS_ON is exactly git + build-essential (Q39: module names only)" {
    _load_module
    [[ "${#DEPENDS_ON[@]}" -eq 2 ]]
    [[ " ${DEPENDS_ON[*]} " == *" git "* ]]
    [[ " ${DEPENDS_ON[*]} " == *" build-essential "* ]]
}

@test "qmk-firmware ensures the build-essential package inside install (Q39)" {
    _load_module
    # build-essential is also re-listed in the apt prereq array because
    # standalone mode does not resolve DEPENDS_ON.
    [[ " ${_QMK_APT_PREREQS[*]} " == *" build-essential "* ]]
}

@test "qmk-firmware DESCRIPTION is associative with en + zh-TW entries" {
    _load_module
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ -n "${DESCRIPTION[en]}" ]]
    [[ -n "${DESCRIPTION[zh-TW]}" ]]
}

@test "qmk-firmware module_get_description returns language-specific text" {
    _load_module
    [[ "$(module_get_description en)" == *"QMK"* ]]
    [[ -n "$(module_get_description zh-TW)" ]]
    # Unknown language falls back to en.
    [[ "$(module_get_description xx)" == "$(module_get_description en)" ]]
}

@test "qmk-firmware SUPPORTED_UBUNTU includes 22.04 24.04 26.04" {
    _load_module
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 22.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 24.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 26.04 "* ]]
}

@test "qmk-firmware SUPPORTED_PLATFORMS excludes wsl and container (US-5)" {
    _load_module
    [[ " ${SUPPORTED_PLATFORMS[*]} " != *" wsl "* ]]
    [[ " ${SUPPORTED_PLATFORMS[*]} " != *" container "* ]]
}

@test "qmk-firmware module RISK_LEVEL=low" {
    _load_module
    [[ "${RISK_LEVEL}" == "low" ]]
}

@test "qmk-firmware module VERSION_PROVIDED=pipx-managed" {
    _load_module
    [[ "${VERSION_PROVIDED}" == "pipx-managed" ]]
}

@test "qmk-firmware HOMEPAGE points at qmk.fm" {
    _load_module
    [[ "${HOMEPAGE}" == *"qmk.fm"* ]]
}

@test "qmk-firmware POST_INSTALL_MESSAGE mentions qmk setup in both languages" {
    _load_module
    [[ "$(module_get_post_install_message en)" == *"qmk"* ]]
    [[ -n "$(module_get_post_install_message zh-TW)" ]]
}

# ── Controllable mocks ───────────────────────────────────────────────────────
# Each shadowed function is defined exactly once and parameterized via
# MOCK_* variables, so every definition stays reachable for the linter
# (avoids SC2317 without disable directives).

# is_installed mock: MOCK_IS_INSTALLED_RC (0 = installed, 1 = not).
_mock_is_installed() {
    is_installed() { return "${MOCK_IS_INSTALLED_RC:-0}"; }
}

# install-step mocks: MOCK_<STEP>_RC (default 0 = success).
_mock_install_steps() {
    _qmk_apt_prereqs()    { return "${MOCK_APT_PREREQS_RC:-0}"; }
    _qmk_pipx_install()   { return "${MOCK_PIPX_INSTALL_RC:-0}"; }
    _qmk_pipx_upgrade()   { return "${MOCK_PIPX_UPGRADE_RC:-0}"; }
    _qmk_pipx_uninstall() { return "${MOCK_PIPX_UNINSTALL_RC:-0}"; }
    _qmk_setup()          { return "${MOCK_QMK_SETUP_RC:-0}"; }
    _qmk_deploy_keymaps() { return "${MOCK_DEPLOY_KEYMAPS_RC:-0}"; }
}

# CLI version mock: MOCK_QMK_CLI_VERSION (empty = undeterminable, exit 1).
_mock_cli_version() {
    _qmk_cli_version() {
        [[ -n "${MOCK_QMK_CLI_VERSION:-}" ]] || return 1
        printf '%s' "${MOCK_QMK_CLI_VERSION}"
    }
}

# PyPI latest-version mock: MOCK_PYPI_VERSION (empty = network failure).
_mock_pypi_version() {
    _qmk_latest_pypi_version() {
        [[ -n "${MOCK_PYPI_VERSION:-}" ]] || return 1
        printf '%s' "${MOCK_PYPI_VERSION}"
    }
}

# Fake qmk binary on PATH: MOCK_QMK_BIN_VERSION is what --version prints.
_install_fake_qmk_bin() {
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    printf '#!/usr/bin/env bash\nprintf "%s\\n"\n' "${MOCK_QMK_BIN_VERSION:-1.1.5}" \
        > "${INIT_UBUNTU_TEST_SCRATCH}/bin/qmk"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/qmk"
}

# ── is_installed: relies on `command -v qmk` ─────────────────────────────────

@test "is_installed returns nonzero when qmk is not on PATH" {
    _load_module
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/empty-bin"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/empty-bin" run is_installed
    assert_failure
}

@test "is_installed returns zero when qmk is on PATH" {
    _load_module
    _install_fake_qmk_bin
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run is_installed
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
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/qmk-firmware" ]]
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/state.json" ]]
}

@test "dry-run remove leaves an existing sidecar in place" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.0.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/qmk-firmware"
    INIT_UBUNTU_DRY_RUN=true run remove
    assert_success
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/qmk-firmware" ]]
}

@test "dry-run purge leaves CONFIG_PATHS dirs untouched" {
    _load_module
    local _cfg="${INIT_UBUNTU_TEST_SCRATCH}/cfg-qmk"
    mkdir -p "${_cfg}"
    CONFIG_PATHS=("${_cfg}")
    INIT_UBUNTU_DRY_RUN=true run purge
    assert_success
    [[ -d "${_cfg}" ]]
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

# ── Sidecar lifecycle (ADR-0001) ─────────────────────────────────────────────

@test "install writes the sidecar with the CLI-reported version" {
    _load_module
    _mock_install_steps
    MOCK_QMK_CLI_VERSION="1.1.5"
    _mock_cli_version
    module_standalone_main install
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/qmk-firmware" ]]
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/qmk-firmware")" == "1.1.5" ]]
}

@test "install sidecar falls back to pipx-managed when the CLI version is empty" {
    _load_module
    _mock_install_steps
    MOCK_QMK_CLI_VERSION=""
    _mock_cli_version
    module_standalone_main install
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/qmk-firmware")" == "pipx-managed" ]]
}

@test "install never touches state.json (ADR-0001 / AC-23 pattern)" {
    _load_module
    printf '{"schema_version":"0.1.0","installed":{}}\n' \
        > "${INIT_UBUNTU_STATE_DIR}/state.json"
    local _before; _before="$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")"
    _mock_install_steps
    MOCK_QMK_CLI_VERSION="1.1.5"
    _mock_cli_version
    module_standalone_main install
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")" == "${_before}" ]]
}

@test "failed apt prereqs leave no sidecar behind (ADR-0015)" {
    _load_module
    MOCK_APT_PREREQS_RC=1
    _mock_install_steps
    run module_standalone_main install
    assert_failure
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/qmk-firmware" ]]
}

@test "failed pipx install leaves no sidecar behind (ADR-0015)" {
    _load_module
    MOCK_PIPX_INSTALL_RC=1
    _mock_install_steps
    run module_standalone_main install
    assert_failure
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/qmk-firmware" ]]
}

@test "failed qmk setup leaves no sidecar behind (ADR-0015)" {
    _load_module
    MOCK_QMK_SETUP_RC=1
    _mock_install_steps
    run module_standalone_main install
    assert_failure
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/qmk-firmware" ]]
}

@test "upgrade refreshes the sidecar version" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.0.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/qmk-firmware"
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    _mock_install_steps
    MOCK_QMK_CLI_VERSION="1.1.5"
    _mock_cli_version
    module_standalone_main upgrade
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/qmk-firmware")" == "1.1.5" ]]
}

@test "upgrade falls back to install when not installed" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    _mock_install_steps
    MOCK_QMK_CLI_VERSION="1.1.5"
    _mock_cli_version
    run upgrade
    assert_success
    assert_output --partial "running install instead"
}

@test "remove deletes the sidecar" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.0.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/qmk-firmware"
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    _mock_install_steps
    module_standalone_main remove
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/qmk-firmware" ]]
}

@test "remove deletes the sidecar even when already uninstalled" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.0.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/qmk-firmware"
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    module_standalone_main remove
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/qmk-firmware" ]]
}

@test "purge deletes the sidecar and CONFIG_PATHS dirs" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.0.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/qmk-firmware"
    local _cfg="${INIT_UBUNTU_TEST_SCRATCH}/cfg-qmk"
    local _fw="${INIT_UBUNTU_TEST_SCRATCH}/qmk_firmware"
    mkdir -p "${_cfg}" "${_fw}"
    CONFIG_PATHS=("${_cfg}" "${_fw}")
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    _mock_install_steps
    module_standalone_main purge
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/qmk-firmware" ]]
    [[ ! -e "${_cfg}" ]]
    [[ ! -e "${_fw}" ]]
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

@test "install twice with steps mocked exits 0 both times" {
    _load_module
    _mock_install_steps
    MOCK_QMK_CLI_VERSION="1.1.5"
    _mock_cli_version
    run install
    assert_success
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    run install
    assert_success
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

@test "doctor passes when the qmk binary answers --version" {
    _load_module
    _install_fake_qmk_bin
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run doctor
    assert_success
}

@test "doctor warns (but passes) when the qmk_firmware checkout is missing" {
    _load_module
    _install_fake_qmk_bin
    _QMK_HOME="${INIT_UBUNTU_TEST_SCRATCH}/no-such-checkout"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run doctor
    assert_success
    assert_output --partial "missing"
}

@test "is_outdated returns nonzero when not installed" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    run is_outdated
    assert_failure
}

@test "is_outdated returns zero when PyPI has a newer version" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    MOCK_QMK_CLI_VERSION="1.1.5"
    _mock_cli_version
    MOCK_PYPI_VERSION="1.2.0"
    _mock_pypi_version
    run is_outdated
    assert_success
}

@test "is_outdated returns nonzero when local matches PyPI" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    MOCK_QMK_CLI_VERSION="1.1.5"
    _mock_cli_version
    MOCK_PYPI_VERSION="1.1.5"
    _mock_pypi_version
    run is_outdated
    assert_failure
}

@test "is_outdated returns nonzero when PyPI is unreachable" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    MOCK_QMK_CLI_VERSION="1.1.5"
    _mock_cli_version
    MOCK_PYPI_VERSION=""
    _mock_pypi_version
    run is_outdated
    assert_failure
}

# ── is_recommended ───────────────────────────────────────────────────────────

@test "is_recommended is nonzero (opt-in niche hardware module)" {
    _load_module
    run is_recommended
    assert_failure
}

@test "is_recommended stays nonzero even when not installed (config opt-in only)" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    run is_recommended
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

# ── Keymap overlay (module-specific) ─────────────────────────────────────────

@test "keymap overlay copies repo keymaps into the qmk_firmware checkout" {
    _load_module
    local _src="${INIT_UBUNTU_TEST_SCRATCH}/src-keyboards"
    local _fw="${INIT_UBUNTU_TEST_SCRATCH}/qmk_firmware"
    mkdir -p "${_src}/boardsource/unicorne/keymaps/cyc_keymap" "${_fw}/keyboards"
    printf '// keymap\n' > "${_src}/boardsource/unicorne/keymaps/cyc_keymap/keymap.c"
    _QMK_KEYMAP_SRC="${_src}"
    _QMK_HOME="${_fw}"
    run _qmk_deploy_keymaps
    assert_success
    [[ -f "${_fw}/keyboards/boardsource/unicorne/keymaps/cyc_keymap/keymap.c" ]]
}

@test "keymap overlay is a no-op when the checkout does not exist" {
    _load_module
    _QMK_HOME="${INIT_UBUNTU_TEST_SCRATCH}/no-such-checkout"
    run _qmk_deploy_keymaps
    assert_success
}

@test "repo ships the boardsource/unicorne cyc_keymap referenced by the overlay" {
    # Resolve from MODULE_DIR directly (same expression the module uses for
    # _QMK_KEYMAP_SRC) — earlier tests reassign the variable in subshells.
    [[ -f "${MODULE_DIR}/config/qmk_firmware/keyboards/boardsource/unicorne/keymaps/cyc_keymap/keymap.c" ]]
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
    assert_output --partial "qmk-firmware"
}

@test "standalone: unknown phase returns exit 2" {
    run _standalone_module nope
    assert_failure 2
}

@test "standalone: info prints metadata" {
    run _standalone_module info
    assert_success
    assert_output --partial "name:        qmk-firmware"
    assert_output --partial "category:    optional"
    assert_output --partial "hardware"
    assert_output --partial "git"
}

@test "standalone: info --lang=zh-TW prints localized description" {
    run _standalone_module info --lang=zh-TW
    assert_success
    assert_output --partial "鍵盤"
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
    # Not installed in the test container -> clean exit 1, never the
    # "not implemented" exit 2 (AC-25).
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/empty-bin"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/empty-bin:/usr/bin:/bin" \
        run _standalone_module is-outdated
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "standalone: doctor is implemented (exit != 2)" {
    run _standalone_module doctor
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}
