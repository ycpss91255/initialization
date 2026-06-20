#!/usr/bin/env bash
# remind_no_emoji.sh — Claude Code UserPromptSubmit hook.
#
# Standing rule so the maintainer does not have to repeat it: never use emoji
# anywhere — chat replies, commit messages, PR / issue titles + bodies +
# comments, code, and docs. A hook cannot inspect the agent's chat prose, so
# this keeps the rule in context every turn; the gh-side artifacts are also
# hard-enforced by enforce_gh_english.sh (which blocks emoji in PR/issue/
# comment titles + bodies).
#
# Non-blocking: emits hookSpecificOutput.additionalContext only, always exit 0.

set -uo pipefail

main() {
  cat >/dev/null 2>&1 || true   # consume the stdin prompt payload

  local msg
  msg="Standing style rule (maintainer, do not re-ask): NEVER use emoji anywhere — not in chat replies, commit messages, PR/issue titles or bodies, comments, code, or docs. Plain text only. (Functional symbols like arrows or box-drawing in TUI output are fine; decorative emoji are not.)"

  jq -n --arg m "${msg}" '{
    hookSpecificOutput: {
      hookEventName: "UserPromptSubmit",
      additionalContext: $m
    }
  }'
  return 0
}

main "$@"
