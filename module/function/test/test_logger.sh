#!/usr/bin/env bash

set -euo pipefail

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    printf "Warn: %s is a executable script, not a library.\n" "${BASH_SOURCE[0]##*/}"
    printf "Please run this file.\n"
    return 0 2>/dev/null
fi

SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "${SCRIPT_PATH}/../logger.sh"

# ----------------------------- Usage -----------------------------
export LOG_COLOR="true"
export LOG_LEVEL="DEBUG"

_color_mode=("false" "true")
_level_mode=("DEBUG" "INFO" "WARN" "ERROR" "FATAL")

echo "${TTY_CLR_RED}TTY_CLR_RED${TTY_CLR_RESET}"
echo "${TTY_BOLD_RED}TTY_BOLD_RED${TTY_CLR_RESET}"
echo "${TTY_CLR_GREEN}TTY_CLR_GREEN${TTY_CLR_RESET}"
echo "${TTY_BOLD_GREEN}TTY_BOLD_GREEN${TTY_CLR_RESET}"
echo "${TTY_CLR_YELLOW}TTY_CLR_YELLOW${TTY_CLR_RESET}"
echo "${TTY_BOLD_YELLOW}TTY_BOLD_YELLOW${TTY_CLR_RESET}"
echo "${TTY_CLR_BLUE}TTY_CLR_BLUE${TTY_CLR_RESET}"
echo "${TTY_BOLD_BLUE}TTY_BOLD_BLUE${TTY_CLR_RESET}"
echo "${TTY_CLR_MAGENTA}TTY_CLR_MAGENTA${TTY_CLR_RESET}"
echo "${TTY_BOLD_MAGENTA}TTY_BOLD_MAGENTA${TTY_CLR_RESET}"
echo "${TTY_CLR_CYAN}TTY_CLR_CYAN${TTY_CLR_RESET}"
echo "${TTY_BOLD_CYAN}TTY_BOLD_CYAN${TTY_CLR_RESET}"
echo "${TTY_CLR_WHITE}TTY_CLR_WHITE${TTY_CLR_RESET}"
echo "${TTY_BOLD_WHITE}TTY_BOLD_WHITE${TTY_CLR_RESET}"
echo ""

for i in "${_color_mode[@]}"; do
    LOG_COLOR="${i}"

    for j in "${_level_mode[@]}"; do
        LOG_LEVEL="${j}"

        printf "\n%sLOG_COLOR=%s, LOG_LEVEL=%s%s\n" "${TTY_BOLD_MAGENTA}" "${LOG_COLOR}" "${LOG_LEVEL}" "${TTY_CLR_RESET}"
        log_debug "This is debug message"
        log_info "This is info message"
        log_warn "This is warn message"
        log_error "This is error message"

        sleep 0.5
    done
done

log_fatal "This is fatal message"
