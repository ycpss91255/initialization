#!/usr/bin/env bats
# test/unit/module/apt-essentials_spec.bats — module/apt-essentials.module.sh
# (issue #123, Batch-A backfill)
#
# Per Q29: smoke / metadata / lifecycle dry-run / no-side-fx / idempotency /
# standalone CLI (AC-25) / module-specific behaviors.
#
# Module-specific notes (vs. the plain apt archetype, see ripgrep_spec.bats):
#   - Hand-written lifecycle: per-pkg fallback install (PRD §18.1 Q-A12 /
#     A-N6) — one missing pkg never kills the whole batch.
#   - remove/purge are intentionally NON-destructive: baseline pkgs are only
#     apt-mark'ed auto, never apt-removed.
#   - is_outdated / doctor are NOT implemented; module_standalone_main fails
#     gracefully (exit 2 + "not implemented") for those optional phases.
#   - No version sidecar: VERSION_PROVIDED=apt-managed and install() never
#     calls module_sidecar_write. ADR-0011's frozen_pkgs/INCOMPAT_BY_PLATFORM
#     are engine-side state (not yet in the module); this spec pins the
#     current universal-list behavior.

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
    # shellcheck source=../../../module/apt-essentials.module.sh
    source "${MODULE_DIR}/apt-essentials.module.sh"
}

# _standalone_module runs the module as a self-contained CLI (the same
# entry users hit when they type `bash module/apt-essentials.module.sh ...`).
_standalone_module() {
    bash "${MODULE_DIR}/apt-essentials.module.sh" "$@"
}

# ── Controllable mocks ───────────────────────────────────────────────────────
# Each shadowed function is defined exactly once and parameterized via
# MOCK_* variables, so every definition stays reachable for the linter
# (avoids SC2317 without disable directives).

# have_sudo_access mock: MOCK_SUDO_RC (0 = sudo available, 1 = not).
_mock_have_sudo_access() {
    have_sudo_access() { return "${MOCK_SUDO_RC:-0}"; }
}

# sudo mock: records every invocation into ${INIT_UBUNTU_TEST_SCRATCH}/sudo.log
# and never runs the real command. `apt-get install` calls return
# MOCK_APT_INSTALL_RC (default 0), `apt-get update` returns
# MOCK_APT_UPDATE_RC (default 0); everything else (apt-mark) 0.
_mock_sudo() {
    sudo() {
        printf '%s\n' "$*" >> "${INIT_UBUNTU_TEST_SCRATCH}/sudo.log"
        case "$*" in
            apt-get\ install*) return "${MOCK_APT_INSTALL_RC:-0}" ;;
            apt-get\ update*)  return "${MOCK_APT_UPDATE_RC:-0}" ;;
        esac
        return 0
    }
}

# dpkg mock: pkgs listed in MOCK_DPKG_INSTALLED (space-separated) report a
# '^ii' line; everything else returns 1 (not installed).
_mock_dpkg() {
    dpkg() {
        local _pkg="${2:-}"
        [[ " ${MOCK_DPKG_INSTALLED:-} " == *" ${_pkg} "* ]] || return 1
        printf 'ii  %s  1.0  amd64  baseline pkg\n' "${_pkg}"
    }
}

# lsb_release mock for detect(): MOCK_LSB_ID (e.g. Ubuntu / Debian).
_mock_lsb_release() {
    lsb_release() { printf '%s\n' "${MOCK_LSB_ID:-Ubuntu}"; }
}

_assert_sudo_log_has() {
    grep -q "$1" "${INIT_UBUNTU_TEST_SCRATCH}/sudo.log"
}

_refute_sudo_log_has() {
    ! grep -q "$1" "${INIT_UBUNTU_TEST_SCRATCH}/sudo.log" 2>/dev/null
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "apt-essentials module file parses (bash -n)" {
    run bash -n "${MODULE_DIR}/apt-essentials.module.sh"
    assert_success
}

@test "apt-essentials sources cleanly in engine mode (MODULE_STANDALONE=false)" {
    _load_module
    [[ "${MODULE_STANDALONE}" == "false" ]]
}

@test "sourcing in engine mode runs no lifecycle phase" {
    run _load_module
    assert_success
    refute_output --partial "summary:"
    refute_output --partial "DRY-RUN"
}

@test "apt-essentials defines its 8 hand-written lifecycle functions" {
    _load_module
    local _fn
    for _fn in detect is_recommended is_installed install upgrade \
               remove purge verify; do
        declare -F "${_fn}" >/dev/null || {
            printf 'missing lifecycle function: %s\n' "${_fn}" >&2
            return 1
        }
    done
}

@test "is_outdated and doctor are intentionally absent (optional phases)" {
    _load_module
    run ! declare -F is_outdated
    run ! declare -F doctor
}

# ── Metadata sanity (doc/module-spec.md §3) ──────────────────────────────────

@test "apt-essentials declares NAME=apt-essentials" {
    _load_module
    [[ "${NAME}" == "apt-essentials" ]]
}

@test "apt-essentials CATEGORY=base" {
    _load_module
    [[ "${CATEGORY}" == "base" ]]
}

@test "apt-essentials TAGS contains core and apt" {
    _load_module
    [[ " ${TAGS[*]} " == *" core "* ]]
    [[ " ${TAGS[*]} " == *" apt "* ]]
}

@test "apt-essentials DEPENDS_ON is empty (root of the dep tree)" {
    _load_module
    [[ "${#DEPENDS_ON[@]}" -eq 0 ]]
}

@test "apt-essentials DESCRIPTION is associative with en + zh-TW entries" {
    _load_module
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ -n "${DESCRIPTION[en]}" ]]
    [[ -n "${DESCRIPTION[zh-TW]}" ]]
}

@test "module_get_description returns language-specific text + en fallback" {
    _load_module
    [[ "$(module_get_description en)" == *"apt baseline"* ]]
    [[ -n "$(module_get_description zh-TW)" ]]
    # Unknown language falls back to en.
    [[ "$(module_get_description xx)" == "$(module_get_description en)" ]]
}

@test "apt-essentials SUPPORTED_UBUNTU includes 22.04 24.04 26.04" {
    _load_module
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 22.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 24.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 26.04 "* ]]
}

@test "SUPPORTED_PLATFORMS covers all five form factors (ADR-0011 universal base)" {
    _load_module
    local _p
    for _p in desktop server wsl container vm; do
        [[ " ${SUPPORTED_PLATFORMS[*]} " == *" ${_p} "* ]] || {
            printf 'missing platform: %s\n' "${_p}" >&2
            return 1
        }
    done
}

@test "apt-essentials RISK_LEVEL=low and REBOOT_REQUIRED=false" {
    _load_module
    [[ "${RISK_LEVEL}" == "low" ]]
    [[ "${REBOOT_REQUIRED}" == "false" ]]
}

@test "apt-essentials VERSION_PROVIDED=apt-managed" {
    _load_module
    [[ "${VERSION_PROVIDED}" == "apt-managed" ]]
}

@test "INSTALL_TARGET_DEFAULT=sudo and SUPPORTS_USER_HOME=false" {
    _load_module
    [[ "${INSTALL_TARGET_DEFAULT}" == "sudo" ]]
    [[ "${SUPPORTS_USER_HOME}" == "false" ]]
}

@test "APT_PKGS is the universal baseline set, no PPA" {
    _load_module
    local _pkg
    for _pkg in git vim curl wget ca-certificates jq; do
        [[ " ${APT_PKGS[*]} " == *" ${_pkg} "* ]] || {
            printf 'missing baseline pkg: %s\n' "${_pkg}" >&2
            return 1
        }
    done
    [[ "${#APT_PKGS[@]}" -eq 6 ]]
    [[ -z "${APT_PPA}" ]]
}

@test "TEST_VERIFY_CMD is declared for module_default_verify" {
    _load_module
    [[ -n "${TEST_VERIFY_CMD}" ]]
}

# ── is_installed: every baseline pkg must be ii ──────────────────────────────

@test "is_installed returns nonzero when dpkg reports nothing installed" {
    _load_module
    MOCK_DPKG_INSTALLED=""
    _mock_dpkg
    run is_installed
    assert_failure
}

@test "is_installed returns nonzero when only some pkgs are installed" {
    _load_module
    MOCK_DPKG_INSTALLED="git curl"
    _mock_dpkg
    run is_installed
    assert_failure
}

@test "is_installed returns zero when every baseline pkg is ii" {
    _load_module
    MOCK_DPKG_INSTALLED="${APT_PKGS[*]}"
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

@test "purge in dry-run mode is a no-op (guards before delegating to remove)" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run purge
    assert_success
    assert_output --partial "DRY-RUN"
    refute_output --partial "apt-mark"
}

@test "verify in dry-run mode is a no-op" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run verify
    assert_success
    assert_output --partial "DRY-RUN"
}

# ── No side effects under dry-run / read-only phases ─────────────────────────

@test "dry-run install writes nothing under the state dir" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    [[ -z "$(find "${INIT_UBUNTU_STATE_DIR}" -type f 2>/dev/null)" ]]
}

@test "detect / is_installed / is_recommended leave the state dir untouched" {
    _load_module
    MOCK_DPKG_INSTALLED=""
    _mock_dpkg
    _mock_lsb_release
    detect || true
    is_installed || true
    is_recommended || true
    [[ -z "$(find "${INIT_UBUNTU_STATE_DIR}" -type f 2>/dev/null)" ]]
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

# ── install: per-pkg fallback strategy (PRD §18.1 Q-A12 / A-N6) ──────────────

@test "install with everything already ii skips apt-get install entirely" {
    _load_module
    _mock_have_sudo_access
    _mock_sudo
    MOCK_DPKG_INSTALLED="${APT_PKGS[*]}"
    _mock_dpkg
    run install
    assert_success
    assert_output --partial "summary: ok=6 skipped=0 failed=0"
    _refute_sudo_log_has "apt-get install"
}

@test "install with sudo installs each missing pkg individually" {
    _load_module
    _mock_have_sudo_access
    _mock_sudo
    MOCK_DPKG_INSTALLED=""
    _mock_dpkg
    run install
    assert_success
    assert_output --partial "summary: ok=6 skipped=0 failed=0"
    _assert_sudo_log_has "apt-get update"
    _assert_sudo_log_has "apt-get install -y --no-install-recommends git"
    _assert_sudo_log_has "apt-get install -y --no-install-recommends jq"
}

@test "install without sudo skips missing pkgs but still exits 0" {
    _load_module
    MOCK_SUDO_RC=1
    _mock_have_sudo_access
    _mock_sudo
    MOCK_DPKG_INSTALLED=""
    _mock_dpkg
    run install
    assert_success
    assert_output --partial "no sudo"
    assert_output --partial "summary: ok=0 skipped=6 failed=0"
    assert_output --partial "manually install:"
    [[ ! -e "${INIT_UBUNTU_TEST_SCRATCH}/sudo.log" ]]
}

@test "install hard-fails only when every attempted pkg install fails" {
    _load_module
    _mock_have_sudo_access
    MOCK_APT_INSTALL_RC=1
    _mock_sudo
    MOCK_DPKG_INSTALLED=""
    _mock_dpkg
    run install
    assert_failure
    assert_output --partial "summary: ok=0 skipped=0 failed=6"
    assert_output --partial "failed:"
}

@test "one failing pkg does not kill the batch (continue-on-error)" {
    _load_module
    _mock_have_sudo_access
    MOCK_APT_INSTALL_RC=1
    _mock_sudo
    MOCK_DPKG_INSTALLED="git"
    _mock_dpkg
    run install
    assert_success
    assert_output --partial "summary: ok=1 skipped=0 failed=5"
}

@test "install survives a failing apt-get update (warn + per-pkg anyway)" {
    _load_module
    _mock_have_sudo_access
    MOCK_APT_UPDATE_RC=1
    _mock_sudo
    MOCK_DPKG_INSTALLED=""
    _mock_dpkg
    run install
    assert_success
    assert_output --partial "apt-get update failed"
    assert_output --partial "summary: ok=6 skipped=0 failed=0"
}

# ── upgrade: same per-pkg path as install ────────────────────────────────────

@test "upgrade reuses the install path (per-pkg summary)" {
    _load_module
    _mock_have_sudo_access
    _mock_sudo
    MOCK_DPKG_INSTALLED="${APT_PKGS[*]}"
    _mock_dpkg
    run upgrade
    assert_success
    assert_output --partial "summary: ok=6 skipped=0 failed=0"
}

# ── Idempotency (AC-5 pattern) ───────────────────────────────────────────────

@test "install twice exits 0 both times" {
    _load_module
    _mock_have_sudo_access
    _mock_sudo
    MOCK_DPKG_INSTALLED="${APT_PKGS[*]}"
    _mock_dpkg
    run install
    assert_success
    run install
    assert_success
}

@test "remove is idempotent — second run still exits 0" {
    _load_module
    _mock_have_sudo_access
    _mock_sudo
    run remove
    assert_success
    run remove
    assert_success
}

# ── remove / purge: intentionally NON-destructive for the baseline ───────────

@test "remove only apt-marks auto, never apt-get remove" {
    _load_module
    _mock_have_sudo_access
    _mock_sudo
    run remove
    assert_success
    _assert_sudo_log_has "apt-mark auto"
    _refute_sudo_log_has "apt-get remove"
}

@test "remove warns that the baseline is left in place" {
    _load_module
    _mock_have_sudo_access
    _mock_sudo
    run remove
    assert_success
    assert_output --partial "baseline left in place"
    assert_output --partial "apt autoremove"
}

@test "remove without sudo still exits 0 (no apt-mark attempted)" {
    _load_module
    MOCK_SUDO_RC=1
    _mock_have_sudo_access
    _mock_sudo
    run remove
    assert_success
    [[ ! -e "${INIT_UBUNTU_TEST_SCRATCH}/sudo.log" ]]
}

@test "purge delegates to remove — no apt-get purge, no CONFIG_PATHS wipe" {
    _load_module
    _mock_have_sudo_access
    _mock_sudo
    run purge
    assert_success
    assert_output --partial "baseline left in place"
    _assert_sudo_log_has "apt-mark auto"
    _refute_sudo_log_has "apt-get purge"
}

@test "purge is idempotent — second run still exits 0" {
    _load_module
    _mock_have_sudo_access
    _mock_sudo
    run purge
    assert_success
    run purge
    assert_success
}

# ── Sidecar / state boundary (ADR-0001) ──────────────────────────────────────

@test "install never touches state.json (ADR-0001 / AC-23 pattern)" {
    _load_module
    printf '{"schema_version":"0.1.0","installed":{}}\n' \
        > "${INIT_UBUNTU_STATE_DIR}/state.json"
    local _before; _before="$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")"
    _mock_have_sudo_access
    _mock_sudo
    MOCK_DPKG_INSTALLED="${APT_PKGS[*]}"
    _mock_dpkg
    install
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")" == "${_before}" ]]
}

@test "install writes no version sidecar (apt-managed baseline)" {
    _load_module
    _mock_have_sudo_access
    _mock_sudo
    MOCK_DPKG_INSTALLED="${APT_PKGS[*]}"
    _mock_dpkg
    install
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/apt-essentials" ]]
}

@test "remove leaves a pre-existing sidecar alone (no sidecar lifecycle)" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf 'apt-managed\n' > "${INIT_UBUNTU_STATE_DIR}/versions/apt-essentials"
    _mock_have_sudo_access
    _mock_sudo
    remove
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/apt-essentials" ]]
}

# ── verify ───────────────────────────────────────────────────────────────────

@test "verify fails when not installed" {
    _load_module
    MOCK_DPKG_INSTALLED=""
    _mock_dpkg
    run verify
    assert_failure
}

@test "verify passes when installed and TEST_VERIFY_CMD succeeds" {
    _load_module
    MOCK_DPKG_INSTALLED="${APT_PKGS[*]}"
    _mock_dpkg
    TEST_VERIFY_CMD="true"
    run verify
    assert_success
}

@test "verify fails when installed but TEST_VERIFY_CMD fails (ADR-0015)" {
    _load_module
    MOCK_DPKG_INSTALLED="${APT_PKGS[*]}"
    _mock_dpkg
    TEST_VERIFY_CMD="false"
    run verify
    assert_failure
}

# ── detect ───────────────────────────────────────────────────────────────────

@test "detect succeeds when lsb_release reports Ubuntu" {
    _load_module
    MOCK_LSB_ID="Ubuntu"
    _mock_lsb_release
    run detect
    assert_success
}

@test "detect fails when lsb_release reports a non-Ubuntu distro" {
    _load_module
    MOCK_LSB_ID="Debian"
    _mock_lsb_release
    run detect
    assert_failure
}

@test "detect fails when lsb_release is not on PATH" {
    _load_module
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/empty-bin"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/empty-bin" run detect
    assert_failure
}

# ── is_recommended: baseline is always recommended ───────────────────────────

@test "is_recommended is zero when not installed" {
    _load_module
    MOCK_DPKG_INSTALLED=""
    _mock_dpkg
    run is_recommended
    assert_success
}

@test "is_recommended stays zero even when already installed (baseline)" {
    _load_module
    MOCK_DPKG_INSTALLED="${APT_PKGS[*]}"
    _mock_dpkg
    run is_recommended
    assert_success
}

# ── Engine discovery (registry scan) ─────────────────────────────────────────

@test "registry discovers apt-essentials under --tag=core" {
    # shellcheck source=../../../lib/logger.sh
    source "${LIB_DIR}/logger.sh"
    # shellcheck source=../../../lib/registry.sh
    source "${LIB_DIR}/registry.sh"
    export INIT_UBUNTU_USER_MODULE_DIR="${INIT_UBUNTU_TEST_SCRATCH}/user-module"
    registry_load_all "${MODULE_DIR}"
    run registry_list_names --tag=core
    assert_success
    assert_output --partial "apt-essentials"
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
    assert_output --partial "apt-essentials"
    assert_output --partial "apt-managed"
}

@test "standalone: unknown phase returns exit 2" {
    run _standalone_module frobnicate
    assert_failure 2
}

@test "standalone: info prints metadata" {
    run _standalone_module info
    assert_success
    assert_output --partial "name:        apt-essentials"
    assert_output --partial "category:    base"
    assert_output --partial "core"
}

@test "standalone: info --lang=zh-TW prints localized description" {
    run _standalone_module info --lang=zh-TW
    assert_success
    assert_output --partial "基底"
}

@test "standalone: status reports installed + missing is_outdated" {
    run _standalone_module status
    assert_success
    assert_output --partial "installed:"
    assert_output --partial "(no is_outdated)"
}

# ── AC-25: implemented phases runnable; optional ones fail gracefully ────────

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

@test "standalone: is-outdated fails gracefully (optional, exit 2)" {
    run _standalone_module is-outdated
    assert_failure 2
    assert_output --partial "not implemented"
}

@test "standalone: doctor fails gracefully (optional, exit 2)" {
    run _standalone_module doctor
    assert_failure 2
    assert_output --partial "not implemented"
}
