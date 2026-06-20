#!/usr/bin/env bash
# auto-merge-on-green.sh — arm GitHub native auto-merge on a PR, then poll
# until it lands, handling strict-branch-protection staleness on the way.
#
# Designed to be wrapped in a SINGLE Monitor call from the
# auto-merge-on-green skill. The loop lives here (not inline in the Monitor
# command) so Claude Code's bash AST parser does not choke on parameter
# expansions / `[[ ... ]]` (see wait-pr-ci.sh for the same rationale).
#
# Division of labour (refs #154):
#   - GitHub performs the actual merge server-side (`gh pr merge --auto`), so
#     it lands even if this script / the session dies.
#   - This script's job is to ARM auto-merge, give the operator one snapshot
#     per state transition, and keep auto-merge UNBLOCKED under `strict`
#     branch protection by running `gh pr update-branch` whenever the PR falls
#     BEHIND (GitHub native auto-merge does NOT auto-update a stale branch).
#
# Usage:
#   auto-merge-on-green.sh --repo <OWNER>/<REPO> --pr <N> [options]
#
# Options:
#   --repo <OWNER>/<REPO>  GitHub repo (required)
#   --pr <N>               PR number (required)
#   --merge-method <m>     squash|merge|rebase (default squash)
#   --no-delete-branch     Do not pass --delete-branch when arming
#   --no-arm               Skip the `gh pr merge --auto` arm step (poll only;
#                          used by tests and when auto-merge is pre-armed)
#   --interval <seconds>   Poll interval (default 30; 0 = no sleep, for tests)
#   --grace <seconds>      How long to tolerate a non-progressing BLOCKED
#                          state (blocked by something other than a running
#                          or failed check, e.g. a required review, or a repo
#                          with no CI that never merges) before bailing.
#                          Default 90. 0 disables the grace bail.
#   --retrigger-grace <s>  How long to tolerate ci=none (no workflow run on the
#                          head SHA — e.g. a push that lost a concurrency race
#                          and created no run) before re-triggering CI by
#                          pushing an empty commit via the git API. Fires at
#                          most once per run. Default 180. 0 = fire on first
#                          observation (used by tests).
#   --no-retrigger         Disable the ci=none re-trigger entirely.
#   --max-iterations <N>   Iteration cap (default 0 = unlimited; for tests)
#   -h, --help             Show this help
#
# Exit:
#   0   = MERGED (GitHub landed the PR)
#   1   = FAIL — required check failed, merge conflict (DIRTY), PR closed
#         unmerged, or grace exhausted while BLOCKED. Auto-merge is left
#         ARMED on check-failure so a fix-push merges automatically.
#   2   = arg error
#   124 = max-iterations exhausted without resolution
#
# Output (per state transition):
#   PR<n>: state=<OPEN|MERGED|CLOSED> merge=<mergeStateStatus> ci=<pass|pending|fail|none>
#   ---
# Final line: `MERGED`, or `FAIL <reason>`.

set -euo pipefail

# Check conclusions that mean a check is done and did NOT pass.
readonly FAIL_CONCLUSIONS='["FAILURE","TIMED_OUT","CANCELLED","ACTION_REQUIRED","STARTUP_FAILURE","STALE","ERROR"]'

usage() {
  sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

err() {
  printf '[auto-merge] ERROR: %s\n' "$*" >&2
}

# Re-trigger CI when the head SHA has no workflow run at all. Pushes an empty
# commit (same tree, parent = current head) via the git API so a `synchronize`
# event fires — no local checkout needed, so it works from a detached Monitor.
# Best-effort: every step is guarded; returns non-zero on any failure so the
# caller can keep polling rather than abort.
_retrigger_ci() {
  local repo="$1" pr="$2"
  local pull head_sha branch commit tree_sha new_sha
  pull=$(gh api "repos/${repo}/pulls/${pr}" 2>/dev/null || echo '')
  head_sha=$(jq -r '.head.sha // empty' <<< "${pull}" 2>/dev/null)
  branch=$(jq -r '.head.ref // empty' <<< "${pull}" 2>/dev/null)
  [[ -n "${head_sha}" && -n "${branch}" ]] || { err "re-trigger: cannot read PR head"; return 1; }
  commit=$(gh api "repos/${repo}/git/commits/${head_sha}" 2>/dev/null || echo '')
  tree_sha=$(jq -r '.tree.sha // empty' <<< "${commit}" 2>/dev/null)
  [[ -n "${tree_sha}" ]] || { err "re-trigger: cannot read head tree"; return 1; }
  new_sha=$(gh api "repos/${repo}/git/commits" \
              -f "message=ci: re-trigger (no workflow run on head)" \
              -f "tree=${tree_sha}" -f "parents[]=${head_sha}" 2>/dev/null \
            | jq -r '.sha // empty' 2>/dev/null)
  [[ -n "${new_sha}" ]] || { err "re-trigger: cannot create empty commit"; return 1; }
  gh api "repos/${repo}/git/refs/heads/${branch}" -X PATCH -f "sha=${new_sha}" >/dev/null 2>&1 \
    || { err "re-trigger: cannot move branch ref"; return 1; }
  return 0
}

main() {
  local repo="" pr="" merge_method="squash" delete_branch=1 arm=1
  local interval=30 grace=90 max_iter=0 retrigger=1 retrigger_grace=180

  while (( $# > 0 )); do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --repo) repo="$2"; shift 2 ;;
      --pr) pr="$2"; shift 2 ;;
      --merge-method) merge_method="$2"; shift 2 ;;
      --no-delete-branch) delete_branch=0; shift ;;
      --no-arm) arm=0; shift ;;
      --interval) interval="$2"; shift 2 ;;
      --grace) grace="$2"; shift 2 ;;
      --retrigger-grace) retrigger_grace="$2"; shift 2 ;;
      --no-retrigger) retrigger=0; shift ;;
      --max-iterations) max_iter="$2"; shift 2 ;;
      *) err "unknown arg: $1"; usage; exit 2 ;;
    esac
  done

  [[ -n "${repo}" ]] || { err "--repo is required"; exit 2; }
  [[ "${pr}" =~ ^[0-9]+$ ]] || { err "--pr must be a number (got: ${pr:-})"; exit 2; }
  case "${merge_method}" in squash|merge|rebase) : ;; *) err "--merge-method must be squash|merge|rebase"; exit 2 ;; esac
  [[ "${grace}" =~ ^[0-9]+$ ]] || { err "--grace must be a non-negative integer"; exit 2; }
  [[ "${retrigger_grace}" =~ ^[0-9]+$ ]] || { err "--retrigger-grace must be a non-negative integer"; exit 2; }

  # Arm GitHub native auto-merge. Non-fatal on error: the PR may already be
  # armed, or already mergeable (GitHub merges immediately) — the poll loop
  # below resolves the real outcome either way.
  if (( arm )); then
    local -a arm_cmd=(gh pr merge "${pr}" --repo "${repo}" --auto "--${merge_method}")
    (( delete_branch )) && arm_cmd+=(--delete-branch)
    if ! "${arm_cmd[@]}" >/dev/null 2>&1; then
      printf '[arm] auto-merge not newly armed (already armed, already merging, or arm refused) — polling state\n'
    fi
  fi

  local prev="" iter=0 blocked_since=0 noci_since=0 retriggered=0 now
  while true; do
    iter=$((iter + 1))

    local view state mss
    view=$(gh pr view "${pr}" --repo "${repo}" \
             --json state,mergeStateStatus,statusCheckRollup 2>/dev/null || echo '')
    if [[ -z "${view}" ]]; then
      printf 'PR%s: state=UNKNOWN merge=UNKNOWN ci=none\n---\n' "${pr}"
      err "cannot read PR ${pr} on ${repo} (does it exist?)"
      exit 1
    fi

    state=$(jq -r '.state // "UNKNOWN"' <<< "${view}")
    mss=$(jq -r '.mergeStateStatus // "UNKNOWN"' <<< "${view}")

    # Classify CI rollup: pending (any check not COMPLETED), fail (any
    # COMPLETED check with a non-pass conclusion), pass (>=1 check, all
    # COMPLETED + passing), none (no checks at all).
    local ci
    ci=$(jq -r --argjson failc "${FAIL_CONCLUSIONS}" '
      [.statusCheckRollup[]?] as $c
      | if ($c | length) == 0 then "none"
        elif ($c | any(.status != null and .status != "COMPLETED")) then "pending"
        elif ($c | any(.conclusion as $x | $failc | index($x))) then "fail"
        else "pass" end' <<< "${view}")

    local line="PR${pr}: state=${state} merge=${mss} ci=${ci}"
    case "${line}" in
      "${prev}") : ;;
      *) printf '%s\n---\n' "${line}" ;;
    esac
    prev="${line}"

    # Terminal: merged.
    if [[ "${state}" == "MERGED" ]]; then
      echo "MERGED"
      exit 0
    fi
    # Terminal: closed without merging.
    if [[ "${state}" == "CLOSED" ]]; then
      printf 'FAIL closed-unmerged\n'
      exit 1
    fi
    # Terminal: merge conflict — needs a rebase, polling will not fix it.
    if [[ "${mss}" == "DIRTY" ]]; then
      printf 'FAIL conflict (mergeStateStatus=DIRTY). Rebase the branch onto the base, then re-run.\n'
      exit 1
    fi
    # Terminal: a required check failed (CI done, not all passing, merge
    # blocked). Auto-merge stays armed so a fix-push merges automatically.
    if [[ "${ci}" == "fail" && "${mss}" == "BLOCKED" ]]; then
      printf 'FAIL check (a required check did not pass; auto-merge left armed for a fix-push)\n'
      exit 1
    fi
    # Stale base under `strict` protection: GitHub will not auto-update, so
    # nudge it. Re-triggers CI; next polls re-evaluate the new head.
    if [[ "${mss}" == "BEHIND" ]]; then
      gh pr update-branch "${pr}" --repo "${repo}" >/dev/null 2>&1 || true
    fi

    # No workflow run on the head at all (ci=none) — e.g. a push that lost a
    # concurrency race created no run, so auto-merge would wait forever. After
    # retrigger_grace seconds, push an empty commit to force a run. Once per
    # run (retriggered guard) so we don't spam the branch. BEHIND/DIRTY are
    # handled above; only act on an otherwise-OPEN, run-less head.
    if (( retrigger )) && [[ "${ci}" == "none" && "${mss}" != "BEHIND" && "${mss}" != "DIRTY" ]]; then
      now=$(date -u +%s)
      if (( noci_since == 0 )); then noci_since=${now}; fi
      if (( ! retriggered && now - noci_since >= retrigger_grace )); then
        printf 'PR%s: no CI run on head for >=%ss — re-triggering via empty commit\n---\n' "${pr}" "${retrigger_grace}"
        if _retrigger_ci "${repo}" "${pr}"; then
          printf '[retrigger] pushed an empty commit to force a CI run\n'
        else
          printf '[retrigger] re-trigger failed; will keep polling\n'
        fi
        retriggered=1
        noci_since=0
      fi
    else
      noci_since=0
    fi

    # Grace bail: BLOCKED with nothing pending and no failed check means
    # blocked by something this script can't drive (e.g. a required review),
    # or a repo whose merge requirements never clear. Don't spin forever.
    if [[ "${mss}" == "BLOCKED" && "${ci}" != "pending" && "${ci}" != "fail" ]]; then
      now=$(date -u +%s)
      if (( blocked_since == 0 )); then blocked_since=${now}; fi
      if (( grace > 0 && now - blocked_since >= grace )); then
        printf 'FAIL blocked (mergeStateStatus=BLOCKED for >%ss with no pending/failed check — needs a review or other gate)\n' "${grace}"
        exit 1
      fi
    else
      blocked_since=0
    fi

    if (( max_iter > 0 && iter >= max_iter )); then
      err "max-iterations (${max_iter}) reached"
      exit 124
    fi

    (( interval > 0 )) && sleep "${interval}"
  done
}

main "$@"
