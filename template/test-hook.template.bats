#!/usr/bin/env bats
# test/unit/hook/<HOOK-NAME>_spec.bats — bats spec for .agents/hook/<HOOK-NAME>.sh
#
# Quick start:
#   1. cp template/test-hook.template.bats test/unit/hook/<your-name>_spec.bats
#   2. Replace every <HOOK-NAME> below with your hook name (no quotes).
#   3. Set the JSON payload + banned pattern to match your hook's rule.
#   4. Search for <TODO> markers and fill them in.
#   5. Run: just -f justfile.ci test-unit
#
# What this template covers (the hook outward contract — see
# lib/hook_bootstrap.sh, ADR-0007):
#   - block path:  exit 2 + "[hook:<name>] BLOCKED — ..." on stderr
#   - allow path:  exit 0, no block message
#   - never emits a spurious block on an unrelated / empty command
#
# The hook is driven as a subprocess (stdin JSON -> exit code + stderr), the
# same way Claude Code invokes it. All tests run inside Docker (ADR-0004).

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    HOOK_SH="${REPO_ROOT}/.claude/hook/<HOOK-NAME>.sh"
}

teardown() { teardown_test_env; }

# Build a PreToolUse Bash payload with the given command string.
_json() { jq -n --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}'; }

# Feed a command's JSON to the hook on stdin, the way Claude Code does.
_run() {
    run bash -c "printf '%s' \"\$1\" | '${HOOK_SH}'" _ "$(_json "$1")"
}

# ── Block path ───────────────────────────────────────────────────────────────

@test "<HOOK-NAME>: banned command is blocked (exit 2 + message)" {
    # <TODO>: replace with a command your hook must BLOCK.
    _run "banned-command --now"
    assert_failure 2
    assert_output --partial "BLOCKED"
}

# ── Allow path ───────────────────────────────────────────────────────────────

@test "<HOOK-NAME>: unrelated command is allowed (exit 0)" {
    # <TODO>: replace with a command your hook must ALLOW.
    _run "ls -la"
    assert_success
    refute_output --partial "BLOCKED"
}

@test "<HOOK-NAME>: empty command is allowed (exit 0)" {
    _run ""
    assert_success
}

# ── TODO: hook-specific behavior ─────────────────────────────────────────────
# Add tests for each pattern your hook decides on: the boundary cases that MUST
# block and the near-miss cases that MUST NOT (guard against false positives).
