#!/usr/bin/env bats
# test/unit/state_interface_spec.bats — the converged State module interface
#
# Architecture deepening #1: lib/state.sh, lib/state_migrate.sh and
# lib/state_io.sh are presented as ONE State module through state.sh. Migration
# (state_migrate.sh) and import/export (state_io.sh) are INTERNAL SEAMS — the
# engine reaches them only through the external State interface:
#   state_init, the record_* writers, the field accessors, the io export/import.
#
# This spec drives that interface END-TO-END and asserts OBSERVABLE outcomes
# THROUGH the interface (state_list_installed / state_get_field / the exported
# payload), NOT internal file shapes. The keystone flow is:
#
#   init (on an OLD-version state.json) -> migration runs INTERNALLY -> record
#   a fresh module -> export the synced payload
#
# The companion state_migrate_spec.bats / state_io_spec.bats keep covering the
# seams directly; this spec proves the convergence: migration is folded into
# state_init (no separate state_migrate_run call), and one source-the-module
# load wires the whole interface up.

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

# Load the State module exactly the way the engine entry point does: state.sh
# first (the external interface), then the two internal seams alongside it.
_load_state_module() {
    # shellcheck source=../../lib/logger.sh
    source "${LIB_DIR}/logger.sh"
    # shellcheck source=../../lib/general.sh
    source "${LIB_DIR}/general.sh"
    # shellcheck source=../../lib/state.sh
    source "${LIB_DIR}/state.sh"
    # shellcheck source=../../lib/state_migrate.sh
    source "${LIB_DIR}/state_migrate.sh"
    # shellcheck source=../../lib/state_io.sh
    source "${LIB_DIR}/state_io.sh"
}

_state_path() {
    printf '%s/state.json' "${INIT_UBUNTU_STATE_DIR}"
}

# An older-schema state.json (pre-baseline) with one installed module. The
# interface should migrate this on state_init, never via a separate migrate
# call. The apt-essentials 0.1.0 -> 0.2.0 hop was retired (0.1.0 was never
# released), so the framework ships with no live hops — this spec registers a
# SYNTHETIC hop in-shell to exercise the "migration folded into init" seam
# generically (the same technique state_migrate_spec.bats uses).
_write_old_version_file() {
    cat > "$(_state_path)" <<'JSON'
{
  "version": "0.1.9",
  "installed": {
    "legacy": {
      "synced": {
        "manual": true,
        "depends_on": [],
        "version_provided": "apt-managed",
        "installed_at": "2026-01-02T03:04:05+00:00",
        "installed_by": "init_ubuntu@0.1.9"
      },
      "local": {"last_verified_at": "2026-01-02T03:04:05+00:00"}
    }
  }
}
JSON
}

# Register a synthetic 0.1.9 -> 0.2.0 hop in THIS shell so state_init's internal
# state_migrate_run has a hop to replay. The hop adds an observable `migrated`
# module (version_provided "hop-added") and bumps the version to the baseline.
_register_synthetic_hop() {
    STATE_MIGRATE_CHAIN=("0.1.9" "0.2.0")
    migrate_0_1_9_to_0_2_0() {
        jq '.version = "0.2.0"
            | .installed.migrated = {
                synced: {manual: true, depends_on: [], version_provided: "hop-added"},
                local: {}
              }' <<<"$1"
    }
}

# ── convergence: one load wires the whole external interface ─────────────────

@test "State interface: one module load exposes init + writers + accessors + io" {
    _load_state_module
    # External State interface (architecture deepening #1).
    declare -F state_init           >/dev/null
    declare -F state_record_install >/dev/null
    declare -F state_get_field      >/dev/null
    declare -F state_list_installed >/dev/null
    declare -F state_io_export      >/dev/null
    declare -F state_io_import_apply >/dev/null
}

# ── the keystone flow: init(old file) -> migrate -> record -> export ─────────

@test "State interface: state_init migrates an old-version file INTERNALLY (no separate migrate call)" {
    _load_state_module
    _register_synthetic_hop
    _write_old_version_file

    # ONLY the interface is touched — no state_migrate_run here. state_init
    # folds the migration in.
    run state_init
    assert_success

    # Observable through the interface: the hop's `migrated` module is now
    # installed alongside the carried-forward `legacy` entry. (Asserted via
    # state_list_installed, not the file.)
    run state_list_installed
    assert_success
    assert_line "migrated"
    assert_line "legacy"
}

@test "State interface: migrated entries are observable via the field accessor" {
    _load_state_module
    _register_synthetic_hop
    _write_old_version_file
    state_init

    # version_provided / manual surface through state_get_field (the interface),
    # carrying the migration's output forward.
    run state_get_field migrated version_provided
    assert_success
    assert_output "hop-added"
    run state_get_field migrated manual
    assert_success
    assert_output "true"
}

@test "State interface: init -> migrate -> record -> export round-trips a fresh module" {
    _load_state_module
    _register_synthetic_hop
    _write_old_version_file

    # init folds migration in; then record a brand-new module through the writer.
    state_init
    state_record_install neovim true v0.10.5 "fzf"

    # export through the io seam — observable payload, not file internals.
    local _out="${INIT_UBUNTU_TEST_SCRATCH}/payload.json"
    run state_io_export "${_out}"
    assert_success
    [[ -f "${_out}" ]]

    # The payload carries BOTH the migration output AND the freshly recorded
    # module, all via the synced section (ADR-0018: local never ships).
    run jq -r '.modules[].name' "${_out}"
    assert_success
    assert_line "migrated"
    assert_line "neovim"

    run jq -r '.modules[] | select(.name == "neovim") | .synced.version_provided' "${_out}"
    assert_success
    assert_output "v0.10.5"
    run jq -cr '.modules[] | select(.name == "neovim") | .synced.depends_on' "${_out}"
    assert_success
    assert_output '["fzf"]'

    # No local section ever leaves the host (ADR-0018), even after a migration.
    run jq -r '[.modules[] | has("local")] | any' "${_out}"
    assert_success
    assert_output "false"
}

# ── fatal migration surfaces through state_init (ADR-0008) ────────────────────

@test "State interface: a failed migration is FATAL through state_init (file + .bak untouched)" {
    _load_state_module
    # An on-file version newer than the tool is a refuse-to-migrate case
    # (ADR-0008 no-downgrade). Through the interface it must be fatal.
    printf '{"version":"9.9.9","installed":{}}\n' > "$(_state_path)"
    local _before; _before="$(cat "$(_state_path)")"

    run state_init
    assert_failure
    assert_output --partial "unknown tool version"

    # Original file is left exactly as it was (ADR-0008: never touched on refusal).
    [[ "$(cat "$(_state_path)")" == "${_before}" ]]
    # No backup is written for a refused migration.
    [[ -z "$(find "${INIT_UBUNTU_STATE_DIR}" -name 'state.json.v*.bak' 2>/dev/null)" ]]
}

# ── idempotency: an already-current file passes init untouched ───────────────

@test "State interface: state_init is idempotent on an already-current file" {
    _load_state_module
    state_init                       # fresh skeleton at current schema
    state_record_install docker true v1
    local _before; _before="$(cat "$(_state_path)")"

    run state_init                   # second init: no migration churn
    assert_success
    [[ "$(cat "$(_state_path)")" == "${_before}" ]]
    # Still no spurious backup from a no-op migration.
    [[ -z "$(find "${INIT_UBUNTU_STATE_DIR}" -name 'state.json.v*.bak' 2>/dev/null)" ]]
}
