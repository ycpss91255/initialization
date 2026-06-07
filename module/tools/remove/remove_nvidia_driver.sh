#!/usr/bin/env bash

INSTALLED_NVIDIA_DRIVER=$(dpkg --get-selections | grep -oP '^nvidia-driver-\d+' | head -1)

pip uninstall -y nvitop

if [ -n "${INSTALLED_NVIDIA_DRIVER}" ]; then
    sudo apt purge -y "${INSTALLED_NVIDIA_DRIVER}"

    # print Success or failure message
    printf "\033[1;37;42mNVIDIA driver purge successfully.\033[0m\n"
fi

