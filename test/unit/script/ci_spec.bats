#!/usr/bin/env bats
# test/unit/script/ci_spec.bats
#
# Tests for `script/ci/ci.sh` per-shard kcov coverage + merge gate
# (issue #28): each per-module CI matrix shard runs bats ONCE under kcov
# (`--kcov`), and a final aggregation entry point (`--ci-merge-coverage`)
# merges all shard outputs and asserts the coverage gate on the MERGED
# result. Gate default is 80 (the AC-17 gate, ratcheted up from the 66
# baseline in #124); COVERAGE_ENFORCE=0|false makes it report-only (CI
# narrow PR matrices).
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
    mkdir -p "$2/kcov-merged"
    cat > "$2/kcov-merged/coverage.json" <<JSON
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
    assert_output --partial "--merge ${FIXTURE_ROOT}/coverage/merged"
    assert_output --partial "coverage/coverage-shard-alpha"
    assert_output --partial "coverage/shard-core"
}

@test "merge gate passes when merged coverage meets the 80 default (AC-17)" {
    mkdir -p "${FIXTURE_ROOT}/coverage/shard-core"
    STUB_KCOV_PERCENT="80.00" run "${CI_SH}" --ci-merge-coverage
    assert_success
    assert_output --partial "80.00%"
}

@test "merge gate fails when merged coverage is below the 80 default (AC-17)" {
    mkdir -p "${FIXTURE_ROOT}/coverage/shard-core"
    STUB_KCOV_PERCENT="79.99" run "${CI_SH}" --ci-merge-coverage
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
