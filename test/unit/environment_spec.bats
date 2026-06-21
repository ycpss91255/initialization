#!/usr/bin/env bats
# test/unit/environment_spec.bats — lib/environment.sh
#
# Folds the former detect_spec.bats + platform_spec.bats into one spec for
# the merged Environment module. Exercises the public surface
# (environment_snapshot / environment_field) plus the backward-compat
# aliases (detect_environment / detect_get_field / platform_classify /
# platform_export_env), and pins the `detect` subcommand contract.
#
# env-driven probes stage their inputs as `VAR=val run ...` prefixes (not a
# standalone `export`) so the value reaches the bats `run` subshell without
# tripping SC2030/SC2031.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
}

teardown() {
    teardown_test_env
}

_load_environment() {
    # shellcheck source=../../lib/environment.sh
    source "${LIB_DIR}/environment.sh"
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "lib/environment.sh sources without error" {
    run bash -c "source '${LIB_DIR}/environment.sh'"
    assert_success
}

@test "environment_snapshot is defined" {
    run bash -c "source '${LIB_DIR}/environment.sh' && declare -F environment_snapshot"
    assert_success
    assert_output --partial "environment_snapshot"
}

@test "environment_field is defined" {
    run bash -c "source '${LIB_DIR}/environment.sh' && declare -F environment_field"
    assert_success
    assert_output --partial "environment_field"
}

@test "backward-compat aliases are defined" {
    run bash -c "source '${LIB_DIR}/environment.sh' && declare -F detect_environment detect_get_field platform_classify platform_export_env"
    assert_success
    assert_output --partial "detect_environment"
    assert_output --partial "detect_get_field"
    assert_output --partial "platform_classify"
    assert_output --partial "platform_export_env"
}

# ── Snapshot JSON shape ──────────────────────────────────────────────────────

@test "environment_snapshot emits one JSON object on stdout" {
    _load_environment
    run environment_snapshot
    assert_success
    [[ "${output:0:1}" == "{" ]]
    [[ "${output: -1}" == "}" ]]
}

@test "environment_snapshot JSON contains all top-level fields + form_factor" {
    _load_environment
    run environment_snapshot
    assert_success
    assert_output --partial '"os":'
    assert_output --partial '"arch":'
    assert_output --partial '"cpu":'
    assert_output --partial '"gpu":'
    assert_output --partial '"desktop":'
    assert_output --partial '"session_type":'
    assert_output --partial '"virt":'
    assert_output --partial '"wsl":'
    assert_output --partial '"board":'
    assert_output --partial '"form_factor":'
}

@test "environment_snapshot is valid JSON (jq parses it)" {
    _load_environment
    run environment_snapshot
    assert_success
    echo "${output}" | jq -e '.form_factor | length > 0' > /dev/null
}

@test "environment_snapshot os object has id / version / codename" {
    _load_environment
    run environment_snapshot
    assert_success
    assert_output --partial '"os":{"id":'
    assert_output --partial '"version":'
    assert_output --partial '"codename":'
}

@test "environment_snapshot virt object has container / vm bools" {
    _load_environment
    run environment_snapshot
    assert_success
    assert_output --regexp '"virt":\{"container":(true|false|null)'
    assert_output --regexp '"vm":(true|false|null)'
}

@test "environment_snapshot is idempotent (same JSON across two calls)" {
    _load_environment
    local _a _b
    _a="$(environment_snapshot)"
    _b="$(environment_snapshot)"
    [[ "${_a}" == "${_b}" ]]
}

# ── Container detection (running inside the test-tools container) ─────────────

@test "running inside the test-tools container, virt.container is true" {
    _load_environment
    run environment_field virt.container
    assert_success
    assert_output "true"
}

# ── environment_field single-field accessors ─────────────────────────────────

@test "environment_field os.id returns a non-empty string in the container" {
    _load_environment
    run environment_field os.id
    assert_success
    [[ -n "${output}" ]]
}

@test "environment_field arch matches uname -m" {
    _load_environment
    local _expected
    _expected="$(uname -m)"
    run environment_field arch
    assert_success
    [[ "${output}" == "${_expected}" ]]
}

@test "environment_field wsl is true|false (not unset)" {
    _load_environment
    run environment_field wsl
    assert_success
    [[ "${output}" == "true" || "${output}" == "false" ]]
}

@test "environment_field virt.vm is true|false (not unset)" {
    _load_environment
    run environment_field virt.vm
    assert_success
    [[ "${output}" == "true" || "${output}" == "false" ]]
}

@test "environment_field rejects unknown field with exit 1" {
    _load_environment
    run environment_field bogus.path
    assert_failure
}

@test "in test-tools container, board is empty (no SBC marker)" {
    _load_environment
    run environment_field board
    assert_success
    [[ -z "${output}" ]]
}

@test "environment_field reads form_factor off the snapshot" {
    _load_environment
    run environment_field form_factor
    assert_success
    case "${output}" in
        desktop|server|rpi-4|rpi-5|jetson-orin|wsl|container|vm|unknown) :;;
        *) printf "unexpected form_factor: %s\n" "${output}" >&2; return 1 ;;
    esac
}

@test "environment_field accepts a pre-fetched snapshot (no re-probe)" {
    _load_environment
    local _snap
    _snap="$(environment_snapshot)"
    run environment_field arch "${_snap}"
    assert_success
    [[ "${output}" == "$(uname -m)" ]]
}

@test "environment_field cpu.vendor succeeds and contains no spaces" {
    _load_environment
    run environment_field cpu.vendor
    assert_success
    [[ "${output}" != *" "* ]]
}

@test "environment_field os.version matches /etc/os-release VERSION_ID" {
    _load_environment
    [[ -f /etc/os-release ]] || skip "no /etc/os-release in image"
    local _expected
    _expected="$(. /etc/os-release; printf '%s' "${VERSION_ID:-}")"
    run environment_field os.version
    assert_success
    [[ "${output}" == "${_expected}" ]]
}

@test "environment_field os.codename matches /etc/os-release VERSION_CODENAME" {
    _load_environment
    [[ -f /etc/os-release ]] || skip "no /etc/os-release in image"
    local _expected
    _expected="$(. /etc/os-release; printf '%s' "${VERSION_CODENAME:-}")"
    run environment_field os.codename
    assert_success
    [[ "${output}" == "${_expected}" ]]
}

# ── env-driven fields (stage via `VAR=val run ...`) ──────────────────────────

@test "environment_field desktop reflects XDG_CURRENT_DESKTOP" {
    _load_environment
    XDG_CURRENT_DESKTOP="ubuntu:GNOME" run environment_field desktop
    assert_success
    assert_output "ubuntu:GNOME"
}

@test "environment_field desktop is empty when XDG_CURRENT_DESKTOP is unset" {
    _load_environment
    XDG_CURRENT_DESKTOP="" run environment_field desktop
    assert_success
    assert_output ""
}

@test "environment_field session_type reflects XDG_SESSION_TYPE" {
    _load_environment
    XDG_SESSION_TYPE="wayland" run environment_field session_type
    assert_success
    assert_output "wayland"
}

@test "WSL env marker (WSL_DISTRO_NAME) flips wsl to true" {
    _load_environment
    [[ -e /proc/sys/fs/binfmt_misc/WSLInterop ]] && skip "real WSL host"
    WSL_DISTRO_NAME="Ubuntu" run environment_field wsl
    assert_success
    assert_output "true"
}

@test "environment_snapshot JSON-escapes double quotes in env-sourced values" {
    _load_environment
    XDG_CURRENT_DESKTOP='Weird"Desk' run environment_snapshot
    assert_success
    assert_output --partial '"desktop":"Weird\"Desk"'
}

# ── GPU probe classification (lspci stubbed on PATH) ────────────────────────

_stub_lspci() {
    local _stubdir="${INIT_UBUNTU_TEST_SCRATCH}/stubs"
    mkdir -p "${_stubdir}"
    printf '#!/usr/bin/env bash\necho "%s"\n' "$1" > "${_stubdir}/lspci"
    chmod +x "${_stubdir}/lspci"
    printf '%s' "${_stubdir}"
}

@test "gpu.vendor classifies an NVIDIA VGA line as nvidia" {
    _load_environment
    local _stub
    _stub="$(_stub_lspci "01:00.0 VGA compatible controller: NVIDIA Corporation AD102 [GeForce RTX 4090]")"
    PATH="${_stub}:${PATH}" run environment_field gpu.vendor
    assert_success
    assert_output "nvidia"
}

@test "gpu.model carries the lspci description after the vendor split" {
    _load_environment
    local _stub
    _stub="$(_stub_lspci "01:00.0 VGA compatible controller: NVIDIA Corporation AD102 [GeForce RTX 4090]")"
    PATH="${_stub}:${PATH}" run environment_field gpu.model
    assert_success
    assert_output --partial "NVIDIA Corporation AD102"
}

@test "gpu.vendor classifies an AMD VGA line as amd" {
    _load_environment
    local _stub
    _stub="$(_stub_lspci "03:00.0 VGA compatible controller: Advanced Micro Devices, Inc. [AMD/ATI] Navi 31")"
    PATH="${_stub}:${PATH}" run environment_field gpu.vendor
    assert_success
    assert_output "amd"
}

@test "gpu.vendor falls back to other for unrecognized VGA vendors" {
    _load_environment
    local _stub
    _stub="$(_stub_lspci "02:00.0 VGA compatible controller: Matrox Electronics Systems Ltd. MGA G200e")"
    PATH="${_stub}:${PATH}" run environment_field gpu.vendor
    assert_success
    assert_output "other"
}

@test "gpu.vendor is empty when lspci shows no VGA/3D device" {
    _load_environment
    local _stub
    _stub="$(_stub_lspci "00:1f.3 Audio device: Intel Corporation Cannon Lake PCH cAVS")"
    PATH="${_stub}:${PATH}" run environment_field gpu.vendor
    assert_success
    assert_output ""
}

# ── form_factor classification: fixture JSON drives each branch ──────────────
#
# These pin the internal _classify logic via the documented JSON-in entry
# point platform_classify (the no-probe compat path).

@test "WSL beats container even when both are signalled" {
    _load_environment
    local _json='{"os":{"id":"ubuntu","version":"24.04","codename":"noble"},"arch":"x86_64","cpu":{"vendor":"GenuineIntel"},"gpu":{"vendor":null,"model":null},"desktop":null,"session_type":null,"virt":{"container":true,"vm":false},"wsl":true,"board":null}'
    run platform_classify "${_json}"
    assert_success
    assert_output "wsl"
}

@test "container wins over vm" {
    _load_environment
    local _json='{"os":{"id":"ubuntu","version":"24.04","codename":"noble"},"arch":"x86_64","cpu":{"vendor":"GenuineIntel"},"gpu":{"vendor":null,"model":null},"desktop":null,"session_type":null,"virt":{"container":true,"vm":true},"wsl":false,"board":null}'
    run platform_classify "${_json}"
    assert_success
    assert_output "container"
}

@test "vm classifies as vm when not container/wsl" {
    _load_environment
    local _json='{"os":{"id":"ubuntu","version":"24.04","codename":"noble"},"arch":"x86_64","cpu":{"vendor":"GenuineIntel"},"gpu":{"vendor":null,"model":null},"desktop":null,"session_type":null,"virt":{"container":false,"vm":true},"wsl":false,"board":null}'
    run platform_classify "${_json}"
    assert_success
    assert_output "vm"
}

@test "raspberry-pi-4 board -> rpi-4" {
    _load_environment
    local _json='{"os":{"id":"ubuntu","version":"24.04","codename":"noble"},"arch":"aarch64","cpu":{"vendor":"ARM"},"gpu":{"vendor":null,"model":null},"desktop":null,"session_type":null,"virt":{"container":false,"vm":false},"wsl":false,"board":"raspberry-pi-4"}'
    run platform_classify "${_json}"
    assert_success
    assert_output "rpi-4"
}

@test "raspberry-pi-5 board -> rpi-5" {
    _load_environment
    local _json='{"os":{"id":"ubuntu","version":"24.04","codename":"noble"},"arch":"aarch64","cpu":{"vendor":"ARM"},"gpu":{"vendor":null,"model":null},"desktop":null,"session_type":null,"virt":{"container":false,"vm":false},"wsl":false,"board":"raspberry-pi-5"}'
    run platform_classify "${_json}"
    assert_success
    assert_output "rpi-5"
}

@test "jetson-orin board -> jetson-orin" {
    _load_environment
    local _json='{"os":{"id":"ubuntu","version":"22.04","codename":"jammy"},"arch":"aarch64","cpu":{"vendor":"ARM"},"gpu":{"vendor":"nvidia","model":"Tegra"},"desktop":null,"session_type":null,"virt":{"container":false,"vm":false},"wsl":false,"board":"jetson-orin"}'
    run platform_classify "${_json}"
    assert_success
    assert_output "jetson-orin"
}

@test "non-empty desktop + no SBC + bare-metal -> desktop" {
    _load_environment
    local _json='{"os":{"id":"ubuntu","version":"24.04","codename":"noble"},"arch":"x86_64","cpu":{"vendor":"GenuineIntel"},"gpu":{"vendor":"nvidia","model":"RTX 4090"},"desktop":"GNOME","session_type":"x11","virt":{"container":false,"vm":false},"wsl":false,"board":null}'
    run platform_classify "${_json}"
    assert_success
    assert_output "desktop"
}

@test "empty desktop + x86_64 + bare-metal -> server" {
    _load_environment
    local _json='{"os":{"id":"ubuntu","version":"24.04","codename":"noble"},"arch":"x86_64","cpu":{"vendor":"GenuineIntel"},"gpu":{"vendor":null,"model":null},"desktop":null,"session_type":null,"virt":{"container":false,"vm":false},"wsl":false,"board":null}'
    run platform_classify "${_json}"
    assert_success
    assert_output "server"
}

@test "empty desktop + aarch64 + bare-metal -> server" {
    _load_environment
    local _json='{"os":{"id":"ubuntu","version":"24.04","codename":"noble"},"arch":"aarch64","cpu":{"vendor":"ARM"},"gpu":{"vendor":null,"model":null},"desktop":null,"session_type":null,"virt":{"container":false,"vm":false},"wsl":false,"board":null}'
    run platform_classify "${_json}"
    assert_success
    assert_output "server"
}

@test "exotic arch + no desktop -> unknown" {
    _load_environment
    local _json='{"os":{"id":"ubuntu","version":"24.04","codename":"noble"},"arch":"riscv64","cpu":{"vendor":null},"gpu":{"vendor":null,"model":null},"desktop":null,"session_type":null,"virt":{"container":false,"vm":false},"wsl":false,"board":null}'
    run platform_classify "${_json}"
    assert_success
    assert_output "unknown"
}

# ── platform_export_env (compat) ─────────────────────────────────────────────

@test "platform_export_env exports INIT_UBUNTU_FORM_FACTOR" {
    _load_environment
    local _json='{"os":{"id":"ubuntu","version":"24.04","codename":"noble"},"arch":"x86_64","cpu":{"vendor":"GenuineIntel"},"gpu":{"vendor":null,"model":null},"desktop":"GNOME","session_type":"x11","virt":{"container":false,"vm":false},"wsl":false,"board":null}'
    platform_export_env "${_json}"
    [[ "${INIT_UBUNTU_FORM_FACTOR}" == "desktop" ]]
}

@test "platform_classify with no arg falls back to a self-probe" {
    _load_environment
    run platform_classify
    assert_success
    case "${output}" in
        desktop|server|rpi-4|rpi-5|jetson-orin|wsl|container|vm|unknown) :;;
        *) printf "unexpected form_factor: %s\n" "${output}" >&2; return 1 ;;
    esac
}

# ── backward-compat: detect_environment / detect_get_field shape ─────────────

@test "detect_environment emits the raw probe JSON WITHOUT form_factor" {
    _load_environment
    run detect_environment
    assert_success
    [[ "${output:0:1}" == "{" ]]
    [[ "${output: -1}" == "}" ]]
    [[ "${output}" != *'"form_factor"'* ]]
}

@test "detect_get_field arch matches uname -m (compat path)" {
    _load_environment
    run detect_get_field arch
    assert_success
    [[ "${output}" == "$(uname -m)" ]]
}

# ── Golden contract: `detect` subcommand output is unchanged ─────────────────
#
# The `detect --json` wire shape is an ADR-0019-adjacent contract the TUI +
# agents parse. It must equal environment_snapshot() byte-for-byte, and stay
# the documented {probe...,"form_factor":"X"} shape.

_load_engine_for_detect() {
    # shellcheck source=../../lib/logger.sh
    source "${LIB_DIR}/logger.sh"
    # shellcheck source=../../lib/color.sh
    source "${LIB_DIR}/color.sh"
    # shellcheck source=../../lib/general.sh
    source "${LIB_DIR}/general.sh"
    # shellcheck source=../../lib/i18n.sh
    source "${LIB_DIR}/i18n.sh"
    # shellcheck source=../../lib/environment.sh
    source "${LIB_DIR}/environment.sh"
    # shellcheck source=../../lib/dispatcher.sh
    source "${LIB_DIR}/dispatcher.sh"
}

@test "GOLDEN: detect --json equals environment_snapshot() byte-for-byte" {
    _load_engine_for_detect
    local _direct _via_cmd
    _direct="$(environment_snapshot)"
    _via_cmd="$(dispatcher_dispatch detect --json)"
    [[ "${_via_cmd}" == "${_direct}" ]]
}

@test "GOLDEN: detect --json is valid JSON with the contract keys" {
    _load_engine_for_detect
    run dispatcher_dispatch detect --json
    assert_success
    echo "${output}" | jq -e '
        has("os") and (.os | has("id") and has("version") and has("codename"))
        and (.arch | type) == "string"
        and (.cpu | has("vendor"))
        and (.gpu | has("vendor") and has("model"))
        and (.virt | has("container") and has("vm"))
        and has("wsl") and has("board")
        and (.form_factor | type) == "string"
    ' > /dev/null
}

@test "GOLDEN: detect (human) prints the fixed key order incl. form_factor" {
    _load_engine_for_detect
    run dispatcher_dispatch detect
    assert_success
    assert_line --index 0 "----- init_ubuntu environment ------"
    assert_output --partial "os.id:"
    assert_output --partial "os.version:"
    assert_output --partial "os.codename:"
    assert_output --partial "arch:"
    assert_output --partial "cpu.vendor:"
    assert_output --partial "gpu.vendor:"
    assert_output --partial "gpu.model:"
    assert_output --partial "desktop:"
    assert_output --partial "session_type:"
    assert_output --partial "virt.container:"
    assert_output --partial "virt.vm:"
    assert_output --partial "wsl:"
    assert_output --partial "board:"
    assert_output --partial "form_factor:"
}
