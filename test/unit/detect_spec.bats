#!/usr/bin/env bats
# test/unit/detect_spec.bats — lib/detect.sh

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
}

teardown() {
    teardown_test_env
}

_load_detect() {
    # shellcheck disable=SC1091
    source "${LIB_DIR}/detect.sh"
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "lib/detect.sh sources without error" {
    run bash -c "source '${LIB_DIR}/detect.sh'"
    assert_success
}

@test "detect_environment is defined" {
    run bash -c "source '${LIB_DIR}/detect.sh' && declare -F detect_environment"
    assert_success
    assert_output --partial "detect_environment"
}

@test "detect_get_field is defined" {
    run bash -c "source '${LIB_DIR}/detect.sh' && declare -F detect_get_field"
    assert_success
    assert_output --partial "detect_get_field"
}

# ── JSON shape ───────────────────────────────────────────────────────────────

@test "detect_environment emits one JSON object on stdout" {
    _load_detect
    run detect_environment
    assert_success
    [[ "${output:0:1}" == "{" ]]
    [[ "${output: -1}" == "}" ]]
}

@test "detect_environment JSON contains all top-level fields" {
    _load_detect
    run detect_environment
    assert_success
    assert_output --partial '"os":'
    assert_output --partial '"arch":'
    assert_output --partial '"cpu":'
    assert_output --partial '"gpu":'
    assert_output --partial '"desktop":'
    assert_output --partial '"session_type":'
    assert_output --partial '"virt":'
    assert_output --partial '"wsl":'
    assert_output --partial '"board":'
}

@test "detect_environment os object has id / version / codename" {
    _load_detect
    run detect_environment
    assert_success
    assert_output --partial '"os":{"id":'
    assert_output --partial '"version":'
    assert_output --partial '"codename":'
}

@test "detect_environment virt object has container / vm bools" {
    _load_detect
    run detect_environment
    assert_success
    assert_output --regexp '"virt":\{"container":(true|false|null)'
    assert_output --regexp '"vm":(true|false|null)'
}

# ── Container detection ──────────────────────────────────────────────────────

@test "running inside the test-tools container, virt.container is true" {
    _load_detect
    run detect_get_field virt.container
    assert_success
    assert_output "true"
}

# ── Single-field accessors ───────────────────────────────────────────────────

@test "detect_get_field os.id returns a non-empty string in the container" {
    _load_detect
    run detect_get_field os.id
    assert_success
    [[ -n "${output}" ]]
}

@test "detect_get_field arch matches uname -m" {
    _load_detect
    local _expected
    _expected="$(uname -m)"
    run detect_get_field arch
    assert_success
    [[ "${output}" == "${_expected}" ]]
}

@test "detect_get_field wsl is true|false (not unset)" {
    _load_detect
    run detect_get_field wsl
    assert_success
    [[ "${output}" == "true" || "${output}" == "false" ]]
}

@test "detect_get_field rejects unknown field with exit 1" {
    _load_detect
    run detect_get_field bogus.path
    assert_failure
}

@test "in test-tools container, board is empty (no SBC marker)" {
    _load_detect
    run detect_get_field board
    assert_success
    [[ -z "${output}" ]]
}

@test "detect_environment is idempotent (same JSON across two calls)" {
    _load_detect
    local _a _b
    _a="$(detect_environment)"
    _b="$(detect_environment)"
    [[ "${_a}" == "${_b}" ]]
}
