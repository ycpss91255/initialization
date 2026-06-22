#!/usr/bin/env bats
# test/integration/tui/tui_real_install_spec.bats — AC-11 (issue #178, S2):
# TUI → Proceed → REAL install fork (not a mock CLI).
#
# PRD §11.1 AC-11 / G4: the TUI is a CLI frontend. < Run > → Review & Install
# → Proceed forks the ONE real `setup_ubuntu install <picks>` pipeline — the
# SAME engine the keystone harness (#175) drives. The AC-10 smoke
# (tui_smoke_spec.bats) deliberately stops at < Exit > with a recording-MOCK
# TUI_CLI, so no test ever proved the Proceed leg reaches the real pipeline.
# This closes that gap: it drives the live widget through Proceed and asserts
# the github-release module ACTUALLY installed (state.json + Sidecar + binary)
# — CLI/TUI parity on the real pipeline, not a stub.
#
# How the two requirements (real fork AND offline determinism) coexist:
#   - The TUI reads its menu from `${TUI_CLI} list/detect --json`; a wrapper
#     CLI answers those from a controlled fixture (gum = the lone Optional
#     module) so the pty navigation is deterministic.
#   - For the Proceed fork (`install gum -y`) the SAME wrapper execs the REAL
#     setup_ubuntu.sh with the #175 offline github-release seam set, so the
#     dispatcher → runner → module → archetype → extract → state/Sidecar/
#     binary chain runs for real, offline.
#   - Non-root: the install refuses EUID 0 (PRD §10); the container is root, so
#     the TUI + its forked install run as the engine_lifecycle non-root user.
#
# ADR-0004: runs inside Docker only, via `just -f justfile.ci test-integration`.

load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/engine_lifecycle"
load "${BATS_TEST_DIRNAME}/../../helper/tui_harness"
load "${BATS_TEST_DIRNAME}/../../helper/tui_real_install"

_GUM_V="0.16.2"

_gum_arch() {
    case "$(uname -m)" in
        x86_64)        printf 'x86_64' ;;
        aarch64|arm64) printf 'arm64' ;;
        armv7l)        printf 'armv7' ;;
        *)             printf 'x86_64' ;;
    esac
}
_gum_asset() { printf 'gum_%s_Linux_%s.tar.gz' "${_GUM_V}" "$(_gum_arch)"; }

setup() {
    engine_lt_require_root
    if ! command -v expect >/dev/null 2>&1; then
        skip "expect not in the test-tools image — rebuild: just -f justfile.ci build-test-tools"
    fi
    setup_test_env
    engine_lt_setup_user
}

teardown() {
    teardown_test_env
}

# The full path: live widget → Run → Review → Proceed → real install lands.
@test "AC-11 (whiptail): Proceed forks the REAL setup_ubuntu install — gum lands (state + Sidecar + binary)" {
    engine_lt_make_gh_fixture "$(_gum_asset)" gum "${_GUM_V}"
    tri_setup_env whiptail "${_GUM_V}"

    tri_run_flow "${BATS_TEST_DIRNAME}/harness/real_install_flow.exp" whiptail

    # The expect flow exits 0 only when the forked real install succeeded and
    # the TUI propagated rc 0; 99 = a pty/screen assertion tripped (stderr).
    assert_success
    # The Proceed leg forked the REAL install action (not a mock, not a
    # dry-run-only stub): a bare `install …` line, no --dry-run, in the log.
    tri_assert_real_install_forked

    # And the real engine actually landed gum — the load-bearing parity proof:
    #   state.json recorded by the runner (state_record_install),
    engine_lt_state_has gum
    #   Sidecar (ADR-0001) written by the module on success,
    [[ "$(engine_lt_sidecar gum)" == "${_GUM_V}" ]]
    #   and the real extract + symlink produced a runnable binary.
    [[ -x "${ENGINE_LT_HOME}/.local/bin/gum" ]]
}
