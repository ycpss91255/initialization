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

  # Dual-watch reminder: a hook can only REMIND — the agent still arms both,
  # because the notifying watchers (Monitor / background Bash) are agent tools a
  # short-lived hook cannot invoke. Appended to the PR / auto-merge reminders.
  local watchdog=" Second safety (dual-watch): besides the auto-merge Monitor, arm an INDEPENDENT watchdog via a run_in_background Bash that polls this PR's state (exits on MERGED/CLOSED or a ~28-min timeout), so a silently-dead primary Monitor never strands the loop. The two are independent."

  if [[ "${cmd}" =~ gh[[:space:]]+pr[[:space:]]+create ]]; then
    msg="PR opened — do NOT sleep-poll. Run the auto-merge-on-green skill (.claude/skills/auto-merge-on-green/SKILL.md): it arms GitHub-native auto-merge (--auto --squash --delete-branch) and Monitor-wraps .claude/script/auto-merge-on-green.sh — a green CI merges server-side, BEHIND auto-updates the branch, a CI failure is reported with auto-merge left armed.${watchdog}"
  elif [[ "${cmd}" =~ git[[:space:]]+push ]]; then
    if [[ "${cmd}" =~ (--tags|refs/tags/|[[:space:]]v[0-9]) ]]; then
      msg="This push may trigger release CI — watch it via the wait-pr-ci skill's tag flow (.claude/script/wait-tag-ci.sh) with a Monitor, do NOT sleep-poll. A tag has no PR, so no auto-merge."
    else
      msg="This push may (re)trigger CI — if the branch has a PR, run the auto-merge-on-green skill (handles auto-merge + BEHIND); otherwise watch via the wait-pr-ci skill with a Monitor. Do NOT sleep-poll.${watchdog}"
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
