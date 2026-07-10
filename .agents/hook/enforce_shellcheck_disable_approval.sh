#!/usr/bin/env bash
# enforce_shellcheck_disable_approval.sh -- Claude Code PreToolUse hook
# (matcher: Edit | Write | MultiEdit).
#
# Gates the introduction of new `# shellcheck disable=SC<code>` directives.
# Blocks (permissionDecision: deny) any Edit / Write / MultiEdit that
# adds a disable code which has not been explicitly approved by the user
# in their most recent message via the phrase `approve SC<code>`.
#
# Rationale: PR #4 established the discipline ("consult
# https://www.shellcheck.net/wiki/SC<code> first; proper fix preferred;
# every disable carries wiki-link rationale") but relied on self-
# discipline. This hook makes the discipline enforceable. See issue #17
# for the PRD and ADR-0007 for the exit-code-contract convention this
# script follows.
#
# Modules (each is internally a function with a narrow stdin/stdout/exit
# contract so it can be tested in isolation by bats):
#   - read_latest_user_message <transcript_path>
#       Emits the latest user-typed text message to stdout. Skips
#       tool_result entries (synthetic content, not user-typed).
#       Missing or unreadable file -> empty stdout.
#   - new_shellcheck_disables <new_content_str> <existing_file_path>
#       Diffs new content against existing file content, emits each
#       newly-introduced `SC<code>` (one per line). Multi-code directives
#       (`disable=SC2034,SC2317`) yield each code independently.
#   - is_disable_approved <SC_code> <user_msg_text>
#       Returns 0 if the user message text matches
#       `\bapprove\b.*\bSC<code>\b` (case-insensitive on the verb).
#   - main
#       Orchestrates the three above against PreToolUse JSON stdin.
#
# Output contract:
#   - allow  -> exit 0, no stdout
#   - deny   -> exit 0, emit permissionDecision JSON on stdout
#
# Bypass: ECC_ALLOW_SHELLCHECK_DISABLE=1 env var -> allow silently.
#
# Template-first (ADR-0029): sources lib/hook_bootstrap.sh for set -uo pipefail
# (ADR-0007 exit-code-contract) + input reading (hook_read_input). The transcript
# scan, disable-diffing, approval matching, and permissionDecision=deny emission
# are this hook's unique logic and are unchanged. The isolated modules stay
# independently source-able for bats (main runs only as the entrypoint, below).

# shellcheck source=../../lib/hook_bootstrap.sh
source "${LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd -P)}/hook_bootstrap.sh"
hook_bootstrap "enforce-shellcheck-disable-approval"

# ── read_latest_user_message ─────────────────────────────────────────────────
# Args: $1 = transcript_path. Stdout: latest user-typed text message.
# Algorithm: scan JSONL backwards (`tac`) for entries where
# `.type == "user"` AND `.message.role == "user"` AND `.message.content`
# is either a plain string or an array containing a `type:"text"` block
# (NOT a tool_result, which is synthetic). Emit the first match's text.
read_latest_user_message() {
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
                  ( map(select(.type == "text")) | .[0].text // empty )
              else empty
              end
        ' 2>/dev/null)"
        if [[ -n "${text}" ]]; then
            printf '%s\n' "${text}"
            return 0
        fi
    done < <(tac "${transcript_path}" 2>/dev/null)
    return 0
}

# ── new_shellcheck_disables ──────────────────────────────────────────────────
# Args: $1 = new_content_str, $2 = existing_file_path (may not exist).
# Stdout: one SC code per line for each disable in $1 that is NOT in
# the existing file. Multi-code directives split into individual codes.
new_shellcheck_disables() {
    local new_content="${1:-}"
    local existing_path="${2:-}"

    local existing_content=""
    if [[ -n "${existing_path}" && -f "${existing_path}" ]]; then
        existing_content="$(cat "${existing_path}" 2>/dev/null)"
    fi

    local new_codes existing_codes
    new_codes="$(_extract_disable_codes "${new_content}")"
    existing_codes="$(_extract_disable_codes "${existing_content}")"

    if [[ -z "${new_codes}" ]]; then
        return 0
    fi
    if [[ -z "${existing_codes}" ]]; then
        printf '%s\n' "${new_codes}"
        return 0
    fi
    comm -23 <(printf '%s\n' "${new_codes}") <(printf '%s\n' "${existing_codes}")
    return 0
}

# Extract SC codes from a content string. Matches both
# `# shellcheck disable=SC2034` and `# shellcheck disable=SC2034,SC2317`.
# Outputs each SC code on its own line, deduplicated.
_extract_disable_codes() {
    local content="${1:-}"
    [[ -z "${content}" ]] && return 0
    printf '%s' "${content}" \
      | grep -oE '#[[:space:]]*shellcheck[[:space:]]+disable=SC[0-9]+(,SC[0-9]+)*' \
      | grep -oE 'SC[0-9]+' \
      | sort -u
}

# ── is_disable_approved ──────────────────────────────────────────────────────
# Args: $1 = SC<code>, $2 = user_msg_text.
# Exit 0 if approved (msg matches `\bapprove\b.*\bSC<code>\b`,
# case-insensitive on the verb); exit 1 otherwise.
is_disable_approved() {
    local code="${1:-}"
    local user_msg="${2:-}"
    [[ -z "${code}" || -z "${user_msg}" ]] && return 1

    local lower_msg lower_code
    lower_msg="$(printf '%s' "${user_msg}" | tr '[:upper:]' '[:lower:]')"
    lower_code="$(printf '%s' "${code}" | tr '[:upper:]' '[:lower:]')"

    # Use PCRE (-P) for `\b` + cross-line `.` via `(?s)`. Fall back to
    # ERE on a flattened single-line string if PCRE isn't available.
    if printf '%s' "${lower_msg}" \
         | grep -qP "\\bapprove\\b(?s).*\\b${lower_code}\\b" 2>/dev/null; then
        return 0
    fi
    local flat
    flat="$(printf '%s' "${lower_msg}" | tr '\n' ' ')"
    if printf '%s' "${flat}" \
         | grep -qE "(^|[^[:alnum:]_])approve([^[:alnum:]_]|\$).*(^|[^[:alnum:]_])${lower_code}([^[:alnum:]_]|\$)"; then
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

# Stdin: PreToolUse JSON. Stdout: one line per edit, format
# `<file_path><TAB><base64-of-content>`. Base64 keeps the content opaque
# to the line-based shell loop (otherwise embedded newlines would split
# a single multi-line edit into many bogus rows).
_extract_edits() {
    local input="$1"
    local tool
    tool="$(printf '%s' "${input}" | jq -r '.tool_name // empty' 2>/dev/null)"
    case "${tool}" in
        Write)
            printf '%s' "${input}" \
              | jq -r '.tool_input.file_path + "\t" + ((.tool_input.content // "") | @base64)' 2>/dev/null
            ;;
        Edit)
            printf '%s' "${input}" \
              | jq -r '.tool_input.file_path + "\t" + ((.tool_input.new_string // "") | @base64)' 2>/dev/null
            ;;
        MultiEdit)
            printf '%s' "${input}" | jq -r '
                .tool_input.file_path as $fp
                | .tool_input.edits[]
                | $fp + "\t" + ((.new_string // "") | @base64)
            ' 2>/dev/null
            ;;
        *)
            return 0
            ;;
    esac
}

main() {
    if [[ "${ECC_ALLOW_SHELLCHECK_DISABLE:-}" == "1" ]]; then
        return 0
    fi

    hook_read_input
    local input="${HOOK_INPUT}"
    [[ -z "${input}" ]] && return 0

    local tool
    tool="$(printf '%s' "${input}" | jq -r '.tool_name // empty' 2>/dev/null)"
    case "${tool}" in
        Edit|Write|MultiEdit) ;;
        *) return 0 ;;
    esac

    local transcript_path user_msg
    transcript_path="$(printf '%s' "${input}" | jq -r '.transcript_path // empty' 2>/dev/null)"
    user_msg="$(read_latest_user_message "${transcript_path}")"

    local edits_tsv
    edits_tsv="$(_extract_edits "${input}")"
    [[ -z "${edits_tsv}" ]] && return 0

    local -A unapproved_set=()
    local -a unapproved_order=()
    local file_path b64_content new_content code
    while IFS=$'\t' read -r file_path b64_content; do
        [[ -z "${file_path}" ]] && continue
        new_content="$(printf '%s' "${b64_content}" | base64 -d 2>/dev/null || true)"
        while IFS= read -r code; do
            [[ -z "${code}" ]] && continue
            if ! is_disable_approved "${code}" "${user_msg}"; then
                if [[ -z "${unapproved_set[${code}]+x}" ]]; then
                    unapproved_set[${code}]=1
                    unapproved_order+=("${code}")
                fi
            fi
        done < <(new_shellcheck_disables "${new_content}" "${file_path}")
    done <<< "${edits_tsv}"

    if (( ${#unapproved_order[@]} == 0 )); then
        return 0
    fi

    local reason="ShellCheck disable approval required (issue #17, hook source: .claude/hook/enforce_shellcheck_disable_approval.sh).

The following new \`# shellcheck disable=...\` directive(s) were detected but have not been approved by the user in their most recent message:
"
    local c
    for c in "${unapproved_order[@]}"; do
        reason+="
  - ${c} — https://www.shellcheck.net/wiki/${c}"
    done
    reason+="

Protocol (per ADR-0007 / CLAUDE.md \`## Script conventions\`):
  1. Consult the wiki URL(s) above; try the proper fix first.
  2. If no proper fix applies, ask the user for explicit approval using
     the phrase \`approve SC<code>\` (case-insensitive; batchable as
     \`approve SC2034 SC1091\`). Approval is read from the session
     transcript -- it cannot be forged.
  3. Emergency bypass: \`ECC_ALLOW_SHELLCHECK_DISABLE=1\` env var
     (leaves an audit trail in shell history)."

    _emit_deny "${reason}"
    return 0
}

# Only run main when this script is the entrypoint. Allows bats specs to
# `source` the file and exercise individual functions in isolation.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
