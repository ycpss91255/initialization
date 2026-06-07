#!/usr/bin/env bats
# test/unit/script/select_unit_matrix_spec.bats
#
# Tests for `script/ci/select_unit_matrix.sh` (issue #31, PRD M10): the
# discover-job helper that decides which test-unit matrix shards (and
# whether the core job) a CI run needs.
#
# Strategy: fixture module dir with two modules (alpha, beta) via
# INIT_UBUNTU_MODULE_DIR; drive --event/--changed combinations and
# assert on the emitted GITHUB_OUTPUT lines.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    SCRIPT="${REPO_ROOT}/script/ci/select_unit_matrix.sh"
    FIXTURE_MODULE_DIR="${BATS_TEST_TMPDIR}/module"
    mkdir -p "${FIXTURE_MODULE_DIR}"
    touch "${FIXTURE_MODULE_DIR}/alpha.module.sh"
    touch "${FIXTURE_MODULE_DIR}/beta.module.sh"
    export INIT_UBUNTU_MODULE_DIR="${FIXTURE_MODULE_DIR}"
}

teardown() {
    teardown_test_env
}

@test "push event runs the full matrix + core" {
    run "${SCRIPT}" --event push --changed '[]'
    assert_success
    assert_line 'modules=["alpha","beta"]'
    assert_line 'core=true'
    assert_line 'full=true'
}

@test "push event ignores narrower filter matches" {
    run "${SCRIPT}" --event push --changed '["module-alpha"]'
    assert_success
    assert_line 'modules=["alpha","beta"]'
    assert_line 'core=true'
    assert_line 'full=true'
}

@test "shared filter match fans out to full matrix + core" {
    run "${SCRIPT}" --event pull_request --changed '["shared","module-alpha"]'
    assert_success
    assert_line 'modules=["alpha","beta"]'
    assert_line 'core=true'
    assert_line 'full=true'
}

@test "single module match runs only that shard, no core" {
    run "${SCRIPT}" --event pull_request --changed '["module-alpha"]'
    assert_success
    assert_line 'modules=["alpha"]'
    assert_line 'core=false'
    assert_line 'full=false'
}

@test "module + core match runs that shard and core" {
    run "${SCRIPT}" --event pull_request --changed '["module-beta","core"]'
    assert_success
    assert_line 'modules=["beta"]'
    assert_line 'core=true'
    assert_line 'full=false'
}

@test "core-only match emits empty matrix + core" {
    run "${SCRIPT}" --event pull_request --changed '["core"]'
    assert_success
    assert_line 'modules=[]'
    assert_line 'core=true'
    assert_line 'full=false'
}

@test "no relevant filter match falls back to full matrix + core" {
    # A code change outside every known filter (e.g. a root-level
    # script) must not silently skip unit tests.
    run "${SCRIPT}" --event pull_request --changed '[]'
    assert_success
    assert_line 'modules=["alpha","beta"]'
    assert_line 'core=true'
    assert_line 'full=true'
}

@test "unknown filter names alone also trigger the fallback" {
    run "${SCRIPT}" --event pull_request --changed '["something-else"]'
    assert_success
    assert_line 'modules=["alpha","beta"]'
    assert_line 'core=true'
    assert_line 'full=true'
}

@test "PR whose matched filters cover every module + core reports full=true" {
    # Rule 4 can coincidentally select the complete cartesian — the
    # coverage gate must then enforce (full=true), not stay report-only.
    run "${SCRIPT}" --event pull_request \
        --changed '["module-alpha","module-beta","core"]'
    assert_success
    assert_line 'modules=["alpha","beta"]'
    assert_line 'core=true'
    assert_line 'full=true'
}

@test "module filter for a nonexistent module is dropped by intersection" {
    run "${SCRIPT}" --event pull_request --changed '["module-ghost","module-alpha"]'
    assert_success
    assert_line 'modules=["alpha"]'
    assert_line 'core=false'
}

@test "matrix output is sorted regardless of input order" {
    run "${SCRIPT}" --event pull_request --changed '["module-beta","module-alpha"]'
    assert_success
    assert_line 'modules=["alpha","beta"]'
}

@test "missing --event fails" {
    run "${SCRIPT}" --changed '[]'
    assert_failure
    assert_output --partial "--event is required"
}

@test "non-array --changed fails" {
    run "${SCRIPT}" --event pull_request --changed 'not-json'
    assert_failure
    assert_output --partial "must be a JSON array"
}
