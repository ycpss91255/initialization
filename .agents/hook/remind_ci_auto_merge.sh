#!/usr/bin/env bash
# remind_ci_auto_merge.sh — Claude Code PreToolUse hook (matcher: Bash).
#
# Fires before any Bash command. When the command can trigger CI, inject a
# non-blocking systemMessage telling the agent to MONITOR CI (and, when a PR
# is involved, drive GitHub-native auto-merge) instead of sleep-polling.
#
# The hook only DETECTS + INSTRUCTS. It cannot itself run a Monitor or merge:
# Claude Code hooks are synchronous, short-lived shell scripts. The actual
# monitoring + auto-merge is done by the agent via the auto-merge-on-green /
# wait-pr-ci skills. Refs #154 (supersedes remind_pr_wait_ci.sh).
#
# Triggers + injected instruction:
#   - `gh pr create`      -> run the auto-merge-on-green skill (arm GitHub
#                            native auto-merge + Monitor-wrap
#                            .claude/script/auto-merge-on-green.sh).
#   - `git push` (tag)    -> monitor release CI via wait-tag-ci; no PR to merge.
#   - `git push` (branch) -> if the branch has a PR, auto-merge-on-green;
#                            else monitor via wait-pr-ci. The skill resolves
#                            which at run time.
#
# Non-blocking: always exit 0 (emit additionalContext, never deny).

set -uo pipefail

main() {
  local input cmd msg=""
  input="$(cat)"
  cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  [[ -z "${cmd}" ]] && return 0

  if [[ "${cmd}" =~ gh[[:space:]]+pr[[:space:]]+create ]]; then
    msg="PR open 提醒：別 sleep 輪詢。開完跑 auto-merge-on-green skill（.claude/skills/auto-merge-on-green/SKILL.md）—— 它掛上 GitHub 原生 auto-merge（--auto --squash --delete-branch）並用一個 Monitor 包 .claude/script/auto-merge-on-green.sh：CI 綠由 GitHub 伺服器端自動合,BEHIND 自動 update-branch,CI 失敗只回報且 auto 保留掛著。"
  elif [[ "${cmd}" =~ git[[:space:]]+push ]]; then
    if [[ "${cmd}" =~ (--tags|refs/tags/|[[:space:]]v[0-9]) ]]; then
      msg="push 可能觸發 release CI：用 wait-pr-ci skill 的 tag 流程（.claude/script/wait-tag-ci.sh）以 Monitor 監控,別 sleep 輪詢。tag 無 PR,不 auto-merge。"
    else
      msg="push 可能觸發/重跑 CI：若該分支已有對應 PR,跑 auto-merge-on-green skill（處理 auto-merge + BEHIND）;否則用 wait-pr-ci skill 以 Monitor 監控。別 sleep 輪詢。"
    fi
  else
    return 0
  fi

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
