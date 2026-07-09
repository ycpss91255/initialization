#!/usr/bin/env bats
# test/unit/script/set_address_pool_spec.bats
#
# Tests for `script/docker-tools/set-address-pool.sh` (issue #270): the
# standalone config tool that pins Docker's default-address-pools in
# daemon.json to 172.16.0.0/12 sliced into /24 blocks, avoiding the silent
# overflow into 192.168.0.0/16 under heavy docker-compose churn.
#
# Strategy: point DOCKER_DAEMON_JSON_PATH at a scratch daemon.json under
# $BATS_TEST_TMPDIR and assert on the merged file + emitted output. dockerd is
# absent from the test-tools image, so the validate branch is skipped on the
# happy path; the validation-failure path is exercised with a PATH-shimmed
# `dockerd` stub.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    SCRIPT="${REPO_ROOT}/script/docker-tools/set-address-pool.sh"
    DAEMON_JSON="${BATS_TEST_TMPDIR}/etc/docker/daemon.json"
    export DOCKER_DAEMON_JSON_PATH="${DAEMON_JSON}"
}

teardown() {
    teardown_test_env
}

@test "refuses to run when not root" {
    if ! command -v su >/dev/null 2>&1 || ! id nobody >/dev/null 2>&1; then
        skip "need su + a nobody account to exercise the non-root refusal path"
    fi
    run su nobody -s /bin/bash -c \
        "DOCKER_DAEMON_JSON_PATH='${DAEMON_JSON}' bash '${SCRIPT}'"
    assert_failure
    assert_output --partial "must run as root"
}

@test "pins the default pool when daemon.json does not exist yet" {
    [ ! -e "${DAEMON_JSON}" ]
    run "${SCRIPT}"
    assert_success
    assert_equal "$(jq -r '.["default-address-pools"][0].base' "${DAEMON_JSON}")" "172.16.0.0/12"
    assert_equal "$(jq -r '.["default-address-pools"][0].size' "${DAEMON_JSON}")" "24"
}

@test "backs up the existing daemon.json before writing" {
    mkdir -p "$(dirname "${DAEMON_JSON}")"
    printf '{"debug": true}\n' > "${DAEMON_JSON}"
    run "${SCRIPT}"
    assert_success
    assert_output --partial "Backed up existing config to"
    local _baks=( "${DAEMON_JSON}".bak.* )
    local _bak="${_baks[0]}"
    [ -f "${_bak}" ]
    assert_equal "$(jq -r '.debug' "${_bak}")" "true"
    # backup must NOT contain the new key — it is a snapshot of the original.
    assert_equal "$(jq -r '.["default-address-pools"]' "${_bak}")" "null"
}

@test "merges into existing config, preserving other keys" {
    mkdir -p "$(dirname "${DAEMON_JSON}")"
    printf '{"runtimes": {"nvidia": {"path": "nvidia-container-runtime"}}}\n' > "${DAEMON_JSON}"
    run "${SCRIPT}"
    assert_success
    assert_equal "$(jq -r '.runtimes.nvidia.path' "${DAEMON_JSON}")" "nvidia-container-runtime"
    assert_equal "$(jq -r '.["default-address-pools"][0].base' "${DAEMON_JSON}")" "172.16.0.0/12"
}

@test "accepts an explicit base and size" {
    run "${SCRIPT}" "10.200.0.0/16" "26"
    assert_success
    assert_equal "$(jq -r '.["default-address-pools"][0].base' "${DAEMON_JSON}")" "10.200.0.0/16"
    assert_equal "$(jq -r '.["default-address-pools"][0].size' "${DAEMON_JSON}")" "26"
}

@test "size is written as a JSON number, not a string" {
    run "${SCRIPT}"
    assert_success
    assert_equal "$(jq -r '.["default-address-pools"][0].size | type' "${DAEMON_JSON}")" "number"
}

@test "does not restart docker; prints restart guidance" {
    run "${SCRIPT}"
    assert_success
    assert_output --partial "Not restarted automatically"
    assert_output --partial "docker ps -a"
    assert_output --partial "systemctl restart docker"
}

@test "cleans up the scratch .tmp file on success" {
    run "${SCRIPT}"
    assert_success
    [ ! -e "${DAEMON_JSON}.tmp" ]
}

@test "leaves the original untouched and fails when dockerd --validate rejects the config" {
    mkdir -p "$(dirname "${DAEMON_JSON}")"
    printf '{"debug": true}\n' > "${DAEMON_JSON}"

    local _stub_dir="${BATS_TEST_TMPDIR}/stub-bin"
    mkdir -p "${_stub_dir}"
    cat > "${_stub_dir}/dockerd" <<'STUB'
#!/usr/bin/env bash
echo "unable to configure the Docker daemon: invalid pool" >&2
exit 1
STUB
    chmod +x "${_stub_dir}/dockerd"

    PATH="${_stub_dir}:${PATH}" run "${SCRIPT}"
    assert_failure
    assert_output --partial "failed dockerd --validate"
    # Original content must survive untouched (no new key written).
    assert_equal "$(jq -r '.["default-address-pools"]' "${DAEMON_JSON}")" "null"
    assert_equal "$(jq -r '.debug' "${DAEMON_JSON}")" "true"
    [ ! -e "${DAEMON_JSON}.tmp" ]
}
