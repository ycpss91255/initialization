#!/usr/bin/env bats
# test/unit/hook/remind_ci_auto_merge_spec.bats
#
# Tests for the remind_ci_auto_merge.sh PreToolUse hook (issue #154).
# Driven as a subprocess (stdin JSON -> stdout additionalContext JSON or
# empty), the same way Claude Code invokes a PreToolUse hook.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    HOOK_SH="${REPO_ROOT}/.claude/hook/remind_ci_auto_merge.sh"
}

teardown() { teardown_test_env; }

_json() { jq -n --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}'; }

_run() {
    run bash -c "printf '%s' \"\$1\" | '${HOOK_SH}'" _ "$(_json "$1")"
}

@test "gh pr create -> instructs auto-merge-on-green skill" {
    _run 'gh pr create --title x --body-file /tmp/b --label bug'
    assert_success
    assert_output --partial '"additionalContext"'
    assert_output --partial 'auto-merge-on-green'
}

@test "git push tag -> instructs release CI monitoring, no merge" {
    _run 'git push origin v1.2.3'
    assert_success
    assert_output --partial 'wait-tag-ci.sh'
    assert_output --partial 'release CI'
}

@test "git push --tags -> release CI monitoring branch" {
    _run 'git push --tags'
    assert_success
    assert_output --partial 'wait-tag-ci.sh'
}

@test "git push branch -> instructs PR-or-monitor decision" {
    _run 'git push -u origin feat/x'
    assert_success
    assert_output --partial 'auto-merge-on-green'
    assert_output --partial 'wait-pr-ci'
}

@test "unrelated command -> silent (no output)" {
    _run 'ls -la'
    assert_success
    assert_output ""
}

@test "empty command -> silent" {
    _run ''
    assert_success
    assert_output ""
}

@test "always allow (never emits a deny decision)" {
    _run 'gh pr create --title x --body-file /tmp/b'
    assert_success
    refute_output --partial '"permissionDecision"'
}
