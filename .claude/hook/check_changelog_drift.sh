#!/usr/bin/env bash
# check_changelog_drift.sh — Claude Code PreToolUse hook (matcher: Bash)
#
# Fires before any Bash command. When the command is `git commit`, check
# whether non-doc files are staged without a corresponding update to
# `doc/changelog/CHANGELOG.md`. On drift, emit a JSON systemMessage.
# Non-blocking — exit 0.
#
# Why: doc/process/release.md第 1 條與「文件對齊原則」要求
# 使用者可見的行為變更必須在 CHANGELOG.md `[Unreleased]` 加條目。
# 過去常見漏 — feature commit 沒帶 CHANGELOG，要等 release 才補；
# dependabot bot PR 也不會自己改 CHANGELOG。
#
# Detection:
#   1. Resolve work dir from command (`git -C <dir>` / `cd <dir> &&` / cwd).
#   2. `git rev-parse --show-toplevel` to find repo root.
#   3. Skip if no `doc/changelog/CHANGELOG.md` in repo (rule N/A).
#   4. Diff staged: if any non-doc file staged AND CHANGELOG not staged
#      AND not `--amend`/`--allow-empty` → warn.
#
# Non-doc = anything outside `doc/`, not `*.md`, not `.gitignore`/`LICENSE*`.
# Conservative — better to over-nag (non-blocking) than miss real drift.

set -uo pipefail

main() {
  local input cmd cwd work_dir repo_root staged has_code has_changelog msg
  input="$(cat)"
  cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  cwd="$(printf '%s' "${input}" | jq -r '.cwd // empty' 2>/dev/null)"
  [[ -z "${cwd}" ]] && cwd="${PWD}"

  [[ -z "${cmd}" ]] && return 0

  # Trigger only on `git commit` (not status/log/show/etc.); exclude --amend.
  [[ "${cmd}" =~ git[[:space:]]+(-[A-Za-z]+[[:space:]]+[^[:space:]]+[[:space:]]+)*commit([[:space:]]|$) ]] || return 0
  [[ "${cmd}" == *"--amend"* ]] && return 0
  [[ "${cmd}" == *"--allow-empty"* ]] && return 0

  # Resolve work dir: prefer `git -C <dir>`, then `cd <dir> &&`, else cwd.
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

  [[ -f "${repo_root}/doc/changelog/CHANGELOG.md" ]] || return 0

  staged="$(git -C "${repo_root}" diff --cached --name-only 2>/dev/null)"
  [[ -z "${staged}" ]] && return 0

  has_code=0
  has_changelog=0
  while IFS= read -r f; do
    [[ -z "${f}" ]] && continue
    case "${f}" in
      doc/changelog/CHANGELOG.md) has_changelog=1 ;;
      doc/*|*.md|.gitignore|LICENSE*|*.lock|.env*) ;;
      *) has_code=1 ;;
    esac
  done <<< "${staged}"

  (( has_code == 1 && has_changelog == 0 )) || return 0

  msg="$(printf 'CHANGELOG drift in %s:\n  staged code/config files but doc/changelog/CHANGELOG.md not in the commit.\n  doc/process/release.md (CHANGELOG section): 使用者可見的變更必須在 [Unreleased] section 加條目。\n  Staged files:\n%s' \
    "${repo_root}" "$(printf '%s' "${staged}" | sed 's/^/    /')")"

  jq -n --arg m "${msg}" '{
    systemMessage: $m,
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      additionalContext: $m
    }
  }'

  return 0
}

main "$@"
