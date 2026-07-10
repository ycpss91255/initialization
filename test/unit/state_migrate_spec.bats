#!/usr/bin/env bats
# test/unit/state_migrate_spec.bats — lib/state_migrate.sh (ADR-0008)
#
# Forward-only schema-migration FRAMEWORK. The apt-essentials 0.1.0 -> 0.2.0
# hop was retired (0.1.0 was never released), so the framework currently
# defines NO migration hops. These specs cover the machinery generically:
#   - no-op when version == current (baseline 0.2.0)
#   - refuse unknown / newer-than-tool / version-less files (ADR-0008)
#   - backup + replay + atomic write for a SYNTHETIC hop registered in-shell
#     (proves the framework still works for the first real future migration)

bats_require_minimum_version 1.5.0

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
}

teardown() {
    teardown_test_env
}

_load_migrate() {
    # shellcheck source=../../lib/logger.sh
    source "${LIB_DIR}/logger.sh"
    # shellcheck source=../../lib/general.sh
    source "${LIB_DIR}/general.sh"
    # shellcheck source=../../lib/state.sh
    source "${LIB_DIR}/state.sh"
    # shellcheck source=../../lib/state_migrate.sh
    source "${LIB_DIR}/state_migrate.sh"
}

_state_path() {
    printf '%s/state.json' "${INIT_UBUNTU_STATE_DIR}"
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "state_migrate.sh parses (bash -n)" {
    run bash -n "${LIB_DIR}/state_migrate.sh"
    assert_success
}

@test "state_migrate.sh sourced as a library does not run main" {
    run bash "${LIB_DIR}/state_migrate.sh"
    assert_output --partial "is a library"
}

@test "state_migrate defines the runner + the framework helpers (no live hops)" {
    _load_migrate
    declare -F state_migrate_run          >/dev/null
    declare -F _state_migrate_chain_index >/dev/null
    declare -F _state_migrate_backup      >/dev/null
    # The retired apt-essentials hop must NOT be defined.
    run declare -F migrate_0_1_0_to_0_2_0
    assert_failure
    # The chain is a single baseline entry (no hops).
    [[ "${#STATE_MIGRATE_CHAIN[@]}" -eq 1 ]]
    [[ "${STATE_MIGRATE_CHAIN[0]}" == "0.2.0" ]]
}

# ── no-op / fresh ────────────────────────────────────────────────────────────

@test "state_migrate_run is a no-op when state.json is absent" {
    _load_migrate
    run state_migrate_run
    assert_success
    [[ ! -f "$(_state_path)" ]]
}

@test "state_migrate_run is a no-op when version already current" {
    _load_migrate
    printf '{"version":"0.2.0","installed":{}}\n' > "$(_state_path)"
    local _before; _before="$(cat "$(_state_path)")"
    run state_migrate_run
    assert_success
    [[ "$(cat "$(_state_path)")" == "${_before}" ]]
    # No backup is written for a no-op.
    [[ -z "$(find "${INIT_UBUNTU_STATE_DIR}" -name 'state.json.v*.bak' 2>/dev/null)" ]]
}

# ── framework: backup + replay + atomic write (synthetic hop) ────────────────

@test "framework: state_migrate_run backs up and replays a registered hop" {
    # The framework is content-free after the apt-essentials hop was retired.
    # Register a synthetic earlier version + hop IN THIS SHELL to prove the
    # backup / replay / atomic-write machinery (ADR-0008) still works for the
    # first real future migration. current == STATE_SCHEMA_VERSION == 0.2.0.
    _load_migrate
    STATE_MIGRATE_CHAIN=("0.1.9" "0.2.0")
    migrate_0_1_9_to_0_2_0() {
        jq '.version = "0.2.0" | .installed.marker = {synced:{manual:true}, local:{}}' <<<"$1"
    }
    printf '{"version":"0.1.9","installed":{}}\n' > "$(_state_path)"
    local _orig; _orig="$(cat "$(_state_path)")"

    run state_migrate_run
    assert_success

    # Mandatory backup written with the pre-migration content (ADR-0008).
    local _bak; _bak="$(_state_path).v0.1.9.bak"
    [[ -f "${_bak}" ]]
    [[ "$(cat "${_bak}")" == "${_orig}" ]]
    # bak.latest points at the newest backup.
    [[ -L "$(_state_path).bak.latest" ]]
    [[ "$(readlink "$(_state_path).bak.latest")" == "state.json.v0.1.9.bak" ]]
    # The hop's transform landed via the atomic write.
    run jq -r '.version' "$(_state_path)"
    assert_output "0.2.0"
    run jq -e '.installed | has("marker")' "$(_state_path)"
    assert_success
}

@test "framework: state_migrate_run errors when a chained hop function is missing" {
    _load_migrate
    STATE_MIGRATE_CHAIN=("0.1.9" "0.2.0")
    # No migrate_0_1_9_to_0_2_0 defined -> the replay loop must abort.
    printf '{"version":"0.1.9","installed":{}}\n' > "$(_state_path)"
    run state_migrate_run
    assert_failure
    assert_output --partial "missing migration step"
}

# ── refusal paths (ADR-0008) ─────────────────────────────────────────────────

@test "state_migrate_run refuses an unknown on-file version" {
    _load_migrate
    printf '{"version":"9.9.9","installed":{}}\n' > "$(_state_path)"
    run state_migrate_run
    assert_failure
    assert_output --partial "unknown tool version"
}

@test "state_migrate_run refuses a newer-than-tool version (no downgrade)" {
    _load_migrate
    # Fake a newer registered version by extending the chain in this shell.
    STATE_MIGRATE_CHAIN=("0.1.9" "0.2.0" "0.3.0")
    printf '{"version":"0.3.0","installed":{}}\n' > "$(_state_path)"
    run state_migrate_run
    assert_failure
    assert_output --partial "downgrade is not supported"
}

@test "state_migrate_run refuses a state.json with no version field" {
    _load_migrate
    printf '{"installed":{}}\n' > "$(_state_path)"
    run state_migrate_run
    assert_failure
    assert_output --partial "no 'version' field"
}
