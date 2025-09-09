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
        log_fatal "No sudo access. Cannot continue install 'fzf'."
    else
        log_warn "Skip install 'fzf' due to no sudo access."
        return 1
    fi
fi

# NOTE: Not using the public version function
function install_fzf() {
    local _github_repo="${1:?"${FUNCNAME[0]}: missing github repo"}"
    local _run_alias="${2:?"${FUNCNAME[0]}: missing run alias"}"
    local _install_dir="${3:-${HOME}/.fzf}"

    local _pkg_name="${_github_repo##*/}"
    local _latest_version="" _install_version="" _no_download="false"

    get_github_pkg_latest_version _latest_version "${_github_repo}"


    if [[ "${_no_download}" == "false" ]]; then
        exec_cmd "git clone --depth 1 \"https://github.com/junegunn/fzf.git\" \"${_install_dir}\" && \
        ${_install_dir}/install --key-bindings --completion --no-update-rc"
    fi

    for _shell in "bash" "zsh"; do
        _fzf_conf="[ -f ~/.fzf.${_shell} ] && source ~/.fzf.${_shell}"
        if [[ -f "${HOME}/.${_shell}rc" ]]; then
            if ! grep -q "${_fzf_conf}" "${HOME}/.${_shell}rc"; then
                log_info "Add fzf configuration to ${HOME}/.${_shell}rc"
                exec_cmd "printf '\n%s\n' \"${_fzf_conf}\" >> \"${HOME}/.${_shell}rc\""
            fi
        fi
    done

    log_info "Installed ${_pkg_name} v${_latest_version} to ${_install_dir}, run alias: ${_run_alias}."
}


function install_xxx() {
    local _github_repo="${1:?"${FUNCNAME[0]}: missing github repo"}"
    local _bin_file="${2:?"${FUNCNAME[0]}: missing bin name"}"
    local _install_dir="${3:-${HOME}/.fzf}"

    local _pkg_name="${_github_repo##*/}"
    local _latest_version="" _install_version="" _no_download="false"

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

        exec_cmd "git clone --depth 1 \"https://github.com/junegunn/fzf.git\" \"${_install_dir}\" && \
        ${_install_dir}/install --key-bindings --completion --no-update-rc"

        _install_version="${_latest_version}"
    fi

    # NOTE: add config to user's shell profile and rc file (optional)
    for _shell in "bash" "zsh"; do
        # add to rc file
        if [[ -f "${HOME}/.${_shell}rc" ]]; then
            local _fzf_conf="[ -f ~/.fzf.${_shell} ] && source ~/.fzf.${_shell}"
            if ! grep -q "${_fzf_conf}" "${HOME}/.${_shell}rc"; then
                log_info "Add fzf configuration to ${HOME}/.${_shell}rc"
                exec_cmd "echo \"${_fzf_conf}\" >> \"${HOME}/.${_shell}rc\""
            fi
        fi
    done

    log_info "Installed ${_pkg_name} v${_install_version} to ${_install_dir}, run alias: ${_bin_file}"
}

install_fzf "junegunn/fzf" "fzf" "${HOME}/.fzf"
