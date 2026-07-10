#!/usr/bin/env bash
# .agents/hook/test-must-use-docker.sh — Claude PreToolUse Bash hook.
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
#           { "type": "command", "command": ".claude/hook/test-must-use-docker.sh" }
#         ]
#       }
#     ]
#   }
#
# Template-first (ADR-0029): sources lib/hook_bootstrap.sh, which supplies
# set -uo pipefail, HOOK_NAME, hook_read_input, and the standard hook_allow
# (exit 0) / hook_block (exit 2, "[hook:<name>] BLOCKED — ...") decision paths.
# The command is extracted with a jq-or-sed fallback rather than the shared
# hook_command because this hook runs on the HOST, where jq may be absent.
#
# Exit codes:
#   0  -> allow
#   2  -> block (Claude shows stderr to model)

# shellcheck source=../../lib/hook_bootstrap.sh
source "${LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd -P)}/hook_bootstrap.sh"
hook_bootstrap "test-must-use-docker"

# Extract .tool_input.command from HOOK_INPUT. jq when available (it is in the
# test-tools image) but the hook runs on the host, so fall back to a tiny
# grep/sed parser when jq is missing. Not perfect (won't handle escaped quotes
# in the command itself) but adequate for the host-side use case.
_extract_cmd() {
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "${HOOK_INPUT}" | jq -r '.tool_input.command // empty'
        return
    fi
    printf '%s' "${HOOK_INPUT}" \
        | sed -n 's/.*"command":[[:space:]]*"\(\([^"\\]*\|\\.\)*\)".*/\1/p' \
        | head -n1
}

# _block <reason> — the ADR-0004 block, rendered in the repo's standard hook
# message shape via hook_block (exit 2). _cmd is a script global (below).
_block() {
    hook_block "${1}" \
        "Command: ${_cmd}" \
        "See doc/adr/0004-tests-must-run-in-docker-only.md" \
        "Use: just -f justfile.ci test-unit / test-integration / coverage"
}

main() {
    hook_read_input
    _cmd="$(_extract_cmd)"

    # Empty command (or non-Bash invocation that still routed here) — allow.
    [[ -z "${_cmd}" ]] && hook_allow

    # Whitelist: commands whose first token is a known-safe binary that never
    # runs Module Action Phases. This avoids false positives when commit
    # messages, git diff output, or grep arguments contain literal substrings
    # like "host bats" or "apt-get install".
    local _first_tok="${_cmd%%[[:space:]]*}"
    case "${_first_tok}" in
        git|gh|docker|just|grep|find|ls|cat|sed|awk|tr|sort|uniq|wc|head|tail|\
        cd|pwd|true|false|echo|printf|test|chmod|chown|mkdir|rm|cp|mv|ln|touch|\
        stat|file|which|command|type|tee|date|env|export|unset|history|jq|\
        python3|python|node|npm|pnpm|yarn|cargo|rustc|go|hadolint|shellcheck|\
        fish|fishtape|kcov|fc-cache|fc-list|sleep|wait|kill|ps|pgrep|pkill|\
        diff|patch|xargs|basename|dirname|realpath|readlink|tar|gzip|gunzip|\
        zip|unzip|7z|curl|wget)
            hook_allow ;;
    esac

    # 1. Direct bats invocation on host.
    if [[ "${_cmd}" =~ (^|[[:space:];|&])bats([[:space:]]|$) ]]; then
        _block "direct 'bats' on host — use 'just -f justfile.ci test-unit' instead"
    fi

    # 2. Module Action Phase on host (install / upgrade / remove / purge).
    #    Matches both 'bash module/foo.module.sh install' and direct './module/foo.module.sh install'.
    if [[ "${_cmd}" =~ (bash[[:space:]]+)?(\.?/)?module/[a-z0-9-]+\.module\.sh[[:space:]]+(install|upgrade|remove|purge) ]]; then
        _block "module Action Phase on host — use 'just -f justfile.ci test-unit' or 'docker compose run --rm ci ...'"
    fi

    # 3. Host apt install (only block 'install' — apt-get update / search are read-only).
    if [[ "${_cmd}" =~ sudo[[:space:]]+apt(-get)?[[:space:]]+(install|remove|purge|upgrade) ]]; then
        _block "host apt mutation — modules run inside Docker only"
    fi

    # 4. Bare `apt install` without sudo (unusual but caught for completeness).
    if [[ "${_cmd}" =~ (^|[[:space:];|&])apt-get[[:space:]]+(install|remove|purge|upgrade) ]]; then
        _block "host apt-get mutation — modules run inside Docker only"
    fi

    hook_allow
}

main "$@"
