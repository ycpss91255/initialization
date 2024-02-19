#!/usr/bin/env bash

# ${1}: USER NAME

# SCRIPT_PATH=$(dirname "$(readlink -f "${0}")")
# USER_NAME=${1:-"$USER"}

sudo apt update && \
sudo apt install -y --no-install-recommends \
    git \
    git-lfs \
    tig && \
echo "
