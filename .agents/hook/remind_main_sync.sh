#!/usr/bin/env bash
# remind_main_sync.sh — Claude Code PreToolUse hook (matcher: Bash)
#
# Fires before `gh pr merge` (any flag combination). Emits a JSON
# systemMessage reminding the user to `git pull --ff-only origin main`
# on the main checkout after the merge lands, so the local main keeps
# tracking origin/main HEAD instead of freezing in place.
#
# Non-blocking (always exit 0). Two message variants:
#   - With --auto: merge is queued; remind to pull after CI passes
#   - Without --auto: merge is immediate; remind to pull right after
#
# Why: doc/process/worktree.md ("Lifecycle > Cleanup")要求主 checkout
# 永遠停在 origin/main HEAD — 意思是「持續 ff-tracking」不是「凍結在
# 某個 commit」。PR #89 那次踩到正是因為 local main 落後好幾個 PR,
# 從 stale base 起 worktree branch,後來才被迫 rebase。
#
# Trigger pattern: `gh pr merge` 出現在 command 作為實際子指令,不算
# quoted string 內 substring(避免 `git commit -m "...gh pr merge..."`
# 之類的 commit message 觸發 false positive)。實作:
#   1. 用 sed 砍掉雙引號 / 單引號區段(unnested 簡單情況)
#   2. 在 cleaned 字串上跑 trigger regex
#   3. 加 command-boundary anchor (^ 或 ; & | $( 之後),`gh pr merge`
#      必須是 actual subcommand 才 match
# 不限定 `--squash` / `--merge` / `--rebase`,任何 merge mode 都觸發。
# Skip read-only `gh pr view` / `gh pr checks` etc.

set -uo pipefail

# Strip outer-level double-quoted and single-quoted regions so a literal
# `gh pr merge` inside a commit message / -m argument / heredoc body
# does not falsely trigger the reminder. Conservative: handles
# unnested quotes; mixed nesting / escaped quotes degrade gracefully
# (worst case: a false positive survives -- never a false negative).
strip_quoted_regions() {
  local s="$1"
  s="$(printf '%s' "${s}" | sed -E 's/"[^"]*"//g')"
  s="$(printf '%s' "${s}" | sed -E "s/'[^']*'//g")"
  printf '%s' "${s}"
}

main() {
  local input cmd cleaned msg variant
  input="$(cat)"
  cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null)"

  [[ -z "${cmd}" ]] && return 0

  cleaned="$(strip_quoted_regions "${cmd}")"

  # `gh pr merge` must sit at a command boundary in `cleaned`: start of
  # string, or right after one of `;` `&` `|` `$(`, allowing whitespace
  # between the boundary and `gh`. This prevents matches mid-token (e.g.
  # the substring of a removed quoted region's surroundings).
  if ! [[ "${cleaned}" =~ (^|[\;\&\|]|\$\()[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$) ]]; then
    return 0
  fi

  if [[ "${cleaned}" =~ --auto([[:space:]]|$) ]]; then
    variant="queued"
    msg="Auto-merge queued. After CI passes and GitHub completes the merge, run \`git -C \$(git rev-parse --show-toplevel 2>/dev/null) pull --ff-only origin main\` (or the same from your main checkout) to keep local main tracking origin/main HEAD. See doc/process/worktree.md ("Lifecycle > Cleanup")."
  else
    variant="immediate"
    msg="PR merged. Run \`git pull --ff-only origin main\` on your main checkout now so local main keeps tracking origin/main HEAD (don't let it freeze behind). See doc/process/worktree.md ("Lifecycle > Cleanup")."
  fi

  jq -n --arg m "${msg}" --arg v "${variant}" '{
    systemMessage: $m,
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      additionalContext: ($m + " [variant=" + $v + "]")
    }
  }'

  return 0
}

main "$@"
