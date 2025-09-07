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
    export FUNCTION_PATH="${SCRIPT_PATH}/function"
    export CONFIG_PATH="${SCRIPT_PATH}/config"

    :
fi

# include sub script
# shellcheck disable=SC1091
source "${FUNCTION_PATH}/logger.sh"
# shellcheck disable=SC1091
source "${FUNCTION_PATH}/general.sh"

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
    "yarn"
    "xclip"
)
log_info "Install 'Neovim' dependency packages: ${_neovim_dep_pkgs[*]}"
apt_pkg_manager --install -- "${_neovim_dep_pkgs[@]}"

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

# zoxide
curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh
# shellcheck disable=SC2016
_zoxide_bash_conf='eval "$(zoxide init bash)"'
if [[ -f "${HOME}/.bashrc" ]]; then
    if ! grep -q "${_zoxide_bash_conf}" "${HOME}/.bashrc"; then
        log_info "Add zoxide configuration to ${HOME}/.bashrc"
        exec_cmd "printf '\n%s\n' \"${_zoxide_bash_conf}\" >> \"${HOME}/.bashrc\""
    fi
fi
# shellcheck disable=SC2016
_zoxide_zsh_conf='eval "$(zoxide init zsh)"'
if [[ -f "${HOME}/.zshrc" ]]; then
    if ! grep -q "${_zoxide_zsh_conf}" "${HOME}/.zshrc"; then
        log_info "Add zoxide configuration to ${HOME}/.zshrc"
        exec_cmd "printf '\n%s\n' \"${_zoxide_bash_conf}\" >> \"${HOME}/.zshrc\""
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
_skip_fdfind_install="false"
if [[ -e "${_fdfind_install_dir}" ]]; then
    # system fd-find version check
    if [[ -x "${_fdfind_install_dir}/fd" ]]; then
        if [[ "$("${_fdfind_install_dir}/fd" --version | awk '{print $2}')" == "${_fdfind_version}" ]]; then
            log_info "fd-find v${_fdfind_version} already installed to ${_fdfind_install_dir}."
            _skip_fdfind_install="true"
        fi
    fi
    if [[ "${_skip_fdfind_install}" == "false" ]]; then
        log_info "Backup old fdfind installation (${_fdfind_install_dir}) to ${BACKUP_DIR}/fdfind"
        backup_file "${_fdfind_install_dir}"
        sudo rm -rf "${_fdfind_install_dir}"
    fi
fi

if [[ "${_skip_fdfind_install}" == "false" ]]; then
    log_info "Install fdfind v${_fdfind_version} to ${_fdfind_install_dir}"
    exec_cmd "sudo mkdir -p -- \"${_fdfind_install_dir}\" && \
        sudo tar -C \"${_fdfind_install_dir}\" --strip-components=1 -xzf \"${_tmp_fdfind}\" && \
        sudo ln -sfn \"${_fdfind_install_dir}/fd\" \"/usr/local/bin/fd\""
fi
log_info "fdfind v${_fdfind_version} installed to ${_fdfind_install_dir}."

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
    _fnm_fish_conf_file="${_script_path}/config/neovim/fnm_shell_config/fnm.fish"
    log_info "Add fnm configuration to ${HOME}/.config/fish/conf.d/fnm.fish from ${_fnm_fish_conf_file}"
    exec_cmd "cp \"${_fnm_fish_conf_file}\" \"${HOME}/.config/fish/conf.d/fnm.fish\""
fi
# bash
if [[ -f "${HOME}/.bashrc" ]]; then
    if ! grep -q 'fnm env' "${HOME}/.bashrc"; then
        _fnm_bash_conf_file="${_script_path}/config/neovim/fnm_shell_config/config.bash"
        log_info "Add fnm configuration to ${HOME}/.bashrc from ${_fnm_bash_conf_file}"
        exec_cmd "cat \"${_fnm_bash_conf_file}\" >> \"${HOME}/.bashrc\""
    fi
fi

# shellcheck disable=SC1091
source "${CONFIG_PATH}/neovim/fnm_shell_config/config.bash"
_fnm_version="22"
exec_cmd "fnm install ${_fnm_version} && \
    fnm use ${_fnm_version} && \
    fnm alias default ${_fnm_version}"

log_info "node.js version: $(node -v), npm version: $(npm -v)"

log_info "Install packages with 'npm'"
_npm_pkgs=(
    "tree-sitter-cli"
)
for _pkg in "${_npm_pkgs[@]}"; do
    exec_cmd "npm install -g -- \"${_pkg}\""
done


# log_info "Install nvimdots dependencies - other (Latest Release)"
# # rustup component add rust-analyzer
# # cargo/rustc required by sniprun and rustfmt
# curl https://sh.rustup.rs -sSf | sh -s -- -y

log_info "Install nvimdots (Latest Release)"

if [[ ! -d "${HOME}/.cache/nvim" ]]; then
    exec_cmd "mkdir -p \"${HOME}/.cache/nvim\""
fi

# NOTE: enter is use default option
# NOTE: Close directly when enter for the first time. There is a problem with '.cache' path location.
_tmp_nvimdots=""
create_temp_file _tmp_nvimdots "nvimdots_install" "sh"
_nvimdots_url="https://raw.githubusercontent.com/ayamir/nvimdots/HEAD/scripts/install.sh"

if check_pkg_status --exec -- "curl"; then
    exec_cmd "curl -fsSL -o \"${_tmp_nvimdots}\" ${_nvimdots_url} "
elif check_pkg_status --exec -- "wget"; then
    exec_cmd "wget -q -O \"${_tmp_nvimdots}\" ${_nvimdots_url}"
else
    log_fatal "Neither 'curl' nor 'wget' found, cannot download nvimdots install script."
fi
bash "${_tmp_nvimdots}" || true

# NOTE: ERROR List
# go.nvim
# NOTE: WARN list
# codecompanion.nvim

# NOTE: remove lsp_signature.nvim doc tags to avoid error
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

log_info "Please resource you shell source file or open a new terminal, continue to use."
