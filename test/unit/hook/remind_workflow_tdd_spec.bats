#!/usr/bin/env bats
# test/unit/hook/remind_workflow_tdd_spec.bats
#
# Tests for remind_workflow_tdd.sh (UserPromptSubmit). Advisory-only: it always
# injects hookSpecificOutput.additionalContext with the Workflow + TDD +
# dual-watch standing directive and never blocks (exit 0). Stdin is ignored.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    HOOK_SH="${REPO_ROOT}/.claude/hook/remind_workflow_tdd.sh"
}

teardown() { teardown_test_env; }

_run_hook() {
    run bash -c 'printf "%s" "$1" | "$2"' _ "$1" "${HOOK_SH}"
}

@test "injects the Workflow + TDD directive as additionalContext" {
    _run_hook '{"prompt":"build a feature"}'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"additionalContext"* ]]
    [[ "${output}" == *"Workflow tool"* ]]
    [[ "${output}" == *"TDD"* ]]
}

@test "directive mentions dual-watch integration" {
    _run_hook '{"prompt":"x"}'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"dual-watch"* ]]
}

@test "fires even for an empty payload and never blocks" {
    _run_hook ""
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Workflow tool"* ]]
    [[ "${output}" != *"permissionDecision"* ]]
}
