#!/usr/bin/env bats
# test/unit/auto_power_profile_spec.bats
#
# Tests for tool/battery/auto-power-profile (issue #260): the decision script
# that picks a power-profiles-daemon profile from the current power source.
#
#   On AC            -> performance
#   On battery >25%  -> balanced
#   On battery <=25% -> power-saver
#
# It only calls `powerprofilesctl set` when the target differs from the current
# profile, and logs each real switch via `logger -t auto-power-profile`.
#
# Strategy: the script reads the power state from sysfs (root overridable via
# $POWER_SUPPLY_ROOT) and shells out to `powerprofilesctl` and `logger`. A fake
# sysfs tree is built per test and both commands are stubbed on PATH, so the
# real system is never touched (ADR-0004: no host mutation). The stubs record
# their argv to files so we can assert exactly what the script asked for.
#
#   PPD_CURRENT=<file>  -> `powerprofilesctl get` echoes this file's contents
#   PPD_REC=<dir>       -> `set` argv appended to $PPD_REC/set
#   APP_LOG=<file>      -> `logger` argv appended here

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    setup_test_env

    SCRIPT="${REPO_ROOT}/tool/battery/auto-power-profile"

    STUB_BIN="${INIT_UBUNTU_TEST_SCRATCH}/bin"
    PSROOT="${INIT_UBUNTU_TEST_SCRATCH}/power_supply"
    CURRENT="${INIT_UBUNTU_TEST_SCRATCH}/current-profile"
    SETREC="${INIT_UBUNTU_TEST_SCRATCH}/set-rec"
    LOGREC="${INIT_UBUNTU_TEST_SCRATCH}/logger-rec"
    mkdir -p "${STUB_BIN}" "${PSROOT}"

    # `powerprofilesctl get` prints $PPD_CURRENT; `set X` records X and updates
    # the current-profile file so a following get reflects the new value.
    cat > "${STUB_BIN}/powerprofilesctl" <<'SH'
#!/bin/sh
case "$1" in
  get) cat "$PPD_CURRENT" 2>/dev/null || true ;;
  set) printf '%s\n' "$2" >> "$PPD_REC"; printf '%s\n' "$2" > "$PPD_CURRENT" ;;
esac
exit 0
SH
    cat > "${STUB_BIN}/logger" <<'SH'
#!/bin/sh
# Drop the leading "-t <tag>" so only the message text is recorded.
while [ "$1" = "-t" ]; do shift 2; done
printf '%s\n' "$*" >> "$APP_LOG"
exit 0
SH
    chmod +x "${STUB_BIN}/powerprofilesctl" "${STUB_BIN}/logger"
}

teardown() {
    teardown_test_env
}

# Build a Mains supply (AC0) with the given online value (0|1).
_make_ac() {
    mkdir -p "${PSROOT}/AC0"
    printf 'Mains\n' > "${PSROOT}/AC0/type"
    printf '%s\n' "$1" > "${PSROOT}/AC0/online"
}

# Build a Battery supply (BAT0) with the given capacity percent.
_make_bat() {
    mkdir -p "${PSROOT}/BAT0"
    printf 'Battery\n' > "${PSROOT}/BAT0/type"
    printf '%s\n' "$1" > "${PSROOT}/BAT0/capacity"
}

# Seed the "current" profile that `powerprofilesctl get` will report.
_set_current() {
    printf '%s\n' "$1" > "${CURRENT}"
}

_run_script() {
    run env PATH="${STUB_BIN}:${PATH}" \
        POWER_SUPPLY_ROOT="${PSROOT}" \
        PPD_CURRENT="${CURRENT}" \
        PPD_REC="${SETREC}" \
        APP_LOG="${LOGREC}" \
        bash "${SCRIPT}"
}

# ── On AC ────────────────────────────────────────────────────────────────────

@test "on AC: switches to performance" {
    _make_ac 1
    _make_bat 80
    _set_current balanced
    _run_script
    assert_success
    run grep -Fx "performance" "${SETREC}"
    assert_success
}

# ── On battery, above threshold ──────────────────────────────────────────────

@test "on battery at 50% (>25): switches to balanced" {
    _make_ac 0
    _make_bat 50
    _set_current performance
    _run_script
    assert_success
    run grep -Fx "balanced" "${SETREC}"
    assert_success
}

@test "on battery at 26% (just above threshold): balanced" {
    _make_ac 0
    _make_bat 26
    _set_current performance
    _run_script
    assert_success
    run grep -Fx "balanced" "${SETREC}"
    assert_success
}

# ── On battery, at/below threshold ───────────────────────────────────────────

@test "on battery at 20% (<25): switches to power-saver" {
    _make_ac 0
    _make_bat 20
    _set_current balanced
    _run_script
    assert_success
    run grep -Fx "power-saver" "${SETREC}"
    assert_success
}

@test "on battery at exactly 25% (<=25 boundary): power-saver" {
    _make_ac 0
    _make_bat 25
    _set_current balanced
    _run_script
    assert_success
    run grep -Fx "power-saver" "${SETREC}"
    assert_success
}

# ── Idempotence: no switch when already on target ────────────────────────────

@test "no-op when the current profile already matches the target" {
    _make_ac 1
    _make_bat 80
    _set_current performance
    _run_script
    assert_success
    # `set` must never have been called.
    assert [ ! -f "${SETREC}" ]
    # ... and nothing was logged (a log line marks a real switch).
    assert [ ! -f "${LOGREC}" ]
}

# ── Logging on a real switch ─────────────────────────────────────────────────

@test "logs the switch via logger on an actual profile change" {
    _make_ac 1
    _make_bat 80
    _set_current balanced
    _run_script
    assert_success
    assert [ -f "${LOGREC}" ]
    run grep -F "performance" "${LOGREC}"
    assert_success
}

# ── Missing battery: default to balanced on battery ──────────────────────────

@test "on battery with no readable capacity: defaults to balanced" {
    _make_ac 0
    # No BAT0 device at all.
    _set_current performance
    _run_script
    assert_success
    run grep -Fx "balanced" "${SETREC}"
    assert_success
}
