#!/usr/bin/env bash

set -euo pipefail
shopt -s inherit_errexit &>/dev/null || true

MAIN_FILE="true"; [[ "${BASH_SOURCE[0]}" != "${0}" ]] && MAIN_FILE="false"

if [[ "${MAIN_FILE}" == "true" ]]; then
    export USER="${USER:-"$(whoami)"}"
    export HOME="${HOME:-"/home/${USER}"}"
    export LANGUAGE="C:en"

    # logger.sh variables
    export LOG_LEVEL="DEBUG"

    # sub_func.sh variables
    export LOG_NO_COLOR="false"
    unset HAVE_SUDO_ACCESS

    # main.sh variables
    # shellcheck disable=SC2155
    # export DATETIME="$(date +"%Y-%m-%d-%T")"
    # export BACKUP_DIR="${HOME}/.backup/${DATETIME}"
    # export SET_MIRRORS="false"
    :
else
    # include module
    :
fi

# include sub script
# shellcheck disable=SC2155
SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "${SCRIPT_PATH}/function/logger.sh"
# shellcheck disable=SC1091
source "${SCRIPT_PATH}/function/sub_func.sh"

# main script
log_info "Start setup process..."

unset HAVE_SUDO_ACCESS

# install step ref: https://code.visualstudio.com/docs/setup/linux


if ! have_sudo_access; then
    # coreutils => for 'install' command
    # lsb-release => for 'lsb_release' command
    # apt-transport-https => for https apt source
    # wget => for download gpg key
    # gpg => for import gpg key
    _vscode_dep_pkgs=(
        "coreutils"
        "software-properties-common"
        "apt-transport-https"
        "lsb-release"
        "wget"
        "gpg"
    )

    log_info "Install 'VSCode' dependency packages: ${_vscode_dep_pkgs[*]}"
    apt_pkg_manager --install -- "${_vscode_dep_pkgs[@]}"

    log_info "Setup 'VSCode' apt source"
    exec_cmd "wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > microsoft.gpg"
    exec_cmd "sudo install -D -o root -g root -m 644 microsoft.gpg /usr/share/keyrings/microsoft.gpg && rm -f microsoft.gpg"

    log_info "Add 'VSCode' apt source list"
    # for ubuntu 20.04 or 20.04 up
    if [[ -f /etc/apt/sources.list.d/vscode.sources ]]; then
        log_info "Backup old 'vscode.sources' file"
        if ! grep -qF 'packages.microsoft.com/repos/code' /etc/apt/sources.list.d/vscode.sources; then
            exec_cmd "sudo cp -f /etc/apt/sources.list.d/vscode.sources{,.save}"
        fi
    fi
    log_info "Copy new 'vscode.sources' file"
    exec_cmd "sudo install -D -o root -g root -m 644 ${SCRIPT_PATH}/config/vscode/vscode.sources /etc/apt/sources.list.d/vscode.sources"
    # # for ubuntu 18.04
    # if [[ -f /etc/apt/sources.list.d/vscode.list ]]; then
    #     if ! grep -qF 'packages.microsoft.com/repos/code' /etc/apt/sources.list; then
    #         exec_cmd "sudo cp -f /etc/apt/sources.list.d/vscode.list /etc/apt/sources.list.d/vscode.list.save"
    #     fi
    #     exec_cmd 'echo "deb [arch=amd64,arm64,armhf] https://packages.microsoft.com/repos/code stable main" | sudo tee /etc/apt/sources.list.d/vscode.list'
    # fi

    log_info "Install 'VSCode'"
    apt_pkg_manager --install -- "code"
else
    if [[ "${MAIN_FILE}" == "true" ]]; then
        log_fatal "No sudo access. Cannot continue install 'VSCode'."
    else
        log_warn "Skip install 'VSCode' due to no sudo access."
        return 1
    fi
fi
