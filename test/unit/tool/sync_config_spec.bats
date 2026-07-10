#!/usr/bin/env bats
# test/unit/tool/sync_config_spec.bats — spec for the migrated
# tool/sync_config.sh (ADR-0029 template-first migration).
#
# The tool sources lib/tool_bootstrap.sh for the shared always-act strict mode
# and dry-run-aware helpers, but keeps its OWN status/pull/push dispatcher
# (tool_main's flat parser cannot accept bare subcommands). It still honours the
# outward contract: --help -> 0, unknown -> 2, --dry-run writes nothing.
#
# SYNC_CONFIG_SRC (repo side) / SYNC_CONFIG_MANIFEST / HOME (local side) /
# BACKUP_DIR all redirect into scratch so push/pull are observable and host-safe.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
    export LIB_DIR REPO_ROOT

    TOOL_SH="${REPO_ROOT}/tool/sync_config.sh"

    SRC="${INIT_UBUNTU_TEST_SCRATCH}/repo"
    LOCAL_HOME="${INIT_UBUNTU_TEST_SCRATCH}/home"
    MANIFEST="${INIT_UBUNTU_TEST_SCRATCH}/manifest"
    mkdir -p "${SRC}" "${LOCAL_HOME}"

    # One managed pair: repo file present, local target under HOME.
    printf 'repo-version\n' >"${SRC}/ssh_config"
    printf 'ssh_config\t.ssh/config\n' >"${MANIFEST}"

    export SYNC_CONFIG_SRC="${SRC}"
    export SYNC_CONFIG_MANIFEST="${MANIFEST}"
    export HOME="${LOCAL_HOME}"
    export BACKUP_DIR="${INIT_UBUNTU_TEST_SCRATCH}/backup"
    LOCAL_TARGET="${LOCAL_HOME}/.ssh/config"
}

teardown() { teardown_test_env; }

# ── 1. --help exits 0 and prints usage ───────────────────────────────────────

@test "sync_config: --help prints usage and exits 0" {
    run bash "${TOOL_SH}" --help
    assert_success
    assert_output --partial "Usage:"
}

@test "sync_config: -h is an alias for --help (exit 0)" {
    run bash "${TOOL_SH}" -h
    assert_success
    assert_output --partial "Usage:"
}

# ── 2. unknown arg / missing command exits 2 ─────────────────────────────────

@test "sync_config: unknown argument prints usage to stderr and exits 2" {
    run bash "${TOOL_SH}" --bogus
    assert_failure 2
    assert_output --partial "Usage:"
}

@test "sync_config: missing command exits 2" {
    run bash "${TOOL_SH}"
    assert_failure 2
}

# ── 3. --dry-run performs no mutation ────────────────────────────────────────

@test "sync_config: push --dry-run reports intent and writes no local file" {
    run bash "${TOOL_SH}" push --dry-run
    assert_success
    assert_output --partial "dry-run"
    [[ ! -e "${LOCAL_TARGET}" ]] || { printf '--dry-run created local target: %s\n' "${LOCAL_TARGET}" >&2; return 1; }
}

# ── status classifies the drift ──────────────────────────────────────────────

@test "sync_config: status reports the local-missing pair and exits 0" {
    run bash "${TOOL_SH}" status
    assert_success
    assert_output --partial "local-missing"
}

# ── Real push applies the repo version to the local target ───────────────────

@test "sync_config: push copies the repo version to the local target" {
    run bash "${TOOL_SH}" push
    assert_success
    [[ -f "${LOCAL_TARGET}" ]] || { printf 'push did not create local target\n' >&2; return 1; }
    grep -q 'repo-version' "${LOCAL_TARGET}"
}

@test "sync_config: re-push is a no-op once identical" {
    run bash "${TOOL_SH}" push
    assert_success
    run bash "${TOOL_SH}" push --dry-run
    assert_success
    refute_output --partial "would write"
}

# ── Migration guardrail: sources the shared bootstrap ────────────────────────

@test "sync_config: sources lib/tool_bootstrap.sh" {
    grep -q 'tool_bootstrap.sh' "${TOOL_SH}"
}
