#!/usr/bin/env bats
# test/unit/script/junit_to_weights_spec.bats
#
# Tests for `script/ci/junit_to_weights.sh` — the self-maintaining refresh
# half of the time-weighted LPT sharding (ADR-0028). It turns bats junit
# reports into `<seconds> <basename>` weight lines and, with --merge, folds
# them into the committed test/ci-shard-weights.tsv.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    SCRIPT="${REPO_ROOT}/script/ci/junit_to_weights.sh"
    JUNIT="${BATS_TEST_TMPDIR}/report.xml"
    cat >"${JUNIT}" <<'EOF'
<?xml version="1.0"?>
<testsuites>
  <testsuite name="test/unit/alpha_spec.bats" tests="3" time="12.4">
  </testsuite>
  <testsuite name="test/unit/beta_spec.bats" tests="1" time="0.2">
  </testsuite>
</testsuites>
EOF
}

teardown() {
    teardown_test_env
}

@test "junit time rounds to whole seconds, floored at 1" {
    run "${SCRIPT}" "${JUNIT}"
    assert_success
    # 12.4 -> 12 ; 0.2 -> 1 (floor)
    assert_line "12 alpha_spec.bats"
    assert_line "1 beta_spec.bats"
}

@test "no xml argument fails" {
    run "${SCRIPT}"
    assert_failure
}

@test "missing xml file fails" {
    run "${SCRIPT}" /no/such/report.xml
    assert_failure
}

@test "--merge preserves the comment header, overrides measured, keeps unmeasured" {
    local base="${BATS_TEST_TMPDIR}/weights.tsv"
    cat >"${base}" <<'EOF'
# header line one
# header line two
99 alpha_spec.bats
7 gamma_spec.bats
EOF
    run "${SCRIPT}" --merge "${base}" "${JUNIT}"
    assert_success
    # Header preserved verbatim.
    assert_line "# header line one"
    assert_line "# header line two"
    # alpha overridden by the measured 12 (was 99).
    assert_line "12 alpha_spec.bats"
    # gamma unmeasured this run -> prior weight kept.
    assert_line "7 gamma_spec.bats"
    # beta newly measured -> added.
    assert_line "1 beta_spec.bats"
    # alpha's stale 99 is gone.
    refute_line "99 alpha_spec.bats"
}
