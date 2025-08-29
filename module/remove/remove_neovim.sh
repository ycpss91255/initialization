#!/usr/bin/env bash

# ${1}: USER NAME. Use the provided username, or default to the current user ($USER).

USER_NAME=${1:-"$USER"}

USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6 || true)"
if [[ -z "${USER_HOME}" || ! -d "${USER_HOME}" ]]; then
    echo "User home directory for '${USER_NAME}' not found."
    exit 1
fi

echo "==> Remove Neovim (Github Releases)"
sudo rm -rf /opt/nvim /usr/local/bin/nvim

rm -rf "${USER_HOME}"/.config/nvim "${USER_HOME}"/.local/share/nvim

echo "==> Remove nvimdots dependencies - lazygit"
sudo rm -rf /usr/local/bin/lazygit

echo "==> Install nvimdots dependencies - nvm"
# shell used fish
if dpkg -l | awk '/^ii/ && $2=="fish" {found=1} END {exit !found}';then
    if fish -c "type -q fisher"; then
        fish -c "fisher remove jorgebucaran/nvm.fish"
    fi
fi
rm -rf "${USER_HOME}/.nvm"

echo "==> Install nvimdots dependencies - other (Latest Release)"

# Install 'tree-sitter' with 'npm'
sudo npm remove -g tree-sitter-cli

if [ -f "${USER_HOME}/.cargo/bin/rustup" ]; then
    bash -c "${USER_HOME}.cargo/bin/rustup self uninstall -y"
fi

echo -e "\033[1;37;42mNvim and Nvimdots removal finished.\033[0m"
