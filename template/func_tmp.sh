#!/usr/bin/env bash

set -euo pipefail

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    printf "Warn: %s is a library, not a executable script.\n" "${BASH_SOURCE[0]##*/}"
    printf "To learn how to use it, please refer to './test/test_logger.sh'\n"
    return 0 2>/dev/null
fi
