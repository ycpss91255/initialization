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

# ── logger_prune_logs retention (PRD §10.2, AC-33) ──────────────────────────
#
# Session-end retention: keep the newest 100 `.jsonl` files and none older
# than 30 days; when either limit is exceeded delete from the oldest.

# Create <count> .jsonl fixtures in <dir>, oldest first (1-minute mtime steps
# backwards from <base-age-min> minutes ago), named log-001.jsonl ... so the
# lowest-numbered file is always the oldest.
_make_jsonl_fixtures() {
    local _dir="$1" _count="$2" _base_age_min="${3:-60}"
    local _i _age
    mkdir -p "${_dir}"
    for (( _i = 1; _i <= _count; _i++ )); do
        _age=$(( _base_age_min + _count - _i ))
        printf '{}\n' > "${_dir}/$(printf 'log-%03d' "${_i}").jsonl"
        touch -d "${_age} minutes ago" "${_dir}/$(printf 'log-%03d' "${_i}").jsonl"
    done
}

_count_jsonl() {
    find "$1" -maxdepth 1 -type f -name '*.jsonl' | wc -l
}

_load_logger() {
    # shellcheck source=../../lib/logger.sh
    source "${LIB_DIR}/logger.sh"
}

@test "logger_prune_logs deletes oldest files beyond the 100-file cap" {
    local _dir="${INIT_UBUNTU_TEST_SCRATCH}/logs"
    _make_jsonl_fixtures "${_dir}" 105
    _load_logger
    run logger_prune_logs "${_dir}"
    assert_success
    [[ "$(_count_jsonl "${_dir}")" -eq 100 ]]
    # the 5 oldest are gone, the newest survive
    [[ ! -e "${_dir}/log-001.jsonl" ]]
    [[ ! -e "${_dir}/log-005.jsonl" ]]
    [[ -e "${_dir}/log-006.jsonl" ]]
    [[ -e "${_dir}/log-105.jsonl" ]]
}

@test "logger_prune_logs keeps exactly 100 files untouched (count boundary)" {
    local _dir="${INIT_UBUNTU_TEST_SCRATCH}/logs"
    _make_jsonl_fixtures "${_dir}" 100
    _load_logger
    run logger_prune_logs "${_dir}"
    assert_success
    [[ "$(_count_jsonl "${_dir}")" -eq 100 ]]
    [[ -e "${_dir}/log-001.jsonl" ]]
}

@test "logger_prune_logs deletes .jsonl older than 30 days" {
    local _dir="${INIT_UBUNTU_TEST_SCRATCH}/logs"
    mkdir -p "${_dir}"
    printf '{}\n' > "${_dir}/ancient.jsonl"
    touch -d "31 days ago" "${_dir}/ancient.jsonl"
    printf '{}\n' > "${_dir}/recent.jsonl"
    touch -d "1 day ago" "${_dir}/recent.jsonl"
    _load_logger
    run logger_prune_logs "${_dir}"
    assert_success
    [[ ! -e "${_dir}/ancient.jsonl" ]]
    [[ -e "${_dir}/recent.jsonl" ]]
}

@test "logger_prune_logs keeps a file exactly 30 days old (age boundary)" {
    local _dir="${INIT_UBUNTU_TEST_SCRATCH}/logs"
    mkdir -p "${_dir}"
    printf '{}\n' > "${_dir}/boundary.jsonl"
    touch -d "30 days ago" "${_dir}/boundary.jsonl"
    _load_logger
    run logger_prune_logs "${_dir}"
    assert_success
    [[ -e "${_dir}/boundary.jsonl" ]]
}

@test "logger_prune_logs is a no-op on an empty directory" {
    local _dir="${INIT_UBUNTU_TEST_SCRATCH}/logs"
    mkdir -p "${_dir}"
    _load_logger
    run logger_prune_logs "${_dir}"
    assert_success
    [[ -d "${_dir}" ]]
}

@test "logger_prune_logs is a no-op when the directory does not exist" {
    _load_logger
    run logger_prune_logs "${INIT_UBUNTU_TEST_SCRATCH}/no-such-dir"
    assert_success
}

@test "logger_prune_logs leaves non-jsonl files alone" {
    local _dir="${INIT_UBUNTU_TEST_SCRATCH}/logs"
    mkdir -p "${_dir}"
    printf 'keep me\n' > "${_dir}/notes.txt"
    touch -d "90 days ago" "${_dir}/notes.txt"
    _load_logger
    run logger_prune_logs "${_dir}"
    assert_success
    [[ -e "${_dir}/notes.txt" ]]
}

@test "logger_prune_logs emits log_pruned OTel event with deleted count" {
    local _dir="${INIT_UBUNTU_TEST_SCRATCH}/logs"
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/events.jsonl"
    _make_jsonl_fixtures "${_dir}" 3 "$(( 31 * 24 * 60 ))"
    bash -c "export INIT_UBUNTU_LOG_FILE='${_log}'; source '${LIB_DIR}/logger.sh' && logger_prune_logs '${_dir}'"
    run jq -e '.severity_text == "INFO" and .body == "log_pruned" and .attributes."service.name" == "engine" and .attributes.deleted_count == 3' "${_log}"
    assert_success
}

@test "logger_prune_logs emits no event when nothing was deleted" {
    local _dir="${INIT_UBUNTU_TEST_SCRATCH}/logs"
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/events.jsonl"
    _make_jsonl_fixtures "${_dir}" 2
    bash -c "export INIT_UBUNTU_LOG_FILE='${_log}'; source '${LIB_DIR}/logger.sh' && logger_prune_logs '${_dir}'"
    [[ ! -e "${_log}" ]]
}

@test "logger_prune_logs defaults to dirname of INIT_UBUNTU_LOG_FILE" {
    local _dir="${INIT_UBUNTU_TEST_SCRATCH}/logs"
    _make_jsonl_fixtures "${_dir}" 105
    # active log file exists before pruning, as in a real session
    printf '{}\n' > "${_dir}/current.jsonl"
    bash -c "export INIT_UBUNTU_LOG_FILE='${_dir}/current.jsonl'; source '${LIB_DIR}/logger.sh' && logger_prune_logs"
    [[ "$(_count_jsonl "${_dir}")" -eq 100 ]]
}

@test "logger_prune_logs never deletes the active INIT_UBUNTU_LOG_FILE" {
    local _dir="${INIT_UBUNTU_TEST_SCRATCH}/logs"
    _make_jsonl_fixtures "${_dir}" 104
    # active file is the newest (just written), must survive the count cap
    printf '{}\n' > "${_dir}/current.jsonl"
    bash -c "export INIT_UBUNTU_LOG_FILE='${_dir}/current.jsonl'; source '${LIB_DIR}/logger.sh' && logger_prune_logs"
    [[ -e "${_dir}/current.jsonl" ]]
    [[ "$(_count_jsonl "${_dir}")" -eq 100 ]]
}
