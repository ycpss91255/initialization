#!/usr/bin/env bats
# test/unit/color_spec.bats — lib/color.sh (PRD §5.1 / §7.5, M8, AC-16)
#
# ANSI auto-detection: non-tty / NO_COLOR / TERM=dumb / background → off.
# Explicit modes: --color=always forces on (even piped), --color=never
# forces off (even on a tty). LOG_COLOR + INIT_UBUNTU_COLOR_MODE are kept
# in sync so lib/logger.sh follows the same decision.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    setup_test_env
    # Start each test from a clean color-related env.
    unset NO_COLOR INIT_UBUNTU_COLOR_MODE COLOR_ENABLED LOG_COLOR
    export TERM="xterm-256color"
    export LOG_LEVEL=INFO
}

teardown() {
    teardown_test_env
}

source_color() {
    # shellcheck source=../../lib/color.sh
    source "${LIB_DIR}/color.sh"
}

# ── Library guard ────────────────────────────────────────────────────────────

@test "color.sh refuses direct execution" {
    run bash "${LIB_DIR}/color.sh"
    assert_success
    assert_output --partial "is a library"
}

# ── Auto-detection (color_init auto) ─────────────────────────────────────────

@test "color_init auto disables color when stdout is not a tty" {
    source_color
    # bats runs tests with stdout captured (non-tty), so auto must say off.
    color_init auto
    [ "${COLOR_ENABLED}" = "false" ]
    [ -z "${CLR_RED}" ]
    [ -z "${CLR_RESET}" ]
    [ "${LOG_COLOR}" = "false" ]
}

@test "color_init defaults to auto when no mode given" {
    source_color
    color_init
    [ "${INIT_UBUNTU_COLOR_MODE}" = "auto" ]
    [ "${COLOR_ENABLED}" = "false" ]
}

@test "color_init auto disables color when NO_COLOR is set" {
    source_color
    NO_COLOR=1 color_init auto
    [ "${COLOR_ENABLED}" = "false" ]
}

@test "color_init auto disables color when TERM=dumb" {
    source_color
    TERM=dumb color_init auto
    [ "${COLOR_ENABLED}" = "false" ]
}

# ── Explicit modes ───────────────────────────────────────────────────────────

@test "color_init always enables color even when piped (non-tty)" {
    source_color
    color_init always
    [ "${COLOR_ENABLED}" = "true" ]
    [ "${INIT_UBUNTU_COLOR_MODE}" = "always" ]
    [ "${LOG_COLOR}" = "true" ]
    [[ "${CLR_RED}" == *$'\033'* ]]
    [[ "${CLR_BOLD_RED}" == *$'\033'* ]]
    [[ "${CLR_RESET}" == *$'\033'* ]]
}

@test "color_init never disables color and wins over everything" {
    source_color
    color_init never
    [ "${COLOR_ENABLED}" = "false" ]
    [ "${INIT_UBUNTU_COLOR_MODE}" = "never" ]
    [ "${LOG_COLOR}" = "false" ]
    [ -z "${CLR_GREEN}" ]
}

@test "color_init rejects an unknown mode with exit 2" {
    source_color
    run color_init sometimes
    assert_failure 2
    assert_output --partial "invalid --color mode"
}

@test "color_init always then never re-init clears the palette" {
    source_color
    color_init always
    [[ -n "${CLR_YELLOW}" ]]
    color_init never
    [ -z "${CLR_YELLOW}" ]
    [ "${COLOR_ENABLED}" = "false" ]
}

# ── color_enabled helper ─────────────────────────────────────────────────────

@test "color_enabled reflects the color_init decision" {
    source_color
    color_init always
    run color_enabled
    assert_success
    color_init never
    run color_enabled
    assert_failure
}

# ── colorize helper ──────────────────────────────────────────────────────────

@test "colorize wraps text in escapes when color is on" {
    source_color
    color_init always
    run colorize RED "danger"
    assert_success
    [[ "${output}" == *$'\033'* ]]
    [[ "${output}" == *"danger"* ]]
}

@test "colorize passes text through untouched when color is off" {
    source_color
    color_init never
    run colorize RED "danger"
    assert_success
    assert_output "danger"
    [[ "${output}" != *$'\033'* ]]
}

# ── Logger integration (LOG_COLOR / INIT_UBUNTU_COLOR_MODE sync) ─────────────

@test "log output piped has no ANSI escapes under color_init auto" {
    source_logger
    source_color
    color_init auto
    run log_info "hello"
    assert_success
    [[ "${output}" != *$'\033'* ]]
}

@test "log output contains ANSI escapes when forced with color_init always" {
    source_logger
    source_color
    color_init always
    run log_info "hello"
    assert_success
    [[ "${output}" == *$'\033'* ]]
}
