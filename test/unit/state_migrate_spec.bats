#!/usr/bin/env bats
# test/unit/state_migrate_spec.bats — lib/state_migrate.sh (ADR-0008 + ADR-0026)
#
# Forward-only schema migration:
#   - no-op when version == current
#   - 0.1.0 -> 0.2.0 splits an installed apt-essentials bundle into the five
#     per-tool modules it actually installed (git/vim/curl/wget/jq), ADR-0026
#   - mandatory backup (state.json.v<old>.bak + bak.latest symlink), ADR-0008
#   - refuse unknown / newer-than-tool versions

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

# Write a v0.1.0 state.json with an installed apt-essentials bundle entry.
_write_v010_with_bundle() {
    cat > "$(_state_path)" <<'JSON'
{
  "version": "0.1.0",
  "installed": {
    "apt-essentials": {
      "synced": {
        "manual": true,
        "depends_on": [],
        "version_provided": "apt-managed",
        "installed_at": "2026-01-02T03:04:05+00:00",
        "installed_by": "init_ubuntu@0.1.0",
        "frozen_pkgs": ["git", "vim", "curl", "wget", "jq", "ca-certificates"],
        "frozen_platform": "rpi-5"
      },
      "local": {"last_verified_at": "2026-01-02T03:04:05+00:00"}
    },
    "docker": {
      "synced": {
        "manual": true,
        "depends_on": ["apt-essentials"],
        "version_provided": "27.4.0",
        "installed_at": "2026-01-02T03:04:05+00:00",
        "installed_by": "init_ubuntu@0.1.0"
      },
      "local": {}
    }
  }
}
JSON
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

@test "state_migrate defines the runner + the 0.1.0->0.2.0 hop" {
    _load_migrate
    declare -F state_migrate_run >/dev/null
    declare -F migrate_0_1_0_to_0_2_0 >/dev/null
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

# ── 0.1.0 -> 0.2.0 apt-essentials split (ADR-0026) ───────────────────────────

@test "migration bumps the schema version to 0.2.0" {
    _load_migrate
    _write_v010_with_bundle
    run state_migrate_run
    assert_success
    run jq -r '.version' "$(_state_path)"
    assert_output "0.2.0"
}

@test "migration drops the apt-essentials bundle entry" {
    _load_migrate
    _write_v010_with_bundle
    state_migrate_run
    run jq -e '.installed | has("apt-essentials")' "$(_state_path)"
    assert_failure
}

@test "migration adds git/vim/curl/wget/jq as manual installed entries" {
    _load_migrate
    _write_v010_with_bundle
    state_migrate_run
    local _tool
    for _tool in git vim curl wget jq; do
        run jq -e --arg t "${_tool}" '.installed[$t].synced.manual == true' "$(_state_path)"
        assert_success
        run jq -r --arg t "${_tool}" '.installed[$t].synced.version_provided' "$(_state_path)"
        assert_output "apt-managed"
        run jq -e --arg t "${_tool}" '.installed[$t].synced.depends_on == []' "$(_state_path)"
        assert_success
    done
}

@test "migration does NOT add build-essential / htop / unzip" {
    _load_migrate
    _write_v010_with_bundle
    state_migrate_run
    local _tool
    for _tool in build-essential htop unzip; do
        run jq -e --arg t "${_tool}" '.installed | has($t)' "$(_state_path)"
        assert_failure
    done
}

@test "migration carries installed_at / installed_by forward to the split tools" {
    _load_migrate
    _write_v010_with_bundle
    state_migrate_run
    run jq -r '.installed.git.synced.installed_at' "$(_state_path)"
    assert_output "2026-01-02T03:04:05+00:00"
    run jq -r '.installed.git.synced.installed_by' "$(_state_path)"
    assert_output "init_ubuntu@0.1.0"
}

@test "migration rebuilds each split tool's local sub-object EMPTY" {
    # ADR-0008 synced-vs-local split: the machine-specific `local` object holds
    # host-derived facts (resolved targets, last_verified_at) that must NOT
    # forward-carry. Every split tool entry must land with local == {} so stale
    # machine state from an earlier (separately-tracked) entry is not preserved.
    _load_migrate
    _write_v010_with_bundle
    state_migrate_run
    local _tool
    for _tool in git vim curl wget jq; do
        run jq -e --arg t "${_tool}" '.installed[$t].local == {}' "$(_state_path)"
        assert_success
    done
}

@test "migration does NOT preserve a pre-existing split tool's stale local" {
    # A 0.1.0 file that already tracked one of the split tools separately (with
    # machine-specific local paths) must have that local wiped on migration —
    # the forward-only shape rebuilds local empty, never carrying poisoned
    # host paths to a new machine.
    _load_migrate
    cat > "$(_state_path)" <<'JSON'
{
  "version": "0.1.0",
  "installed": {
    "apt-essentials": {
      "synced": {"manual": true, "depends_on": [], "version_provided": "apt-managed",
                 "installed_at": "t", "installed_by": "b"},
      "local": {}
    },
    "curl": {
      "synced": {"manual": true, "depends_on": [], "version_provided": "apt-managed"},
      "local": {"install_target_resolved": "/old/machine/path"}
    }
  }
}
JSON
    state_migrate_run
    run jq -e '.installed.curl.local == {}' "$(_state_path)"
    assert_success
}

@test "migration leaves unrelated entries (docker) intact" {
    _load_migrate
    _write_v010_with_bundle
    state_migrate_run
    run jq -e '.installed | has("docker")' "$(_state_path)"
    assert_success
    run jq -r '.installed.docker.synced.version_provided' "$(_state_path)"
    assert_output "27.4.0"
}

@test "migration drops frozen_pkgs / frozen_platform with the bundle" {
    _load_migrate
    _write_v010_with_bundle
    state_migrate_run
    run jq -e '[.. | objects | select(has("frozen_pkgs"))] | length == 0' "$(_state_path)"
    assert_success
}

# ── backup (ADR-0008) ────────────────────────────────────────────────────────

@test "migration writes a state.json.v0.1.0.bak with the pre-migration content" {
    _load_migrate
    _write_v010_with_bundle
    local _orig; _orig="$(cat "$(_state_path)")"
    state_migrate_run
    local _bak; _bak="$(_state_path).v0.1.0.bak"
    [[ -f "${_bak}" ]]
    [[ "$(cat "${_bak}")" == "${_orig}" ]]
}

@test "migration points state.json.bak.latest at the newest backup" {
    _load_migrate
    _write_v010_with_bundle
    state_migrate_run
    local _latest; _latest="$(_state_path).bak.latest"
    [[ -L "${_latest}" ]]
    [[ "$(readlink "${_latest}")" == "state.json.v0.1.0.bak" ]]
}

# ── idempotency: migrating an already-split (no-bundle) 0.1.0 file ────────────

@test "migration of a 0.1.0 file without apt-essentials only bumps the version" {
    _load_migrate
    cat > "$(_state_path)" <<'JSON'
{"version":"0.1.0","installed":{"git":{"synced":{"manual":true,"depends_on":[],"version_provided":"apt-managed"},"local":{}}}}
JSON
    state_migrate_run
    run jq -r '.version' "$(_state_path)"
    assert_output "0.2.0"
    run jq -e '.installed | has("git")' "$(_state_path)"
    assert_success
    run jq -e '.installed | keys | length == 1' "$(_state_path)"
    assert_success
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
    STATE_MIGRATE_CHAIN=("0.1.0" "0.2.0" "0.3.0")
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

# ── direct hop unit (migrate_0_1_0_to_0_2_0) ─────────────────────────────────

@test "migrate_0_1_0_to_0_2_0 is a pure transform on its payload arg" {
    _load_migrate
    local _in='{"version":"0.1.0","installed":{"apt-essentials":{"synced":{"manual":true,"depends_on":[],"version_provided":"apt-managed","installed_at":"t","installed_by":"b"},"local":{}}}}'
    run migrate_0_1_0_to_0_2_0 "${_in}"
    assert_success
    echo "${output}" | jq -e '.version == "0.2.0"' >/dev/null
    echo "${output}" | jq -e '(.installed | has("apt-essentials")) | not' >/dev/null
    echo "${output}" | jq -e '.installed.curl.synced.manual == true' >/dev/null
}
