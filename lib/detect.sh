#!/usr/bin/env bash
# lib/detect.sh — environment probes for init_ubuntu
#
# Per docs/architecture.md §3.3 / §14. Probes the host and emits a JSON
# document describing OS, CPU, GPU, desktop session, virt, WSL, and SBC
# board. Pairs with lib/platform.sh which derives form_factor.
#
# Public API:
#   detect_environment
#     Print one JSON object on stdout with the full probe result.
#
#   detect_get_field <dotted-path>
#     Print the value at <dotted-path> in the JSON. Examples:
#       detect_get_field os.id          # ubuntu
#       detect_get_field arch           # x86_64
#       detect_get_field gpu.vendor     # nvidia / amd / intel / other / (empty)
#       detect_get_field virt.container # true / false
#       detect_get_field wsl            # true / false
#       detect_get_field board          # raspberry-pi-5 / jetson-orin / (empty)
#
# No jq dependency: JSON is hand-assembled via printf. Field accessor
# uses bash string ops on the assembled JSON.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    printf "Warn: %s is a library, not a executable script.\n" "${BASH_SOURCE[0]##*/}"
    return 0 2>/dev/null
fi

# ── JSON helpers ─────────────────────────────────────────────────────────────

_detect_json_escape() {
    local _s="$1"
    _s="${_s//\\/\\\\}"
    _s="${_s//\"/\\\"}"
    _s="${_s//$'\n'/\\n}"
    _s="${_s//$'\r'/\\r}"
    _s="${_s//$'\t'/\\t}"
    printf '%s' "${_s}"
}

_detect_json_str_or_null() {
    local _v="$1"
    if [[ -z "${_v}" ]]; then
        printf 'null'
    else
        printf '"%s"' "$(_detect_json_escape "${_v}")"
    fi
}

_detect_json_bool_or_null() {
    case "${1:-}" in
        true)  printf 'true'  ;;
        false) printf 'false' ;;
        *)     printf 'null'  ;;
    esac
}

# ── Individual probes ───────────────────────────────────────────────────────

_detect_probe_os() {
    local _id="" _ver="" _code=""
    if [[ -f /etc/os-release ]]; then
        local _saved_ID="${ID:-}" _saved_VID="${VERSION_ID:-}" _saved_VCN="${VERSION_CODENAME:-}"
        # shellcheck disable=SC1091
        . /etc/os-release 2>/dev/null || true
        _id="${ID:-}"
        _ver="${VERSION_ID:-}"
        _code="${VERSION_CODENAME:-}"
        # Restore in case caller had its own values.
        ID="${_saved_ID}" VERSION_ID="${_saved_VID}" VERSION_CODENAME="${_saved_VCN}"
    fi
    if [[ -z "${_id}" ]] && command -v lsb_release >/dev/null 2>&1; then
        _id="$(lsb_release -is 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
        _ver="$(lsb_release -rs 2>/dev/null || true)"
        _code="$(lsb_release -cs 2>/dev/null || true)"
    fi
    printf '%s|%s|%s' "${_id}" "${_ver}" "${_code}"
}

_detect_probe_arch() {
    uname -m 2>/dev/null || echo ""
}

_detect_probe_cpu_vendor() {
    local _v=""
    if command -v lscpu >/dev/null 2>&1; then
        _v="$(lscpu 2>/dev/null | awk -F: '/^Vendor ID/{gsub(/ /,"",$2); print $2; exit}')"
    fi
    if [[ -z "${_v}" && -r /proc/cpuinfo ]]; then
        _v="$(awk -F: '/^vendor_id/{gsub(/ /,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null)"
    fi
    printf '%s' "${_v}"
}

_detect_probe_gpu() {
    local _vendor="" _model=""
    if ! command -v lspci >/dev/null 2>&1; then
        printf '|'
        return 0
    fi
    local _line
    _line="$(lspci 2>/dev/null | grep -E '\bVGA\b|\b3D\b' | head -1 || true)"
    if [[ -z "${_line}" ]]; then
        printf '|'
        return 0
    fi
    local _lower="${_line,,}"
    case "${_lower}" in
        *nvidia*) _vendor="nvidia" ;;
        *amd*|*radeon*|*advanced\ micro*) _vendor="amd" ;;
        *intel*) _vendor="intel" ;;
        *) _vendor="other" ;;
    esac
    _model="${_line#*: }"
    printf '%s|%s' "${_vendor}" "${_model}"
}

_detect_probe_desktop() {
    printf '%s' "${XDG_CURRENT_DESKTOP:-}"
}

_detect_probe_session_type() {
    printf '%s' "${XDG_SESSION_TYPE:-}"
}

_detect_probe_container() {
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        if systemd-detect-virt --container --quiet 2>/dev/null; then
            printf 'true'
            return 0
        fi
    fi
    if [[ -f /.dockerenv ]]; then
        printf 'true'
        return 0
    fi
    if [[ -r /proc/1/cgroup ]] && grep -qE '/docker|/lxc/' /proc/1/cgroup 2>/dev/null; then
        printf 'true'
        return 0
    fi
    printf 'false'
}

_detect_probe_vm() {
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        if systemd-detect-virt --vm --quiet 2>/dev/null; then
            printf 'true'
            return 0
        fi
    fi
    printf 'false'
}

_detect_probe_wsl() {
    if [[ -e /proc/sys/fs/binfmt_misc/WSLInterop ]]; then
        printf 'true'
        return 0
    fi
    if [[ -n "${WSL_DISTRO_NAME:-}" ]] || [[ -n "${WSL_INTEROP:-}" ]]; then
        printf 'true'
        return 0
    fi
    if uname -r 2>/dev/null | grep -qiE 'microsoft|wsl' ; then
        printf 'true'
        return 0
    fi
    printf 'false'
}

_detect_probe_board() {
    local _model=""
    if [[ -r /proc/device-tree/model ]]; then
        _model="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)"
    fi
    case "${_model,,}" in
        *"raspberry pi 4"*) printf 'raspberry-pi-4'; return 0 ;;
        *"raspberry pi 5"*) printf 'raspberry-pi-5'; return 0 ;;
    esac
    if [[ -r /etc/nv_tegra_release ]]; then
        printf 'jetson-orin'
        return 0
    fi
    printf ''
}

# ── Public: detect_environment ──────────────────────────────────────────────

detect_environment() {
    local _os _arch _cpu_vendor _gpu _desktop _session _container _vm _wsl _board
    _os="$(_detect_probe_os)"
    _arch="$(_detect_probe_arch)"
    _cpu_vendor="$(_detect_probe_cpu_vendor)"
    _gpu="$(_detect_probe_gpu)"
    _desktop="$(_detect_probe_desktop)"
    _session="$(_detect_probe_session_type)"
    _container="$(_detect_probe_container)"
    _vm="$(_detect_probe_vm)"
    _wsl="$(_detect_probe_wsl)"
    _board="$(_detect_probe_board)"

    local _os_id="${_os%%|*}"
    local _os_rest="${_os#*|}"
    local _os_ver="${_os_rest%%|*}"
    local _os_code="${_os_rest#*|}"

    local _gpu_vendor="${_gpu%%|*}"
    local _gpu_model="${_gpu#*|}"

    printf '{'
    printf '"os":{"id":%s,"version":%s,"codename":%s},' \
        "$(_detect_json_str_or_null "${_os_id}")" \
        "$(_detect_json_str_or_null "${_os_ver}")" \
        "$(_detect_json_str_or_null "${_os_code}")"
    printf '"arch":%s,' "$(_detect_json_str_or_null "${_arch}")"
    printf '"cpu":{"vendor":%s},' "$(_detect_json_str_or_null "${_cpu_vendor}")"
    printf '"gpu":{"vendor":%s,"model":%s},' \
        "$(_detect_json_str_or_null "${_gpu_vendor}")" \
        "$(_detect_json_str_or_null "${_gpu_model}")"
    printf '"desktop":%s,' "$(_detect_json_str_or_null "${_desktop}")"
    printf '"session_type":%s,' "$(_detect_json_str_or_null "${_session}")"
    printf '"virt":{"container":%s,"vm":%s},' \
        "$(_detect_json_bool_or_null "${_container}")" \
        "$(_detect_json_bool_or_null "${_vm}")"
    printf '"wsl":%s,' "$(_detect_json_bool_or_null "${_wsl}")"
    printf '"board":%s' "$(_detect_json_str_or_null "${_board}")"
    printf '}\n'
}

# ── Public: detect_get_field ────────────────────────────────────────────────

detect_get_field() {
    local _path="${1:?detect_get_field needs <dotted-path>}"
    local _json
    _json="$(detect_environment)"

    case "${_path}" in
        os.id)            _detect_extract_str "${_json}" '"os":{"id":' ;;
        os.version)       _detect_extract_str_after "${_json}" '"os":{' '"version":' ;;
        os.codename)      _detect_extract_str_after "${_json}" '"os":{' '"codename":' ;;
        arch)             _detect_extract_str "${_json}" '"arch":' ;;
        cpu.vendor)       _detect_extract_str "${_json}" '"cpu":{"vendor":' ;;
        gpu.vendor)       _detect_extract_str "${_json}" '"gpu":{"vendor":' ;;
        gpu.model)        _detect_extract_str_after "${_json}" '"gpu":{' '"model":' ;;
        desktop)          _detect_extract_str "${_json}" '"desktop":' ;;
        session_type)     _detect_extract_str "${_json}" '"session_type":' ;;
        virt.container)   _detect_extract_bool "${_json}" '"virt":{"container":' ;;
        virt.vm)          _detect_extract_bool_after "${_json}" '"virt":{' '"vm":' ;;
        wsl)              _detect_extract_bool "${_json}" '"wsl":' ;;
        board)            _detect_extract_str "${_json}" '"board":' ;;
        *)
            printf '[detect] ERROR: unknown field %s\n' "${_path}" >&2
            return 1
            ;;
    esac
}

# Inline JSON extractors. These do NOT handle escaped quotes inside string
# values — but our writer only ever embeds escaped \" so the closing-quote
# scan ("${_val%%\"*}") still terminates at the first unescaped quote.

_detect_extract_str() {
    local _json="$1" _anchor="$2"
    local _rest="${_json#*"${_anchor}"}"
    if [[ "${_rest}" == "${_json}" ]]; then
        return 0
    fi
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

_detect_extract_str_after() {
    local _json="$1" _anchor1="$2" _anchor2="$3"
    local _rest="${_json#*"${_anchor1}"}"
    [[ "${_rest}" == "${_json}" ]] && return 0
    _detect_extract_str "${_anchor1}${_rest}" "${_anchor2}"
}

_detect_extract_bool() {
    local _json="$1" _anchor="$2"
    local _rest="${_json#*"${_anchor}"}"
    [[ "${_rest}" == "${_json}" ]] && return 0
    case "${_rest}" in
        true*)  printf 'true' ;;
        false*) printf 'false' ;;
        null*)  return 0 ;;
    esac
}

_detect_extract_bool_after() {
    local _json="$1" _anchor1="$2" _anchor2="$3"
    local _rest="${_json#*"${_anchor1}"}"
    [[ "${_rest}" == "${_json}" ]] && return 0
    _detect_extract_bool "${_anchor1}${_rest}" "${_anchor2}"
}
