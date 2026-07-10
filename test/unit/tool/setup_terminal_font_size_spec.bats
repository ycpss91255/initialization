#!/usr/bin/env bats
# test/unit/tool/setup_terminal_font_size_spec.bats — spec for the migrated
# tool/setup_terminal_font_size.sh (ADR-0029 template-first migration).
#
# The tool sources lib/tool_bootstrap.sh and shrinks to usage() + do_work().
# do_work rewrites FONTFACE/FONTSIZE in a console-setup file and runs setupcon.
# CONSOLE_SETUP_FILE redirects the target to a scratch file; sudo is a
# pass-through stub and setupcon a no-op stub so a real run is observable.
# CONSOLE_FONTSIZE feeds the size non-interactively (no TTY prompt in bats).

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
    export LIB_DIR REPO_ROOT

    TOOL_SH="${REPO_ROOT}/tool/setup_terminal_font_size.sh"

    TARGET="${INIT_UBUNTU_TEST_SCRATCH}/console-setup"
    printf 'FONTFACE="Fixed"\nFONTSIZE="16x32"\n' >"${TARGET}"
    export CONSOLE_SETUP_FILE="${TARGET}"

    STUB_BIN="${INIT_UBUNTU_TEST_SCRATCH}/bin"
    mkdir -p "${STUB_BIN}"
    cat >"${STUB_BIN}/sudo" <<'STUB'
#!/usr/bin/env bash
exec "$@"
STUB
    cat >"${STUB_BIN}/setupcon" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "${STUB_BIN}"/*
    PATH="${STUB_BIN}:${PATH}"
    export PATH
}

teardown() { teardown_test_env; }

# ── 1. --help exits 0 and prints usage ───────────────────────────────────────

@test "setup_terminal_font_size: --help prints usage and exits 0" {
    run bash "${TOOL_SH}" --help
    assert_success
    assert_output --partial "Usage:"
}

@test "setup_terminal_font_size: -h is an alias for --help (exit 0)" {
    run bash "${TOOL_SH}" -h
    assert_success
    assert_output --partial "Usage:"
}

# ── 2. unknown arg exits 2 ───────────────────────────────────────────────────

@test "setup_terminal_font_size: unknown argument prints usage to stderr and exits 2" {
    run bash "${TOOL_SH}" --bogus
    assert_failure 2
    assert_output --partial "Usage:"
}

# ── 3. --dry-run performs no mutation ────────────────────────────────────────

@test "setup_terminal_font_size: --dry-run reports intent and leaves the file unchanged" {
    local _before
    _before="$(cat "${TARGET}")"
    CONSOLE_FONTSIZE="8x16" run bash "${TOOL_SH}" --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
    [[ "$(cat "${TARGET}")" == "${_before}" ]] || { printf '--dry-run mutated the file\n' >&2; return 1; }
}

# ── Real run rewrites the font lines ─────────────────────────────────────────

@test "setup_terminal_font_size: run rewrites FONTSIZE in the target file" {
    CONSOLE_FONTSIZE="8x16" run bash "${TOOL_SH}"
    assert_success
    grep -q 'FONTSIZE="8x16"' "${TARGET}"
    grep -q 'FONTFACE="Fixed"' "${TARGET}"
}

@test "setup_terminal_font_size: re-run is idempotent (no line growth)" {
    CONSOLE_FONTSIZE="8x16" run bash "${TOOL_SH}"
    assert_success
    local _first
    _first="$(wc -l <"${TARGET}")"
    CONSOLE_FONTSIZE="8x16" run bash "${TOOL_SH}"
    assert_success
    [[ "$(wc -l <"${TARGET}")" -eq "${_first}" ]] || { printf 'file grew across runs\n' >&2; return 1; }
}

# ── Migration guardrail: sources the shared bootstrap ────────────────────────

@test "setup_terminal_font_size: sources lib/tool_bootstrap.sh and dispatches through tool_main" {
    grep -q 'tool_bootstrap.sh' "${TOOL_SH}"
    grep -qE '^tool_main "\$@"$' "${TOOL_SH}"
}
