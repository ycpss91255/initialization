#!/usr/bin/env bash

# ${1}: USER NAME

# SCRIPT_PATH=$(dirname "$(readlink -f "${0}")")
# USER_NAME=${1:-"$USER"}

sudo apt purge -y \
    git \
    git-lfs \
    tig && \
echo -e "\033[1;37;42mGit purge successfully.\033[0m" || \
echo -e "\033[1;37;41mGit purge failed.\033[0m"