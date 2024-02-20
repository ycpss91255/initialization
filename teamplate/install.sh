#!/usr/bin/env bash

# ${1}: USER NAME. Use the provided username, or default to the current user ($USER).

# SCRIPT_PATH=$(dirname "$(readlink -f "${0}")")
# USER_NAME=${1:-"$USER"}

# Update the package lists
sudo apt update && \

# Install required packages for 'XXX'
sudo apt install -y --no-install-recommends \
    && \

# echo Success or failure message
echo -e "\033[1;37;42mXXX install successfully.\033[0m" || \
echo -e "\033[1;37;41mXXX Install failed.\033[0m"
