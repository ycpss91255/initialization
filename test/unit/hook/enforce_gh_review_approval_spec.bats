#!/usr/bin/env bats
# test/unit/hook/enforce_gh_review_approval_spec.bats
#
# Tests for the enforce_gh_review_approval.sh hook (issue #34). The hook
# blocks `gh issue create|edit` / `gh pr create|edit` unless the session
# transcript contains an explicit user approval phrase.
#
# Two layers:
#   - Unit: source the script, exercise read_user_messages /
#     is_review_approved in isolation.
#   - Integration: drive the script as a subprocess (stdin JSON, stdout
#     permissionDecision JSON or empty) the way Claude Code invokes it.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    HOOK_SH="${REPO_ROOT}/.claude/hook/enforce_gh_review_approval.sh"
    # shellcheck source=../../../.claude/hook/enforce_gh_review_approval.sh
    source "${HOOK_SH}"
    FIXTURE_DIR="${BATS_TEST_TMPDIR}/fixtures"
    mkdir -p "${FIXTURE_DIR}"

    # Default transcript: a user message that does NOT approve anything.
    TRANSCRIPT="${FIXTURE_DIR}/transcript.jsonl"
    cat > "${TRANSCRIPT}" <<'EOF'
{"type":"assistant","message":{"role":"assistant","content":"drafting..."}}
{"type":"user","message":{"role":"user","content":"please open an issue for the bug"}}
EOF
}

teardown() {
    teardown_test_env
    unset ECC_ALLOW_GH_REVIEW
}

# Build a PreToolUse Bash JSON payload pointing at the current TRANSCRIPT.
_pre_bash_json() {
    local command="$1"
    jq -n \
        --arg c "${command}" \
        --arg tp "${TRANSCRIPT}" \
        '{tool_name:"Bash", transcript_path:$tp, tool_input:{command:$c}}'
}

# ── read_user_messages ───────────────────────────────────────────────────────

@test "read_user_messages: missing file -> empty stdout, exit 0" {
    run read_user_messages "${FIXTURE_DIR}/nope.jsonl"
    assert_success
    assert_output ""
}

@test "read_user_messages: empty arg -> empty stdout, exit 0" {
    run read_user_messages ""
    assert_success
    assert_output ""
}

@test "read_user_messages: emits string + array text, skips tool_result" {
    local f="${FIXTURE_DIR}/mixed.jsonl"
    cat > "${f}" <<'EOF'
{"type":"assistant","message":{"role":"assistant","content":"hi"}}
{"type":"user","message":{"role":"user","content":"approve pr please"}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"synthetic"}]}}
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"looks good"}]}}
EOF
    run read_user_messages "${f}"
    assert_success
    assert_line "approve pr please"
    assert_line "looks good"
    refute_output --partial "synthetic"
}

# ── is_review_approved ───────────────────────────────────────────────────────

@test "is_review_approved: 'approve issue' authorizes issue" {
    run is_review_approved "issue" "ok, approve issue"
    assert_success
}

@test "is_review_approved: 'issue ok' authorizes issue" {
    run is_review_approved "issue" "the draft is fine, issue ok"
    assert_success
}

@test "is_review_approved: 'approve pr' authorizes pr" {
    run is_review_approved "pr" "APPROVE PR"
    assert_success
}

@test "is_review_approved: 'pr ok' authorizes pr" {
    run is_review_approved "pr" "pr ok, ship it"
    assert_success
}

@test "is_review_approved: 'skip review' authorizes issue" {
    run is_review_approved "issue" "just open it, skip review"
    assert_success
}

@test "is_review_approved: 'skip review' authorizes pr" {
    run is_review_approved "pr" "skip review and open the pr"
    assert_success
}

@test "is_review_approved: issue approval does not authorize pr" {
    run is_review_approved "pr" "approve issue"
    assert_failure
}

@test "is_review_approved: pr approval does not authorize issue" {
    run is_review_approved "issue" "approve pr"
    assert_failure
}

@test "is_review_approved: unrelated text -> not approved" {
    run is_review_approved "issue" "please write the draft first"
    assert_failure
}

@test "is_review_approved: empty message -> not approved" {
    run is_review_approved "issue" ""
    assert_failure
}

# ── main: allow paths ────────────────────────────────────────────────────────

@test "main: non-gh command -> allow silently" {
    local input; input="$(_pre_bash_json "echo hello")"
    run bash -c "printf '%s' \"\$1\" | '${HOOK_SH}'" _ "${input}"
    assert_success
    assert_output ""
}

@test "main: gh issue view (read-only) -> allow silently" {
    local input; input="$(_pre_bash_json "gh issue view 34")"
    run bash -c "printf '%s' \"\$1\" | '${HOOK_SH}'" _ "${input}"
    assert_success
    assert_output ""
}

@test "main: gh issue create WITH approval -> allow" {
    cat > "${TRANSCRIPT}" <<'EOF'
{"type":"user","message":{"role":"user","content":"draft looks good, approve issue"}}
EOF
    local input; input="$(_pre_bash_json "gh issue create --title t --body-file /tmp/x.md --label bug")"
    run bash -c "printf '%s' \"\$1\" | '${HOOK_SH}'" _ "${input}"
    assert_success
    assert_output ""
}

@test "main: gh pr create WITH approval -> allow" {
    cat > "${TRANSCRIPT}" <<'EOF'
{"type":"user","message":{"role":"user","content":"pr ok"}}
EOF
    local input; input="$(_pre_bash_json "gh pr create --base main --head auto/x --body-file /tmp/x.md")"
    run bash -c "printf '%s' \"\$1\" | '${HOOK_SH}'" _ "${input}"
    assert_success
    assert_output ""
}

@test "main: ECC_ALLOW_GH_REVIEW=1 bypass -> allow even without approval" {
    local input; input="$(_pre_bash_json "gh pr create --body-file /tmp/x.md")"
    ECC_ALLOW_GH_REVIEW=1 run bash -c "printf '%s' \"\$1\" | '${HOOK_SH}'" _ "${input}"
    assert_success
    assert_output ""
}

# ── main: deny paths ─────────────────────────────────────────────────────────

@test "main: gh issue create WITHOUT approval -> deny JSON" {
    local input; input="$(_pre_bash_json "gh issue create --title t --body-file /tmp/x.md --label bug")"
    run bash -c "printf '%s' \"\$1\" | '${HOOK_SH}'" _ "${input}"
    assert_success
    assert_output --partial '"permissionDecision": "deny"'
    assert_output --partial 'GitHub review approval required'
    assert_output --partial 'approve issue'
}

@test "main: gh pr create WITHOUT approval -> deny JSON" {
    local input; input="$(_pre_bash_json "gh pr create --base main --head auto/x --body-file /tmp/x.md")"
    run bash -c "printf '%s' \"\$1\" | '${HOOK_SH}'" _ "${input}"
    assert_success
    assert_output --partial '"permissionDecision": "deny"'
    assert_output --partial 'approve pr'
}

@test "main: gh pr edit WITHOUT approval -> deny JSON" {
    local input; input="$(_pre_bash_json "gh pr edit 5 --body-file /tmp/x.md")"
    run bash -c "printf '%s' \"\$1\" | '${HOOK_SH}'" _ "${input}"
    assert_success
    assert_output --partial '"permissionDecision": "deny"'
}

@test "main: issue approval does NOT unlock a pr create -> deny" {
    cat > "${TRANSCRIPT}" <<'EOF'
{"type":"user","message":{"role":"user","content":"approve issue"}}
EOF
    local input; input="$(_pre_bash_json "gh pr create --body-file /tmp/x.md")"
    run bash -c "printf '%s' \"\$1\" | '${HOOK_SH}'" _ "${input}"
    assert_success
    assert_output --partial '"permissionDecision": "deny"'
}
