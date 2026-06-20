#!/usr/bin/env bats
# test/unit/hook/worktree_create_spec.bats
#
# Tests for the WorktreeCreate hook: it must place Claude Code's worktrees at
# <repo>/.worktree/<name> (on stdout) and create the git worktree there. Driven
# as a subprocess (stdin JSON) the way Claude Code invokes it, against a
# throwaway git repo used as CLAUDE_PROJECT_DIR.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    HOOK_SH="${REPO_ROOT}/.claude/hook/worktree_create.sh"

    # Throwaway repo to act as the target project.
    FAKE_REPO="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${FAKE_REPO}"
    git -C "${FAKE_REPO}" init -q
    git -C "${FAKE_REPO}" config user.email t@e.st
    git -C "${FAKE_REPO}" config user.name tester
    git -C "${FAKE_REPO}" commit -q --allow-empty -m init
}

teardown() {
    teardown_test_env
}

# _run_create <name> — feed {"name":...} to the hook with CLAUDE_PROJECT_DIR set.
# git chatter goes to the hook's stderr (dropped here) so ${output} is the
# clean stdout path, exactly what Claude Code reads.
_run_create() {
    run bash -c 'printf "%s" "$1" | CLAUDE_PROJECT_DIR="$2" "$3" 2>/dev/null' _ \
        "{\"name\":\"$1\"}" "${FAKE_REPO}" "${HOOK_SH}"
}

@test "creates the worktree under <repo>/.worktree/<name> and prints the path" {
    _run_create "agent-abc"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${FAKE_REPO}/.worktree/agent-abc" ]
    [ -e "${FAKE_REPO}/.worktree/agent-abc/.git" ]
}

@test "creates the worktree on a worktree-<name> branch" {
    _run_create "agent-xyz"
    [ "${status}" -eq 0 ]
    run git -C "${FAKE_REPO}" worktree list
    [[ "${output}" == *"worktree-agent-xyz"* ]]
}

@test "is idempotent — re-running returns the same path, no error" {
    _run_create "dup"
    [ "${status}" -eq 0 ]
    _run_create "dup"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${FAKE_REPO}/.worktree/dup" ]
}

@test "rejects an unsafe name with path separators" {
    _run_create "../evil"
    [ "${status}" -ne 0 ]
    [ ! -e "${FAKE_REPO}/evil" ]
}

@test "rejects a name containing .." {
    _run_create "a..b"
    [ "${status}" -ne 0 ]
}

@test "fails when .name is missing from the payload" {
    run bash -c 'printf "%s" "{}" | CLAUDE_PROJECT_DIR="$1" "$2" 2>/dev/null' _ "${FAKE_REPO}" "${HOOK_SH}"
    [ "${status}" -ne 0 ]
}

@test "stdout carries ONLY the path (no git chatter)" {
    _run_create "clean-out"
    [ "${status}" -eq 0 ]
    # exactly one line, equal to the path
    [ "$(printf '%s' "${output}" | wc -l | tr -d ' ')" = "0" ]   # no trailing newline -> 0 newlines
    [ "${output}" = "${FAKE_REPO}/.worktree/clean-out" ]
}
