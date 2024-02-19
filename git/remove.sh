#!/usr/bin/env bash

# ${1}: USER NAME

SCRIPT_PATH=$(dirname "$(readlink -f "${0}")")
USER_NAME=${1:-"$USER"}

sudo apt purge -y \
    git \
    git-lfs \
    tig && \
