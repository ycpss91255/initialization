#!/usr/bin/env bash
# tests/helpers/common.bash — shared bats test helpers
#
# Loaded by each spec via:
#   load "${BATS_TEST_DIRNAME}/../helpers/common"
#
# Provides:
#   - REPO_ROOT / LIB_DIR / MODULE_DIR / TEMPLATE_DIR path exports
#   - bats-support / bats-assert / bats-mock loaders
#   - setup_test_env / teardown_test_env that create/clean a per-test scratch
#     dir under $BATS_TEST_TMPDIR (auto-cleaned by bats)

# ── Path constants (resolved once at load time) ──────────────────────────────
COMMON_HELPER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
export COMMON_HELPER_DIR

REPO_ROOT="$(cd -- "${COMMON_HELPER_DIR}/../.." && pwd -P)"
export REPO_ROOT

export LIB_DIR="${REPO_ROOT}/lib"
export MODULE_DIR="${REPO_ROOT}/modules"
export TEMPLATE_DIR="${REPO_ROOT}/templates"
export TEST_DIR="${REPO_ROOT}/tests"

# ── Load bats-* extensions ───────────────────────────────────────────────────
# The test-tools:local image bakes these at /usr/lib/bats/{bats-support,
# bats-assert,bats-mock} (see dockerfile/Dockerfile.test-tools). Each ships
# a `load.bash` that wires up the helper functions when sourced.

_BATS_LIB="/usr/lib/bats"
if [[ -f "${_BATS_LIB}/bats-support/load.bash" ]]; then
    # shellcheck disable=SC1091  # dynamic source path ($VAR resolved at runtime) — https://www.shellcheck.net/wiki/SC1091
    load "${_BATS_LIB}/bats-support/load"
fi
if [[ -f "${_BATS_LIB}/bats-assert/load.bash" ]]; then
    # shellcheck disable=SC1091  # dynamic source path ($VAR resolved at runtime) — https://www.shellcheck.net/wiki/SC1091
    load "${_BATS_LIB}/bats-assert/load"
fi
if [[ -f "${_BATS_LIB}/bats-mock/load.bash" ]]; then
    # shellcheck disable=SC1091  # dynamic source path ($VAR resolved at runtime) — https://www.shellcheck.net/wiki/SC1091
    load "${_BATS_LIB}/bats-mock/load"
fi

# ── Scratch dir lifecycle ────────────────────────────────────────────────────

setup_test_env() {
    INIT_UBUNTU_TEST_SCRATCH="${BATS_TEST_TMPDIR}/init_ubuntu_scratch"
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}"
    export INIT_UBUNTU_TEST_SCRATCH

    INIT_UBUNTU_STATE_DIR="${INIT_UBUNTU_TEST_SCRATCH}/state"
    INIT_UBUNTU_CONFIG_DIR="${INIT_UBUNTU_TEST_SCRATCH}/config"
    mkdir -p "${INIT_UBUNTU_STATE_DIR}" "${INIT_UBUNTU_CONFIG_DIR}"
    export INIT_UBUNTU_STATE_DIR INIT_UBUNTU_CONFIG_DIR
}

teardown_test_env() {
    unset INIT_UBUNTU_TEST_SCRATCH \
          INIT_UBUNTU_STATE_DIR \
          INIT_UBUNTU_CONFIG_DIR \
          INIT_UBUNTU_LOG_FILE \
          INIT_UBUNTU_CURRENT_MODULE
}

# ── Convenience source helpers ───────────────────────────────────────────────

source_logger() {
    unset TTY_COLORS_READY
    # shellcheck disable=SC1091  # dynamic source path ($VAR resolved at runtime) — https://www.shellcheck.net/wiki/SC1091
    source "${LIB_DIR}/logger.sh"
}

source_general() {
    unset TTY_COLORS_READY
    # shellcheck disable=SC1091  # dynamic source path ($VAR resolved at runtime) — https://www.shellcheck.net/wiki/SC1091
    source "${LIB_DIR}/general.sh"
}
