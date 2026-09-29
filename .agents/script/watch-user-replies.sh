#!/usr/bin/env bash
# watch-user-replies.sh -- poll a GitHub repo's OPEN issues and PRs and print
# the maintainer's own comments that are NOT agent output.
#
# Companion to watch-open-issues.sh, which watches issue METADATA (new /
# updated / closed). This one watches COMMENT BODIES, to answer a different
# question: "has the human replied to me?"
#
# Designed to be wrapped in a SINGLE Monitor call (same pattern as
# auto-merge-on-green.sh / wait-pr-ci.sh): the poll loop lives HERE so
# Monitor emits an event only when a genuine reply appears.
#
# Division of labour:
#   - `watch_reply_is_user` and `watch_replies_filter` are PURE functions:
#     no network, fully unit-testable.
#   - `main` does the gh fetch + seed + sleep loop.
#
# What counts as a user reply:
#   a comment authored by --login whose body does NOT START with an agent
#   tag ([claude] or [codex]). The tag is matched at the START only. Matching
#   it ANYWHERE is wrong and was a real defect: a genuine acceptance report
#   that merely quoted "[codex]" in its prose was silently swallowed, and the
#   maintainer's findings sat unread. See test/unit/script/
#   watch_user_replies_spec.bats, "quoting an agent tag mid-body".
#
# Usage:
#   watch-user-replies.sh --repo <OWNER>/<REPO> --login <USER> [options]
#
# Options:
#   --repo <OWNER>/<REPO>  GitHub repo (required)
#   --login <USER>         Comment author to watch for (required)
#   --interval <seconds>   Poll interval, positive integer >= 1 (default 180)
#   --state-file <path>    File of already-seen comment ids, one per line
#                          (default: a mktemp). Reused across runs, so a
#                          restart does not re-announce old replies.
#   --seed                 Mark every current reply as seen WITHOUT printing,
#                          then exit. Use this when arming a fresh watch on a
#                          repo that already has history.
#   --once                 Do a single check-and-print, then exit (for tests
#                          and one-shot probes).
#   -h, --help             Show this help (exit 0)
#
# Exit:
#   0   = normal (a poll cycle completed, or --help / --seed). In the watch
#         loop a failed fetch does NOT change the exit code; it is reported
#         as a WATCH FETCH FAILED event instead (see Output).
#   1   = --seed could not read every thread; nothing was seeded
#   2   = arg error (missing/unknown flag, bad --interval)
#
# Output:
#   STDOUT carries ONLY events worth acting on, one per line: a reply the
#   human actually wrote,
#     USER REPLY on #<n> : <first 200 chars of the body, newlines folded>
#   plus one line per cycle in which any thread could not be read, so a
#   broken fetch is never mistaken for "no replies":
#     WATCH FETCH FAILED: <failed> of <total> thread(s) unreadable this cycle
#   Heartbeats and fetch warnings go to STDERR (logged, no notification).

set -uo pipefail

AGENT_TAGS=('[claude]' '[codex]')

# Set by main; the EXIT trap quotes it lazily so no SC2064 disable is needed.
WATCH_TMP=''

# watch_reply_is_user <login> <comment-login> <body>
#   0 = this comment is a human reply, 1 = it is agent output or someone else.
watch_reply_is_user() {
    local _want="$1" _got="$2" _body="$3" _tag
    [[ "${_got}" == "${_want}" ]] || return 1
    for _tag in "${AGENT_TAGS[@]}"; do
        # Anchored at the start on purpose; see the header note.
        [[ "${_body}" == "${_tag}"* ]] && return 1
    done
    return 0
}

# watch_replies_filter <login> <state-file> <tsv-file>
#   tsv-file lines: <issue-number>\t<comment-id>\t<comment-login>\t<body-base64>
#   Prints one event line per UNSEEN human reply and appends its id to the
#   state file. Base64 keeps multi-line bodies on a single TSV line.
watch_replies_filter() {
    local _login="$1" _state="$2" _tsv="$3"
    local _num _id _author _b64 _body _preview
    [[ -f "${_state}" ]] || : > "${_state}"
    while IFS=$'\t' read -r _num _id _author _b64; do
        [[ -n "${_id}" ]] || continue
        _body="$(printf '%s' "${_b64}" | base64 -d 2>/dev/null)"
        watch_reply_is_user "${_login}" "${_author}" "${_body}" || continue
        grep -qxF "${_id}" "${_state}" && continue
        printf '%s\n' "${_id}" >> "${_state}"
        _preview="$(printf '%s' "${_body}" | tr '\n\r\t' '   ' | cut -c1-200)"
        printf 'USER REPLY on #%s : %s\n' "${_num}" "${_preview}"
    done < "${_tsv}"
}

_usage() {
    sed -n '/^# Usage:/,/^# Output:/p' "$0" | sed 's/^# \{0,1\}//'
}

_die_args() {
    printf 'watch-user-replies.sh: %s (see --help)\n' "$1" >&2
    exit 2
}

# _fetch <repo> <out-tsv>
#   Appends one TSV line per comment on every OPEN issue and PR. A failure on
#   any single number warns and is skipped: a transient error must not look
#   like "no replies". Prints "<failed> <total>" on stdout so the caller can
#   surface a failed cycle instead of treating it as silence.
#
#   The issue number is spliced into the jq program as a string literal.
#   `gh api` has no --arg flag (only standalone jq does); passing one made
#   every fetch fail with "unknown flag: --arg". _n is digits-only (checked
#   below), so splicing it cannot inject jq.
_fetch() {
    local _repo="$1" _out="$2" _n _failed=0 _total=0
    local _nums=()
    mapfile -t _nums < <(
        gh issue list --repo "${_repo}" --state open --limit 300 \
            --json number --jq '.[].number' 2>/dev/null
        gh pr list --repo "${_repo}" --state open --limit 100 \
            --json number --jq '.[].number' 2>/dev/null
    )
    : > "${_out}"
    for _n in "${_nums[@]:-}"; do
        [[ "${_n}" =~ ^[0-9]+$ ]] || continue
        _total=$((_total + 1))
        if ! gh api "repos/${_repo}/issues/${_n}/comments?per_page=100" \
            --jq ".[] | [\"${_n}\", (.id|tostring), .user.login, (.body|@base64)] | @tsv" \
            >> "${_out}" 2>/dev/null; then
            _failed=$((_failed + 1))
            printf '[watch] fetch failed for #%s, skipping this cycle\n' \
                "${_n}" >&2
        fi
    done
    printf '%s %s\n' "${_failed}" "${_total}"
}

main() {
    local _repo='' _login='' _interval=180 _state='' _once=0 _seed=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo) [[ $# -ge 2 ]] || _die_args "--repo needs a value"
                    _repo="$2"; shift 2 ;;
            --login) [[ $# -ge 2 ]] || _die_args "--login needs a value"
                    _login="$2"; shift 2 ;;
            --interval) [[ $# -ge 2 ]] || _die_args "--interval needs a value"
                    _interval="$2"; shift 2 ;;
            --state-file) [[ $# -ge 2 ]] || _die_args "--state-file needs a value"
                    _state="$2"; shift 2 ;;
            --seed) _seed=1; shift ;;
            --once) _once=1; shift ;;
            -h|--help) _usage; exit 0 ;;
            *) _die_args "unknown option '$1'" ;;
        esac
    done

    [[ -n "${_repo}" ]] || _die_args "--repo is required"
    [[ -n "${_login}" ]] || _die_args "--login is required"
    [[ "${_interval}" =~ ^[1-9][0-9]*$ ]] \
        || _die_args "--interval must be a positive integer"

    if [[ -z "${_state}" ]]; then
        _state="$(mktemp)" || exit 2
    fi
    [[ -f "${_state}" ]] || : > "${_state}"

    WATCH_TMP="$(mktemp)" || exit 2
    trap 'rm -f "${WATCH_TMP}"' EXIT

    local _failed _total
    if [[ "${_seed}" -eq 1 ]]; then
        read -r _failed _total < <(_fetch "${_repo}" "${WATCH_TMP}")
        if [[ "${_failed}" -gt 0 ]]; then
            # A partial seed would re-announce the unread threads' history
            # on the next run; refuse rather than half-seed.
            printf '[watch] seed aborted: %s of %s thread(s) unreadable\n' \
                "${_failed}" "${_total}" >&2
            exit 1
        fi
        watch_replies_filter "${_login}" "${_state}" "${WATCH_TMP}" >/dev/null
        printf '[watch] seeded: %s id(s) marked seen, nothing announced\n' \
            "$(grep -c . "${_state}")" >&2
        exit 0
    fi

    while true; do
        read -r _failed _total < <(_fetch "${_repo}" "${WATCH_TMP}")
        if [[ "${_failed}" -gt 0 ]]; then
            # STDOUT on purpose: Monitor only notifies on stdout, and a
            # silent failure is indistinguishable from "no replies".
            printf 'WATCH FETCH FAILED: %s of %s thread(s) unreadable this cycle\n' \
                "${_failed}" "${_total}"
        fi
        watch_replies_filter "${_login}" "${_state}" "${WATCH_TMP}"
        printf '[watch] heartbeat %s\n' "$(date -u +%H:%M:%SZ)" >&2
        [[ "${_once}" -eq 1 ]] && exit 0
        sleep "${_interval}"
    done
}

# Only run main when executed, so the pure functions can be sourced by tests.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
