#!/usr/bin/env bats
# test/unit/hooks/enforce_shellcheck_disable_approval_spec.bats
#
# Integration tests for the enforce_shellcheck_disable_approval.sh hook
# (issue #17). Tests drive the script as a subprocess (stdin JSON,
# stdout permissionDecision JSON or empty) the same way Claude Code
# invokes it.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    HOOK_SH="${REPO_ROOT}/.claude/hook/enforce_shellcheck_disable_approval.sh"
    FIXTURE_DIR="${BATS_TEST_TMPDIR}/fixtures"
    mkdir -p "${FIXTURE_DIR}"

    # Synthetic transcript: one user message approving SC2034 only.
    TRANSCRIPT="${FIXTURE_DIR}/transcript.jsonl"
    cat > "${TRANSCRIPT}" <<'EOF'
{"type":"assistant","message":{"role":"assistant","content":"asking..."}}
{"type":"user","message":{"role":"user","content":"approve SC2034"}}
EOF

    TARGET_SH="${FIXTURE_DIR}/target.sh"
    cat > "${TARGET_SH}" <<'EOF'
#!/usr/bin/env bash
foo=bar
EOF
}

teardown() {
    teardown_test_env
    unset ECC_ALLOW_SHELLCHECK_DISABLE
}

_pre_write_json() {
    local file_path="$1" content="$2"
    jq -n \
        --arg fp "${file_path}" \
        --arg c "${content}" \
        --arg tp "${TRANSCRIPT}" \
        '{tool_name:"Write", transcript_path:$tp, tool_input:{file_path:$fp, content:$c}}'
}

_pre_edit_json() {
    local file_path="$1" new_string="$2"
    jq -n \
        --arg fp "${file_path}" \
        --arg ns "${new_string}" \
        --arg tp "${TRANSCRIPT}" \
        '{tool_name:"Edit", transcript_path:$tp, tool_input:{file_path:$fp, new_string:$ns}}'
}

_pre_multiedit_json() {
    local file_path="$1"; shift
    local edits_json
    edits_json="$(jq -n '[]')"
    local ns
    for ns in "$@"; do
        edits_json="$(printf '%s' "${edits_json}" | jq --arg s "${ns}" '. + [{old_string:"x", new_string:$s}]')"
    done
    jq -n \
        --arg fp "${file_path}" \
        --arg tp "${TRANSCRIPT}" \
        --argjson e "${edits_json}" \
        '{tool_name:"MultiEdit", transcript_path:$tp, tool_input:{file_path:$fp, edits:$e}}'
}

@test "main: Edit adding approved SC2034 -> allow (empty stdout)" {
    local input
    input="$(_pre_edit_json "${TARGET_SH}" '# shellcheck disable=SC2034
foo=baz')"
    run bash -c "printf '%s' \"\$1\" | '${HOOK_SH}'" _ "${input}"
    assert_success
    assert_output ""
}

@test "main: non-target tool (Bash) -> allow silently" {
    local input
    input="$(jq -n --arg tp "${TRANSCRIPT}" '{tool_name:"Bash", transcript_path:$tp, tool_input:{command:"echo hi"}}')"
    run bash -c "printf '%s' \"\$1\" | '${HOOK_SH}'" _ "${input}"
    assert_success
    assert_output ""
}

@test "main: ECC_ALLOW_SHELLCHECK_DISABLE=1 bypass -> allow even without approval" {
    local input
    input="$(_pre_edit_json "${TARGET_SH}" '# shellcheck disable=SC1091
source x.sh')"
    ECC_ALLOW_SHELLCHECK_DISABLE=1 run bash -c "printf '%s' \"\$1\" | '${HOOK_SH}'" _ "${input}"
    assert_success
    assert_output ""
}

@test "main: Edit with no new disable -> allow silently" {
    local input
    input="$(_pre_edit_json "${TARGET_SH}" 'foo=baz
# no disables here')"
    run bash -c "printf '%s' \"\$1\" | '${HOOK_SH}'" _ "${input}"
    assert_success
    assert_output ""
}

@test "main: Edit adding unapproved SC1091 -> deny JSON with SC1091 + wiki URL" {
    local input
    input="$(_pre_edit_json "${TARGET_SH}" '# shellcheck disable=SC1091
source x.sh')"
    run bash -c "printf '%s' \"\$1\" | '${HOOK_SH}'" _ "${input}"
    assert_success
    assert_output --partial '"permissionDecision": "deny"'
    assert_output --partial 'SC1091'
    assert_output --partial 'https://www.shellcheck.net/wiki/SC1091'
}

@test "main: Write new file adding unapproved SC2317 -> deny JSON with SC2317" {
    local new_file="${FIXTURE_DIR}/brand-new.sh"
    local input
    input="$(_pre_write_json "${new_file}" '#!/usr/bin/env bash
# shellcheck disable=SC2317
foo() { :; }')"
    run bash -c "printf '%s' \"\$1\" | '${HOOK_SH}'" _ "${input}"
    assert_success
    assert_output --partial '"permissionDecision": "deny"'
    assert_output --partial 'SC2317'
    assert_output --partial 'https://www.shellcheck.net/wiki/SC2317'
}

@test "main: MultiEdit where one edit adds unapproved SC1091 -> deny" {
    local input
    input="$(_pre_multiedit_json "${TARGET_SH}" 'foo=baz' '# shellcheck disable=SC1091
source x.sh')"
    run bash -c "printf '%s' \"\$1\" | '${HOOK_SH}'" _ "${input}"
    assert_success
    assert_output --partial '"permissionDecision": "deny"'
    assert_output --partial 'SC1091'
}

@test "main: deny lists unapproved codes only, approved SC2034 wiki URL absent" {
    local input
    input="$(_pre_edit_json "${TARGET_SH}" '# shellcheck disable=SC2034
# shellcheck disable=SC1091
# shellcheck disable=SC2317
foo=baz')"
    run bash -c "printf '%s' \"\$1\" | '${HOOK_SH}'" _ "${input}"
    assert_success
    assert_output --partial '"permissionDecision": "deny"'
    assert_output --partial 'SC1091'
    assert_output --partial 'SC2317'
    refute_output --partial 'https://www.shellcheck.net/wiki/SC2034'
}

@test "main: editing a file that already has SC1091 (re-save same content) -> allow" {
    local pre_existing="${FIXTURE_DIR}/already-has-sc1091.sh"
    cat > "${pre_existing}" <<'EOF'
#!/usr/bin/env bash
# shellcheck disable=SC1091
source x.sh
EOF
    local content
    content="$(cat "${pre_existing}")"
    local input
    input="$(_pre_edit_json "${pre_existing}" "${content}")"
    run bash -c "printf '%s' \"\$1\" | '${HOOK_SH}'" _ "${input}"
    assert_success
    assert_output ""
}
