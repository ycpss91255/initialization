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

# ── remote tool check (PRD §16.3 step 2): exit 7 + §3.4 bootstrap ───────────

# Make the ssh stub simulate a remote where `setup_ubuntu` is missing:
# the tool-check remote command exits with the 9 sentinel.
_stub_remote_without_tool() {
    cat > "${SYNC_STUB_DIR}/ssh" <<EOF
#!/usr/bin/env bash
echo "ssh \$*" >> "${SYNC_STUB_LOG}"
for _a in "\$@"; do
    if [[ "\${_a}" == *"command -v setup_ubuntu"* ]]; then
        exit 9
    fi
done
exit 0
EOF
    chmod +x "${SYNC_STUB_DIR}/ssh"
}

@test "sync_push to a remote without setup_ubuntu exits 7" {
    _load_sync
    _stub_remote_without_tool
    state_record_install docker true
    run sync_push user@host
    assert_failure 7
}

@test "sync_push to a remote without setup_ubuntu prints the 3-line §3.4 bootstrap" {
    _load_sync
    _stub_remote_without_tool
    state_record_install docker true
    run sync_push user@host
    assert_failure 7
    assert_output --partial "sudo apt install -y git"
    assert_output --partial "git clone https://github.com/ycpss91255/initialization.git"
    assert_output --partial "cd initialization && ./setup_ubuntu_tui.sh"
}

@test "sync_push to a remote without setup_ubuntu never scp's nor imports (no auto-rsync, no remote sudo)" {
    _load_sync
    _stub_remote_without_tool
    state_record_install docker true
    run sync_push user@host
    assert_failure 7
    run grep -q "scp " "${SYNC_STUB_LOG}"
    assert_failure
    run grep -q "setup_ubuntu import" "${SYNC_STUB_LOG}"
    assert_failure
}

@test "sync_pull from a remote without setup_ubuntu exits 7 with the bootstrap" {
    _load_sync
    _stub_remote_without_tool
    run sync_pull user@host
    assert_failure 7
    assert_output --partial "git clone https://github.com/ycpss91255/initialization.git"
}

# ── tool version skew warns only (PRD §16.3 step 2) ─────────────────────────

# Make the ssh stub answer `setup_ubuntu version` with a fixed version
# (everything else still exits 0 silently).
_stub_remote_version() {
    local _ver="$1"
    cat > "${SYNC_STUB_DIR}/ssh" <<EOF
#!/usr/bin/env bash
echo "ssh \$*" >> "${SYNC_STUB_LOG}"
for _a in "\$@"; do
    if [[ "\${_a}" == *"setup_ubuntu version"* ]]; then
        echo "init_ubuntu ${_ver}"
    fi
done
exit 0
EOF
    chmod +x "${SYNC_STUB_DIR}/ssh"
}

@test "sync_push warns but proceeds when remote tool version differs" {
    _load_sync
    _stub_remote_version "9.9.9"
    INIT_UBUNTU_VERSION="0.1.0"
    state_record_install docker true
    run sync_push user@host
    assert_success
    assert_output --partial "WARN"
    assert_output --partial "9.9.9"
    assert_output --partial "pushed state"
}

@test "sync_push stays quiet when remote tool version matches" {
    _load_sync
    _stub_remote_version "0.1.0"
    INIT_UBUNTU_VERSION="0.1.0"
    state_record_install docker true
    run sync_push user@host
    assert_success
    refute_output --partial "WARN"
}
