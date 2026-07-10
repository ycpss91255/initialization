#!/usr/bin/env bash
# remind_workflow_tdd.sh — Claude Code UserPromptSubmit hook.
#
# Standing reminder so the maintainer does NOT have to repeat it each prompt:
# when a task decomposes into independent pieces, default to the Workflow tool
# with worktree isolation + TDD for the parallel implementation, then integrate
# and PR serially (dual-watch). The hook can only REMIND — choosing to fan out
# is the agent's judgment; this keeps the directive in context every turn.
#
# Template-first (ADR-0029): sources lib/hook_bootstrap.sh and injects the
# directive via hook_context — the standard non-blocking additionalContext path
# (always exit 0). additionalContext (not systemMessage) so it informs the agent
# without adding user-facing chat noise. The stdin prompt payload is read (and
# ignored).

# shellcheck source=../../lib/hook_bootstrap.sh
source "${LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd -P)}/hook_bootstrap.sh"
hook_bootstrap "remind-workflow-tdd"

main() {
  hook_read_input   # consume the stdin prompt payload (its content is ignored)

  hook_context \
    "Standing workflow directive (maintainer, do not re-ask): when work splits into independent pieces, DEFAULT to the Workflow tool with worktree isolation + TDD (red-green-refactor; tests run in Docker only) for the parallel implementation, then integrate/PR serially with dual-watch (auto-merge Monitor + an independent background watchdog). Scale agent count to the work. Solo (no workflow) only for trivial or conversational turns. Don't wait to be told." \
    "UserPromptSubmit"
}

main "$@"
