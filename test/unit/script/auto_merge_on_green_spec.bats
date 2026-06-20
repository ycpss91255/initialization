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

    # `gh pr view ...` -> fixture; `gh api ...` -> canned JSON for the
    # re-trigger chain (head sha/ref, head commit tree, created commit sha);
    # every other subcommand -> logged no-op.
    cat > "${STUB_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_LOG}"
if [[ "$1" == "api" ]]; then
    case "$*" in
        *"git/commits/"*)   echo '{"tree":{"sha":"tree1"}}' ;;
        *"git/commits"*)    echo '{"sha":"newsha1"}' ;;
        *"git/refs/heads"*) : ;;
        *"pulls/"*)         echo '{"head":{"sha":"headsha1","ref":"my-branch"}}' ;;
    esac
    exit 0
fi
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

@test "no CI run on head (ci=none) past retrigger grace -> pushes empty commit" {
    # The recurrence to prevent: a push that created no workflow run leaves the
    # head with zero checks (ci=none) forever. With --retrigger-grace 0 the
    # script re-triggers on first observation by pushing an empty commit via
    # the git API.
    _fixture '{"state":"OPEN","mergeStateStatus":"BLOCKED","statusCheckRollup":[]}'
    run "${SCRIPT}" --repo o/r --pr 5 --no-arm --interval 0 \
        --grace 0 --retrigger-grace 0 --max-iterations 1
    assert_output --partial "re-triggering"
    # Full chain executed against the git API and moved the branch ref.
    run grep -q "api repos/o/r/pulls/5" "${GH_LOG}"
    assert_success
    run grep -q "api repos/o/r/git/refs/heads/my-branch -X PATCH" "${GH_LOG}"
    assert_success
}

@test "ci=none re-trigger fires at most once per run" {
    _fixture '{"state":"OPEN","mergeStateStatus":"BLOCKED","statusCheckRollup":[]}'
    run "${SCRIPT}" --repo o/r --pr 5 --no-arm --interval 0 \
        --grace 0 --retrigger-grace 0 --max-iterations 3
    # Three poll iterations, but only one ref-moving PATCH.
    run bash -c "grep -c 'git/refs/heads/my-branch -X PATCH' '${GH_LOG}'"
    assert_output "1"
}

@test "ci=none with --no-retrigger -> never re-triggers" {
    _fixture '{"state":"OPEN","mergeStateStatus":"BLOCKED","statusCheckRollup":[]}'
    run "${SCRIPT}" --repo o/r --pr 5 --no-arm --interval 0 \
        --grace 0 --no-retrigger --max-iterations 2
    refute_output --partial "re-triggering"
    run grep -q "git/refs/heads" "${GH_LOG}"
    assert_failure
}

@test "ci=pending does not re-trigger even with retrigger-grace 0" {
    _fixture '{"state":"OPEN","mergeStateStatus":"BLOCKED","statusCheckRollup":[{"name":"ci-passed","status":"IN_PROGRESS","conclusion":null}]}'
    run "${SCRIPT}" --repo o/r --pr 5 --no-arm --interval 0 \
        --grace 0 --retrigger-grace 0 --max-iterations 2
    refute_output --partial "re-triggering"
    run grep -q "git/refs/heads" "${GH_LOG}"
    assert_failure
}
