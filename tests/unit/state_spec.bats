#!/usr/bin/env bats
# tests/unit/state_spec.bats — lib/state.sh

load "${BATS_TEST_DIRNAME}/../helpers/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
}

teardown() {
    teardown_test_env
}

_load_state() {
    # shellcheck disable=SC1091  # dynamic source path ($VAR resolved at runtime) — https://www.shellcheck.net/wiki/SC1091
    source "${LIB_DIR}/state.sh"
}

# ── path + init ──────────────────────────────────────────────────────────────

@test "state_get_path returns a path under INIT_UBUNTU_STATE_DIR" {
    _load_state
    local _p
    _p="$(state_get_path)"
    [[ "${_p}" == "${INIT_UBUNTU_STATE_DIR}/state.json" ]]
}

@test "state_init creates state.json with schema skeleton" {
    _load_state
    state_init
    local _p; _p="$(state_get_path)"
    [[ -f "${_p}" ]]
    run jq -r '.version' "${_p}"
    assert_success
    assert_output --partial "0.1.0"
    run jq -r '.installed | length' "${_p}"
    assert_success
    assert_output "0"
}

@test "state_init is idempotent (does not overwrite existing data)" {
    _load_state
    state_init
    local _p; _p="$(state_get_path)"
    jq '.installed["foo"] = {"version_provided":"v1"}' "${_p}" > "${_p}.tmp" && mv "${_p}.tmp" "${_p}"
    state_init
    run jq -r '.installed["foo"].version_provided' "${_p}"
    assert_success
    assert_output "v1"
}

# ── record_install / record_remove ──────────────────────────────────────────

@test "state_record_install writes all schema fields" {
    _load_state
    state_record_install docker true apt-managed
    local _p; _p="$(state_get_path)"
    run jq -r '.installed.docker.version_provided' "${_p}"
    assert_success
    assert_output "apt-managed"
    run jq -r '.installed.docker.manual' "${_p}"
    assert_success
    assert_output "true"
    run jq -r '.installed.docker.installed_by' "${_p}"
    assert_success
    assert_output --partial "init_ubuntu"
    run jq -r '.installed.docker.installed_at' "${_p}"
    assert_success
    assert_output --regexp '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}'
}

@test "state_record_install with no <manual> defaults to manual=false (dep)" {
    _load_state
    state_record_install neovim
    local _p; _p="$(state_get_path)"
    run jq -r '.installed.neovim.manual' "${_p}"
    assert_success
    assert_output "false"
}

@test "state_record_install normalizes manual=1|yes|true to boolean true" {
    _load_state
    state_record_install a 1
    state_record_install b yes
    state_record_install c TRUE
    local _p; _p="$(state_get_path)"
    [[ "$(jq -r '.installed.a.manual' "${_p}")" == "true" ]]
    [[ "$(jq -r '.installed.b.manual' "${_p}")" == "true" ]]
    [[ "$(jq -r '.installed.c.manual' "${_p}")" == "true" ]]
}

@test "state_record_remove drops the entry (idempotent on missing)" {
    _load_state
    state_record_install docker true
    state_record_remove docker
    local _p; _p="$(state_get_path)"
    run jq -r '.installed | has("docker")' "${_p}"
    assert_success
    assert_output "false"
    run state_record_remove docker
    assert_success
}

@test "state_record_install can re-record same module (overwrite)" {
    _load_state
    state_record_install docker false v1
    state_record_install docker true v2
    local _p; _p="$(state_get_path)"
    [[ "$(jq -r '.installed.docker.version_provided' "${_p}")" == "v2" ]]
    [[ "$(jq -r '.installed.docker.manual' "${_p}")" == "true" ]]
}

# ── read API ────────────────────────────────────────────────────────────────

@test "state_is_recorded returns 0 for recorded, 1 for not" {
    _load_state
    state_record_install docker
    run state_is_recorded docker
    assert_success
    run state_is_recorded nonexistent
    assert_failure
}

@test "state_list_installed returns sorted names" {
    _load_state
    state_record_install zoo
    state_record_install alpha
    state_record_install middle
    run state_list_installed
    assert_success
    [[ "${lines[0]}" == "alpha" ]]
    [[ "${lines[1]}" == "middle" ]]
    [[ "${lines[2]}" == "zoo" ]]
}

@test "state_list_installed --manual-only filters" {
    _load_state
    state_record_install user-pick true
    state_record_install dep false
    run state_list_installed --manual-only
    assert_success
    assert_output "user-pick"
}

@test "state_get_field reads single field" {
    _load_state
    state_record_install docker true v27
    run state_get_field docker version_provided
    assert_success
    assert_output "v27"
    run state_get_field docker manual
    assert_success
    assert_output "true"
}

@test "state_get_field returns empty for missing module / field" {
    _load_state
    state_init
    run state_get_field nonexistent version_provided
    assert_success
    assert_output ""
}

# ── concurrency: flock serializes writes ────────────────────────────────────

@test "concurrent record_install does not lose updates" {
    _load_state
    state_init
    for i in 1 2 3 4 5; do
        ( state_record_install "mod-${i}" false "v${i}" ) &
    done
    wait
    local _p; _p="$(state_get_path)"
    run jq -r '.installed | keys | length' "${_p}"
    assert_success
    assert_output "5"
}
