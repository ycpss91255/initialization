#!/usr/bin/env bats
# test/integration/tui/tui_smoke_spec.bats — AC-10 layer 2: live-widget smoke
#
# PRD §11.1 AC-10 (issue #73, layer 2 of 2): inside the test-tools
# container, drive the REAL dialog and whiptail binaries on an expect
# pseudo-tty through the literal AC-10 flow:
#   open main menu → enter Optional → check one item → OK → Exit
# once per backend. Assertions:
#   - every screen renders (text expected from the live widget output)
#   - the checkbox is operable ([*] toggles on Space)
#   - < Exit > exits cleanly (rc 0) with ZERO file writes (fs snapshot)
#   - the only CLI forks are the data reads (list/detect --json) — no
#     install is ever forked (Q43: Exit drops the in-memory selection)
#
# Menu data comes from the recording mock `setup_ubuntu` (TUI_CLI override,
# helper/tui_harness.bash) serving the shared ADR-0019 fixtures — the live
# widgets are the test subject here, the engine has its own specs. The
# sealed PATH farm carries exactly ONE backend per test, so whiptail really
# is whiptail (detection prefers dialog whenever it can see one).
#
# ADR-0004: runs inside Docker only, via `just -f justfile.ci test-integration`.

load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/tui_harness"

setup() {
    setup_test_env
    if ! command -v expect >/dev/null 2>&1; then
        fail "expect not found — rebuild the image: just -f justfile.ci build-test-tools"
    fi
}

teardown() {
    teardown_test_env
}

# Build the sealed live-widget env for one backend:
#   farm symlinks + mock setup_ubuntu + the REAL <backend> binary (only).
_make_smoke_env() {
    local _backend="$1"
    local _dir="${INIT_UBUNTU_TEST_SCRATCH}/smoke-${_backend}"
    rm -rf "${_dir}"
    mkdir -p "${_dir}/bin" "${_dir}/home"
    SMOKE_BIN="${_dir}/bin"
    SMOKE_HOME="${_dir}/home"            # fs-snapshot target (must stay empty)
    SMOKE_CLI_LOG="${_dir}/cli.log"
    export SMOKE_BIN SMOKE_HOME SMOKE_CLI_LOG

    tui_harness_farm "${SMOKE_BIN}"
    tui_harness_mock_cli "${SMOKE_BIN}" "${_dir}" "${SMOKE_CLI_LOG}"

    local _real
    if ! _real="$(command -v "${_backend}")"; then
        fail "${_backend} not found in the test-tools image"
    fi
    ln -sf "${_real}" "${SMOKE_BIN}/${_backend}"
}

_run_smoke() {
    run env "TUI_ENTRY=${REPO_ROOT}/setup_ubuntu_tui.sh" \
        "TUI_FARM=${SMOKE_BIN}" "TUI_HOME=${SMOKE_HOME}" \
        "TUI_CLI_MOCK=${SMOKE_BIN}/setup_ubuntu" \
        expect "${BATS_TEST_DIRNAME}/harness/smoke_flow.exp" "$1"
}

# Shared post-flow assertions (the in-flow screen assertions live in
# smoke_flow.exp and fail with rc 99 + a TUI-HARNESS FAIL diagnostic).
_assert_smoke_green() {
    assert_success
    # The expect session echoes the pty stream: the main menu really drew.
    assert_output --partial "Quick Setup"
    # Zero file writes: Exit dropped everything with the process (Q43).
    run find "${SMOKE_HOME}" -mindepth 1
    assert_output ""
    # G4 data path: menu content came from forked list/detect --json...
    run cat "${SMOKE_CLI_LOG}"
    assert_output --partial "list --json"
    assert_output --partial "detect --json"
    # ...and no action fork ever happened.
    run grep "^install" "${SMOKE_CLI_LOG}"
    assert_failure
}

@test "AC-10 smoke (dialog): main menu → Optional → check one → OK → Exit" {
    _make_smoke_env dialog
    _run_smoke dialog
    _assert_smoke_green
}

@test "AC-10 smoke (whiptail): main menu → Optional → check one → OK → Exit" {
    _make_smoke_env whiptail
    _run_smoke whiptail
    _assert_smoke_green
}
