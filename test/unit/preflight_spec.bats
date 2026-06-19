#!/usr/bin/env bats
# test/unit/preflight_spec.bats — lib/preflight.sh (self-deps preflight)
#
# PRD §3.4 / AC-34: entrypoint checks the tool's own dependencies
# (jq / curl / git) before running anything that needs them.
#
# HOST-SAFETY: these specs never touch the real apt / sudo / command -v
# probes — `_preflight_has_cmd`, `_preflight_has_sudo` and
# `_preflight_apt_install` are overridden below with parameterized mocks
# (one definition per name; behavior driven by MOCK_* variables). The
# real apt-install path is exercised by the AC-34 integration check
# inside a clean CI container (wave 6), not here.

load "${BATS_TEST_DIRNAME}/../helper/common"

# Source the library at file level, THEN shadow its probes. bats
# re-evaluates the whole file per test, so every test gets fresh copies.
# shellcheck source=../../lib/preflight.sh
source "${LIB_DIR}/preflight.sh"

# ── Parameterized probe mocks ────────────────────────────────────────────────
# MOCK_MISSING_DEPS  space-separated dep names reported as missing
# MOCK_HAS_SUDO      true|false
# MOCK_APT_RC        exit code for the fake apt install

_preflight_has_cmd() {
    case " ${MOCK_MISSING_DEPS:-} " in
        *" ${1} "*) return 1 ;;
    esac
    return 0
}

_preflight_has_sudo() {
    [[ "${MOCK_HAS_SUDO:-true}" == "true" ]]
}

_preflight_apt_install() {
    printf '%s\n' "$*" >> "${APT_STUB_LOG}"
    return "${MOCK_APT_RC:-0}"
}

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false

    APT_STUB_LOG="${INIT_UBUNTU_TEST_SCRATCH}/apt-stub.log"
    export APT_STUB_LOG

    MOCK_MISSING_DEPS=""
    MOCK_HAS_SUDO=true
    MOCK_APT_RC=0
}

teardown() {
    unset INIT_UBUNTU_PREFLIGHT_DONE INIT_UBUNTU_YES \
          MOCK_MISSING_DEPS MOCK_HAS_SUDO MOCK_APT_RC
    teardown_test_env
}

# ── Quadrant: nothing missing ────────────────────────────────────────────────

@test "preflight: all deps present -> success, no prompt, no apt" {
    run preflight_self_deps install foo
    assert_success
    refute_output --partial "Proceed?"
    [[ ! -f "${APT_STUB_LOG}" ]]
}

@test "preflight: all deps present + no sudo -> still success" {
    MOCK_HAS_SUDO=false
    run preflight_self_deps install foo
    assert_success
}

# ── Quadrant: missing + sudo available ───────────────────────────────────────

@test "preflight: missing + sudo + answer Y -> installs missing deps" {
    MOCK_MISSING_DEPS="jq"
    run preflight_self_deps install foo <<< "y"
    assert_success
    assert_output --partial "jq"
    assert_output --partial "Proceed?"
    run cat "${APT_STUB_LOG}"
    assert_output "jq"
}

@test "preflight: missing + sudo + empty answer (default Y) -> installs" {
    MOCK_MISSING_DEPS="jq"
    run preflight_self_deps install foo <<< ""
    assert_success
    run cat "${APT_STUB_LOG}"
    assert_output "jq"
}

@test "preflight: missing + sudo + answer n -> exit 1, nothing installed" {
    MOCK_MISSING_DEPS="jq"
    run preflight_self_deps install foo <<< "n"
    assert_failure 1
    [[ ! -f "${APT_STUB_LOG}" ]]
}

@test "preflight: missing + sudo + no input (EOF) -> exit 1 with -y hint" {
    MOCK_MISSING_DEPS="jq"
    run preflight_self_deps install foo < /dev/null
    assert_failure 1
    assert_output --partial "-y"
    [[ ! -f "${APT_STUB_LOG}" ]]
}

@test "preflight: missing + sudo + -y flag -> auto-installs without prompt" {
    MOCK_MISSING_DEPS="jq"
    run preflight_self_deps install foo -y
    assert_success
    refute_output --partial "Proceed?"
    run cat "${APT_STUB_LOG}"
    assert_output "jq"
}

@test "preflight: missing + sudo + --yes flag -> auto-installs without prompt" {
    MOCK_MISSING_DEPS="jq"
    run preflight_self_deps install foo --yes
    assert_success
    refute_output --partial "Proceed?"
    run cat "${APT_STUB_LOG}"
    assert_output "jq"
}

@test "preflight: missing + sudo + INIT_UBUNTU_YES=true -> auto-installs" {
    MOCK_MISSING_DEPS="jq"
    export INIT_UBUNTU_YES=true
    run preflight_self_deps install foo
    assert_success
    refute_output --partial "Proceed?"
    run cat "${APT_STUB_LOG}"
    assert_output "jq"
}

@test "preflight: only the missing deps go into the apt plan" {
    MOCK_MISSING_DEPS="jq"
    run preflight_self_deps install foo -y
    assert_success
    run cat "${APT_STUB_LOG}"
    assert_output "jq"
    refute_output --partial "curl"
    refute_output --partial "git"
}

@test "preflight: all three missing -> all three in the apt plan" {
    MOCK_MISSING_DEPS="jq curl git"
    run preflight_self_deps install foo -y
    assert_success
    run cat "${APT_STUB_LOG}"
    assert_output "jq curl git"
}

@test "preflight: apt install failure -> exit 1 with error" {
    MOCK_MISSING_DEPS="jq"
    MOCK_APT_RC=1
    run preflight_self_deps install foo -y
    assert_failure 1
    assert_output --partial "ERROR"
}

# ── Quadrant: missing + no sudo ──────────────────────────────────────────────

@test "preflight: missing + no sudo -> exit 4 with install guidance" {
    MOCK_MISSING_DEPS="jq"
    MOCK_HAS_SUDO=false
    run preflight_self_deps install foo
    assert_failure 4
    assert_output --partial "jq"
    assert_output --partial "apt-get install"
    [[ ! -f "${APT_STUB_LOG}" ]]
}

@test "preflight: missing + no sudo + -y -> still exit 4 (cannot install)" {
    MOCK_MISSING_DEPS="jq"
    MOCK_HAS_SUDO=false
    run preflight_self_deps install foo -y
    assert_failure 4
    [[ ! -f "${APT_STUB_LOG}" ]]
}

# ── Subcommand gating: help / version do not need deps ───────────────────────

@test "preflight: help does not trigger even with everything missing" {
    MOCK_MISSING_DEPS="jq curl git"
    MOCK_HAS_SUDO=false
    run preflight_self_deps help
    assert_success
    refute_output --partial "missing"
    [[ ! -f "${APT_STUB_LOG}" ]]
}

@test "preflight: version does not trigger" {
    MOCK_MISSING_DEPS="jq curl git"
    MOCK_HAS_SUDO=false
    run preflight_self_deps version
    assert_success
}

@test "preflight: --help / -h / --version do not trigger" {
    MOCK_MISSING_DEPS="jq curl git"
    MOCK_HAS_SUDO=false
    run preflight_self_deps --help
    assert_success
    run preflight_self_deps -h
    assert_success
    run preflight_self_deps --version
    assert_success
}

@test "preflight: empty argv (usage path) does not trigger" {
    MOCK_MISSING_DEPS="jq curl git"
    MOCK_HAS_SUDO=false
    run preflight_self_deps
    assert_success
}

# ── At most once per run ─────────────────────────────────────────────────────

@test "preflight: second call in the same run is a no-op (asks/installs once)" {
    MOCK_MISSING_DEPS="jq"
    preflight_self_deps install foo -y
    preflight_self_deps install foo -y
    run cat "${APT_STUB_LOG}"
    assert_output "jq"   # exactly one line — one install, not two
}

@test "preflight: INIT_UBUNTU_PREFLIGHT_DONE=true preset skips entirely" {
    MOCK_MISSING_DEPS="jq curl git"
    MOCK_HAS_SUDO=false
    export INIT_UBUNTU_PREFLIGHT_DONE=true
    run preflight_self_deps install foo
    assert_success
    [[ ! -f "${APT_STUB_LOG}" ]]
}

# ── i18n: zh-TW rendering (issue #185, Phase 2) ──────────────────────────────

@test "preflight: missing + no sudo guidance renders zh-TW under INIT_UBUNTU_LANG=zh-TW" {
    MOCK_MISSING_DEPS="jq"
    MOCK_HAS_SUDO=false
    INIT_UBUNTU_LANG=zh-TW run preflight_self_deps install foo
    assert_failure 4
    assert_output --partial "缺少工具相依套件：jq"
    assert_output --partial "無法使用 sudo"
}
