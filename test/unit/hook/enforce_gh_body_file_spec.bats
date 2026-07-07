#!/usr/bin/env bats
# test/unit/hook/enforce_gh_body_file_spec.bats
#
# Tests for enforce_gh_body_file.sh (issue #64/#91): gh issue/pr creation +
# comment must go through --body-file (real path) and issue create must carry
# a --label; violations are DENIED (permissionDecision:"deny", exit 0).
# Canonical forms + unrelated subcommands pass through silently.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    HOOK_SH="${REPO_ROOT}/.claude/hook/enforce_gh_body_file.sh"
}

teardown() { teardown_test_env; }

_json() { jq -n --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}'; }

_run_hook() {
    run bash -c 'printf "%s" "$1" | "$2"' _ "$(_json "$1")" "${HOOK_SH}"
}

# ── denied: missing body-file / label / bad body sourcing ────────────────────

@test "denies 'gh issue create' without --body-file" {
    _run_hook "gh issue create --title 'x' --label bug"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"deny"* ]]
    [[ "${output}" == *"body-file"* ]]
}

@test "denies 'gh pr create' without --body-file" {
    _run_hook "gh pr create --title 'x'"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"deny"* ]]
    [[ "${output}" == *"body-file"* ]]
}

@test "denies 'gh issue create' with body-file but no --label" {
    _run_hook "gh issue create --title 'x' --body-file /tmp/b.md"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"deny"* ]]
    [[ "${output}" == *"label"* ]]
}

@test "denies a --body \"\$(cat ...)\" substitution" {
    # Assemble the '$' separately so ShellCheck does not read a live expansion
    # (SC2016); the runtime string still carries the literal '$(cat ...)'.
    local d='$'
    _run_hook "gh issue comment 5 --body \"${d}(cat /tmp/b.md)\""
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"deny"* ]]
}

@test "denies a multi-line inline pr comment body" {
    _run_hook "$(printf 'gh pr comment 3 --body "line one\nline two"')"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"deny"* ]]
}

# ── allowed: canonical forms + out-of-scope subcommands ──────────────────────

@test "allows 'gh issue create' with real body-file and label" {
    _run_hook "gh issue create --title 'x' --body-file /tmp/b.md --label enhancement"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "allows 'gh pr create' with real body-file" {
    _run_hook "gh pr create --title 'x' --body-file /tmp/b.md"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "allows a short single-line inline pr comment (<= 80 chars)" {
    _run_hook "gh pr comment 3 --body 'looks good, merging'"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "allows an out-of-scope subcommand (gh pr view)" {
    _run_hook "gh pr view 3"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "allows a non-gh command" {
    _run_hook "git status"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}
