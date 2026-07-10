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
# Template-first (ADR-0029): sources lib/hook_bootstrap.sh and injects the rule
# via hook_context — the standard non-blocking additionalContext path (always
# exit 0). The stdin prompt payload is read (and ignored).

# shellcheck source=../../lib/hook_bootstrap.sh
source "${LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd -P)}/hook_bootstrap.sh"
hook_bootstrap "remind-no-emoji"

main() {
    hook_read_input   # consume the stdin prompt payload (its content is ignored)

    hook_context \
        "Standing style rule (maintainer, do not re-ask): NEVER use emoji anywhere — not in chat replies, commit messages, PR/issue titles or bodies, comments, code, or docs. Plain text only. (Functional symbols like arrows or box-drawing in TUI output are fine; decorative emoji are not.)" \
        "UserPromptSubmit"
}

main "$@"
