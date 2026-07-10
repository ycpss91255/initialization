#!/usr/bin/env bats
# test/unit/tui_backend_branches_spec.bats — lib/tui_backend.sh branch coverage
#
# Focused UNIT tests for the error / fallback / dispatch branches of
# lib/tui_backend.sh that the behavior-focused specs (tui_backend_spec,
# tui_manage_spec, tui_detail_spec, tui_quick_setup_spec, tui_whiptail_tier_spec)
# do not drive. After the gum backend was dropped (ADR-0024) the file lost its
# above-average-covered gum adapters; these tests recover real coverage on the
# CLI-fork error paths, the data-broker single error surface, and the menu
# dispatcher's defensive default:
#   - _tui_cli_json ADR-0019 non-JSON validation failure (fork rc 0 but the
#     payload is not JSON).
#   - tui_cli_install_plan / tui_cli_manage_plan fork-FAILED (rc != 0) paths,
#     plus tui_cli_manage_plan's "returned no plan" path.
#   - the broker single error path's msgbox branch (TUI_BACKEND set + a stubbed
#     widget) and the detect-cache accessor error (the list-cache accessor is
#     already covered in tui_backend_spec; the detect one was not).
#   - _tui_category_entry unknown-category early return (defensive default).
#
# HOST-SAFETY: no real whiptail/sudo is ever touched. The command probe is a
# data-driven mock and every forked CLI / widget is a temp script under the
# test scratch dir.

load "${BATS_TEST_DIRNAME}/../helper/common"
load "${BATS_TEST_DIRNAME}/../helper/tui_harness"

# shellcheck source=../../lib/tui_backend.sh
source "${LIB_DIR}/tui_backend.sh"

setup() {
    setup_test_env
    export LC_ALL=C.UTF-8
    unset TUI_BACKEND 2>/dev/null || true
}

teardown() {
    teardown_test_env
}

# ── _tui_cli_json ADR-0019 non-JSON guard ───────────────────────────────────

@test "_tui_cli_json rejects a fork whose stdout is not JSON (ADR-0019 guard)" {
    # CLI exits 0 but prints non-JSON -> the jq -e validation arm fires.
    TUI_CLI="${INIT_UBUNTU_TEST_SCRATCH}/notjson_cli"
    export TUI_CLI
    printf '#!/usr/bin/env bash\nprintf "not json at all\\n"\n' >"${TUI_CLI}"
    chmod +x "${TUI_CLI}"
    run tui_cli_list_json
    assert_failure
    assert_output --partial "did not return JSON"
}

# ── tui_cli_install_plan fork-FAILED (rc != 0) path ─────────────────────────

@test "tui_cli_install_plan fails cleanly when the fork itself exits nonzero" {
    TUI_CLI="${INIT_UBUNTU_TEST_SCRATCH}/exit7_cli"
    export TUI_CLI
    printf '#!/usr/bin/env bash\nexit 7\n' >"${TUI_CLI}"
    chmod +x "${TUI_CLI}"
    run tui_cli_install_plan eza
    assert_failure
    assert_output --partial "failed"
}

# ── tui_cli_manage_plan fork-FAILED + no-plan + happy paths ─────────────────

@test "tui_cli_manage_plan fails cleanly when the fork itself exits nonzero" {
    TUI_CLI="${INIT_UBUNTU_TEST_SCRATCH}/exit5_cli"
    export TUI_CLI
    printf '#!/usr/bin/env bash\nexit 5\n' >"${TUI_CLI}"
    chmod +x "${TUI_CLI}"
    run tui_cli_manage_plan remove eza
    assert_failure
    assert_output --partial "failed"
}

@test "tui_cli_manage_plan fails when the dry-run output carries no plan" {
    TUI_CLI="${INIT_UBUNTU_TEST_SCRATCH}/noplan_cli"
    export TUI_CLI
    printf '#!/usr/bin/env bash\nprintf "nothing useful\\n"\n' >"${TUI_CLI}"
    chmod +x "${TUI_CLI}"
    run tui_cli_manage_plan purge eza
    assert_failure
    assert_output --partial "no plan"
}

@test "tui_cli_manage_plan parses the dry-run bullets in order" {
    TUI_CLI="${INIT_UBUNTU_TEST_SCRATCH}/plan_cli"
    export TUI_CLI
    cat >"${TUI_CLI}" <<'EOF'
#!/usr/bin/env bash
printf 'DRY-RUN: would remove in this order:\n'
printf '  - eza\n'
EOF
    chmod +x "${TUI_CLI}"
    run tui_cli_manage_plan remove eza
    assert_success
    assert_output "eza"
}

# ── broker single error path: msgbox branch + detect accessor error ─────────

@test "_tui_broker_fail renders a msgbox when a backend is wired" {
    # With TUI_BACKEND set AND a tui_render_msgbox in scope, the error path
    # drives the widget branch instead of the bare stderr line.
    export TUI_BACKEND="whiptail"
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/msgbox.log"
    tui_render_msgbox() { printf 'MSGBOX:%s\n' "$2" >"${_log}"; }
    export -f tui_render_msgbox
    run _tui_broker_fail "list --json"
    assert_failure
    run cat "${_log}"
    assert_output --partial "catalog data"
}

@test "tui_broker_detect_json before init is the single error path (detect cache)" {
    unset TUI_BROKER_LIST_CACHE TUI_BROKER_DETECT_CACHE
    run tui_broker_detect_json
    assert_failure
    assert_output --partial "catalog data"
}

# ── library source guard ─────────────────────────────────────────────────────

@test "executing tui_backend.sh directly warns that it is a library (source guard)" {
    run bash "${LIB_DIR}/tui_backend.sh"
    assert_success
    assert_output --partial "library"
}

# ── _tui_category_entry defensive default (unknown category) ─────────────────

@test "_tui_category_entry emits nothing for an unknown category (defensive default)" {
    local _json='{"items":[{"name":"a","category":"mystery","installed":false}]}'
    run _tui_category_entry "${_json}" "mystery" ""
    assert_success
    assert_output ""
}
