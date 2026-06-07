#!/usr/bin/env bats
# test/unit/logger_spec.bats — exercise lib/logger.sh

load "${BATS_TEST_DIRNAME}/../helper/common"

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

# ── log_event JSONL output (OTel-aligned schema, ADR-0006 / PRD §10.2) ──────

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

@test "log_event JSONL contains timestamp / severity_text / body / trace_id / span_id / attributes" {
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/events.jsonl"
    bash -c "export INIT_UBUNTU_LOG_FILE='${_log}'; source '${LIB_DIR}/logger.sh' && log_event info docker install_start"
    run cat "${_log}"
    assert_success
    assert_output --regexp '"timestamp":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z"'
    assert_output --partial '"severity_text":"INFO"'
    assert_output --partial '"body":"install_start"'
    assert_output --partial '"trace_id":"'
    assert_output --partial '"span_id":'
    assert_output --partial '"attributes":{"service.name":"docker"'
}

@test "log_event emits no legacy ts / level / module / event field names" {
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/events.jsonl"
    bash -c "export INIT_UBUNTU_LOG_FILE='${_log}'; source '${LIB_DIR}/logger.sh' && log_event info docker install_start manual=true"
    run cat "${_log}"
    assert_success
    refute_output --partial '"ts":'
    refute_output --partial '"level":'
    refute_output --partial '"module":'
    refute_output --partial '"event":'
}

@test "log_event emits every line as valid JSON (jq parses)" {
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/events.jsonl"
    bash -c "export INIT_UBUNTU_LOG_FILE='${_log}'; source '${LIB_DIR}/logger.sh' && log_event info docker install_start version=v1 && log_event error '' session_end exit_code=6"
    run jq -e . "${_log}"
    assert_success
}

@test "log_event uppercases severity_text per OTel spec" {
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/events.jsonl"
    bash -c "export INIT_UBUNTU_LOG_FILE='${_log}'; source '${LIB_DIR}/logger.sh' && log_event warn docker install_failed"
    run cat "${_log}"
    assert_success
    assert_output --partial '"severity_text":"WARN"'
    refute_output --partial '"severity_text":"warn"'
}

@test "log_event nests key=value args under attributes" {
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/events.jsonl"
    bash -c "export INIT_UBUNTU_LOG_FILE='${_log}'; source '${LIB_DIR}/logger.sh' && log_event info docker cmd_exec cmd=ls exit=0"
    run jq -e '.attributes."service.name" == "docker" and .attributes.cmd == "ls" and .attributes.exit == 0' "${_log}"
    assert_success
}

@test "log_event treats numeric attribute values as JSON numbers (no quotes)" {
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/events.jsonl"
    bash -c "export INIT_UBUNTU_LOG_FILE='${_log}'; source '${LIB_DIR}/logger.sh' && log_event info docker cmd_exec exit=0 duration_ms=1430"
    run cat "${_log}"
    assert_success
    assert_output --partial '"exit":0'
    assert_output --partial '"duration_ms":1430'
    refute_output --partial '"exit":"0"'
}

@test "log_event treats true/false attribute values as JSON booleans" {
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/events.jsonl"
    bash -c "export INIT_UBUNTU_LOG_FILE='${_log}'; source '${LIB_DIR}/logger.sh' && log_event info docker install_start dry_run=false success=true"
    run cat "${_log}"
    assert_success
    assert_output --partial '"dry_run":false'
    assert_output --partial '"success":true'
    refute_output --partial '"dry_run":"false"'
}

@test "log_event maps empty module arg to service.name engine (PRD §10.2)" {
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/events.jsonl"
    bash -c "export INIT_UBUNTU_LOG_FILE='${_log}'; source '${LIB_DIR}/logger.sh' && log_event info '' session_start"
    run jq -e '.attributes."service.name" == "engine"' "${_log}"
    assert_success
}

@test "log_event emits trace_id from INIT_UBUNTU_TRACE_ID env" {
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/events.jsonl"
    bash -c "export INIT_UBUNTU_LOG_FILE='${_log}' INIT_UBUNTU_TRACE_ID='trace-fixture-42'; source '${LIB_DIR}/logger.sh' && log_event info docker install_start"
    run jq -e '.trace_id == "trace-fixture-42"' "${_log}"
    assert_success
}

@test "log_event self-generates a non-empty trace_id when env unset" {
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/events.jsonl"
    bash -c "unset INIT_UBUNTU_TRACE_ID; export INIT_UBUNTU_LOG_FILE='${_log}'; source '${LIB_DIR}/logger.sh' && log_event info docker install_start && log_event info docker install_done"
    run jq -rs '[.[].trace_id] | (length == 2) and (.[0] | length > 0) and (.[0] == .[1])' "${_log}"
    assert_success
    assert_output "true"
}

@test "log_event emits span_id from INIT_UBUNTU_SPAN_ID env" {
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/events.jsonl"
    bash -c "export INIT_UBUNTU_LOG_FILE='${_log}' INIT_UBUNTU_SPAN_ID='install_docker_001'; source '${LIB_DIR}/logger.sh' && log_event info docker install_start"
    run jq -e '.span_id == "install_docker_001"' "${_log}"
    assert_success
}

@test "log_event emits span_id null when INIT_UBUNTU_SPAN_ID unset" {
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/events.jsonl"
    bash -c "unset INIT_UBUNTU_SPAN_ID; export INIT_UBUNTU_LOG_FILE='${_log}'; source '${LIB_DIR}/logger.sh' && log_event info '' session_start"
    run jq -e '.span_id == null' "${_log}"
    assert_success
}

@test "log_event escapes JSON-breaking characters in attribute string values" {
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/events.jsonl"
    bash -c "export INIT_UBUNTU_LOG_FILE='${_log}'; source '${LIB_DIR}/logger.sh' && log_event info docker cmd_exec 'cmd=echo \"hi\"'"
    run cat "${_log}"
    assert_success
    # The escaped backslash-quote sequence should appear
    assert_output --partial '\"hi\"'
    run jq -e '.attributes.cmd == "echo \"hi\""' "${_log}"
    assert_success
}

@test "log_event appends across multiple calls (does not overwrite)" {
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/events.jsonl"
    bash -c "export INIT_UBUNTU_LOG_FILE='${_log}'; source '${LIB_DIR}/logger.sh' && log_event info docker install_start && log_event info docker install_done"
    [[ "$(wc -l < "${_log}")" -eq 2 ]]
}

@test "log_info mirror to JSONL uses the OTel schema (body=message)" {
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/events.jsonl"
    bash -c "export INIT_UBUNTU_LOG_FILE='${_log}' INIT_UBUNTU_CURRENT_MODULE='docker'; source '${LIB_DIR}/logger.sh' && log_info 'hello from tty'" >/dev/null
    run jq -e '.severity_text == "INFO" and .body == "message" and .attributes."service.name" == "docker" and (.attributes.msg | contains("hello from tty"))' "${_log}"
    assert_success
}
