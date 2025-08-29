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
        log_fatal "No sudo access. Cannot continue install 'VSCode'."
    else
        log_warn "Skip install 'VSCode' due to no sudo access."
        return 1
    fi
fi
