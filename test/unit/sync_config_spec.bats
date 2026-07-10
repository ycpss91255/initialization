#!/usr/bin/env bats
# test/unit/sync_config_spec.bats — unit tests for tool/sync_config.sh
#
# Issue #308: bidirectional config sync between the repo (module/config/) and
# the local deploy targets under $HOME. The tool exposes three commands —
# status/--check, pull/--pull, push/--push — plus --dry-run and a
# $BACKUP_DIR-backed pre-write snapshot. A single managed manifest defines the
# repo-path <-> local-path pairs so the mapping is not hard-coded across the
# setup_*.sh scripts.
#
# These specs drive the tool against an isolated fake repo-config source
# (SYNC_CONFIG_SRC), a fake target base ($HOME), and a custom manifest
# (SYNC_CONFIG_MANIFEST) so nothing touches the real host (ADR-0004: no host
# writes; Docker-only).

load "${BATS_TEST_DIRNAME}/../helper/common"

SYNC_TOOL="${REPO_ROOT}/tool/sync_config.sh"

setup() {
    setup_test_env
    export LOG_LEVEL="INFO"
    export LOG_COLOR="false"

    # Isolated repo-side source and local-side target.
    SRC="${INIT_UBUNTU_TEST_SCRATCH}/src"
    TARGET_HOME="${INIT_UBUNTU_TEST_SCRATCH}/home"
    MANIFEST="${INIT_UBUNTU_TEST_SCRATCH}/manifest"
    BK="${INIT_UBUNTU_TEST_SCRATCH}/backup"
    mkdir -p "${SRC}" "${TARGET_HOME}"

    # One footgun-prone pair per manifest line: <repo-relpath> <local-relpath>.
    printf '%s\t%s\n' "git_config" ".gitconfig" > "${MANIFEST}"

    export SYNC_CONFIG_SRC="${SRC}"
    export SYNC_CONFIG_MANIFEST="${MANIFEST}"
    export HOME="${TARGET_HOME}"
    export BACKUP_DIR="${BK}"
}

teardown() {
    teardown_test_env
}

# Write repo-side and local-side files with a controllable mtime skew so the
# newer/older classification is deterministic.
_seed_repo() { mkdir -p "$(dirname "${SRC}/$1")"; printf '%s' "$2" > "${SRC}/$1"; }
_seed_local() { mkdir -p "$(dirname "${HOME}/$1")"; printf '%s' "$2" > "${HOME}/$1"; }

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "sync_config.sh --help prints usage and exits 0" {
    run bash "${SYNC_TOOL}" --help
    assert_success
    assert_output --partial "status"
    assert_output --partial "pull"
    assert_output --partial "push"
}

@test "unknown command exits non-zero" {
    run bash "${SYNC_TOOL}" frobnicate
    assert_failure
}

# ── status / --check ─────────────────────────────────────────────────────────

@test "status reports identical when repo and local match" {
    _seed_repo "git_config" "same"
    _seed_local ".gitconfig" "same"
    run bash "${SYNC_TOOL}" status
    assert_success
    assert_output --partial "identical"
    assert_output --partial ".gitconfig"
}

@test "--check is an alias for status" {
    _seed_repo "git_config" "same"
    _seed_local ".gitconfig" "same"
    run bash "${SYNC_TOOL}" --check
    assert_success
    assert_output --partial "identical"
}

@test "status reports local-newer when local edited after repo" {
    _seed_repo "git_config" "repo"
    _seed_local ".gitconfig" "local-edit"
    touch -d "2020-01-01" "${SRC}/git_config"
    touch -d "2021-01-01" "${HOME}/.gitconfig"
    run bash "${SYNC_TOOL}" status
    assert_success
    assert_output --partial "local-newer"
}

@test "status reports repo-newer when repo edited after local" {
    _seed_repo "git_config" "repo-edit"
    _seed_local ".gitconfig" "local"
    touch -d "2021-01-01" "${SRC}/git_config"
    touch -d "2020-01-01" "${HOME}/.gitconfig"
    run bash "${SYNC_TOOL}" status
    assert_success
    assert_output --partial "repo-newer"
}

@test "status reports local-missing when target absent" {
    _seed_repo "git_config" "repo"
    run bash "${SYNC_TOOL}" status
    assert_success
    assert_output --partial "local-missing"
}

@test "status reports repo-missing when repo absent" {
    _seed_local ".gitconfig" "local"
    run bash "${SYNC_TOOL}" status
    assert_success
    assert_output --partial "repo-missing"
}

# ── push (repo -> local) ─────────────────────────────────────────────────────

@test "push applies repo version to the local target" {
    _seed_repo "git_config" "repo-content"
    run bash "${SYNC_TOOL}" push
    assert_success
    [ -f "${HOME}/.gitconfig" ]
    run cat "${HOME}/.gitconfig"
    assert_output "repo-content"
}

@test "push --dry-run does not modify the local target" {
    _seed_repo "git_config" "repo-content"
    _seed_local ".gitconfig" "old-local"
    run bash "${SYNC_TOOL}" push --dry-run
    assert_success
    run cat "${HOME}/.gitconfig"
    assert_output "old-local"
}

@test "push backs up an existing local target before overwriting" {
    _seed_repo "git_config" "repo-content"
    _seed_local ".gitconfig" "old-local"
    run bash "${SYNC_TOOL}" push
    assert_success
    # Backed-up copy of the pre-write local file must exist under BACKUP_DIR.
    run bash -c "grep -rl 'old-local' '${BK}'"
    assert_success
}

@test "push is a no-op when already identical (no backup churn)" {
    _seed_repo "git_config" "same"
    _seed_local ".gitconfig" "same"
    run bash "${SYNC_TOOL}" push
    assert_success
    [ ! -d "${BK}" ] || [ -z "$(ls -A "${BK}" 2>/dev/null)" ]
}

# ── pull (local -> repo) ─────────────────────────────────────────────────────

@test "pull applies local version back into the repo" {
    _seed_repo "git_config" "repo-old"
    _seed_local ".gitconfig" "local-new"
    run bash "${SYNC_TOOL}" pull
    assert_success
    run cat "${SRC}/git_config"
    assert_output "local-new"
}

@test "pull --dry-run does not modify the repo file" {
    _seed_repo "git_config" "repo-old"
    _seed_local ".gitconfig" "local-new"
    run bash "${SYNC_TOOL}" pull --dry-run
    assert_success
    run cat "${SRC}/git_config"
    assert_output "repo-old"
}

# ── manifest ─────────────────────────────────────────────────────────────────

@test "honors a custom multi-entry manifest" {
    printf '%s\t%s\n' "git_config" ".gitconfig" > "${MANIFEST}"
    printf '%s\t%s\n' "ssh_config" ".ssh/config" >> "${MANIFEST}"
    _seed_repo "git_config" "g"
    _seed_repo "ssh_config" "s"
    run bash "${SYNC_TOOL}" push
    assert_success
    [ -f "${HOME}/.gitconfig" ]
    [ -f "${HOME}/.ssh/config" ]
}

@test "manifest comments and blank lines are ignored" {
    {
        printf '# a comment\n'
        printf '\n'
        printf '%s\t%s\n' "git_config" ".gitconfig"
    } > "${MANIFEST}"
    _seed_repo "git_config" "ok"
    run bash "${SYNC_TOOL}" status
    assert_success
    assert_output --partial ".gitconfig"
}
