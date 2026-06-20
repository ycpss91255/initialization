#!/usr/bin/env bash
# remind_workflow_tdd.sh — Claude Code UserPromptSubmit hook.
#
# Standing reminder so the maintainer does NOT have to repeat it each prompt:
# when a task decomposes into independent pieces, default to the Workflow tool
# with worktree isolation + TDD for the parallel implementation, then integrate
# and PR serially (dual-watch). The hook can only REMIND — choosing to fan out
# is the agent's judgment; this keeps the directive in context every turn.
#
# Non-blocking: emits hookSpecificOutput.additionalContext only, always exit 0.
# additionalContext (not systemMessage) so it informs the agent without adding
# user-facing chat noise.

set -uo pipefail

main() {
  cat >/dev/null 2>&1 || true   # consume the stdin prompt payload; unconditional inject

  local msg
  msg="Standing workflow directive (maintainer, do not re-ask): when work splits into independent pieces, DEFAULT to the Workflow tool with worktree isolation + TDD (red-green-refactor; tests run in Docker only) for the parallel implementation, then integrate/PR serially with dual-watch (auto-merge Monitor + an independent background watchdog). Scale agent count to the work. Solo (no workflow) only for trivial or conversational turns. Don't wait to be told."

  jq -n --arg m "${msg}" '{
    hookSpecificOutput: {
      hookEventName: "UserPromptSubmit",
      additionalContext: $m
    }
  }'
  return 0
}

main "$@"
