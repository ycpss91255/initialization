#!/usr/bin/env bats
# test/unit/state_io_spec.bats — lib/state_io.sh
#
# Covers the ADR-0018 synced-only payload and the ADR-0013 conflict
# pipeline (dry-run plan, union, remote-wins, sticky manual).

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
    # shellcheck source=../../lib/state.sh
    source "${LIB_DIR}/state.sh"
    # shellcheck source=../../lib/state_io.sh
    source "${LIB_DIR}/state_io.sh"
}

# Fake catalog membership for the conflict pipeline: one module name per
# line in the scratch fake-catalog file counts as locally defined.
registry_has() {
    grep -qx -- "$1" "${INIT_UBUNTU_TEST_SCRATCH}/fake-catalog" 2>/dev/null
}

_set_fake_catalog() {
    printf '%s\n' "$@" > "${INIT_UBUNTU_TEST_SCRATCH}/fake-catalog"
}

# ── library-guard + jq-availability branches ─────────────────────────────────

@test "executing state_io.sh directly warns that it is a library (source guard)" {
    run bash "${LIB_DIR}/state_io.sh"
    assert_success
    assert_output --partial "library"
}

@test "state_io_export errors clearly when jq is unavailable" {
    _load_state_io
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/emptybin"
    # Empty PATH hides jq from `command -v jq`; `command` is a builtin.
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/emptybin" run state_io_export \
        "${INIT_UBUNTU_TEST_SCRATCH}/out.json"
    assert_failure 1
    assert_output --partial "jq not found"
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
    assert_output --regexp '^0\.'

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

@test "state_io_export carries each module's synced section (ADR-0018)" {
    _load_state_io
    state_record_install docker true apt-managed "curl"
    local _out="${INIT_UBUNTU_TEST_SCRATCH}/payload.json"
    state_io_export "${_out}"

    run jq -r '.modules[0].name' "${_out}"
    assert_success
    assert_output "docker"
    run jq -r '.modules[0].synced.manual' "${_out}"
    assert_success
    assert_output "true"
    run jq -r '.modules[0].synced.version_provided' "${_out}"
    assert_success
    assert_output "apt-managed"
    run jq -cr '.modules[0].synced.depends_on' "${_out}"
    assert_success
    assert_output '["curl"]'
}

@test "state_io_export payload never carries local sections (AC, issue #43)" {
    _load_state_io
    state_record_install docker true apt-managed
    state_record_install neovim true v0.10.2
    # Seed machine-specific local fields that must NOT ship.
    local _p; _p="$(state_get_path)"
    jq '.installed.docker.local = {"install_target_resolved":"sudo"}
        | .installed.neovim.local = {"install_target_resolved":"user-home",
                                     "user_home_root":"/home/u/.local/lib/neovim"}' \
        "${_p}" > "${_p}.tmp" && mv "${_p}.tmp" "${_p}"

    local _out="${INIT_UBUNTU_TEST_SCRATCH}/payload.json"
    state_io_export "${_out}"

    run jq -r '[.modules[] | has("local")] | any' "${_out}"
    assert_success
    assert_output "false"
    run jq -r '[.modules[].synced | has("install_target_resolved"), has("user_home_root")] | any' "${_out}"
    assert_success
    assert_output "false"
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

@test "state_io_export rejects too many positional args" {
    _load_state_io
    state_init
    run state_io_export "${INIT_UBUNTU_TEST_SCRATCH}/a.json" "${INIT_UBUNTU_TEST_SCRATCH}/b.json"
    assert_failure 2
}

@test "state_io_export without state.json still writes a valid empty payload" {
    _load_state_io
    # No state_init: state.json absent — export must not crash.
    local _out="${INIT_UBUNTU_TEST_SCRATCH}/payload.json"
    run state_io_export "${_out}"
    assert_success
    run jq -r '.modules | length' "${_out}"
    assert_success
    assert_output "0"
}

@test "state_io_export --modules with name absent from state yields empty list" {
    _load_state_io
    state_record_install docker true v1
    local _out="${INIT_UBUNTU_TEST_SCRATCH}/payload.json"
    state_io_export "${_out}" --modules=not-recorded
    run jq -r '.modules | length' "${_out}"
    assert_success
    assert_output "0"
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

@test "state_io_export on corrupt state.json quarantines and fails (issue #41)" {
    _load_state_io
    state_init
    local _p; _p="$(state_get_path)"
    printf 'not json' > "${_p}"

    local _out="${INIT_UBUNTU_TEST_SCRATCH}/payload.json"
    run state_io_export "${_out}"
    assert_failure
    [[ ! -f "${_out}" ]]

    local _q=("${_p}".corrupt.*)
    [[ -e "${_q[0]}" ]]
    [[ ! -f "${_p}" ]]
}

# ── payload read ────────────────────────────────────────────────────────────

@test "state_io_payload_modules prints module names in payload order" {
    _load_state_io
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/in.json"
    cat > "${_payload}" <<'EOF'
{
  "version": "0.2.0",
  "source_host": "test",
  "source_user": "tester",
  "exported_at": "2026-05-14T10:00:00+00:00",
  "modules": [
    {"name": "docker", "synced": {"manual": true}},
    {"name": "fzf", "synced": {"manual": false}}
  ],
  "include_config": false
}
EOF
    run state_io_payload_modules "${_payload}"
    assert_success
    [[ "${lines[0]}" == "docker" ]]
    [[ "${lines[1]}" == "fzf" ]]
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

@test "state_io_payload_modules rejects a non-object payload (JSON array)" {
    _load_state_io
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/in.json"
    echo '[]' > "${_payload}"
    run state_io_payload_modules "${_payload}"
    assert_failure 2
    assert_output --partial "not a JSON object"
}

# ── import plan (ADR-0013 conflict pipeline) ────────────────────────────────

# Builds a payload at $1 with the given module entries (jq array body in $2).
_write_payload() {
    local _file="$1" _modules="$2"
    jq -n --argjson modules "${_modules}" '{
        version: "0.2.0",
        source_host: "machine-a",
        source_user: "tester",
        exported_at: "2026-06-07T10:00:00+00:00",
        modules: $modules,
        include_config: false
    }' > "${_file}"
}

@test "import plan: union — local-only kept, remote-only (known) installed" {
    _load_state_io
    _set_fake_catalog docker
    state_record_install eza true v0.20.0
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/in.json"
    _write_payload "${_payload}" \
        '[{"name":"docker","synced":{"manual":false,"depends_on":[],"version_provided":"v28.0.0"}}]'

    run state_io_import_plan "${_payload}"
    assert_success
    echo "${output}" | jq -e '
        (map(select(.name == "docker")) | first | .action == "install") and
        (map(select(.name == "eza"))    | first | .action == "keep")' > /dev/null
}

@test "import plan: remote-only module missing from catalog is skipped" {
    _load_state_io
    _set_fake_catalog
    state_init
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/in.json"
    _write_payload "${_payload}" \
        '[{"name":"obscure-tool","synced":{"manual":true,"version_provided":"v1"}}]'

    run state_io_import_plan "${_payload}"
    assert_success
    echo "${output}" | jq -e '.[0].action == "skip"
        and (.[0].reason | test("no local module definition"))' > /dev/null
}

@test "import plan: same version on both sides is a noop" {
    _load_state_io
    _set_fake_catalog docker
    state_record_install docker true v28.0.0
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/in.json"
    _write_payload "${_payload}" \
        '[{"name":"docker","synced":{"manual":true,"version_provided":"v28.0.0"}}]'

    run state_io_import_plan "${_payload}"
    assert_success
    echo "${output}" | jq -e '.[0].action == "noop"' > /dev/null
}

@test "import plan: version diff resolves remote-wins (upgrade action)" {
    _load_state_io
    _set_fake_catalog neovim
    state_record_install neovim true v0.10.2
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/in.json"
    _write_payload "${_payload}" \
        '[{"name":"neovim","synced":{"manual":false,"depends_on":["fnm"],"version_provided":"v0.10.5"}}]'

    run state_io_import_plan "${_payload}"
    assert_success
    echo "${output}" | jq -e '.[0].action == "upgrade"
        and .[0].local_version == "v0.10.2"
        and .[0].remote_version == "v0.10.5"
        and .[0].synced.version_provided == "v0.10.5"
        and .[0].synced.depends_on == ["fnm"]' > /dev/null
}

@test "import plan: manual sticky-to-true survives remote-wins (ADR-0013)" {
    _load_state_io
    _set_fake_catalog neovim
    # Local manual=true, remote manual=false + version diff: remote wins on
    # version/depends_on but manual must stay true (sticky, AC-42 pattern).
    state_record_install neovim true v0.10.2
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/in.json"
    _write_payload "${_payload}" \
        '[{"name":"neovim","synced":{"manual":false,"version_provided":"v0.10.5"}}]'

    run state_io_import_plan "${_payload}"
    assert_success
    echo "${output}" | jq -e '.[0].action == "upgrade"
        and .[0].synced.manual == true' > /dev/null
}

@test "import plan: remote manual=true flips local manual=false (same version)" {
    _load_state_io
    _set_fake_catalog fzf
    state_record_install fzf false v0.55
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/in.json"
    _write_payload "${_payload}" \
        '[{"name":"fzf","synced":{"manual":true,"version_provided":"v0.55"}}]'

    run state_io_import_plan "${_payload}"
    assert_success
    echo "${output}" | jq -e '.[0].action == "flag-manual"
        and .[0].synced.manual == true' > /dev/null
}

@test "import plan propagates payload validation failure (exit 2)" {
    _load_state_io
    state_init
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/in.json"
    echo '{"modules":[]}' > "${_payload}"
    run state_io_import_plan "${_payload}"
    assert_failure 2
}

@test "import plan errors on missing payload file (exit 2)" {
    _load_state_io
    state_init
    run state_io_import_plan "${INIT_UBUNTU_TEST_SCRATCH}/missing.json"
    assert_failure 2
    assert_output --partial "not found"
}

@test "import plan on corrupt local state.json fails (quarantine guard)" {
    _load_state_io
    _set_fake_catalog docker
    state_init
    local _p; _p="$(state_get_path)"
    printf 'garbage' > "${_p}"
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/in.json"
    _write_payload "${_payload}" \
        '[{"name":"docker","synced":{"manual":true,"version_provided":"v1"}}]'
    run state_io_import_plan "${_payload}"
    assert_failure
    local _q=("${_p}".corrupt.*)
    [[ -e "${_q[0]}" ]]
}

@test "import plan: both sides without version_provided compare as unknown (noop)" {
    _load_state_io
    _set_fake_catalog docker
    state_record_install docker true   # version defaults to "unknown"
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/in.json"
    _write_payload "${_payload}" \
        '[{"name":"docker","synced":{"manual":true}}]'

    run state_io_import_plan "${_payload}"
    assert_success
    echo "${output}" | jq -e '.[0].action == "noop"
        and .[0].local_version == "unknown"
        and .[0].remote_version == "unknown"' > /dev/null
}

# ── import apply ────────────────────────────────────────────────────────────

@test "import apply: union + remote-wins land in state.json" {
    _load_state_io
    _set_fake_catalog docker neovim
    state_record_install eza true v0.20.0
    state_record_install neovim true v0.10.2
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/in.json"
    _write_payload "${_payload}" '[
        {"name":"docker","synced":{"manual":true,"depends_on":[],"version_provided":"v28.0.0"}},
        {"name":"neovim","synced":{"manual":false,"depends_on":["fnm"],"version_provided":"v0.10.5"}}
    ]'

    run state_io_import_apply "${_payload}"
    assert_success

    local _p; _p="$(state_get_path)"
    # Union: local-only eza kept untouched.
    [[ "$(jq -r '.installed.eza.synced.version_provided' "${_p}")" == "v0.20.0" ]]
    # Remote-only docker recorded with remote synced.
    [[ "$(jq -r '.installed.docker.synced.version_provided' "${_p}")" == "v28.0.0" ]]
    # Remote-wins on version + depends_on; manual stays sticky-true.
    [[ "$(jq -r '.installed.neovim.synced.version_provided' "${_p}")" == "v0.10.5" ]]
    [[ "$(jq -cr '.installed.neovim.synced.depends_on' "${_p}")" == '["fnm"]' ]]
    [[ "$(jq -r '.installed.neovim.synced.manual' "${_p}")" == "true" ]]
}

@test "import apply never applies payload local sections (AC, issue #43)" {
    _load_state_io
    _set_fake_catalog docker
    state_init
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/in.json"
    # Hand-crafted hostile payload smuggling a local section.
    cat > "${_payload}" <<'EOF'
{"version":"0.2.0","modules":[
  {"name":"docker",
   "synced":{"manual":true,"version_provided":"v28.0.0"},
   "local":{"install_target_resolved":"sudo","user_home_root":"/evil"}}
]}
EOF
    run state_io_import_apply "${_payload}"
    assert_success

    local _p; _p="$(state_get_path)"
    run jq -r '.installed.docker.local | length' "${_p}"
    assert_success
    assert_output "0"
}

@test "import apply --skip excludes named modules from state writes" {
    _load_state_io
    _set_fake_catalog docker fzf
    state_init
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/in.json"
    _write_payload "${_payload}" '[
        {"name":"docker","synced":{"manual":true,"version_provided":"v28.0.0"}},
        {"name":"fzf","synced":{"manual":true,"version_provided":"v0.55"}}
    ]'

    run state_io_import_apply "${_payload}" --skip=docker
    assert_success

    local _p; _p="$(state_get_path)"
    [[ "$(jq -r '.installed | has("docker")' "${_p}")" == "false" ]]
    [[ "$(jq -r '.installed | has("fzf")' "${_p}")" == "true" ]]
}

@test "import apply: skipped catalog-unknown module is never written" {
    _load_state_io
    _set_fake_catalog
    state_init
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/in.json"
    _write_payload "${_payload}" \
        '[{"name":"obscure-tool","synced":{"manual":true,"version_provided":"v1"}}]'

    run state_io_import_apply "${_payload}"
    assert_success

    local _p; _p="$(state_get_path)"
    [[ "$(jq -r '.installed | length' "${_p}")" == "0" ]]
}

@test "import apply rejects unknown flag (exit 2)" {
    _load_state_io
    state_init
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/in.json"
    _write_payload "${_payload}" '[]'
    run state_io_import_apply "${_payload}" --bogus
    assert_failure 2
}

@test "import apply without <in-file> returns 2" {
    _load_state_io
    state_init
    run state_io_import_apply
    assert_failure 2
}

@test "import apply rejects too many positional args (exit 2)" {
    _load_state_io
    state_init
    run state_io_import_apply a.json b.json
    assert_failure 2
}

@test "import apply --plan with missing file returns 2" {
    _load_state_io
    state_init
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/in.json"
    _write_payload "${_payload}" '[]'
    run state_io_import_apply "${_payload}" "--plan=${INIT_UBUNTU_TEST_SCRATCH}/no-plan.json"
    assert_failure 2
}

@test "import apply --plan with non-array JSON returns 2" {
    _load_state_io
    state_init
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/in.json"
    _write_payload "${_payload}" '[]'
    local _plan="${INIT_UBUNTU_TEST_SCRATCH}/plan.json"
    echo '{"not":"an array"}' > "${_plan}"
    run state_io_import_apply "${_payload}" "--plan=${_plan}"
    assert_failure 2
}

@test "import apply --plan uses the pre-computed plan, not a recompute" {
    _load_state_io
    _set_fake_catalog docker
    state_init
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/in.json"
    # Payload that would NOT plan an install for docker on recompute
    # (docker absent from the payload entirely).
    _write_payload "${_payload}" '[]'
    # Pre-computed plan says install docker (the dispatcher's pre-lifecycle
    # snapshot semantics).
    local _plan="${INIT_UBUNTU_TEST_SCRATCH}/plan.json"
    cat > "${_plan}" <<'EOF'
[{"name":"docker","action":"install","local_version":null,
  "remote_version":"v28.0.0",
  "synced":{"manual":true,"version_provided":"v28.0.0"}}]
EOF
    run state_io_import_apply "${_payload}" "--plan=${_plan}"
    assert_success
    local _p; _p="$(state_get_path)"
    [[ "$(jq -r '.installed.docker.synced.version_provided' "${_p}")" == "v28.0.0" ]]
}

# ── round trip (AC-14) ──────────────────────────────────────────────────────

@test "round trip: A export -> B import apply gives consistent installed sets (AC-14)" {
    _load_state_io
    _set_fake_catalog docker neovim fzf

    # Machine A state.
    local _state_a="${INIT_UBUNTU_TEST_SCRATCH}/machine-a"
    export INIT_UBUNTU_STATE_DIR="${_state_a}"
    state_record_install docker true v28.0.0
    state_record_install neovim true v0.10.5 "fzf"
    state_record_install fzf false v0.55

    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/payload.json"
    state_io_export "${_payload}"
    local _a_synced
    _a_synced="$(jq -S '[.installed | to_entries[] | {name: .key, synced: .value.synced}] | sort_by(.name)' \
        "${_state_a}/state.json")"

    # Machine B: empty state, import with apply.
    local _state_b="${INIT_UBUNTU_TEST_SCRATCH}/machine-b"
    export INIT_UBUNTU_STATE_DIR="${_state_b}"
    run state_io_import_apply "${_payload}"
    assert_success

    local _b_synced
    _b_synced="$(jq -S '[.installed | to_entries[] | {name: .key, synced: .value.synced}] | sort_by(.name)' \
        "${_state_b}/state.json")"
    [[ "${_a_synced}" == "${_b_synced}" ]]

    # B's local sections are rebuilt locally — never copied from A.
    run jq -r '[.installed[].local | length] | add // 0' "${_state_b}/state.json"
    assert_success
    assert_output "0"
}
