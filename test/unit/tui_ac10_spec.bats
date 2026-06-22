#!/usr/bin/env bats
# test/unit/tui_ac10_spec.bats — AC-10 layer 1: backend-mock assertion suite
#
# PRD §11.1 AC-10 verifies the TUI in two layers (issue #73):
#   layer 1 (THIS file): with the widget binary mocked, assert the Q43
#     execution model — checked pages accumulate → < Run > → ONE generated
#     CLI command string — on BOTH backends (dialog AND whiptail), plus the
#     argv-level menu-parameter differences between the two backends
#     (Cancel-relabel flag spelling, §8.1 < Exit > / §8.2 < Back >).
#   layer 2: live widgets on an expect pseudo-tty —
#     test/integration/tui/tui_smoke_spec.bats.
#
# The scripted-widget harness (sealed PATH, so the container's real
# dialog/whiptail can never shadow the mock) lives in
# test/helper/tui_harness.bash and is shared with tui_backend_spec.bats.

load "${BATS_TEST_DIRNAME}/../helper/common"
load "${BATS_TEST_DIRNAME}/../helper/tui_harness"

# shellcheck source=../../lib/tui_backend.sh
source "${LIB_DIR}/tui_backend.sh"

setup() {
    setup_test_env
}

teardown() {
    teardown_test_env
}

# Canned AC-10 interaction: Optional page (check eza + zoxide), Recommended
# page (check neovim), < Run >, Review → Proceed.
# ADR-0024 D10 nested drill-down: optional / recommended each have 2 TAGS[0]
# buckets, so entering a category shows a sub-category menu before the checklist.
# Drill in (cli-essentials / editor), check, then Back out the sub-category menu.
_ac10_responses() {
    cat >"${E2E_RESPONSES}" <<'EOF'
0|optional
0|cli-essentials
0|eza\nzoxide\n
1|
0|recommended
0|editor
0|neovim\n
1|
0|run
0|proceed
EOF
}

# ── Backend menu-parameter differences (mock-verified) ───────────────────────

@test "AC-10: cancel relabel spells --cancel-label on dialog" {
    TUI_BACKEND="dialog" run _tui_cancel_button_args "Exit"
    assert_success
    assert_line --index 0 -- "--cancel-label"
    assert_line --index 1 "Exit"
}

@test "AC-10: cancel relabel spells --cancel-button on whiptail (path-qualified too)" {
    TUI_BACKEND="whiptail" run _tui_cancel_button_args "Back"
    assert_success
    assert_line --index 0 -- "--cancel-button"
    assert_line --index 1 "Back"
    # §8.5 detection may hand back a bare name, but a caller-set absolute
    # path must pick the same spelling.
    TUI_BACKEND="/usr/bin/whiptail" run _tui_cancel_button_args "Back"
    assert_success
    assert_line --index 0 -- "--cancel-button"
}

@test "AC-10 (dialog): main menu fork carries --cancel-label Exit, never --cancel-button" {
    tui_e2e_make_harness dialog
    _ac10_responses
    tui_e2e_run
    assert_success
    run grep -- "--cancel-label Exit" "${E2E_WIDGET_LOG}"
    assert_success
    run grep -- "--cancel-button" "${E2E_WIDGET_LOG}"
    assert_failure
}

@test "AC-10 (whiptail): main menu fork carries --cancel-button Exit, never --cancel-label" {
    tui_e2e_make_harness whiptail
    _ac10_responses
    tui_e2e_run
    assert_success
    run grep -- "--cancel-button Exit" "${E2E_WIDGET_LOG}"
    assert_success
    run grep -- "--cancel-label" "${E2E_WIDGET_LOG}"
    assert_failure
}

@test "AC-10: widget argv identical across backends except the cancel spelling" {
    # §8.5 dual-backend guarantee: same screens, same geometry, same rows —
    # the ONLY argv difference is the Cancel-relabel flag.
    tui_e2e_make_harness dialog
    _ac10_responses
    tui_e2e_run
    assert_success
    local _dialog_log
    _dialog_log="$(cat "${E2E_WIDGET_LOG}")"

    tui_e2e_make_harness whiptail
    _ac10_responses
    tui_e2e_run
    assert_success
    run sed 's/--cancel-button/--cancel-label/g' "${E2E_WIDGET_LOG}"
    assert_output "${_dialog_log}"
}

# ── Checked pages → Run → generated CLI command string, per backend ─────────

@test "AC-10 (dialog): accumulated checks → Run → exact CLI command string" {
    tui_e2e_make_harness dialog
    _ac10_responses
    tui_e2e_run
    assert_success
    assert_output --partial "CLI pipeline output"
    run tail -n1 "${E2E_CLI_LOG}"
    assert_output "install eza neovim zoxide -y"
}

@test "AC-10 (whiptail): same checks → byte-identical CLI command string" {
    tui_e2e_make_harness whiptail
    _ac10_responses
    tui_e2e_run
    assert_success
    assert_output --partial "CLI pipeline output"
    run tail -n1 "${E2E_CLI_LOG}"
    assert_output "install eza neovim zoxide -y"
    # The checklist must use --separate-output on whiptail too (the §8.2
    # one-tag-per-line guarantee both backends share).
    run grep -- "--separate-output" "${E2E_WIDGET_LOG}"
    assert_success
}

@test "AC-10 (whiptail): Exit drops selections — exit 0, zero file writes, no fork" {
    tui_e2e_make_harness whiptail
    # optional → cli-essentials → check eza+zoxide → Back out the sub-cat menu →
    # main-menu Exit (rc 1) → exit guard yesno (rc 0 = Yes, confirm leave). The
    # guard response is required since #206 added it to BOTH backends; without it
    # the TUI blocks on the guard prompt (this deadlocked the core-2 kcov shard
    # with no per-test timeout).
    cat >"${E2E_RESPONSES}" <<'EOF'
0|optional
0|cli-essentials
0|eza\nzoxide\n
1|
1|
0|
EOF
    tui_e2e_run
    assert_success
    run find "${E2E_HOME}" -mindepth 1
    assert_output ""
    run grep -c "^install" "${E2E_CLI_LOG}"
    assert_failure
}

# ── #203: ui.tui_hints config switch (startup read) + Help menu entry ─────────

# Empty interaction: straight main-menu Exit (no pending selections → leaves
# immediately, no guard).
_hints_just_exit() {
    cat >"${E2E_RESPONSES}" <<'EOF'
1|
EOF
}

@test "#203 (whiptail): startup forks 'config get ui.tui_hints' exactly once" {
    tui_e2e_make_harness whiptail
    _hints_just_exit
    tui_e2e_run
    assert_success
    run grep -c "^config get ui.tui_hints$" "${E2E_CLI_LOG}"
    assert_output "1"
}

@test "#203 (whiptail): ui.tui_hints=off suppresses the checklist hint line" {
    tui_e2e_make_harness whiptail
    export MOCK_TUI_HINTS="off"
    # optional → cli-essentials → checklist (commit nothing) → Back → Back the
    # sub-cat menu → main Exit (no selections).
    cat >"${E2E_RESPONSES}" <<'EOF'
0|optional
0|cli-essentials
1|
1|
1|
EOF
    tui_e2e_run
    assert_success
    # The whiptail multi-select hint must be absent from every widget invocation.
    run grep -i "tab to" "${E2E_WIDGET_LOG}"
    assert_failure
}

@test "#203 (whiptail): default (on) keeps the checklist hint line" {
    tui_e2e_make_harness whiptail
    # MOCK_TUI_HINTS unset → config get returns empty → default ON.
    # optional → cli-essentials → checklist → Back → Back the sub-cat → Exit.
    cat >"${E2E_RESPONSES}" <<'EOF'
0|optional
0|cli-essentials
1|
1|
1|
EOF
    tui_e2e_run
    assert_success
    run grep -i "tab" "${E2E_WIDGET_LOG}"
    assert_success
}

@test "#203 (whiptail): Help main-menu entry renders the Tab-centric reference" {
    tui_e2e_make_harness whiptail
    # main-menu Help (rc 0, tag "help") → Help msgbox → main Exit.
    cat >"${E2E_RESPONSES}" <<'EOF'
0|help
0|
1|
EOF
    tui_e2e_run
    assert_success
    # The Help msgbox body (passed as the whiptail --msgbox text) centers on Tab.
    run grep -i "tab" "${E2E_WIDGET_LOG}"
    assert_success
}
