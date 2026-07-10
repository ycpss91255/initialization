#!/usr/bin/env bash
# lib/hook_bootstrap.sh — shared bootstrap for Claude hooks (.claude/hook/<n>.sh).
#
# Every hook used to re-implement the same plumbing: read the tool-call JSON
# from stdin, extract .tool_input.command with jq, then either fall through to
# `exit 0` (allow) or print a "[hook:<name>] BLOCKED — ..." line to stderr and
# `exit 2` (block). This centralizes that plumbing so a hook collapses to:
# source this bootstrap, read its input, decide, call hook_allow / hook_block.
#
# Family (ADR-0007): hooks are EXIT-CODE-CONTRACT scripts — Claude Code reads
# the exit code (0=allow, 2=block) to decide. So hook_bootstrap uses
# `set -uo pipefail` (NOT -e): a conditional probe (`[[ ]]`, `grep -q`, a regex
# match) legitimately returns 1 without aborting the decision flow. (Contrast
# the ALWAYS-ACT tools served by lib/tool_bootstrap.sh, which use -euo.)
#
# Public API (all prefixed `hook_`):
#   hook_bootstrap [name]   set -uo pipefail + LIB_DIR/REPO_ROOT + HOOK_NAME
#   hook_read_input         read the stdin JSON payload once into HOOK_INPUT
#   hook_field <jq-filter>  echo a field of HOOK_INPUT via jq (empty if absent)
#   hook_command            shorthand for the Bash tool's .tool_input.command
#   hook_allow              standard pass path: exit 0
#   hook_block <reason>...   standard block path: "[hook:<name>] BLOCKED" + exit 2
#   hook_context <msg> [ev] non-blocking: emit additionalContext JSON + exit 0
#
# Self-location mirrors lib/tool_bootstrap.sh: LIB_DIR is derived from this
# file's own ${BASH_SOURCE[0]}; env LIB_DIR/REPO_ROOT take precedence. No side
# effects at source time beyond declaring the two state globals — call
# hook_bootstrap.

# Standard library guard: refuse to run as an executable script.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    printf "Warn: %s is a library, not an executable script.\n" "${BASH_SOURCE[0]##*/}"
    printf "Source it from a hook, e.g.: source \"%s\"\n" "${BASH_SOURCE[0]:-}"
    return 0 2>/dev/null
fi

# State: the hook's display name (for block messages) and the raw stdin payload.
HOOK_NAME="${HOOK_NAME:-hook}"
HOOK_INPUT="${HOOK_INPUT:-}"

# hook_bootstrap [name] — exit-code-contract strict mode + path resolution.
#   1. set -uo pipefail (deliberately NOT -e, per ADR-0007).
#   2. Resolve + export LIB_DIR (self-located) and REPO_ROOT (env override wins).
#   3. Record HOOK_NAME (arg, else the script basename minus .sh) for the
#      "[hook:<name>] ..." message prefix used by hook_block.
hook_bootstrap() {
    set -uo pipefail

    local _self_lib
    _self_lib="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-}")" && pwd -P)"
    LIB_DIR="${LIB_DIR:-${_self_lib}}"
    REPO_ROOT="${REPO_ROOT:-$(cd -- "${LIB_DIR}/.." && pwd -P)}"
    export LIB_DIR REPO_ROOT

    local _name="${1:-}"
    if [[ -z "${_name}" ]]; then
        _name="${0##*/}"
        _name="${_name%.sh}"
    fi
    HOOK_NAME="${_name}"
}

# hook_read_input — read the hook JSON payload from stdin ONCE into HOOK_INPUT.
hook_read_input() {
    HOOK_INPUT="$(cat)"
}

# hook_field <jq-filter> — echo a field of HOOK_INPUT resolved by jq, or empty
# when jq is missing or the field is absent/null. Never aborts the caller.
# <jq-filter> is a jq path expression, e.g. '.tool_input.command' or '.cwd'.
hook_field() {
    local _filter="${1:?hook_field needs <jq-filter>}"
    command -v jq >/dev/null 2>&1 || return 0
    printf '%s' "${HOOK_INPUT}" | jq -r "${_filter} // empty" 2>/dev/null
}

# hook_command — shorthand for the Bash tool's command string.
hook_command() {
    hook_field '.tool_input.command'
}

# hook_allow — the standard pass path: exit 0 so Claude proceeds with the tool.
hook_allow() {
    exit 0
}

# hook_block <reason> [detail ...] — the standard block path. Print the
# repo-standard "[hook:<name>] BLOCKED — <reason>" plus any extra detail lines
# to stderr, then exit 2 (Claude shows stderr to the model and denies the tool).
hook_block() {
    local _reason="${1:?hook_block needs <reason>}"
    shift || true
    printf '[hook:%s] BLOCKED — %s\n' "${HOOK_NAME}" "${_reason}" >&2
    local _line
    for _line in "$@"; do
        printf '[hook:%s] %s\n' "${HOOK_NAME}" "${_line}" >&2
    done
    exit 2
}

# hook_context <message> [event-name] — the standard non-blocking path: emit a
# hookSpecificOutput.additionalContext JSON object (event-name default
# PreToolUse) and exit 0. For reminder hooks that inject context without
# deciding allow/block.
hook_context() {
    local _msg="${1:?hook_context needs <message>}"
    local _event="${2:-PreToolUse}"
    jq -n --arg m "${_msg}" --arg e "${_event}" '{
        hookSpecificOutput: { hookEventName: $e, additionalContext: $m }
    }'
    exit 0
}
