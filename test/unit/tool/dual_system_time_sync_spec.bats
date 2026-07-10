#!/usr/bin/env bats
# test/unit/tool/dual_system_time_sync_spec.bats — spec for the migrated
# tool/dual_system_time_sync.sh (ADR-0029 template-first migration).
#
# The tool sources lib/tool_bootstrap.sh and shrinks to usage() + do_work().
# do_work sets the timezone, NTP-syncs, and writes the RTC — all privileged
# clock operations, so a real run is exercised through PATH stubs for sudo /
# ntpdate / timedatectl / hwclock. The critical migration property: the old
# `apt-get install -y ntpdate` HOST INSTALL is gone (hard rule #2).

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
    export LIB_DIR REPO_ROOT

    TOOL_SH="${REPO_ROOT}/tool/dual_system_time_sync.sh"

    # Stubs: sudo passes through; the clock tools are no-ops that record calls.
    STUB_BIN="${INIT_UBUNTU_TEST_SCRATCH}/bin"
    CALL_LOG="${INIT_UBUNTU_TEST_SCRATCH}/calls.log"
    mkdir -p "${STUB_BIN}"
    cat >"${STUB_BIN}/sudo" <<'STUB'
#!/usr/bin/env bash
exec "$@"
STUB
    for _c in ntpdate timedatectl hwclock; do
        cat >"${STUB_BIN}/${_c}" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "${_c}" "\$*" >>"${CALL_LOG}"
exit 0
STUB
    done
    chmod +x "${STUB_BIN}"/*
    PATH="${STUB_BIN}:${PATH}"
    export PATH CALL_LOG
}

teardown() { teardown_test_env; }

# ── 1. --help exits 0 and prints usage ───────────────────────────────────────

@test "dual_system_time_sync: --help prints usage and exits 0" {
    run bash "${TOOL_SH}" --help
    assert_success
    assert_output --partial "Usage:"
}

@test "dual_system_time_sync: -h is an alias for --help (exit 0)" {
    run bash "${TOOL_SH}" -h
    assert_success
    assert_output --partial "Usage:"
}

# ── 2. unknown arg exits 2 ───────────────────────────────────────────────────

@test "dual_system_time_sync: unknown argument prints usage to stderr and exits 2" {
    run bash "${TOOL_SH}" --bogus
    assert_failure 2
    assert_output --partial "Usage:"
}

# ── 3. --dry-run performs no clock operation ─────────────────────────────────

@test "dual_system_time_sync: --dry-run reports intent and runs no clock tool" {
    run bash "${TOOL_SH}" --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
    [[ ! -e "${CALL_LOG}" ]] || { printf '--dry-run invoked a clock tool: %s\n' "$(cat "${CALL_LOG}")" >&2; return 1; }
}

# ── Real run drives the clock tools (via stubs) ──────────────────────────────

@test "dual_system_time_sync: run syncs via ntpdate against the configured server" {
    export DUAL_SYSTEM_NTP_SERVER="pool.example.org"
    run bash "${TOOL_SH}"
    assert_success
    grep -q "ntpdate pool.example.org" "${CALL_LOG}"
    grep -q "hwclock --localtime --systohc" "${CALL_LOG}"
}

# ── Migration guardrail: no host package install; sources the bootstrap ───────

@test "dual_system_time_sync: no longer performs a host package install" {
    # Ignore comments; assert no real apt/dpkg/snap install command survives.
    run bash -c "grep -vE '^[[:space:]]*#' \"\$1\" | grep -nE '(apt|apt-get|dpkg|snap)[[:space:]]+(install|remove|purge|upgrade|reinstall)'" _ "${TOOL_SH}"
    assert_failure
}

@test "dual_system_time_sync: sources lib/tool_bootstrap.sh and dispatches through tool_main" {
    grep -q 'tool_bootstrap.sh' "${TOOL_SH}"
    grep -qE '^tool_main "\$@"$' "${TOOL_SH}"
}
