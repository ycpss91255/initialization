#!/usr/bin/env bats
# test/integration/lifecycle/engine_doctor_spec.bats
#
# Real-engine coverage for the F1 architecture fix (architecture-review.md):
# `setup_ubuntu doctor` must INVOKE each installed module's doctor() override,
# not just run the state-drift report. Prior to the fix runner_doctor was dead
# code and _dispatcher_doctor never called a module's doctor().
#
# Drives the REAL entrypoint end to end:
#   setup_ubuntu.sh -> dispatcher doctor -> runner_doctor -> source module
#   (subshell) -> module doctor() override
#
# Fixture module: claude-code-config (custom archetype). It ships a RICH
# doctor() override that syntax-checks its launcher — behavior the archetype
# default (is_installed only) would never produce. That distinct behavior is
# what lets these specs prove the override actually ran under the Engine.
#
# No network, no sudo: claude-code-config installs entirely into the user-home
# scratch tree, so the real doctor() runs offline as the non-root user.

load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/engine_lifecycle"

setup() {
    engine_lt_require_root
    setup_test_env
    engine_lt_setup_user
}

teardown() {
    teardown_test_env
}

# Positive: after a real install, `doctor <module>` runs the drift report AND
# the module's own doctor() override, and exits clean.
@test "doctor runs the installed module's doctor() override through the real engine" {
    engine_lt_run "" install claude-code-config --no-deps -y
    assert_success
    engine_lt_assert_no_wiring_errors

    engine_lt_run "" doctor claude-code-config
    assert_success
    engine_lt_assert_no_wiring_errors
    # Drift half preserved (AUGMENT, not replace).
    assert_output --partial "claude-code-config"
    # doctor() phase actually executed via the runner.
    assert_output --partial "doctor"
}

# Override-proof + RC propagation: breaking the launcher trips ONLY the rich
# doctor() override (is_installed still passes, so the drift report stays
# clean). A nonzero exit therefore proves the override ran and its failure
# propagated through the wired Engine path.
@test "doctor surfaces the module doctor() override failure with a nonzero exit" {
    engine_lt_run "" install claude-code-config --no-deps -y
    assert_success

    # Tamper: strip the launcher's exec bit. is_installed (settings.json
    # managed) is unaffected, so the drift report cannot be the failure source.
    chmod -x "${ENGINE_LT_HOME}/.claude/run-statusline.sh"

    engine_lt_run "" doctor claude-code-config
    assert_failure
    engine_lt_assert_no_wiring_errors
    # The message comes from the claude-code-config doctor() override, not the
    # archetype default — proof the override ran under the Engine.
    assert_output --partial "missing or not executable"
}
