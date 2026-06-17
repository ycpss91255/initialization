#!/usr/bin/env bats
# test/unit/script/auto_merge_on_green_spec.bats
#
# Tests for `.claude/script/auto-merge-on-green.sh` (issue #154).
#
# Strategy: PATH-stub `gh` so `gh pr view ...` prints a canned JSON fixture
# and every other `gh` subcommand (merge / update-branch) is a no-op. Drive
# the script with --no-arm --interval 0 --max-iterations 1 so the poll loop
# runs deterministically once. A separate stub captures `gh pr update-branch`
# / `gh pr merge` invocations to assert the side effects.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    SCRIPT="${REPO_ROOT}/.claude/script/auto-merge-on-green.sh"
    STUB_DIR="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${STUB_DIR}"
    FIXTURE_JSON="${BATS_TEST_TMPDIR}/gh-view.json"
    GH_LOG="${BATS_TEST_TMPDIR}/gh-calls.log"
    export FIXTURE_JSON GH_LOG

    # `gh pr view ...` -> fixture; other subcommands -> logged no-op.
    cat > "${STUB_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_LOG}"
if [[ "$2" == "view" ]]; then cat "${FIXTURE_JSON}"; fi
exit 0
EOF
    chmod +x "${STUB_DIR}/gh"
    export PATH="${STUB_DIR}:${PATH}"
}

teardown() {
    teardown_test_env
}

_fixture() { printf '%s' "$1" > "${FIXTURE_JSON}"; }

@test "arg validation: missing --repo -> exit 2" {
    run "${SCRIPT}" --pr 1
    assert_failure 2
    assert_output --partial "--repo is required"
}

@test "arg validation: non-numeric --pr -> exit 2" {
    run "${SCRIPT}" --repo o/r --pr abc
    assert_failure 2
    assert_output --partial "--pr must be a number"
}

@test "MERGED -> exit 0 with MERGED line" {
    _fixture '{"state":"MERGED","mergeStateStatus":"CLEAN","statusCheckRollup":[{"name":"ci-passed","status":"COMPLETED","conclusion":"SUCCESS"}]}'
    run "${SCRIPT}" --repo o/r --pr 1 --no-arm --interval 0 --max-iterations 1
    assert_success
    assert_output --partial "PR1: state=MERGED merge=CLEAN ci=pass"
    assert_output --partial "MERGED"
}

@test "required check FAILURE while BLOCKED -> FAIL exit 1" {
    _fixture '{"state":"OPEN","mergeStateStatus":"BLOCKED","statusCheckRollup":[{"name":"ci-passed","status":"COMPLETED","conclusion":"FAILURE"}]}'
    run "${SCRIPT}" --repo o/r --pr 1 --no-arm --interval 0 --max-iterations 1
    assert_failure 1
    assert_output --partial "ci=fail"
    assert_output --partial "FAIL check"
}

@test "merge conflict DIRTY -> FAIL exit 1 with rebase hint" {
    _fixture '{"state":"OPEN","mergeStateStatus":"DIRTY","statusCheckRollup":[]}'
    run "${SCRIPT}" --repo o/r --pr 1 --no-arm --interval 0 --max-iterations 1
    assert_failure 1
    assert_output --partial "FAIL conflict"
}

@test "closed unmerged -> FAIL exit 1" {
    _fixture '{"state":"CLOSED","mergeStateStatus":"UNKNOWN","statusCheckRollup":[]}'
    run "${SCRIPT}" --repo o/r --pr 1 --no-arm --interval 0 --max-iterations 1
    assert_failure 1
    assert_output --partial "FAIL closed-unmerged"
}

@test "BEHIND -> runs gh pr update-branch, stays pending" {
    _fixture '{"state":"OPEN","mergeStateStatus":"BEHIND","statusCheckRollup":[{"name":"ci-passed","status":"COMPLETED","conclusion":"SUCCESS"}]}'
    run "${SCRIPT}" --repo o/r --pr 7 --no-arm --interval 0 --max-iterations 1
    assert_failure 124
    assert_output --partial "merge=BEHIND"
    run grep -q "pr update-branch 7" "${GH_LOG}"
    assert_success
}

@test "pending check still running -> keeps polling (max-iter 124)" {
    _fixture '{"state":"OPEN","mergeStateStatus":"BLOCKED","statusCheckRollup":[{"name":"ci-passed","status":"IN_PROGRESS","conclusion":null}]}'
    run "${SCRIPT}" --repo o/r --pr 1 --no-arm --interval 0 --max-iterations 2
    assert_failure 124
    assert_output --partial "ci=pending"
}

@test "BLOCKED with no pending/failed check past grace -> FAIL blocked" {
    _fixture '{"state":"OPEN","mergeStateStatus":"BLOCKED","statusCheckRollup":[]}'
    run "${SCRIPT}" --repo o/r --pr 1 --no-arm --interval 0 --grace 0 --max-iterations 3
    # grace 0 disables the bail, so it spins to max-iter; assert it did NOT
    # falsely declare merged/failed.
    assert_failure 124
    assert_output --partial "ci=none"
}

@test "no PR (empty gh view) -> FAIL exit 1" {
    _fixture ''
    run "${SCRIPT}" --repo o/r --pr 1 --no-arm --interval 0 --max-iterations 1
    assert_failure 1
    assert_output --partial "cannot read PR 1"
}

@test "arm step runs gh pr merge --auto --squash --delete-branch" {
    _fixture '{"state":"MERGED","mergeStateStatus":"CLEAN","statusCheckRollup":[{"name":"ci-passed","status":"COMPLETED","conclusion":"SUCCESS"}]}'
    run "${SCRIPT}" --repo o/r --pr 9 --interval 0 --max-iterations 1
    assert_success
    run grep -qE "pr merge 9 --repo o/r --auto --squash --delete-branch" "${GH_LOG}"
    assert_success
}
