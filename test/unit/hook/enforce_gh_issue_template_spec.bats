#!/usr/bin/env bats
# test/unit/hook/enforce_gh_issue_template_spec.bats
#
# Tests for the enforce_gh_issue_template.sh hook. The hook denies a
# `gh issue create` whose --body-file omits a REQUIRED section of the
# matching .github/ISSUE_TEMPLATE/<kind>.yaml form. Required sections are
# parsed from the real form files, so these tests run against the actual
# templates (CLAUDE_PROJECT_DIR=REPO_ROOT).
#
# Driven as a subprocess (stdin JSON -> stdout deny JSON or empty), the same
# way Claude Code invokes a PreToolUse hook.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    HOOK_SH="${REPO_ROOT}/.claude/hook/enforce_gh_issue_template.sh"
    BODY_DIR="${BATS_TEST_TMPDIR}/bodies"
    mkdir -p "${BODY_DIR}"
}

teardown() {
    teardown_test_env
}

# Write a body fixture, echo its path.
_body() {
    local name="$1" content="$2"
    local p="${BODY_DIR}/${name}.md"
    printf '%s' "${content}" > "${p}"
    printf '%s' "${p}"
}

# Build the PreToolUse Bash JSON for a gh issue create command.
_cmd_json() {
    local title="$1" body_file="$2"
    local cmd="gh issue create --title \"${title}\" --body-file ${body_file} --label bug"
    jq -n --arg c "${cmd}" '{tool_name:"Bash", tool_input:{command:$c}}'
}

_run_hook() {
    run bash -c "printf '%s' \"\$1\" | CLAUDE_PROJECT_DIR='${REPO_ROOT}' '${HOOK_SH}'" _ "$1"
}

@test "bug: all required sections present -> allow (empty stdout)" {
    local body input
    body="$(_body bug-ok '## What happened?
It broke.
## Expected behavior
It should not.
## Steps to reproduce
1. run it')"
    input="$(_cmd_json 'fix: boom' "${body}")"
    _run_hook "${input}"
    assert_success
    assert_output ""
}

@test "bug: missing 'Steps to reproduce' -> deny naming it" {
    local body input
    body="$(_body bug-missing '## What happened?
It broke.
## Expected behavior
It should not.')"
    input="$(_cmd_json 'fix: boom' "${body}")"
    _run_hook "${input}"
    assert_success
    assert_output --partial '"permissionDecision": "deny"'
    assert_output --partial 'Steps to reproduce'
}

@test "bug: heading present but empty -> deny as empty" {
    local body input
    body="$(_body bug-empty '## What happened?
It broke.
## Expected behavior

## Steps to reproduce
1. run it')"
    input="$(_cmd_json 'fix: boom' "${body}")"
    _run_hook "${input}"
    assert_success
    assert_output --partial '"permissionDecision": "deny"'
    assert_output --partial 'Expected behavior'
    assert_output --partial 'empty'
}

@test "bug: literal _No response_ counts as empty -> deny" {
    local body input
    body="$(_body bug-noresp '## What happened?
It broke.
## Expected behavior
It should not.
## Steps to reproduce
_No response_')"
    input="$(_cmd_json 'fix: boom' "${body}")"
    _run_hook "${input}"
    assert_success
    assert_output --partial '"permissionDecision": "deny"'
    assert_output --partial 'Steps to reproduce'
}

@test "bug: '### ' (h3) headings also accepted -> allow" {
    local body input
    body="$(_body bug-h3 '### What happened?
It broke.
### Expected behavior
It should not.
### Steps to reproduce
1. run it')"
    input="$(_cmd_json 'fix: boom' "${body}")"
    _run_hook "${input}"
    assert_success
    assert_output ""
}

@test "scoped prefix fix(scope): maps to bug template -> deny when incomplete" {
    local body input
    body="$(_body scoped '## What happened?
only this')"
    input="$(_cmd_json 'fix(claude-ls): boom' "${body}")"
    _run_hook "${input}"
    assert_success
    assert_output --partial '"permissionDecision": "deny"'
}

@test "feature: complete body -> allow" {
    local body input
    body="$(_body feat-ok '## What to build
A flag.
## Acceptance criteria
- [ ] works')"
    input="$(_cmd_json 'feat: add flag' "${body}")"
    _run_hook "${input}"
    assert_success
    assert_output ""
}

@test "task: missing Acceptance criteria -> deny" {
    local body input
    body="$(_body task-missing '## What needs to be done
Refactor the thing.')"
    input="$(_cmd_json 'refactor: split module' "${body}")"
    _run_hook "${input}"
    assert_success
    assert_output --partial '"permissionDecision": "deny"'
    assert_output --partial 'Acceptance criteria'
}

@test "docs: complete body -> allow" {
    local body input
    body="$(_body docs-ok '## What is wrong or missing
The README lies.
## Where
README.md, Install section')"
    input="$(_cmd_json 'docs: fix readme' "${body}")"
    _run_hook "${input}"
    assert_success
    assert_output ""
}

@test "unrecognized title prefix -> allow (no template enforced)" {
    local body input
    body="$(_body noprefix 'nothing structured here')"
    input="$(_cmd_json 'random freeform title' "${body}")"
    _run_hook "${input}"
    assert_success
    assert_output ""
}

@test "non issue-create (pr create) -> allow silently" {
    local input
    input="$(jq -n '{tool_name:"Bash", tool_input:{command:"gh pr create --title \"feat: x\" --body-file /tmp/x.md"}}')"
    _run_hook "${input}"
    assert_success
    assert_output ""
}

@test "issue create without --body-file -> allow (body-file hook owns that)" {
    local input
    input="$(jq -n '{tool_name:"Bash", tool_input:{command:"gh issue create --title \"fix: x\" --label bug"}}')"
    _run_hook "${input}"
    assert_success
    assert_output ""
}

@test "non-Bash / empty command -> allow silently" {
    local input
    input="$(jq -n '{tool_name:"Bash", tool_input:{command:""}}')"
    _run_hook "${input}"
    assert_success
    assert_output ""
}
