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
        log_fatal "No sudo access. Cannot continue setup 'shell'."
    else
        log_warn "Skip setup 'shell' due to no sudo access."
        return 1
    fi
fi

log_info "Install basic packages..."
_apt_dep_pkgs=(
    "curl"
    # "openssh-client"
    # "openssh-server"
    "ssh"
)
apt_pkg_manager --install "${_apt_dep_pkgs[@]}"

if ! echo ":${PATH}:" | grep -F ":${HOME}/bin:"; then
    log_info "Add bin path to ${HOME}/.profile"
    exec_cmd "printf '%s\n' \
        '# set PATH so it includes user'\''s private bin if it exists' \
        'if [ -d \"\${HOME}/bin\" ] ; then' \
        '    PATH=\"\${HOME}/bin:\$PATH\"' \
        'fi' >> \"${HOME}/.profile\""
    # # set PATH so it includes user's private bin if it exists
    # if [ -d "$HOME/bin" ] ; then
    #     PATH="$HOME/bin:$PATH"
    # fi
fi
if ! echo ":${PATH}:" | grep -F ":${HOME}/.local/bin:"; then
    log_info "Add local bin path to ${HOME}/.profile"
    exec_cmd "printf '%s\n' \
        '# set PATH so it includes user'\''s private bin if it exists' \
        'if [ -d \"\${HOME}/.local/bin\" ] ; then' \
        '    PATH=\"\${HOME}/.local/bin:\$PATH\"' \
        'fi' >> \"${HOME}/.profile\""
    # # set PATH so it includes user's private bin if it exists
    # if [ -d "$HOME/.local/bin" ] ; then
    #     PATH="$HOME/.local/bin:$PATH"
    # fi
fi

log_info "Install zoxide..."
# shellcheck disable=SC1091
source "${SUBMODULE_PATH}/zoxide.sh"

log_info "Install fzf..."
# shellcheck disable=SC1091
source "${SUBMODULE_PATH}/fzf.sh"

log_info "Install fdfind..."
# shellcheck disable=SC1091
source "${SUBMODULE_PATH}/fdfind.sh"

log_info "Install batcat..."
# shellcheck disable=SC1091
source "${SUBMODULE_PATH}/batcat.sh"

function install_fish_plugin_and_set_user_config() {
    log_info "Add fish PPA repository..."
    exec_cmd "sudo apt-add-repository -y ppa:fish-shell/release-4"

    log_info "Install fish and dep..."
    local _apt_dep_pkgs=(
        "xclip"
        # "xsel"
        "fish"
    )
    apt_pkg_manager --install -- "${_apt_dep_pkgs[@]}"

    if [[ ! -d "${HOME}/.ssh" ]]; then
        exec_cmd "
            mkdir -p -- \"${HOME}/.ssh\" && \
            chmod 700 \"${HOME}/.ssh\" && \
            touch \"${HOME}/.ssh/enviroment\" && \
            chmod 600 \"${HOME}/.ssh/enviroment\""
    fi

    log_info "Install fish plugins and configure fish..."
    local _fisher_url="https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish"
    exec_cmd "curl -fsSL --retry 3 \"${_fisher_url}\" | fish -c \"source && fisher install jorgebucaran/fisher\""

    exec_cmd "fish -c \"
        fisher install \
            jorgebucaran/autopair.fish \
            markcial/upto \
            edc/bass \
            danhper/fish-ssh-agent \
            kidonng/zoxide.fish \
            PatrickF1/fzf.fish \
            IlanCosman/tide@v6 \
            meaningful-ooo/sponge \
            oh-my-fish/plugin-pj \""

    # Configure tide
    exec_cmd "fish -c \"
        tide configure \
            --auto \
            --style=Classic \
            --prompt_colors='True color' \
            --classic_prompt_color=Light \
            --show_time='24-hour format' \
            --classic_prompt_separators=Angled \
            --powerline_prompt_heads=Sharp \
            --powerline_prompt_tails=Flat \
            --powerline_prompt_style='Two lines, character' \
            --prompt_connection=Solid \
            --powerline_right_prompt_frame=No \
            --prompt_connection_andor_frame_color=Light \
            --prompt_spacing=Sparse \
            --icons='Many icons' \
            --transient=Yes\" &>/dev/null"

    # copy user config
    exec_cmd "cp -r \"${CONFIG_PATH}/fish\" \"${HOME}/.config\""

    # switch default shell to fish shell
    exec_cmd "sudo chsh -s \"$(which fish)\" \"${USER}\""
}

_install_fisher_and_fish_plugin
