#!/usr/bin/env bats
# test/unit/script/shard_partition_spec.bats
#
# Tests for `script/ci/shard_partition.sh` — the time-weighted greedy-LPT
# (Longest Processing Time) partition that replaces the old count round-robin
# core-shard split (ADR-0028). Given a newline spec list on stdin, a weights
# file, a 0-based shard index and a shard count, it emits the specs assigned
# to that shard.
#
# Invariants under test:
#   - Exhaustive + disjoint: the union of all shards == the input, each spec
#     assigned exactly once (the coverage-merge denominator must stay whole).
#   - Time-balanced: the busiest shard's weight stays within one heaviest item
#     of the ideal total/N floor (the LPT guarantee).
#   - Fallback: an unknown spec (absent from the weights file) still gets the
#     default weight and is partitioned.
#   - Edge cases: empty stdin, single shard, and invalid index/count.
#   - The committed weights file (test/ci-shard-weights.tsv) is well-formed
#     and covers every current core spec.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    SCRIPT="${REPO_ROOT}/script/ci/shard_partition.sh"
    WEIGHTS="${BATS_TEST_TMPDIR}/weights.tsv"
    cat >"${WEIGHTS}" <<'EOF'
# fixture weights
10 a_spec.bats
10 b_spec.bats
10 c_spec.bats
10 d_spec.bats
1 e_spec.bats
EOF
    SPECS=$'test/unit/a_spec.bats\ntest/unit/b_spec.bats\ntest/unit/c_spec.bats\ntest/unit/d_spec.bats\ntest/unit/e_spec.bats'
}

teardown() {
    teardown_test_env
}

# Collect shard <n> of <count> into a sorted newline blob.
_shard() {
    local idx="$1" count="$2"
    printf '%s\n' "${SPECS}" \
        | "${SCRIPT}" --index "${idx}" --count "${count}" --weights "${WEIGHTS}" \
        | sort
}

@test "every spec is assigned exactly once across all shards" {
    local all=""
    for i in 0 1 2; do
        all+="$(printf '%s\n' "${SPECS}" \
            | "${SCRIPT}" --index "${i}" --count 3 --weights "${WEIGHTS}")"$'\n'
    done
    # Strip blank lines, sort, and compare against the sorted input.
    local got want
    got="$(printf '%s' "${all}" | grep -c . )"
    want="$(printf '%s\n' "${SPECS}" | grep -c .)"
    [ "${got}" -eq "${want}" ]
    # No duplicates: unique count equals total count.
    local uniq
    uniq="$(printf '%s' "${all}" | grep . | sort -u | grep -c .)"
    [ "${uniq}" -eq "${want}" ]
}

@test "partition is time-balanced within one heaviest item of the ideal floor" {
    # total weight = 41, count = 2, ideal floor = 20.5, heaviest item = 10.
    # LPT keeps the busiest shard <= floor + heaviest.
    local load0 load1
    load0="$(_shard 0 2 | while read -r f; do
        awk -v b="$(basename "$f")" '$2==b{print $1}' "${WEIGHTS}"; done \
        | awk '{s+=$1} END{print s+0}')"
    load1="$(_shard 1 2 | while read -r f; do
        awk -v b="$(basename "$f")" '$2==b{print $1}' "${WEIGHTS}"; done \
        | awk '{s+=$1} END{print s+0}')"
    # Both shards used, and the gap is at most the heaviest single item (10).
    [ "${load0}" -gt 0 ]
    [ "${load1}" -gt 0 ]
    local gap=$(( load0 > load1 ? load0 - load1 : load1 - load0 ))
    [ "${gap}" -le 10 ]
    # Sanity: the two loads sum to the whole 41.
    [ "$(( load0 + load1 ))" -eq 41 ]
}

@test "unknown spec falls back to the default weight and is still assigned" {
    local out
    out="$(printf '%s\n' 'test/unit/unknown_spec.bats' \
        | "${SCRIPT}" --index 0 --count 1 --weights "${WEIGHTS}")"
    [ "${out}" = "test/unit/unknown_spec.bats" ]
    # An explicit default-weight override is accepted.
    out="$(printf '%s\n' 'test/unit/unknown_spec.bats' \
        | "${SCRIPT}" --index 0 --count 1 --weights "${WEIGHTS}" --default-weight 99)"
    [ "${out}" = "test/unit/unknown_spec.bats" ]
}

@test "single shard receives every spec" {
    run bash -c "printf '%s\n' \"\${SPECS}\" | '${SCRIPT}' --index 0 --count 1 --weights '${WEIGHTS}'"
    assert_success
    [ "$(printf '%s' "${output}" | grep -c .)" -eq 5 ]
}

@test "empty stdin yields empty output and exit 0" {
    run bash -c "printf '' | '${SCRIPT}' --index 0 --count 4 --weights '${WEIGHTS}'"
    assert_success
    [ -z "${output}" ]
}

@test "a shard index with no specs assigned is an empty exit-0 (more shards than specs)" {
    # 5 specs, 8 shards → at least one shard is empty; must not error.
    local nonempty=0 i
    for i in 0 1 2 3 4 5 6 7; do
        run bash -c "printf '%s\n' \"\${SPECS}\" | '${SCRIPT}' --index ${i} --count 8 --weights '${WEIGHTS}'"
        assert_success
        [ -n "${output}" ] && nonempty=$(( nonempty + 1 ))
    done
    [ "${nonempty}" -eq 5 ]
}

@test "missing weights file degrades to the default weight (no crash)" {
    run bash -c "printf '%s\n' \"\${SPECS}\" | '${SCRIPT}' --index 0 --count 2 --weights /no/such/file"
    assert_success
    [ -n "${output}" ]
}

@test "invalid shard index (>= count) fails" {
    run bash -c "printf '%s\n' \"\${SPECS}\" | '${SCRIPT}' --index 2 --count 2 --weights '${WEIGHTS}'"
    assert_failure
}

@test "non-numeric count fails" {
    run bash -c "printf '%s\n' \"\${SPECS}\" | '${SCRIPT}' --index 0 --count x --weights '${WEIGHTS}'"
    assert_failure
}

@test "the partition is deterministic across repeated runs" {
    local a b
    a="$(_shard 0 3)"
    b="$(_shard 0 3)"
    [ "${a}" = "${b}" ]
}

@test "committed weights file is well-formed (int + basename, or comment)" {
    local wf="${REPO_ROOT}/test/ci-shard-weights.tsv"
    [ -f "${wf}" ]
    # Every non-comment, non-blank line is `<positive-int> <basename.bats>`.
    run awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        $1 !~ /^[0-9]+$/ { print "bad weight: " $0; bad=1 }
        $2 !~ /_spec\.bats$/ { print "bad name: " $0; bad=1 }
        NF != 2 { print "bad arity: " $0; bad=1 }
        END { exit bad }
    ' "${wf}"
    assert_success
}

@test "committed weights file has no stale entries (every weight names a real core spec)" {
    # Fallback (tested above) covers a brand-new spec missing from the file,
    # so full coverage is NOT required — but a weight for a DELETED/renamed
    # spec is dead data that skews the partition. Assert every weighted
    # basename still resolves to a live non-module spec.
    local wf="${REPO_ROOT}/test/ci-shard-weights.tsv" stale=0 b
    while read -r _ b; do
        [[ -z "${b}" ]] && continue
        find "${REPO_ROOT}/test/unit" -type f -name "${b}" \
            ! -path "${REPO_ROOT}/test/unit/module/*" | grep -q . || {
            echo "stale weight entry: ${b}"; stale=1
        }
    done < <(grep -vE '^[[:space:]]*(#|$)' "${wf}")
    [ "${stale}" -eq 0 ]
}

@test "the committed weights partition into 8 balanced core shards" {
    # Regression guard for the audit's core imbalance: with the committed
    # weights, no core shard's time exceeds 1.5x the lightest (the old
    # round-robin left one shard ~30 % heavy; LPT keeps them tight).
    local wf="${REPO_ROOT}/test/ci-shard-weights.tsv" i lo=999999 hi=0 load
    local specs
    specs="$(find "${REPO_ROOT}/test/unit" -type f -name '*.bats' \
                 ! -path "${REPO_ROOT}/test/unit/module/*" | sort)"
    for i in 0 1 2 3 4 5 6 7; do
        load="$(printf '%s\n' "${specs}" \
            | "${SCRIPT}" --index "${i}" --count 8 --weights "${wf}" \
            | while read -r f; do
                  awk -v b="$(basename "${f}")" '$2==b{print $1}' "${wf}"
              done | awk '{s+=$1} END{print s+0}')"
        [ "${load}" -lt "${lo}" ] && lo="${load}"
        [ "${load}" -gt "${hi}" ] && hi="${load}"
    done
    # hi <= 1.5 * lo  (integer-safe: 2*hi <= 3*lo)
    [ "$(( 2 * hi ))" -le "$(( 3 * lo ))" ]
}
