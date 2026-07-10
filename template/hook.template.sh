#!/usr/bin/env bash
# template/hook.template.sh — skeleton for a Claude Code hook (.claude/hook/<n>.sh)
#
# ── When to use this template ────────────────────────────────────────────────
#   Use this for a Claude Code hook — a small exit-code-contract script that
#   Claude runs before/after a tool call (PreToolUse / PostToolUse / Stop /
#   UserPromptSubmit). It reads the event JSON on stdin, decides, and reports
#   the decision through its exit code: 0 = allow, 2 = block. Real hooks live in
#   .agents/hook/ and are symlinked into .claude/hook/ (edit the .agents copy).
#
# ── What the shared bootstrap gives you (lib/hook_bootstrap.sh) ───────────────
#   Sourcing lib/hook_bootstrap.sh + calling hook_bootstrap establishes, with
#   near-zero boilerplate:
#     * `set -uo pipefail` — the ADR-0007 exit-code-CONTRACT family (NOT -e):
#       Claude reads the exit code, and a conditional probe (`[[ ]]`, `grep -q`,
#       a regex match) may legitimately return 1 without aborting the decision.
#       (Contrast the ALWAYS-ACT tools on -euo, served by lib/tool_bootstrap.sh.)
#     * hook_read_input / hook_field / hook_command — read the stdin JSON once
#       and pull fields out with jq (empty when absent).
#     * hook_allow  — the standard pass path (exit 0).
#     * hook_block  — the standard block path: "[hook:<name>] BLOCKED — ..." to
#       stderr + exit 2, in the repo's existing hook message style.
#     * hook_context — non-blocking additionalContext injection (reminder hooks).
#
# ── Authoring steps ──────────────────────────────────────────────────────────
#   1. cp template/hook.template.sh .agents/hook/<your-name>.sh  (kebab-case)
#   2. Pass your hook name to hook_bootstrap (drives the block-message prefix).
#   3. Replace the decision in main() with your rule; keep hook_allow last.
#   4. Wire it in .claude/settings.local.json under the right event/matcher.
#   5. cp template/test-hook.template.bats test/unit/hook/<name>_spec.bats and
#      adapt the allow (exit 0) + block (exit 2 + message) cases.
#   6. Run: just -f justfile.ci test-unit   (Docker-only; ADR-0004)

# Locate + load the shared hook bootstrap. LIB_DIR / REPO_ROOT env overrides let
# a test point at the real lib; the fallback walks up from a real hook's own dir
# (.agents/hook/ or .claude/hook/ -> ../../lib).
# shellcheck source=../lib/hook_bootstrap.sh
source "${LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd -P)}/hook_bootstrap.sh"
hook_bootstrap "hook-template"

main() {
    hook_read_input
    local cmd
    cmd="$(hook_command)"

    # Nothing to inspect (empty command, or a non-Bash tool routed here): allow.
    [[ -z "${cmd}" ]] && hook_allow

    # Reference decision: block a banned pattern, otherwise allow. REPLACE the
    # pattern + reason with your rule. Keep the hook_allow fall-through LAST so
    # the default is to permit.
    if [[ "${cmd}" =~ (^|[[:space:]\;\|\&])banned-command([[:space:]]|$) ]]; then
        hook_block "banned-command is not permitted here" \
                   "Use the approved alternative instead."
    fi

    hook_allow
}

main "$@"
