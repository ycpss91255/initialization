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
# Why: doc/process/worktree.md ("Lifecycle > Cleanup") states the main
# checkout must always stay at origin/main — meaning it ff-tracks the
# origin/main HEAD, not that it stays frozen. PR #89 was bitten exactly
# because a worktree was started from a stale base and later had to be
# rebased. This hook adds prevention at the hook layer instead of relying
# on the agent to remember to pull first.
#
# Implementation:
#   1. Match `git worktree add` in command (with optional `git -C <dir>`).
#   2. Detect main / origin/main as a standalone arg.
#   3. Resolve repo root from `-C` / `cd && ...` / cwd.
#   4. `git fetch --quiet origin main` (best-effort; on failure, allow).
#   5. `git rev-list --count main..origin/main` to count behind commits.
#   6. If > 0 → deny with concrete `git pull` instruction.
#
# Template-first (ADR-0029): sources lib/hook_bootstrap.sh for set -uo pipefail
# (ADR-0007 exit-code-contract) + input reading (hook_read_input / hook_command /
# hook_field). The worktree-add detection, best-effort fetch, behind-count, and
# permissionDecision=deny emission are this hook's unique logic and are unchanged.

# shellcheck source=../../lib/hook_bootstrap.sh
source "${LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd -P)}/hook_bootstrap.sh"
hook_bootstrap "check-main-fresh-before-worktree"

main() {
  hook_read_input
  local cmd cwd work_dir repo_root behind msg
  cmd="$(hook_command)"
  cwd="$(hook_field '.cwd')"
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

  msg="$(printf 'Local main is %d commit(s) behind origin/main in %s.\nStarting a worktree from a stale base risks merge conflicts later (see docker_harness#89 for the precedent that motivated this hook).\nRun this first, then retry:\n  git -C %s pull --ff-only origin main\nSee doc/process/worktree.md ("Lifecycle > Cleanup").' \
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
