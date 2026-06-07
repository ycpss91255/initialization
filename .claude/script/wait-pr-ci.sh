#!/usr/bin/env bash
# wait-pr-ci.sh — poll GitHub PR CI rollup until all PRs settle.
#
# Designed to be wrapped in a single Monitor call from the wait-pr-ci
# skill. Extracting the loop here keeps the Monitor body to one line so
# Claude Code's bash AST parser does not emit `Contains simple_expansion`
# warnings on parameter expansions like ${pair%:*}.
#
# Usage:
#   wait-pr-ci.sh --repo <OWNER>/<REPO> --prs <N1,N2,...> [options]
#
# Options:
#   --repo <OWNER>/<REPO>     GitHub repo (required)
#   --prs <CSV>               Comma-separated PR numbers (required)
#   --check-filter <jq-expr>  jq inner expression filtering
#                             .statusCheckRollup[]?. Default:
#                             '.name=="test" or (.name|startswith("Integration"))'
#   --min-checks <N>          Minimum number of filter-matched checks
#                             required before "all-pass" is allowed.
#                             Default 1 (backwards-compatible). Set to the
#                             count of required-check names the workflow
#                             ought to register to guard against GitHub's
#                             PR rollup briefly returning a SUBSET of
#                             expected checks right after PR creation
#                             (e.g. for the default filter `test +
#                             Integration ...` use --min-checks 2). When
#                             length < N the state is "pending", not
#                             "all-pass".
#   --interval <seconds>      Poll interval (default 45; 0 = no sleep, for tests)
#   --stale-window <seconds>  Width of the post-force-push stale-rollup
#                             race window (default 120). The watch-start
#                             completedAt guard only demotes to "pending"
#                             when every matching check completed
#                             AFTER (watch_start - stale_window); checks
#                             that completed earlier than that are
#                             trusted as a legitimate prior run, fixing
#                             issue #22 (post-completion launch hung
#                             forever). 0 = restore pre-fix behaviour
#                             (always demote when completedAt <
#                             watch_start); large value = effectively
#                             disable the guard.
#
# Stale-rollup guards (refs ycpss91255-docker/docker_harness#60, ycpss91255/initialization#22):
#   * Watch-start completedAt guard — if every filter-matched check has
#     watch_start - stale_window < completedAt < watch_start, the rollup
#     is showing carry-over results from a previous head (typically
#     because the agent ran this script immediately after a `git push
#     --force-with-lease` and GitHub has not yet re-triggered CI).
#     Demoted to "pending" rather than declared "all-pass". When checks
#     completed earlier than that window, they are trusted as a
#     legitimate prior run rather than stale rollup (post-completion
#     launch case, #22). Backwards-compatible: only fires when every
#     matching check has completedAt set (real GitHub API always sets
#     it; existing test stubs that omit it keep working).
#   * headRefOid change guard — on each poll, compare current
#     headRefOid against the value seen on the previous poll. When it
#     changes, emit one `[head-moved] PR<n> <old7>..<new7>` log line and
#     force the per-PR state to "pending" for this poll iteration. The
#     next poll re-evaluates against the new head normally.
#   --max-iterations <N>      Iteration cap (default 0 = unlimited; for tests)
#   -h, --help                Show this help
#
# Exit:
#   0   = ALL_DONE — every PR is all-pass + MERGEABLE
#   1   = FAIL     — any required check went FAILURE
#   2   = arg error
#   124 = max-iterations exhausted without resolution
#
# Output (per state transition):
#   PR<n>: checks=<state> mergeable=<m>
#   ...
#   ---
# Final line: `ALL_DONE` or `FAIL <pr>`.

set -euo pipefail

readonly DEFAULT_FILTER='.name=="test" or (.name|startswith("Integration"))'

usage() {
  sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

err() {
  printf '[wait-pr-ci] ERROR: %s\n' "$*" >&2
}

main() {
  local repo=""
  local prs_csv=""
  local check_filter="${DEFAULT_FILTER}"
  local min_checks=1
  local interval=45
  local max_iter=0
  local stale_window=120

  while (( $# > 0 )); do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --repo) repo="$2"; shift 2 ;;
      --prs) prs_csv="$2"; shift 2 ;;
      --check-filter) check_filter="$2"; shift 2 ;;
      --min-checks) min_checks="$2"; shift 2 ;;
      --interval) interval="$2"; shift 2 ;;
      --stale-window) stale_window="$2"; shift 2 ;;
      --max-iterations) max_iter="$2"; shift 2 ;;
      *) err "unknown arg: $1"; usage; exit 2 ;;
    esac
  done

  if ! [[ "${min_checks}" =~ ^[0-9]+$ ]] || (( min_checks < 1 )); then
    err "--min-checks must be a positive integer (got: ${min_checks})"
    exit 2
  fi

  if ! [[ "${stale_window}" =~ ^[0-9]+$ ]]; then
    err "--stale-window must be a non-negative integer (got: ${stale_window})"
    exit 2
  fi

  if [[ -z "${repo}" ]]; then
    err "--repo is required"
    exit 2
  fi
  if [[ -z "${prs_csv}" ]]; then
    err "--prs is required"
    exit 2
  fi

  local -a prs
  IFS=',' read -ra prs <<< "${prs_csv}"

  local watch_start
  watch_start=$(date -u +%s)

  local -A head_oid_by_pr=()

  local prev=""
  local iter=0
  while true; do
    iter=$((iter + 1))

    local out=""
    local all_ready=1
    local fail_pr="" fail_reason=""

    local pr
    for pr in "${prs[@]}"; do
      local s
      s=$(gh pr view "${pr}" --repo "${repo}" \
            --json mergeable,statusCheckRollup,headRefOid 2>/dev/null \
          || echo '{}')

      # headRefOid stale-rollup guard. Compare PR head against the
      # value seen on the previous poll; on change, emit one
      # `[head-moved] PR<n> <old7>..<new7>` log line so the operator
      # knows the CI signal needs to be re-evaluated against the new
      # head. head_moved is checked below so the all-pass demotion
      # cannot fire on the same iteration as a head move.
      local current_oid prev_oid head_moved=0
      current_oid=$(jq -r '.headRefOid // ""' <<< "${s}")
      prev_oid="${head_oid_by_pr[${pr}]:-}"
      if [[ -n "${prev_oid}" && -n "${current_oid}" \
            && "${current_oid}" != "${prev_oid}" ]]; then
        head_moved=1
        printf '[head-moved] PR%s %s..%s\n' \
          "${pr}" "${prev_oid:0:7}" "${current_oid:0:7}"
      fi
      head_oid_by_pr["${pr}"]="${current_oid}"

      # Two guards above the original `all(.conclusion == "SUCCESS")` to fix
      # premature ALL_DONE seen in practice (refs ycpss91255-docker/docker_harness#XX):
      #
      #  (a) `length < min_checks`  — GitHub's PR rollup briefly returns a
      #      SUBSET of expected checks right after PR creation; if all visible
      #      ones happen to be SUCCESS, jq's `all([SUCCESS]) == true` reports
      #      false all-pass. Caller passes --min-checks to assert the
      #      filter-matched count.
      #  (b) `any(.status != "COMPLETED")` — when a check is registered but
      #      still IN_PROGRESS / QUEUED, .conclusion is "" so the original
      #      `all(.conclusion == "SUCCESS")` correctly reports false; but
      #      this guard catches the same case earlier and produces a more
      #      meaningful "pending" label. The `.status != null` precondition
      #      preserves backward compatibility with mocks that only set
      #      .conclusion (real GitHub API always populates .status).
      # The watch-start completedAt guard is appended inside the
      # all(.conclusion == "SUCCESS") branch: if every matching check
      # has completedAt set AND every one of those completedAt values
      # is older than the watch start time, the rollup is carry-over
      # from a prior head; demote to "pending". The
      # `all(.completedAt != null)` precondition keeps mocks that omit
      # completedAt working unchanged.
      local state
      state=$(jq -r --argjson min "${min_checks}" \
        --argjson watch_start "${watch_start}" \
        --argjson stale_window "${stale_window}" \
        "[.statusCheckRollup[]? | select(${check_filter})] as \$c | \
        if (\$c | length) == 0 then \"no-checks\" \
        elif (\$c | length) < \$min then \"pending\" \
        elif (\$c | any(.status != null and .status != \"COMPLETED\")) then \"pending\" \
        elif (\$c | all(.conclusion == \"SUCCESS\" or .conclusion == \"SKIPPED\")) then \
          (if (\$c | all(.completedAt != null)) \
              and (\$c | all((.completedAt | fromdateiso8601) < \$watch_start)) \
              and (\$c | all((.completedAt | fromdateiso8601) > (\$watch_start - \$stale_window))) \
           then \"pending\" else \"all-pass\" end) \
        elif (\$c | any(.conclusion == \"FAILURE\")) then \"FAIL\" \
        else \"pending\" end" <<< "${s}")

      if (( head_moved )) && [[ "${state}" == "all-pass" ]]; then
        state="pending"
      fi

      local m
      m=$(jq -r '.mergeable // "?"' <<< "${s}")

      out="${out}PR${pr}: checks=${state} mergeable=${m}"$'\n'

      # mergeable=CONFLICTING means main moved + the PR has merge conflicts.
      # No amount of polling will resolve this -- the head must be rebased.
      # Surface as FAIL with a rebase-pr.sh hint so the caller acts on it
      # (refs issue #87) rather than looping forever waiting for MERGEABLE.
      case "${state}" in
        FAIL) fail_pr="${pr}"; fail_reason="check"; all_ready=0 ;;
        all-pass)
          case "${m}" in
            MERGEABLE) : ;;
            CONFLICTING) fail_pr="${pr}"; fail_reason="conflict"; all_ready=0 ;;
            *) all_ready=0 ;;
          esac
          ;;
        *) all_ready=0 ;;
      esac
    done

    case "${out}" in
      "${prev}") : ;;
      *) printf '%s---\n' "${out}" ;;
    esac
    prev="${out}"

    if [[ -n "${fail_pr}" ]]; then
      case "${fail_reason:-}" in
        conflict)
          printf 'FAIL %s (mergeable=CONFLICTING). Rebase:\n  .claude/scripts/rebase-pr.sh %s --repo %s\nSee .claude/skills/rebase-pr/SKILL.md.\n' \
            "${fail_pr}" "${fail_pr}" "${repo}"
          ;;
        *)
          printf 'FAIL %s\n' "${fail_pr}"
          ;;
      esac
      exit 1
    fi

    if (( all_ready )); then
      echo "ALL_DONE"
      exit 0
    fi

    if (( max_iter > 0 && iter >= max_iter )); then
      err "max-iterations (${max_iter}) reached"
      exit 124
    fi

    if (( interval > 0 )); then
      sleep "${interval}"
    fi
  done
}

main "$@"
