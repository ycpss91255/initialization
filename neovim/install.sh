#!/usr/bin/env bash

set -euo pipefail

USER_NAME=${1:-"$USER"}

USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6 || true)"
if [[ -z "${USER_HOME}" || ! -d "${USER_HOME}" ]]; then
    echo "User home directory for '${USER_NAME}' not found."
    exit 1
fi

SCRIPT_PATH=$(dirname "$(readlink -f "${0}")")

echo "==> Install apt basic dependencies"
sudo apt update && \
sudo apt install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    ripgrep \
    fd-find \
    unzip \
    build-essential \
    clang \
    g++ \
    gcc \
    make \
    cmake \
    lldb \
    python3 \
    python3-pip \
    python3-venv \
    zoxide \
    jq \
    yarn

echo "==> Install Neovim (Github Releases)"
TMP_NVIM="$(mktemp -t nvim_XXXXXX.tar.gz)"
NVIM_VERSION="$(
    curl -fsSL "https://api.github.com/repos/neovim/neovim/releases/latest" \
    | jq -r .tag_name | sed 's/v//'
)"
curl -fsSL -o "${TMP_NVIM}" \
    https://github.com/neovim/neovim/releases/download/v${NVIM_VERSION}/nvim-linux-x86_64.tar.gz
sudo rm -rf /opt/nvim
sudo tar -C /opt -xzf "${TMP_NVIM}"
sudo mv /opt/nvim-linux-x86_64 /opt/nvim
sudo ln -sf /opt/nvim/bin/nvim /usr/local/bin/nvim
# rm -f /usr/local/bin/nvim

# https://github.com/ayamir/nvimdots/wiki/Prerequisites
echo "==> Install nvimdots dependencies - lazygit (Latest Release)"
TMP_LAZYGIT="$(mktemp -t lazygit_XXXXXX.tar.gz)"
LAZYGIT_VERSION="$(
    curl -fsSL "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" \
    | jq -r .tag_name | sed 's/v//'
)"
curl -fsSL -o "${TMP_LAZYGIT}" https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz
tar -C /tmp -zxf "${TMP_LAZYGIT}" lazygit
sudo install /tmp/lazygit /usr/local/bin

echo "==> Install nvimdots dependencies - nvm"
# shell used fish
if dpkg -l | awk '/^ii/ && $2=="fish" {found=1} END {exit !found}';then
    if ! fish -c "type -q fisher"; then
        fish -c "
        curl -fsSL \
            https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish \
        | source && fisher install jorgebucaran/fisher
        "
    fi

    # Install 'zoxide' and 'nvm'
    fish -c "
        fisher install \
            kidonng/zoxide.fish \
            jorgebucaran/nvm.fish && \
        nvm install 18 && nvm use 18
    "
else
    curl -fsSL https://raw.githubusercontent.com/creationix/nvm/master/install.sh | bash
    nvm install 18
    nvm use 18

    # export NVM_DIR="$HOME/.nvm"
    # [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    # [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
fi

echo "==> Install nvimdots dependencies - other (Latest Release)"

# Install 'tree-sitter' with 'npm'
sudo npm install -g tree-sitter-cli

curl https://sh.rustup.rs -sSf | sh -s -- -y

# rustup component add rust-analyzer

echo "==> Install nvimdots (Latest Release)"
if command -v curl >/dev/null 2>&1; then
    bash -c "$(curl -fsSL https://raw.githubusercontent.com/ayamir/nvimdots/HEAD/scripts/install.sh)"
else
    bash -c "$(wget -O- https://raw.githubusercontent.com/ayamir/nvimdots/HEAD/scripts/install.sh)"
fi
USER_CONF_DIR="${USER_HOME}/.config/nvim/lua"
TARGET_USER_DIR="${USER_CONF_DIR}/user"

mkdir -p "${USER_CONF_DIR}"

if [ -e "${TARGET_USER_DIR}" ]; then
    rm -rf "${TARGET_USER_DIR}"
fi
cp -r "${SCRIPT_PATH}/config" "${TARGET_USER_DIR}"

echo -e "\033[1;37;42mNvim and Nvimdots install finished.\033[0m"
