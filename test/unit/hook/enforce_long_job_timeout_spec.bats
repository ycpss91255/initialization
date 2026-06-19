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

# _run_hook <json> — feed JSON to the hook on stdin. JSON and the hook path are
# passed as positional args (not interpolated into the command string), so
# single quotes / `*` globs inside the command value can't break the harness.
_run_hook() {
    run bash -c 'printf "%s" "$1" | "$2"' _ "$1" "${HOOK_SH}"
}

# ── blocked: long foreground jobs with no time bound ─────────────────────────

@test "blocks 'just coverage' with no timeout / not backgrounded" {
    _run_hook "$(_bash_json "just -f justfile.ci coverage")"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"BLOCKED"* ]]
}

@test "blocks 'just test-unit core' with no bound" {
    _run_hook "$(_bash_json "just -f justfile.ci test-unit core")"
    [ "${status}" -eq 2 ]
}

@test "blocks 'docker build' with no bound" {
    _run_hook "$(_bash_json "docker build -t x .")"
    [ "${status}" -eq 2 ]
}

@test "blocks a docker compose service run with no bound" {
    _run_hook "$(_bash_json "docker compose -f compose.yaml run --rm coverage -c x")"
    [ "${status}" -eq 2 ]
}

@test "blocks an env-prefixed long launch (first token is the env assignment)" {
    _run_hook "$(_bash_json "INIT_UBUNTU_LANG=x just -f justfile.ci coverage")"
    [ "${status}" -eq 2 ]
}

# ── allowed: bounded, backgrounded, short, or text-carriers ──────────────────

@test "allows 'just coverage' when the timeout param is set" {
    _run_hook "$(_bash_json "just -f justfile.ci coverage" "" 600000)"
    [ "${status}" -eq 0 ]
}

@test "allows 'just coverage' when run_in_background is true" {
    _run_hook "$(_bash_json "just -f justfile.ci coverage" true)"
    [ "${status}" -eq 0 ]
}

@test "allows a self-wrapped timeout(1) command" {
    _run_hook "$(_bash_json "timeout 600 just -f justfile.ci lint")"
    [ "${status}" -eq 0 ]
}

@test "allows a targeted single-spec bats run (no '*' glob)" {
    _run_hook "$(_bash_json "docker run --rm img bats test/unit/foo_spec.bats")"
    [ "${status}" -eq 0 ]
}

@test "allows a git commit whose message contains trigger words" {
    _run_hook "$(_bash_json "git commit -m 'just test the lint coverage wording'")"
    [ "${status}" -eq 0 ]
}

@test "allows a gh pr body that mentions just coverage" {
    _run_hook "$(_bash_json "gh pr create --body 'runs just coverage in CI'")"
    [ "${status}" -eq 0 ]
}

@test "allows a short ordinary command" {
    _run_hook "$(_bash_json "git status")"
    [ "${status}" -eq 0 ]
}

# ── per-sub-command analysis (cd-prefixed compounds) ─────────────────────────

@test "allows 'cd repo && git commit' whose message mentions kcov / coverage" {
    _run_hook "$(_bash_json "cd /repo && git commit -m 'fix under CI kcov run; just coverage wording'")"
    [ "${status}" -eq 0 ]
}

@test "allows a multi-line cd + git commit with trigger words in the body" {
    _run_hook "$(_bash_json "$(printf 'cd /repo\ngit add x\ngit commit -m "ran kcov and just coverage"')")"
    [ "${status}" -eq 0 ]
}

@test "still blocks a real long launch after a cd prefix" {
    _run_hook "$(_bash_json "cd /repo && just -f justfile.ci coverage")"
    [ "${status}" -eq 2 ]
}

@test "allows a bare 'cd repo'" {
    _run_hook "$(_bash_json "cd /home/x/repo")"
    [ "${status}" -eq 0 ]
}
