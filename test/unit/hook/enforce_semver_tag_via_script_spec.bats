#!/usr/bin/env bats
# test/unit/hook/enforce_semver_tag_via_script_spec.bats
#
# Tests for enforce_semver_tag_via_script.sh (issue #106): ad-hoc version
# tagging / pushing is DENIED (emits permissionDecision:"deny", exit 0) so all
# traffic goes through .claude/script/release-tag.sh. Listing / delete /
# ordinary branch pushes pass through silently.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    HOOK_SH="${REPO_ROOT}/.claude/hook/enforce_semver_tag_via_script.sh"
}

teardown() { teardown_test_env; }

_json() { jq -n --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}'; }

_run_hook() {
    run bash -c 'printf "%s" "$1" | "$2"' _ "$(_json "$1")" "${HOOK_SH}"
}

# ── denied: ad-hoc version tag / push ────────────────────────────────────────

@test "denies 'git tag v1.2.3' (lightweight create)" {
    _run_hook "git tag v1.2.3"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"deny"* ]]
    [[ "${output}" == *"release-tag.sh"* ]]
}

@test "denies an annotated 'git tag -a v0.2.0 -m ...'" {
    _run_hook "git tag -a v0.2.0 -m 'release'"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"deny"* ]]
}

@test "denies 'git push origin v1.2.3'" {
    _run_hook "git push origin v1.2.3"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"deny"* ]]
}

@test "denies 'git push --tags'" {
    _run_hook "git push --tags"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"deny"* ]]
}

# ── allowed: list / delete / branch push ─────────────────────────────────────

@test "allows 'git tag -l' (list)" {
    _run_hook "git tag -l"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "allows 'git tag -d v1.2.3' (delete)" {
    _run_hook "git tag -d v1.2.3"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "allows a delete-by-refspec push 'git push origin :v1.2.3'" {
    _run_hook "git push origin :v1.2.3"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "allows an ordinary branch push" {
    _run_hook "git push -u origin feat/x"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "allows the canonical release-tag.sh invocation" {
    _run_hook ".claude/script/release-tag.sh v0.2.0 -m 'release'"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}
