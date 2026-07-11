#!/usr/bin/env bats
# test/unit/module/claude-monitor_spec.bats — module/claude-monitor.module.sh
#
# Per Q29: smoke / metadata / lifecycle dry-run / no-side-fx / idempotency /
# standalone CLI / module-specific (custom archetype: pipx install, user-home
# scope, pipx bootstrap when absent, sidecar lifecycle ADR-0001). Issue #315
# / TODO.md ADD items -> claude code -> claude-monitor.

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
    # shellcheck source=../../../module/claude-monitor.module.sh
    source "${MODULE_DIR}/claude-monitor.module.sh"
}

# _standalone_module runs the module as a self-contained CLI (the same
# entry users hit when they type `bash module/claude-monitor.module.sh ...`).
_standalone_module() {
    bash "${MODULE_DIR}/claude-monitor.module.sh" "$@"
}

# ── Controllable mocks ───────────────────────────────────────────────────────
# Each shadowed function is defined exactly once and parameterized via
# MOCK_* variables, so every definition stays reachable for the linter
# (avoids SC2317 without disable directives).

# is_installed mock: MOCK_IS_INSTALLED_RC (0 = installed, 1 = not).
_mock_is_installed() {
    is_installed() { return "${MOCK_IS_INSTALLED_RC:-0}"; }
}

# pipx seam mock: records the full argv into MOCK_PIPX_LOG (one line per
# call) and answers queries. Also stubs the pipx-bootstrap seam so install
# never shells out to apt.
#   MOCK_PIPX_RC        — exit code for mutating subcommands (install/...)
#   MOCK_PIPX_INSTALLED — 0 = `pipx list` reports the package
#   MOCK_PIPX_VERSION   — version emitted for `pipx list --short`
#   MOCK_PIPX_OUTDATED  — full `pipx runpip ... list --outdated` output
_mock_pipx() {
    MOCK_PIPX_LOG="${INIT_UBUNTU_TEST_SCRATCH}/pipx.log"
    : > "${MOCK_PIPX_LOG}"
    _claude_monitor_pipx() {
        printf '%s\n' "$*" >> "${MOCK_PIPX_LOG}"
        case "${1:-}" in
            list)
                if [[ "${2:-}" == "--short" ]]; then
                    [[ -n "${MOCK_PIPX_VERSION:-}" ]] \
                        && printf 'claude-monitor %s\n' "${MOCK_PIPX_VERSION}"
                else
                    [[ "${MOCK_PIPX_INSTALLED:-0}" -eq 0 ]] \
                        && printf 'package claude-monitor %s\n' "${MOCK_PIPX_VERSION:-3.0.0}"
                fi
                ;;
            runpip)
                printf '%s' "${MOCK_PIPX_OUTDATED:-}"
                ;;
            *)
                return "${MOCK_PIPX_RC:-0}"
                ;;
        esac
    }
}

# claude-monitor fake binary answering --version.
_mock_monitor_bin() {
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    printf '#!/usr/bin/env bash\nprintf "claude-monitor 3.0.0\\n"\n' \
        > "${INIT_UBUNTU_TEST_SCRATCH}/bin/claude-monitor"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/claude-monitor"
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "claude-monitor module file parses (bash -n)" {
    run bash -n "${MODULE_DIR}/claude-monitor.module.sh"
    assert_success
}

@test "claude-monitor module sources cleanly in engine mode (MODULE_STANDALONE=false)" {
    _load_module
    [[ "${MODULE_STANDALONE}" == "false" ]]
}

@test "claude-monitor module defines all 10 lifecycle functions" {
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

@test "claude-monitor module declares NAME=claude-monitor" {
    _load_module
    [[ "${NAME}" == "claude-monitor" ]]
}

@test "claude-monitor module CATEGORY=optional" {
    _load_module
    [[ "${CATEGORY}" == "optional" ]]
}

@test "claude-monitor module TAGS contains agent + cli" {
    _load_module
    [[ " ${TAGS[*]} " == *" agent "* ]]
    [[ " ${TAGS[*]} " == *" cli "* ]]
}

@test "claude-monitor module DEPENDS_ON contains pipx" {
    _load_module
    [[ " ${DEPENDS_ON[*]} " == *" pipx "* ]]
}

@test "claude-monitor DESCRIPTION is associative with en + zh-TW entries" {
    _load_module
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ -n "${DESCRIPTION[en]}" ]]
    [[ -n "${DESCRIPTION[zh-TW]}" ]]
}

@test "claude-monitor module_get_description returns language-specific text" {
    _load_module
    [[ "$(module_get_description en)" == *"monitor"* ]]
    [[ -n "$(module_get_description zh-TW)" ]]
    # Unknown language falls back to en.
    [[ "$(module_get_description xx)" == "$(module_get_description en)" ]]
}

@test "claude-monitor module RISK_LEVEL=low" {
    _load_module
    [[ "${RISK_LEVEL}" == "low" ]]
}

@test "claude-monitor module INSTALL_TARGET_DEFAULT=user-home" {
    _load_module
    [[ "${INSTALL_TARGET_DEFAULT}" == "user-home" ]]
}

@test "claude-monitor module SUPPORTS_USER_HOME=true" {
    _load_module
    [[ "${SUPPORTS_USER_HOME}" == "true" ]]
}

@test "claude-monitor module VERSION_PROVIDED=pipx-managed" {
    _load_module
    [[ "${VERSION_PROVIDED}" == "pipx-managed" ]]
}

@test "claude-monitor HOMEPAGE points at the claude-monitor PyPI page" {
    _load_module
    [[ "${HOMEPAGE}" == *"claude-monitor"* ]]
}

@test "claude-monitor POST_INSTALL_MESSAGE mentions ~/.local/bin PATH" {
    _load_module
    [[ "$(module_get_post_install_message en)" == *".local/bin"* ]]
    [[ -n "$(module_get_post_install_message zh-TW)" ]]
}

@test "claude-monitor REBOOT_REQUIRED=false" {
    _load_module
    [[ "${REBOOT_REQUIRED}" == "false" ]]
}

@test "TEST_VERIFY_CMD exercises the claude-monitor binary" {
    _load_module
    [[ "${TEST_VERIFY_CMD}" == *"claude-monitor"* ]]
}

# ── is_installed: shim on PATH or pipx listing ───────────────────────────────

@test "is_installed returns zero when the claude-monitor shim is on PATH" {
    _load_module
    _mock_monitor_bin
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run is_installed
    assert_success
}

@test "is_installed returns zero when pipx lists the package (no shim)" {
    _load_module
    # No real claude-monitor shim in the container: command -v fails and the
    # pipx-list fallback (mocked to report the package) decides. Keep the
    # system PATH so is_installed's own `grep` stays resolvable.
    MOCK_PIPX_INSTALLED=0
    _mock_pipx
    run is_installed
    assert_success
}

@test "is_installed returns nonzero when neither shim nor pipx record exist" {
    _load_module
    MOCK_PIPX_INSTALLED=1
    _mock_pipx
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
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/claude-monitor" ]]
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/state.json" ]]
}

@test "dry-run install never shells out to pipx" {
    _load_module
    _mock_pipx
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    [[ ! -s "${MOCK_PIPX_LOG}" ]]
}

@test "dry-run remove leaves an existing sidecar in place" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '3.0.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/claude-monitor"
    INIT_UBUNTU_DRY_RUN=true run remove
    assert_success
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/claude-monitor" ]]
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

# ── install / upgrade / remove: pipx paths (custom archetype core) ───────────

@test "install runs pipx install claude-monitor" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    _mock_pipx
    install
    grep -q '^install claude-monitor$' "${MOCK_PIPX_LOG}"
}

@test "install skips when already installed (idempotent fast path)" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    _mock_pipx
    run install
    assert_success
    assert_output --partial "already installed"
    [[ ! -s "${MOCK_PIPX_LOG}" ]]
}

@test "failed pipx install propagates the failure" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    MOCK_PIPX_RC=1
    _mock_pipx
    run install
    assert_failure
}

@test "upgrade on a missing install falls through to install" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    _mock_pipx
    run upgrade
    assert_success
    grep -q '^install claude-monitor$' "${MOCK_PIPX_LOG}"
}

@test "upgrade runs pipx upgrade when installed" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    _mock_pipx
    run upgrade
    assert_success
    grep -q '^upgrade claude-monitor$' "${MOCK_PIPX_LOG}"
}

@test "failed pipx upgrade propagates the failure" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    MOCK_PIPX_RC=1
    _mock_pipx
    run upgrade
    assert_failure
}

@test "remove runs pipx uninstall claude-monitor" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    _mock_pipx
    run remove
    assert_success
    grep -q '^uninstall claude-monitor$' "${MOCK_PIPX_LOG}"
}

@test "remove skips when not installed" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    _mock_pipx
    run remove
    assert_success
    [[ ! -s "${MOCK_PIPX_LOG}" ]]
}

# ── Sidecar lifecycle (ADR-0001) ─────────────────────────────────────────────

@test "install writes the sidecar with the pipx-reported version" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    MOCK_PIPX_VERSION="3.0.0"
    _mock_pipx
    module_standalone_main install
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/claude-monitor" ]]
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/claude-monitor")" == "3.0.0" ]]
}

@test "install sidecar falls back to pipx-managed when pipx list is empty" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    MOCK_PIPX_VERSION=""
    _mock_pipx
    module_standalone_main install
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/claude-monitor")" == "pipx-managed" ]]
}

@test "install never touches state.json (ADR-0001 / AC-23 pattern)" {
    _load_module
    printf '{"schema_version":"0.1.0","installed":{}}\n' \
        > "${INIT_UBUNTU_STATE_DIR}/state.json"
    local _before; _before="$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")"
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    MOCK_PIPX_VERSION="3.0.0"
    _mock_pipx
    module_standalone_main install
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")" == "${_before}" ]]
}

@test "failed install leaves no sidecar (ADR-0015)" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    MOCK_PIPX_RC=1
    _mock_pipx
    run module_standalone_main install
    assert_failure
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/claude-monitor" ]]
}

@test "upgrade refreshes the sidecar version" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '2.9.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/claude-monitor"
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    MOCK_PIPX_VERSION="3.0.0"
    _mock_pipx
    module_standalone_main upgrade
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/claude-monitor")" == "3.0.0" ]]
}

@test "remove deletes the sidecar" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '3.0.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/claude-monitor"
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    _mock_pipx
    module_standalone_main remove
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/claude-monitor" ]]
}

@test "purge deletes the sidecar and the config dir" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '3.0.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/claude-monitor"
    local _cfg="${INIT_UBUNTU_TEST_SCRATCH}/xdg/claude-monitor"
    mkdir -p "${_cfg}"
    printf 'x\n' > "${_cfg}/params.json"
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    _mock_pipx
    XDG_CONFIG_HOME="${INIT_UBUNTU_TEST_SCRATCH}/xdg" \
        module_standalone_main purge
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/claude-monitor" ]]
}

# ── Idempotency (AC-5 pattern) ───────────────────────────────────────────────

@test "install twice exits 0 both times" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    _mock_pipx
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
    _mock_pipx
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

@test "doctor passes when claude-monitor answers --version" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    _mock_monitor_bin
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run doctor
    assert_success
}

@test "doctor fails when the claude-monitor shim is not on PATH" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/empty-bin"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/empty-bin" run doctor
    assert_failure
}

@test "is_outdated returns zero when pipx runpip reports claude-monitor outdated" {
    _load_module
    MOCK_PIPX_OUTDATED='claude-monitor 2.9.0 3.0.0 wheel'
    _mock_pipx
    run is_outdated
    assert_success
}

@test "is_outdated returns nonzero when claude-monitor is not in the outdated list" {
    _load_module
    MOCK_PIPX_OUTDATED='some-other-pkg 1.0 2.0 wheel'
    _mock_pipx
    run is_outdated
    assert_failure
}

@test "is_outdated returns nonzero when pipx output is empty" {
    _load_module
    MOCK_PIPX_OUTDATED=""
    _mock_pipx
    run is_outdated
    assert_failure
}

# ── is_recommended / detect ──────────────────────────────────────────────────

@test "is_recommended is zero when not installed" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    run is_recommended
    assert_success
}

@test "is_recommended is nonzero when already installed" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    run is_recommended
    assert_failure
}

@test "detect succeeds (pure-python pipx tool, no arch constraint)" {
    _load_module
    run detect
    assert_success
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
    assert_output --partial "claude-monitor"
}

@test "standalone: unknown phase returns exit 2" {
    run _standalone_module nope
    assert_failure 2
}

@test "standalone: info prints metadata" {
    run _standalone_module info
    assert_success
    assert_output --partial "name:        claude-monitor"
    assert_output --partial "category:    optional"
    assert_output --partial "agent"
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
    # Fake pipx on PATH: the test container has no pipx, and a bare
    # command-not-found (127) would trip bats' BW01 warning.
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    printf '#!/bin/sh\nexit 0\n' > "${INIT_UBUNTU_TEST_SCRATCH}/bin/pipx"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/pipx"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run _standalone_module is-installed
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "standalone: is-recommended is implemented (exit != 2)" {
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    printf '#!/bin/sh\nexit 0\n' > "${INIT_UBUNTU_TEST_SCRATCH}/bin/pipx"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/pipx"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run _standalone_module is-recommended
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "standalone: is-outdated is implemented (exit != 2)" {
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    printf '#!/bin/sh\nexit 0\n' > "${INIT_UBUNTU_TEST_SCRATCH}/bin/pipx"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/pipx"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run _standalone_module is-outdated
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "standalone: doctor is implemented (exit != 2)" {
    run _standalone_module doctor
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}
