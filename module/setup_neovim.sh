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
    export DATETIME="$(date +"%Y-%m-%d-%T")"
    export BACKUP_DIR="${HOME}/.backup/${DATETIME}"
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

_neovim_dep_pkgs=(
    "ca-certificates"
    "curl"
    "git"
    "jq"
    "unzip"
    "build-essential"
    "clang"
    "g++"
    "gcc"
    "make"
    "cmake"
    "lldb"
    "python3"
    "python3-pip"
    "python3-venv"
    "ripgrep"
    "fd-find"
    "zoxide"
    "yarn"
)
log_info "Install 'Neovim' dependency packages: ${_neovim_dep_pkgs[*]}"
apt_pkg_manager --install -- "${_neovim_dep_pkgs[@]}"

log_info "Install Neovim (Github Releases)"
log_info "Get latest Neovim release version from GitHub"
_tmp_nvim=""
create_temp_file _tmp_nvim "nvim" "tar.gz"
_nvim_version=""
get_github_pkg_latest_version _nvim_version "neovim/neovim"
exec_cmd "curl -fsSL --retry 3 -o \"${_tmp_nvim}\" \
    \"https://github.com/neovim/neovim/releases/download/v${_nvim_version}/nvim-linux-x86_64.tar.gz\""

_nvim_install_dir="/opt/nvim"
if [[ -e "${_nvim_install_dir}" ]]; then
    log_info "Backup old Neovim installation (${_nvim_install_dir}) to ${BACKUP_DIR}/nvim"
    backup_file "${_nvim_install_dir}"
    sudo rm -rf "${_nvim_install_dir}"
fi

log_info "Install Neovim v${_nvim_version} to ${_nvim_install_dir}"
exec_cmd "sudo mkdir -p -- \"${_nvim_install_dir}\" && \
    sudo tar -C \"${_nvim_install_dir}\" --strip-components=1 -xzf \"${_tmp_nvim}\" && \
    sudo ln -sfn \"${_nvim_install_dir}/bin/nvim\" \"/usr/local/bin/nvim\""

log_info "Neovim v${_nvim_version} installed to ${_nvim_install_dir}."

# https://github.com/ayamir/nvimdots/wiki/Prerequisites
log_info "Install 'nvimdots' dependencies - lazygit (Latest Release)"

log_info "Get latest lazygit release version from GitHub"
_tmp_lazygit=""
create_temp_file _tmp_lazygit "lazygit" "tar.gz"
_lazygit_version=""
get_github_pkg_latest_version _lazygit_version "jesseduffield/lazygit"
exec_cmd "curl -fsSL --retry 3 -o \"${_tmp_lazygit}\" \
    \"https://github.com/jesseduffield/lazygit/releases/download/v${_lazygit_version}/lazygit_${_lazygit_version}_Linux_x86_64.tar.gz\""

_lazygit_install_dir="/opt/lazygit"
if [[ -e "${_lazygit_install_dir}" ]]; then
    log_info "Backup old lazygit installation (${_lazygit_install_dir}) to ${BACKUP_DIR}/lazygit"
    backup_file "${_lazygit_install_dir}"
    sudo rm -rf "${_lazygit_install_dir}"
fi

exec_cmd "sudo mkdir -p -- \"${_lazygit_install_dir}/bin\"&& \
    sudo tar -C \"${_lazygit_install_dir}/bin\" -xzf \"${_tmp_lazygit}\" \"lazygit\" && \
    sudo ln -sfn \"${_lazygit_install_dir}/bin/lazygit\" \"/usr/local/bin/lazygit\""

log_info "lazygit v${_lazygit_version} installed to ${_lazygit_install_dir}."


log_info "Install 'node.js' dependencies - Fast Node Manager (fnm)"
exec_cmd "curl -fsSL --retry 3 \
    \"https://fnm.vercel.app/install\" | bash -s -- --skip-shell"

log_info "Configure shell to use 'fnm'"
# fish
if [[ ! -f "${HOME}/.config/fish/conf.d/fnm.fish" ]]; then
    mkdir -p "${HOME}/.config/fish/conf.d"
    _source_file="${_script_path}/config/neovim/fnm_shell_config/fnm.fish"
    log_info "Add fnm configuration to ${HOME}/.config/fish/conf.d/fnm.fish from ${_source_file}"
    exec_cmd "cp \"${_source_file}\" \"${HOME}/.config/fish/conf.d/fnm.fish\""
fi
# bash
if [[ -f "${HOME}/.bashrc" ]]; then
    if ! grep -q 'fnm env' "${HOME}/.bashrc"; then
        _source_file="${_script_path}/config/neovim/fnm_shell_config/config.bash"
        log_info "Add fnm configuration to ${HOME}/.bashrc from ${_source_file}"
        exec_cmd "cat \"${_source_file}\" >> \"${HOME}/.bashrc\""
    fi
fi

_source_file="${_script_path}/config/neovim/fnm_shell_config/config.bash"
_fnm_version="22"
exec_cmd "source \"${_source_file}\" && \
    fnm install ${_fnm_version} && \
    fnm use ${_fnm_version} && \
    fnm alias default ${_fnm_version}"

log_info "node.js version: $(node -v), npm version: $(npm -v)"

log_info "Install packages with 'npm'"
# TODO: del test
# _npm_pkgs=(
#     "tree-sitter-cli"
#     "prettier"
# )
# for _pkg in "${_npm_pkgs[@]}"; do
#     exec_cmd "source \"${_source_file}\" && \
#         npm install -g -- \"${_pkg}\""
# done


# log_info "Install nvimdots dependencies - other (Latest Release)"
# # rustup component add rust-analyzer
# # cargo/rustc required by sniprun and rustfmt
# curl https://sh.rustup.rs -sSf | sh -s -- -y

log_info "Install nvimdots (Latest Release)"

# NOTE: enter is use default option
if command -v curl >/dev/null 2>&1; then
    # shellcheck disable=SC1090
    bash -c "$(
        source "${_source_file}" && \
        curl -fsSL https://raw.githubusercontent.com/ayamir/nvimdots/HEAD/scripts/install.sh
    )" || true
else
    # shellcheck disable=SC1090
    bash -c "$(
        source "${_source_file}" && \
        wget -O- https://raw.githubusercontent.com/ayamir/nvimdots/HEAD/scripts/install.sh
    )" || true
fi

# NOTE: ERROR List
# go.nvim error
# mason-null-ls.nvim
#  `npm install -g -- "prettier"`

# find ~/.local ~/.config/ -type f -path "*/lsp_signature*/doc/tags" -exec rm -f {} \;
# rm ${HOME}/.local/share/nvim/site/lazy/lsp_signature.nvim/doc/tags
log_info "Remove lsp_signature.nvim doc tags to avoid error"
exec_cmd "rm -f \"${HOME}/.local/share/nvim/site/lazy/lsp_signature.nvim/doc/tags\" || true"

log_info "Copy nvimdots configuration files"
_nvimdots_sur_dir="${_script_path}/config/neovim/nvimdots_config"
_nvimdots_conf_dir="${HOME}/.config/nvim/lua/user"
mkdir -p "${_nvimdots_conf_dir}"

if [ -d "${_nvimdots_conf_dir}" ]; then
    rm -rf "${_nvimdots_conf_dir}"
fi
cp -r "${_nvimdots_sur_dir}" "${_nvimdots_conf_dir}"

log_info "Neovim installation finished."

log_info "Please"
    # fish -c "
    #     fisher install \
    #         kidonng/zoxide.fish \

