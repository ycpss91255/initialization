#!/usr/bin/env bash

# ${1}: USER NAME. Use the provided username, or default to the current user ($USER).

# SCRIPT_PATH=$(dirname "$(readlink -f "${0}")")
USER_NAME=${1:-"$USER"}

# purge 'XXX' related packages
sudo snap remove nvim

# Remove 'XXX' related files

sudo rm /usr/local/bin/lazygit \
    && \

rustup self uninstall && \

rm -rf /home/"${USER_NAME}"/.config/nvim && \

# print Success or failure message
printf "\033[1;37;42mXXX purge successfully.\033[0m" || \
printf "\033[1;37;41mXXX purge failed.\033[0m"
