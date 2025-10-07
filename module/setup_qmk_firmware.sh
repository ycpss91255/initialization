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
    export SUBMODULE_PATH="${SCRIPT_PATH}/submodule"

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

function _install_qmk_firmware() {
    local -ar _pkgs=(
        "python3"
        "python3-pip"
        "pipx"
    )
    apt_pkg_manager --install -- "${_pkgs[@]}"
    pipx install qmk
    qmk setup -y

}

qmk list-keyboards
# my keyboard boardsource/unicorne (test)
qmk compile -kb "<keyboard>" -km "default"

# ${HOME}/.config/qmk/qmk.ini
qmk config user.keyboard="<keyboard>"
qmk config user.keymap="<keymap>"

# create new keymap
# ${HOME}/qmk_firmware/keyboards/<keyboard>/keymaps/<keymap>
qmk new-keymap
# or
qmk new-keymap -kb "<keyboard>" -km "<keymap>"

# compile
qmk compile
# or
qmk compile -kb "<keyboard>" -km "<keymap>"

# flash
qmk flash
# or
qmk flash -kb "<keyboard>" -km "<keymap>"

# ref: https://docs.qmk.fm/

module/config/qmk_firmware/keyboards
module/config/qmk_firmware/keyboards/boardsource
module/config/qmk_firmware/keyboards/boardsource/unicorne
module/config/qmk_firmware
module/config/qmk_firmware/keyboards/boardsource/unicorne/keymap
