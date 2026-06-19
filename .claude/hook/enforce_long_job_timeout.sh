#!/usr/bin/env bash
# .claude/hook/enforce_long_job_timeout.sh — Claude PreToolUse Bash hook.
#
# Long-running local jobs (full test suites, coverage/kcov, lint over the whole
# tree, image builds, compose service runs) must not be launched as an unbounded
# FOREGROUND command: if they hang, the session waits forever (this has happened
# — a lint run wedged for 54 min, a coverage run for 25 min). Enforce the
# two-safety pattern:
#
#   1. run_in_background: true   → the harness notifies on completion (and the
#      assistant can arm a Monitor watchdog), OR
#   2. timeout: <ms>             → the OS reaps a hung job at the deadline.
#
# A command that already wraps itself in `timeout`/`gtimeout` also passes.
# This hook BLOCKS (exit 2) a known-long foreground command that has neither,
# and tells the model to add the Bash `timeout` param or set run_in_background.
# (The PreToolUse hook contract here is exit-code based — it cannot rewrite the
# command — so "enforce" means block-with-guidance, not silent auto-wrap.)
#
# Exit codes:
#   0  → allow
#   2  → block (Claude shows stderr to the model)
#
# Per ADR-0007 this exit-code-contract hook defaults to `set -uo pipefail`.

set -uo pipefail

_stdin_payload="$(cat)"

_json_field() {
    # $1 = jq filter. Empty when jq is missing or the key is absent/null.
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "${_stdin_payload}" | jq -r "${1} // empty" 2>/dev/null
    fi
}

_cmd="$(_json_field '.tool_input.command')"
_bg="$(_json_field '.tool_input.run_in_background')"
_timeout="$(_json_field '.tool_input.timeout')"

# Nothing to inspect, or jq unavailable (cannot safely classify) — allow.
[[ -z "${_cmd}" ]] && exit 0

# Text-carrier whitelist: when the FIRST token is a command that merely PRINTS
# or searches text, trigger words like "just coverage" / "docker build" inside
# its arguments (commit messages, grep patterns, gh PR bodies) are data, not a
# launch. Mirrors the first-token guard in test-must-use-docker.sh. An
# env-prefixed real launch (e.g. `INIT_UBUNTU_LANG=x just coverage`) has a
# first token of `INIT_UBUNTU_LANG=x` — not whitelisted — so it still matches.
_first_tok="${_cmd%%[[:space:]]*}"
case "${_first_tok}" in
    git|gh|grep|egrep|fgrep|rg|ag|echo|printf|cat|sed|awk|jq|comm|diff|\
    sort|uniq|head|tail|tee|wc)
        exit 0 ;;
esac

# Safety 1: backgrounded — the harness notifies on completion.
[[ "${_bg}" == "true" ]] && exit 0

# Safety 2: an explicit positive Bash timeout param is set.
[[ "${_timeout}" =~ ^[0-9]+$ && "${_timeout}" -gt 0 ]] && exit 0

# Command already self-wraps in timeout/gtimeout — fine.
_re_self_wrap='(^|[[:space:]])g?timeout[[:space:]]'
[[ "${_cmd}" =~ ${_re_self_wrap} ]] && exit 0

# ── Known-long foreground command patterns ───────────────────────────────────
# Curated: full suites / coverage / kcov / whole-tree lint / image builds /
# compose service runs. Targeted single-spec runs (one *_spec.bats path) are
# fast and deliberately NOT matched (the bats pattern requires a '*' glob).
_long_patterns=(
    'just[[:space:]].*(coverage|test-unit|test-integration|lint)'
    'just[[:space:]].*[[:space:]]test([[:space:]]|$)'
    'bats[[:space:]].*test/(unit|integration)/\*'
    '(^|[[:space:]])kcov[[:space:]]'
    'docker[[:space:]]+build'
    'docker[[:space:]]+compose[[:space:]].*[[:space:]]run([[:space:]]|$)'
)

_is_long=0
for _re in "${_long_patterns[@]}"; do
    if [[ "${_cmd}" =~ ${_re} ]]; then
        _is_long=1
        break
    fi
done

[[ "${_is_long}" -eq 0 ]] && exit 0

printf '[hook:long-job-timeout] BLOCKED — long-running foreground command with no time bound.\n' >&2
printf '[hook:long-job-timeout] Command: %s\n' "${_cmd}" >&2
printf '[hook:long-job-timeout] Pick one (the two-safety pattern):\n' >&2
printf '[hook:long-job-timeout]   1. run_in_background: true   (harness notifies on completion; arm a Monitor watchdog)\n' >&2
printf '[hook:long-job-timeout]   2. set the Bash "timeout" param, e.g. 600000 (OS reaps a hang at the deadline)\n' >&2
printf '[hook:long-job-timeout] Self-wrapping the command with the timeout(1) utility also passes.\n' >&2
exit 2
