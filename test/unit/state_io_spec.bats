#!/usr/bin/env bats
# test/unit/state_io_spec.bats — lib/state_io.sh

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
}

teardown() {
    teardown_test_env
}

_load_state_io() {
    # shellcheck disable=SC1091
    source "${LIB_DIR}/state.sh"
    # shellcheck disable=SC1091
    source "${LIB_DIR}/state_io.sh"
}

# ── export ──────────────────────────────────────────────────────────────────

@test "state_io_export with empty state writes an empty modules list" {
    _load_state_io
    state_init
    local _out="${INIT_UBUNTU_TEST_SCRATCH}/payload.json"
    state_io_export "${_out}"
    [[ -f "${_out}" ]]
    run jq -r '.modules | length' "${_out}"
    assert_success
    assert_output "0"
}

@test "state_io_export emits payload schema fields" {
    _load_state_io
    state_record_install docker true apt-managed
    local _out="${INIT_UBUNTU_TEST_SCRATCH}/payload.json"
    state_io_export "${_out}"

    run jq -r '.version' "${_out}"
    assert_success
    assert_output --partial "0.1.0"

    run jq -r '.source_host' "${_out}"
    assert_success
    [[ -n "${output}" ]]

    run jq -r '.source_user' "${_out}"
    assert_success
    [[ -n "${output}" ]]

    run jq -r '.exported_at' "${_out}"
    assert_success
    assert_output --regexp '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}'

    run jq -r '.include_config' "${_out}"
    assert_success
    assert_output "false"
}

@test "state_io_export includes module entry with name+manual" {
    _load_state_io
    state_record_install docker true apt-managed
    local _out="${INIT_UBUNTU_TEST_SCRATCH}/payload.json"
    state_io_export "${_out}"

    run jq -r '.modules[0].name' "${_out}"
    assert_success
    assert_output "docker"
    run jq -r '.modules[0].manual' "${_out}"
    assert_success
    assert_output "true"
}

@test "state_io_export --modules filters to the specified subset" {
    _load_state_io
    state_record_install docker true
    state_record_install neovim true
    state_record_install fzf false
    local _out="${INIT_UBUNTU_TEST_SCRATCH}/payload.json"
    state_io_export "${_out}" --modules=docker,fzf

    run jq -r '.modules | length' "${_out}"
    assert_success
    assert_output "2"

    run jq -r '.modules[0].name' "${_out}"
    assert_output "docker"
    run jq -r '.modules[1].name' "${_out}"
    assert_output "fzf"
}

@test "state_io_export rejects unknown flag" {
    _load_state_io
    state_init
    local _out="${INIT_UBUNTU_TEST_SCRATCH}/payload.json"
    run state_io_export "${_out}" --bogus
    assert_failure 2
}

@test "state_io_export with missing <out-file> arg returns 2" {
    _load_state_io
    state_init
    run state_io_export
    assert_failure 2
}

# ── import / payload_modules ───────────────────────────────────────────────

@test "state_io_payload_modules prints module names in payload order" {
    _load_state_io
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/in.json"
    cat > "${_payload}" <<'EOF'
{
  "version": "0.1.0",
  "source_host": "test",
  "source_user": "tester",
  "exported_at": "2026-05-14T10:00:00+00:00",
  "modules": [
    {"name": "docker", "manual": true},
    {"name": "fzf", "manual": false}
  ],
  "include_config": false
}
EOF
    run state_io_payload_modules "${_payload}"
    assert_success
    [[ "${lines[0]}" == "docker" ]]
    [[ "${lines[1]}" == "fzf" ]]
}

@test "state_io_import is an alias for state_io_payload_modules" {
    _load_state_io
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/in.json"
    cat > "${_payload}" <<'EOF'
{"version":"0.1.0","modules":[{"name":"docker","manual":true}]}
EOF
    run state_io_import "${_payload}"
    assert_success
    assert_output "docker"
}

@test "state_io_payload_modules rejects payload missing 'version'" {
    _load_state_io
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/in.json"
    echo '{"modules":[]}' > "${_payload}"
    run state_io_payload_modules "${_payload}"
    assert_failure 2
    assert_output --partial "missing 'version'"
}

@test "state_io_payload_modules rejects incompatible major version" {
    _load_state_io
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/in.json"
    echo '{"version":"1.0.0","modules":[]}' > "${_payload}"
    run state_io_payload_modules "${_payload}"
    assert_failure 2
    assert_output --partial "not supported"
}

@test "state_io_payload_modules errors on missing file" {
    _load_state_io
    run state_io_payload_modules "${INIT_UBUNTU_TEST_SCRATCH}/does-not-exist.json"
    assert_failure 2
}

# ── round trip ─────────────────────────────────────────────────────────────

@test "export -> payload_modules round trip preserves module names" {
    _load_state_io
    state_record_install docker true
    state_record_install neovim true
    local _out="${INIT_UBUNTU_TEST_SCRATCH}/payload.json"
    state_io_export "${_out}"

    run state_io_payload_modules "${_out}"
    assert_success
    [[ "${lines[0]}" == "docker" ]]
    [[ "${lines[1]}" == "neovim" ]]
}
