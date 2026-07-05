#!/usr/bin/env bash
# shard_partition.sh — time-weighted greedy-LPT partition of a spec list.
#
# Replaces the old count round-robin core-shard split (ci.sh
# _partition_core_specs_for_shard) with a Longest-Processing-Time (LPT)
# bin-packing that balances shards by MEASURED runtime, not spec count.
# See doc/adr/0028-ci-time-weighted-lpt-sharding.md (adapts the pattern from
# ycpss91255-docker/base ADR-00000017).
#
# Reads a newline-separated spec list on stdin and echoes the subset assigned
# to shard <index> of <count>. Every spec is assigned to exactly one shard, so
# the union over index 0..count-1 is the whole input with no overlap — the
# coverage-merge denominator (AC-17) stays whole regardless of shard count.
#
# Weighting: each spec's weight is its recorded runtime (whole seconds) looked
# up by basename in --weights FILE (`<seconds> <basename>` lines; `#` comments
# ignored). A spec absent from the file — a brand-new spec, or a run with no
# weights file at all — falls back to --default-weight, so it is still
# partitioned proportionally until CI records its real time.
#
# Algorithm: sort specs heaviest-first (ties broken by path for
# determinism), then assign each to the currently-lightest shard. This is the
# classic greedy-LPT heuristic; the busiest shard's load stays within one
# heaviest item of the ideal total/count floor.
#
# Usage:
#   printf '%s\n' spec1 spec2 ... \
#     | shard_partition.sh --index N --count T [--weights FILE] \
#                          [--default-weight D]
#
# Env: none. All inputs are explicit flags + stdin (deterministic, testable).

set -euo pipefail

_die() { printf '[shard-partition] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat >&2 <<'EOF'
Usage: shard_partition.sh --index <n> --count <t> [--weights <file>]
                          [--default-weight <d>]

  --index           0-based shard index (0 <= n < t)
  --count           total shard count (positive integer)
  --weights         weights file: `<seconds> <basename>` lines, `#` comments
  --default-weight  weight for specs absent from --weights (default: 5)

Reads the newline-separated spec list on stdin; prints the specs assigned to
shard <index> (one per line).
EOF
    exit 0
}

main() {
    local index="" count="" weights="" default_weight="5"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage ;;
            --index)
                [[ $# -ge 2 ]] || _die "--index requires a value"
                index="$2"; shift 2 ;;
            --count)
                [[ $# -ge 2 ]] || _die "--count requires a value"
                count="$2"; shift 2 ;;
            --weights)
                [[ $# -ge 2 ]] || _die "--weights requires a value"
                weights="$2"; shift 2 ;;
            --default-weight)
                [[ $# -ge 2 ]] || _die "--default-weight requires a value"
                default_weight="$2"; shift 2 ;;
            *) _die "Unknown option: $1" ;;
        esac
    done

    [[ -n "${index}" ]] || _die "--index is required"
    [[ -n "${count}" ]] || _die "--count is required"
    [[ "${index}" =~ ^[0-9]+$ ]] \
        || _die "--index must be a non-negative integer (got '${index}')"
    [[ "${count}" =~ ^[1-9][0-9]*$ ]] \
        || _die "--count must be a positive integer (got '${count}')"
    (( index < count )) \
        || _die "--index ${index} out of range for --count ${count} (valid: 0..$((count - 1)))"
    [[ "${default_weight}" =~ ^[0-9]+$ ]] \
        || _die "--default-weight must be a non-negative integer (got '${default_weight}')"

    # Concatenate weights + a sentinel + the stdin spec list into ONE stream,
    # so awk splits the two by the sentinel rather than by FNR==NR — the latter
    # misfires when the weights file is empty/absent (its first-file pass reads
    # zero records, so the first spec line looks like record 1 of file 1 and is
    # wrongly parsed as a weight). A missing / unset weights file is NOT an
    # error: every spec then takes the default weight. The sentinel (0x1e ASCII
    # record separator) can never collide with a real spec path.
    local sentinel=$'\036SPECS\036'
    {
        if [[ -n "${weights}" && -f "${weights}" ]]; then
            cat -- "${weights}"
        fi
        printf '%s\n' "${sentinel}"
        cat -
    } \
    | awk -v defw="${default_weight}" -v sentinel="${sentinel}" '
        $0 == sentinel { specs = 1; next }
        specs == 0 {
            if (substr($0, 1, 1) == "#") next
            if (NF >= 2) w[$2] = $1
            next
        }
        {
            b = $0; sub(/.*\//, "", b)
            printf "%s\t%s\n", (b in w ? w[b] : defw), $0
        }
    ' \
    | sort -k1,1nr -k2,2 \
    | awk -v want="${index}" -v total="${count}" '
        BEGIN { for (i = 0; i < total; i++) load[i] = 0 }
        {
            min = 0
            for (i = 1; i < total; i++) if (load[i] < load[min]) min = i
            load[min] += $1
            if (min == want) print $2
        }'
}

main "$@"
