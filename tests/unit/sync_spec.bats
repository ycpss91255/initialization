#!/usr/bin/env bats
# tests/unit/sync_spec.bats — lib/sync.sh
#
# Real SSH/scp is stubbed via a PATH override. We assert: option flags
# (StrictHostKeyChecking=yes, BatchMode=yes), target string, remote
# commands. Real ssh end-to-end testing lives in integration (Phase 9).

load "${BATS_TEST_DIRNAME}/../helpers/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false

    SYNC_STUB_DIR="${INIT_UBUNTU_TEST_SCRATCH}/stubs"
    SYNC_STUB_LOG="${INIT_UBUNTU_TEST_SCRATCH}/stub-calls.log"
    mkdir -p "${SYNC_STUB_DIR}"
    : > "${SYNC_STUB_LOG}"
    cat > "${SYNC_STUB_DIR}/ssh" <<EOF
#!/usr/bin/env bash
echo "ssh \$*" >> "${SYNC_STUB_LOG}"
exit 0
EOF
    cat > "${SYNC_STUB_DIR}/scp" <<EOF
#!/usr/bin/env bash
echo "scp \$*" >> "${SYNC_STUB_LOG}"
exit 0
EOF
    chmod +x "${SYNC_STUB_DIR}/ssh" "${SYNC_STUB_DIR}/scp"
    export PATH="${SYNC_STUB_DIR}:${PATH}"
}

teardown() {
    teardown_test_env
}

_load_sync() {
    # shellcheck disable=SC1091  # dynamic source path ($VAR resolved at runtime) — https://www.shellcheck.net/wiki/SC1091
    source "${LIB_DIR}/logger.sh"
    # shellcheck disable=SC1091  # dynamic source path ($VAR resolved at runtime) — https://www.shellcheck.net/wiki/SC1091
    source "${LIB_DIR}/general.sh"
    # shellcheck disable=SC1091  # dynamic source path ($VAR resolved at runtime) — https://www.shellcheck.net/wiki/SC1091
    source "${LIB_DIR}/state.sh"
    # shellcheck disable=SC1091  # dynamic source path ($VAR resolved at runtime) — https://www.shellcheck.net/wiki/SC1091
    source "${LIB_DIR}/state_io.sh"
    # shellcheck disable=SC1091  # dynamic source path ($VAR resolved at runtime) — https://www.shellcheck.net/wiki/SC1091
    source "${LIB_DIR}/sync.sh"
}

# ── arg validation ──────────────────────────────────────────────────────────

@test "sync_push without <user@host> returns exit 2" {
    _load_sync
    run sync_push
    assert_failure 2
    assert_output --partial "user@host"
}

@test "sync_pull without <user@host> returns exit 2" {
    _load_sync
    run sync_pull
    assert_failure 2
    assert_output --partial "user@host"
}

@test "sync_push --bogus flag returns exit 2" {
    _load_sync
    run sync_push user@host --bogus
    assert_failure 2
}

# ── dry-run paths do NOT call ssh/scp ──────────────────────────────────────

@test "sync_push --dry-run does not invoke ssh / scp" {
    _load_sync
    run sync_push user@host --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
    [[ ! -s "${SYNC_STUB_LOG}" ]]
}

@test "sync_pull --dry-run does not invoke ssh / scp" {
    _load_sync
    run sync_pull user@host --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
    [[ ! -s "${SYNC_STUB_LOG}" ]]
}

# ── real flow uses StrictHostKeyChecking=yes ────────────────────────────────

@test "sync_push uses StrictHostKeyChecking=yes + BatchMode=yes" {
    _load_sync
    state_record_install docker true
    run sync_push user@host
    assert_success
    grep -q "StrictHostKeyChecking=yes" "${SYNC_STUB_LOG}"
    grep -q "BatchMode=yes" "${SYNC_STUB_LOG}"
}

@test "sync_push invokes scp with the target host" {
    _load_sync
    state_record_install docker true
    run sync_push user@host
    assert_success
    grep -q "user@host:/tmp/init_ubuntu_sync.json" "${SYNC_STUB_LOG}"
}

@test "sync_push runs 'setup_ubuntu import' on the remote" {
    _load_sync
    state_record_install docker true
    run sync_push user@host
    assert_success
    grep -q "setup_ubuntu import" "${SYNC_STUB_LOG}"
}

@test "sync_push --modules=<csv> succeeds (filter forwarded to state_io_export)" {
    _load_sync
    state_record_install docker true
    state_record_install neovim true
    state_record_install fzf false
    run sync_push user@host --modules=docker
    assert_success
}
