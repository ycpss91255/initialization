#!/usr/bin/env bats
# test/unit/hook/check_changelog_drift_spec.bats
#
# Tests for check_changelog_drift.sh (PreToolUse Bash). Advisory-only
# (exit 0): on `git commit` it warns (systemMessage) when non-doc files are
# staged without doc/changelog/CHANGELOG.md also staged. Doc-only commits,
# CHANGELOG-included commits, and --amend pass silently. Driven against a
# throwaway git repo; the command uses `git -C <repo> commit`.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    HOOK_SH="${REPO_ROOT}/.claude/hook/check_changelog_drift.sh"

    FAKE_REPO="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${FAKE_REPO}/doc/changelog" "${FAKE_REPO}/lib" "${FAKE_REPO}/doc/adr"
    git -C "${FAKE_REPO}" init -q
    git -C "${FAKE_REPO}" config user.email t@e.st
    git -C "${FAKE_REPO}" config user.name tester
    printf '# Changelog\n' > "${FAKE_REPO}/doc/changelog/CHANGELOG.md"
    git -C "${FAKE_REPO}" add doc/changelog/CHANGELOG.md
    git -C "${FAKE_REPO}" commit -q -m init
}

teardown() { teardown_test_env; }

_json() { jq -n --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}'; }

_run_hook() {
    run bash -c 'printf "%s" "$1" | "$2"' _ "$(_json "$1")" "${HOOK_SH}"
}

# ── warns: staged code, CHANGELOG not staged ─────────────────────────────────

@test "warns when a code file is staged without a CHANGELOG update" {
    printf 'echo hi\n' > "${FAKE_REPO}/lib/foo.sh"
    git -C "${FAKE_REPO}" add lib/foo.sh
    _run_hook "git -C ${FAKE_REPO} commit -m 'feat: foo'"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"CHANGELOG drift"* ]]
    [[ "${output}" == *"lib/foo.sh"* ]]
}

# ── silent: doc-only / CHANGELOG present / amend / non-commit ─────────────────

@test "silent when only a doc file is staged" {
    printf '# adr\n' > "${FAKE_REPO}/doc/adr/0099-x.md"
    git -C "${FAKE_REPO}" add doc/adr/0099-x.md
    _run_hook "git -C ${FAKE_REPO} commit -m 'docs: adr'"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "silent when code AND CHANGELOG are staged together" {
    printf 'echo hi\n' > "${FAKE_REPO}/lib/foo.sh"
    printf '# Changelog\n- entry\n' > "${FAKE_REPO}/doc/changelog/CHANGELOG.md"
    git -C "${FAKE_REPO}" add lib/foo.sh doc/changelog/CHANGELOG.md
    _run_hook "git -C ${FAKE_REPO} commit -m 'feat: foo'"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "silent on --amend even with staged code" {
    printf 'echo hi\n' > "${FAKE_REPO}/lib/foo.sh"
    git -C "${FAKE_REPO}" add lib/foo.sh
    _run_hook "git -C ${FAKE_REPO} commit --amend -m 'feat: foo'"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "silent for a non-commit git command (git status)" {
    _run_hook "git -C ${FAKE_REPO} status"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}
