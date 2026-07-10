#!/usr/bin/env bash
# tool/setup_wayland.sh — enable Wayland end to end: add nvidia-drm.modeset=1 to
# GRUB (NVIDIA only), stop GDM from forcing X11, and set the user's session to
# ubuntu-wayland in AccountsService.
#
# One-off tool (ADR-0029). It kept its logger/general helpers but had no --help
# and drove mutations through exec_cmd, which is not dry-run aware. It now
# sources lib/tool_bootstrap.sh and shrinks to usage() + do_work() (split into
# three focused steps): --help/--dry-run, sudo checked only for a real run, all
# reads grep-guarded, and every mutation routed through tool_run.

# shellcheck source=../lib/tool_bootstrap.sh
source "${LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd -P)}/tool_bootstrap.sh"
tool_bootstrap
# shellcheck source=../lib/general.sh
source "${LIB_DIR}/general.sh"

# ── Identity ─────────────────────────────────────────────────────────────────
TOOL_NAME="setup_wayland"
TOOL_SUMMARY="enable Wayland: nvidia-drm.modeset=1 in GRUB, GDM WaylandEnable, user session"

# System files (overridable so the tool is testable off the host).
GRUB_FILE="${WAYLAND_GRUB_FILE:-/etc/default/grub}"
GDM_FILE="${WAYLAND_GDM_FILE:-/etc/gdm3/custom.conf}"
ACCOUNTS_DIR="${WAYLAND_ACCOUNTS_DIR:-/var/lib/AccountsService/users}"
GRUB_KEY="GRUB_CMDLINE_LINUX_DEFAULT"
MODESET_PARAM="nvidia-drm.modeset=1"

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${TOOL_NAME} — ${TOOL_SUMMARY}

Usage:
  ${TOOL_NAME}              configure GRUB (NVIDIA), GDM, and the user session
  ${TOOL_NAME} --dry-run    show what would run, write nothing
  ${TOOL_NAME} -h|--help    show this help and exit

Environment:
  WAYLAND_GRUB_FILE       GRUB defaults (default: ${GRUB_FILE})
  WAYLAND_GDM_FILE        GDM custom conf (default: ${GDM_FILE})
  WAYLAND_ACCOUNTS_DIR    AccountsService users dir (default: ${ACCOUNTS_DIR})

Exit codes:
  0  success (or --help)
  2  usage error (unknown argument)

Notes:
  * Idempotent: each step is grep-guarded and skips when already applied.
  * Requires sudo for a real run; --dry-run needs neither sudo nor the files.
  * Never installs host packages. Changes take effect on next login.
EOF
}

# ── Step 1: GRUB (NVIDIA only) ───────────────────────────────────────────────
_configure_grub() {
    log_info "Checking for NVIDIA GPU..."
    if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi >/dev/null 2>&1; then
        log_warn "No NVIDIA GPU detected. Skipping ${MODESET_PARAM} setup."
        return 0
    fi
    log_info "NVIDIA GPU detected."

    if [[ ! -f "${GRUB_FILE}" ]]; then
        log_warn "GRUB file not found: ${GRUB_FILE}; skipping."
        return 0
    fi
    if grep -q "${MODESET_PARAM}" "${GRUB_FILE}"; then
        log_info "${MODESET_PARAM} already present in ${GRUB_FILE}; skipping."
        return 0
    fi

    log_info "Adding ${MODESET_PARAM} to ${GRUB_KEY} in ${GRUB_FILE}..."
    tool_run "sudo sed -i 's|^${GRUB_KEY}=\"\(.*\)\"|${GRUB_KEY}=\"\1 ${MODESET_PARAM}\"|' \"${GRUB_FILE}\""
    tool_run "sudo update-grub"
}

# ── Step 2: GDM allows Wayland ───────────────────────────────────────────────
_configure_gdm() {
    log_info "Checking GDM configuration..."
    if [[ -f "${GDM_FILE}" ]] && grep -qE "^WaylandEnable=false" "${GDM_FILE}"; then
        log_info "GDM has WaylandEnable=false — commenting it out..."
        tool_run "sudo sed -i 's/^WaylandEnable=false/#WaylandEnable=false/' \"${GDM_FILE}\""
    else
        log_info "GDM already allows Wayland."
    fi
}

# ── Step 3: user session -> ubuntu-wayland ───────────────────────────────────
_configure_session() {
    local _user="${USER:-$(whoami)}"
    local _file="${ACCOUNTS_DIR}/${_user}"

    log_info "Checking AccountsService session for ${_user}..."
    if [[ ! -f "${_file}" ]]; then
        log_warn "AccountsService file not found for ${_user}. Log in via GDM once to create it."
        return 0
    fi

    if ! tool_is_dry_run && sudo grep -q "^Session=ubuntu-wayland" "${_file}" 2>/dev/null; then
        log_info "Session already set to ubuntu-wayland."
        return 0
    fi

    log_info "Setting session to ubuntu-wayland in AccountsService..."
    if ! tool_is_dry_run && sudo grep -q "^Session=" "${_file}" 2>/dev/null; then
        tool_run "sudo sed -i 's/^Session=.*/Session=ubuntu-wayland/' \"${_file}\""
    else
        tool_run "printf '\n[User]\nSession=ubuntu-wayland\n' | sudo tee -a \"${_file}\" > /dev/null"
    fi
}

# ── Work ─────────────────────────────────────────────────────────────────────
do_work() {
    if ! tool_is_dry_run && ! have_sudo_access; then
        log_fatal "No sudo access. Cannot configure Wayland."
    fi

    _configure_grub
    _configure_gdm
    _configure_session

    log_info "Wayland setup complete. Changes take effect on next login."
}

# ── Entry ────────────────────────────────────────────────────────────────────
tool_main "$@"
