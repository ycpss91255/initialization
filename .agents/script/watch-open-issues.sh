#!/usr/bin/env bash
# watch-open-issues.sh — poll a GitHub repo's OPEN issues and print a change
# report whenever any open issue is created, updated, or closed.
#
# Designed to be wrapped in a SINGLE Monitor call from the maintainer's
# session (same pattern as auto-merge-on-green.sh / wait-pr-ci.sh): the poll
# loop lives HERE, not inline in the Monitor command, so Claude Code's bash
# AST parser does not choke on parameter expansions / `[[ ... ]]`, and so
# Monitor emits an event only when this script prints a change report.
#
# Division of labour:
#   - `watch_issues_diff` is a PURE function: it reads two snapshot files and
#     prints NEW/UPDATED/CLOSED lines. No network, fully unit-testable.
#   - `main` does the gh fetch + baseline + sleep loop, calling the diff.
#
# Snapshot format (one line per open issue, sorted by number):
#   <number>\t<updatedAt>\t<title>
#
# Usage:
#   watch-open-issues.sh --repo <OWNER>/<REPO> [options]
#
# Options:
#   --repo <OWNER>/<REPO>  GitHub repo (required)
#   --interval <seconds>   Poll interval, positive integer >= 1 (default 180)
#   --state-file <path>    Snapshot file to diff against (default: a mktemp).
#                          If it already holds a snapshot, the first cycle
#                          reports changes against it instead of arming fresh.
#   --once                 Do a single check-and-print, then exit (for tests
#                          and one-shot Monitor probes).
#   -h, --help             Show this help (exit 0)
#
# Exit:
#   0   = normal (a poll cycle completed, or --help). Transient gh fetch
#         failures warn and do NOT change the exit code.
#   2   = arg error (missing/unknown flag)
#
# Output:
#   On the first (arming) cycle: one line `watch armed: N issues`.
#   Thereafter, only when something changed: a dated header
#   `== issue changes: <UTC> ==` followed by the NEW/UPDATED/CLOSED lines.
#   Quiet otherwise, so Monitor fires only on real changes.

set -uo pipefail

usage() {
  sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

err() {
  printf '[watch-issues] ERROR: %s\n' "$*" >&2
}

warn() {
  printf '[watch-issues] WARN: %s\n' "$*" >&2
}

# watch_issues_diff <prev_file> <cur_file>
#
# PURE: compares two snapshot files (each "<number>\t<updatedAt>\t<title>",
# sorted by number) and prints, in a deterministic order:
#   NEW #<n> <title>       number present in cur, absent from prev
#   UPDATED #<n> <title>   number in both, updatedAt differs
#   CLOSED #<n>            number present in prev, absent from cur
# No output when nothing changed. Reads only the two files — no network.
watch_issues_diff() {
  local prev_file="$1" cur_file="$2"
  local num ts title
  local -A prev_ts=() cur_seen=()

  # Load prev snapshot into an associative array (empty file => no entries).
  # `|| [[ -n "$num" ]]` also consumes a final line with no trailing newline.
  while IFS=$'\t' read -r num ts title || [[ -n "$num" ]]; do
    [[ -n "$num" ]] || continue
    prev_ts["$num"]="$ts"
  done < "$prev_file"

  # Walk cur (sorted by number): emit NEW / UPDATED in number order.
  while IFS=$'\t' read -r num ts title || [[ -n "$num" ]]; do
    [[ -n "$num" ]] || continue
    cur_seen["$num"]=1
    if [[ -z "${prev_ts[$num]+set}" ]]; then
      printf 'NEW #%s %s\n' "$num" "$title"
    elif [[ "${prev_ts[$num]}" != "$ts" ]]; then
      printf 'UPDATED #%s %s\n' "$num" "$title"
    fi
  done < "$cur_file"

  # Walk prev (sorted by number): numbers no longer present are CLOSED.
  while IFS=$'\t' read -r num ts title || [[ -n "$num" ]]; do
    [[ -n "$num" ]] || continue
    if [[ -z "${cur_seen[$num]+set}" ]]; then
      printf 'CLOSED #%s\n' "$num"
    fi
  done < "$prev_file"
}

# _snapshot <repo> — print the current open-issue snapshot to stdout, one
# "<number>\t<updatedAt>\t<title>" line per issue, sorted by number. Returns
# non-zero (via pipefail) if the gh fetch fails, so the caller can warn.
_snapshot() {
  local repo="$1"
  gh issue list --repo "$repo" --state open --limit 300 \
       --json number,updatedAt,title \
    | jq -r '.[] | [.number, .updatedAt, .title] | @tsv' \
    | sort -n
}

# _check_cycle <repo> <state_file> — one fetch + (arm | diff + update).
# Warns and returns 0 on a transient fetch failure so the poll loop survives.
_check_cycle() {
  local repo="$1" state_file="$2"
  local armed_flag="${state_file}.armed"
  local cur changes
  cur="$(mktemp)"

  if ! _snapshot "$repo" > "$cur"; then
    warn "gh issue fetch failed for ${repo}; will retry next cycle"
    rm -f "$cur"
    return 0
  fi

  # Arm the baseline on the first cycle only. "Armed" is tracked by a sentinel
  # flag file rather than by state-file non-emptiness, so a repo with zero open
  # issues (empty-but-armed baseline) stays quiet instead of re-arming — and
  # emitting `watch armed: 0 issues` — on every poll. A pre-populated
  # state-file counts as already armed, so it diffs on the first cycle
  # (the documented --state-file behaviour).
  if [[ ! -f "$armed_flag" && ! -s "$state_file" ]]; then
    mv "$cur" "$state_file"
    : > "$armed_flag"
    printf 'watch armed: %s issues\n' "$(wc -l < "$state_file" | tr -d ' ')"
    return 0
  fi

  changes="$(watch_issues_diff "$state_file" "$cur")"
  if [[ -n "$changes" ]]; then
    printf '== issue changes: %s ==\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s\n' "$changes"
  fi
  mv "$cur" "$state_file"
  : > "$armed_flag"
  return 0
}

main() {
  local repo="" interval=180 state_file="" once=0

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)    usage; exit 0 ;;
      # Value flags: fail fast (exit 2) when the value is missing rather than
      # letting `shift 2` no-op on the last token and spin the while loop.
      --repo)       [[ $# -ge 2 ]] || { err "--repo needs a value"; exit 2; }; repo="$2"; shift 2 ;;
      --interval)   [[ $# -ge 2 ]] || { err "--interval needs a value"; exit 2; }; interval="$2"; shift 2 ;;
      --state-file) [[ $# -ge 2 ]] || { err "--state-file needs a value"; exit 2; }; state_file="$2"; shift 2 ;;
      --once)       once=1; shift ;;
      *)            err "unknown arg: $1"; usage; exit 2 ;;
    esac
  done

  [[ -n "$repo" ]] || { err "--repo is required"; usage; exit 2; }
  # A poll interval of 0 would busy-spin the gh fetch with no delay, so require
  # a positive integer (>= 1) rather than merely non-negative. Explicit if/
  # early-return (not `A && B || C`, which trips SC2015 and is not if-then-else).
  if ! [[ "$interval" =~ ^[0-9]+$ ]] || (( interval < 1 )); then
    err "--interval must be a positive integer (>= 1)"
    exit 2
  fi
  [[ -n "$state_file" ]] || state_file="$(mktemp)"

  _check_cycle "$repo" "$state_file"

  if (( once )); then
    exit 0
  fi

  while true; do
    sleep "$interval"
    _check_cycle "$repo" "$state_file"
  done
}

# Only run when executed, not when sourced (so tests can source the pure
# `watch_issues_diff` without triggering the poll loop).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
