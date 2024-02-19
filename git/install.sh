#!/usr/bin/env bash

# ${1}: USER NAME

# SCRIPT_PATH=$(dirname "$(readlink -f "${0}")")
# USER_NAME=${1:-"$USER"}

sudo apt update && \
sudo apt install -y --no-install-recommends \
    git \
    git-lfs \
    tig && \
echo -e "\033[1;37;42mGit install successfully.\033[0m" || \
echo -e "\033[1;37;41mGit Install failed.\033[0m"

