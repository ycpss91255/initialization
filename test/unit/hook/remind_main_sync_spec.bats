#!/usr/bin/env bats
# test/unit/hook/remind_main_sync_spec.bats
#
# Tests for remind_main_sync.sh (PreToolUse Bash). Advisory-only: fires on an
# actual `gh pr merge` subcommand, emitting a systemMessage reminding to
# ff-pull local main, with a queued vs immediate variant. Never blocks (exit
# 0). A `gh pr merge` substring inside a quoted string must NOT trigger it.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    HOOK_SH="${REPO_ROOT}/.claude/hook/remind_main_sync.sh"
}

teardown() { teardown_test_env; }

_json() { jq -n --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}'; }

_run_hook() {
    run bash -c 'printf "%s" "$1" | "$2"' _ "$(_json "$1")" "${HOOK_SH}"
}

# ── fires: real gh pr merge ──────────────────────────────────────────────────

@test "gh pr merge --auto -> queued variant reminder" {
    _run_hook "gh pr merge --auto --squash 42"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"variant=queued"* ]]
    [[ "${output}" == *"pull --ff-only"* ]]
}

@test "gh pr merge --squash (no --auto) -> immediate variant reminder" {
    _run_hook "gh pr merge --squash 42"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"variant=immediate"* ]]
    [[ "${output}" == *"pull --ff-only"* ]]
}

@test "gh pr merge at a command boundary after && still fires" {
    _run_hook "gh pr checks 42 && gh pr merge --rebase 42"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"pull --ff-only"* ]]
}

# ── silent: no real merge subcommand ─────────────────────────────────────────

@test "gh pr view -> silent (no reminder)" {
    _run_hook "gh pr view 42"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "commit message containing 'gh pr merge' does NOT trigger (quoted)" {
    _run_hook "git commit -m 'note: run gh pr merge after CI'"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "empty command -> silent" {
    _run_hook ""
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}
