#!/usr/bin/env bash
# remind_pr_wait_ci.sh — Claude Code PreToolUse hook (matcher: Bash)
#
# Fires before any Bash command. When the command opens a GitHub PR
# (`gh pr create ...`), emit a JSON systemMessage reminding to use the
# /wait-pr-ci skill instead of sleep-polling. Non-blocking (always exit 0).
#
# Why: docs/processes/release.md (CI monitoring)明文要求用 wait-pr-ci skill；
# 過去常見錯誤是 PR 開完後直接 `sleep 60 && gh pr checks` 輪詢，會把
# context 噴爆且 agent 被 sleep 卡住。
#
# Trigger pattern: `gh pr create` 出現在 command 任一段（含 chained `&&`）。

set -uo pipefail

main() {
  local input cmd msg
  input="$(cat)"
  cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null)"

  [[ -z "${cmd}" ]] && return 0

  [[ "${cmd}" =~ gh[[:space:]]+pr[[:space:]]+create ]] || return 0

  msg="PR open 提醒：開完別用 sleep 輪詢 — 用 /wait-pr-ci skill（.claude/skills/wait-pr-ci/SKILL.md）。內部用 Monitor + until poll 30s，不會 burn context。"

  jq -n --arg m "${msg}" '{
    systemMessage: $m,
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      additionalContext: $m
    }
  }'

  return 0
}

main "$@"
