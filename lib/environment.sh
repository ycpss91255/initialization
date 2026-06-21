#!/usr/bin/env bash
# lib/environment.sh — the Environment module for init_ubuntu
#
# Per doc/architecture.md §3.3 / §14. One deep module that PROBES the host
# (I/O: reads files / runs commands) and CLASSIFIES a single form_factor
# (pure logic) behind a small public surface. Merges the former
# lib/detect.sh + lib/platform.sh into one layered file.
#
# Internal layering (top → bottom):
#   1. JSON helpers           — assemble / escape JSON without jq.
#   2. _probe_* functions     — I/O layer: read /etc, /proc, run lspci…
#   3. probe assembly         — _environment_probe_json: raw probe document.
#   4. _classify (pure logic) — _environment_classify: derive form_factor
#                               from an already-probed JSON document.
#   5. JSON field extractors  — bash string ops over the assembled JSON.
#   6. Public surface         — environment_snapshot / environment_field.
#   7. Backward-compat aliases — detect_environment / detect_get_field /
#                               platform_classify / platform_export_env.
#
# Public API (the small external surface; callers fetch the snapshot once):
#   environment_snapshot
#     Print ONE JSON object on stdout with the full probe result PLUS the
#     derived form_factor:
#       {os{id,version,codename}, arch, cpu{vendor}, gpu{vendor,model},
#        desktop, session_type, virt{container,vm}, wsl, board, form_factor}
#
#   environment_field <dotted-path> [<snapshot-json>]
#     Print the value at <dotted-path>. If <snapshot-json> is omitted, a
#     fresh snapshot is taken. Recognised paths:
#       os.id os.version os.codename arch cpu.vendor gpu.vendor gpu.model
#       desktop session_type virt.container virt.vm wsl board form_factor
#
# Backward-compat (kept verbatim so existing callers + the `detect`
# subcommand contract stay byte-identical):
#   detect_environment            — raw probe JSON (NO form_factor key)
#   detect_get_field <path>       — field accessor over the raw probe JSON
#   platform_classify [<json>]    — form_factor token
#   platform_export_env [<json>]  — export INIT_UBUNTU_FORM_FACTOR
#
# No jq dependency: JSON is hand-assembled via printf. Field accessors use
# bash string ops on the assembled JSON.

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    printf "Warn: %s is a library, not a executable script.\n" "${BASH_SOURCE[0]##*/}"
    return 0 2>/dev/null
fi

# ── 1. JSON helpers ──────────────────────────────────────────────────────────

_environment_json_escape() {
    local _s="$1"
    _s="${_s//\\/\\\\}"
    _s="${_s//\"/\\\"}"
    _s="${_s//$'\n'/\\n}"
    _s="${_s//$'\r'/\\r}"
    _s="${_s//$'\t'/\\t}"
    printf '%s' "${_s}"
}

_environment_json_str_or_null() {
    local _v="$1"
    if [[ -z "${_v}" ]]; then
        printf 'null'
    else
        printf '"%s"' "$(_environment_json_escape "${_v}")"
    fi
}

_environment_json_bool_or_null() {
    case "${1:-}" in
        true)  printf 'true'  ;;
        false) printf 'false' ;;
        *)     printf 'null'  ;;
    esac
}

# ── 2. _probe_* (I/O layer: read files / run commands) ───────────────────────

_environment_probe_os() {
    local _id="" _ver="" _code=""
    if [[ -f /etc/os-release ]]; then
        local _saved_ID="${ID:-}" _saved_VID="${VERSION_ID:-}" _saved_VCN="${VERSION_CODENAME:-}"
        # shellcheck source=/dev/null  # system file not in repo
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

_environment_probe_arch() {
    uname -m 2>/dev/null || echo ""
}

_environment_probe_cpu_vendor() {
    local _v=""
    if command -v lscpu >/dev/null 2>&1; then
        _v="$(lscpu 2>/dev/null | awk -F: '/^Vendor ID/{gsub(/ /,"",$2); print $2; exit}')"
    fi
    if [[ -z "${_v}" && -r /proc/cpuinfo ]]; then
        _v="$(awk -F: '/^vendor_id/{gsub(/ /,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null)"
    fi
    printf '%s' "${_v}"
}

_environment_probe_gpu() {
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

_environment_probe_desktop() {
    printf '%s' "${XDG_CURRENT_DESKTOP:-}"
}

_environment_probe_session_type() {
    printf '%s' "${XDG_SESSION_TYPE:-}"
}

_environment_probe_container() {
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

_environment_probe_vm() {
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        if systemd-detect-virt --vm --quiet 2>/dev/null; then
            printf 'true'
            return 0
        fi
    fi
    printf 'false'
}

_environment_probe_wsl() {
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

_environment_probe_board() {
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

# ── 3. Probe assembly: raw probe JSON (NO form_factor) ───────────────────────
#
# This is the document shape the ADR-0019-adjacent `detect` contract emits;
# environment_snapshot() splices form_factor onto it. Kept as a private
# helper and re-exposed verbatim as detect_environment() below.

_environment_probe_json() {
    local _os _arch _cpu_vendor _gpu _desktop _session _container _vm _wsl _board
    _os="$(_environment_probe_os)"
    _arch="$(_environment_probe_arch)"
    _cpu_vendor="$(_environment_probe_cpu_vendor)"
    _gpu="$(_environment_probe_gpu)"
    _desktop="$(_environment_probe_desktop)"
    _session="$(_environment_probe_session_type)"
    _container="$(_environment_probe_container)"
    _vm="$(_environment_probe_vm)"
    _wsl="$(_environment_probe_wsl)"
    _board="$(_environment_probe_board)"

    local _os_id="${_os%%|*}"
    local _os_rest="${_os#*|}"
    local _os_ver="${_os_rest%%|*}"
    local _os_code="${_os_rest#*|}"

    local _gpu_vendor="${_gpu%%|*}"
    local _gpu_model="${_gpu#*|}"

    printf '{'
    printf '"os":{"id":%s,"version":%s,"codename":%s},' \
        "$(_environment_json_str_or_null "${_os_id}")" \
        "$(_environment_json_str_or_null "${_os_ver}")" \
        "$(_environment_json_str_or_null "${_os_code}")"
    printf '"arch":%s,' "$(_environment_json_str_or_null "${_arch}")"
    printf '"cpu":{"vendor":%s},' "$(_environment_json_str_or_null "${_cpu_vendor}")"
    printf '"gpu":{"vendor":%s,"model":%s},' \
        "$(_environment_json_str_or_null "${_gpu_vendor}")" \
        "$(_environment_json_str_or_null "${_gpu_model}")"
    printf '"desktop":%s,' "$(_environment_json_str_or_null "${_desktop}")"
    printf '"session_type":%s,' "$(_environment_json_str_or_null "${_session}")"
    printf '"virt":{"container":%s,"vm":%s},' \
        "$(_environment_json_bool_or_null "${_container}")" \
        "$(_environment_json_bool_or_null "${_vm}")"
    printf '"wsl":%s,' "$(_environment_json_bool_or_null "${_wsl}")"
    printf '"board":%s' "$(_environment_json_str_or_null "${_board}")"
    printf '}\n'
}

# ── 5. JSON field extractors (used by the classify + accessor layers) ─────────
#
# These do NOT handle escaped quotes inside string values — but our writer
# only ever embeds escaped \" so the closing-quote scan ("${_val%%\"*}")
# still terminates at the first unescaped quote.

_environment_extract_str() {
    local _json="$1" _anchor="$2"
    local _rest="${_json#*"${_anchor}"}"
    if [[ "${_rest}" == "${_json}" ]]; then
        return 0
    fi
    case "${_rest}" in
        null,*|null\}*|null)
            return 0
            ;;
        \"*)
            local _val="${_rest#\"}"
            _val="${_val%%\"*}"
            printf '%s' "${_val}"
            ;;
    esac
}

_environment_extract_str_after() {
    local _json="$1" _anchor1="$2" _anchor2="$3"
    local _rest="${_json#*"${_anchor1}"}"
    [[ "${_rest}" == "${_json}" ]] && return 0
    _environment_extract_str "${_anchor1}${_rest}" "${_anchor2}"
}

_environment_extract_bool() {
    local _json="$1" _anchor="$2"
    local _rest="${_json#*"${_anchor}"}"
    [[ "${_rest}" == "${_json}" ]] && return 0
    case "${_rest}" in
        true*)  printf 'true' ;;
        false*) printf 'false' ;;
        null*)  return 0 ;;
    esac
}

_environment_extract_bool_after() {
    local _json="$1" _anchor1="$2" _anchor2="$3"
    local _rest="${_json#*"${_anchor1}"}"
    [[ "${_rest}" == "${_json}" ]] && return 0
    _environment_extract_bool "${_anchor1}${_rest}" "${_anchor2}"
}

# ── 4. _classify (pure logic): form_factor from a probed JSON document ────────
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

_environment_classify() {
    local _json="$1"
    local _wsl _container _vm _board _desktop _arch
    _wsl="$(_environment_extract_bool       "${_json}" '"wsl":')"
    _container="$(_environment_extract_bool  "${_json}" '"virt":{"container":')"
    _vm="$(_environment_extract_bool_after   "${_json}" '"virt":{' '"vm":')"
    _board="$(_environment_extract_str      "${_json}" '"board":')"
    _desktop="$(_environment_extract_str    "${_json}" '"desktop":')"
    _arch="$(_environment_extract_str       "${_json}" '"arch":')"

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

# ── 6. Public surface ────────────────────────────────────────────────────────

# environment_snapshot — full probe document PLUS the derived form_factor.
# This is the one call callers (runner, dispatcher) make instead of probing
# and classifying separately. The form_factor is spliced onto the probe JSON
# by replacing the closing '}' (same wire shape the old dispatcher emitted).
environment_snapshot() {
    local _probe _form
    _probe="$(_environment_probe_json)"
    _form="$(_environment_classify "${_probe}")"
    printf '%s,"form_factor":"%s"}\n' "${_probe%\}}" "${_form}"
}

# environment_field <dotted-path> [<snapshot-json>]
#   Field accessor over a snapshot (form_factor-inclusive). Omit the JSON to
#   take a fresh snapshot.
environment_field() {
    local _path="${1:?environment_field needs <dotted-path>}"
    local _json="${2:-}"
    [[ -z "${_json}" ]] && _json="$(environment_snapshot)"
    _environment_field_from "${_json}" "${_path}"
}

# Internal: dotted-path dispatch over an arbitrary env JSON document.
_environment_field_from() {
    local _json="$1" _path="$2"
    case "${_path}" in
        os.id)            _environment_extract_str "${_json}" '"os":{"id":' ;;
        os.version)       _environment_extract_str_after "${_json}" '"os":{' '"version":' ;;
        os.codename)      _environment_extract_str_after "${_json}" '"os":{' '"codename":' ;;
        arch)             _environment_extract_str "${_json}" '"arch":' ;;
        cpu.vendor)       _environment_extract_str "${_json}" '"cpu":{"vendor":' ;;
        gpu.vendor)       _environment_extract_str "${_json}" '"gpu":{"vendor":' ;;
        gpu.model)        _environment_extract_str_after "${_json}" '"gpu":{' '"model":' ;;
        desktop)          _environment_extract_str "${_json}" '"desktop":' ;;
        session_type)     _environment_extract_str "${_json}" '"session_type":' ;;
        virt.container)   _environment_extract_bool "${_json}" '"virt":{"container":' ;;
        virt.vm)          _environment_extract_bool_after "${_json}" '"virt":{' '"vm":' ;;
        wsl)              _environment_extract_bool "${_json}" '"wsl":' ;;
        board)            _environment_extract_str "${_json}" '"board":' ;;
        form_factor)      _environment_extract_str "${_json}" '"form_factor":' ;;
        *)
            printf '[environment] ERROR: unknown field %s\n' "${_path}" >&2
            return 1
            ;;
    esac
}

# ── 7. Backward-compat aliases ───────────────────────────────────────────────
#
# Existing callers + the `detect` subcommand contract keep working. The raw
# (form_factor-free) probe document and its accessor are preserved verbatim;
# the form_factor classifier keeps its old name + no-arg self-probe behavior.

# detect_environment — raw probe JSON, NO form_factor key (contract-stable).
detect_environment() {
    _environment_probe_json
}

# detect_get_field <dotted-path> — accessor over the RAW probe JSON.
detect_get_field() {
    local _path="${1:?detect_get_field needs <dotted-path>}"
    _environment_field_from "$(_environment_probe_json)" "${_path}"
}

# platform_classify [<env-json>] — form_factor token; no-arg self-probes.
platform_classify() {
    local _json="${1:-}"
    if [[ -z "${_json}" ]]; then
        if ! declare -F detect_environment >/dev/null 2>&1; then
            printf '[platform] ERROR: detect_environment not loaded (source lib/environment.sh first)\n' >&2
            return 1
        fi
        _json="$(detect_environment)"
    fi
    _environment_classify "${_json}"
}

# platform_export_env <env-json> — export INIT_UBUNTU_FORM_FACTOR.
# Takes a required <env-json> positional (callers pass "" to self-probe); this
# avoids SC2119/SC2120 on an optional arg without a shellcheck disable.
platform_export_env() {
    local _json="$1"
    INIT_UBUNTU_FORM_FACTOR="$(platform_classify "${_json}")"
    export INIT_UBUNTU_FORM_FACTOR
}
