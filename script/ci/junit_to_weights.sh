#!/usr/bin/env bash
# junit_to_weights.sh — refresh the committed shard-weights file from real
# bats junit timings (ADR-0028; the "self-maintaining, committed, no
# CI-only-cache" half of the time-weighted LPT sharding).
#
# bats `--report-formatter junit` writes one
#   <testsuite name="test/unit/foo_spec.bats" ... time="12.345">
# per spec FILE. This reads those reports and emits `<seconds> <basename>`
# lines — the exact format shard_partition.sh reads back — rounding each time
# to a whole second (floored at 1 so a sub-second spec still carries weight).
#
# With --merge <file> it folds the new timings INTO the existing committed
# weights: leading comment lines are preserved verbatim, a spec measured this
# run overrides its old weight, and a spec absent from the reports keeps its
# prior weight (so a narrow local run never drops specs it did not exercise).
# Output goes to stdout; the refresh recipe redirects it back over the file.
#
# Pure text processing — no Docker, no network — so it is unit-testable and
# fully reproducible from the repo.
#
# Usage:
#   junit_to_weights.sh [--merge <weights.tsv>] <junit.xml> [<junit.xml> ...]

set -euo pipefail

_die() { printf '[junit-to-weights] ERROR: %s\n' "$*" >&2; exit 1; }

main() {
    local merge=""
    local -a xmls=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --merge)
                [[ $# -ge 2 ]] || _die "--merge requires a value"
                merge="$2"; shift 2 ;;
            -h|--help)
                _die "usage: junit_to_weights.sh [--merge <weights.tsv>] <junit.xml> ..." ;;
            *) xmls+=("$1"); shift ;;
        esac
    done

    [[ "${#xmls[@]}" -gt 0 ]] || _die "no junit xml files given"
    local _x
    for _x in "${xmls[@]}"; do
        [[ -f "${_x}" ]] || _die "junit report not found: ${_x}"
    done

    # New timings: `<seconds> <basename>` from every <testsuite> across all
    # reports. Attribute order-independent; the <testsuites> root is skipped
    # (it has no per-file name/time we want). Last write wins on duplicates.
    local new_timings
    new_timings="$(awk '
        /<testsuite[ >]/ {
            name = ""; t = ""
            if (match($0, /name="[^"]*"/)) { name = substr($0, RSTART + 6, RLENGTH - 7) }
            if (match($0, /time="[^"]*"/)) { t    = substr($0, RSTART + 6, RLENGTH - 7) }
            if (name == "") next
            n = split(name, p, "/"); base = p[n]
            if (base !~ /_spec\.bats$/) next
            s = int(t + 0.5); if (s < 1) s = 1
            print s, base
        }
    ' "${xmls[@]}")"

    # Merge: comment header (from --merge, verbatim) + a data map that starts
    # from the existing weights and is overwritten by this run's timings.
    awk -v have_merge="${merge:+1}" '
        FNR == NR {
            # First stream: the new timings (<secs> <basename>).
            if (NF >= 2) { w[$2] = $1; seen[$2] = 1 }
            next
        }
        # Second stream: the existing committed file (if any).
        /^[[:space:]]*#/ { comments[++nc] = $0; next }   # preserve header
        /^[[:space:]]*$/ { next }
        NF >= 2 {
            if (!($2 in w)) w[$2] = $1   # keep prior weight when unmeasured
            keys[$2] = 1
        }
        END {
            for (i = 1; i <= nc; i++) print comments[i]
            # union of prior keys + newly seen specs, sorted by basename
            for (k in seen) keys[k] = 1
            n = 0; for (k in keys) order[++n] = k
            # simple insertion sort (small n; keeps zero external deps)
            for (i = 2; i <= n; i++) {
                key = order[i]; j = i - 1
                while (j >= 1 && order[j] > key) { order[j+1] = order[j]; j-- }
                order[j+1] = key
            }
            for (i = 1; i <= n; i++) print w[order[i]], order[i]
        }
    ' <(printf '%s\n' "${new_timings}") "${merge:-/dev/null}"
}

main "$@"
