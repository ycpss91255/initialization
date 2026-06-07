#!/usr/bin/env bats
# test/unit/sync_spec.bats — lib/sync.sh
#
# Real SSH/scp is stubbed via a PATH override. We assert: option flags
# (StrictHostKeyChecking=yes, BatchMode=yes), target string, remote
# commands. Real ssh end-to-end testing lives in integration (Phase 9).

load "${BATS_TEST_DIRNAME}/../helper/common"

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
    # shellcheck source=../../lib/logger.sh
    source "${LIB_DIR}/logger.sh"
    # shellcheck source=../../lib/general.sh
    source "${LIB_DIR}/general.sh"
    # shellcheck source=../../lib/state.sh
    source "${LIB_DIR}/state.sh"
    # shellcheck source=../../lib/state_io.sh
    source "${LIB_DIR}/state_io.sh"
    # shellcheck source=../../lib/sync.sh
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

@test "sync_push without --apply leaves the remote import a dry-run (ADR-0013)" {
    _load_sync
    state_record_install docker true
    run sync_push user@host
    assert_success
    run grep -q -- "--apply" "${SYNC_STUB_LOG}"
    assert_failure
}

@test "sync_push --apply forwards --apply to the remote import" {
    _load_sync
    state_record_install docker true
    run sync_push user@host --apply
    assert_success
    grep -q "setup_ubuntu import /tmp/init_ubuntu_sync.json --apply" "${SYNC_STUB_LOG}"
}

@test "sync_push --modules=<csv> succeeds (filter forwarded to state_io_export)" {
    _load_sync
    state_record_install docker true
    state_record_install neovim true
    state_record_install fzf false
    run sync_push user@host --modules=docker
    assert_success
}

# ── more arg validation ─────────────────────────────────────────────────────

@test "sync_pull --bogus flag returns exit 2" {
    _load_sync
    run sync_pull user@host --bogus
    assert_failure 2
}

@test "sync_push with two targets returns exit 2" {
    _load_sync
    run sync_push user@host other@host
    assert_failure 2
    assert_output --partial "one <user@host>"
}

@test "sync_pull with two targets returns exit 2" {
    _load_sync
    run sync_pull user@host other@host
    assert_failure 2
    assert_output --partial "one <user@host>"
}

@test "sync_push --dry-run --modules prints the filtered module list" {
    _load_sync
    run sync_push user@host --dry-run --modules=docker,neovim
    assert_success
    assert_output --partial "filtered modules: docker,neovim"
    [[ ! -s "${SYNC_STUB_LOG}" ]]
}

@test "sync_push without lib/state_io.sh loaded fails with exit 1" {
    run bash -c 'source "${LIB_DIR}/logger.sh"; source "${LIB_DIR}/sync.sh";
        sync_push user@host'
    assert_failure 1
    assert_output --partial "state_io"
}

# ── connection / transfer failure paths ─────────────────────────────────────

@test "sync_push maps a failed ssh connection test to exit 7 with the ssh-key hint" {
    _load_sync
    state_record_install docker true
    cat > "${SYNC_STUB_DIR}/ssh" <<EOF
#!/usr/bin/env bash
echo "ssh \$*" >> "${SYNC_STUB_LOG}"
exit 255
EOF
    chmod +x "${SYNC_STUB_DIR}/ssh"
    run sync_push user@host
    assert_failure 7
    assert_output --partial "cannot ssh to user@host"
    assert_output --partial "ssh-key copy"
}

@test "sync_push maps an scp upload failure to exit 7" {
    _load_sync
    state_record_install docker true
    cat > "${SYNC_STUB_DIR}/scp" <<EOF
#!/usr/bin/env bash
echo "scp \$*" >> "${SYNC_STUB_LOG}"
exit 1
EOF
    chmod +x "${SYNC_STUB_DIR}/scp"
    run sync_push user@host
    assert_failure 7
    assert_output --partial "scp upload failed"
}

@test "sync_push maps a remote import failure to exit 7" {
    _load_sync
    state_record_install docker true
    cat > "${SYNC_STUB_DIR}/ssh" <<EOF
#!/usr/bin/env bash
echo "ssh \$*" >> "${SYNC_STUB_LOG}"
case "\$*" in *"setup_ubuntu import"*) exit 1 ;; esac
exit 0
EOF
    chmod +x "${SYNC_STUB_DIR}/ssh"
    run sync_push user@host
    assert_failure 7
    assert_output --partial "remote import failed"
}

@test "sync_push cleans up the remote payload after a successful import" {
    _load_sync
    state_record_install docker true
    run sync_push user@host
    assert_success
    grep -q "rm -f /tmp/init_ubuntu_sync.json" "${SYNC_STUB_LOG}"
    assert_output --partial "pushed state to user@host OK"
}

# ── pull flow ───────────────────────────────────────────────────────────────

@test "sync_pull exports remotely, downloads, and prints the local file path" {
    _load_sync
    run sync_pull user@host
    assert_success
    grep -q "setup_ubuntu export /tmp/init_ubuntu_sync.json" "${SYNC_STUB_LOG}"
    grep -q "user@host:/tmp/init_ubuntu_sync.json" "${SYNC_STUB_LOG}"
    grep -q "rm -f /tmp/init_ubuntu_sync.json" "${SYNC_STUB_LOG}"
    [[ "${output}" =~ /tmp/init_ubuntu_sync\..+\.json ]]
}

@test "sync_pull maps a remote export failure to exit 7" {
    _load_sync
    cat > "${SYNC_STUB_DIR}/ssh" <<EOF
#!/usr/bin/env bash
echo "ssh \$*" >> "${SYNC_STUB_LOG}"
case "\$*" in *"setup_ubuntu export"*) exit 1 ;; esac
exit 0
EOF
    chmod +x "${SYNC_STUB_DIR}/ssh"
    run sync_pull user@host
    assert_failure 7
    assert_output --partial "remote export failed"
}

@test "sync_pull maps an scp download failure to exit 7" {
    _load_sync
    cat > "${SYNC_STUB_DIR}/scp" <<EOF
#!/usr/bin/env bash
echo "scp \$*" >> "${SYNC_STUB_LOG}"
exit 1
EOF
    chmod +x "${SYNC_STUB_DIR}/scp"
    run sync_pull user@host
    assert_failure 7
    assert_output --partial "scp download failed"
}
