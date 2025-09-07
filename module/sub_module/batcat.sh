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
    export FUNCTION_PATH="${SCRIPT_PATH}/function"
    export CONFIG_PATH="${SCRIPT_PATH}/config"

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

log_info "Install batcat (Github Releases)"
log_info "Get latest batcat release version from GitHub"

# create temp file
_tmp_batcat=""
create_temp_file _tmp_batcat "batcat" "tar.gz"

# get latest version from github and download
_batcat_version=""
_batcat_repo="sharkdp/bat"
get_github_pkg_latest_version _batcat_version "${_batcat_repo}"
exec_cmd "curl -fsSL --retry 3 -o \"${_tmp_batcat}\" \
    \"https://github.com/${_batcat_repo}/releases/download/v${_batcat_version}/bat-v${_batcat_version}-x86_64-unknown-linux-gnu.tar.gz\""

_batcat_install_dir="/opt/batcat"
if [[ -e "${_batcat_install_dir}" ]]; then
    log_info "Backup old batcat installation (${_batcat_install_dir}) to ${BACKUP_DIR}/batcat"
    backup_file "${_batcat_install_dir}"
    sudo rm -rf "${_batcat_install_dir}"
fi

log_info "Install batcat v${_batcat_version} to ${_batcat_install_dir}"
exec_cmd "sudo mkdir -p -- \"${_batcat_install_dir}\" && \
    sudo tar -C \"${_batcat_install_dir}\" --strip-components=1 -xzf \"${_tmp_batcat}\" && \
    sudo ln -sfn \"${_batcat_install_dir}/bat\" \"/usr/local/bin/bat\""

log_info "batcat v${_batcat_version} installed to ${_batcat_install_dir}."
