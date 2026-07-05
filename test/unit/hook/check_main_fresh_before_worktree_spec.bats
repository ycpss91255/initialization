#!/usr/bin/env bats
# test/unit/hook/check_main_fresh_before_worktree_spec.bats
#
# Tests for check_main_fresh_before_worktree.sh (PreToolUse Bash). BLOCKS
# (permissionDecision:"deny", exit 0) a `git worktree add ... main` when local
# main is behind origin/main. Allows when up to date, when not branching from
# main, and when the dir is not a git repo. Driven against a throwaway
# origin/clone pair so the hook's real `git fetch` runs.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    HOOK_SH="${REPO_ROOT}/.claude/hook/check_main_fresh_before_worktree.sh"

    _gc() { git -C "$1" config user.email t@e.st; git -C "$1" config user.name tester; }

    # Seed repo -> bare origin (main) -> a working clone tracking origin/main.
    SEED="${BATS_TEST_TMPDIR}/seed"
    ORIGIN="${BATS_TEST_TMPDIR}/origin.git"
    CLONE="${BATS_TEST_TMPDIR}/clone"
    git init -q -b main "${SEED}"; _gc "${SEED}"
    git -C "${SEED}" commit -q --allow-empty -m init
    git clone -q --bare "${SEED}" "${ORIGIN}"
    git clone -q "${ORIGIN}" "${CLONE}"; _gc "${CLONE}"
}

teardown() { teardown_test_env; }

_json() { jq -n --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}'; }

_run_hook() {
    run bash -c 'printf "%s" "$1" | "$2"' _ "$(_json "$1")" "${HOOK_SH}"
}

# Advance origin/main by pushing an extra commit from a second clone, so CLONE
# falls behind after the hook fetches.
_advance_origin() {
    local pusher="${BATS_TEST_TMPDIR}/pusher"
    git clone -q "${ORIGIN}" "${pusher}"
    git -C "${pusher}" config user.email t@e.st
    git -C "${pusher}" config user.name tester
    git -C "${pusher}" commit -q --allow-empty -m advance
    git -C "${pusher}" push -q origin main
}

# ── blocks: local main behind origin/main ────────────────────────────────────

@test "denies worktree-from-main when local main is behind origin/main" {
    _advance_origin
    _run_hook "git -C ${CLONE} worktree add ${BATS_TEST_TMPDIR}/wt main"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"deny"* ]]
    [[ "${output}" == *"behind origin/main"* ]]
}

# ── allows: up to date / not-from-main / not-a-repo ──────────────────────────

@test "allows worktree-from-main when local main is up to date" {
    _run_hook "git -C ${CLONE} worktree add ${BATS_TEST_TMPDIR}/wt main"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "allows a worktree that does not branch from main" {
    _advance_origin
    _run_hook "git -C ${CLONE} worktree add ${BATS_TEST_TMPDIR}/wt -b feat/x"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "allows when the working dir is not a git repo" {
    mkdir -p "${BATS_TEST_TMPDIR}/notrepo"
    _run_hook "git -C ${BATS_TEST_TMPDIR}/notrepo worktree add ${BATS_TEST_TMPDIR}/wt main"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "allows a non-worktree command" {
    _run_hook "git -C ${CLONE} status"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}
