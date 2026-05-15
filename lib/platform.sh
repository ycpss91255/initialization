#!/usr/bin/env bash
# lib/platform.sh — derive form_factor from lib/detect.sh output
#
# Per doc/architecture.md §14. Reads the JSON environment description
# produced by detect_environment() and returns a single form_factor token:
#
#   desktop / server / rpi-4 / rpi-5 / jetson-orin / wsl / container / vm
#   / unknown
#
# Priority (most specific wins):
#   1. wsl       — even if systemd-detect-virt says "container", WSL is its
#                  own platform and pre-empts the container bucket
#   2. container — systemd-detect-virt --container OR /.dockerenv
#   3. vm        — systemd-detect-virt --vm
#   4. rpi-4 / rpi-5 / jetson-orin — SBC boards
#   5. desktop   — XDG_CURRENT_DESKTOP non-empty
#   6. server    — empty desktop + recognised arch (x86_64 / aarch64) + no SBC
#   7. unknown   — nothing matched
#
# Public API:
#   platform_classify [<env-json>]
#     If <env-json> is given, classify that exact JSON. Otherwise calls
#     detect_environment from lib/detect.sh (which must be sourced first).
#     Prints the form_factor token on stdout.
#
#   platform_export_env [<env-json>]
#     Convenience: classify and export INIT_UBUNTU_FORM_FACTOR.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    printf "Warn: %s is a library, not a executable script.\n" "${BASH_SOURCE[0]##*/}"
    return 0 2>/dev/null
fi

# ── JSON field extractor (self-contained; platform.sh can run without
#    lib/detect.sh sourced as long as the caller passes the JSON directly) ─

_platform_extract_str() {
    local _json="$1" _anchor="$2"
    local _rest="${_json#*"${_anchor}"}"
    [[ "${_rest}" == "${_json}" ]] && return 0
    case "${_rest}" in
        null,*|null}*|null)
            return 0
            ;;
        \"*)
            local _val="${_rest#\"}"
            _val="${_val%%\"*}"
            printf '%s' "${_val}"
            ;;
    esac
}

_platform_extract_bool() {
    local _json="$1" _anchor="$2"
    local _rest="${_json#*"${_anchor}"}"
    [[ "${_rest}" == "${_json}" ]] && return 0
    case "${_rest}" in
        true*)  printf 'true' ;;
        false*) printf 'false' ;;
    esac
}

_platform_extract_bool_after() {
    local _json="$1" _anchor1="$2" _anchor2="$3"
    local _rest="${_json#*"${_anchor1}"}"
    [[ "${_rest}" == "${_json}" ]] && return 0
    _platform_extract_bool "${_anchor1}${_rest}" "${_anchor2}"
}

# ── Public: platform_classify ───────────────────────────────────────────────

platform_classify() {
    local _json="${1:-}"
    if [[ -z "${_json}" ]]; then
        if ! declare -F detect_environment >/dev/null 2>&1; then
            printf '[platform] ERROR: detect_environment not loaded (source lib/detect.sh first)\n' >&2
            return 1
        fi
        _json="$(detect_environment)"
    fi

    local _wsl _container _vm _board _desktop _arch
    _wsl="$(_platform_extract_bool      "${_json}" '"wsl":')"
    _container="$(_platform_extract_bool "${_json}" '"virt":{"container":')"
    _vm="$(_platform_extract_bool_after  "${_json}" '"virt":{' '"vm":')"
    _board="$(_platform_extract_str     "${_json}" '"board":')"
    _desktop="$(_platform_extract_str   "${_json}" '"desktop":')"
    _arch="$(_platform_extract_str      "${_json}" '"arch":')"

    # 1. WSL wins over container / vm.
    if [[ "${_wsl}" == "true" ]]; then
        printf 'wsl'
        return 0
    fi

    # 2. container
    if [[ "${_container}" == "true" ]]; then
        printf 'container'
        return 0
    fi

    # 3. vm
    if [[ "${_vm}" == "true" ]]; then
        printf 'vm'
        return 0
    fi

    # 4. SBC boards (Pi / Jetson)
    case "${_board}" in
        raspberry-pi-4)  printf 'rpi-4';       return 0 ;;
        raspberry-pi-5)  printf 'rpi-5';       return 0 ;;
        jetson-orin)     printf 'jetson-orin'; return 0 ;;
    esac

    # 5. desktop — any non-empty XDG_CURRENT_DESKTOP counts.
    if [[ -n "${_desktop}" ]]; then
        printf 'desktop'
        return 0
    fi

    # 6. server — recognised arch + no SBC + no desktop.
    case "${_arch}" in
        x86_64|aarch64|arm64) printf 'server'; return 0 ;;
    esac

    # 7. give up
    printf 'unknown'
}

# ── Public: platform_export_env ─────────────────────────────────────────────

platform_export_env() {
    INIT_UBUNTU_FORM_FACTOR="$(platform_classify "${1:-}")"
    export INIT_UBUNTU_FORM_FACTOR
}
