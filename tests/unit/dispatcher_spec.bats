#!/usr/bin/env bats
# tests/unit/dispatcher_spec.bats — lib/dispatcher.sh

load "${BATS_TEST_DIRNAME}/../helpers/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false

    FAKE_MODULE_DIR="${INIT_UBUNTU_TEST_SCRATCH}/modules"
    mkdir -p "${FAKE_MODULE_DIR}"

    cat > "${FAKE_MODULE_DIR}/noop.module.sh" <<'EOF'
NAME="noop"
CATEGORY="optional"
TAGS=("test")
SUPPORTED_UBUNTU=()
SUPPORTED_PLATFORMS=()
DEPENDS_ON=()
CONFLICTS_WITH=()

install() { return 0; }
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
    source "${LIB_DIR}/resolver.sh"
    source "${LIB_DIR}/runner.sh"
    source "${LIB_DIR}/dispatcher.sh"
    registry_load_all "${FAKE_MODULE_DIR}"
}

@test "dispatcher_dispatch with no args prints usage" {
    _load_engine
    run dispatcher_dispatch
    assert_success
    assert_output --partial "Usage: setup_ubuntu"
}

@test "dispatcher_dispatch --help prints usage" {
    _load_engine
    run dispatcher_dispatch --help
    assert_success
    assert_output --partial "Usage: setup_ubuntu"
}

@test "dispatcher_dispatch --version prints tool version" {
    _load_engine
    run dispatcher_dispatch --version
    assert_success
    assert_output --partial "init_ubuntu"
}

@test "dispatcher_dispatch list shows registered modules" {
    _load_engine
    run dispatcher_dispatch list
    assert_success
    assert_output --partial "noop"
}

@test "dispatcher_dispatch list --category=optional filters" {
    _load_engine
    run dispatcher_dispatch list --category=optional
    assert_success
    assert_output --partial "noop"
}

@test "dispatcher_dispatch list --category=base produces empty (no base modules in fixture)" {
    _load_engine
    run dispatcher_dispatch list --category=base
    assert_success
    refute_output --partial "noop"
}

@test "dispatcher_dispatch show <module> prints metadata fields" {
    _load_engine
    run dispatcher_dispatch show noop
    assert_success
    assert_output --partial "name:"
    assert_output --partial "noop"
    assert_output --partial "category:"
    assert_output --partial "optional"
}

@test "dispatcher_dispatch show unknown returns exit 2" {
    _load_engine
    run dispatcher_dispatch show nonexistent
    assert_failure 2
}

@test "dispatcher_dispatch install without modules returns exit 2" {
    _load_engine
    run dispatcher_dispatch install
    assert_failure 2
}

@test "dispatcher_dispatch install <module> --dry-run does not execute" {
    _load_engine
    run dispatcher_dispatch install noop --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
    assert_output --partial "noop"
}

@test "dispatcher_dispatch install <module> --dry-run succeeds" {
    # Use --dry-run because the test-tools container runs as root and the
    # dispatcher refuses real install/remove/purge under root (PRD §10).
    # Dry-run is the right surface for testing dispatcher -> resolver wiring
    # without depending on container user identity.
    _load_engine
    run dispatcher_dispatch install noop --dry-run
    assert_success
}

@test "dispatcher_dispatch install nonexistent returns exit 2 (resolver unknown)" {
    _load_engine
    run dispatcher_dispatch install nonexistent
    assert_failure 2
}

@test "dispatcher_dispatch unknown-subcommand returns exit 2" {
    _load_engine
    run dispatcher_dispatch this-is-not-real
    assert_failure 2
}

@test "dispatcher_dispatch stubbed subcommand (self-upgrade) returns non-zero with 'not implemented'" {
    _load_engine
    run dispatcher_dispatch self-upgrade
    assert_failure
    assert_output --partial "not implemented"
}
