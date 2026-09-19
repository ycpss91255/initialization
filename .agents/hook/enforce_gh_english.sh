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
# Repository scoping (2026-09-19): the English-only rule is THIS repo's, not
# the host's. The same machine hosts sibling repos whose issues / PRs are
# written in another language, and `gh --repo <other>` calls for them run
# from this cwd (so this PreToolUse hook fires on them). The hook therefore
# allows early when the command targets another repository:
#   - `--repo <owner/name>` / `-R <owner/name>` (also `--repo=<owner/name>`)
#     names a repo other than this one, OR
#   - no --repo is given and the cwd's git toplevel is not this checkout
#     (`gh` then targets the cwd's own origin).
# "This repo" is derived from `git remote get-url origin` of the checkout the
# hook lives in (GH_ENGLISH_REPO overrides; falls back to the literal
# ycpss91255/initialization when origin is unreadable). Behaviour for this
# repo is unchanged.
#
# Refs: project rule "GitHub interaction English-only" (2026-05-16
# session), aligns with ycpss91255-docker/docker_harness convention.
#
# Template-first (ADR-0029): sources lib/hook_bootstrap.sh for set -uo pipefail
# (ADR-0007 exit-code-contract) + input reading (hook_read_input / hook_command).
# The CJK/emoji scanning (Python range checks) + permissionDecision=deny emission
# are this hook's unique logic and are unchanged.

# shellcheck source=../../lib/hook_bootstrap.sh
source "${LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd -P)}/hook_bootstrap.sh"
hook_bootstrap "enforce-gh-english"

# ── Repository scoping ───────────────────────────────────────────────────────

# Literal fallback for "this repo" when the checkout's origin cannot be read.
GH_ENGLISH_REPO_LITERAL="ycpss91255/initialization"

# _repo_slug <ref> — normalise a repository reference to lower-case
# "owner/name". Accepts what `gh --repo` and `git remote` produce: owner/name,
# host/owner/name, https:// or ssh:// URLs, git@host:owner/name, an optional
# trailing .git, and optional surrounding quotes. Prints nothing when no
# owner/name pair can be found.
_repo_slug() {
  local _v="${1:-}" _name _rest _owner
  _v="${_v#\"}"; _v="${_v%\"}"; _v="${_v#\'}"; _v="${_v%\'}"
  _v="${_v%/}"
  _v="${_v%.git}"
  _v="${_v//://}"
  _name="${_v##*/}"
  _rest="${_v%/*}"
  _owner="${_rest##*/}"
  [[ -n "${_owner}" && -n "${_name}" && "${_rest}" != "${_v}" ]] || return 0
  printf '%s/%s' "${_owner,,}" "${_name,,}"
}

# _this_repo — owner/name of the checkout this hook lives in (REPO_ROOT's
# origin remote; a linked worktree shares it), else the literal fallback.
_this_repo() {
  local _slug
  _slug="$(_repo_slug "$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null)")"
  printf '%s' "${_slug:-${GH_ENGLISH_REPO_LITERAL}}"
}

# _target_repo <cmd> — owner/name the gh command targets: an explicit
# `--repo <ref>` / `-R <ref>` / `--repo=<ref>`, else $GH_REPO, else the origin
# of the directory the command runs in (a leading `cd <dir> &&`, the payload's
# .cwd, or $PWD). Prints nothing when the target cannot be determined.
_target_repo() {
  local _cmd="$1" _ref="" _dir _cd
  if [[ "${_cmd}" =~ (^|[[:space:]])(--repo|-R)[[:space:]]+([^[:space:]]+) ]]; then
    _ref="${BASH_REMATCH[3]}"
  elif [[ "${_cmd}" =~ (^|[[:space:]])--repo=([^[:space:]]+) ]]; then
    _ref="${BASH_REMATCH[2]}"
  elif [[ -n "${GH_REPO:-}" ]]; then
    _ref="${GH_REPO}"
  else
    _dir="$(hook_field '.cwd')"
    [[ -z "${_dir}" ]] && _dir="${PWD}"
    if [[ "${_cmd}" =~ (^|[[:space:]\;\&])cd[[:space:]]+([^[:space:]\&\;]+)[[:space:]]*\&\& ]]; then
      _cd="${BASH_REMATCH[2]}"
      if [[ "${_cd}" == /* ]]; then
        _dir="${_cd}"
      else
        _dir="${_dir}/${_cd}"
      fi
    fi
    _ref="$(git -C "${_dir}" remote get-url origin 2>/dev/null)"
  fi
  _repo_slug "${_ref}"
}

main() {
  hook_read_input
  local cmd
  cmd="$(hook_command)"
  [[ -z "${cmd}" ]] && return 0

  # Trigger pattern: `gh issue create|comment` or `gh pr create|comment`.
  if ! [[ "${cmd}" =~ (^|[[:space:];|&]|\$\()[[:space:]]*gh[[:space:]]+(issue|pr)[[:space:]]+(create|comment)([[:space:]]|$) ]]; then
    return 0
  fi

  # Repository scoping: the English-only rule guards THIS repo's artifacts.
  # A command that demonstrably targets another repository passes through;
  # an undeterminable target keeps the guard (conservative, unchanged).
  local target
  target="$(_target_repo "${cmd}")"
  if [[ -n "${target}" && "${target}" != "$(_this_repo)" ]]; then
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

  # Emoji detection (separate from CJK). Functional symbols are EXCLUDED so
  # legitimate technical text passes: arrows U+2190-21FF, box-drawing
  # U+2500-257F, bullet U+2022, middle dot U+00B7, ellipsis U+2026.
  local has_emoji
  has_emoji="$(printf '%s' "${to_scan}" | python3 -c '
import sys, re
text = sys.stdin.read()
emoji = re.compile(
    "["
    "\U0001F000-\U0001FAFF"   # emoticons / pictographs / transport / symbols ext
    "\U00002600-\U000026FF"   # miscellaneous symbols
    "\U00002700-\U000027BF"   # dingbats (check mark, scissors, sparkles, ...)
    "\U00002B00-\U00002BFF"   # misc symbols & decorative arrows (star, ...)
    "\U0000FE0F"              # emoji variation selector
    "\U0000200D"              # zero-width joiner (emoji sequences)
    "\U000020E3"              # combining enclosing keycap
    "]"
)
m = emoji.search(text)
if m:
    i = m.start()
    print(f"FOUND:{m.group()}:" + text[max(0, i-20):i+20].replace("\n", " "))
' 2>/dev/null)"

  [[ -z "${has_cjk}" && -z "${has_emoji}" ]] && return 0

  local kind detail
  if [[ -n "${has_cjk}" ]]; then
    kind="CJK character(s)"; detail="${has_cjk}"
  else
    kind="emoji"; detail="${has_emoji}"
  fi

  local msg="GitHub text rule (init_ubuntu / docker_harness alignment):
  gh issue/pr create/comment body / title must be English-only and emoji-free.
  Detected ${kind}: ${detail}

  Rewrite the title / body without it and retry. Emoji belong nowhere in this
  project; CJK belongs in commit messages or chat, not on GitHub artifacts
  (public + indexed).

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
