#!/usr/bin/env bats
# test/integration/tui/tui_smoke_spec.bats — AC-10 layer 2: live-widget smoke
#
# PRD §11.1 AC-10 (issue #73, layer 2 of 2; ADR-0024: fzf Rich tier + whiptail
# Fallback tier, gum dropped): inside the test-tools container, drive the REAL
# whiptail (and fzf, when present) binaries on an expect pseudo-tty through the
# literal AC-10 flow:
#   open main menu → enter Optional → check one item → OK → Exit
# once per tier. Assertions:
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

# ADR-0024 D10 whiptail-tier feature-parity smoke: drives the nested drill-down,
# the Manage Secrets three-way picker and Run → Proceed on the live whiptail.
_run_whiptail_parity() {
    run env "TUI_ENTRY=${REPO_ROOT}/setup_ubuntu_tui.sh" \
        "TUI_FARM=${SMOKE_BIN}" "TUI_HOME=${SMOKE_HOME}" \
        "TUI_CLI_MOCK=${SMOKE_BIN}/setup_ubuntu" \
        expect "${BATS_TEST_DIRNAME}/harness/smoke_flow_whiptail_parity.exp"
}

# `--lang zh-TW` render proof: same sealed env, the lang_flow.exp variant.
_run_lang() {
    run env "TUI_ENTRY=${REPO_ROOT}/setup_ubuntu_tui.sh" \
        "TUI_FARM=${SMOKE_BIN}" "TUI_HOME=${SMOKE_HOME}" \
        "TUI_CLI_MOCK=${SMOKE_BIN}/setup_ubuntu" \
        expect "${BATS_TEST_DIRNAME}/harness/lang_flow.exp" "$1"
}

# The fzf Rich tier (ADR-0024) needs TWO real binaries in the sealed farm: fzf
# (the navigator) AND whiptail (the screens the navigator DELEGATES to — Quick
# Setup / System Info / Review / msgbox, which still render via tui_render_*).
# _make_smoke_env symlinks exactly one backend, so build the fzf env on top of
# the whiptail env (whiptail already in the farm) and add the real fzf.
_make_smoke_env_fzf() {
    _make_smoke_env whiptail
    local _real_fzf
    if ! _real_fzf="$(command -v fzf)"; then
        fail "fzf not found in the test-tools image"
    fi
    ln -sf "${_real_fzf}" "${SMOKE_BIN}/fzf"
}

# The fzf flow forces the Rich tier via `--backend fzf` (set inside
# smoke_flow_fzf.exp's tui_spawn). Same sealed env + mock CLI as the others.
_run_smoke_fzf() {
    run env "TUI_ENTRY=${REPO_ROOT}/setup_ubuntu_tui.sh" \
        "TUI_FARM=${SMOKE_BIN}" "TUI_HOME=${SMOKE_HOME}" \
        "TUI_CLI_MOCK=${SMOKE_BIN}/setup_ubuntu" \
        expect "${BATS_TEST_DIRNAME}/harness/smoke_flow_fzf.exp"
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

# ADR-0024: gum dropped from the tier set — the live smoke now covers the
# whiptail Fallback tier (always-present, forced via --backend) and the fzf
# Rich tier (forced + skipped when fzf is absent from the image).
@test "AC-10 smoke (whiptail): main menu → Optional → check one → OK → Exit" {
    _make_smoke_env whiptail
    _run_smoke whiptail
    _assert_smoke_green
}

# ADR-0024: the fzf Rich tier on the LIVE fzf binary. The navigator drives fzf
# directly (TUI_FZF_BIN) but DELEGATES Quick Setup / System Info / Review /
# msgbox to the whiptail dialog screens (tui_render_*). This flow ENTERS those
# delegated screens — the regression guard for the fzf-tier TUI_BACKEND fix
# (5a3d4a7): before the fix TUI_BACKEND was unset in the fzf tier, so every
# delegated screen aborted on `${TUI_BACKEND:?TUI_BACKEND not set}` ("cannot
# enter Quick Setup / screens flash"). Requires fzf in the test-tools image —
# skip cleanly when absent so single-backend images still pass.
@test "AC-10 smoke (fzf): main menu → Quick Setup (delegated whiptail) → back → Exit" {
    if ! command -v fzf >/dev/null 2>&1; then
        skip "fzf not in the test-tools image — fzf Rich-tier live smoke deferred"
    fi
    _make_smoke_env_fzf
    _run_smoke_fzf
    _assert_smoke_green
}

# ADR-0024 D10: the whiptail Fallback tier reaches feature parity with the fzf
# Rich tier — nested drill-down, the Manage Secrets three-way picker (Token /
# GPG / SSH), recommended browse, and Run → Review → Proceed forking the ONE
# install pipeline — all on the LIVE whiptail binary.
@test "AC-10 parity smoke (whiptail): secrets 3 sub-menus + drill-down + Run/Proceed" {
    _make_smoke_env whiptail
    _run_whiptail_parity
    assert_success
    # The Proceed leg forked the install pipeline (G4 / AC-11 structural).
    assert_output --partial "CLI pipeline output"
    run grep -E "^install (eza|zoxide)" "${SMOKE_CLI_LOG}"
    assert_success
}

# `--lang zh-TW` forces the UI language at the entrypoint, overriding the
# source-time resolution. The live whiptail main menu must render zh-TW text
# (lang_flow.exp asserts 系統 / 離開) and still exit cleanly with zero writes.
@test "TUI --lang zh-TW renders the main menu in zh-TW (whiptail)" {
    _make_smoke_env whiptail
    _run_lang whiptail
    assert_success
    # The pty echo proves the zh-TW catalog reached the live widget.
    assert_output --partial "系統"
    # Exit dropped everything with the process — zero file writes (Q43).
    run find "${SMOKE_HOME}" -mindepth 1
    assert_output ""
}
