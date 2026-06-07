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

# Dep-chain fixtures for the ADR-0010 depends_on snapshot specs (#93):
# top -> mid -> leaf, plus half-broken (depends on fails + leaf).
_write_dep_chain_fixtures() {
    local _m
    for _m in leaf mid top half-broken; do
        local _deps='()'
        case "${_m}" in
            mid)         _deps='("leaf")' ;;
            top)         _deps='("mid")' ;;
            half-broken) _deps='("fails" "leaf")' ;;
        esac
        cat > "${FAKE_MODULE_DIR}/${_m}.module.sh" <<EOF
NAME="${_m}"
CATEGORY="optional"
TAGS=()
SUPPORTED_UBUNTU=()
SUPPORTED_PLATFORMS=()
DEPENDS_ON=${_deps}
CONFLICTS_WITH=()

install() { return 0; }
remove()  { return 0; }
purge()   { return 0; }
EOF
    done
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

# Engine with state.json + resolver wired in — the surface the ADR-0010
# depends_on snapshot specs (#93) exercise.
_load_engine_with_state() {
    # shellcheck source=../../lib/state.sh
    source "${LIB_DIR}/state.sh"
    # shellcheck source=../../lib/resolver.sh
    source "${LIB_DIR}/resolver.sh"
    _write_dep_chain_fixtures
    _load_engine
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

# ── Session-end log retention wiring (PRD §10.2, AC-33) ─────────────────────

@test "session end prunes the log directory to <= 100 jsonl files (AC-33)" {
    _load_engine
    local _logdir="${INIT_UBUNTU_TEST_SCRATCH}/logs"
    mkdir -p "${_logdir}"
    local _i
    for (( _i = 1; _i <= 110; _i++ )); do
        printf '{}\n' > "${_logdir}/$(printf 'old-%03d' "${_i}").jsonl"
        touch -d "1 day ago" "${_logdir}/$(printf 'old-%03d' "${_i}").jsonl"
    done
    INIT_UBUNTU_LOG_FILE="${_logdir}/current.jsonl" runner_install echo-mod >/dev/null 2>&1 || true
    [[ "$(find "${_logdir}" -maxdepth 1 -type f -name '*.jsonl' | wc -l)" -eq 100 ]]
    [[ -e "${_logdir}/current.jsonl" ]]
    grep -q '"body":"log_pruned"' "${_logdir}/current.jsonl"
}

# ── ADR-0010 depends_on snapshot (issue #93) ─────────────────────────────────
#
# The runner records the resolver's transitive dep snapshot (forward-dep,
# ADR-0010) for every module installed in the session — not the metadata
# DEPENDS_ON as-is. --no-deps installs record [].

@test "install records the resolved transitive depends_on snapshot (#93)" {
    _load_engine_with_state
    INIT_UBUNTU_REQUESTED_MODULES=" top " runner_install leaf mid top
    run jq -c '.installed.top.synced.depends_on' "$(state_get_path)"
    assert_success
    assert_output '["leaf","mid"]'
}

@test "install records correct depends_on on the dep's own entry too (#93)" {
    _load_engine_with_state
    INIT_UBUNTU_REQUESTED_MODULES=" top " runner_install leaf mid top
    run jq -c '[.installed.mid.synced.depends_on, .installed.leaf.synced.depends_on]' \
        "$(state_get_path)"
    assert_success
    assert_output '[["leaf"],[]]'
}

@test "install --no-deps records depends_on [] (ADR-0010, #93)" {
    _load_engine_with_state
    INIT_UBUNTU_NO_DEPS=true INIT_UBUNTU_REQUESTED_MODULES=" top " \
        runner_install top
    run jq -c '.installed.top.synced.depends_on' "$(state_get_path)"
    assert_success
    assert_output '[]'
}

@test "depends_on snapshot excludes deps that failed this session (ADR-0010, #93)" {
    _load_engine_with_state
    INIT_UBUNTU_REQUESTED_MODULES=" half-broken " \
        runner_install leaf fails half-broken || true
    run jq -c '.installed."half-broken".synced.depends_on' "$(state_get_path)"
    assert_success
    assert_output '["leaf"]'
}

@test "depends_on snapshot resets between runner sessions (#93)" {
    _load_engine_with_state
    INIT_UBUNTU_REQUESTED_MODULES=" mid " runner_install leaf mid
    # Second session installs only top: leaf/mid succeeded in the PREVIOUS
    # session, not this one, so they must not leak into top's snapshot.
    INIT_UBUNTU_REQUESTED_MODULES=" top " runner_install top
    run jq -c '.installed.top.synced.depends_on' "$(state_get_path)"
    assert_success
    assert_output '[]'
}
