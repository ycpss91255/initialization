#!/usr/bin/env bash
# tool/setup_terminal_font_size.sh — set the Linux virtual-console font face and
# size in /etc/default/console-setup, then apply it with setupcon.
#
# One-off tool (ADR-0029). It used to be a set -euo script with no --help, an
# unconditional interactive `read` (which blocks non-interactively), and inline
# `sudo sed`/`setupcon` mutations with no dry-run. It now sources
# lib/tool_bootstrap.sh and shrinks to usage() + do_work(): --help, --dry-run,
# a font size taken from an argument/env (prompting only on a real TTY), and all
# mutations routed through tool_run.
#
# Font size comes from (in order): a `-- <size>` argument, CONSOLE_FONTSIZE, an
# interactive prompt when stdin is a TTY, else the default below.

# shellcheck source=../lib/tool_bootstrap.sh
source "${LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd -P)}/tool_bootstrap.sh"
tool_bootstrap

# ── Identity ─────────────────────────────────────────────────────────────────
TOOL_NAME="setup_terminal_font_size"
TOOL_SUMMARY="set the Linux virtual-console font face/size in /etc/default/console-setup"

CONSOLE_SETUP_FILE="${CONSOLE_SETUP_FILE:-/etc/default/console-setup}"
FONTFACE="${CONSOLE_FONTFACE:-Fixed}"
DEFAULT_FONTSIZE="16x32"

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${TOOL_NAME} — ${TOOL_SUMMARY}

Usage:
  ${TOOL_NAME} -- <size>    set the console font size (e.g. 8x16, 16x32)
  ${TOOL_NAME}              prompt for the size on a TTY, else use the default
  ${TOOL_NAME} --dry-run    show what would run, write nothing
  ${TOOL_NAME} -h|--help    show this help and exit

Environment:
  CONSOLE_FONTSIZE     font size (skips the prompt; default: ${DEFAULT_FONTSIZE})
  CONSOLE_FONTFACE     font face (default: ${FONTFACE})
  CONSOLE_SETUP_FILE   target file (default: ${CONSOLE_SETUP_FILE})

Exit codes:
  0  success (or --help)
  2  usage error (unknown argument)

Notes:
  * Idempotent: re-running rewrites the same two FONTFACE/FONTSIZE lines.
  * Never installs host packages.

Manual alternative:
  sudo dpkg-reconfigure console-setup
EOF
}

# ── Work ─────────────────────────────────────────────────────────────────────
do_work() {
    local _fontsize="${1:-${CONSOLE_FONTSIZE:-}}"
    if [[ -z "${_fontsize}" ]]; then
        if [[ -t 0 ]]; then
            read -r -p "font size? (8x16, 16x32 ...) " _fontsize || true
        fi
        _fontsize="${_fontsize:-${DEFAULT_FONTSIZE}}"
    fi

    tool_run "sudo sed -i 's/^FONTFACE=.*/FONTFACE=\"${FONTFACE}\"/' \"${CONSOLE_SETUP_FILE}\""
    tool_run "sudo sed -i 's/^FONTSIZE=.*/FONTSIZE=\"${_fontsize}\"/' \"${CONSOLE_SETUP_FILE}\""
    tool_run "sudo setupcon"
    tool_is_dry_run || log_info "console font set to ${FONTFACE} ${_fontsize} in ${CONSOLE_SETUP_FILE}"
}

# ── Entry ────────────────────────────────────────────────────────────────────
tool_main "$@"
