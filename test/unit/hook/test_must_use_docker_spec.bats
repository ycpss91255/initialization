#!/usr/bin/env bats
# test/unit/hook/test_must_use_docker_spec.bats
#
# Tests for test-must-use-docker.sh (ADR-0004): host-side test / Module Action
# Phase / apt-mutation commands must be BLOCKED (exit 2); anything routed
# through Docker / just / a whitelisted read-only binary is ALLOWED (exit 0).
# Driven as a subprocess (stdin JSON) the way Claude Code invokes it.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    HOOK_SH="${REPO_ROOT}/.claude/hook/test-must-use-docker.sh"
}

teardown() { teardown_test_env; }

_json() { jq -n --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}'; }

_run_hook() {
    run bash -c 'printf "%s" "$1" | "$2"' _ "$(_json "$1")" "${HOOK_SH}"
}

# ── blocked: host-side test / module / apt ───────────────────────────────────

@test "blocks a bare 'bats' run on the host" {
    _run_hook "bats test/unit/foo_spec.bats"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"BLOCKED"* ]]
}

@test "blocks a Module Action Phase (install) on the host" {
    _run_hook "bash module/config-git.module.sh install"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"Action Phase"* ]]
}

@test "blocks a direct ./module purge on the host" {
    _run_hook "./module/tmux.module.sh purge"
    [ "${status}" -eq 2 ]
}

@test "blocks host 'sudo apt install'" {
    _run_hook "sudo apt install ripgrep"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"apt"* ]]
}

@test "blocks bare 'apt-get install' without sudo" {
    _run_hook "apt-get install -y fzf"
    [ "${status}" -eq 2 ]
}

# ── allowed: docker / just / read-only / carriers ────────────────────────────

@test "allows 'just -f justfile.ci test-unit'" {
    _run_hook "just -f justfile.ci test-unit"
    [ "${status}" -eq 0 ]
}

@test "allows bats when it runs inside docker" {
    _run_hook "docker run --rm test-tools:local bats test/unit/foo_spec.bats"
    [ "${status}" -eq 0 ]
}

@test "allows 'apt-get update' (read-only, not a mutation)" {
    _run_hook "sudo apt-get update"
    [ "${status}" -eq 0 ]
}

@test "allows a git commit whose message contains 'bats' / 'apt install'" {
    _run_hook "git commit -m 'run bats and apt install notes in docker'"
    [ "${status}" -eq 0 ]
}

@test "allows an empty command" {
    _run_hook ""
    [ "${status}" -eq 0 ]
}
