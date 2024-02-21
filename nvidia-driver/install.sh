#!/usr/bin/env bash

# ${1}: USER NAME. Use the provided username, or default to the current user ($USER).

# SCRIPT_PATH=$(dirname "$(readlink -f "${0}")")
# USER_NAME=${1:-"$USER"}


# Update the package lists
sudo apt update && \

# Install required packages for 'XXX'
sudo apt install -y --no-install-recommends \
    software-properties-common \
    ubuntu-drivers-common \
    gnupg-agent \
    python3 \
    python3-pip \
    && \
sudo add-apt-repository -y ppa:graphics-drivers/ppa && \

# Update pip and setuptools
pip install -U pip setuptools && \

# Install 'nvitop'
pip install git+https://github.com/XuehaiPan/nvitop.git#egg=nvitop && \

INSTALLED_NVIDIA_DRIVER=$(dpkg --get-selections | grep -oP '^nvidia-driver-\d+' | head -1)
RECOMMENDED_NVIDIA_DRIVER=$(ubuntu-drivers devices | grep 'recommended' | awk '{print $3}')

# Check if the recommended NVIDIA driver not found
if [ -z "${RECOMMENDED_NVIDIA_DRIVER}" ]; then
    printf "\033[1;37;41mNVIDIA driver recommend version not found.\033[0m\n"
    printf "Please use 'ubuntu-drivers devices' check the recommended drivers and try again.\n"
    exit 1

# if the installed NVIDIA driver not equal to the recommended NVIDIA driver
elif [ "${INSTALLED_NVIDIA_DRIVER}" != "${RECOMMENDED_NVIDIA_DRIVER}" ]; then
    if (lspci | grep -q 'VGA.*NVIDIA'); then
        # purge old NVIDIA driver and install the recommended NVIDIA driver
        sudo apt purge -y "${INSTALLED_NVIDIA_DRIVER}" && \
        sudo apt install -y --no-install-recommends "${RECOMMENDED_NVIDIA_DRIVER}" && \

        # print Success or failure message
        printf "\033[1;37;42mNVIDIA driver dependencies install successfully.\033[0m\n" || \
        printf "\033[1;37;41mNVIDIA driver dependencies Install failed.\033[0m\n"
    fi

# if the installed NVIDIA driver equal to the recommended NVIDIA driver
else
    printf "\033[1;37;42mNVIDIA driver dependencies install successfully.\033[0m\n"
fi
