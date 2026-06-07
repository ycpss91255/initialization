#!/usr/bin/env bash

set -euo pipefail
shopt -s inherit_errexit &>/dev/null || true

SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${SCRIPT_PATH}/../function/logger.sh"
source "${SCRIPT_PATH}/../function/general.sh"

if ! have_sudo_access; then
    log_fatal "No sudo access. Cannot configure Wayland."
fi

GRUB_FILE="/etc/default/grub"
GDM_FILE="/etc/gdm3/custom.conf"
GRUB_KEY="GRUB_CMDLINE_LINUX_DEFAULT"
MODESET_PARAM="nvidia-drm.modeset=1"

# ── 1. NVIDIA check ──────────────────────────────────────────────────────────
log_info "Checking for NVIDIA GPU..."
if ! command -v nvidia-smi &>/dev/null || ! nvidia-smi &>/dev/null; then
    log_warn "No NVIDIA GPU detected. Skipping nvidia-drm.modeset=1 setup."
else
    log_info "NVIDIA GPU detected: $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"

    # ── 2. Add nvidia-drm.modeset=1 to GRUB ──────────────────────────────────
    current_cmdline=$(grep "^${GRUB_KEY}=" "${GRUB_FILE}" | sed 's/.*="\(.*\)"/\1/')
    if echo "${current_cmdline}" | grep -q "${MODESET_PARAM}"; then
        log_info "${MODESET_PARAM} already set in ${GRUB_FILE}, skipping."
    else
        log_info "Adding ${MODESET_PARAM} to ${GRUB_KEY} in ${GRUB_FILE}..."
        exec_cmd "sudo sed -i \
            \"s|^${GRUB_KEY}=\\\"\(.*\)\\\"|${GRUB_KEY}=\\\"\1 ${MODESET_PARAM}\\\"|\" \
            \"${GRUB_FILE}\""
        log_info "Updated: $(grep "^${GRUB_KEY}=" "${GRUB_FILE}")"
        exec_cmd "sudo update-grub"
    fi
fi

# ── 3. Ensure GDM allows Wayland ─────────────────────────────────────────────
log_info "Checking GDM configuration..."
if grep -qE "^WaylandEnable=false" "${GDM_FILE}" 2>/dev/null; then
    log_info "GDM has WaylandEnable=false — commenting it out..."
    exec_cmd "sudo sed -i 's/^WaylandEnable=false/#WaylandEnable=false/' '${GDM_FILE}'"
else
    log_info "GDM already allows Wayland."
fi

# ── 4. Set user session to Wayland ───────────────────────────────────────────
USER_NAME="${USER:-$(whoami)}"
ACCOUNTS_FILE="/var/lib/AccountsService/users/${USER_NAME}"

log_info "Checking AccountsService session for ${USER_NAME}..."
if [[ -f "${ACCOUNTS_FILE}" ]]; then
    current_session=$(sudo grep -E "^Session=" "${ACCOUNTS_FILE}" 2>/dev/null || true)
    if [[ "${current_session}" == "Session=ubuntu-wayland" ]]; then
        log_info "Session already set to ubuntu-wayland."
    else
        log_info "Setting session to ubuntu-wayland in AccountsService..."
        if sudo grep -q "^Session=" "${ACCOUNTS_FILE}" 2>/dev/null; then
            exec_cmd "sudo sed -i 's/^Session=.*/Session=ubuntu-wayland/' '${ACCOUNTS_FILE}'"
        else
            exec_cmd "printf '\n[User]\nSession=ubuntu-wayland\n' | sudo tee -a '${ACCOUNTS_FILE}' > /dev/null"
        fi
    fi
else
    log_warn "AccountsService file not found for ${USER_NAME}. Log in via GDM once to create it."
fi

log_info "Wayland setup complete. Changes take effect on next login."
