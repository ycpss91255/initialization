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
    export DATETIME="$(date +"%Y-%m-%d-%T")"
    export BACKUP_DIR="${HOME}/.backup/${DATETIME}"

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
        log_fatal "No sudo access. Cannot continue install 'eza'."
    else
        log_warn "Skip install 'eza' due to no sudo access."
        return 1
    fi
fi

function install_eza() {
    local _github_repo="${1:?"${FUNCNAME[0]}: missing github repo"}"
    local _bin_file="${2:?"${FUNCNAME[0]}: missing bin name"}"
    local _strip_components="${3:-0}"

    local _pkg_name="${_github_repo##*/}"
    local _install_dir="/opt/${_pkg_name}"
    local _tmp_file="" _latest_version="" _install_version="" _repo_url="" _download_file="" _no_download="false"

    # create temp file
    create_temp_file _tmp_file "${_pkg_name}" ".tar.gz"

    # get latest version from Github
    get_github_pkg_latest_version _latest_version "${_github_repo}"

    # check if already installed
    if command -v "${_bin_file}" ;then
        _install_version="$("${_bin_file}" --version | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?')"

        # The latest version is already installed
        [ "${_install_version}" == "${_latest_version}" ] && _no_download="true"
    fi

    # download and install latest version package
    if [[ "${_no_download}" == "false" ]]; then
        # backup old installation
        if [[ -d "${_install_dir}" ]]; then
            log_info "Backup old ${_pkg_name} installation ${_install_dir}) to ${BACKUP_DIR}/${_pkg_name}"
            backup_file "${_install_dir}"
            sudo rm -rf "${_install_dir}"
        fi

        _download_file="${_pkg_name}_x86_64-unknown-linux-gnu.tar.gz"
        _repo_url="https://github.com/${_github_repo}/releases/latest/download/${_download_file}"

        log_info "Download ${_pkg_name} v${_latest_version} from ${_repo_url}"
        exec_cmd "curl -fsSL --retry 3 -o \"${_tmp_file}\" \"${_repo_url}\""

        # verify download file
        if ! file "${_tmp_file}" | grep -q "gzip compressed data"; then
            log_fatal "Downloaded file ${_tmp_file} is not a valid gzip file."
            return 1
        fi
        if ! sudo tar -tzf "${_tmp_file}" &>/dev/null; then
            log_fatal "Downloaded file ${_tmp_file} is not a valid tar.gz archive."
            return 1
        fi

        # install package
        log_info "Install ${_pkg_name} v${_latest_version} to ${_install_dir}"
        exec_cmd "sudo mkdir -p -- \"${_install_dir}\" &&\
            sudo tar -xzf \"${_tmp_file}\" -C \"${_install_dir}\" --strip-components=${_strip_components}"
        exec_cmd "sudo ln -sfn -- \"${_install_dir}/${_bin_file}\" \"/usr/local/bin/${_bin_file}\""

        _install_version="${_latest_version}"
    fi

    for _shell in "bash" "zsh"; do
        # add to rc file
        if [[ -f "${HOME}/.${_shell}rc" ]]; then
            local _replace_cmd="ls"
            local _alias_cmd="${_bin_file}"
            local _alias_full_cmd="command -v ${_alias_cmd} &>/dev/null && alias ${_replace_cmd}='${_alias_cmd}'"

            if ! grep -q "${_alias_full_cmd}" "${HOME}/.${_shell}rc"; then
                log_info "Add alias '${_alias_full_cmd}' to ${HOME}/.${_shell}rc"
                exec_cmd "echo \"${_alias_full_cmd}\" >> \"${HOME}/.${_shell}rc\""
            fi
        fi
    done

    log_info "Installed ${_pkg_name} v${_install_version} to ${_install_dir}, run alias: ${_bin_file}"
}

install_eza "eza-community/eza" "eza" "1"
