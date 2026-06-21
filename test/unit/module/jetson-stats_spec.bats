#!/usr/bin/env bats
# test/unit/module/jetson-stats_spec.bats — module/jetson-stats.module.sh
#
# Per Q29: smoke / metadata / lifecycle dry-run / no-side-fx / idempotency /
# standalone CLI / module-specific (custom archetype: pip install with pipx
# fallback on PEP 668 environments, jetson-orin only, jtop.service health in
# doctor, sidecar lifecycle ADR-0001). Issue #37 / PRD Q51.

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
    # shellcheck source=../../../module/jetson-stats.module.sh
    source "${MODULE_DIR}/jetson-stats.module.sh"
}

# _standalone_module runs the module as a self-contained CLI (the same
# entry users hit when they type `bash module/jetson-stats.module.sh ...`).
_standalone_module() {
    bash "${MODULE_DIR}/jetson-stats.module.sh" "$@"
}

# ── Controllable mocks ───────────────────────────────────────────────────────
# Each shadowed function is defined exactly once and parameterized via
# MOCK_* variables, so every definition stays reachable for the linter
# (avoids SC2317 without disable directives).

# is_installed mock: MOCK_IS_INSTALLED_RC (0 = installed, 1 = not).
_mock_is_installed() {
    is_installed() { return "${MOCK_IS_INSTALLED_RC:-0}"; }
}

# sudo mock: records the full argv into MOCK_SUDO_LOG (one line per call)
# and executes nothing. MOCK_SUDO_RC controls the exit code.
_mock_sudo() {
    MOCK_SUDO_LOG="${INIT_UBUNTU_TEST_SCRATCH}/sudo.log"
    : > "${MOCK_SUDO_LOG}"
    have_sudo_access() { return 0; }
    sudo() {
        printf '%s\n' "$*" >> "${MOCK_SUDO_LOG}"
        return "${MOCK_SUDO_RC:-0}"
    }
}

# pip3 mock for version / show / list queries:
#   MOCK_PIP_SHOW_RC      — `pip3 show jetson-stats` exit code (0 = found)
#   MOCK_PIP_VERSION      — version printed for `pip3 show`
#   MOCK_PIP_OUTDATED     — full `pip3 list --outdated` output to emit
_mock_pip3() {
    pip3() {
        case "${1:-}" in
            show)
                [[ "${MOCK_PIP_SHOW_RC:-0}" -eq 0 ]] || return "${MOCK_PIP_SHOW_RC}"
                printf 'Name: jetson-stats\nVersion: %s\n' \
                    "${MOCK_PIP_VERSION:-4.3.2}"
                ;;
            list)
                printf '%s' "${MOCK_PIP_OUTDATED:-}"
                ;;
            *)
                return 0
                ;;
        esac
    }
}

# PEP 668 mock: MOCK_PEP668_RC (0 = externally managed -> pipx fallback).
_mock_pep668() {
    _jetson_stats_pep668() { return "${MOCK_PEP668_RC:-1}"; }
}

# systemctl mock for doctor: MOCK_SYSTEMCTL_ACTIVE_RC (0 = jtop.service
# active). Binary on PATH so `command -v systemctl` also succeeds.
_mock_systemctl_bin() {
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    printf '#!/bin/sh\nexit %s\n' "${MOCK_SYSTEMCTL_ACTIVE_RC:-0}" \
        > "${INIT_UBUNTU_TEST_SCRATCH}/bin/systemctl"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/systemctl"
}

# jtop fake binary answering --version.
_mock_jtop_bin() {
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    printf '#!/usr/bin/env bash\nprintf "jtop 4.3.2\\n"\n' \
        > "${INIT_UBUNTU_TEST_SCRATCH}/bin/jtop"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/jtop"
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "jetson-stats module file parses (bash -n)" {
    run bash -n "${MODULE_DIR}/jetson-stats.module.sh"
    assert_success
}

@test "jetson-stats module sources cleanly in engine mode (MODULE_STANDALONE=false)" {
    _load_module
    [[ "${MODULE_STANDALONE}" == "false" ]]
}

@test "jetson-stats module defines all 10 lifecycle functions" {
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

@test "jetson-stats module declares NAME=jetson-stats" {
    _load_module
    [[ "${NAME}" == "jetson-stats" ]]
}

@test "jetson-stats module CATEGORY=optional" {
    _load_module
    [[ "${CATEGORY}" == "optional" ]]
}

@test "jetson-stats module TAGS contains hardware" {
    _load_module
    [[ " ${TAGS[*]} " == *" hardware "* ]]
}

@test "jetson-stats module DEPENDS_ON is exactly git + curl (Q39)" {
    _load_module
    [[ "${#DEPENDS_ON[@]}" -eq 2 ]]
    [[ " ${DEPENDS_ON[*]} " == *" git "* ]]
    [[ " ${DEPENDS_ON[*]} " == *" curl "* ]]
}

@test "jetson-stats DESCRIPTION is associative with en + zh-TW entries" {
    _load_module
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ -n "${DESCRIPTION[en]}" ]]
    [[ -n "${DESCRIPTION[zh-TW]}" ]]
}

@test "jetson-stats module_get_description returns language-specific text" {
    _load_module
    [[ "$(module_get_description en)" == *"jtop"* ]]
    [[ -n "$(module_get_description zh-TW)" ]]
    # Unknown language falls back to en.
    [[ "$(module_get_description xx)" == "$(module_get_description en)" ]]
}

@test "jetson-stats SUPPORTED_PLATFORMS is exactly jetson-orin (Q51)" {
    _load_module
    [[ "${#SUPPORTED_PLATFORMS[@]}" -eq 1 ]]
    [[ "${SUPPORTED_PLATFORMS[0]}" == "jetson-orin" ]]
}

@test "jetson-stats module RISK_LEVEL=low" {
    _load_module
    [[ "${RISK_LEVEL}" == "low" ]]
}

@test "jetson-stats module INSTALL_TARGET_DEFAULT=sudo" {
    _load_module
    [[ "${INSTALL_TARGET_DEFAULT}" == "sudo" ]]
}

@test "jetson-stats module VERSION_PROVIDED=pip-managed" {
    _load_module
    [[ "${VERSION_PROVIDED}" == "pip-managed" ]]
}

@test "jetson-stats HOMEPAGE points at the rbonghi/jetson_stats project" {
    _load_module
    [[ "${HOMEPAGE}" == *"jetson_stats"* ]]
}

@test "jetson-stats POST_INSTALL_MESSAGE mentions re-login for jtop.service" {
    _load_module
    [[ "$(module_get_post_install_message en)" == *"re-login"* ]]
    [[ -n "$(module_get_post_install_message zh-TW)" ]]
}

@test "jetson-stats REBOOT_REQUIRED=false (re-login is enough)" {
    _load_module
    [[ "${REBOOT_REQUIRED}" == "false" ]]
}

@test "TEST_VERIFY_CMD exercises the jtop binary" {
    _load_module
    [[ "${TEST_VERIFY_CMD}" == *"jtop"* ]]
}

# ── is_installed: pip metadata or jtop on PATH ───────────────────────────────

@test "is_installed returns zero when pip3 reports jetson-stats" {
    _load_module
    MOCK_PIP_SHOW_RC=0
    _mock_pip3
    run is_installed
    assert_success
}

@test "is_installed returns zero when only the jtop binary is on PATH" {
    _load_module
    MOCK_PIP_SHOW_RC=1
    _mock_pip3
    _mock_jtop_bin
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run is_installed
    assert_success
}

@test "is_installed returns nonzero when neither pip record nor jtop exist" {
    _load_module
    MOCK_PIP_SHOW_RC=1
    _mock_pip3
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/empty-bin"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/empty-bin" run is_installed
    assert_failure
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
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/jetson-stats" ]]
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/state.json" ]]
}

@test "dry-run install never shells out to sudo" {
    _load_module
    _mock_sudo
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    [[ ! -s "${MOCK_SUDO_LOG}" ]]
}

@test "dry-run remove leaves an existing sidecar in place" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '4.3.2\n' > "${INIT_UBUNTU_STATE_DIR}/versions/jetson-stats"
    INIT_UBUNTU_DRY_RUN=true run remove
    assert_success
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/jetson-stats" ]]
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

# ── PEP 668 installer selection (custom archetype core) ─────────────────────

@test "installer picks pip on a classic (non-PEP-668) environment" {
    _load_module
    MOCK_PEP668_RC=1
    _mock_pep668
    [[ "$(_jetson_stats_installer)" == "pip" ]]
}

@test "installer falls back to pipx on a PEP 668 environment" {
    _load_module
    MOCK_PEP668_RC=0
    _mock_pep668
    [[ "$(_jetson_stats_installer)" == "pipx" ]]
}

@test "_jetson_stats_pep668 detects the EXTERNALLY-MANAGED marker" {
    _load_module
    local _stdlib="${INIT_UBUNTU_TEST_SCRATCH}/stdlib"
    mkdir -p "${_stdlib}"
    touch "${_stdlib}/EXTERNALLY-MANAGED"
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    printf '#!/bin/sh\necho "%s"\n' "${_stdlib}" \
        > "${INIT_UBUNTU_TEST_SCRATCH}/bin/python3"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/python3"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run _jetson_stats_pep668
    assert_success
}

@test "_jetson_stats_pep668 is nonzero when no marker exists" {
    _load_module
    local _stdlib="${INIT_UBUNTU_TEST_SCRATCH}/stdlib"
    mkdir -p "${_stdlib}"
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    printf '#!/bin/sh\necho "%s"\n' "${_stdlib}" \
        > "${INIT_UBUNTU_TEST_SCRATCH}/bin/python3"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/python3"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run _jetson_stats_pep668
    assert_failure
}

# ── install: pip / pipx paths ────────────────────────────────────────────────

@test "install runs sudo pip3 install -U jetson-stats on classic env" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    MOCK_PEP668_RC=1
    _mock_pep668
    MOCK_PIP_SHOW_RC=0 MOCK_PIP_VERSION="4.3.2"
    _mock_pip3
    _mock_sudo
    install
    grep -q 'pip3 install -U jetson-stats' "${MOCK_SUDO_LOG}"
}

@test "install runs sudo pipx install jetson-stats under PEP 668" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    MOCK_PEP668_RC=0
    _mock_pep668
    MOCK_PIP_SHOW_RC=1
    _mock_pip3
    _mock_sudo
    install
    grep -q 'pipx install jetson-stats' "${MOCK_SUDO_LOG}"
    run grep -q 'pip3 install' "${MOCK_SUDO_LOG}"
    assert_failure
}

@test "install skips when already installed (idempotent fast path)" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    _mock_sudo
    run install
    assert_success
    assert_output --partial "already installed"
    [[ ! -s "${MOCK_SUDO_LOG}" ]]
}

@test "failed pip install propagates the failure" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    MOCK_PEP668_RC=1
    _mock_pep668
    _mock_sudo
    MOCK_SUDO_RC=1
    run install
    assert_failure
}

# ── Sidecar lifecycle (ADR-0001) ─────────────────────────────────────────────

@test "install writes the sidecar with the pip-reported version" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    MOCK_PEP668_RC=1
    _mock_pep668
    MOCK_PIP_SHOW_RC=0 MOCK_PIP_VERSION="4.3.2"
    _mock_pip3
    _mock_sudo
    install
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/jetson-stats" ]]
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/jetson-stats")" == "4.3.2" ]]
}

@test "install sidecar falls back to pip-managed when pip3 show is empty" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    MOCK_PEP668_RC=1
    _mock_pep668
    MOCK_PIP_SHOW_RC=1
    _mock_pip3
    _mock_sudo
    install
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/jetson-stats")" == "pip-managed" ]]
}

@test "install never touches state.json (ADR-0001 / AC-23 pattern)" {
    _load_module
    printf '{"schema_version":"0.1.0","installed":{}}\n' \
        > "${INIT_UBUNTU_STATE_DIR}/state.json"
    local _before; _before="$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")"
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    MOCK_PEP668_RC=1
    _mock_pep668
    MOCK_PIP_SHOW_RC=0 MOCK_PIP_VERSION="4.3.2"
    _mock_pip3
    _mock_sudo
    install
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")" == "${_before}" ]]
}

@test "failed install leaves no sidecar (ADR-0015)" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    MOCK_PEP668_RC=1
    _mock_pep668
    _mock_sudo
    MOCK_SUDO_RC=1
    run install
    assert_failure
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/jetson-stats" ]]
}

@test "upgrade refreshes the sidecar version" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '4.2.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/jetson-stats"
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    MOCK_PEP668_RC=1
    _mock_pep668
    MOCK_PIP_SHOW_RC=0 MOCK_PIP_VERSION="4.3.2"
    _mock_pip3
    _mock_sudo
    upgrade
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/jetson-stats")" == "4.3.2" ]]
}

@test "remove deletes the sidecar" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '4.3.2\n' > "${INIT_UBUNTU_STATE_DIR}/versions/jetson-stats"
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    MOCK_PIP_SHOW_RC=0 MOCK_PIP_VERSION="4.3.2"
    _mock_pip3
    _mock_sudo
    remove
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/jetson-stats" ]]
}

@test "purge deletes the sidecar and the jtop.service leftover" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '4.3.2\n' > "${INIT_UBUNTU_STATE_DIR}/versions/jetson-stats"
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    MOCK_PIP_SHOW_RC=0 MOCK_PIP_VERSION="4.3.2"
    _mock_pip3
    _mock_sudo
    purge
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/jetson-stats" ]]
    grep -q "rm -f ${JTOP_SERVICE_UNIT}" "${MOCK_SUDO_LOG}"
}

# ── upgrade / remove semantics ──────────────────────────────────────────────

@test "upgrade on a missing install falls through to install" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    MOCK_PEP668_RC=1
    _mock_pep668
    MOCK_PIP_SHOW_RC=0 MOCK_PIP_VERSION="4.3.2"
    _mock_pip3
    _mock_sudo
    run upgrade
    assert_success
    grep -q 'pip3 install -U jetson-stats' "${MOCK_SUDO_LOG}"
}

@test "upgrade uses pipx upgrade under PEP 668" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    MOCK_PEP668_RC=0
    _mock_pep668
    MOCK_PIP_SHOW_RC=1
    _mock_pip3
    _mock_sudo
    run upgrade
    assert_success
    grep -q 'pipx upgrade jetson-stats' "${MOCK_SUDO_LOG}"
}

@test "remove uses pip3 uninstall when pip owns the package" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    MOCK_PIP_SHOW_RC=0 MOCK_PIP_VERSION="4.3.2"
    _mock_pip3
    _mock_sudo
    run remove
    assert_success
    grep -q 'pip3 uninstall -y jetson-stats' "${MOCK_SUDO_LOG}"
}

@test "remove uses pipx uninstall when pip has no record" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    MOCK_PIP_SHOW_RC=1
    _mock_pip3
    _mock_sudo
    run remove
    assert_success
    grep -q 'pipx uninstall jetson-stats' "${MOCK_SUDO_LOG}"
}

# ── Idempotency (AC-5 pattern) ───────────────────────────────────────────────

@test "install twice exits 0 both times" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    MOCK_PEP668_RC=1
    _mock_pep668
    MOCK_PIP_SHOW_RC=0 MOCK_PIP_VERSION="4.3.2"
    _mock_pip3
    _mock_sudo
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
    _mock_sudo
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

@test "doctor passes when jtop answers --version and the service is active" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    _mock_jtop_bin
    MOCK_SYSTEMCTL_ACTIVE_RC=0
    _mock_systemctl_bin
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run doctor
    assert_success
}

@test "doctor warns (but passes) when jtop.service is not active" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    _mock_jtop_bin
    MOCK_SYSTEMCTL_ACTIVE_RC=3
    _mock_systemctl_bin
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run doctor
    assert_success
    assert_output --partial "jtop.service"
}

@test "doctor fails when the jtop binary is not on PATH" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/empty-bin"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/empty-bin" run doctor
    assert_failure
}

@test "is_outdated returns zero when pip reports jetson-stats outdated" {
    _load_module
    MOCK_PIP_OUTDATED='jetson-stats 4.2.0 4.3.2 wheel'
    _mock_pip3
    run is_outdated
    assert_success
}

@test "is_outdated returns nonzero when jetson-stats is not in the outdated list" {
    _load_module
    MOCK_PIP_OUTDATED='some-other-pkg 1.0 2.0 wheel'
    _mock_pip3
    run is_outdated
    assert_failure
}

@test "is_outdated returns nonzero when pip output is empty" {
    _load_module
    MOCK_PIP_OUTDATED=""
    _mock_pip3
    run is_outdated
    assert_failure
}

# ── is_recommended: jetson-orin only ─────────────────────────────────────────

@test "is_recommended is zero on jetson-orin when not installed" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    INIT_UBUNTU_FORM_FACTOR="jetson-orin" run is_recommended
    assert_success
}

@test "is_recommended is nonzero on jetson-orin when already installed" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    INIT_UBUNTU_FORM_FACTOR="jetson-orin" run is_recommended
    assert_failure
}

@test "is_recommended is nonzero on a desktop form factor" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    INIT_UBUNTU_FORM_FACTOR="desktop" run is_recommended
    assert_failure
}

@test "is_recommended is nonzero when the form factor is unset" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    INIT_UBUNTU_FORM_FACTOR="" run is_recommended
    assert_failure
}

# ── detect: tegra release file or jetson-orin form factor ────────────────────

@test "detect succeeds when the form factor says jetson-orin" {
    _load_module
    JETSON_TEGRA_RELEASE="${INIT_UBUNTU_TEST_SCRATCH}/nope"
    INIT_UBUNTU_FORM_FACTOR="jetson-orin" run detect
    assert_success
}

@test "detect succeeds when the tegra release file exists" {
    _load_module
    JETSON_TEGRA_RELEASE="${INIT_UBUNTU_TEST_SCRATCH}/nv_tegra_release"
    printf '# R36 (release)\n' > "${JETSON_TEGRA_RELEASE}"
    INIT_UBUNTU_FORM_FACTOR="" run detect
    assert_success
}

@test "detect fails off-jetson (no file, non-jetson form factor)" {
    _load_module
    JETSON_TEGRA_RELEASE="${INIT_UBUNTU_TEST_SCRATCH}/nope"
    INIT_UBUNTU_FORM_FACTOR="desktop" run detect
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
    assert_output --partial "jetson-stats"
}

@test "standalone: unknown phase returns exit 2" {
    run _standalone_module nope
    assert_failure 2
}

@test "standalone: info prints metadata" {
    run _standalone_module info
    assert_success
    assert_output --partial "name:        jetson-stats"
    assert_output --partial "category:    optional"
    assert_output --partial "hardware"
}

@test "standalone: info --lang=zh-TW prints localized description" {
    run _standalone_module info --lang=zh-TW
    assert_success
    assert_output --partial "監控"
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
    # Fake pip3 on PATH: the test container has no pip3, and a bare
    # command-not-found (127) would trip bats' BW01 warning.
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    printf '#!/bin/sh\nexit 1\n' > "${INIT_UBUNTU_TEST_SCRATCH}/bin/pip3"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/pip3"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run _standalone_module is-installed
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
    printf '#!/bin/sh\nexit 0\n' > "${INIT_UBUNTU_TEST_SCRATCH}/bin/pip3"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/pip3"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run _standalone_module is-outdated
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "standalone: doctor is implemented (exit != 2)" {
    run _standalone_module doctor
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}
