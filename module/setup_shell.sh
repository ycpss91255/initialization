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

log_info "Install basic packages..."
_apt_dep_pkgs=(
    "curl"
    "openssh-client"
    # "openssh-server"
    "ssh"
)
apt_pkg_manager --install "${_apt_dep_pkgs[@]}"

for _shell in "bash" "zsh"; do
    if [[ -f "${HOME}/.${_shell}rc" ]]; then
        _add_path="${HOME}/.local/bin"
        if ! grep -Fq "export PATH=\"${_add_path}:\$PATH\"" "${HOME}/.${_shell}rc"; then
            log_info "Add local bin path to ${HOME}/.${_shell}rc"
            exec_cmd "printf '\n%s\n' 'export PATH=\"${_add_path}:\$PATH\"' >> \"${HOME}/.${_shell}rc\""
        fi
    fi
done

log_info "Add fish PPA repository..."
exec_cmd "sudo apt-add-repository -y ppa:fish-shell/release-4"

log_info "Install fish..."
apt_pkg_manager --install -- fish
#xsel

log_info "Install zoxide..."
source "${SUBMODULE_PATH}/zoxide.sh"

log_info "Install fzf..."
source "${SUBMODULE_PATH}/fzf.sh"

log_info "Install fdfind..."
source "${SUBMODULE_PATH}/fdfind.sh"

log_info "Install batcat..."
source "${SUBMODULE_PATH}/batcat.sh"

if [[ ! -d "${HOME}/.ssh" ]]; then
    mkdir -p -- "${HOME}/.ssh"
    chmod 700 "${HOME}/.ssh"
    touch "${HOME}/.ssh/enviroment"
fi

log_info "Install fish plugins and configure fish..."
curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | fish -c "source && fisher install jorgebucaran/fisher"

# Install fish plugin
# TODO: check ssh-agent
exec_cmd "fish -c \"fisher install \
        jorgebucaran/autopair.fish \
        markcial/upto \
        edc/bass \
        danhper/fish-ssh-agent \
        kidonng/zoxide.fish \
        PatrickF1/fzf.fish \
        IlanCosman/tide@v6 \
        meaningful-ooo/sponge \
        oh-my-fish/plugin-pj \
        \""

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
