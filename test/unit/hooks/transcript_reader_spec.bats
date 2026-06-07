#!/usr/bin/env bats
# test/unit/hooks/transcript_reader_spec.bats
#
# Unit tests for `read_latest_user_message` in
# .claude/hook/enforce_shellcheck_disable_approval.sh (issue #17).
#
# Module contract:
#   - Args: $1 = transcript_path
#   - Stdout: latest user-typed text message (most recent in file order)
#   - Exit: 0 always; missing/malformed content yields empty stdout
#
# Test fixtures are inline minimal JSONL written under BATS_TEST_TMPDIR.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    HOOK_SH="${REPO_ROOT}/.claude/hook/enforce_shellcheck_disable_approval.sh"
    # shellcheck source=../../../.claude/hook/enforce_shellcheck_disable_approval.sh
    source "${HOOK_SH}"
    FIXTURE_DIR="${BATS_TEST_TMPDIR}/transcripts"
    mkdir -p "${FIXTURE_DIR}"
}

teardown() {
    teardown_test_env
}

@test "read_latest_user_message: empty file -> empty stdout, exit 0" {
    local f="${FIXTURE_DIR}/empty.jsonl"
    : > "${f}"
    run read_latest_user_message "${f}"
    assert_success
    assert_output ""
}

@test "read_latest_user_message: missing file -> empty stdout, exit 0" {
    run read_latest_user_message "${FIXTURE_DIR}/does-not-exist.jsonl"
    assert_success
    assert_output ""
}

@test "read_latest_user_message: empty arg -> empty stdout, exit 0" {
    run read_latest_user_message ""
    assert_success
    assert_output ""
}

@test "read_latest_user_message: only assistant messages -> empty stdout" {
    local f="${FIXTURE_DIR}/asst-only.jsonl"
    cat > "${f}" <<'EOF'
{"type":"assistant","message":{"role":"assistant","content":"hello"}}
{"type":"assistant","message":{"role":"assistant","content":"world"}}
EOF
    run read_latest_user_message "${f}"
    assert_success
    assert_output ""
}

@test "read_latest_user_message: one user message (string content) returned" {
    local f="${FIXTURE_DIR}/one-user.jsonl"
    cat > "${f}" <<'EOF'
{"type":"user","message":{"role":"user","content":"approve SC2034"}}
EOF
    run read_latest_user_message "${f}"
    assert_success
    assert_output "approve SC2034"
}

@test "read_latest_user_message: alternating user/assistant — latest user wins" {
    local f="${FIXTURE_DIR}/alternating.jsonl"
    cat > "${f}" <<'EOF'
{"type":"user","message":{"role":"user","content":"first user msg"}}
{"type":"assistant","message":{"role":"assistant","content":"asst reply"}}
{"type":"user","message":{"role":"user","content":"approve SC2034"}}
{"type":"assistant","message":{"role":"assistant","content":"final reply"}}
EOF
    run read_latest_user_message "${f}"
    assert_success
    assert_output "approve SC2034"
}

@test "read_latest_user_message: array content with text block returned" {
    local f="${FIXTURE_DIR}/array-text.jsonl"
    cat > "${f}" <<'EOF'
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"approve SC1091"}]}}
EOF
    run read_latest_user_message "${f}"
    assert_success
    assert_output "approve SC1091"
}

@test "read_latest_user_message: tool_result-only array is skipped, falls back to prior text" {
    local f="${FIXTURE_DIR}/tool-result-then-text.jsonl"
    cat > "${f}" <<'EOF'
{"type":"user","message":{"role":"user","content":"approve SC2317"}}
{"type":"assistant","message":{"role":"assistant","content":"calling tool"}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"abc","content":"output"}]}}
EOF
    run read_latest_user_message "${f}"
    assert_success
    assert_output "approve SC2317"
}

@test "read_latest_user_message: malformed line skipped, valid prior line returned" {
    local f="${FIXTURE_DIR}/malformed.jsonl"
    cat > "${f}" <<'EOF'
{"type":"user","message":{"role":"user","content":"approve SC2155"}}
this is not json
EOF
    run read_latest_user_message "${f}"
    assert_success
    assert_output "approve SC2155"
}
