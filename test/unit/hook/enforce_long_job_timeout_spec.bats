#!/usr/bin/env bats
# test/unit/hook/enforce_long_job_timeout_spec.bats
#
# Tests for the enforce_long_job_timeout.sh PreToolUse Bash hook: long-running
# FOREGROUND jobs must be bounded (run_in_background OR a timeout param OR a
# self-wrapped timeout(1)); otherwise the hook blocks (exit 2). Tests drive the
# script as a subprocess (stdin JSON) the same way Claude Code invokes it.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    HOOK_SH="${REPO_ROOT}/.claude/hook/enforce_long_job_timeout.sh"
}

teardown() {
    teardown_test_env
}

# _bash_json <command> [run_in_background] [timeout]
_bash_json() {
    local _cmd="$1" _bg="${2:-}" _to="${3:-}"
    jq -n --arg c "${_cmd}" --argjson bg "${_bg:-null}" --argjson to "${_to:-null}" \
        '{tool_name:"Bash", tool_input:({command:$c}
            + (if $bg == null then {} else {run_in_background:$bg} end)
            + (if $to == null then {} else {timeout:$to} end))}'
}

# ── blocked: long foreground jobs with no time bound ─────────────────────────

@test "blocks 'just coverage' with no timeout / not backgrounded" {
    run bash -c "printf '%s' '$(_bash_json "just -f justfile.ci coverage")' | '${HOOK_SH}'"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"BLOCKED"* ]]
}

@test "blocks 'just test-unit core' with no bound" {
    run bash -c "printf '%s' '$(_bash_json "just -f justfile.ci test-unit core")' | '${HOOK_SH}'"
    [ "${status}" -eq 2 ]
}

@test "blocks a whole-tree bats glob run" {
    run bash -c "printf '%s' '$(_bash_json "docker run --entrypoint bash img -c 'bats test/unit/*.bats'")' | '${HOOK_SH}'"
    [ "${status}" -eq 2 ]
}

@test "blocks 'docker build' with no bound" {
    run bash -c "printf '%s' '$(_bash_json "docker build -t x .")' | '${HOOK_SH}'"
    [ "${status}" -eq 2 ]
}

@test "blocks a docker compose service run with no bound" {
    run bash -c "printf '%s' '$(_bash_json "docker compose -f compose.yaml run --rm coverage -c x")' | '${HOOK_SH}'"
    [ "${status}" -eq 2 ]
}

@test "blocks an env-prefixed long launch (first token is the env assignment)" {
    run bash -c "printf '%s' '$(_bash_json "INIT_UBUNTU_LANG=x just -f justfile.ci coverage")' | '${HOOK_SH}'"
    [ "${status}" -eq 2 ]
}

# ── allowed: bounded, backgrounded, short, or text-carriers ──────────────────

@test "allows 'just coverage' when the timeout param is set" {
    run bash -c "printf '%s' '$(_bash_json "just -f justfile.ci coverage" "" 600000)' | '${HOOK_SH}'"
    [ "${status}" -eq 0 ]
}

@test "allows 'just coverage' when run_in_background is true" {
    run bash -c "printf '%s' '$(_bash_json "just -f justfile.ci coverage" true)' | '${HOOK_SH}'"
    [ "${status}" -eq 0 ]
}

@test "allows a self-wrapped timeout(1) command" {
    run bash -c "printf '%s' '$(_bash_json "timeout 600 just -f justfile.ci lint")' | '${HOOK_SH}'"
    [ "${status}" -eq 0 ]
}

@test "allows a targeted single-spec bats run (no '*' glob)" {
    run bash -c "printf '%s' '$(_bash_json "docker run --rm img bats test/unit/foo_spec.bats")' | '${HOOK_SH}'"
    [ "${status}" -eq 0 ]
}

@test "allows a git commit whose message contains trigger words" {
    run bash -c "printf '%s' '$(_bash_json "git commit -m 'just test the lint coverage wording'")' | '${HOOK_SH}'"
    [ "${status}" -eq 0 ]
}

@test "allows a gh pr body that mentions just coverage" {
    run bash -c "printf '%s' '$(_bash_json "gh pr create --body 'runs just coverage in CI'")' | '${HOOK_SH}'"
    [ "${status}" -eq 0 ]
}

@test "allows a short ordinary command" {
    run bash -c "printf '%s' '$(_bash_json "git status")' | '${HOOK_SH}'"
    [ "${status}" -eq 0 ]
}
