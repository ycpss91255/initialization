#!/usr/bin/env bash

set -euo pipefail

MAIN_FILE="true"; [[ "${BASH_SOURCE[0]}" != "${0}" ]] && MAIN_FILE="false"

if [[ "${MAIN_FILE}" == "false" ]]; then
    # script
    printf "Warn: %s is a executable script, not a library.\n" "${BASH_SOURCE[0]##*/}"
    printf "Please run this file.\n"
    return 0 2>/dev/null
fi

SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
export FUNCTION_PATH="${SCRIPT_PATH}/../function"
export CONFIG_PATH="${SCRIPT_PATH}/../../config"

:
