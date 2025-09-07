#!/usr/bin/env bash

set -euo pipefail
shopt -s inherit_errexit &>/dev/null || true

MAIN_FILE="true"; [[ "${BASH_SOURCE[0]}" != "${0}" ]] && MAIN_FILE="false"

if [[ "${MAIN_FILE}" == "true" ]]; then
    # shellcheck disable=SC2155
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

    SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
    export FUNCTION_PATH="${SCRIPT_PATH}/../function"
    export CONFIG_PATH="${SCRIPT_PATH}/../config"

    :
fi

# include sub script
# shellcheck disable=SC1091
source "${FUNCTION_PATH}/logger.sh"
# shellcheck disable=SC1091
source "${FUNCTION_PATH}/general.sh"

# main script
log_info "Start setup process..."

if ! have_sudo_access; then
    if [[ "${MAIN_FILE}" == "true" ]]; then
        log_fatal "No sudo access. Cannot continue install 'xxx'."
    else
        log_warn "Skip install 'xxx' due to no sudo access."
        return 1
    fi
fi

log_info "Install fd-find (Github Releases)"
log_info "Get latest fd-find release version from GitHub"
# create temp file
_tmp_fdfind=""
create_temp_file _tmp_fdfind "fdfind" "tar.gz"

# get latest version from github and download
_fdfind_version=""
_fdfind_repo="sharkdp/fd"
get_github_pkg_latest_version _fdfind_version "${_fdfind_repo}"
exec_cmd "curl -fsSL --retry 3 -o \"${_tmp_fdfind}\" \
    \"https://github.com/${_fdfind_repo}/releases/download/v${_fdfind_version}/fd-v${_fdfind_version}-x86_64-unknown-linux-gnu.tar.gz\""

_fdfind_install_dir="/opt/fdfind"
_skip_fdfind_install="false"
if [[ -e "${_fdfind_install_dir}" ]]; then
    # system fd-find version check
    if [[ -x "${_fdfind_install_dir}/fd" ]]; then
        if [[ "$("${_fdfind_install_dir}/fd" --version | awk '{print $2}')" == "${_fdfind_version}" ]]; then
            log_info "fd-find v${_fdfind_version} already installed to ${_fdfind_install_dir}."
            _skip_fdfind_install="true"
        fi
    fi
    if [[ "${_skip_fdfind_install}" == "false" ]]; then
        log_info "Backup old fdfind installation (${_fdfind_install_dir}) to ${BACKUP_DIR}/fdfind"
        backup_file "${_fdfind_install_dir}"
        sudo rm -rf "${_fdfind_install_dir}"
    fi
fi

if [[ "${_skip_fdfind_install}" == "false" ]]; then
    log_info "Install fdfind v${_fdfind_version} to ${_fdfind_install_dir}"
    exec_cmd "sudo mkdir -p -- \"${_fdfind_install_dir}\" && \
        sudo tar -C \"${_fdfind_install_dir}\" --strip-components=1 -xzf \"${_tmp_fdfind}\" && \
        sudo ln -sfn \"${_fdfind_install_dir}/fd\" \"/usr/local/bin/fd\""
fi

log_info "fdfind v${_fdfind_version} installed to ${_fdfind_install_dir}."
