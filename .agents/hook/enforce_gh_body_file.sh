#!/usr/bin/env bash
# enforce_gh_body_file.sh -- Claude Code PreToolUse hook (matcher: Bash)
#
# Fires before any Bash command. BLOCKS (permissionDecision: deny) gh
# invocations that violate the body-file discipline rules from issue #64.
# Renamed + upgraded from `remind_use_body_file.sh` (non-blocking remind).
#
# Companion: .github/ISSUE_TEMPLATE/<kind>.yaml define the positive body
# format (the structured sections per kind); enforce_gh_issue_template.sh
# enforces those required sections on the agent --body-file path.
#
# Rules (deny on violation):
#   1. `gh issue create` without `--body-file <path>`
#   9. `gh issue create` without `--label <non-empty>` (PR create exempt;
#      added by issue #91 -- maps title type prefix to stock GitHub label,
#      see gh-artifact-format SKILL.md Section 6)
#   2. `gh issue comment` with `--body|--comment "<long>"` (long = multi-
#      line or > 80 chars). Short single-line bodies <= 80 chars are
#      allowed inline.
#   3. `gh issue close --comment "..."` (any inline value) -- enforce
#      two-step close: `gh issue comment N --body-file X && gh issue
#      close N [--reason ...]`. `gh issue close N --reason <r>` (no
#      `--comment`) stays silent.
#   4. `gh pr create` without `--body-file <path>`
#   5. `gh pr comment` with `--body "<long>"` (same threshold as rule 2)
#   6. `gh pr edit --body "..."` inline (any value) -- always go through
#      a file
#   7. `gh pr review --body "<long>"` (same threshold as rule 2)
#   8. `--body "$(cat ...)"` or `--body-file - <<EOF` heredoc on any gh
#      subcommand -- both trigger Claude bash AST parser fallback
#
# Threshold: SHORT_LIMIT = 80 chars, single line. Decided in #64
# discussion to keep the rule uniform across review / comment / trivial-
# close so one number covers all "short inline" cases.
#
# Silent (no rule applies):
#   - Any gh subcommand not listed above (e.g. `gh repo edit`, `gh pr
#     view`, `gh pr merge`, `gh run view`, `gh api ...`)
#   - `gh issue close N --reason <r>` without `--comment`
#   - `--body-file <real-path>` (canonical form, exactly what we want)
#   - Non-gh commands

set -uo pipefail

readonly SHORT_LIMIT=80

extract_body() {
  local cmd="$1"
  if [[ "${cmd}" =~ --(body|comment)[[:space:]]+\"([^\"]*)\" ]]; then
    printf '%s' "${BASH_REMATCH[2]}"
    return 0
  fi
  if [[ "${cmd}" =~ --(body|comment)[[:space:]]+\'([^\']*)\' ]]; then
    printf '%s' "${BASH_REMATCH[2]}"
    return 0
  fi
  if [[ "${cmd}" =~ --(body|comment)=([^[:space:]]+) ]]; then
    printf '%s' "${BASH_REMATCH[2]}"
    return 0
  fi
  printf ''
}

short_body_ok() {
  local body="$1"
  [[ "${body}" == *$'\n'* ]] && return 1
  (( ${#body} <= SHORT_LIMIT ))
}

has_real_body_file() {
  local cmd="$1"
  if [[ "${cmd}" =~ --body-file[[:space:]]+([^[:space:]][^[:space:]]*) ]]; then
    [[ "${BASH_REMATCH[1]}" != "-" ]]
    return $?
  fi
  if [[ "${cmd}" =~ --body-file=([^[:space:]]+) ]]; then
    [[ "${BASH_REMATCH[1]}" != "-" ]]
    return $?
  fi
  return 1
}

has_label() {
  # Rule 9 (#91): require `--label <non-empty>` (or `-l`, or `--label=`).
  # Empty value (--label "" / --label '' / --label= ) does not count.
  # The check is lexical; gh itself errors out if the label name is bogus
  # or not present on the target repo.
  #
  # Bash regex (=~) does not support back-references, so quoted-form
  # and bare-form are matched in separate alternatives instead of via
  # a captured quote char.
  local cmd="$1"
  # --label "value" or -l "value" (double-quoted non-empty)
  if [[ "${cmd}" =~ (^|[[:space:]])(--label|-l)[[:space:]]+\"[^\"]+\"([[:space:]]|$) ]]; then
    return 0
  fi
  # --label 'value' or -l 'value' (single-quoted non-empty)
  if [[ "${cmd}" =~ (^|[[:space:]])(--label|-l)[[:space:]]+\'[^\']+\'([[:space:]]|$) ]]; then
    return 0
  fi
  # --label value or -l value (bare; first char not quote / = / dash)
  if [[ "${cmd}" =~ (^|[[:space:]])(--label|-l)[[:space:]]+[^[:space:]\"\'=-][^[:space:]]*([[:space:]]|$) ]]; then
    return 0
  fi
  # --label="value" or --label='value' (quoted, equals form)
  if [[ "${cmd}" =~ --label=\"[^\"]+\"([[:space:]]|$) ]]; then
    return 0
  fi
  if [[ "${cmd}" =~ --label=\'[^\']+\'([[:space:]]|$) ]]; then
    return 0
  fi
  # --label=value (bare, equals form, non-empty)
  if [[ "${cmd}" =~ --label=[^[:space:]\"\'][^[:space:]]*([[:space:]]|$) ]]; then
    return 0
  fi
  return 1
}

has_stdin_body_file() {
  local cmd="$1"
  [[ "${cmd}" =~ --body-file[[:space:]]+-([[:space:]\&\|\;\<]|$) ]]
}

has_cat_substitution() {
  local cmd="$1"
  [[ "${cmd}" =~ --(body|comment)[[:space:]]+\"?\$\([[:space:]]*cat[[:space:]] ]]
}

detect_subcmd() {
  local cmd="$1"
  if [[ "${cmd}" =~ gh[[:space:]]+(issue|pr)[[:space:]]+([a-z]+) ]]; then
    printf '%s %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  fi
}

deny() {
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

main() {
  local input cmd subcmd body len
  input="$(cat)"
  cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  [[ -z "${cmd}" ]] && return 0

  if ! printf '%s' "${cmd}" | grep -qE '(^|[[:space:]&|;])gh[[:space:]]'; then
    return 0
  fi

  if has_cat_substitution "${cmd}"; then
    deny "gh long-body via --body \"\$(cat ...)\" triggers Claude bash AST parser fallback (Unhandled node type: string). Canonical: Write the body to /tmp/<name>.md, then gh ... --body-file /tmp/<name>.md. Rule 8 of #64."
    return 0
  fi
  if has_stdin_body_file "${cmd}"; then
    deny "gh --body-file - <<EOF (stdin heredoc) triggers Claude bash AST parser fallback. Write the body to /tmp/<name>.md, then gh ... --body-file /tmp/<name>.md. Rule 8 of #64."
    return 0
  fi

  subcmd="$(detect_subcmd "${cmd}")"

  case "${subcmd}" in
    "issue create"|"pr create")
      if ! has_real_body_file "${cmd}"; then
        deny "gh ${subcmd} needs --body-file <path>. Write the body to /tmp/<name>.md, then gh ${subcmd} ... --body-file /tmp/<name>.md. Rules 1/4 of #64 (creation artifacts are reviewer-visible, must land in a real file)."
        return 0
      fi
      # Rule 9 (#91): `gh issue create` must carry --label <non-empty>.
      # PRs are exempt -- they inherit labels from the issue they close.
      if [[ "${subcmd}" == "issue create" ]] && ! has_label "${cmd}"; then
        deny "gh issue create needs --label <name> (Rule 9 of #91). Map the title type prefix to a stock GitHub label (matches .github/ISSUE_TEMPLATE/<kind>.yaml): feat/refactor/chore/track -> enhancement, fix -> bug, docs -> documentation. Example: gh issue create ... --body-file /tmp/x.md --label enhancement"
        return 0
      fi
      return 0
      ;;
    "issue close")
      if printf '%s' "${cmd}" | grep -qE -e '(--comment|-c)([[:space:]]+|=)'; then
        deny "gh issue close --comment is denied. Use two-step close: gh issue comment N --body-file X (or short --body \"<le 80 chars>\"), then gh issue close N [--reason completed|not\\ planned]. Rule 3 of #64."
        return 0
      fi
      return 0
      ;;
    "pr edit")
      if printf '%s' "${cmd}" | grep -qE -e '--body([[:space:]]+|=)' \
         && ! has_real_body_file "${cmd}"; then
        deny "gh pr edit --body inline is denied. Always use gh pr edit ... --body-file /tmp/<name>.md. Rule 6 of #64 (pr-edit overwrites the entire body, file form keeps the diff reviewable)."
        return 0
      fi
      return 0
      ;;
    "issue comment"|"pr comment"|"pr review")
      body="$(extract_body "${cmd}")"
      if [[ -n "${body}" ]] && ! short_body_ok "${body}"; then
        len="${#body}"
        deny "gh ${subcmd} body is too long for inline (${len} chars or multi-line; SHORT_LIMIT=${SHORT_LIMIT} single line). Write to /tmp/<name>.md and pass --body-file. Rule 2/5/7 of #64."
        return 0
      fi
      return 0
      ;;
  esac

  return 0
}

main "$@"
