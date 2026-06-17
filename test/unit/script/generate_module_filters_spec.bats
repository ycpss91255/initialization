#!/usr/bin/env bats
# test/unit/script/generate_module_filters_spec.bats
#
# Tests for `script/ci/generate_module_filters.sh` (issue #31, PRD M10):
# the dorny/paths-filter YAML generator behind the per-module CI matrix.
#
# Strategy: point INIT_UBUNTU_MODULE_DIR at a fixture dir with a known
# set of *.module.sh files and assert on the emitted filter blocks.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    SCRIPT="${REPO_ROOT}/script/ci/generate_module_filters.sh"
    FIXTURE_MODULE_DIR="${BATS_TEST_TMPDIR}/module"
    mkdir -p "${FIXTURE_MODULE_DIR}"
}

teardown() {
    teardown_test_env
}

_make_module() {
    touch "${FIXTURE_MODULE_DIR}/$1.module.sh"
}

@test "emits static shared and core filters" {
    _make_module alpha
    INIT_UBUNTU_MODULE_DIR="${FIXTURE_MODULE_DIR}" run "${SCRIPT}"
    assert_success
    assert_line "shared:"
    assert_line "  - 'lib/**'"
    assert_line "  - 'script/**'"
    assert_line "  - 'justfile'"
    assert_line "  - 'justfile.ci'"
    assert_line "  - '.github/workflows/**'"
    assert_line "core:"
    assert_line "  - 'test/unit/*.bats'"
    assert_line "  - 'test/unit/hook/**'"
    assert_line "  - 'test/unit/script/**'"
    assert_line "  - 'template/**'"
}

@test "emits one filter per module with script + spec paths" {
    _make_module alpha
    _make_module beta-tool
    INIT_UBUNTU_MODULE_DIR="${FIXTURE_MODULE_DIR}" run "${SCRIPT}"
    assert_success
    assert_line "module-alpha:"
    assert_line "  - 'module/alpha.module.sh'"
    assert_line "  - 'test/unit/module/alpha_spec.bats'"
    assert_line "module-beta-tool:"
    assert_line "  - 'module/beta-tool.module.sh'"
    assert_line "  - 'test/unit/module/beta-tool_spec.bats'"
}

@test "ignores non-module files in the module dir" {
    _make_module alpha
    touch "${FIXTURE_MODULE_DIR}/setup_legacy.sh"
    touch "${FIXTURE_MODULE_DIR}/helper.bash"
    INIT_UBUNTU_MODULE_DIR="${FIXTURE_MODULE_DIR}" run "${SCRIPT}"
    assert_success
    refute_output --partial "setup_legacy"
    refute_output --partial "module-helper"
}

@test "empty module dir still emits shared + core" {
    INIT_UBUNTU_MODULE_DIR="${FIXTURE_MODULE_DIR}" run "${SCRIPT}"
    assert_success
    assert_line "shared:"
    assert_line "core:"
    refute_output --partial "module-"
}

@test "module output order is deterministic (sorted)" {
    _make_module zeta
    _make_module alpha
    _make_module mid
    INIT_UBUNTU_MODULE_DIR="${FIXTURE_MODULE_DIR}" run "${SCRIPT}"
    assert_success
    local _filtered
    _filtered="$(printf '%s\n' "${output}" | grep '^module-')"
    [ "${_filtered}" = "$(printf 'module-alpha:\nmodule-mid:\nmodule-zeta:')" ]
}

@test "real repo: every module/*.module.sh gets a filter" {
    run "${SCRIPT}"
    assert_success
    local _f _name
    for _f in "${MODULE_DIR}"/*.module.sh; do
        _name="$(basename "${_f}" .module.sh)"
        assert_line "module-${_name}:"
    done
}
