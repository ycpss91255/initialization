#!/usr/bin/env bash
# tool/copy_gnome_terminal_config.sh — back up the GNOME Terminal dconf tree.
#
# One-off tool (ADR-0029). It used to be a shebang-less, set-less pair of lines
# that ran `dconf dump` immediately followed by `dconf load` — a no-op round
# trip flagged by the linux review (F26). It is now a proper template-first
# tool: sources lib/tool_bootstrap.sh and shrinks to usage() + do_work(), with
# --help, --dry-run, and an idempotent, host-package-free operation.
#
# It BACKS UP the GNOME Terminal profile tree (/org/gnome/terminal/) to a conf
# file. Restore later with the inverse dconf command (shown in --help).

# shellcheck source=../lib/tool_bootstrap.sh
source "${LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd -P)}/tool_bootstrap.sh"
tool_bootstrap

# ── Identity ─────────────────────────────────────────────────────────────────
TOOL_NAME="copy_gnome_terminal_config"
TOOL_SUMMARY="back up the GNOME Terminal dconf profile tree to a file"

# Where the backup is written. Overridable so the tool can target a chosen path
# (and so the spec can redirect it to a scratch file).
BACKUP_FILE="${GNOME_TERMINAL_BACKUP_FILE:-${HOME}/.config/init_ubuntu/gnome-terminal-backup.conf}"
DCONF_PATH="/org/gnome/terminal/"

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${TOOL_NAME} — ${TOOL_SUMMARY}

Usage:
  ${TOOL_NAME}              dump ${DCONF_PATH} to the backup file
  ${TOOL_NAME} --dry-run    show what would run, write nothing
  ${TOOL_NAME} -h|--help    show this help and exit

Backup file:
  ${BACKUP_FILE}
  (override with GNOME_TERMINAL_BACKUP_FILE=/path)

Restore the saved profiles later with the inverse dconf command:
  dconf load ${DCONF_PATH} < <backup-file>

Exit codes:
  0  success (or --help)
  2  usage error (unknown argument)

Notes:
  * Idempotent: re-running overwrites the single backup file.
  * Requires a GNOME/dconf session; never installs host packages.
EOF
}

# ── Work ─────────────────────────────────────────────────────────────────────
do_work() {
    if ! tool_is_dry_run; then
        mkdir -p -- "$(dirname -- "${BACKUP_FILE}")"
    fi
    tool_run "dconf dump ${DCONF_PATH} > \"${BACKUP_FILE}\""
    tool_is_dry_run || log_info "gnome-terminal profiles backed up to ${BACKUP_FILE}"
}

# ── Entry ────────────────────────────────────────────────────────────────────
tool_main "$@"
