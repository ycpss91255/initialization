#!/usr/bin/env bats
# test/unit/hooks/approval_check_spec.bats
#
# Unit tests for `is_disable_approved` in
# .claude/hook/enforce_shellcheck_disable_approval.sh (issue #17).
#
# Module contract:
#   - Args: $1 = SC<code>, $2 = user_msg_text
#   - Exit 0 if msg matches `\bapprove\b.*\bSC<code>\b`
#     (case-insensitive on the verb, exact case on the code)
#   - Exit 1 otherwise

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    HOOK_SH="${REPO_ROOT}/.claude/hook/enforce_shellcheck_disable_approval.sh"
    # shellcheck source=../../../.claude/hook/enforce_shellcheck_disable_approval.sh
    source "${HOOK_SH}"
}

teardown() {
    teardown_test_env
}

@test "is_disable_approved: 'approve SC2034' matches SC2034" {
    run is_disable_approved "SC2034" "approve SC2034"
    assert_success
}

@test "is_disable_approved: 'approve SC2034' does NOT match SC1091" {
    run is_disable_approved "SC1091" "approve SC2034"
    assert_failure
}

@test "is_disable_approved: capital 'Approve SC2034' matches (case-insensitive verb)" {
    run is_disable_approved "SC2034" "Approve SC2034"
    assert_success
}

@test "is_disable_approved: batch 'approve SC2034 SC1091' matches SC2034" {
    run is_disable_approved "SC2034" "approve SC2034 SC1091"
    assert_success
}

@test "is_disable_approved: batch 'approve SC2034 SC1091' matches SC1091" {
    run is_disable_approved "SC1091" "approve SC2034 SC1091"
    assert_success
}

@test "is_disable_approved: bare 'approve' (no code) does NOT match SC2034" {
    run is_disable_approved "SC2034" "approve"
    assert_failure
}

@test "is_disable_approved: 'revoke SC2034' does NOT match SC2034" {
    run is_disable_approved "SC2034" "revoke SC2034"
    assert_failure
}

@test "is_disable_approved: 'approve' and 'SC2034' separated by other words still matches" {
    run is_disable_approved "SC2034" "approve the following code: SC2034 please"
    assert_success
}

@test "is_disable_approved: empty user msg -> not approved" {
    run is_disable_approved "SC2034" ""
    assert_failure
}

@test "is_disable_approved: empty code arg -> not approved" {
    run is_disable_approved "" "approve SC2034"
    assert_failure
}

@test "is_disable_approved: 'approves' (non-word-boundary) does not match" {
    run is_disable_approved "SC2034" "approves SC2034"
    assert_failure
}

@test "is_disable_approved: SC2034 substring inside XSC20349 does not match" {
    run is_disable_approved "SC2034" "approve XSC20349"
    assert_failure
}
