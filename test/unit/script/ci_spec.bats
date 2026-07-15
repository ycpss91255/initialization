#!/usr/bin/env bats
# test/unit/script/ci_spec.bats
#
# Tests for `script/ci/ci.sh` per-shard kcov coverage + merge gate
# (issue #28): each per-module CI matrix shard runs bats ONCE under kcov
# (`--kcov`), and a final aggregation entry point (`--ci-merge-coverage`)
# merges all shard outputs and asserts the coverage gate on the MERGED
# result. Gate default is 84 (the AC-17 gate, ratcheted 66 -> 80 in #124,
# then 80 -> 84 once merged coverage reached 84.53%);
# COVERAGE_ENFORCE=0|false makes it report-only (CI narrow PR matrices).
#
# Strategy: copy ci.sh into a fixture repo skeleton under
# $BATS_TEST_TMPDIR so its self-resolved REPO_ROOT points at the fixture,
# then stub `kcov` / `bats` / `docker` on PATH and assert on the recorded
# invocations — no real container or kcov run needed.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env

    FIXTURE_ROOT="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${FIXTURE_ROOT}/script/ci" \
             "${FIXTURE_ROOT}/test/unit/module" \
             "${FIXTURE_ROOT}/dockerfile" \
             "${FIXTURE_ROOT}/bin"
    cp "${REPO_ROOT}/script/ci/ci.sh" "${FIXTURE_ROOT}/script/ci/ci.sh"
    CI_SH="${FIXTURE_ROOT}/script/ci/ci.sh"

    # Host-side compose routes resolve the content-keyed image tag
    # (issue #113) from a sibling helper + dockerfile/Dockerfile.test-tools
    # — mirror both into the fixture so SCRIPT_DIR-relative resolution works.
    cp "${REPO_ROOT}/script/ci/resolve_test_tools_tag.sh" \
       "${FIXTURE_ROOT}/script/ci/resolve_test_tools_tag.sh"
    printf 'FROM alpine:3.20\n' \
        > "${FIXTURE_ROOT}/dockerfile/Dockerfile.test-tools"

    # The coverage compose route resolves the content-keyed kcov-tools tag
    # (issue #226) from a sibling helper + dockerfile/Dockerfile.kcov-tools —
    # mirror both into the fixture too.
    cp "${REPO_ROOT}/script/ci/resolve_kcov_tools_tag.sh" \
       "${FIXTURE_ROOT}/script/ci/resolve_kcov_tools_tag.sh"
    printf 'FROM kcov/kcov\n' \
        > "${FIXTURE_ROOT}/dockerfile/Dockerfile.kcov-tools"

    # The core-<N> sub-shard partition delegates to a sibling helper
    # (ADR-0028); mirror it so SCRIPT_DIR-relative resolution works in the
    # fixture. No weights file is copied, so the partition falls back to the
    # default per-spec weight — still exhaustive + pairwise-disjoint.
    cp "${REPO_ROOT}/script/ci/shard_partition.sh" \
       "${FIXTURE_ROOT}/script/ci/shard_partition.sh"

    # Fixture unit specs (content never executed — bats is stubbed).
    printf '#!/usr/bin/env bats\n' \
        > "${FIXTURE_ROOT}/test/unit/module/alpha_spec.bats"
    printf '#!/usr/bin/env bats\n' \
        > "${FIXTURE_ROOT}/test/unit/core_thing_spec.bats"

    STUB_CALL_LOG="${BATS_TEST_TMPDIR}/calls"
    mkdir -p "${STUB_CALL_LOG}"
    export STUB_CALL_LOG

    # Stub kcov: record argv; emulate `--merge` by writing a merged
    # coverage.json shaped like the real one — per-file entries carry
    # their own (misleading) "percent_covered" BEFORE the overall field,
    # so the gate parser must not naively grab the first match. Overall
    # percent comes from $STUB_KCOV_PERCENT. In run mode, emulate kcov's
    # absolute-path convenience symlink (dangling outside the container).
    cat > "${FIXTURE_ROOT}/bin/kcov" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_CALL_LOG}/kcov.calls"
if [[ "${1:-}" == "--merge" ]]; then
    shift
    # skip any flags (e.g. --exclude-region=...) before the output dir arg
    while [[ "${1:-}" == --* ]]; do shift; done
    mkdir -p "$1/kcov-merged"
    cat > "$1/kcov-merged/coverage.json" <<JSON
{
  "files": [
    {"file": "/source/lib/x.sh", "percent_covered": "11.11", "covered_lines": "1", "total_lines": "9"}
  ],
  "percent_covered": "${STUB_KCOV_PERCENT:-85.00}",
  "covered_lines": "1",
  "total_lines": "9"
}
JSON
else
    for _a in "$@"; do
        case "${_a}" in
            --*) ;;
            *) ln -sf "/source/does-not-exist-outside-container" \
                   "${_a}/bats"
               break ;;
        esac
    done
fi
EOF

    # Stub bats: record argv, succeed.
    cat > "${FIXTURE_ROOT}/bin/bats" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_CALL_LOG}/bats.calls"
EOF

    chmod +x "${FIXTURE_ROOT}/bin/kcov" "${FIXTURE_ROOT}/bin/bats"
    PATH="${FIXTURE_ROOT}/bin:${PATH}"
    export PATH
}

teardown() {
    teardown_test_env
}

@test "--ci-unit --module <name> --kcov wraps the single bats run in kcov into coverage/shard-<name>" {
    run "${CI_SH}" --ci-unit --module alpha --kcov
    assert_success

    run cat "${STUB_CALL_LOG}/kcov.calls"
    assert_success
    assert_output --partial "${FIXTURE_ROOT}/coverage/shard-alpha bats"
    assert_output --partial "test/unit/module/alpha_spec.bats"

    # ci.sh must pre-create the shard dir: kcov only mkdirs one level,
    # and coverage/ does not exist on a fresh checkout.
    [[ -d "${FIXTURE_ROOT}/coverage/shard-alpha" ]]

    # kcov drops absolute-path convenience symlinks (/source/... inside
    # the container) that dangle on the host/runner and can break the
    # shard artifact upload — ci.sh must prune them after the run.
    run find "${FIXTURE_ROOT}/coverage/shard-alpha" -maxdepth 1 -type l
    assert_success
    assert_output ""

    # bats must run exactly once — only inside the kcov wrapper, never as
    # a second bare invocation (that double run is what issue #28 kills).
    [[ ! -f "${STUB_CALL_LOG}/bats.calls" ]]
}

@test "--ci-unit --module core --kcov writes the core shard to coverage/shard-core" {
    run "${CI_SH}" --ci-unit --module core --kcov
    assert_success

    run cat "${STUB_CALL_LOG}/kcov.calls"
    assert_success
    assert_output --partial "${FIXTURE_ROOT}/coverage/shard-core bats"
    assert_output --partial "test/unit/core_thing_spec.bats"
}

@test "missing module spec under --kcov is a green skip and never invokes kcov" {
    run "${CI_SH}" --ci-unit --module ghost --kcov
    assert_success
    assert_output --partial "skipping"
    [[ ! -f "${STUB_CALL_LOG}/kcov.calls" ]]
}

@test "--kcov outside unit modes fails fast" {
    run "${CI_SH}" --ci-lint --kcov
    assert_failure
    assert_output --partial "--kcov is only valid"
}

@test "--ci-merge-coverage merges every coverage shard dir into coverage/merged" {
    # Mix local naming (shard-*) and CI artifact naming (coverage-shard-*)
    # — the merge glob must pick up both layouts.
    mkdir -p "${FIXTURE_ROOT}/coverage/shard-core" \
             "${FIXTURE_ROOT}/coverage/coverage-shard-alpha"
    run "${CI_SH}" --ci-merge-coverage
    assert_success

    run cat "${STUB_CALL_LOG}/kcov.calls"
    assert_success
    # `--merge` + the merged output dir (an --exclude-region flag sits between
    # them so the i18n data tables stay out of the merged gate — see ci.sh).
    assert_output --partial "--merge "
    assert_output --partial "--exclude-region="
    assert_output --partial "${FIXTURE_ROOT}/coverage/merged"
    assert_output --partial "coverage/coverage-shard-alpha"
    assert_output --partial "coverage/shard-core"
}

@test "merge gate passes when merged coverage meets the 84 default (AC-17)" {
    mkdir -p "${FIXTURE_ROOT}/coverage/shard-core"
    STUB_KCOV_PERCENT="84.00" run "${CI_SH}" --ci-merge-coverage
    assert_success
    assert_output --partial "84.00%"
}

@test "merge gate fails when merged coverage is below the 84 default (AC-17)" {
    mkdir -p "${FIXTURE_ROOT}/coverage/shard-core"
    STUB_KCOV_PERCENT="83.99" run "${CI_SH}" --ci-merge-coverage
    assert_failure
    assert_output --partial "coverage gate failed"
}

@test "merge gate honors COVERAGE_MIN override" {
    mkdir -p "${FIXTURE_ROOT}/coverage/shard-core"
    STUB_KCOV_PERCENT="42.50" COVERAGE_MIN=40 run "${CI_SH}" --ci-merge-coverage
    assert_success
}

@test "COVERAGE_ENFORCE=false turns a below-threshold gate into report-only" {
    # Narrow-matrix PR runs (issue #28): the CI coverage job passes
    # discover's `full=false` as COVERAGE_ENFORCE — the merge must print
    # the percentage but never fail, since unrun shards' files still
    # count in the merged denominator.
    mkdir -p "${FIXTURE_ROOT}/coverage/shard-alpha"
    STUB_KCOV_PERCENT="12.34" COVERAGE_ENFORCE=false \
        run "${CI_SH}" --ci-merge-coverage
    assert_success
    assert_output --partial "12.34%"
    assert_output --partial "report-only"
}

@test "COVERAGE_ENFORCE=0 is also report-only" {
    mkdir -p "${FIXTURE_ROOT}/coverage/shard-alpha"
    STUB_KCOV_PERCENT="12.34" COVERAGE_ENFORCE=0 \
        run "${CI_SH}" --ci-merge-coverage
    assert_success
    assert_output --partial "report-only"
}

@test "COVERAGE_ENFORCE=true still enforces the gate" {
    mkdir -p "${FIXTURE_ROOT}/coverage/shard-core"
    STUB_KCOV_PERCENT="12.34" COVERAGE_ENFORCE=true \
        run "${CI_SH}" --ci-merge-coverage
    assert_failure
    assert_output --partial "coverage gate failed"
}

@test "--ci-merge-coverage with no shard dirs is a green skip (all shards spec-less)" {
    # A PR touching only a module without a spec produces zero shards;
    # the aggregation job must stay green, mirroring the shard-level
    # green-skip contract.
    run "${CI_SH}" --ci-merge-coverage
    assert_success
    assert_output --partial "no coverage shards"
    [[ ! -f "${STUB_CALL_LOG}/kcov.calls" ]]
}

@test "host --unit-only --kcov routes to the kcov compose service with --kcov" {
    cat > "${FIXTURE_ROOT}/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_CALL_LOG}/docker.calls"
EOF
    chmod +x "${FIXTURE_ROOT}/bin/docker"

    run "${CI_SH}" --unit-only --kcov --module alpha
    assert_success

    run cat "${STUB_CALL_LOG}/docker.calls"
    assert_success
    assert_output --partial " coverage -c ./script/ci/ci.sh --ci-unit --module alpha --kcov"
}

@test "host --merge-coverage routes --ci-merge-coverage into the kcov compose service" {
    cat > "${FIXTURE_ROOT}/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_CALL_LOG}/docker.calls"
EOF
    chmod +x "${FIXTURE_ROOT}/bin/docker"

    COVERAGE_ENFORCE=false run "${CI_SH}" --merge-coverage
    assert_success

    run cat "${STUB_CALL_LOG}/docker.calls"
    assert_success
    assert_output --partial " coverage -c ./script/ci/ci.sh --ci-merge-coverage"
    # The enforce flag must cross the container boundary (CI sets it on
    # the host-side just invocation).
    assert_output --partial "COVERAGE_ENFORCE=false"
}

@test "host route exports the content-keyed TEST_TOOLS_IMAGE to compose (issue #113)" {
    # docker stub records the env var compose would use for the
    # ${TEST_TOOLS_IMAGE:-test-tools:local} image substitution.
    cat > "${FIXTURE_ROOT}/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf 'TEST_TOOLS_IMAGE=%s\n' "${TEST_TOOLS_IMAGE:-<unset>}" \
    >> "${STUB_CALL_LOG}/docker.calls"
EOF
    chmod +x "${FIXTURE_ROOT}/bin/docker"

    local _expected
    _expected="test-tools:$(sha256sum \
        "${FIXTURE_ROOT}/dockerfile/Dockerfile.test-tools" | cut -c1-12)"

    TEST_TOOLS_IMAGE='' run "${CI_SH}" --lint-only
    assert_success

    run cat "${STUB_CALL_LOG}/docker.calls"
    assert_success
    assert_output --partial "TEST_TOOLS_IMAGE=${_expected}"
}

@test "host route honors a pre-set TEST_TOOLS_IMAGE override (issue #113)" {
    cat > "${FIXTURE_ROOT}/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf 'TEST_TOOLS_IMAGE=%s\n' "${TEST_TOOLS_IMAGE:-<unset>}" \
    >> "${STUB_CALL_LOG}/docker.calls"
EOF
    chmod +x "${FIXTURE_ROOT}/bin/docker"

    TEST_TOOLS_IMAGE="test-tools:pinned" run "${CI_SH}" --lint-only
    assert_success

    run cat "${STUB_CALL_LOG}/docker.calls"
    assert_success
    assert_output --partial "TEST_TOOLS_IMAGE=test-tools:pinned"
}

# ── kcov-tools image resolution (issue #226) ─────────────────────────────────

@test "coverage route exports the content-keyed KCOV_TOOLS_IMAGE to compose (issue #226)" {
    cat > "${FIXTURE_ROOT}/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf 'KCOV_TOOLS_IMAGE=%s\n' "${KCOV_TOOLS_IMAGE:-<unset>}" \
    >> "${STUB_CALL_LOG}/docker.calls"
EOF
    chmod +x "${FIXTURE_ROOT}/bin/docker"

    local _expected
    _expected="kcov-tools:$(sha256sum \
        "${FIXTURE_ROOT}/dockerfile/Dockerfile.kcov-tools" | cut -c1-12)"

    KCOV_TOOLS_IMAGE='' run "${CI_SH}" --unit-only --kcov --module core
    assert_success

    run cat "${STUB_CALL_LOG}/docker.calls"
    assert_success
    assert_output --partial "KCOV_TOOLS_IMAGE=${_expected}"
}

@test "coverage route honors a pre-set KCOV_TOOLS_IMAGE override (issue #226)" {
    cat > "${FIXTURE_ROOT}/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf 'KCOV_TOOLS_IMAGE=%s\n' "${KCOV_TOOLS_IMAGE:-<unset>}" \
    >> "${STUB_CALL_LOG}/docker.calls"
EOF
    chmod +x "${FIXTURE_ROOT}/bin/docker"

    KCOV_TOOLS_IMAGE="kcov-tools:pinned" run "${CI_SH}" \
        --unit-only --kcov --module core
    assert_success

    run cat "${STUB_CALL_LOG}/docker.calls"
    assert_success
    assert_output --partial "KCOV_TOOLS_IMAGE=kcov-tools:pinned"
}

# ── Core sub-shard partitioning (issue #226; ADR-0028) ───────────────────────
# Time-weighted greedy-LPT split of the sorted non-module specs into
# CORE_SHARD_COUNT shards (shard_partition.sh); the union of all shards is
# exactly the full set, pairwise-disjoint. (In this fixture no weights file is
# present, so every spec takes the default weight — the exhaustive + disjoint
# invariant holds regardless of weight source.)

@test "--ci-unit --module core-<N> --kcov writes coverage/shard-core-<N>" {
    # Add a few more core specs so the round-robin split is observable.
    printf '#!/usr/bin/env bats\n' \
        > "${FIXTURE_ROOT}/test/unit/aaa_spec.bats"
    printf '#!/usr/bin/env bats\n' \
        > "${FIXTURE_ROOT}/test/unit/bbb_spec.bats"

    CORE_SHARD_COUNT=4 run "${CI_SH}" --ci-unit --module core-0 --kcov
    assert_success

    run cat "${STUB_CALL_LOG}/kcov.calls"
    assert_success
    assert_output --partial "${FIXTURE_ROOT}/coverage/shard-core-0 bats"
    [[ -d "${FIXTURE_ROOT}/coverage/shard-core-0" ]]
}

@test "core-<N> LPT shards partition the core specs with no gap/overlap" {
    # Five sorted core specs: aaa, bbb, ccc, ddd, core_thing.
    printf '#!/usr/bin/env bats\n' > "${FIXTURE_ROOT}/test/unit/aaa_spec.bats"
    printf '#!/usr/bin/env bats\n' > "${FIXTURE_ROOT}/test/unit/bbb_spec.bats"
    printf '#!/usr/bin/env bats\n' > "${FIXTURE_ROOT}/test/unit/ccc_spec.bats"
    printf '#!/usr/bin/env bats\n' > "${FIXTURE_ROOT}/test/unit/ddd_spec.bats"

    local _shard
    for _shard in 0 1 2 3; do
        CORE_SHARD_COUNT=4 run "${CI_SH}" \
            --ci-unit --module "core-${_shard}" --kcov
        assert_success
    done

    # Every core spec must appear exactly once across the 4 shards' kcov runs.
    local _spec
    for _spec in aaa bbb ccc ddd core_thing; do
        run grep -c "${_spec}_spec.bats" "${STUB_CALL_LOG}/kcov.calls"
        assert_success
        assert_output "1"
    done
}

@test "--ci-unit --module core-99 --kcov out of range fails fast" {
    CORE_SHARD_COUNT=4 run "${CI_SH}" --ci-unit --module core-99 --kcov
    assert_failure
    assert_output --partial "out of range"
}

@test "--ci-unit --module core-x --kcov rejects a non-numeric shard index" {
    CORE_SHARD_COUNT=4 run "${CI_SH}" --ci-unit --module core-x --kcov
    assert_failure
    assert_output --partial "Invalid core shard index"
}

@test "--ci-unit --module core-0 --kcov rejects a non-positive CORE_SHARD_COUNT" {
    CORE_SHARD_COUNT=0 run "${CI_SH}" --ci-unit --module core-0 --kcov
    assert_failure
    assert_output --partial "Invalid CORE_SHARD_COUNT"
}

# ── ShellCheck parallelization + fail-signal (perf/ci-parallel-shellcheck) ───
# The lint step forks shellcheck across nproc workers (xargs -P + -n batch)
# instead of one serial `xargs shellcheck` over all ~197 files (the 212s
# critical-path tail). The correctness constraint: parallelizing must NOT
# lose the fail-on-violation signal — xargs exits 123 when ANY batched child
# reports a violation, and the lint step must still exit nonzero on that.

# Stub the three lint tools onto the fixture PATH (already prepended in
# setup). shellcheck records argv and FAILS (rc=1) for any file containing
# the literal token SHELLCHECK_VIOLATION; hadolint/fish are inert no-ops so
# the fixture Dockerfiles / (absent) fish files never gate the lint test.
_stub_lint_tools() {
    cat > "${FIXTURE_ROOT}/bin/shellcheck" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_CALL_LOG}/shellcheck.calls"
_rc=0
for _a in "$@"; do
    case "${_a}" in
        -*) ;;
        *) grep -q 'SHELLCHECK_VIOLATION' "${_a}" 2>/dev/null && _rc=1 ;;
    esac
done
exit "${_rc}"
EOF
    printf '#!/usr/bin/env bash\nexit 0\n' > "${FIXTURE_ROOT}/bin/hadolint"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${FIXTURE_ROOT}/bin/fish"
    chmod +x "${FIXTURE_ROOT}/bin/shellcheck" \
             "${FIXTURE_ROOT}/bin/hadolint" \
             "${FIXTURE_ROOT}/bin/fish"
}

@test "lint fails (nonzero) when a linted script has a ShellCheck violation" {
    _stub_lint_tools
    printf '#!/usr/bin/env bash\n: SHELLCHECK_VIOLATION\n' \
        > "${FIXTURE_ROOT}/bad.sh"
    run "${CI_SH}" --ci-lint
    assert_failure
    assert_output --partial "ShellCheck failed"
}

@test "lint passes (zero) when every linted script is clean" {
    _stub_lint_tools
    run "${CI_SH}" --ci-lint
    assert_success
    assert_output --partial "ShellCheck OK"
}

@test "parallel lint still fails when one violation hides among many clean scripts (xargs 123 preserved)" {
    _stub_lint_tools
    # Enough clean scripts that a small batch size forces xargs to fork
    # several shellcheck invocations — the violation lives in only one batch.
    local _i
    for _i in $(seq 1 40); do
        printf '#!/usr/bin/env bash\n:\n' \
            > "${FIXTURE_ROOT}/clean_${_i}.sh"
    done
    printf '#!/usr/bin/env bash\n: SHELLCHECK_VIOLATION\n' \
        > "${FIXTURE_ROOT}/needle_bad.sh"

    SHELLCHECK_BATCH=5 run "${CI_SH}" --ci-lint
    assert_failure

    # Batching must have forked MORE THAN ONE shellcheck process — proof the
    # run is parallelized across batches, not a single serial invocation.
    run wc -l < "${STUB_CALL_LOG}/shellcheck.calls"
    assert_success
    [[ "${output// /}" -gt 1 ]]
}
