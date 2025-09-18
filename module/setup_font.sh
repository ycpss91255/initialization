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
        log_fatal "No sudo access. Cannot continue setup 'Font'."
    else
        log_warn "Skip setup 'Font' due to no sudo access."
        return 1
    fi
fi



function setup_font() {
    local _github_repo="${1:?"${FUNCNAME[0]}: missing github repo"}"; shift
    local _fonts=("$@")

    local _tmp_folder="" _font=""

    local _fonts_dir="$HOME/.local/share/fonts"

    local -a _basic_dep_pkgs=(
        "unzip"
        "fontconfig"
        "dconf-cli"
    )
    apt_pkg_manager --install -- "${_basic_dep_pkgs[@]}"

    if [[ ! -d "${_fonts_dir}" ]]; then
        exec_cmd "mkdir -p -- \"${_fonts_dir}\" && chmod 755 -- \"${_fonts_dir}\""
    fi

    # create temp file
    create_temp_file -d -- _tmp_folder "nerd-fonts"

    for _font in "${_fonts[@]}"; do
        # backup old installation
        if [[ -d "${_fonts_dir}/${_font}" ]]; then
            log_info "Backup old ${_font} installation (${_fonts_dir}/${_font}) to ${BACKUP_DIR}/${_font}"
            backup_file "${_fonts_dir}/${_font}"
            exec_cmd "rm -rf \"${_fonts_dir:?}/${_font}\""
        fi

        local _download_file="${_font}.tar.xz"
        local _repo_url="https://github.com/${_github_repo}/releases/latest/download/${_download_file}"

        exec_cmd "curl -fsSL --retry 3 -o \"${_tmp_folder}/${_download_file}\" \"${_repo_url}\""
        # verify download file
        if ! file "${_tmp_folder}/${_download_file}" | grep -q "XZ compressed data"; then
            log_fatal "Downloaded file ${_tmp_folder}/${_download_file} is not a valid gzip file."
            return 1
        fi
        if ! tar -tJf "${_tmp_folder}/${_download_file}" &>/dev/null; then
            log_fatal "Downloaded file ${_tmp_folder}/${_download_file} is not a valid tar.gz archive."
            return 1
        fi

        exec_cmd "mkdir -p -- \"${_fonts_dir}/${_font}\" && \
            tar -xJf \"${_tmp_folder}/${_download_file}\" -C \"${_fonts_dir}/${_font}\""

    done

    exec_cmd "fc-cache -f -v \"${_fonts_dir}\" >/dev/null"


    if check_pkg_status --exec "dconf"; then
        exec_cmd "dconf load /org/gnome/terminal/ < ${CONFIG_PATH}/gnome-terminal.conf"
    fi

    log_info "Fonts installation finished for ${USER}."
}

setup_font "ryanoasis/nerd-fonts" "SourceCodePro" "FiraCode" "Meslo"
