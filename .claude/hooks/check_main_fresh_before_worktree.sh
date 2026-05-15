#!/usr/bin/env bash
# check_main_fresh_before_worktree.sh — Claude Code PreToolUse hook
# (matcher: Bash)
#
# Fires before `git worktree add ... main` (or `... origin/main`).
# BLOCKS with permissionDecision="deny" if the local main branch is
# behind origin/main, so the new worktree never branches from a stale
# base. Allow when:
#   - The command does not start a worktree from main / origin/main
#     (e.g. branching from a tag or another branch — not in scope)
#   - The working directory is not a git repo (defensive — hook shouldn't
#     fire in unexpected cwds anyway)
#   - `git fetch` fails (offline / auth — don't false-deny in degraded
#     network conditions)
#   - Local main is already even with or ahead of origin/main
#   - The repo has no origin/main yet (fresh clone before first fetch)
#
# Why: docs/processes/worktree.md ("Lifecycle > Cleanup")明文「主 checkout
# 永遠停在 origin/main」— 意指 ff-tracking origin/main HEAD,不是凍結。
# PR #89 那次正是因為從 stale base 起 worktree、後來才被迫 rebase。
# Hook 層補上預防,不再依賴 agent 記得先 pull。
#
# Implementation:
#   1. Match `git worktree add` in command (with optional `git -C <dir>`).
#   2. Detect main / origin/main as a standalone arg.
#   3. Resolve repo root from `-C` / `cd && ...` / cwd.
#   4. `git fetch --quiet origin main` (best-effort; on failure, allow).
#   5. `git rev-list --count main..origin/main` to count behind commits.
#   6. If > 0 → deny with concrete `git pull` instruction.

set -uo pipefail

main() {
  local input cmd cwd work_dir repo_root behind msg
  input="$(cat)"
  cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  cwd="$(printf '%s' "${input}" | jq -r '.cwd // empty' 2>/dev/null)"
  [[ -z "${cwd}" ]] && cwd="${PWD}"

  [[ -z "${cmd}" ]] && return 0

  # Must contain `git worktree add`.
  [[ "${cmd}" =~ git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?worktree[[:space:]]+add ]] || return 0

  # Must reference main or origin/main as a standalone token.
  if [[ "${cmd}" =~ ([[:space:]]|^)origin/main([[:space:]]|$) ]]; then
    : # branching from origin/main
  elif [[ "${cmd}" =~ ([[:space:]]|^)main([[:space:]]|$) ]]; then
    : # branching from main
  else
    return 0
  fi

  # Resolve work dir.
  work_dir=""
  if [[ "${cmd}" =~ git[[:space:]]+-C[[:space:]]+([^[:space:]]+) ]]; then
    work_dir="${BASH_REMATCH[1]}"
  elif [[ "${cmd}" =~ cd[[:space:]]+([^[:space:]\&\;]+)[[:space:]]*\&\& ]]; then
    work_dir="${BASH_REMATCH[1]}"
  fi
  [[ -z "${work_dir}" ]] && work_dir="${cwd}"
  [[ "${work_dir}" != /* ]] && work_dir="${cwd}/${work_dir}"

  repo_root="$(git -C "${work_dir}" rev-parse --show-toplevel 2>/dev/null)"
  [[ -z "${repo_root}" ]] && return 0

  # Best-effort fetch — if offline / auth fails, allow (degraded mode).
  if ! git -C "${repo_root}" fetch --quiet origin main 2>/dev/null; then
    return 0
  fi

  # If origin/main doesn't exist yet (fresh clone state), allow.
  if ! git -C "${repo_root}" rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
    return 0
  fi

  # If local main doesn't exist (worktree-only checkout?), allow.
  if ! git -C "${repo_root}" rev-parse --verify --quiet main >/dev/null 2>&1; then
    return 0
  fi

  behind="$(git -C "${repo_root}" rev-list --count main..origin/main 2>/dev/null)"
  [[ -z "${behind}" ]] && return 0
  (( behind > 0 )) || return 0

  msg="$(printf 'Local main is %d commit(s) behind origin/main in %s.\nStarting a worktree from a stale base risks merge conflicts later (see docker_harness#89 for the precedent that motivated this hook).\nRun this first, then retry:\n  git -C %s pull --ff-only origin main\nSee docs/processes/worktree.md ("Lifecycle > Cleanup").' \
    "${behind}" "${repo_root}" "${repo_root}")"

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
