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

curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh

for _shell in "bash" "zsh"; do
    _zoxide_conf="eval \"\$(zoxide init ${_shell})\""

    if [[ -f "${HOME}/.${_shell}rc" ]]; then
        if ! grep -Fq "${_zoxide_conf}" "${HOME}/.${_shell}rc"; then
            log_info "Add zoxide configuration to ${HOME}/.${_shell}rc"
            exec_cmd "printf '\n%s\n' '${_zoxide_conf}' >> \"./${_shell}rc\""
        fi
    fi
done
