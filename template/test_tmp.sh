#!/usr/bin/env bash

set -euo pipefail

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    printf "Warn: %s is a executable script, not a library.\n" "${BASH_SOURCE[0]##*/}"
    printf "Please run this file.\n"
    return 0 2>/dev/null
fi

SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
# source "${SCRIPT_PATH}/../logger.sh"

# log_info "This is a test log from test.sh"

:
