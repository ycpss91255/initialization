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
        log_fatal "No sudo access. Cannot continue setup 'font'."
    else
        log_warn "Skip setup 'font' due to no sudo access."
        return 1
    fi
fi

_src_fonts_dir="${_script_path}/fonts"
if [[ ! -d "${_src_fonts_dir}" ]]; then
    if [[ "${MAIN_FILE}" == "true" ]]; then
        log_fatal "Not found: ${_src_fonts_dir}"
    else
        log_warn "Skip setup 'font' due to not found: ${_src_fonts_dir}"
        return 1
    fi
fi

readarray -d '' -t _fonts_dir < <(
    find "${_src_fonts_dir}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z
)

if [[ ${#_fonts_dir[@]} -eq 0 ]]; then
    if [[ "${MAIN_FILE}" == "true" ]]; then
        log_fatal "Subdirectories not found in ${_src_fonts_dir}"
    else
        log_warn "Skip setup 'font' due to subdirectories not found in ${_src_fonts_dir}"
        return 1
    fi
fi

_basic_dep_pkgs=(
    unzip
    fontconfig
)

apt_pkg_manager --install -- "${_basic_dep_pkgs[@]}"

_target_dir="${HOME}/.local/share/fonts"
mkdir -p -- "${_target_dir}"
chmod 755 -- "${_target_dir}"
cp -r -- "${_fonts_dir[@]}" "${_target_dir}/"

if [[ "${USER}" == "$(id -un)" ]]; then
    fc-cache -f -v "${_target_dir}" >/dev/null
else
    sudo -u "$USER" fc-cache -f -v "${_target_dir}" >/dev/null
fi

log_info "Fonts installation finished for ${USER}."
