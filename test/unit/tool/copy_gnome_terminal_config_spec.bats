#!/usr/bin/env bats
# test/unit/tool/copy_gnome_terminal_config_spec.bats — spec for the migrated
# tool/copy_gnome_terminal_config.sh (ADR-0029 template-first migration).
#
# The tool sources lib/tool_bootstrap.sh and shrinks to usage() + do_work().
# do_work backs up the GNOME Terminal dconf tree via tool_run; dconf is absent
# in the test image, so a stub on PATH stands in for the real-run cases. The
# --help / unknown-arg / --dry-run cases never reach do_work, so they need no
# dconf at all.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
    export LIB_DIR REPO_ROOT

    TOOL_SH="${REPO_ROOT}/tool/copy_gnome_terminal_config.sh"

    # Redirect the backup to a scratch file so mutation is observable.
    BACKUP_FILE="${INIT_UBUNTU_TEST_SCRATCH}/gnome-terminal-backup.conf"
    export GNOME_TERMINAL_BACKUP_FILE="${BACKUP_FILE}"

    # dconf stub on PATH: emits a deterministic dump so `dconf dump ... > file`
    # produces observable content without a real GNOME session.
    STUB_BIN="${INIT_UBUNTU_TEST_SCRATCH}/bin"
    mkdir -p "${STUB_BIN}"
    cat >"${STUB_BIN}/dconf" <<'STUB'
#!/usr/bin/env bash
# Minimal dconf stub: `dconf dump <path>` prints a fixed profile dump.
if [[ "${1:-}" == "dump" ]]; then
    printf '[/]\ndefault-show-menubar=false\n'
    exit 0
fi
exit 0
STUB
    chmod +x "${STUB_BIN}/dconf"
    PATH="${STUB_BIN}:${PATH}"
    export PATH
}

teardown() {
    teardown_test_env
}

# ── 1. --help exits 0 and prints usage ───────────────────────────────────────

@test "copy_gnome_terminal_config: --help prints usage and exits 0" {
    run bash "${TOOL_SH}" --help
    assert_success
    assert_output --partial "Usage:"
}

@test "copy_gnome_terminal_config: -h is an alias for --help (exit 0)" {
    run bash "${TOOL_SH}" -h
    assert_success
    assert_output --partial "Usage:"
}

# ── 2. unknown arg exits 2 and mutates nothing ───────────────────────────────

@test "copy_gnome_terminal_config: unknown argument prints usage to stderr and exits 2" {
    run bash "${TOOL_SH}" --bogus
    assert_failure 2
    assert_output --partial "Usage:"
}

@test "copy_gnome_terminal_config: unknown arg does not create the backup" {
    run bash "${TOOL_SH}" --bogus
    assert_failure 2
    [[ ! -e "${BACKUP_FILE}" ]] || { printf 'backup created on usage error: %s\n' "${BACKUP_FILE}" >&2; return 1; }
}

# ── 3. --dry-run performs no mutation ────────────────────────────────────────

@test "copy_gnome_terminal_config: --dry-run reports intent and mutates nothing" {
    run bash "${TOOL_SH}" --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
    [[ ! -e "${BACKUP_FILE}" ]] || { printf '--dry-run created backup: %s\n' "${BACKUP_FILE}" >&2; return 1; }
}

@test "copy_gnome_terminal_config: -n is an alias for --dry-run (no mutation)" {
    run bash "${TOOL_SH}" -n
    assert_success
    [[ ! -e "${BACKUP_FILE}" ]] || return 1
}

# ── Real run + idempotency ───────────────────────────────────────────────────

@test "copy_gnome_terminal_config: run dumps the profile tree to the backup file" {
    run bash "${TOOL_SH}"
    assert_success
    [[ -f "${BACKUP_FILE}" ]] || { printf 'run did not create backup: %s\n' "${BACKUP_FILE}" >&2; return 1; }
    grep -q "default-show-menubar" "${BACKUP_FILE}"
}

@test "copy_gnome_terminal_config: re-run overwrites (idempotent, no growth)" {
    run bash "${TOOL_SH}"
    assert_success
    local _first
    _first="$(wc -l <"${BACKUP_FILE}")"
    run bash "${TOOL_SH}"
    assert_success
    local _second
    _second="$(wc -l <"${BACKUP_FILE}")"
    [[ "${_first}" -eq "${_second}" ]] || { printf 'backup grew across runs: %s -> %s lines\n' "${_first}" "${_second}" >&2; return 1; }
}

# ── Migration guardrail: sources the shared bootstrap ────────────────────────

@test "copy_gnome_terminal_config: sources lib/tool_bootstrap.sh and dispatches through tool_main" {
    grep -q 'tool_bootstrap.sh' "${TOOL_SH}"
    grep -qE '^tool_main "\$@"$' "${TOOL_SH}"
}
