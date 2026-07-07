#!/usr/bin/env bash
# enforce_gh_review_approval.sh -- Claude Code PreToolUse hook (matcher: Bash).
#
# DENIES `gh issue create|edit` and `gh pr create|edit` unless the user
# has explicitly approved the drafted content in the session transcript.
#
# Rationale (issue #34): the agent used to jump straight to
# `gh issue create` / `gh pr create` after drafting the body in English,
# so the user never saw the draft before it landed on a public, indexed
# repo. `enforce_gh_english.sh` only enforces that the body is English;
# it does not enforce that the user approved the content. This hook makes
# the review step enforceable, the same way
# `enforce_shellcheck_disable_approval.sh` requires `approve SC<code>`.
#
# Desired flow (also documented in
# .agents/rules/common/development-workflow.md):
#   1. Agent writes a draft in the user's working language (zh-TW) to a
#      local file, e.g. /tmp/<slug>.zh.md.
#   2. Agent shows the path / a short summary to the user for review.
#   3. After the user approves, the agent translates to English.
#   4. Agent runs `gh issue create` / `gh pr create` with the English
#      `--body-file`.
#
# Approval phrases (case-insensitive, any one is enough):
#   - `approve issue` / `issue ok`   -> authorizes gh issue create|edit
#   - `approve pr`    / `pr ok`      -> authorizes gh pr    create|edit
#   - `skip review`                  -> the escape hatch; authorizes both
#     (the user explicitly opting out of the review step)
# The canonical tokens stay English so the check is locale-agnostic;
# locale equivalents may be layered on later.
#
# Modules (each a function with a narrow stdin/stdout/exit contract so it
# can be exercised in isolation by bats):
#   - read_user_messages <transcript_path>
#       Emits every user-typed text message (one per line). Skips
#       tool_result entries (synthetic content, not user-typed). Missing
#       or unreadable file -> empty stdout.
#   - is_review_approved <kind> <messages_text>
#       kind is `issue` or `pr`. Exit 0 if the text contains a matching
#       approval phrase (or the `skip review` escape hatch); exit 1
#       otherwise.
#   - main
#       Orchestrates the two above against PreToolUse JSON stdin.
#
# Output contract (per ADR-0007 exit-code-contract convention):
#   - allow  -> exit 0, no stdout
#   - deny   -> exit 0, emit permissionDecision JSON on stdout
#
# Bypass: ECC_ALLOW_GH_REVIEW=1 env var -> allow silently (leaves an
# audit trail in shell history).

set -uo pipefail

# ── read_user_messages ───────────────────────────────────────────────────────
# Args: $1 = transcript_path. Stdout: every user-typed text message, one
# per line, in file order.
# Algorithm: scan JSONL for entries where `.type == "user"` AND
# `.message.role == "user"` AND `.message.content` is either a plain
# string or an array containing `type:"text"` block(s) (NOT tool_result,
# which is synthetic). Concatenate the text blocks of each entry.
read_user_messages() {
    local transcript_path="${1:-}"
    [[ -z "${transcript_path}" ]] && return 0
    [[ ! -r "${transcript_path}" ]] && return 0

    local line text
    while IFS= read -r line; do
        text="$(printf '%s' "${line}" | jq -r '
            select(.type == "user")
            | select(.message.role == "user")
            | .message.content
            | if type == "string" then .
              elif type == "array" then
                  ( map(select(.type == "text") | .text) | join(" ") )
              else empty
              end
        ' 2>/dev/null)"
        [[ -n "${text}" ]] && printf '%s\n' "${text}"
    done < "${transcript_path}"
    return 0
}

# ── is_review_approved ───────────────────────────────────────────────────────
# Args: $1 = kind (issue|pr), $2 = messages_text.
# Exit 0 if approved, 1 otherwise. Matching is case-insensitive and
# treats the whole text as one flattened line so phrases split across
# messages still match at word boundaries.
is_review_approved() {
    local kind="${1:-}"
    local msg="${2:-}"
    [[ -z "${kind}" || -z "${msg}" ]] && return 1

    local flat
    flat="$(printf '%s' "${msg}" | tr '[:upper:]' '[:lower:]' | tr '\n' ' ')"

    # `skip review` is the explicit opt-out; it authorizes either kind.
    if printf '%s' "${flat}" \
         | grep -qE '(^|[^[:alnum:]_])skip[[:space:]]+review([^[:alnum:]_]|$)'; then
        return 0
    fi

    local pattern
    case "${kind}" in
        issue)
            pattern='(^|[^[:alnum:]_])(approve[[:space:]]+issue|issue[[:space:]]+ok)([^[:alnum:]_]|$)'
            ;;
        pr)
            pattern='(^|[^[:alnum:]_])(approve[[:space:]]+pr|pr[[:space:]]+ok)([^[:alnum:]_]|$)'
            ;;
        *)
            return 1
            ;;
    esac

    if printf '%s' "${flat}" | grep -qE "${pattern}"; then
        return 0
    fi
    return 1
}

# ── main ─────────────────────────────────────────────────────────────────────

_emit_deny() {
    local reason="$1"
    jq -n --arg m "${reason}" '{
        systemMessage: $m,
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: $m
        }
    }'
}

# Detect the triggering gh subcommand. Echoes `issue` or `pr` on a match,
# empty otherwise.
_triggering_kind() {
    local cmd="$1"
    if [[ "${cmd}" =~ (^|[[:space:]\;\|\&]|\$\()[[:space:]]*gh[[:space:]]+issue[[:space:]]+(create|edit)([[:space:]]|$) ]]; then
        printf 'issue'
    elif [[ "${cmd}" =~ (^|[[:space:]\;\|\&]|\$\()[[:space:]]*gh[[:space:]]+pr[[:space:]]+(create|edit)([[:space:]]|$) ]]; then
        printf 'pr'
    fi
}

main() {
    if [[ "${ECC_ALLOW_GH_REVIEW:-}" == "1" ]]; then
        return 0
    fi

    local input cmd
    input="$(cat)"
    [[ -z "${input}" ]] && return 0
    cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    [[ -z "${cmd}" ]] && return 0

    local kind
    kind="$(_triggering_kind "${cmd}")"
    [[ -z "${kind}" ]] && return 0

    local transcript_path messages
    transcript_path="$(printf '%s' "${input}" | jq -r '.transcript_path // empty' 2>/dev/null)"
    messages="$(read_user_messages "${transcript_path}")"

    if is_review_approved "${kind}" "${messages}"; then
        return 0
    fi

    local phrase
    if [[ "${kind}" == "issue" ]]; then
        phrase="\`approve issue\` / \`issue ok\`"
    else
        phrase="\`approve pr\` / \`pr ok\`"
    fi

    local reason="GitHub review approval required (issue #34, hook source: .claude/hook/enforce_gh_review_approval.sh).

A \`gh ${kind} create|edit\` was attempted but the user has not approved the drafted content in this session's transcript.

Expected flow (per .claude/rules/common/development-workflow.md):
  1. Write the draft in the user's working language (zh-TW) to a local
     file, e.g. /tmp/<slug>.zh.md.
  2. Show the path / a short summary and ask the user to review it.
  3. After approval, translate the approved content to English.
  4. Re-run \`gh ${kind} create|edit\` with the English --body-file.

To approve, the user says one of (case-insensitive): ${phrase}. The
user may also say \`skip review\` to opt out for either kind. Approval is
read from the session transcript -- it cannot be forged. English
enforcement (enforce_gh_english.sh) still runs after approval.

Emergency bypass: ECC_ALLOW_GH_REVIEW=1 env var (leaves an audit trail
in shell history)."

    _emit_deny "${reason}"
    return 0
}

# Only run main when this script is the entrypoint. Allows bats specs to
# `source` the file and exercise individual functions in isolation.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
