#!/usr/bin/env bats
# test/unit/tool/setup_wayland_spec.bats — spec for the migrated
# tool/setup_wayland.sh (ADR-0029 template-first migration).
#
# The tool sources lib/tool_bootstrap.sh and shrinks to usage() + do_work().
# do_work configures GRUB (NVIDIA only), GDM, and the AccountsService session —
# all root-owned system files. WAYLAND_GRUB_FILE / WAYLAND_GDM_FILE /
# WAYLAND_ACCOUNTS_DIR redirect every path into scratch so the outward contract
# (--help / unknown-arg / --dry-run) is exercised without touching the host and
# without needing sudo (sudo is only required for a real run).

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
    export LIB_DIR REPO_ROOT

    TOOL_SH="${REPO_ROOT}/tool/setup_wayland.sh"

    # Redirect every system path into scratch; leave them absent so --dry-run
    # touches nothing and the guarded reads take their skip branches.
    export WAYLAND_GRUB_FILE="${INIT_UBUNTU_TEST_SCRATCH}/grub"
    export WAYLAND_GDM_FILE="${INIT_UBUNTU_TEST_SCRATCH}/custom.conf"
    export WAYLAND_ACCOUNTS_DIR="${INIT_UBUNTU_TEST_SCRATCH}/accounts"
}

teardown() { teardown_test_env; }

# ── 1. --help exits 0 and prints usage ───────────────────────────────────────

@test "setup_wayland: --help prints usage and exits 0" {
    run bash "${TOOL_SH}" --help
    assert_success
    assert_output --partial "Usage:"
}

@test "setup_wayland: -h is an alias for --help (exit 0)" {
    run bash "${TOOL_SH}" -h
    assert_success
    assert_output --partial "Usage:"
}

# ── 2. unknown arg exits 2 ───────────────────────────────────────────────────

@test "setup_wayland: unknown argument prints usage to stderr and exits 2" {
    run bash "${TOOL_SH}" --bogus
    assert_failure 2
    assert_output --partial "Usage:"
}

# ── 3. --dry-run performs no mutation (no sudo, no system files) ──────────────

@test "setup_wayland: --dry-run reports intent and mutates nothing" {
    run bash "${TOOL_SH}" --dry-run
    assert_success
    [[ ! -e "${WAYLAND_GRUB_FILE}" ]] || { printf 'dry-run created grub file\n' >&2; return 1; }
    [[ ! -e "${WAYLAND_GDM_FILE}" ]] || { printf 'dry-run created gdm file\n' >&2; return 1; }
}

@test "setup_wayland: -n is an alias for --dry-run (no mutation)" {
    run bash "${TOOL_SH}" -n
    assert_success
    [[ ! -e "${WAYLAND_GRUB_FILE}" ]] || return 1
}

# ── Dry-run applies the GRUB edit only in intent (NVIDIA present) ─────────────

@test "setup_wayland: --dry-run with NVIDIA present reports the GRUB edit but writes nothing" {
    printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"\n' >"${WAYLAND_GRUB_FILE}"
    local _before
    _before="$(cat "${WAYLAND_GRUB_FILE}")"

    STUB_BIN="${INIT_UBUNTU_TEST_SCRATCH}/bin"
    mkdir -p "${STUB_BIN}"
    printf '#!/usr/bin/env bash\nexit 0\n' >"${STUB_BIN}/nvidia-smi"
    chmod +x "${STUB_BIN}/nvidia-smi"

    PATH="${STUB_BIN}:${PATH}" run bash "${TOOL_SH}" --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
    [[ "$(cat "${WAYLAND_GRUB_FILE}")" == "${_before}" ]] || { printf 'dry-run mutated grub\n' >&2; return 1; }
}

# ── Migration guardrail: sources the shared bootstrap ────────────────────────

@test "setup_wayland: sources lib/tool_bootstrap.sh and dispatches through tool_main" {
    grep -q 'tool_bootstrap.sh' "${TOOL_SH}"
    grep -qE '^tool_main "\$@"$' "${TOOL_SH}"
}
