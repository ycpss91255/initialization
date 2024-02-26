#!/usr/bin/env bash

# ${1}: USER NAME. Use the provided username, or default to the current user ($USER).

SCRIPT_PATH=$(dirname "$(readlink -f "${0}")")
USER_NAME=${1:-"$USER"}

LAZYGIT_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | grep -Po '"tag_name": "v\K[^"]*')

# Update the package lists
sudo apt update && \

# Install required packages for 'XXX'
sudo apt install -y --no-install-recommends \
    clang \
    curl \
    fd-find \
    gcc \
    git \
    g++ \
    lldb \
    make \
    npm \
    python3 \
    python3-pip \
    python3-venv \
    ripgrep \
    snapd \
    unzip \
    yarn \
    zoxide \
    && \

# Install 'neovim' with 'snap'
sudo snap install snapd && \
sudo nvim --classic && \

# Install 'lazygit'
curl -Lo lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz" && \
tar xf lazygit.tar.gz lazygit && \
sudo install lazygit /usr/local/bin && \
rm -rf lazygit lazygit.tar.gz && \

# nvm
if dpkg -l | grep -q "fish" ; then
    if fish -c "type -q 'fisher'"; then
        fish -c "curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish \
        | source && fisher install jorgebucaran/fisher"
    fi

    # Install 'zoxide' and 'nvm'
    fish -c "fisher install \
        kidonng/zoxide.fish \
        jorgebucaran/nvm.fish && \
    nvm install 18 && \
    nvm use 18"
fi

if dpkg -l |grep -q "bash"; then
    curl https://raw.githubusercontent.com/creationix/nvm/master/install.sh | bash
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
    nvm install 18
    nvm use 18
fi

curl https://sh.rustup.rs -sSf | sh && \

if command -v curl >/dev/null 2>&1; then
    bash -c "$(curl -fsSL https://raw.githubusercontent.com/ayamir/nvimdots/HEAD/scripts/install.sh)"
else
    bash -c "$(wget -O- https://raw.githubusercontent.com/ayamir/nvimdots/HEAD/scripts/install.sh)"
fi

cp -r "${SCRIPT_PATH}/config" "/home/${USER_NAME}/.config/nvim/lua/user" && \

# print success or failure message
# printf "\033[1;37;42mXXX install successfully.\033[0m" || \
# printf "\033[1;37;41mxxx install failed.\033[0m"
