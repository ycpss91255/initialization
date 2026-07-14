#!/usr/bin/env bash
# tool/dual_system_time_sync.sh — set the timezone, sync the clock over NTP, and
# persist it to the hardware clock in localtime for dual-boot Windows/Linux
# machines whose RTC is kept in local time.
#
# One-off tool (ADR-0029). It used to be a bare `sudo apt-get install -y ntpdate`
# + sync sequence with no strict mode, no --help, and no dry-run — and, worse, a
# HOST PACKAGE INSTALL, which a one-off tool must never do (repo hard rule #2).
# It now sources lib/tool_bootstrap.sh and shrinks to usage() + do_work(). The
# apt install is REMOVED: ntpdate is treated as a prerequisite (install it via a
# module, e.g. `setup_ubuntu install ntpdate`), and do_work fails fast with
# guidance when it is missing. All mutations run through tool_run so --dry-run is
# honored.
#
# MAINTAINER NOTE: the dropped `apt-get install ntpdate` now lives in a proper
# module — module/ntpdate.module.sh. Provision the package with
# `setup_ubuntu install ntpdate` before running this tool. tool_run also
# structurally refuses host package installs, so re-adding it here would fail.

# shellcheck source=../lib/tool_bootstrap.sh
source "${LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd -P)}/tool_bootstrap.sh"
tool_bootstrap

# ── Identity ─────────────────────────────────────────────────────────────────
TOOL_NAME="dual_system_time_sync"
TOOL_SUMMARY="set timezone, NTP-sync the clock, and write it to the RTC in localtime"

# Overridable so the tool is not pinned to one locale/server.
TIMEZONE="${DUAL_SYSTEM_TIMEZONE:-Asia/Taipei}"
NTP_SERVER="${DUAL_SYSTEM_NTP_SERVER:-tw.pool.ntp.org}"

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${TOOL_NAME} — ${TOOL_SUMMARY}

Usage:
  ${TOOL_NAME}              set timezone, NTP-sync, write RTC (localtime)
  ${TOOL_NAME} --dry-run    show what would run, write nothing
  ${TOOL_NAME} -h|--help    show this help and exit

Environment:
  DUAL_SYSTEM_TIMEZONE     timezone (default: ${TIMEZONE})
  DUAL_SYSTEM_NTP_SERVER   NTP server (default: ${NTP_SERVER})

Exit codes:
  0  success (or --help)
  2  usage error (unknown argument)

Notes:
  * Requires ntpdate to be installed already (this tool never installs host
    packages — hard rule #2). Install it via a module first.
  * Writes the RTC in localtime, matching a Windows dual-boot's expectation.
EOF
}

# ── Work ─────────────────────────────────────────────────────────────────────
do_work() {
    # ntpdate is a prerequisite, not something a one-off tool installs.
    if ! tool_is_dry_run && ! command -v ntpdate >/dev/null 2>&1; then
        log_fatal "ntpdate not found — install it first (e.g. 'setup_ubuntu install ntpdate'); this tool does not install host packages"
    fi

    tool_run "sudo timedatectl set-timezone ${TIMEZONE}"
    tool_run "sudo ntpdate ${NTP_SERVER}"
    tool_run "sudo hwclock --localtime --systohc"
    tool_is_dry_run || log_info "system time synced (${TIMEZONE} via ${NTP_SERVER}) and written to the RTC in localtime"
}

# ── Entry ────────────────────────────────────────────────────────────────────
tool_main "$@"
