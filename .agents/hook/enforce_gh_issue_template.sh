#!/usr/bin/env bash
# enforce_gh_issue_template.sh -- Claude Code PreToolUse hook (matcher: Bash)
#
# Fires before any Bash command. BLOCKS (permissionDecision: deny) a
# `gh issue create` whose --body-file content does not carry every REQUIRED
# section of the matching issue form.
#
# Why: agents open issues with `gh issue create --body-file <path>` (forced by
# enforce_gh_body_file.sh). That path bypasses GitHub's .github/ISSUE_TEMPLATE
# forms entirely, so without this hook an agent-authored body need not follow
# the template at all. This hook re-imposes the template on the agent path.
#
# Single source of truth: the required section list is PARSED FROM the form
# files in .github/ISSUE_TEMPLATE/<kind>.yaml (fields with
# `validations: required: true`). Editing a form updates the enforcement with
# no second list to keep in sync.
#
# Kind is chosen from the conventional-commit prefix of --title:
#   fix:                                  -> bug.yaml
#   feat:                                 -> feature.yaml
#   docs:                                 -> docs.yaml
#   refactor:/test:/ci:/chore:/perf:/build:/style: -> task.yaml
#   (any other / no recognized prefix)    -> allow (no template enforced)
#
# A required section is satisfied when the body has a `## <label>` or
# `### <label>` heading (the label is the form field's `label:`, which is also
# exactly how GitHub renders a submitted form) followed by non-empty content
# that is not the literal `_No response_`.
#
# Silent (return 0, no decision):
#   - any non `gh issue create` command
#   - unrecognized / missing title prefix
#   - no --body-file path (enforce_gh_body_file.sh already denies that)
#   - the matching form file does not exist
#   - awk/jq unavailable
#
# Companion hooks on the same matcher: enforce_gh_body_file.sh (body-file +
# label discipline) and enforce_gh_english.sh (English-only).

set -uo pipefail

readonly TEMPLATE_REL=".github/ISSUE_TEMPLATE"

# --- helpers -----------------------------------------------------------------

extract_title() {
  local cmd="$1"
  if [[ "${cmd}" =~ --title[[:space:]]+\"([^\"]*)\" ]]; then printf '%s' "${BASH_REMATCH[1]}"; return 0; fi
  if [[ "${cmd}" =~ --title=\"([^\"]*)\" ]]; then printf '%s' "${BASH_REMATCH[1]}"; return 0; fi
  if [[ "${cmd}" =~ --title[[:space:]]+\'([^\']*)\' ]]; then printf '%s' "${BASH_REMATCH[1]}"; return 0; fi
  if [[ "${cmd}" =~ (^|[[:space:]])-t[[:space:]]+\"([^\"]*)\" ]]; then printf '%s' "${BASH_REMATCH[2]}"; return 0; fi
  if [[ "${cmd}" =~ (^|[[:space:]])-t[[:space:]]+\'([^\']*)\' ]]; then printf '%s' "${BASH_REMATCH[2]}"; return 0; fi
  printf ''
}

extract_body_file() {
  local cmd="$1"
  if [[ "${cmd}" =~ --body-file[[:space:]]+([^[:space:]][^[:space:]]*) ]]; then
    [[ "${BASH_REMATCH[1]}" != "-" ]] && printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "${cmd}" =~ --body-file=([^[:space:]]+) ]]; then
    [[ "${BASH_REMATCH[1]}" != "-" ]] && printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  printf ''
}

kind_for_prefix() {
  # Map a conventional-commit type prefix to an issue-form kind.
  case "$1" in
    fix) printf 'bug' ;;
    feat) printf 'feature' ;;
    docs) printf 'docs' ;;
    refactor|test|ci|chore|perf|build|style) printf 'task' ;;
    *) printf '' ;;
  esac
}

# Required field labels of a form file (those with `validations: required:
# true`). busybox-awk safe: no {n,m} intervals.
required_labels() {
  awk '
    /^[[:space:]]*-[[:space:]]+type:/ { lbl="" }
    /^[[:space:]]+label:[[:space:]]/ {
      line=$0
      sub(/^[[:space:]]+label:[[:space:]]*/, "", line)
      sub(/[[:space:]]+$/, "", line)
      lbl=line
    }
    /^[[:space:]]+required:[[:space:]]+true[[:space:]]*$/ { if (lbl != "") print lbl }
  ' "$1"
}

# Print OK / MISSING / EMPTY for one required section in the body file.
section_state() {
  local body_file="$1" want="$2"
  awk -v want="${want}" '
    function strip(s){ sub(/^###?[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    BEGIN { found=0; content=0; insec=0 }
    /^###?[[:space:]]+/ {
      h=strip($0)
      if (h == want) { found=1; insec=1 } else { insec=0 }
      next
    }
    /^#[[:space:]]+/ { insec=0 }
    {
      if (insec) {
        t=$0; gsub(/[[:space:]\r]/, "", t)
        if (t != "" && $0 !~ /^_No response_[[:space:]]*$/) content=1
      }
    }
    END {
      if (!found) print "MISSING"
      else if (!content) print "EMPTY"
      else print "OK"
    }
  ' "${body_file}"
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

# --- main --------------------------------------------------------------------

main() {
  command -v jq >/dev/null 2>&1 || return 0
  command -v awk >/dev/null 2>&1 || return 0

  local input cmd
  input="$(cat)"
  cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  [[ -z "${cmd}" ]] && return 0

  # Only `gh issue create`.
  [[ "${cmd}" =~ (^|[[:space:];|&]|\$\()[[:space:]]*gh[[:space:]]+issue[[:space:]]+create([[:space:]]|$) ]] || return 0

  local title kind body_file
  title="$(extract_title "${cmd}")"
  [[ -z "${title}" ]] && return 0

  local prefix=""
  if [[ "${title}" =~ ^([a-zA-Z]+)(\([^\)]*\))?: ]]; then
    prefix="${BASH_REMATCH[1],,}"
  fi
  kind="$(kind_for_prefix "${prefix}")"
  [[ -z "${kind}" ]] && return 0

  body_file="$(extract_body_file "${cmd}")"
  [[ -z "${body_file}" ]] && return 0
  [[ -f "${body_file}" ]] || return 0

  local form="${CLAUDE_PROJECT_DIR:-${PWD}}/${TEMPLATE_REL}/${kind}.yaml"
  [[ -f "${form}" ]] || return 0

  local label missing="" state
  while IFS= read -r label; do
    [[ -z "${label}" ]] && continue
    state="$(section_state "${body_file}" "${label}")"
    case "${state}" in
      MISSING) missing+="  - ${label} (heading absent)"$'\n' ;;
      EMPTY)   missing+="  - ${label} (heading present but empty)"$'\n' ;;
    esac
  done < <(required_labels "${form}")

  [[ -z "${missing}" ]] && return 0

  deny "gh issue create body does not satisfy the ${kind} template (${TEMPLATE_REL}/${kind}.yaml).
Missing / empty required section(s):
${missing}
Each required field is a '## <label>' (or '### <label>') heading with non-empty
content. Add the section(s) above to the --body-file and retry. The full form,
including optional sections and what to write, is in ${TEMPLATE_REL}/${kind}.yaml.
Hook: .claude/hook/enforce_gh_issue_template.sh"

  return 0
}

main "$@"
