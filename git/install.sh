#!/usr/bin/env bash

# ${1}: USER NAME. Use the provided username, or default to the current user ($USER).

# SCRIPT_PATH=$(dirname "$(readlink -f "${0}")")
# USER_NAME=${1:-"$USER"}

# Update the package lists
sudo apt update && \

# Install required packages for Git installation
sudo apt install -y --no-install-recommends \
    git \
    git-lfs \
    tig && \

# echo Success or failure message
echo -e "\033[1;37;42mGit install successfully.\033[0m" || \
echo -e "\033[1;37;41mGit Install failed.\033[0m"

