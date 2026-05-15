#!/usr/bin/env bats
# tests/unit/general_spec.bats — smoke + targeted unit tests for lib/general.sh
#
# batch A scope: confirm general.sh sources cleanly and the key helper
# functions are defined. Full behavior tests for sudo / apt_pkg_manager /
# get_github_pkg_latest_version land in Phase 7 (module migration), when
# we also split out lib/detect.sh / lib/platform.sh / lib/install_target.sh.

load "${BATS_TEST_DIRNAME}/../helpers/common"

setup() {
    setup_test_env
    export LOG_LEVEL="INFO"
    export LOG_COLOR="false"
}

teardown() {
    teardown_test_env
}

# ── Smoke: source without crashing ───────────────────────────────────────────

@test "lib/general.sh sources without error" {
    run bash -c "source '${LIB_DIR}/general.sh'"
    assert_success
}

@test "lib/general.sh transitively sources lib/logger.sh (TTY_COLORS_READY set)" {
    run bash -c "source '${LIB_DIR}/general.sh' && echo \"loaded=\${TTY_COLORS_READY}\""
    assert_success
    assert_output --partial "loaded=true"
}

# ── Function existence checks ────────────────────────────────────────────────

@test "exec_cmd is defined" {
    run bash -c "source '${LIB_DIR}/general.sh' && declare -F exec_cmd"
    assert_success
    assert_output --partial "exec_cmd"
}

@test "have_sudo_access is defined" {
    run bash -c "source '${LIB_DIR}/general.sh' && declare -F have_sudo_access"
    assert_success
    assert_output --partial "have_sudo_access"
}

@test "backup_file is defined" {
    run bash -c "source '${LIB_DIR}/general.sh' && declare -F backup_file"
    assert_success
    assert_output --partial "backup_file"
}

@test "create_temp_file is defined" {
    run bash -c "source '${LIB_DIR}/general.sh' && declare -F create_temp_file"
    assert_success
    assert_output --partial "create_temp_file"
}

@test "check_pkg_status is defined" {
    run bash -c "source '${LIB_DIR}/general.sh' && declare -F check_pkg_status"
    assert_success
    assert_output --partial "check_pkg_status"
}

@test "setup_apt_mirror is defined" {
    run bash -c "source '${LIB_DIR}/general.sh' && declare -F setup_apt_mirror"
    assert_success
    assert_output --partial "setup_apt_mirror"
}

@test "apt_pkg_manager is defined" {
    run bash -c "source '${LIB_DIR}/general.sh' && declare -F apt_pkg_manager"
    assert_success
    assert_output --partial "apt_pkg_manager"
}

@test "get_github_pkg_latest_version is defined" {
    run bash -c "source '${LIB_DIR}/general.sh' && declare -F get_github_pkg_latest_version"
    assert_success
    assert_output --partial "get_github_pkg_latest_version"
}

@test "environment detection helpers are defined (check_in_WSL, check_in_docker, check_in_mac)" {
    run bash -c "source '${LIB_DIR}/general.sh' && declare -F check_in_WSL check_in_docker check_in_mac"
    assert_success
    assert_output --partial "check_in_WSL"
    assert_output --partial "check_in_docker"
    assert_output --partial "check_in_mac"
}

# ── Targeted behavior: exec_cmd echoes the rendered command ──────────────────

@test "exec_cmd with EXEC_CMD_NO_PRINT=true does not echo command preamble" {
    run bash -c "export EXEC_CMD_NO_PRINT=true; source '${LIB_DIR}/general.sh' && exec_cmd echo hello"
    assert_success
    assert_output --partial "hello"
}

# ── Targeted behavior: check_in_docker runs without crashing ─────────────────
# (Inside the test-tools:local container, /.dockerenv exists, so the function
#  exports IN_DOCKER=true. We verify it doesn't crash; exact value depends on
#  cgroup detection which we don't pin here.)

@test "check_in_docker runs without error inside container" {
    run bash -c "source '${LIB_DIR}/general.sh' && check_in_docker"
    assert_success
}
