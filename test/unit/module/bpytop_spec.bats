#!/usr/bin/env bats
# test/unit/module/bpytop_spec.bats — module/bpytop.module.sh
#
# Per Q29: smoke / metadata / lifecycle dry-run / no-side-fx / idempotency /
# standalone CLI / module-specific (custom archetype: user-level pipx install,
# Sidecar lifecycle ADR-0001, real doctor probe). Small-tools modularization
# program (pipx tier). Mirrors the tmuxp/claude-monitor custom-archetype spec.

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
    # shellcheck source=../../../module/bpytop.module.sh
    source "${MODULE_DIR}/bpytop.module.sh"
}

# _standalone_module runs the module as a self-contained CLI (the same entry
# users hit when they type `bash module/bpytop.module.sh ...`).
_standalone_module() {
    bash "${MODULE_DIR}/bpytop.module.sh" "$@"
}

# ── Controllable mocks ───────────────────────────────────────────────────────
# Each shadowed function is defined exactly once and parameterized via MOCK_*
# variables, so every definition stays reachable for the linter (avoids SC2317
# without disable directives).

# pipx seam mock: records argv into MOCK_PIPX_LOG (one line per call). `list`
# emits MOCK_PIPX_LIST (used by is_installed / version via `list --short`);
# every other subcommand returns MOCK_PIPX_RC.
_mock_pipx() {
    MOCK_PIPX_LOG="${INIT_UBUNTU_TEST_SCRATCH}/pipx.log"
    : > "${MOCK_PIPX_LOG}"
    _bpytop_pipx() {
        printf '%s\n' "$*" >> "${MOCK_PIPX_LOG}"
        case "${1:-}" in
            list) printf '%s\n' "${MOCK_PIPX_LIST:-}" ;;
            *)    return "${MOCK_PIPX_RC:-0}" ;;
        esac
    }
}

# Fake bpytop binary answering --version.
_fake_bpytop_bin() {
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    printf '#!/usr/bin/env bash\nprintf "bpytop version: 1.0.68\\n"\n' \
        > "${INIT_UBUNTU_TEST_SCRATCH}/bin/bpytop"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/bpytop"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}"
}

# Put a fake executable on PATH so `command -v <name>` succeeds.
_fake_bin() {
    local _name="${1:?bin name required}"
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    printf '#!/bin/sh\nexit 0\n' > "${INIT_UBUNTU_TEST_SCRATCH}/bin/${_name}"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/${_name}"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}"
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "bpytop module file parses (bash -n)" {
    run bash -n "${MODULE_DIR}/bpytop.module.sh"
    assert_success
}

@test "bpytop module sources cleanly in engine mode (MODULE_STANDALONE=false)" {
    _load_module
    [[ "${MODULE_STANDALONE}" == "false" ]]
}

@test "bpytop module defines all 10 lifecycle functions" {
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

@test "bpytop module declares NAME=bpytop" {
    _load_module
    [[ "${NAME}" == "bpytop" ]]
}

@test "bpytop module CATEGORY=optional" {
    _load_module
    [[ "${CATEGORY}" == "optional" ]]
}

@test "bpytop module TAGS contains monitoring" {
    _load_module
    [[ " ${TAGS[*]} " == *" monitoring "* ]]
}

@test "bpytop module DEPENDS_ON contains pipx" {
    _load_module
    [[ " ${DEPENDS_ON[*]} " == *" pipx "* ]]
}

@test "bpytop DESCRIPTION is associative with en + zh-TW entries" {
    _load_module
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ -n "${DESCRIPTION[en]}" ]]
    [[ -n "${DESCRIPTION[zh-TW]}" ]]
}

@test "bpytop module_get_description returns language-specific text" {
    _load_module
    [[ "$(module_get_description en)" == *"monitor"* ]]
    [[ -n "$(module_get_description zh-TW)" ]]
    # Unknown language falls back to en.
    [[ "$(module_get_description xx)" == "$(module_get_description en)" ]]
}

@test "bpytop module VERSION_PROVIDED=pipx-managed" {
    _load_module
    [[ "${VERSION_PROVIDED}" == "pipx-managed" ]]
}

@test "bpytop module INSTALL_TARGET_DEFAULT=user-home (pipx is user-level)" {
    _load_module
    [[ "${INSTALL_TARGET_DEFAULT}" == "user-home" ]]
}

@test "bpytop module SUPPORTS_USER_HOME=true" {
    _load_module
    [[ "${SUPPORTS_USER_HOME}" == "true" ]]
}

@test "bpytop module RISK_LEVEL=low" {
    _load_module
    [[ "${RISK_LEVEL}" == "low" ]]
}

@test "bpytop module SUPPORTED_UBUNTU covers 22.04 / 24.04 / 26.04" {
    _load_module
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 22.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 24.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 26.04 "* ]]
}

@test "bpytop HOMEPAGE points at the aristocratos/bpytop project" {
    _load_module
    [[ "${HOMEPAGE}" == *"aristocratos/bpytop"* ]]
}

@test "bpytop POST_INSTALL_MESSAGE mentions pipx / PATH" {
    _load_module
    [[ "$(module_get_post_install_message en)" == *"pipx"* ]]
    [[ -n "$(module_get_post_install_message zh-TW)" ]]
}

@test "TEST_VERIFY_CMD exercises the bpytop binary" {
    _load_module
    [[ "${TEST_VERIFY_CMD}" == *"bpytop"* ]]
}

# ── is_installed: pipx ownership ─────────────────────────────────────────────

@test "is_installed returns zero when pipx list shows bpytop" {
    _load_module
    MOCK_PIPX_LIST="bpytop 1.0.68"
    _mock_pipx
    run is_installed
    assert_success
}

@test "is_installed returns nonzero when pipx list is empty" {
    _load_module
    MOCK_PIPX_LIST=""
    _mock_pipx
    run is_installed
    assert_failure
}

@test "is_installed ignores an unrelated pipx package" {
    _load_module
    MOCK_PIPX_LIST="some-other-pkg 2.0.0"
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
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/bpytop" ]]
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/state.json" ]]
}

@test "dry-run install never shells out to pipx" {
    _load_module
    _mock_pipx
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

# ── install / upgrade / remove: pipx paths (custom archetype core) ───────────

@test "install runs pipx install bpytop" {
    _load_module
    MOCK_PIPX_LIST=""
    _mock_pipx
    install
    grep -q '^install bpytop$' "${MOCK_PIPX_LOG}"
}

@test "install skips when already pipx-managed (idempotent fast path)" {
    _load_module
    MOCK_PIPX_LIST="bpytop 1.0.68"
    _mock_pipx
    run install
    assert_success
    assert_output --partial "already installed"
    run grep -q '^install bpytop$' "${MOCK_PIPX_LOG}"
    assert_failure
}

@test "failed pipx install propagates the failure" {
    _load_module
    MOCK_PIPX_LIST=""
    MOCK_PIPX_RC=1
    _mock_pipx
    run install
    assert_failure
}

@test "upgrade on a missing install falls through to install" {
    _load_module
    MOCK_PIPX_LIST=""
    _mock_pipx
    run upgrade
    assert_success
    grep -q '^install bpytop$' "${MOCK_PIPX_LOG}"
}

@test "upgrade uses pipx upgrade when already pipx-managed" {
    _load_module
    MOCK_PIPX_LIST="bpytop 1.0.68"
    _mock_pipx
    run upgrade
    assert_success
    grep -q '^upgrade bpytop$' "${MOCK_PIPX_LOG}"
}

@test "failed pipx upgrade propagates the failure" {
    _load_module
    MOCK_PIPX_LIST="bpytop 1.0.68"
    MOCK_PIPX_RC=1
    _mock_pipx
    run upgrade
    assert_failure
}

@test "remove uses pipx uninstall" {
    _load_module
    MOCK_PIPX_LIST="bpytop 1.0.68"
    _mock_pipx
    run remove
    assert_success
    grep -q '^uninstall bpytop$' "${MOCK_PIPX_LOG}"
}

@test "remove on a not-installed bpytop is a no-op" {
    _load_module
    MOCK_PIPX_LIST=""
    _mock_pipx
    run remove
    assert_success
    assert_output --partial "nothing to do"
}

# ── Sidecar lifecycle (ADR-0001) ─────────────────────────────────────────────

@test "install writes the sidecar with the pipx-reported version" {
    _load_module
    MOCK_PIPX_LIST="bpytop 1.0.68"
    _mock_pipx
    # is_installed must be false so install actually runs; flip via a
    # one-shot override that reports "not installed", then let the version
    # helper read the mocked pipx list.
    is_installed() { return 1; }
    module_standalone_main install
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/bpytop" ]]
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/bpytop")" == "1.0.68" ]]
}

@test "install sidecar falls back to pipx-managed when pipx list is empty" {
    _load_module
    MOCK_PIPX_LIST=""
    _mock_pipx
    module_standalone_main install
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/bpytop")" == "pipx-managed" ]]
}

@test "install never touches state.json (ADR-0001 / AC-23 pattern)" {
    _load_module
    printf '{"schema_version":"0.1.0","installed":{}}\n' \
        > "${INIT_UBUNTU_STATE_DIR}/state.json"
    local _before; _before="$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")"
    MOCK_PIPX_LIST=""
    _mock_pipx
    module_standalone_main install
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")" == "${_before}" ]]
}

@test "failed install leaves no sidecar (ADR-0015)" {
    _load_module
    MOCK_PIPX_LIST=""
    MOCK_PIPX_RC=1
    _mock_pipx
    run module_standalone_main install
    assert_failure
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/bpytop" ]]
}

@test "remove deletes the sidecar" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.0.68\n' > "${INIT_UBUNTU_STATE_DIR}/versions/bpytop"
    MOCK_PIPX_LIST="bpytop 1.0.68"
    _mock_pipx
    module_standalone_main remove
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/bpytop" ]]
    grep -q '^uninstall bpytop$' "${MOCK_PIPX_LOG}"
}

@test "purge uninstalls via pipx and deletes the sidecar" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.0.68\n' > "${INIT_UBUNTU_STATE_DIR}/versions/bpytop"
    MOCK_PIPX_LIST="bpytop 1.0.68"
    _mock_pipx
    module_standalone_main purge
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/bpytop" ]]
    grep -q '^uninstall bpytop$' "${MOCK_PIPX_LOG}"
}

# ── Idempotency (AC-5 pattern) ───────────────────────────────────────────────

@test "install twice exits 0 both times" {
    _load_module
    MOCK_PIPX_LIST=""
    _mock_pipx
    run install
    assert_success
    MOCK_PIPX_LIST="bpytop 1.0.68"
    _mock_pipx
    run install
    assert_success
}

@test "remove is idempotent — second run still exits 0" {
    _load_module
    MOCK_PIPX_LIST="bpytop 1.0.68"
    _mock_pipx
    run remove
    assert_success
    MOCK_PIPX_LIST=""
    _mock_pipx
    run remove
    assert_success
}

# ── verify / doctor / is_outdated ────────────────────────────────────────────

@test "verify fails when not installed" {
    _load_module
    MOCK_PIPX_LIST=""
    _mock_pipx
    run verify
    assert_failure
}

@test "verify passes when installed and TEST_VERIFY_CMD succeeds" {
    _load_module
    MOCK_PIPX_LIST="bpytop 1.0.68"
    _mock_pipx
    TEST_VERIFY_CMD="true"
    run verify
    assert_success
}

@test "doctor fails when not installed" {
    _load_module
    MOCK_PIPX_LIST=""
    _mock_pipx
    run doctor
    assert_failure
}

@test "doctor passes when bpytop answers --version" {
    _load_module
    MOCK_PIPX_LIST="bpytop 1.0.68"
    _mock_pipx
    _fake_bpytop_bin
    run doctor
    assert_success
}

@test "doctor fails when the bpytop binary is not on PATH" {
    _load_module
    MOCK_PIPX_LIST="bpytop 1.0.68"
    _mock_pipx
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/empty-bin"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/empty-bin" run doctor
    assert_failure
}

@test "is_outdated returns nonzero (pipx upgrade is idempotent; no cheap probe)" {
    _load_module
    run is_outdated
    assert_failure
}

# ── is_recommended / detect ──────────────────────────────────────────────────

@test "is_recommended is zero when not installed" {
    _load_module
    MOCK_PIPX_LIST=""
    _mock_pipx
    run is_recommended
    assert_success
}

@test "is_recommended is nonzero when already installed" {
    _load_module
    MOCK_PIPX_LIST="bpytop 1.0.68"
    _mock_pipx
    run is_recommended
    assert_failure
}

@test "detect succeeds when apt-get is available" {
    _load_module
    _fake_bin apt-get
    run detect
    assert_success
}

@test "detect fails without apt-get on PATH" {
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
    assert_output --partial "bpytop"
}

@test "standalone: unknown phase returns exit 2" {
    run _standalone_module nope
    assert_failure 2
}

@test "standalone: info prints metadata" {
    run _standalone_module info
    assert_success
    assert_output --partial "name:        bpytop"
    assert_output --partial "category:    optional"
    assert_output --partial "monitoring"
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
    run _standalone_module is-outdated
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "standalone: doctor is implemented (exit != 2)" {
    run _standalone_module doctor
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}
