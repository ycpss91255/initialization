#!/usr/bin/env bash
# check_changelog_drift.sh — Claude Code PreToolUse hook (matcher: Bash)
#
# Fires before any Bash command. When the command is `git commit`, check
# whether non-doc files are staged without a corresponding update to
# `doc/changelog/CHANGELOG.md`. On drift, emit a JSON systemMessage.
# Non-blocking — exit 0.
#
# Why: doc/process/release.md item 1 and the "doc-alignment principle"
# require that user-visible behavior changes add an entry under
# CHANGELOG.md `[Unreleased]`. This was commonly missed — a feature
# commit would ship without a CHANGELOG entry and only get backfilled at
# release time; dependabot bot PRs also never update the CHANGELOG
# themselves.
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
#
# Template-first (ADR-0029): sources lib/hook_bootstrap.sh for set -uo pipefail
# (ADR-0007 exit-code-contract) + input reading (hook_read_input / hook_command /
# hook_field). The staged-diff drift detection + the systemMessage emission are
# this hook's unique logic and are unchanged.

# shellcheck source=../../lib/hook_bootstrap.sh
source "${LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd -P)}/hook_bootstrap.sh"
hook_bootstrap "check-changelog-drift"

main() {
  hook_read_input
  local cmd cwd work_dir repo_root staged has_code has_changelog msg
  cmd="$(hook_command)"
  cwd="$(hook_field '.cwd')"
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

  msg="$(printf 'CHANGELOG drift in %s:\n  staged code/config files but doc/changelog/CHANGELOG.md not in the commit.\n  doc/process/release.md (CHANGELOG section): user-visible changes must add an entry to the [Unreleased] section.\n  Staged files:\n%s' \
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
