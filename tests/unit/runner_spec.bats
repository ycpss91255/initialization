#!/usr/bin/env bats
# tests/unit/runner_spec.bats — lib/runner.sh

load "${BATS_TEST_DIRNAME}/../helpers/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false

    FAKE_MODULE_DIR="${INIT_UBUNTU_TEST_SCRATCH}/modules"
    mkdir -p "${FAKE_MODULE_DIR}"

    cat > "${FAKE_MODULE_DIR}/echo-mod.module.sh" <<'EOF'
NAME="echo-mod"
CATEGORY="optional"
TAGS=()
SUPPORTED_UBUNTU=()
SUPPORTED_PLATFORMS=()
DEPENDS_ON=()
CONFLICTS_WITH=()

install() { echo "INSTALL-RAN" >&2; return 0; }
remove()  { echo "REMOVE-RAN" >&2;  return 0; }
purge()   { echo "PURGE-RAN" >&2;   return 0; }
upgrade() { echo "UPGRADE-RAN" >&2; return 0; }
verify()  { echo "VERIFY-RAN" >&2;  return 0; }
doctor()  { echo "DOCTOR-RAN" >&2;  return 0; }
EOF

    cat > "${FAKE_MODULE_DIR}/fails.module.sh" <<'EOF'
NAME="fails"
CATEGORY="optional"
TAGS=()
SUPPORTED_UBUNTU=()
SUPPORTED_PLATFORMS=()
DEPENDS_ON=()
CONFLICTS_WITH=()

install() { echo "BOOM" >&2; return 1; }
remove()  { return 0; }
purge()   { return 0; }
EOF
}

teardown() {
    teardown_test_env
}

_load_engine() {
    source "${LIB_DIR}/logger.sh"
    source "${LIB_DIR}/general.sh"
    source "${LIB_DIR}/registry.sh"
    source "${LIB_DIR}/runner.sh"
    registry_load_all "${FAKE_MODULE_DIR}"
}

@test "runner_install runs install() of the named module" {
    _load_engine
    run runner_install echo-mod
    assert_success
    assert_output --partial "INSTALL-RAN"
}

@test "runner_remove runs remove() of the named module" {
    _load_engine
    run runner_remove echo-mod
    assert_success
    assert_output --partial "REMOVE-RAN"
}

@test "runner_purge runs purge() of the named module" {
    _load_engine
    run runner_purge echo-mod
    assert_success
    assert_output --partial "PURGE-RAN"
}

@test "runner_install on empty list is a no-op" {
    _load_engine
    run runner_install
    assert_success
    assert_output --partial "No modules"
}

@test "runner_install of unknown module fails the batch (exit 6)" {
    _load_engine
    run runner_install nonexistent
    assert_failure 6
}

@test "runner_install where one module fails returns 6 but continues others" {
    _load_engine
    run runner_install fails echo-mod
    assert_failure 6
    assert_output --partial "INSTALL-RAN"
    assert_output --partial "BOOM"
}

@test "INIT_UBUNTU_DRY_RUN=true is forwarded into module sub-shell" {
    _load_engine

    cat > "${FAKE_MODULE_DIR}/observer.module.sh" <<'EOF'
NAME="observer"
CATEGORY="optional"
TAGS=()
SUPPORTED_UBUNTU=()
SUPPORTED_PLATFORMS=()
DEPENDS_ON=()
CONFLICTS_WITH=()

install() {
    echo "OBSERVED-DRY-RUN=${INIT_UBUNTU_DRY_RUN:-unset}" >&2
}
remove() { return 0; }
purge()  { return 0; }
EOF
    registry_load_all "${FAKE_MODULE_DIR}"

    INIT_UBUNTU_DRY_RUN=true run runner_install observer
    assert_success
    assert_output --partial "OBSERVED-DRY-RUN=true"
}

@test "runner emits JSONL events to INIT_UBUNTU_LOG_FILE" {
    _load_engine
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/run.jsonl"
    INIT_UBUNTU_LOG_FILE="${_log}" runner_install echo-mod >/dev/null 2>&1 || true

    [[ -f "${_log}" ]]
    grep -q '"event":"session_start"' "${_log}"
    grep -q '"event":"install_start"' "${_log}"
    grep -q '"event":"install_done"' "${_log}"
    grep -q '"event":"session_end"' "${_log}"
}

# ── upgrade / verify / doctor phase ─────────────────────────────────────────

@test "runner_upgrade runs upgrade() of the named module" {
    _load_engine
    run runner_upgrade echo-mod
    assert_success
    assert_output --partial "UPGRADE-RAN"
}

@test "runner_verify runs verify() of the named module" {
    _load_engine
    run runner_verify echo-mod
    assert_success
    assert_output --partial "VERIFY-RAN"
}

@test "runner_doctor runs doctor() of the named module" {
    _load_engine
    run runner_doctor echo-mod
    assert_success
    assert_output --partial "DOCTOR-RAN"
}

@test "runner_upgrade on empty list is a no-op" {
    _load_engine
    run runner_upgrade
    assert_success
    assert_output --partial "No modules"
}

@test "runner_verify on empty list is a no-op" {
    _load_engine
    run runner_verify
    assert_success
    assert_output --partial "No modules"
}
