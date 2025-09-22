#!/usr/bin/env bash

set -euo pipefail
shopt -s inherit_errexit &>/dev/null || true

MAIN_FILE="true"; [[ "${BASH_SOURCE[0]}" != "${0}" ]] && MAIN_FILE="false"

if [[ "${MAIN_FILE}" == "true" ]]; then
    # shellcheck disable=SC2155
    SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
    export USER="${USER:-"$(whoami)"}"
    export HOME="${HOME:-"/home/${USER}"}"
    export LANGUAGE="C:en"

    # logger.sh variables
    export LOG_LEVEL="INFO"
    export LOG_COLOR="true"

    # sub_func.sh variables
    unset HAVE_SUDO_ACCESS

    # shellcheck disable=SC2155
    # export DATETIME="$(date +"%Y-%m-%d-%T")"
    # export BACKUP_DIR="${HOME}/.backup/${DATETIME}"
    :
fi

# include sub script
# shellcheck disable=SC1091
source "${SCRIPT_PATH}/function/logger.sh"
# shellcheck disable=SC1091
source "${SCRIPT_PATH}/function/general.sh"

# the file used variables
if [[ "${MAIN_FILE}" == "true" ]]; then
    _script_path="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
else
    _script_path="${SCRIPT_PATH}"
fi

# main script
log_info "Start setup process..."


if ! have_sudo_access; then
    if [[ "${MAIN_FILE}" == "true" ]]; then
        log_fatal "No sudo access. Cannot continue install 'NVIDIA-driver'."
    else
        log_warn "Skip install 'NVIDIA-driver' due to no sudo access."
        return 1
    fi
fi

if ! sudo lshw -C display | grep -qi "nvidia"; then
    if [[ "${MAIN_FILE}" == "true" ]]; then
        log_fatal "No NVIDIA GPU detected. Cannot continue install 'NVIDIA-driver'."
    else
        log_warn "Skip install 'NVIDIA-driver' due to no NVIDIA GPU detected."
        return 1
    fi
fi

log_info "Install 'NVIDIA-driver' dependencies"
_basic_dep_pkgs=(
    "software-properties-common"
    "ubuntu-drivers-common"
    "gnupg-agent"
)
apt_pkg_manager --install "${_basic_dep_pkgs[@]}"

log_info "Adding graphics-drivers PPA"
exec_cmd "sudo add-apt-repository -y \"ppa:graphics-drivers/ppa\""

if ! check_pkg_status --exec -- "nvidia-smi"; then
    # NOTE: delete old nvidia-driver-* package?
    # exec_cmd "sudo apt-get purge -y 'nvidia-driver-*'" || true
    :
else
    _install_version="$(dpkg-query -W -f='${Package}\n' 'nvidia-driver-*' 2>/dev/null \
    | grep -E '^nvidia-driver-[0-9]+(-open)?$' \
    | sort -V \
    | tail -1)"
fi

_recommend_version="$(ubuntu-drivers devices | grep 'recommended' | awk '{print $3}')"

# TODO: user-specified version
# Check if the recommended NVIDIA driver not found
if [[ -z "${_recommend_version}" ]]; then
    if [[ "${MAIN_FILE}" == "true" ]]; then
        log_fatal "NVIDIA driver recommend version not found. Please use 'ubuntu-drivers devices' check the recommended drivers and try again."
    else
        log_warn "Skip install 'NVIDIA-driver' due to recommend version not found."
        return 1
    fi
fi

# if the installed NVIDIA driver not equal to the recommended NVIDIA driver
if [[ "${_install_version:-}" != "${_recommend_version}" ]]; then
        # purge old NVIDIA driver and install the recommended NVIDIA driver
    log_info "Purge old NVIDIA driver and install recommended NVIDIA driver"
    if [[ -n "${_install_version:-}" ]]; then
        apt_pkg_manager --purge -- "${_install_version}"
    fi

    apt_pkg_manager --install -- "${_recommend_version}"
fi

# Install 'nvitop'
log_info "Install 'nvitop' dependencies"
_basic_pip_pkgs=(
    "python3"
    "python3-pip"
    "pipx"
)
apt_pkg_manager --install "${_basic_pip_pkgs[@]}"

log_info "Install 'nvitop'"
# Install 'nvitop'
# for ubuntu 20.04 - 22.04
# pip install -U pip setuptools
# pip install git+https://github.com/XuehaiPan/nvitop.git#egg=nvitop

# for ubuntu 24.04 up
pipx install git+https://github.com/XuehaiPan/nvitop.git#egg=nvitop

apt_pkg_manager --install -- "gpustat"

log_info "'NVIDIA-driver' installation finished. version: $(nvidia-smi --version | head -n1)"
