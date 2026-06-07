#!/usr/bin/env bats
# test/unit/hook/disable_diff_spec.bats
#
# Unit tests for `new_shellcheck_disables` in
# .claude/hook/enforce_shellcheck_disable_approval.sh (issue #17).
#
# Module contract:
#   - Args: $1 = new_content_str, $2 = existing_file_path (may not exist)
#   - Stdout: one SC code per line for each disable in $1 NOT in $2;
#     multi-code directives (`disable=SC2034,SC2317`) split into codes
#   - Exit: 0 always

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    HOOK_SH="${REPO_ROOT}/.claude/hook/enforce_shellcheck_disable_approval.sh"
    # shellcheck source=../../../.claude/hook/enforce_shellcheck_disable_approval.sh
    source "${HOOK_SH}"
    FIXTURE_DIR="${BATS_TEST_TMPDIR}/contents"
    mkdir -p "${FIXTURE_DIR}"
}

teardown() {
    teardown_test_env
}

@test "new_shellcheck_disables: new file, one disable -> that code emitted" {
    local new_content='#!/usr/bin/env bash
# shellcheck disable=SC2034
foo=bar
'
    local nonexistent="${FIXTURE_DIR}/new.sh"
    run new_shellcheck_disables "${new_content}" "${nonexistent}"
    assert_success
    assert_output "SC2034"
}

@test "new_shellcheck_disables: empty content + empty existing -> empty" {
    local nonexistent="${FIXTURE_DIR}/empty.sh"
    run new_shellcheck_disables "" "${nonexistent}"
    assert_success
    assert_output ""
}

@test "new_shellcheck_disables: content adds SC2034, existing has SC1091 -> only SC2034" {
    local existing="${FIXTURE_DIR}/with-sc1091.sh"
    cat > "${existing}" <<'EOF'
#!/usr/bin/env bash
# shellcheck disable=SC1091
source x.sh
EOF
    local new_content
    new_content="$(cat "${existing}")
# shellcheck disable=SC2034
foo=bar"
    run new_shellcheck_disables "${new_content}" "${existing}"
    assert_success
    assert_output "SC2034"
}

@test "new_shellcheck_disables: comma-separated disable=SC2034,SC2317 -> both codes" {
    local new_content='# shellcheck disable=SC2034,SC2317
foo() { :; }'
    local nonexistent="${FIXTURE_DIR}/multi.sh"
    run new_shellcheck_disables "${new_content}" "${nonexistent}"
    assert_success
    assert_line "SC2034"
    assert_line "SC2317"
}

@test "new_shellcheck_disables: re-save with same disables -> empty (additions only)" {
    local existing="${FIXTURE_DIR}/same.sh"
    cat > "${existing}" <<'EOF'
# shellcheck disable=SC2034
foo=bar
EOF
    local new_content
    new_content="$(cat "${existing}")"
    run new_shellcheck_disables "${new_content}" "${existing}"
    assert_success
    assert_output ""
}

@test "new_shellcheck_disables: removal of a disable -> empty (additions only)" {
    local existing="${FIXTURE_DIR}/with-two.sh"
    cat > "${existing}" <<'EOF'
# shellcheck disable=SC2034
# shellcheck disable=SC1091
foo=bar
EOF
    local new_content='# shellcheck disable=SC2034
foo=bar
'
    run new_shellcheck_disables "${new_content}" "${existing}"
    assert_success
    assert_output ""
}

@test "new_shellcheck_disables: mixed add (SC1091) + remove (SC2317) -> only SC1091" {
    local existing="${FIXTURE_DIR}/mixed.sh"
    cat > "${existing}" <<'EOF'
# shellcheck disable=SC2034
# shellcheck disable=SC2317
foo=bar
EOF
    local new_content='# shellcheck disable=SC2034
# shellcheck disable=SC1091
foo=bar
'
    run new_shellcheck_disables "${new_content}" "${existing}"
    assert_success
    assert_output "SC1091"
}

@test "new_shellcheck_disables: empty existing-path arg -> treats as no existing" {
    local new_content='# shellcheck disable=SC2155
x=foo'
    run new_shellcheck_disables "${new_content}" ""
    assert_success
    assert_output "SC2155"
}
