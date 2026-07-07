#!/usr/bin/env bats
# test/unit/hook/enforce_gh_english_spec.bats
#
# Tests for enforce_gh_english.sh: gh issue/pr create|comment titles + bodies
# must be English-only and emoji-free. CJK / emoji content is DENIED
# (permissionDecision:"deny", exit 0); plain English + read-only subcommands
# pass through silently.
#
# NOTE: the hook detects CJK / emoji via python3. The lean test-tools image
# ships no python3, and the hook silently allows when python3 is absent (its
# detection returns empty). The deny-path tests therefore `skip` when python3
# is unavailable so they assert the real guard where the dependency exists
# (the host, where Claude Code actually invokes the hook) instead of
# false-failing in the minimal image. The trigger/allow paths do not depend on
# python3 and always run.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    HOOK_SH="${REPO_ROOT}/.claude/hook/enforce_gh_english.sh"
}

teardown() { teardown_test_env; }

_json() { jq -n --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}'; }

_run_hook() {
    run bash -c 'printf "%s" "$1" | "$2"' _ "$(_json "$1")" "${HOOK_SH}"
}

_require_python3() {
    command -v python3 >/dev/null 2>&1 || skip "python3 not available; hook CJK/emoji detection is a no-op"
}

# ── denied: CJK / emoji in issue+pr create/comment text ──────────────────────

@test "denies CJK in an issue body" {
    _require_python3
    _run_hook 'gh issue create --title "bug" --body "你好世界" --label bug'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"deny"* ]]
    [[ "${output}" == *"CJK"* ]]
}

@test "denies CJK in an issue title" {
    _require_python3
    _run_hook 'gh issue create --title "修复错误" --body "english body" --label bug'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"deny"* ]]
}

@test "denies Japanese kana in a pr comment" {
    _require_python3
    _run_hook 'gh pr comment 3 --body "ありがとう"'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"deny"* ]]
}

@test "denies an emoji in a pr create body" {
    _require_python3
    _run_hook 'gh pr create --title "feat" --body "shipped it ✨"'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"deny"* ]]
    [[ "${output}" == *"emoji"* ]]
}

# ── allowed: English + functional symbols + read-only (python3-independent) ───

@test "allows a plain-English issue body" {
    _run_hook 'gh issue create --title "fix: boom" --body "It crashed on start." --label bug'
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "allows functional symbols (arrows) in a body" {
    _run_hook 'gh pr create --title "feat" --body "input -> output pipeline"'
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "allows a read-only 'gh issue view'" {
    _run_hook 'gh issue view 5'
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "allows a non-gh command" {
    _run_hook "git status"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}
