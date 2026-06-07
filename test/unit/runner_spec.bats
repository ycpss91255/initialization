#!/usr/bin/env bats
# test/unit/runner_spec.bats — lib/runner.sh

bats_require_minimum_version 1.5.0

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false

    FAKE_MODULE_DIR="${INIT_UBUNTU_TEST_SCRATCH}/module"
    mkdir -p "${FAKE_MODULE_DIR}"

    cat > "${FAKE_MODULE_DIR}/echo-mod.module.sh" <<'EOF'
NAME="echo-mod"
CATEGORY="optional"
TAGS=()
SUPPORTED_UBUNTU=()
SUPPORTED_PLATFORMS=()
DEPENDS_ON=()
CONFLICTS_WITH=()

install() { echo "INSTALL-RAN" >&2; return 0; }
remove()  { echo "REMOVE-RAN" >&2;  return 0; }
purge()   { echo "PURGE-RAN" >&2;   return 0; }
upgrade() { echo "UPGRADE-RAN" >&2; return 0; }
verify()  { echo "VERIFY-RAN" >&2;  return 0; }
doctor()  { echo "DOCTOR-RAN" >&2;  return 0; }
EOF

    cat > "${FAKE_MODULE_DIR}/fails.module.sh" <<'EOF'
NAME="fails"
CATEGORY="optional"
TAGS=()
SUPPORTED_UBUNTU=()
SUPPORTED_PLATFORMS=()
DEPENDS_ON=()
CONFLICTS_WITH=()

install() { echo "BOOM" >&2; return 1; }
remove()  { return 0; }
purge()   { return 0; }
EOF
}

teardown() {
    teardown_test_env
}

_load_engine() {
    # shellcheck source=../../lib/logger.sh
    source "${LIB_DIR}/logger.sh"
    # shellcheck source=../../lib/general.sh
    source "${LIB_DIR}/general.sh"
    # shellcheck source=../../lib/registry.sh
    source "${LIB_DIR}/registry.sh"
    # shellcheck source=../../lib/runner.sh
    source "${LIB_DIR}/runner.sh"
    registry_load_all "${FAKE_MODULE_DIR}"
}

@test "runner_install runs install() of the named module" {
    _load_engine
    run runner_install echo-mod
    assert_success
    assert_output --partial "INSTALL-RAN"
}

@test "runner_remove runs remove() of the named module" {
    _load_engine
    run runner_remove echo-mod
    assert_success
    assert_output --partial "REMOVE-RAN"
}

@test "runner_purge runs purge() of the named module" {
    _load_engine
    run runner_purge echo-mod
    assert_success
    assert_output --partial "PURGE-RAN"
}

@test "runner_install on empty list is a no-op" {
    _load_engine
    run runner_install
    assert_success
    assert_output --partial "No modules"
}

@test "runner_install of unknown module fails the batch (exit 6)" {
    _load_engine
    run runner_install nonexistent
    assert_failure 6
}

@test "runner_install where one module fails returns 6 but continues others" {
    _load_engine
    run runner_install fails echo-mod
    assert_failure 6
    assert_output --partial "INSTALL-RAN"
    assert_output --partial "BOOM"
}

@test "INIT_UBUNTU_DRY_RUN=true is forwarded into module sub-shell" {
    _load_engine

    cat > "${FAKE_MODULE_DIR}/observer.module.sh" <<'EOF'
NAME="observer"
CATEGORY="optional"
TAGS=()
SUPPORTED_UBUNTU=()
SUPPORTED_PLATFORMS=()
DEPENDS_ON=()
CONFLICTS_WITH=()

install() {
    echo "OBSERVED-DRY-RUN=${INIT_UBUNTU_DRY_RUN:-unset}" >&2
}
remove() { return 0; }
purge()  { return 0; }
EOF
    registry_load_all "${FAKE_MODULE_DIR}"

    INIT_UBUNTU_DRY_RUN=true run runner_install observer
    assert_success
    assert_output --partial "OBSERVED-DRY-RUN=true"
}

@test "runner emits JSONL events to INIT_UBUNTU_LOG_FILE" {
    _load_engine
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/run.jsonl"
    INIT_UBUNTU_LOG_FILE="${_log}" runner_install echo-mod >/dev/null 2>&1 || true

    [[ -f "${_log}" ]]
    grep -q '"body":"session_start"' "${_log}"
    grep -q '"body":"install_start"' "${_log}"
    grep -q '"body":"install_done"' "${_log}"
    grep -q '"body":"session_end"' "${_log}"
}

@test "runner emits no legacy ts / level / module / event field names" {
    _load_engine
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/run.jsonl"
    INIT_UBUNTU_LOG_FILE="${_log}" runner_install echo-mod >/dev/null 2>&1 || true

    run ! grep -q '"ts":' "${_log}"
    run ! grep -q '"level":' "${_log}"
    run ! grep -q '"module":' "${_log}"
    run ! grep -q '"event":' "${_log}"
}

@test "runner shares one session-level trace_id across all JSONL events" {
    _load_engine
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/run.jsonl"
    INIT_UBUNTU_LOG_FILE="${_log}" runner_install echo-mod >/dev/null 2>&1 || true

    run jq -rs '[.[].trace_id] | unique | (length == 1) and (.[0] | length > 0)' "${_log}"
    assert_success
    assert_output "true"
}

@test "runner assigns a phase_module span_id to module lifecycle events" {
    _load_engine
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/run.jsonl"
    INIT_UBUNTU_LOG_FILE="${_log}" runner_install echo-mod >/dev/null 2>&1 || true

    run jq -cs '[.[] | select(.body == "install_start" or .body == "install_done") | .span_id] | unique' "${_log}"
    assert_success
    assert_output --regexp '^\["install_echo-mod_[0-9]{3}"\]$'
}

@test "runner emits session_start / session_end with span_id null (engine level)" {
    _load_engine
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/run.jsonl"
    INIT_UBUNTU_LOG_FILE="${_log}" runner_install echo-mod >/dev/null 2>&1 || true

    run jq -es '[.[] | select(.body == "session_start" or .body == "session_end")] | (length == 2) and all(.span_id == null) and all(.attributes."service.name" == "engine")' "${_log}"
    assert_success
}

@test "runner session_start carries an environment snapshot" {
    _load_engine
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/run.jsonl"
    INIT_UBUNTU_LOG_FILE="${_log}" INIT_UBUNTU_FORM_FACTOR="container" \
        runner_install echo-mod >/dev/null 2>&1 || true

    run jq -es '[.[] | select(.body == "session_start")][0] | (.attributes.form_factor == "container") and (.attributes | has("os") and has("arch") and has("gpu")) and (.attributes.arch | length > 0)' "${_log}"
    assert_success
}

@test "runner session_end carries exit_code and ok/skipped/failed stats" {
    _load_engine
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/run.jsonl"
    INIT_UBUNTU_LOG_FILE="${_log}" runner_install echo-mod fails >/dev/null 2>&1 || true

    run jq -es '[.[] | select(.body == "session_end")][0] | (.attributes.exit_code == 6) and (.attributes.ok == 1) and (.attributes.failed == 1) and (.attributes.skipped == 0)' "${_log}"
    assert_success
}

@test "runner propagates trace_id and span_id into module sub-shell log_event calls" {
    _load_engine

    cat > "${FAKE_MODULE_DIR}/tracer.module.sh" <<'EOF'
NAME="tracer"
CATEGORY="optional"
TAGS=()
SUPPORTED_UBUNTU=()
SUPPORTED_PLATFORMS=()
DEPENDS_ON=()
CONFLICTS_WITH=()

install() { log_event info "tracer" cmd_exec cmd=true exit=0; return 0; }
remove()  { return 0; }
purge()   { return 0; }
EOF
    registry_load_all "${FAKE_MODULE_DIR}"

    local _log="${INIT_UBUNTU_TEST_SCRATCH}/run.jsonl"
    INIT_UBUNTU_LOG_FILE="${_log}" runner_install tracer >/dev/null 2>&1 || true

    # cmd_exec from inside the module sub-shell carries the same trace_id as
    # session_start and the same span_id as the surrounding install_* events.
    run jq -rs '([.[].trace_id] | unique | length == 1) and ([.[] | select(.body == "cmd_exec" or .body == "install_start") | .span_id] | unique | length == 1)' "${_log}"
    assert_success
    assert_output "true"
}

# ── upgrade / verify / doctor phase ─────────────────────────────────────────

@test "runner_upgrade runs upgrade() of the named module" {
    _load_engine
    run runner_upgrade echo-mod
    assert_success
    assert_output --partial "UPGRADE-RAN"
}

@test "runner_verify runs verify() of the named module" {
    _load_engine
    run runner_verify echo-mod
    assert_success
    assert_output --partial "VERIFY-RAN"
}

@test "runner_doctor runs doctor() of the named module" {
    _load_engine
    run runner_doctor echo-mod
    assert_success
    assert_output --partial "DOCTOR-RAN"
}

@test "runner_upgrade on empty list is a no-op" {
    _load_engine
    run runner_upgrade
    assert_success
    assert_output --partial "No modules"
}

@test "runner_verify on empty list is a no-op" {
    _load_engine
    run runner_verify
    assert_success
    assert_output --partial "No modules"
}
