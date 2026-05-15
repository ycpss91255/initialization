#!/usr/bin/env bash
# script/hook/test-must-use-docker.sh — Claude PreToolUse Bash hook.
#
# Enforces ADR-0004: tests / Module Action Phases MUST run in Docker, never
# on the host. This hook receives the Bash tool input as JSON on stdin and
# blocks (exit 2) any command that matches a host-side dangerous pattern.
#
# Wired in via .claude/settings.local.json:
#   "hooks": {
#     "PreToolUse": [
#       {
#         "matcher": "Bash",
#         "hooks": [
#           { "type": "command", "command": "script/hook/test-must-use-docker.sh" }
#         ]
#       }
#     ]
#   }
#
# Exit codes:
#   0  → allow
#   2  → block (Claude shows stderr to model)

set -euo pipefail

# Read JSON from stdin; extract tool_input.command. jq is in test-tools image
# but the hook runs on host, so fall back to a tiny grep/sed if jq missing.
_extract_cmd() {
    local _stdin="$1"
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "${_stdin}" | jq -r '.tool_input.command // empty'
        return
    fi
    # Minimal fallback parser. Not perfect (won't handle escaped quotes in
    # the command itself) but adequate for the host-side use case.
    printf '%s' "${_stdin}" \
        | sed -n 's/.*"command":[[:space:]]*"\(\([^"\\]*\|\\.\)*\)".*/\1/p' \
        | head -n1
}

_stdin_payload="$(cat)"
_cmd="$(_extract_cmd "${_stdin_payload}")"

# Empty command (or non-Bash invocation that still routed here) — allow.
[[ -z "${_cmd}" ]] && exit 0

# Whitelist: commands whose first token is a known-safe binary that never
# runs Module Action Phases. This avoids false positives when commit
# messages, git diff output, or grep arguments contain literal substrings
# like "host bats" or "apt-get install".
_first_tok="${_cmd%%[[:space:]]*}"
case "${_first_tok}" in
    git|gh|docker|make|grep|find|ls|cat|sed|awk|tr|sort|uniq|wc|head|tail|\
    cd|pwd|true|false|echo|printf|test|chmod|chown|mkdir|rm|cp|mv|ln|touch|\
    stat|file|which|command|type|tee|date|env|export|unset|history|jq|\
    python3|python|node|npm|pnpm|yarn|cargo|rustc|go|hadolint|shellcheck|\
    fish|fishtape|kcov|fc-cache|fc-list|sleep|wait|kill|ps|pgrep|pkill|\
    diff|patch|xargs|basename|dirname|realpath|readlink|tar|gzip|gunzip|\
    zip|unzip|7z|curl|wget)
        exit 0 ;;
esac

# ── Block patterns ──────────────────────────────────────────────────────────
_block() {
    local _reason="$1"
    printf '[hook:test-must-use-docker] BLOCKED — %s\n' "${_reason}" >&2
    printf '[hook:test-must-use-docker] Command: %s\n' "${_cmd}" >&2
    printf '[hook:test-must-use-docker] See doc/adr/0004-tests-must-run-in-docker-only.md\n' >&2
    printf '[hook:test-must-use-docker] Use: make test-unit / make test-integration / make coverage\n' >&2
    exit 2
}

# 1. Direct bats invocation on host.
if [[ "${_cmd}" =~ (^|[[:space:];|&])bats([[:space:]]|$) ]]; then
    _block "direct 'bats' on host — use 'make test-unit' instead"
fi

# 2. Module Action Phase on host (install / upgrade / remove / purge).
#    Matches both 'bash module/foo.module.sh install' and direct './module/foo.module.sh install'.
if [[ "${_cmd}" =~ (bash[[:space:]]+)?(\.?/)?module/[a-z0-9-]+\.module\.sh[[:space:]]+(install|upgrade|remove|purge) ]]; then
    _block "module Action Phase on host — use 'make test-unit' or 'docker compose run --rm ci ...'"
fi

# 3. Host apt install (only block 'install' — apt-get update / search are read-only).
if [[ "${_cmd}" =~ sudo[[:space:]]+apt(-get)?[[:space:]]+(install|remove|purge|upgrade) ]]; then
    _block "host apt mutation — modules run inside Docker only"
fi

# 4. Bare `apt install` without sudo (unusual but caught for completeness).
if [[ "${_cmd}" =~ (^|[[:space:];|&])apt-get[[:space:]]+(install|remove|purge|upgrade) ]]; then
    _block "host apt-get mutation — modules run inside Docker only"
fi

exit 0
