#!/usr/bin/env bats
# test/unit/modules/docker_spec.bats — module/docker.module.sh

load "${BATS_TEST_DIRNAME}/../../helpers/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
}

teardown() {
    teardown_test_env
}

_load_module() {
    # shellcheck disable=SC1091
    source "${LIB_DIR}/logger.sh"
    # shellcheck disable=SC1091
    source "${LIB_DIR}/general.sh"
    # shellcheck disable=SC1091
    source "${MODULE_DIR}/docker.module.sh"
}

# ── Metadata sanity ──────────────────────────────────────────────────────────

@test "docker module declares NAME=docker" {
    _load_module
    [[ "${NAME}" == "docker" ]]
}

@test "docker module CATEGORY=recommended" {
    _load_module
    [[ "${CATEGORY}" == "recommended" ]]
}

@test "docker module declares apt-essentials as a dependency" {
    _load_module
    [[ " ${DEPENDS_ON[*]} " == *" apt-essentials "* ]]
}

@test "docker module declares SUPPORTS_USER_HOME=false" {
    _load_module
    [[ "${SUPPORTS_USER_HOME}" == "false" ]]
}

@test "docker module SUPPORTED_UBUNTU includes 22.04 24.04 26.04" {
    _load_module
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 22.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 24.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 26.04 "* ]]
}

# ── is_installed: relies on dpkg ─────────────────────────────────────────────

@test "is_installed returns nonzero when dpkg does not report docker-ce as installed" {
    _load_module
    run is_installed
    assert_failure
}

# ── Dry-run behavior ─────────────────────────────────────────────────────────

@test "install in dry-run mode does not execute (no sudo, no apt)" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "remove in dry-run mode is a no-op" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run remove
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "purge in dry-run mode is a no-op (does not touch /etc/docker etc.)" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run purge
    assert_success
    assert_output --partial "DRY-RUN"
}

# ── Idempotency hint ─────────────────────────────────────────────────────────

@test "install short-circuits when is_installed returns 0 (idempotency)" {
    _load_module
    is_installed() { return 0; }
    run install
    assert_success
    assert_output --partial "already installed"
}

# ── Recommendation logic ─────────────────────────────────────────────────────

@test "is_recommended returns nonzero when already installed" {
    _load_module
    is_installed() { return 0; }
    run is_recommended
    assert_failure
}

@test "is_recommended returns nonzero inside a container" {
    _load_module
    is_installed() { return 1; }
    systemd-detect-virt() {
        [[ "$*" == *"--container"* ]] && return 0
        return 1
    }
    export -f systemd-detect-virt
    run is_recommended
    assert_failure
}
