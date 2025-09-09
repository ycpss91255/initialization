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
        log_fatal "No sudo access. Cannot continue install 'zoxide'."
    else
        log_warn "Skip install 'xxx' due to no sudo access."
        return 1
    fi
fi

function install_zoxide() {
    local _github_repo="${1:?"${FUNCNAME[0]}: missing github repo"}"
    local _run_alias="${2:?"${FUNCNAME[0]}: missing run alias"}"
    local _strip-components="${3:-0}"

    local _pkg_name="${_github_repo##*/}"
    local _install_dir="/opt/${_pkg_name}"
    local _tmp_file="" _latest_version="" _install_version="" _repo_url="" _download_file=""

    # create temp file
    create_temp_file _tmp_file "${_pkg_name}" ".tar.gz"

    # get latest version from Github
    get_github_pkg_latest_version _latest_version "${_github_repo}"

    # check if already installed
    if [[ -x "$(command -v "${_run_alias}")" ]];then
        # NOTE: please check the version command
        _install_version="$("${_run_alias}" --version | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?')"

        # The latest version is already installed
        if [[ "${_install_version}" == "${_latest_version}" ]]; then
            log_info "${_run_alias} v${_latest_version} lready installed to ${_install_dir}."
            return 0
        fi
    fi

    # backup old installation
    if [[ -d "${_install_dir}" ]]; then
        log_info "Backup old ${_pkg_name} installation ${_install_dir}) to ${BACKUP_DIR}/${_pkg_name}"
        backup_file "${_install_dir}"
        sudo rm -rf "${_install_dir}"
    fi

   # NOTE: This is example URL, please modify it according to your need
    _download_file="${_pkg_name}-${_latest_version}-x86_64-unknown-linux-musl.tar.gz"
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
    # NOTE: check the --strip-components value
    exec_cmd "sudo mkdir -p -- \"${_install_dir}\" &&\
        sudo tar -xzf \"${_tmp_file}\" -C \"${_install_dir}\" --strip-components=${_strip-components}"
    # NOTE: please check the binary name or path
    exec_cmd "sudo ln -sfn -- \"${_install_dir}/${_pkg_name}\" \"/usr/local/bin/${_run_alias}\""

    for _shell in "bash" "zsh"; do
        _zoxide_conf="eval \"\$(zoxide init ${_shell})\""

        if [[ -f "${HOME}/.${_shell}rc" ]]; then
            if ! grep -Fq "${_zoxide_conf}" "${HOME}/.${_shell}rc"; then
                log_info "Add zoxide configuration to ${HOME}/.${_shell}rc"
                exec_cmd "printf '\n%s\n' '${_zoxide_conf}' >> \"${HOME}/.${_shell}rc\""
            fi
        fi
    done

    log_info "Installed ${_pkg_name} v${_latest_version} to ${_install_dir}, run alias: ${_run_alias}"
}

install_zoxide "ajeetdsouza/zoxide" "zoxide"

# old version install method
# curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh

# for _shell in "bash" "zsh"; do
#     _zoxide_conf="eval \"\$(zoxide init ${_shell})\""
#     _add_path="${HOME}/.local/bin"

#     if [[ -f "${HOME}/.${_shell}rc" ]]; then
#         if ! grep -Fq "export PATH=\"${_add_path}:\$PATH\"" "${HOME}/.${_shell}rc"; then
#             log_info "Add local bin path to ${HOME}/.${_shell}rc"
#             exec_cmd "printf '\n%s\n' 'export PATH=\"${_add_path}:\$PATH\"' >> \"${HOME}/.${_shell}rc\""
#         fi

#         if ! grep -Fq "${_zoxide_conf}" "${HOME}/.${_shell}rc"; then
#             log_info "Add zoxide configuration to ${HOME}/.${_shell}rc"
#             exec_cmd "printf '\n%s\n' '${_zoxide_conf}' >> \"${HOME}/.${_shell}rc\""
#         fi
#     fi
# done
