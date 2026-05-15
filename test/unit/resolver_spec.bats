#!/usr/bin/env bats
# test/unit/resolver_spec.bats — lib/resolver.sh (Kahn topo sort + cycle detect)

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false

    FAKE_MODULE_DIR="${INIT_UBUNTU_TEST_SCRATCH}/module"
    mkdir -p "${FAKE_MODULE_DIR}"
}

teardown() {
    teardown_test_env
}

# Helper to write a minimal module fixture.
_make_mod() {
    local _name="$1"
    local _deps="$2"  # space-separated quoted list, e.g. '"a" "b"'
    cat > "${FAKE_MODULE_DIR}/${_name}.module.sh" <<EOF
NAME="${_name}"
CATEGORY="optional"
TAGS=()
SUPPORTED_UBUNTU=()
SUPPORTED_PLATFORMS=()
DEPENDS_ON=(${_deps})
CONFLICTS_WITH=()
EOF
}

@test "linear chain: install c pulls a then b then c" {
    _make_mod "a" ""
    _make_mod "b" '"a"'
    _make_mod "c" '"b"'
    source "${LIB_DIR}/registry.sh"
    source "${LIB_DIR}/resolver.sh"
    registry_load_all "${FAKE_MODULE_DIR}"

    run resolver_resolve c
    assert_success
    [[ "${lines[0]}" == "a" ]]
    [[ "${lines[1]}" == "b" ]]
    [[ "${lines[2]}" == "c" ]]
}

@test "diamond: bottom first, left/right alpha-sorted, top last" {
    _make_mod "bottom" ""
    _make_mod "left"   '"bottom"'
    _make_mod "right"  '"bottom"'
    _make_mod "top"    '"left" "right"'
    source "${LIB_DIR}/registry.sh"
    source "${LIB_DIR}/resolver.sh"
    registry_load_all "${FAKE_MODULE_DIR}"

    run resolver_resolve top
    assert_success
    [[ "${lines[0]}" == "bottom" ]]
    [[ "${lines[1]}" == "left" ]]
    [[ "${lines[2]}" == "right" ]]
    [[ "${lines[3]}" == "top" ]]
}

@test "no-dep module: order is just the module itself" {
    _make_mod "solo" ""
    source "${LIB_DIR}/registry.sh"
    source "${LIB_DIR}/resolver.sh"
    registry_load_all "${FAKE_MODULE_DIR}"

    run resolver_resolve solo
    assert_success
    [[ "${output}" == "solo" ]]
}

@test "unknown module returns exit 2" {
    source "${LIB_DIR}/registry.sh"
    source "${LIB_DIR}/resolver.sh"
    registry_load_all "${FAKE_MODULE_DIR}"

    run resolver_resolve nonexistent
    assert_failure 2
}

@test "direct cycle returns exit 5" {
    _make_mod "a" '"b"'
    _make_mod "b" '"a"'
    source "${LIB_DIR}/registry.sh"
    source "${LIB_DIR}/resolver.sh"
    registry_load_all "${FAKE_MODULE_DIR}"

    run resolver_resolve a
    assert_failure 5
}

@test "indirect cycle returns exit 5" {
    _make_mod "a" '"b"'
    _make_mod "b" '"c"'
    _make_mod "c" '"a"'
    source "${LIB_DIR}/registry.sh"
    source "${LIB_DIR}/resolver.sh"
    registry_load_all "${FAKE_MODULE_DIR}"

    run resolver_resolve a
    assert_failure 5
}

@test "multiple requested with shared dep: shared dep emitted once, at the start" {
    _make_mod "shared" ""
    _make_mod "x"      '"shared"'
    _make_mod "y"      '"shared"'
    source "${LIB_DIR}/registry.sh"
    source "${LIB_DIR}/resolver.sh"
    registry_load_all "${FAKE_MODULE_DIR}"

    run resolver_resolve x y
    assert_success
    [[ "${lines[0]}" == "shared" ]]
    [[ "${#lines[@]}" -eq 3 ]]
}

@test "empty input returns success with empty output" {
    source "${LIB_DIR}/registry.sh"
    source "${LIB_DIR}/resolver.sh"
    registry_load_all "${FAKE_MODULE_DIR}"

    run resolver_resolve
    assert_success
    assert_output ""
}

@test "resolver_collect_transitive returns all reachable deps (unsorted)" {
    _make_mod "a" ""
    _make_mod "b" '"a"'
    _make_mod "c" '"b"'
    source "${LIB_DIR}/registry.sh"
    source "${LIB_DIR}/resolver.sh"
    registry_load_all "${FAKE_MODULE_DIR}"

    run resolver_collect_transitive c
    assert_success
    assert_output --partial "a"
    assert_output --partial "b"
    assert_output --partial "c"
}
