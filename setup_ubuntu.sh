#!/usr/bin/env bash
# ==============================================================================
#
# Usage: bash setup_ubuntu.sh [--help]
# TODO: default = install all
# option:
#   (default): dialog
#   --All
#   --nvidia
#   --fish
#   --docker

#   --help: show this help message and exit
#
# ==============================================================================

set -euo pipefail

shopt -s inherit_errexit &>/dev/null || true


MAIN_FILE="true"; [[ "${BASH_SOURCE[0]}" != "${0}" ]] && MAIN_FILE="false"

if [[ "${MAIN_FILE}" == "true" ]]; then
    printf "Warn: %s is a executable script, not a library.\n" "${BASH_SOURCE[0]##*/}"
    printf "Please run this file.\n"
    return 0 2>/dev/null
fi

export USER="${USER:-"$(whoami)"}"
export HOME="${HOME:-"/home/${USER}"}"

export LANGUAGE="C:en"

# logger.sh variables
export LOG_LEVEL="DEBUG"
# export LOG_COLOR="true"

# sub_func.sh variables
unset HAVE_SUDO_ACCESS

# main.sh variables
# shellcheck disable=SC2155
export DATETIME="$(date +"%Y-%m-%d-%T")"
export BACKUP_DIR="${HOME}/.backup/${DATETIME}"
export SET_MIRRORS="false"

# include sub script
# shellcheck disable=SC2155
SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "${SCRIPT_PATH}/module/function/logger.sh"
# shellcheck disable=SC1091
source "${SCRIPT_PATH}/module/function/sub_func.sh"

# main script
log_info "Start setup process..."

if ! have_sudo_access; then
    log_fatal "This script requires sudo access. Please run as a user with sudo privileges."
fi


log_info "Start"
# # Update ca-certificates
# log_info "Update ca-certificates..."
# apt_pkg_manager --install --only-upgrade -- "ca-certificates"

# Setup APT source mirror
if [[ "${SET_MIRRORS}" == "true" ]]; then
    log_info "Setup APT source mirror..."
    log_info "Not action now."

    # setup_apt_mirror "tw.packages.microsoft.com" "packages.microsoft.com"
    # setup_apt_mirror "tw.archive.ubuntu.com" "archive.ubuntu.com"
    # log_info "Test: update apt-get..."
    # if ! exec_cmd "sudo apt-get update"; then
    #     log_error "Failed to update apt-get."
    #     log_info "Rollback APT source mirror changes..."
    #     # rollback to backup
    # fi
fi

_BASIC_PKGS=(
    "software-properties-common"
    # NOTE: maybe first run upgrade ca-certificates
    "ca-certificates"
    "apt-transport-https"
    "curl"
    "wget"
)

log_info "Install basic packages: ${_BASIC_PKGS[*]}..."
apt_pkg_manager --install -- "${_BASIC_PKGS[@]}"


# shellcheck disable=SC1091
source "${SCRIPT_PATH}/module/setup_font.sh" || fatal_pkg+=("font")

# shellcheck disable=SC1091
source "${SCRIPT_PATH}/module/setup_docker.sh" || fatal_pkg+=("docker")

# shellcheck disable=SC1091
source "${SCRIPT_PATH}/module/setup_vscode.sh" || fatal_pkg+=("vscode")

# shellcheck disable=SC1091
source "${SCRIPT_PATH}/module/setup_neovim.sh" || fatal_pkg+=("neovim")

if [ "${#fatal_pkg[@]}" -ne 0 ]; then
    log_error "Some packages failed to install: ${fatal_pkg[*]}"
fi

log_info "Done yayayaya"


exit 0

# NVIDIA driver
# shellcheck disable=SC2317
exec_cmd 'sudo add-apt-repository ppa:graphics-drivers/ppa --yes'
