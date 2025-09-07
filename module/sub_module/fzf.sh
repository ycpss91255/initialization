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
        log_fatal "No sudo access. Cannot continue install 'xxx'."
    else
        log_warn "Skip install 'xxx' due to no sudo access."
        return 1
    fi
fi

if [[ -d "${HOME}/.fzf" ]]; then
    log_info "Backup old fzf installation (${HOME}/.fzf) to ${BACKUP_DIR}/fzf"
    backup_file "${HOME}/.fzf"
    rm -rf "${HOME}/.fzf"
fi
exec_cmd "git clone --depth 1 \"https://github.com/junegunn/fzf.git\" \"${HOME}/.fzf\" && ${HOME}/.fzf/install --key-bindings --completion --no-update-rc"

for _shell in "bash" "zsh"; do
    _fzf_conf="[ -f ~/.fzf.${_shell} ] && source ~/.fzf.${_shell}"
    if [[ -f "${HOME}/.${_shell}rc" ]]; then
        if ! grep -q "${_fzf_conf}" "${HOME}/.${_shell}rc"; then
            log_info "Add fzf configuration to ${HOME}/.${_shell}rc"
            exec_cmd "printf '\n%s\n' \"${_fzf_conf}\" >> \"${HOME}/.${_shell}rc\""
        fi
    fi
done
