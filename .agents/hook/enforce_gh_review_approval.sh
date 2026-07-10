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
# Per-draft scoping (issue #34): approval is scoped to the CURRENT draft,
# not the whole session. One `approve issue` no longer authorizes every
# later `gh issue create` — after the agent has already run a
# `gh <kind> create|edit`, a fresh approval (post-dating that publish) is
# required for the next one. Otherwise a second, never-reviewed draft
# would ride in on a stale approval.
#
# Modules (each a function with a narrow stdin/stdout/exit contract so it
# can be exercised in isolation by bats):
#   - read_user_messages <transcript_path> [min_index]
#       Emits every user-typed text message (one per line) on a line whose
#       1-based index is > min_index (default 0 = whole transcript). Skips
#       tool_result entries (synthetic content, not user-typed). Missing
#       or unreadable file -> empty stdout.
#   - _last_publish_line_index <transcript_path> <kind>
#       The 1-based line index of the last assistant Bash tool_use that
#       already ran `gh <kind> create|edit` (the scoping boundary); 0 when
#       none. Per-kind, so an issue publish never resets a pr approval.
#   - is_review_approved <kind> <messages_text>
#       kind is `issue` or `pr`. Exit 0 if the text contains a matching
#       approval phrase (or the `skip review` escape hatch); exit 1
#       otherwise.
#   - main
#       Orchestrates the above against PreToolUse JSON stdin: computes the
#       per-draft boundary, reads only the approvals after it, decides.
#
# Output contract (per ADR-0007 exit-code-contract convention):
#   - allow  -> exit 0, no stdout
#   - deny   -> exit 0, emit permissionDecision JSON on stdout
#
# Bypass: ECC_ALLOW_GH_REVIEW=1 env var -> allow silently (leaves an
# audit trail in shell history).

set -uo pipefail

# ── read_user_messages ───────────────────────────────────────────────────────
# Args: $1 = transcript_path, $2 = min_index (optional, default 0).
# Stdout: every user-typed text message on a transcript line whose 1-based
# index is STRICTLY GREATER than min_index, one per line, in file order.
# Algorithm: scan JSONL for entries where `.type == "user"` AND
# `.message.role == "user"` AND `.message.content` is either a plain
# string or an array containing `type:"text"` block(s) (NOT tool_result,
# which is synthetic). Concatenate the text blocks of each entry.
#
# min_index implements per-draft scoping (issue #34): approvals that
# predate the boundary line (the last `gh <kind> create|edit` the agent
# already ran) are ignored, so one approval cannot authorize a later,
# separately-drafted publish. min_index == 0 -> whole transcript.
read_user_messages() {
    local transcript_path="${1:-}"
    local min_index="${2:-0}"
    [[ -z "${transcript_path}" ]] && return 0
    [[ ! -r "${transcript_path}" ]] && return 0

    local line text idx=0
    while IFS= read -r line; do
        idx=$((idx + 1))
        (( idx <= min_index )) && continue
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

# ── _last_publish_line_index ─────────────────────────────────────────────────
# Args: $1 = transcript_path, $2 = kind (issue|pr).
# Stdout: the 1-based transcript line index of the LAST assistant Bash
# tool_use that already invoked `gh <kind> create|edit` (the boundary
# after which a fresh approval is required); `0` when there is none, the
# file is missing/unreadable, or the args are empty.
#
# Rationale (issue #34, per-draft review): without a boundary, a single
# `approve issue` earlier in the session would authorize every later
# `gh issue create` — including a different, never-reviewed draft. The
# current (about-to-run) command is NOT in the transcript yet (PreToolUse
# fires before execution), so only PRIOR publishes are counted. The
# boundary is per-kind so an issue publish never invalidates a pr
# approval (and vice versa).
_last_publish_line_index() {
    local transcript_path="${1:-}"
    local kind="${2:-}"
    if [[ -z "${transcript_path}" || -z "${kind}" || ! -r "${transcript_path}" ]]; then
        printf '0'
        return 0
    fi

    local line idx=0 last=0 cmd
    while IFS= read -r line; do
        idx=$((idx + 1))
        cmd="$(printf '%s' "${line}" | jq -r '
            select(.type == "assistant")
            | .message.content
            | if type == "array" then
                  ( map(select(.type == "tool_use" and .name == "Bash")
                        | .input.command // empty) | join("\n") )
              else empty
              end
        ' 2>/dev/null)"
        [[ -z "${cmd}" ]] && continue
        [[ "$(_triggering_kind "${cmd}")" == "${kind}" ]] && last=${idx}
    done < "${transcript_path}"
    printf '%s' "${last}"
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

    local transcript_path boundary messages
    transcript_path="$(printf '%s' "${input}" | jq -r '.transcript_path // empty' 2>/dev/null)"
    # Per-draft scoping: only approvals AFTER the last `gh <kind> create|edit`
    # the agent already ran count for the current publish (issue #34).
    boundary="$(_last_publish_line_index "${transcript_path}" "${kind}")"
    messages="$(read_user_messages "${transcript_path}" "${boundary}")"

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
