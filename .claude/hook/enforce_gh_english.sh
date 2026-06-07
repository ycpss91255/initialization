#!/usr/bin/env bash
# enforce_gh_english.sh -- Claude Code PreToolUse hook (matcher: Bash).
#
# DENIES `gh issue create`, `gh issue comment`, `gh pr create`, and
# `gh pr comment` invocations whose body / title contains CJK (Chinese,
# Japanese, Korean) characters. Project rule: GitHub interaction (issue
# / PR titles + bodies + comments) is English-only so the artifacts
# stay accessible to any contributor and to OSS norms.
#
# Detection:
#   1. Match a triggering `gh` subcommand at a command-line boundary.
#   2. Resolve the body source — either:
#      - inline `--body "..."` or `-b "..."` flag
#      - `--body-file <path>` (read the file)
#      - process substitution `--body-file <(...)` (read the cmd output;
#        we conservatively allow this since reading the substitution
#        requires shell evaluation; rely on author discipline)
#      - heredoc-style on stdin (out of scope; pass through)
#   3. Also scan `--title "..."` / `-t "..."`.
#   4. If any extracted text contains a Han / Hiragana / Katakana / Hangul
#      codepoint, BLOCK with permissionDecision="deny".
#
# Unicode ranges checked (CJK only — Latin-1 supplement, accented Latin,
# math symbols etc. pass through):
#   U+3040..U+309F  Hiragana
#   U+30A0..U+30FF  Katakana
#   U+3400..U+4DBF  CJK Unified Ideographs Extension A
#   U+4E00..U+9FFF  CJK Unified Ideographs
#   U+AC00..U+D7AF  Hangul Syllables
#   U+F900..U+FAFF  CJK Compatibility Ideographs
#   U+FF66..U+FF9F  Halfwidth Katakana
#
# Out of scope (pass through silently):
#   - `gh issue view` / `gh pr view` (read-only)
#   - `gh issue list` / `gh pr list`
#   - `gh repo` / `gh api` / other subcommands
#   - git commit messages (project rule covers issue/PR only)
#
# Refs: project rule "GitHub interaction English-only" (2026-05-16
# session), aligns with ycpss91255-docker/docker_harness convention.

set -uo pipefail

main() {
  local input cmd
  input="$(cat)"
  cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  [[ -z "${cmd}" ]] && return 0

  # Trigger pattern: `gh issue create|comment` or `gh pr create|comment`.
  if ! [[ "${cmd}" =~ (^|[[:space:];|&]|\$\()[[:space:]]*gh[[:space:]]+(issue|pr)[[:space:]]+(create|comment)([[:space:]]|$) ]]; then
    return 0
  fi

  # Extract body + title text to scan. Strategy: pull each flag's value.
  local to_scan=""

  # --title "..." / -t "..."
  if [[ "${cmd}" =~ --title[[:space:]]+\"([^\"]*)\" ]]; then
    to_scan+="${BASH_REMATCH[1]}"$'\n'
  elif [[ "${cmd}" =~ --title=\"([^\"]*)\" ]]; then
    to_scan+="${BASH_REMATCH[1]}"$'\n'
  elif [[ "${cmd}" =~ --title[[:space:]]+\'([^\']*)\' ]]; then
    to_scan+="${BASH_REMATCH[1]}"$'\n'
  fi
  if [[ "${cmd}" =~ ([[:space:]]|^)-t[[:space:]]+\"([^\"]*)\" ]]; then
    to_scan+="${BASH_REMATCH[2]}"$'\n'
  fi

  # --body "..." / -b "..."
  if [[ "${cmd}" =~ --body[[:space:]]+\"([^\"]*)\" ]]; then
    to_scan+="${BASH_REMATCH[1]}"$'\n'
  elif [[ "${cmd}" =~ --body=\"([^\"]*)\" ]]; then
    to_scan+="${BASH_REMATCH[1]}"$'\n'
  fi
  if [[ "${cmd}" =~ ([[:space:]]|^)-b[[:space:]]+\"([^\"]*)\" ]]; then
    to_scan+="${BASH_REMATCH[2]}"$'\n'
  fi

  # --body-file <path>  (read file content if a literal path)
  if [[ "${cmd}" =~ --body-file[[:space:]]+([^[:space:]\(]+) ]]; then
    local _bf="${BASH_REMATCH[1]}"
    # Skip if it's a process substitution like <(...)
    if [[ "${_bf}" != "<("* ]] && [[ -f "${_bf}" ]]; then
      to_scan+="$(cat "${_bf}" 2>/dev/null)"$'\n'
    fi
  fi

  # Nothing to scan → allow (caller might be using --body-file <(heredoc)
  # form which we don't introspect; rely on author + post-CI human review).
  [[ -z "${to_scan}" ]] && return 0

  # CJK detection. Use Python (available in test-tools image; also in
  # Ubuntu /usr/bin/python3 by default) for proper Unicode range check.
  local has_cjk
  has_cjk="$(printf '%s' "${to_scan}" | python3 -c '
import sys, re
text = sys.stdin.read()
# CJK + Hiragana + Katakana + Hangul ranges.
pattern = re.compile(
    "["
    "぀-ゟ"   # Hiragana
    "゠-ヿ"   # Katakana
    "㐀-䶿"   # CJK Ext A
    "一-鿿"   # CJK Unified
    "가-힯"   # Hangul Syllables
    "豈-﫿"   # CJK Compatibility
    "ｦ-ﾟ"   # Halfwidth Katakana
    "]"
)
m = pattern.search(text)
if m:
    i = m.start()
    excerpt = text[max(0, i-20):i+20].replace("\n", " ")
    print(f"FOUND:{m.group()}:{excerpt}")
' 2>/dev/null)"

  [[ -z "${has_cjk}" ]] && return 0

  local msg="GitHub English-only rule (init_ubuntu / docker_harness alignment):
  gh issue/pr create/comment body / title must be English only.
  Detected CJK character(s): ${has_cjk}

  Rewrite the title / body in English and retry. Project / private notes
  in CJK belong in commit messages or chat, not on GitHub artifacts that
  are public + indexed.

  Hook source: .claude/hook/enforce_gh_english.sh"

  jq -n --arg m "${msg}" '{
    systemMessage: $m,
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $m
    }
  }'

  return 0
}

main "$@"
