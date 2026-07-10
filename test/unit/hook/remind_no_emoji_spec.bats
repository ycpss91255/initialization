#!/usr/bin/env bats
# test/unit/hook/remind_no_emoji_spec.bats
#
# Tests for remind_no_emoji.sh (UserPromptSubmit). Advisory-only: it always
# injects hookSpecificOutput.additionalContext with the no-emoji standing rule
# and never blocks (exit 0). The stdin prompt payload is ignored.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    HOOK_SH="${REPO_ROOT}/.claude/hook/remind_no_emoji.sh"
}

teardown() { teardown_test_env; }

# Feed an arbitrary UserPromptSubmit payload on stdin.
_run_hook() {
    run bash -c 'printf "%s" "$1" | "$2"' _ "$1" "${HOOK_SH}"
}

@test "injects the no-emoji reminder as additionalContext" {
    _run_hook '{"prompt":"do something"}'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"additionalContext"* ]]
    [[ "${output}" == *"NEVER use emoji"* ]]
    [[ "${output}" == *"UserPromptSubmit"* ]]
}

@test "reminder fires even for an empty prompt payload" {
    _run_hook ""
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"NEVER use emoji"* ]]
}

@test "never emits a permission decision (advisory only, never blocks)" {
    _run_hook '{"prompt":"x"}'
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"permissionDecision"* ]]
}
