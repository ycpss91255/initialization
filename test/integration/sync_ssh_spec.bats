#!/usr/bin/env bats
# test/integration/sync_ssh_spec.bats — AC-15 dual-container sync E2E
#
# PRD §16 + AC-15 (Q52: ship gate runs the REAL ssh flow between two
# containers). Sender = this ci container; receiver = the `sync-receiver`
# compose service (profile sync-e2e, see compose.yaml) running sshd and
# provisioned by test/integration/sync/receiver-entry.sh.
#
# Real ssh + scp, StrictHostKeyChecking=yes against the receiver's pinned
# host key, key-only auth — exactly the §16.4 posture sync enforces.
#
# Gated on SYNC_E2E=1: `just -f justfile.ci test-integration` (script/ci/ci.sh
# --integration-only) starts the receiver and sets it; every other workflow
# that sweeps test/integration/ (full `just -f justfile.ci test`, `coverage`) skips
# this file instead of failing on a receiver that was never started.

load "${BATS_TEST_DIRNAME}/../helper/common"

TARGET="syncuser@sync-receiver"

_require_e2e() {
    [[ "${SYNC_E2E:-0}" == "1" ]] \
        || skip "SYNC_E2E != 1 — run via 'just -f justfile.ci test-integration'"
}

_remote() {
    ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=5 \
        "${TARGET}" "$@"
}

# Drop receiver-side artifacts so each test asserts from a known-clean
# slate (tests share one receiver container per suite run). Paths are
# home-relative: ssh remote commands start in syncuser's home dir.
_reset_receiver() {
    _remote 'rm -f .local/state/init_ubuntu/state.json .local/share/e2e-probe-installed'
}

setup_file() {
    # The two tests below share one receiver; remote state assertions are
    # only meaningful when they do not interleave.
    export BATS_NO_PARALLELIZE_WITHIN_FILE=true

    [[ "${SYNC_E2E:-0}" == "1" ]] || return 0

    # openssh client is baked into test-tools:local; the apk fallback only
    # covers a stale pre-#67 image.
    command -v ssh >/dev/null 2>&1 || apk add --no-cache openssh-client

    # receiver-entry.sh touches `ready` right before exec'ing sshd.
    local _e2e="${REPO_ROOT}/.tmp/sync-e2e"
    local _i
    for _i in $(seq 1 60); do
        [[ -f "${_e2e}/ready" ]] && break
        sleep 1
    done
    if [[ ! -f "${_e2e}/ready" ]]; then
        echo "# sync-receiver never became ready (${_e2e}/ready missing)" >&3
        return 1
    fi

    # Pin the receiver's host key + wire the throwaway client key. ssh
    # resolves ~ from passwd (not $HOME), so write the real home's .ssh —
    # this container is disposable (compose run --rm).
    local _home
    _home="$(getent passwd "$(id -un)" | cut -d: -f6)"
    mkdir -p "${_home}/.ssh"
    chmod 700 "${_home}/.ssh"
    awk '{print "sync-receiver", $1, $2}' \
        "${_e2e}/ssh_host_ed25519_key.pub" > "${_home}/.ssh/known_hosts"
    cat > "${_home}/.ssh/config" <<EOF
Host sync-receiver
    User syncuser
    IdentityFile ${_e2e}/id_ed25519
    IdentitiesOnly yes
    CheckHostIP no
EOF
    chmod 600 "${_home}/.ssh/config"

    # `ready` precedes sshd's listen by a beat; wait for a real key login.
    for _i in $(seq 1 30); do
        if ssh -o BatchMode=yes -o StrictHostKeyChecking=yes \
               -o ConnectTimeout=2 "${TARGET}" true 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    echo "# could not ssh to ${TARGET} after 30s" >&3
    return 1
}

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
    _require_e2e
    _reset_receiver

    # Seed the SENDER's state.json so export ships the fixture module the
    # receiver knows from its user-local catalog (receiver-entry.sh).
    (
        # shellcheck source=../../lib/logger.sh
        source "${LIB_DIR}/logger.sh"
        # shellcheck source=../../lib/general.sh
        source "${LIB_DIR}/general.sh"
        # shellcheck source=../../lib/state.sh
        source "${LIB_DIR}/state.sh"
        state_init
        state_record_install e2e-probe true 1.0.0
    )
}

teardown() {
    teardown_test_env
}

@test "sync without --apply streams the remote IMPORT DIFF back and changes nothing (ADR-0013)" {
    run bash "${REPO_ROOT}/setup_ubuntu.sh" sync "${TARGET}"
    assert_success
    # The diff is printed by the REMOTE import and must arrive over the
    # ssh channel (PRD §16.3 step 6 — logs stream back to the sender).
    assert_output --partial "IMPORT DIFF"
    assert_output --partial "e2e-probe"
    assert_output --partial "dry-run"

    # Default is dry-run on the receiving side: no state entry, no install.
    run _remote 'jq -e ".installed[\"e2e-probe\"]" .local/state/init_ubuntu/state.json'
    assert_failure
    run _remote 'test -f .local/share/e2e-probe-installed'
    assert_failure
}

@test "sync --apply: receiver state.json contains the pushed module via its install pipeline (AC-15)" {
    run bash "${REPO_ROOT}/setup_ubuntu.sh" sync "${TARGET}" --apply
    assert_success
    assert_output --partial "pushed state"

    # AC-15: the remote state.json records the module, manual stays sticky.
    run _remote 'jq -er ".installed[\"e2e-probe\"].synced.manual" .local/state/init_ubuntu/state.json'
    assert_success
    assert_output "true"
    run _remote 'jq -er ".installed[\"e2e-probe\"].synced.version_provided" .local/state/init_ubuntu/state.json'
    assert_success
    assert_output "1.0.0"

    # The import went through the real install pipeline (PRD §16.3 step 5):
    # the fixture module's install() left its marker.
    run _remote 'test -f .local/share/e2e-probe-installed'
    assert_success

    # The transferred payload is cleaned up on the remote side.
    run _remote 'test -f /tmp/init_ubuntu_sync.json'
    assert_failure
}
