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

# Safety 1: backgrounded — the harness notifies on completion.
[[ "${_bg}" == "true" ]] && exit 0

# Safety 2: an explicit positive Bash timeout param is set.
[[ "${_timeout}" =~ ^[0-9]+$ && "${_timeout}" -gt 0 ]] && exit 0

# ── Known-long foreground command patterns ───────────────────────────────────
# Curated: full suites / coverage / kcov / whole-tree lint / image builds /
# compose service runs. Targeted single-spec runs (one *_spec.bats path) are
# fast and deliberately NOT matched (the bats glob pattern requires a '*').
_long_patterns=(
    'just[[:space:]].*(coverage|test-unit|test-integration|test|lint)'
    '(^|[[:space:]])kcov([[:space:]]|$)'
    'docker[[:space:]]+build'
    'docker[[:space:]]+compose[[:space:]].*[[:space:]]run([[:space:]]|$)'
)

_is_long=0

# NOTE: a raw `docker run … -c 'bats test/unit/*.bats'` whole-suite run is NOT
# matched — the glob lives inside quotes that the quote-strip below removes, and
# checking it on the raw command false-positives on test data / commit messages
# that merely mention the pattern. The `just test-unit|coverage` recipes are the
# common full-suite path and ARE matched; a bare full-tree bats run is the rare
# gap (background it).

# Detection is PER SUB-COMMAND, on a QUOTE-STRIPPED copy. Long jobs are
# habitually prefixed with `cd <repo> && …`, so a whole-command first-token
# whitelist would either defeat the hook (whitelisting `cd`) or false-positive
# on trigger words / separators inside a `git commit -m "…; just coverage…"`
# message or a JSON test payload. So: drop quoted spans (where trigger words and
# stray separators hide), split the rest on the shell separators (; && || | and
# newlines), strip leading env-assignments / cd|sudo|env|command|time wrappers,
# skip pieces whose launcher merely carries text or self-wraps timeout, and
# pattern-match only the remaining real launches.
if [[ "${_is_long}" -eq 0 ]]; then
    _clean="$(printf '%s' "${_cmd}" | sed "s/'[^']*'//g; s/\"[^\"]*\"//g")"
    _clean="${_clean//&&/$'\n'}"
    _clean="${_clean//||/$'\n'}"
    _clean="${_clean//;/$'\n'}"
    _clean="${_clean//|/$'\n'}"

    while IFS= read -r _sub; do
        # Strip leading wrappers until stable.
        while :; do
            _before="${_sub#"${_sub%%[![:space:]]*}"}"   # left-trim
            _sub="${_before}"
            if [[ "${_sub}" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]] ]]; then
                _sub="${_sub#*[[:space:]]}"              # drop "VAR=val "
            else
                case "${_sub}" in
                    cd[[:space:]]*|sudo[[:space:]]*|env[[:space:]]*|command[[:space:]]*|time[[:space:]]*)
                        _sub="${_sub#*[[:space:]]}" ;;
                esac
            fi
            [[ "${_sub}" == "${_before}" ]] && break
        done

        # Self-wrapped timeout sub-command — bounded, skip.
        case "${_sub}" in timeout[[:space:]]*|gtimeout[[:space:]]*) continue ;; esac

        # Text-carrier launcher — its args are data, not a launch.
        case "${_sub%%[[:space:]]*}" in
            git|gh|grep|egrep|fgrep|rg|ag|echo|printf|cat|sed|awk|jq|comm|diff|\
            sort|uniq|head|tail|tee|wc) continue ;;
        esac

        for _re in "${_long_patterns[@]}"; do
            if [[ "${_sub}" =~ ${_re} ]]; then _is_long=1; break; fi
        done
        [[ "${_is_long}" -eq 1 ]] && break
    done <<< "${_clean}"
fi

[[ "${_is_long}" -eq 0 ]] && exit 0

printf '[hook:long-job-timeout] BLOCKED — long-running foreground command with no time bound.\n' >&2
printf '[hook:long-job-timeout] Command: %s\n' "${_cmd}" >&2
printf '[hook:long-job-timeout] Pick one (the two-safety pattern):\n' >&2
printf '[hook:long-job-timeout]   1. run_in_background: true   (harness notifies on completion; arm a Monitor watchdog)\n' >&2
printf '[hook:long-job-timeout]   2. set the Bash "timeout" param, e.g. 600000 (OS reaps a hang at the deadline)\n' >&2
printf '[hook:long-job-timeout] Self-wrapping the command with the timeout(1) utility also passes.\n' >&2
exit 2
