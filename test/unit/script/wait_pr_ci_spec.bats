#!/usr/bin/env bats
# test/unit/script/wait_pr_ci_spec.bats
#
# Tests for `.claude/script/wait-pr-ci.sh` watch-start / stale-window
# guards (issue #22).
#
# Strategy: PATH-stub `gh` to return a canned `gh pr view --json …`
# response, then drive the script with --max-iterations 1 --interval 0
# so the polling loop runs exactly once.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    SCRIPT="${REPO_ROOT}/.claude/script/wait-pr-ci.sh"
    STUB_DIR="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${STUB_DIR}"
    FIXTURE_JSON="${BATS_TEST_TMPDIR}/gh-response.json"

    # PATH-stub gh: ignore args, print whatever FIXTURE_JSON contains.
    cat > "${STUB_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
cat "${FIXTURE_JSON}"
EOF
    chmod +x "${STUB_DIR}/gh"
    export PATH="${STUB_DIR}:${PATH}"
    export FIXTURE_JSON
}

teardown() {
    teardown_test_env
}

# Write a gh pr view --json response with a single completed SUCCESS
# check whose completedAt is <seconds_before_now> seconds before the
# current wall-clock (which is what `watch_start` captures).
_write_fixture_completed_seconds_ago() {
    local seconds_before_now="$1"
    local completed_at
    completed_at="$(date -u -d "@$(($(date -u +%s) - seconds_before_now))" +%Y-%m-%dT%H:%M:%SZ)"
    cat > "${FIXTURE_JSON}" <<EOF
{
  "mergeable": "MERGEABLE",
  "headRefOid": "abc1234deadbeef",
  "statusCheckRollup": [
    {
      "__typename": "CheckRun",
      "name": "ci-passed",
      "status": "COMPLETED",
      "conclusion": "SUCCESS",
      "completedAt": "${completed_at}",
      "startedAt": "${completed_at}"
    }
  ]
}
EOF
}

# ── Bug case (issue #22): post-completion launch ────────────────────────────
# Check completed long before the script's watch_start; current behaviour
# (pre-fix) demotes to "pending" forever — script never emits ALL_DONE.

@test "wait-pr-ci: check completed 1 hour before watch_start -> ALL_DONE (issue #22)" {
    _write_fixture_completed_seconds_ago 3600

    run "${SCRIPT}" \
        --repo owner/repo \
        --prs 21 \
        --check-filter '.name=="ci-passed"' \
        --max-iterations 1 \
        --interval 0

    assert_success
    assert_output --partial "PR21: checks=all-pass mergeable=MERGEABLE"
    assert_output --partial "ALL_DONE"
}

# ── Force-push race coverage preserved ──────────────────────────────────────
# Check completed seconds before watch_start (still inside the stale-rollup
# window) -> should remain demoted to "pending" so we don't trust the
# carry-over results from the previous head.

@test "wait-pr-ci: check completed 10s before watch_start -> pending (force-push race guard)" {
    _write_fixture_completed_seconds_ago 10

    run "${SCRIPT}" \
        --repo owner/repo \
        --prs 21 \
        --check-filter '.name=="ci-passed"' \
        --max-iterations 1 \
        --interval 0

    # exit 124 = max-iterations reached without ALL_DONE -> still pending
    assert_failure 124
    assert_output --partial "PR21: checks=pending mergeable=MERGEABLE"
    refute_output --partial "ALL_DONE"
}

# ── Boundary: check completed just past STALE_WINDOW (120s) ─────────────────

@test "wait-pr-ci: check completed 121s before watch_start -> ALL_DONE (past stale window)" {
    _write_fixture_completed_seconds_ago 121

    run "${SCRIPT}" \
        --repo owner/repo \
        --prs 21 \
        --check-filter '.name=="ci-passed"' \
        --max-iterations 1 \
        --interval 0

    assert_success
    assert_output --partial "ALL_DONE"
}
