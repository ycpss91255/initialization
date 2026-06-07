#!/usr/bin/env bats
# test/unit/state_spec.bats — lib/state.sh

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
}

teardown() {
    teardown_test_env
}

_load_state() {
    # shellcheck source=../../lib/state.sh
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

@test "state_record_install writes all schema fields under synced (ADR-0018)" {
    _load_state
    state_record_install docker true apt-managed
    local _p; _p="$(state_get_path)"
    run jq -r '.installed.docker.synced.version_provided' "${_p}"
    assert_success
    assert_output "apt-managed"
    run jq -r '.installed.docker.synced.manual' "${_p}"
    assert_success
    assert_output "true"
    run jq -r '.installed.docker.synced.installed_by' "${_p}"
    assert_success
    assert_output --partial "init_ubuntu"
    run jq -r '.installed.docker.synced.installed_at' "${_p}"
    assert_success
    assert_output --regexp '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}'
}

@test "state_record_install creates the synced/local split shape (ADR-0018)" {
    _load_state
    state_record_install docker true apt-managed
    local _p; _p="$(state_get_path)"
    run jq -r '.installed.docker | has("synced") and has("local")' "${_p}"
    assert_success
    assert_output "true"
    # local starts empty — populated by the local install pipeline only.
    run jq -r '.installed.docker.local | length' "${_p}"
    assert_success
    assert_output "0"
}

@test "state_record_install records depends_on snapshot (4th arg, csv)" {
    _load_state
    state_record_install neovim true v0.10.2 "fzf,lazygit,ripgrep"
    local _p; _p="$(state_get_path)"
    run jq -cr '.installed.neovim.synced.depends_on' "${_p}"
    assert_success
    assert_output '["fzf","lazygit","ripgrep"]'
}

@test "state_record_install with no depends_on defaults to []" {
    _load_state
    state_record_install docker true
    local _p; _p="$(state_get_path)"
    run jq -cr '.installed.docker.synced.depends_on' "${_p}"
    assert_success
    assert_output '[]'
}

@test "state_record_install with no <manual> defaults to manual=false (dep)" {
    _load_state
    state_record_install neovim
    local _p; _p="$(state_get_path)"
    run jq -r '.installed.neovim.synced.manual' "${_p}"
    assert_success
    assert_output "false"
}

@test "state_record_install normalizes manual=1|yes|true to boolean true" {
    _load_state
    state_record_install a 1
    state_record_install b yes
    state_record_install c TRUE
    local _p; _p="$(state_get_path)"
    [[ "$(jq -r '.installed.a.synced.manual' "${_p}")" == "true" ]]
    [[ "$(jq -r '.installed.b.synced.manual' "${_p}")" == "true" ]]
    [[ "$(jq -r '.installed.c.synced.manual' "${_p}")" == "true" ]]
}

@test "state_record_install preserves existing local section on re-record" {
    _load_state
    state_record_install docker false v1
    local _p; _p="$(state_get_path)"
    jq '.installed.docker.local.install_target_resolved = "sudo"' "${_p}" \
        > "${_p}.tmp" && mv "${_p}.tmp" "${_p}"
    state_record_install docker true v2
    run jq -r '.installed.docker.local.install_target_resolved' "${_p}"
    assert_success
    assert_output "sudo"
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
    [[ "$(jq -r '.installed.docker.synced.version_provided' "${_p}")" == "v2" ]]
    [[ "$(jq -r '.installed.docker.synced.manual' "${_p}")" == "true" ]]
}

# ── synced section accessors (ADR-0018, issue #43) ──────────────────────────

@test "state_get_synced prints the synced JSON object" {
    _load_state
    state_record_install docker true v27 "apt-essentials"
    run state_get_synced docker
    assert_success
    echo "${output}" | jq -e '.manual == true and .version_provided == "v27"
        and .depends_on == ["apt-essentials"]' > /dev/null
}

@test "state_get_synced on missing module prints nothing" {
    _load_state
    state_init
    run state_get_synced nonexistent
    assert_success
    assert_output ""
}

@test "state_set_synced creates entry with empty local section" {
    _load_state
    state_init
    state_set_synced docker '{"manual":true,"depends_on":[],"version_provided":"v28"}'
    local _p; _p="$(state_get_path)"
    run jq -r '.installed.docker.synced.version_provided' "${_p}"
    assert_success
    assert_output "v28"
    run jq -r '.installed.docker.local | length' "${_p}"
    assert_success
    assert_output "0"
}

@test "state_set_synced preserves existing local section" {
    _load_state
    state_record_install docker false v1
    local _p; _p="$(state_get_path)"
    jq '.installed.docker.local.user_home_root = "/home/u/.local/lib/x"' "${_p}" \
        > "${_p}.tmp" && mv "${_p}.tmp" "${_p}"
    state_set_synced docker '{"manual":true,"version_provided":"v2"}'
    [[ "$(jq -r '.installed.docker.synced.version_provided' "${_p}")" == "v2" ]]
    [[ "$(jq -r '.installed.docker.local.user_home_root' "${_p}")" == "/home/u/.local/lib/x" ]]
}

@test "state_set_synced rejects non-object JSON" {
    _load_state
    state_init
    run state_set_synced docker 'not-json'
    assert_failure
    run state_set_synced docker '["array"]'
    assert_failure
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

# ── corruption: quarantine + fail fast (PRD §10.1, issue #41) ───────────────

@test "corrupt state.json: read fails (exit 1) and file is quarantined" {
    _load_state
    state_init
    local _p; _p="$(state_get_path)"
    printf 'not json {{{' > "${_p}"

    run state_is_recorded docker
    assert_failure

    # quarantined copy exists; original is gone — and NOT silently rebuilt
    local _q=("${_p}".corrupt.*)
    [[ -e "${_q[0]}" ]]
    [[ ! -f "${_p}" ]]
}

@test "corrupt state.json: recovery guidance mentions rerun-rebuild + manual rename" {
    _load_state
    state_init
    local _p; _p="$(state_get_path)"
    printf '{"version": broken' > "${_p}"

    run state_list_installed
    assert_failure
    assert_output --partial "quarantined"
    assert_output --partial "re-run"
    assert_output --partial "rename"
}

@test "corrupt state.json: write fails fast without silent rebuild" {
    _load_state
    state_init
    local _p; _p="$(state_get_path)"
    printf '{broken' > "${_p}"

    run state_record_install docker true v1
    assert_failure

    local _q=("${_p}".corrupt.*)
    [[ -e "${_q[0]}" ]]
    [[ ! -f "${_p}" ]]
}

@test "corrupt state.json: quarantined file preserves original bytes (no data loss)" {
    _load_state
    state_init
    local _p; _p="$(state_get_path)"
    printf '{"installed":{"docker":{"manual":true}}  TRUNCATED' > "${_p}"

    run state_get_field docker manual
    assert_failure

    local _q=("${_p}".corrupt.*)
    [[ "$(cat "${_q[0]}")" == '{"installed":{"docker":{"manual":true}}  TRUNCATED' ]]
}

@test "non-object JSON state.json (null) is treated as corrupt" {
    _load_state
    state_init
    local _p; _p="$(state_get_path)"
    printf 'null\n' > "${_p}"

    run state_list_installed
    assert_failure
    local _q=("${_p}".corrupt.*)
    [[ -e "${_q[0]}" ]]
}

@test "state_init on corrupt state.json quarantines and fails (never recreates in-run)" {
    _load_state
    state_init
    local _p; _p="$(state_get_path)"
    printf 'garbage' > "${_p}"

    run state_init
    assert_failure
    [[ ! -f "${_p}" ]]
}

# ── lock contention UX (PRD §10.1, issue #41) ───────────────────────────────

# Holds the state flock from a background subshell, recording its PID in
# <lock>.pid (same convention the writer uses) for <hold-secs> seconds.
_hold_state_lock() {
    local _lock="$1" _hold_secs="$2"
    (
        exec 9>>"${_lock}"
        flock -x 9
        printf '%s' "${BASHPID}" > "${_lock}.pid"
        sleep "${_hold_secs}"
    ) &
    HOLD_LOCK_PID=$!
    # Wait until the holder has the lock (pid file appears).
    local _i
    for _i in $(seq 1 50); do
        [[ -f "${_lock}.pid" ]] && return 0
        sleep 0.1
    done
    return 1
}

@test "contended write prints one-line wait notice then succeeds" {
    _load_state
    state_init
    local _lock="${INIT_UBUNTU_STATE_DIR}/.state.lock"
    _hold_state_lock "${_lock}" 2

    INIT_UBUNTU_LOCK_TIMEOUT=10 run state_record_install docker true v1
    wait "${HOLD_LOCK_PID}"

    assert_success
    assert_output --partial "waiting for state lock"
    local _p; _p="$(state_get_path)"
    [[ "$(jq -r '.installed.docker.synced.version_provided' "${_p}")" == "v1" ]]
}

@test "lock timeout exits 1 and prints holder PID + lock file path" {
    _load_state
    state_init
    local _lock="${INIT_UBUNTU_STATE_DIR}/.state.lock"
    _hold_state_lock "${_lock}" 10
    local _holder_pid; _holder_pid="$(cat "${_lock}.pid")"

    INIT_UBUNTU_LOCK_TIMEOUT=1 run state_record_install docker true v1
    kill "${HOLD_LOCK_PID}" 2>/dev/null || true
    wait "${HOLD_LOCK_PID}" 2>/dev/null || true

    assert_failure
    assert_output --partial "timed out"
    assert_output --partial "${_lock}"
    assert_output --partial "${_holder_pid}"

    # the write must NOT have happened
    local _p; _p="$(state_get_path)"
    [[ "$(jq -r '.installed | has("docker")' "${_p}")" == "false" ]]
}

# ── upgrade / verify recording ──────────────────────────────────────────────

@test "state_record_upgrade stamps version_provided + last_upgraded_at" {
    _load_state
    state_init
    state_record_install docker false "v0.1.0"
    state_record_upgrade docker "v0.2.0"

    local _p; _p="$(state_get_path)"
    run jq -r '.installed.docker.synced.version_provided' "${_p}"
    assert_success
    assert_output "v0.2.0"

    run jq -r '.installed.docker.synced.last_upgraded_at' "${_p}"
    assert_success
    # ISO-8601-ish: yyyy-mm-ddThh:mm:ss
    [[ "${output}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} ]]
}

@test "state_record_upgrade preserves other fields" {
    _load_state
    state_init
    state_record_install docker true "v0.1.0"
    state_record_upgrade docker "v0.2.0"

    local _p; _p="$(state_get_path)"
    run jq -r '.installed.docker.synced.manual' "${_p}"
    assert_success
    assert_output "true"

    run jq -r '.installed.docker.synced.installed_at' "${_p}"
    assert_success
    [[ -n "${output}" && "${output}" != "null" ]]
}

@test "state_record_upgrade on absent module is a no-op (no crash)" {
    _load_state
    state_init
    run state_record_upgrade nonexistent "v1"
    assert_success

    local _p; _p="$(state_get_path)"
    run jq -r '.installed.nonexistent' "${_p}"
    assert_success
    assert_output "null"
}

@test "state_record_verify stamps last_verified_at" {
    _load_state
    state_init
    state_record_install docker false "v0.1.0"
    state_record_verify docker

    local _p; _p="$(state_get_path)"
    run jq -r '.installed.docker.local.last_verified_at' "${_p}"
    assert_success
    [[ "${output}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} ]]
}

@test "state_record_verify preserves version_provided" {
    _load_state
    state_init
    state_record_install docker false "v0.1.0"
    state_record_verify docker

    local _p; _p="$(state_get_path)"
    run jq -r '.installed.docker.synced.version_provided' "${_p}"
    assert_success
    assert_output "v0.1.0"
}

@test "state_record_verify on absent module is a no-op" {
    _load_state
    state_init
    run state_record_verify nonexistent
    assert_success
}
