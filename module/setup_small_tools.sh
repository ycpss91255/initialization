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


#--------------------------
function _install_base_pkgs() {
    local _install_pkgs=(
        "software-properties-common"
        "curl"
        "wget"
        "jq"
        # "apt-file"
        "python3"
        "python3-dev"
        "python3-pip"
        "python3-setuptools"
        "pipx"
        "xclip"
        # "xsel"
        "net-tools"
        "ncdu"
        "neofetch"
        "tree"
        "silversearcher-ag"
        "xdg-utils"

        "cowsay"
        "cmatrix"
        "figlet"
    )

    log_info "Install basic packages..."
    apt_pkg_manager --install -- "${_install_pkgs[@]}"
}

function install_submodule_tool() {
    find "${SUBMODULE_PATH}" -maxdepth 1 -type f -name "*.sh" | while read -r file; do
        log_info "Install tool from ${file##*/}..."
        # shellcheck disable=SC1090
        source "${file}"
    done
}

function _install_ssh_pkgs() {
    local _ssh_pkgs=(
        # "ssh"
        "openssh-client"
        "openssh-server"
        "sshfs"
    )

    log_info "install ssh related packages..."
    apt_pkg_manager --install -- "${_ssh_pkgs[@]}"

    # copy ssh config template to ~/.ssh/config
    exec_cmd "cp ${CONFIG_PATH}/ssh/ssh_config ${HOME}/.ssh/config"

    function _ensure_ssh_config() {
        local key="${1:?"${FUNCNAME[0]}: missing key"}"
        local value="${2:?"${FUNCNAME[0]}: missing value"}"
        local file="${3:?"${FUNCNAME[0]}: missing file"}"

    if grep -q "^[#[:space:]]*$key" "$file"; then
            exec_cmd "sudo sed -i.bak \"s|^[#[:space:]]*$key.*|$key $value|\" \"${file}\""
        else
            exec_cmd "echo \"$key $value\" | sudo tee -a \"${file}\" > /dev/null"
        fi
    }

    # ensure ssh config
    local _ssh_config_file="./ssh_config"
    _ensure_ssh_config "ForwardAgent" "yes" "${_ssh_config_file}"

    # ensure sshd config
    local _ssh_daemon_file="./sshd_config"
    _ensure_ssh_config "AllowTcpForwarding" "yes" "${_ssh_daemon_file}"
    _ensure_ssh_config "X11Forwarding" "yes" "${_ssh_daemon_file}"
    _ensure_ssh_config "X11DisplayOffset" "10" "${_ssh_daemon_file}"
    _ensure_ssh_config "X11UseLocalhost" "yes" "${_ssh_daemon_file}"

    # enable and restart ssh service
    exec_cmd "sudo systemctl enable ssh && sudo systemctl restart ssh"
}

function _install_git_pkgs() {
    local _git_pkgs=(
        "git"
        "git-lfs"
        # https://dandavison.github.io/delta/choosing-colors-styles.html
        # https://github.com/dandavison/delta?tab=readme-ov-file
        "git-delta"
        "tig"
    )

    log_info "install git related packages..."
    apt_pkg_manager --install -- "${_git_pkgs[@]}"
    cp "${CONFIG_PATH}/git/gitconfig" "${HOME}/.gitconfig"
}

function _install_monitor_pkgs() {
    local _monitor_pkgs=(
        "bashtop"
        "htop"
        "iftop"
        "iotop"
        "powertop"
        "powerstat"
        "bmon"
        "nmon"
        "nmap"
    )

    log_info "install monitoring packages..."
    apt_pkg_manager --install -- "${_monitor_pkgs[@]}"
    exec_cmd "pipx install bpytop"
}

function _install_ranger() {
    log_info "Install and configure ranger..."
    apt_pkg_manager --install -- "pipx"
    exec_cmd "pipx install ranger-fm"

    local _conf_dir="${HOME}/.config/ranger"
    local _plugins_dir="${_conf_dir}/plugins"
    local _rc_file="${_conf_dir}/rc.conf"

    if [[ -d "${_conf_dir}" ]]; then
        log_info "Backup old ranger configuration (${_conf_dir}) to ${BACKUP_DIR}/ranger"
        backup_file "${_conf_dir}"
        exec_cmd "rm -rf \"${_conf_dir}\""
    fi
    exec_cmd "mkdir -p \"${_plugins_dir}\""


    log_info "Install ranger plugins..."
    # ranger_devicons
    log_info "Install ranger_devicons..."
    exec_cmd "git clone --depth 1 \
        \"https://github.com/alexanderjeurissen/ranger_devicons\" \
        \"\"${_plugins_dir}/ranger_devicons\""
    # devicons config
    if ! grep -qxF "default_linemode devicons" "${_rc_file}"; then
        exec_cmd "echo \"default_linemode devicons\" >> \"${_rc_file}\""
    fi

    # anger-zoxide
    log_info "Install ranger-zoxide..."
    exec_cmd "git clone --depth 1 \
        \"https://github.com/jchook/ranger-zoxide\" \
        \"${_plugins_dir}/ranger-zoxide\""

    # ranger-fzf-filter
    log_info "Install ranger-fzf-filter..."
    exec_cmd "git clone --depth 1 \
        \"https://github.com/MuXiu1997/ranger-fzf-filter\" \
        \"${_plugins_dir}/ranger_fzf_filter\""
    # fzf config
    if ! grep -qxF "map f console fzf_filter%space" "${_rc_file}"; then
        exec_cmd "echo \"map f console fzf_filter%space\" >> \"${_rc_file}\""
    fi
}

function install_tmux() {
    # tmux and tmuxp
    _tmux_pkgs=(
        "tmux"
        "tmuxp"
    )
    apt_pkg_manager --install -- "${_tmux_pkgs[@]}"

    local _conf_dir="${HOME}/.config/tmux"
    local _powerline_dir="${HOME}/.config/tmux-powerline"
    local _tpm_dir="${HOME}/.tmux/plugins/tpm"

    # backup and delete old tmux config
    if [[ -d "${_conf_dir}" ]]; then
        log_info "Backup old tmux configuration (${_conf_dir}) to ${BACKUP_DIR}/${_conf_dir##*/}"
        backup_file "${_conf_dir}"
        exec_cmd "rm -rf \"${_conf_dir}\""
    fi
    # backup and delete old tmux-powerline
    if [[ -d "${_powerline_dir}" ]]; then
        log_info "Backup old tmux configuration (${_powerline_dir}) to ${BACKUP_DIR}/${_powerline_dir##*/}"
        backup_file "${_powerline_dir}"
        exec_cmd "rm -rf \"${_powerline_dir}\""
    fi
    # backup and delete old tpm
    if [[ -d "${_tpm_dir}" ]]; then
        log_info "Backup old tmux configuration (${_tpm_dir}) to ${BACKUP_DIR}/${_conf_dir##*/}"
        backup_file "${_tpm_dir}"
        exec_cmd "rm -rf \"${_tpm_dir}\""
    fi

    exec_cmd "mkdir -p \"${_conf_dir}\""
    # copy new config
    exec_cmd "cp \"${CONFIG_PATH}/tmux/tmux.conf\" \"${_conf_dir}\""
    # copy new powerline config
    exec_cmd "cp -r \"${CONFIG_PATH}/tmux/tmux-powerline\" \"${_powerline_dir}\""

    # install new plugin manager and plugins
    exec_cmd "git clone --depth 1 \
            \"https://github.com/tmux-plugins/tpm\" \"${_tpm_dir}\" && \
        \"${_tpm_dir}/scripts/install_plugins.sh\""
}

function install_spotify() {
    exec_cmd "curl -sS \"https://download.spotify.com/debian/pubkey_C85668DF69375001.gpg\" \
        | sudo gpg --dearmor --yes -o \"/etc/apt/trusted.gpg.d/spotify.gpg\""
    exec_cmd "echo \"deb https://repository.spotify.com stable non-free\" | sudo tee /etc/apt/sources.list.d/spotify.list"
    apt_pkg_manager --install -- "spotify-client"
}

_install_base_pkgs
install_submodule_tool
_install_ssh_pkgs
_install_git_pkgs
_install_monitor_pkgs
_install_ranger
install_tmux
install_spotify
