#!/usr/bin/env bash
# enforce_semver_tag_via_script.sh -- Claude Code PreToolUse hook (matcher: Bash).
#
# DENIES ad-hoc `git tag v*` / `git push.*v[0-9]` / `git push --tags`
# invocations. Forces the caller through .claude/scripts/release-tag.sh,
# which encodes:
#   - .version integrity check
#   - RC tag + CI requirement for Y / X bumps
#   - RELEASE_X_BUMP_ACK consent gate for X bumps
#
# Why split this from check_tag_version_consistency.sh: that hook checks
# integrity only and lets ad-hoc tagging through whenever .version
# matches. Issue #106 widens the rule to RC + ACK; rather than expand
# the integrity hook, this dedicated boundary guard forces traffic
# through the canonical script and lets the script own all logic.
#
# Out of scope (pass through silently):
#   - `git tag` with no args (list)
#   - `git tag -l` / `git tag --list`
#   - `git tag -d <tag>` / `git tag --delete <tag>` (delete)
#   - `git push <remote> :v...` (delete by refspec)
#   - `git push <remote>` without a v-tag refspec (normal branch push)
#
# Refs: issue ycpss91255-docker/docker_harness#106.

set -uo pipefail

main() {
  local input cmd
  input="$(cat)"
  cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  [[ -z "${cmd}" ]] && return 0

  # Skip listing forms.
  if [[ "${cmd}" =~ git[[:space:]]+(-[A-Za-z]+[[:space:]]+[^[:space:]]+[[:space:]]+)*tag[[:space:]]+(-l|--list)([[:space:]]|$) ]]; then
    return 0
  fi

  # Skip delete forms.
  [[ "${cmd}" == *"git tag -d"* || "${cmd}" == *"git tag --delete"* ]] && return 0
  if [[ "${cmd}" =~ git[[:space:]]+(-[A-Za-z]+[[:space:]]+[^[:space:]]+[[:space:]]+)*push[[:space:]]+[^[:space:]]+[[:space:]]+:v[0-9] ]]; then
    return 0
  fi

  # Detection: `git tag ... v<digit>` (annotated or lightweight create).
  local matched=0
  if [[ "${cmd}" =~ git[[:space:]]+(-[A-Za-z]+[[:space:]]+[^[:space:]]+[[:space:]]+)*tag([[:space:]]+(-a|-s|-u[[:space:]]+[^[:space:]]+|-f|--force|-m[[:space:]]*[^[:space:]]+|--message=[^[:space:]]+))*[[:space:]]+v[0-9] ]]; then
    matched=1
  # `git push <remote> vX.Y.Z` or `git push <remote> refs/tags/vX.Y.Z`.
  elif [[ "${cmd}" =~ git[[:space:]]+(-[A-Za-z]+[[:space:]]+[^[:space:]]+[[:space:]]+)*push[[:space:]]+[^[:space:]]+[[:space:]]+(refs/tags/)?v[0-9] ]]; then
    matched=1
  # `git push --tags` (bulk).
  elif [[ "${cmd}" =~ git[[:space:]]+(-[A-Za-z]+[[:space:]]+[^[:space:]]+[[:space:]]+)*push[[:space:]]+([^[:space:]]+[[:space:]]+)*--tags([[:space:]]|$) ]]; then
    matched=1
  fi

  (( matched )) || return 0

  local msg
  msg="release-tag flow gate (issue #106): ad-hoc \`git tag\` / \`git push\` for version tags is denied.
Use the canonical script:
  .claude/scripts/release-tag.sh <vX.Y.Z> -m \"<message>\"
X bump (e.g. v1.0.0) also requires explicit user ACK:
  RELEASE_X_BUMP_ACK=v1.0.0 .claude/scripts/release-tag.sh v1.0.0 -m \"...\"
The script encodes:
  - .version integrity check
  - RC tag + CI requirement for Y / X bumps
  - X-bump ACK gate
See .claude/skills/semver-bump/SKILL.md for the full workflow."

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
