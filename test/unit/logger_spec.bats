#!/usr/bin/env bats
# test/unit/logger_spec.bats — exercise lib/logger.sh

load "${BATS_TEST_DIRNAME}/../helpers/common"

setup() {
    setup_test_env
    export LOG_LEVEL="INFO"
    export LOG_COLOR="false"
}

teardown() {
    teardown_test_env
}

# ── Basic logging behavior ───────────────────────────────────────────────────

@test "log_info prints to stdout with [INFO] tag" {
    run bash -c "source '${LIB_DIR}/logger.sh' && log_info 'hello'"
    assert_success
    assert_output --partial "[INFO]"
    assert_output --partial "hello"
}

@test "log_warn prints to stderr with [WARN] tag" {
    run bash -c "source '${LIB_DIR}/logger.sh' && log_warn 'careful'"
    assert_success
    assert_output --partial "[WARN]"
    assert_output --partial "careful"
}

@test "log_error prints to stderr with [ERROR] tag" {
    run bash -c "source '${LIB_DIR}/logger.sh' && log_error 'boom'"
    assert_success
    assert_output --partial "[ERROR]"
    assert_output --partial "boom"
}

@test "log_fatal exits 1 with [FATAL] tag" {
    run bash -c "source '${LIB_DIR}/logger.sh' && log_fatal 'die'"
    assert_failure 1
    assert_output --partial "[FATAL]"
    assert_output --partial "die"
}

# ── LOG_LEVEL filtering ──────────────────────────────────────────────────────

@test "LOG_LEVEL=WARN suppresses INFO and DEBUG" {
    run bash -c "export LOG_LEVEL=WARN LOG_COLOR=false; source '${LIB_DIR}/logger.sh' && log_debug 'd' && log_info 'i' && log_warn 'w'"
    assert_success
    refute_output --partial "[INFO]"
    refute_output --partial "[DEBUG]"
    assert_output --partial "[WARN]"
}

@test "LOG_LEVEL=DEBUG prints DEBUG messages" {
    run bash -c "export LOG_LEVEL=DEBUG LOG_COLOR=false; source '${LIB_DIR}/logger.sh' && log_debug 'd'"
    assert_success
    assert_output --partial "[DEBUG]"
    assert_output --partial "d"
}

# ── LOG_COLOR control ────────────────────────────────────────────────────────

@test "LOG_COLOR=false produces no ANSI escapes" {
    run bash -c "export LOG_COLOR=false; source '${LIB_DIR}/logger.sh' && log_info 'plain'"
    assert_success
    refute_output --regexp $'\x1b\\['
}

# ── log_event JSONL output ───────────────────────────────────────────────────

@test "log_event is no-op when INIT_UBUNTU_LOG_FILE unset" {
    run bash -c "unset INIT_UBUNTU_LOG_FILE; source '${LIB_DIR}/logger.sh' && log_event info docker install_start version=v1"
    assert_success
    assert_output ""
}

@test "log_event writes one JSONL line per call when INIT_UBUNTU_LOG_FILE set" {
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/events.jsonl"
    run bash -c "export INIT_UBUNTU_LOG_FILE='${_log}'; source '${LIB_DIR}/logger.sh' && log_event info docker install_start"
    assert_success
    [[ -f "${_log}" ]]
    [[ "$(wc -l < "${_log}")" -eq 1 ]]
}

@test "log_event JSONL contains ts / level / module / event fields" {
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/events.jsonl"
    bash -c "export INIT_UBUNTU_LOG_FILE='${_log}'; source '${LIB_DIR}/logger.sh' && log_event info docker install_start"
    run cat "${_log}"
    assert_success
    assert_output --regexp '"ts":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}'
    assert_output --partial '"level":"info"'
    assert_output --partial '"module":"docker"'
    assert_output --partial '"event":"install_start"'
}

@test "log_event treats numeric values as JSON numbers (no quotes)" {
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/events.jsonl"
    bash -c "export INIT_UBUNTU_LOG_FILE='${_log}'; source '${LIB_DIR}/logger.sh' && log_event info docker cmd_exec exit=0 duration_ms=1430"
    run cat "${_log}"
    assert_success
    assert_output --partial '"exit":0'
    assert_output --partial '"duration_ms":1430'
    refute_output --partial '"exit":"0"'
}

@test "log_event treats true/false as JSON booleans" {
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/events.jsonl"
    bash -c "export INIT_UBUNTU_LOG_FILE='${_log}'; source '${LIB_DIR}/logger.sh' && log_event info docker install_start dry_run=false success=true"
    run cat "${_log}"
    assert_success
    assert_output --partial '"dry_run":false'
    assert_output --partial '"success":true'
    refute_output --partial '"dry_run":"false"'
}

@test "log_event emits empty module as null (not empty string)" {
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/events.jsonl"
    bash -c "export INIT_UBUNTU_LOG_FILE='${_log}'; source '${LIB_DIR}/logger.sh' && log_event info '' session_start"
    run cat "${_log}"
    assert_success
    assert_output --partial '"module":null'
}

@test "log_event escapes JSON-breaking characters in string values" {
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/events.jsonl"
    bash -c "export INIT_UBUNTU_LOG_FILE='${_log}'; source '${LIB_DIR}/logger.sh' && log_event info docker cmd_exec 'cmd=echo \"hi\"'"
    run cat "${_log}"
    assert_success
    # The escaped backslash-quote sequence should appear
    assert_output --partial '\"hi\"'
}

@test "log_event appends across multiple calls (does not overwrite)" {
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/events.jsonl"
    bash -c "export INIT_UBUNTU_LOG_FILE='${_log}'; source '${LIB_DIR}/logger.sh' && log_event info docker install_start && log_event info docker install_done"
    [[ "$(wc -l < "${_log}")" -eq 2 ]]
}
