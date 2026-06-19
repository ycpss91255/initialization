#!/usr/bin/env bash
# release-tag.sh -- canonical primitive for cutting version tags.
#
# Enforces the project's semver workflow (aligned with
# ycpss91255-docker/docker_harness#106):
#   - vX.Y.Z-rcN (RC tag itself): tag + push, skip RC / ACK checks.
#   - vX.Y.Z where Z>0 (Z bump, bug fix): tag + push, skip RC / ACK.
#   - vX.Y.0 where Y > prev_Y (Y bump = feature / behaviour / break):
#       require prior vX.Y.0-rcN with all CI conclusions success/skipped.
#   - vX.0.0 where X > prev_X (X bump = ceremonial):
#       above PLUS require RELEASE_X_BUMP_ACK=<exact-tag> env var.
# Also requires `.version` (if present at repo root) to equal the tag.
#
# Usage:
#   release-tag.sh <tag> [-m <msg>] [--dry-run] [--repo <owner/repo>]
#
# Env:
#   RELEASE_X_BUMP_ACK=<tag>  -- mandatory for X bumps; must match <tag>.
#
# Exit:
#   0  = success (or dry-run preview)
#   1  = blocked by rule violation (missing RC / failing RC CI / ACK)
#   2  = arg or parse error / .version mismatch

set -uo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: release-tag.sh <tag> [options]

Tag shape: vX.Y.Z or vX.Y.Z-rcN (X/Y/Z = digits; N = digits).

Options:
  -m, --message <msg>     Annotation body (default: tag literal)
      --dry-run           Print planned actions, no tag/push
      --repo <owner/repo> Override `gh` repo for the RC CI query
                          (defaults to whatever `gh` resolves from cwd)
  -h, --help              Show this help

Environment:
  RELEASE_X_BUMP_ACK      Required for X-bump (vX.0.0 where X bumped).
                          Value must equal the tag literal verbatim.

Rules (init_ubuntu / docker_harness#106):
  vX.Y.Z-rcN -> tag + push (no RC, no ACK)
  vX.Y.Z (Z>0) -> tag + push (no RC, no ACK)
  vX.Y.0 (Y bumped) -> require passing vX.Y.0-rcN CI
  vX.0.0 (X bumped) -> require passing RC AND RELEASE_X_BUMP_ACK=<tag>

Companion: .claude/skills/semver-bump/SKILL.md, doc/process/release.md.
EOF
}

err() { printf '%s\n' "$*" >&2; }

# do_tag_push <tag> <message> <dry_run>
do_tag_push() {
  local tag="$1" message="$2" dry_run="$3"
  [[ -z "${message}" ]] && message="${tag}"
  if (( dry_run )); then
    printf '[dry-run] would tag: git tag -a %s -m %q\n' "${tag}" "${message}"
    printf '[dry-run] would push: git push origin %s\n' "${tag}"
    return 0
  fi
  git tag -a "${tag}" -m "${message}" || return $?
  git push origin "${tag}" || return $?
  printf 'tagged + pushed %s\n' "${tag}"
}

# check_rc <target-tag> <repo-override>
# Returns 0 if any matching RC tag has all CI conclusions in {success, skipped}.
check_rc() {
  local target="$1" repo_override="$2"
  local rc_glob="${target}-rc*"

  local rc_tags
  rc_tags="$(git tag --list "${rc_glob}" --sort=-v:refname 2>/dev/null)"
  if [[ -z "${rc_tags}" ]]; then
    err "no RC tag found for ${target}."
    err "  Y/X bump requires a prior ${target}-rcN. Cut RC first:"
    err "    release-tag.sh ${target}-rc1 -m '<rc1 release notes>'"
    err "  See .claude/skills/semver-bump/SKILL.md."
    return 1
  fi

  local rc_arg=()
  [[ -n "${repo_override}" ]] && rc_arg=(--repo "${repo_override}")

  local rc
  while IFS= read -r rc; do
    [[ -z "${rc}" ]] && continue
    local conclusions
    conclusions="$(gh run list "${rc_arg[@]}" --branch "${rc}" \
                    --json conclusion --jq '.[].conclusion' 2>/dev/null \
                    || true)"
    if [[ -z "${conclusions}" ]]; then
      continue
    fi
    local all_ok=1
    local c
    while IFS= read -r c; do
      [[ -z "${c}" ]] && continue
      case "${c}" in
        success|skipped) : ;;
        *) all_ok=0; break ;;
      esac
    done <<< "${conclusions}"
    if (( all_ok )); then
      printf 'OK: %s CI all success/skipped.\n' "${rc}"
      return 0
    fi
  done <<< "${rc_tags}"

  err "no RC tag with passing CI found for ${target}."
  err "  Latest RC tags:"
  while IFS= read -r rc; do
    [[ -n "${rc}" ]] && err "    ${rc}"
  done <<< "${rc_tags}"
  err "  Cut a new rcN+1 after fixing CI."
  return 1
}

main() {
  local tag="" message="" dry_run=0 repo=""
  while (( $# > 0 )); do
    case "$1" in
      -h|--help) usage; return 0 ;;
      -m|--message)
        [[ $# -ge 2 ]] || { err "missing value for $1"; return 2; }
        message="$2"; shift 2 ;;
      --message=*) message="${1#--message=}"; shift ;;
      --dry-run) dry_run=1; shift ;;
      --repo)
        [[ $# -ge 2 ]] || { err "missing value for --repo"; return 2; }
        repo="$2"; shift 2 ;;
      --repo=*) repo="${1#--repo=}"; shift ;;
      v[0-9]*)
        [[ -z "${tag}" ]] || { err "duplicate tag arg: $1"; return 2; }
        tag="$1"; shift ;;
      -*) err "unknown flag: $1"; return 2 ;;
      *) err "unexpected arg: $1"; return 2 ;;
    esac
  done

  if [[ -z "${tag}" ]]; then
    err "missing <tag>"
    usage
    return 2
  fi

  if ! [[ "${tag}" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)(-rc([0-9]+))?$ ]]; then
    err "invalid tag shape: ${tag} (expected vX.Y.Z or vX.Y.Z-rcN)"
    return 2
  fi
  local x="${BASH_REMATCH[1]}" z="${BASH_REMATCH[3]}"
  local rc_suffix="${BASH_REMATCH[4]:-}"
  # BASH_REMATCH[2] (Y digit) is not used in the decision tree -- once we
  # reach the vX.Y.0 branch, X-bump-vs-Y-bump is decided by comparing X
  # against prev_X (anything not an X bump is treated as Y).

  local repo_root
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "${repo_root}" && -f "${repo_root}/.version" ]]; then
    local recorded
    recorded="$(tr -d '[:space:]' < "${repo_root}/.version" 2>/dev/null)"
    if [[ -n "${recorded}" && "${recorded}" != "${tag}" ]]; then
      err "tag-version mismatch: attempting ${tag} but .version says ${recorded}."
      err "  Run /release (chore PR that bumps .version + promotes CHANGELOG)"
      err "  before tagging."
      return 2
    fi
  fi

  # RC tag itself: short-circuit.
  if [[ -n "${rc_suffix}" ]]; then
    do_tag_push "${tag}" "${message}" "${dry_run}"
    return $?
  fi

  # Z>0 patch: short-circuit.
  if (( z > 0 )); then
    do_tag_push "${tag}" "${message}" "${dry_run}"
    return $?
  fi

  # vX.Y.0 — Y or X bump path.
  local prev_max prev_x=0
  prev_max="$(git tag --list 'v*' --sort=-v:refname 2>/dev/null \
              | grep -vE -- '-rc[0-9]+$' \
              | head -n1 \
              || true)"
  if [[ -n "${prev_max}" && "${prev_max}" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    prev_x="${BASH_REMATCH[1]}"
  fi

  if (( x > prev_x )); then
    local ack="${RELEASE_X_BUMP_ACK:-}"
    if [[ -z "${ack}" ]]; then
      err "X bump (${prev_max:-v0.0.0} -> ${tag}) requires explicit user consent."
      err "  After user OK in chat, re-run with the ACK env var:"
      err "    RELEASE_X_BUMP_ACK=${tag} .claude/script/release-tag.sh ${tag} ..."
      err "  See .claude/skills/semver-bump/SKILL.md."
      return 1
    fi
    if [[ "${ack}" != "${tag}" ]]; then
      err "RELEASE_X_BUMP_ACK='${ack}' does not match tag '${tag}'."
      err "  ACK value must equal the tag literal verbatim (prevents stale carry-over)."
      return 1
    fi
  fi

  check_rc "${tag}" "${repo}" || return 1
  do_tag_push "${tag}" "${message}" "${dry_run}"
}

main "$@"
