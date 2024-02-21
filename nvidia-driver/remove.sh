#!/usr/bin/env bash

# ${1}: USER NAME. Use the provided username, or default to the current user ($USER).

# SCRIPT_PATH=$(dirname "$(readlink -f "${0}")")
# USER_NAME=${1:-"$USER"}

INSTALLED_NVIDIA_DRIVER=$(dpkg --get-selections | grep -oP '^nvidia-driver-\d+' | head -1)

pip uninstall -y nvitop

if [ -n "${INSTALLED_NVIDIA_DRIVER}" ]; then
    sudo apt purge -y "${INSTALLED_NVIDIA_DRIVER}" && \

    # print Success or failure message
    printf "\033[1;37;42mXXX purge successfully.\033[0m\n" || \
    printf "\033[1;37;41mXXX purge failed.\033[0m\n"
fi

