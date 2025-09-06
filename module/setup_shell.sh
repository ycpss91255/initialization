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

log_info "Install basic packages..."
_apt_dep_pkgs=(
    "curl"
    "openssh-client"
    # "openssh-server"
    "ssh"
)
apt_pkg_manager --install "${_apt_dep_pkgs[@]}"

log_info "Add fish PPA repository..."
exec_cmd "sudo apt-add-repository -y ppa:fish-shell/release-4"

log_info "Install fish..."
apt_pkg_manager --install -- fish
#xsel

# zoxide
curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh
# eval "$(zoxide init bash)"
# eval "$(zoxide init zsh)"

# fzf
if [[ -d "${HOME}/.fzf" ]]; then
    log_info "Backup old fzf installation (${HOME}/.fzf) to ${BACKUP_DIR}/fzf"
    backup_file "${HOME}/.fzf"
    rm -rf "${HOME}/.fzf"
fi
exec_cmd "git clone --depth 1 \"https://github.com/junegunn/fzf.git\" \"${HOME}/.fzf\" && ${HOME}/.fzf/install --key-bindings --completion --no-update-rc"
_fzf_bash_conf="[ -f ~/.fzf.bash ] && source ~/.fzf.bash"
if [[ -f "${HOME}/.bashrc" ]]; then
    if ! grep -q "${_fzf_bash_conf}" "${HOME}/.bashrc"; then
        log_info "Add fzf configuration to ${HOME}/.bashrc"
        exec_cmd "printf '\n%s\n' \"${_fzf_bash_conf}\" >> \"${HOME}/.bashrc\""
    fi
fi

# install fd-find
log_info "Install fd-find (Github Releases)"
log_info "Get latest fd-find release version from GitHub"
_tmp_fdfind=""
create_temp_file _tmp_fdfind "fdfind" "tar.gz"
_fdfind_version=""
_fdfind_repo="sharkdp/fd"
get_github_pkg_latest_version _fdfind_version "${_fdfind_repo}"
exec_cmd "curl -fsSL --retry 3 -o \"${_tmp_fdfind}\" \
    \"https://github.com/${_fdfind_repo}/releases/download/v${_fdfind_version}/fd-v${_fdfind_version}-x86_64-unknown-linux-gnu.tar.gz\""

_fdfind_install_dir="/opt/fdfind"
if [[ -e "${_fdfind_install_dir}" ]]; then
    log_info "Backup old fdfind installation (${_fdfind_install_dir}) to ${BACKUP_DIR}/fdfind"
    backup_file "${_fdfind_install_dir}"
    sudo rm -rf "${_fdfind_install_dir}"
fi

log_info "Install fdfind v${_fdfind_version} to ${_fdfind_install_dir}"
exec_cmd "sudo mkdir -p -- \"${_fdfind_install_dir}\" && \
    sudo tar -C \"${_fdfind_install_dir}\" --strip-components=1 -xzf \"${_tmp_fdfind}\" && \
    sudo ln -sfn \"${_fdfind_install_dir}/fd\" \"/usr/local/bin/fd\""

log_info "fdfind v${_fdfind_version} installed to ${_fdfind_install_dir}."

# install batcat
log_info "Install batcat (Github Releases)"
log_info "Get latest batcat release version from GitHub"
_tmp_batcat=""
create_temp_file _tmp_batcat "batcat" "tar.gz"
_batcat_version=""
_batcat_repo="sharkdp/bat"
get_github_pkg_latest_version _batcat_version "${_batcat_repo}"
exec_cmd "curl -fsSL --retry 3 -o \"${_tmp_batcat}\" \
    \"https://github.com/${_batcat_repo}/releases/download/v${_batcat_version}/bat-v${_batcat_version}-x86_64-unknown-linux-gnu.tar.gz\""

_batcat_install_dir="/opt/batcat"
if [[ -e "${_batcat_install_dir}" ]]; then
    log_info "Backup old batcat installation (${_batcat_install_dir}) to ${BACKUP_DIR}/batcat"
    backup_file "${_batcat_install_dir}"
    sudo rm -rf "${_batcat_install_dir}"
fi

log_info "Install batcat v${_batcat_version} to ${_batcat_install_dir}"
exec_cmd "sudo mkdir -p -- \"${_batcat_install_dir}\" && \
    sudo tar -C \"${_batcat_install_dir}\" --strip-components=1 -xzf \"${_tmp_batcat}\" && \
    sudo ln -sfn \"${_batcat_install_dir}/bin/bat\" \"/usr/local/bin/bat\""

log_info "batcat v${_batcat_version} installed to ${_batcat_install_dir}."


# install fisher
apt_pkg_manager --install -- curl

curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | fish -c "source && fisher install jorgebucaran/fisher"

# Install fish plugin
# TODO: check ssh-agent
exec_cmd "fish -c \"fisher install \
        jorgebucaran/autopair.fish \
        markcicl/upto \
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
        --transient=Yes\""

#
if [[ ! -d "${HOME}/.ssh" ]]; then
    mkdir -p -- "${HOME}/.ssh"
    chomd 700 "${HOME}/.ssh"
    touch "${HOME}/.ssh/enviroment"
fi

# copy user config
exec_cmd "cp -r \"${CONFIG_PATH}/fish\" \"${HOME}/.config\""

# switch default shell to fish shell
exec_cmd "sudo chsh -s \"$(which fish)\" \"${USER}\""
