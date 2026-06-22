#!/usr/bin/env bats
# test/unit/tui_whiptail_tier_spec.bats — whiptail Fallback tier parity (#242 D10)
#
# ADR-0024 D10: the whiptail Fallback tier is FEATURE-equivalent to the fzf
# Rich tier, only render-degraded. This spec covers the SHARED data-layer
# producers that both tiers consume so the two tiers stay behaviorally
# identical:
#   - tui_subtags / tui_subtag_count        (TAGS[0] bucketing — shared between
#                                            the whiptail drill-down and the fzf
#                                            sub-category branches)
#   - tui_category_sel_stats                (PRD D2 SELECTED/total counts, the
#                                            whiptail mirror of
#                                            tui_fzf_category_sel_stats)
#   - tui_recommended_preselect_modules     (PRD D4 pre-selection set, the pure
#                                            producer BOTH tiers wrap)
#
# HOST-SAFETY: pure functions over JSON. No real fzf/whiptail, no host writes
# outside the test scratch.

load "${BATS_TEST_DIRNAME}/../helper/common"
load "${BATS_TEST_DIRNAME}/../helper/tui_harness.bash"

# shellcheck source=../../lib/tui_render_fzf.sh
source "${LIB_DIR}/tui_render_fzf.sh"

setup() {
    setup_test_env
    export LC_ALL=C.UTF-8
    export INIT_UBUNTU_LANG=en
    SELSTATE="$(mktemp "${BATS_TEST_TMPDIR}/sel.XXXXXX")"
}

teardown() {
    teardown_test_env
}

# ── tui_subtags: shared TAGS[0] bucketing ────────────────────────────────────

@test "tui_subtags: distinct TAGS[0] buckets of a category, alphabetical" {
    run tui_subtags "${FIXTURE_LIST_JSON}" optional
    assert_success
    # optional has eza/zoxide (cli-essentials) + claude-code (agent).
    assert_line --index 0 "agent"
    assert_line --index 1 "cli-essentials"
}

@test "tui_subtags: a category with one bucket yields a single line" {
    run tui_subtags "${FIXTURE_LIST_JSON}" base
    assert_success
    assert_output "http"
}

@test "tui_subtag_count: counts the distinct buckets" {
    run tui_subtag_count "${FIXTURE_LIST_JSON}" optional
    assert_success
    assert_output "2"
    run tui_subtag_count "${FIXTURE_LIST_JSON}" recommended
    assert_success
    assert_output "2"
}

@test "tui_subtags: the fzf wrapper delegates to the shared producer" {
    # tui_fzf_subtags must now produce byte-identical output to tui_subtags
    # (the fzf tier wraps the shared bucketing).
    local _shared _fzf
    _shared="$(tui_subtags "${FIXTURE_LIST_JSON}" optional)"
    _fzf="$(tui_fzf_subtags "${FIXTURE_LIST_JSON}" optional)"
    [[ "${_shared}" == "${_fzf}" ]]
}

# ── tui_category_sel_stats: PRD D2 SELECTED/total ────────────────────────────

@test "tui_category_sel_stats: 0 selected of total for an untouched category" {
    run tui_category_sel_stats "${FIXTURE_LIST_JSON}" optional ""
    assert_success
    assert_output "0 3"
}

@test "tui_category_sel_stats: counts only the selected names in the category" {
    run tui_category_sel_stats "${FIXTURE_LIST_JSON}" optional " eza zoxide "
    assert_success
    assert_output "2 3"
}

@test "tui_category_sel_stats: a selection in another category does not count" {
    run tui_category_sel_stats "${FIXTURE_LIST_JSON}" optional " neovim "
    assert_success
    assert_output "0 3"
}

@test "tui_category_sel_stats: matches tui_fzf_category_sel_stats (D2 parity)" {
    # Same selection set, both tiers' count producers must agree.
    printf '%s\n' eza zoxide >"${SELSTATE}"
    local _whip _fzf
    _whip="$(tui_category_sel_stats "${FIXTURE_LIST_JSON}" optional " eza zoxide ")"
    _fzf="$(tui_fzf_category_sel_stats "${FIXTURE_LIST_JSON}" optional "${SELSTATE}")"
    [[ "${_whip}" == "${_fzf}" ]]
}

# ── tui_recommended_preselect_modules: PRD D4 shared producer ────────────────

@test "tui_recommended_preselect_modules: is_recommended names surviving the filter" {
    local _json
    _json="$(jq '.items |= map(if .name == "docker"
        then .recommended = true else . end)' <<<"${FIXTURE_LIST_JSON}")"
    run tui_recommended_preselect_modules "${_json}" desktop
    assert_success
    assert_output "docker"
}

@test "tui_recommended_preselect_modules: a platform-gated module drops off" {
    local _json
    _json="$(jq '.items |= map(if .name == "docker"
        then .recommended = true else . end)' <<<"${FIXTURE_LIST_JSON}")"
    # docker supports desktop/server only — on wsl it must not appear.
    run tui_recommended_preselect_modules "${_json}" wsl
    assert_success
    assert_output ""
}

@test "tui_recommended_preselect_modules: matches the fzf preselect set (D4 parity)" {
    local _json
    _json="$(jq '.items |= map(if .name == "docker"
        then .recommended = true else . end)' <<<"${FIXTURE_LIST_JSON}")"
    # fzf tier wraps the same producer into the selstate file; compare results.
    tui_fzf_recommended_preselect "${_json}" "${SELSTATE}" desktop
    local _fzf_set _shared_set
    _fzf_set="$(tui_fzf_sel_list "${SELSTATE}")"
    _shared_set="$(tui_recommended_preselect_modules "${_json}" desktop | sort)"
    [[ "${_fzf_set}" == "${_shared_set}" ]]
}

# ── PARITY CONTRACT: identical choices → identical install argv ───────────────
# Given the SAME final selection set, the whiptail accumulator (TUI_SELECTION)
# and the fzf selection-state file must produce the SAME `setup_ubuntu install`
# fork argv (ADR-0024 D10 — feature-equivalent tiers). Both tiers feed their
# names into the ONE producer tui_install_args, so the argv is identical
# modulo nothing (no backend-flag spelling differs on the install path).

@test "parity: whiptail accumulator and fzf selstate yield identical install argv" {
    # Whiptail tier: the names live in TUI_SELECTION.
    TUI_SELECTION=()
    TUI_SELECTION[eza]=1
    TUI_SELECTION[neovim]=1
    TUI_SELECTION[zoxide]=1
    local -a _whip_names=() _whip_argv=()
    mapfile -t _whip_names < <(tui_selection_list)
    mapfile -t _whip_argv < <(tui_install_args "" "${_whip_names[@]}")

    # fzf tier: the same names live in the selstate file.
    printf '%s\n' eza neovim zoxide >"${SELSTATE}"
    local -a _fzf_names=() _fzf_argv=()
    mapfile -t _fzf_names < <(tui_fzf_sel_list "${SELSTATE}")
    mapfile -t _fzf_argv < <(tui_install_args "" "${_fzf_names[@]}")

    [[ "${_whip_argv[*]}" == "${_fzf_argv[*]}" ]]
    # And the argv is the canonical install pipeline (sorted names + -y).
    [[ "${_whip_argv[*]}" == "install eza neovim zoxide -y" ]]
}

@test "parity: a platform override threads identically into both tiers' argv" {
    TUI_SELECTION=()
    TUI_SELECTION[eza]=1
    local -a _whip_names=() _whip_argv=()
    mapfile -t _whip_names < <(tui_selection_list)
    mapfile -t _whip_argv < <(tui_install_args "rpi-5" "${_whip_names[@]}")

    printf '%s\n' eza >"${SELSTATE}"
    local -a _fzf_names=() _fzf_argv=()
    mapfile -t _fzf_names < <(tui_fzf_sel_list "${SELSTATE}")
    mapfile -t _fzf_argv < <(tui_install_args "rpi-5" "${_fzf_names[@]}")

    [[ "${_whip_argv[*]}" == "${_fzf_argv[*]}" ]]
    [[ "${_whip_argv[*]}" == "install --profile=rpi-5 eza -y" ]]
}
