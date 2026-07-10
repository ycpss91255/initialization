#!/usr/bin/env bats
# test/unit/tool/copy_neovim_local_config_spec.bats — spec for the migrated
# tool/copy_neovim_local_config.sh (ADR-0029 template-first migration).
#
# The tool sources lib/tool_bootstrap.sh and shrinks to usage() + do_work().
# do_work snapshots a Neovim user/ config dir into the tool's config/ dir.
# NEOVIM_CONFIG_SRC / NEOVIM_CONFIG_DEST redirect both sides to scratch so the
# real-run and dry-run cases are observable without a real user home. The
# --help / unknown-arg / --dry-run cases exercise the outward contract.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
    export LIB_DIR REPO_ROOT

    TOOL_SH="${REPO_ROOT}/tool/copy_neovim_local_config.sh"

    # Source dir with observable content, and a scratch destination.
    SRC_DIR="${INIT_UBUNTU_TEST_SCRATCH}/nvim-user"
    DEST_DIR="${INIT_UBUNTU_TEST_SCRATCH}/nvim-dest"
    mkdir -p "${SRC_DIR}"
    printf 'return {}\n' >"${SRC_DIR}/init.lua"
    export NEOVIM_CONFIG_SRC="${SRC_DIR}"
    export NEOVIM_CONFIG_DEST="${DEST_DIR}"
}

teardown() { teardown_test_env; }

# ── 1. --help exits 0 and prints usage ───────────────────────────────────────

@test "copy_neovim_local_config: --help prints usage and exits 0" {
    run bash "${TOOL_SH}" --help
    assert_success
    assert_output --partial "Usage:"
}

@test "copy_neovim_local_config: -h is an alias for --help (exit 0)" {
    run bash "${TOOL_SH}" -h
    assert_success
    assert_output --partial "Usage:"
}

# ── 2. unknown arg exits 2 and mutates nothing ───────────────────────────────

@test "copy_neovim_local_config: unknown argument prints usage to stderr and exits 2" {
    run bash "${TOOL_SH}" --bogus
    assert_failure 2
    assert_output --partial "Usage:"
}

@test "copy_neovim_local_config: unknown arg does not create the snapshot" {
    run bash "${TOOL_SH}" --bogus
    assert_failure 2
    [[ ! -e "${DEST_DIR}" ]] || { printf 'snapshot created on usage error: %s\n' "${DEST_DIR}" >&2; return 1; }
}

# ── 3. --dry-run performs no mutation ────────────────────────────────────────

@test "copy_neovim_local_config: --dry-run reports intent and mutates nothing" {
    run bash "${TOOL_SH}" --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
    [[ ! -e "${DEST_DIR}" ]] || { printf 'dry-run created snapshot: %s\n' "${DEST_DIR}" >&2; return 1; }
}

@test "copy_neovim_local_config: -n is an alias for --dry-run (no mutation)" {
    run bash "${TOOL_SH}" -n
    assert_success
    [[ ! -e "${DEST_DIR}" ]] || return 1
}

# ── Real run + idempotency ───────────────────────────────────────────────────

@test "copy_neovim_local_config: run snapshots the source into the destination" {
    run bash "${TOOL_SH}"
    assert_success
    [[ -f "${DEST_DIR}/init.lua" ]] || { printf 'run did not create snapshot: %s\n' "${DEST_DIR}" >&2; return 1; }
}

@test "copy_neovim_local_config: re-run rotates the prior snapshot to config.bak" {
    run bash "${TOOL_SH}"
    assert_success
    run bash "${TOOL_SH}"
    assert_success
    [[ -f "${DEST_DIR}/init.lua" ]] || return 1
    [[ -d "${DEST_DIR}.bak" ]] || { printf 're-run did not rotate to .bak\n' >&2; return 1; }
}

# ── Missing source fails fast ─────────────────────────────────────────────────

@test "copy_neovim_local_config: missing source aborts (non-zero, no snapshot)" {
    export NEOVIM_CONFIG_SRC="${INIT_UBUNTU_TEST_SCRATCH}/does-not-exist"
    run bash "${TOOL_SH}"
    assert_failure
    [[ ! -e "${DEST_DIR}" ]] || return 1
}

# ── Migration guardrail: sources the shared bootstrap ────────────────────────

@test "copy_neovim_local_config: sources lib/tool_bootstrap.sh and dispatches through tool_main" {
    grep -q 'tool_bootstrap.sh' "${TOOL_SH}"
    grep -qE '^tool_main "\$@"$' "${TOOL_SH}"
}
