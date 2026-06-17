#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats `@test`/`run` run in a subshell; test bodies `export XDG_CURRENT_DESKTOP/XDG_SESSION_TYPE/WSL_DISTRO_NAME=...` inside that subshell to stage env for detect_get_field (same rationale as i18n_spec.bats) — https://www.shellcheck.net/wiki/SC2030
# test/unit/detect_spec.bats — lib/detect.sh

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
}

teardown() {
    teardown_test_env
}

_load_detect() {
    # shellcheck source=../../lib/detect.sh
    source "${LIB_DIR}/detect.sh"
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "lib/detect.sh sources without error" {
    run bash -c "source '${LIB_DIR}/detect.sh'"
    assert_success
}

@test "detect_environment is defined" {
    run bash -c "source '${LIB_DIR}/detect.sh' && declare -F detect_environment"
    assert_success
    assert_output --partial "detect_environment"
}

@test "detect_get_field is defined" {
    run bash -c "source '${LIB_DIR}/detect.sh' && declare -F detect_get_field"
    assert_success
    assert_output --partial "detect_get_field"
}

# ── JSON shape ───────────────────────────────────────────────────────────────

@test "detect_environment emits one JSON object on stdout" {
    _load_detect
    run detect_environment
    assert_success
    [[ "${output:0:1}" == "{" ]]
    [[ "${output: -1}" == "}" ]]
}

@test "detect_environment JSON contains all top-level fields" {
    _load_detect
    run detect_environment
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
}

@test "detect_environment os object has id / version / codename" {
    _load_detect
    run detect_environment
    assert_success
    assert_output --partial '"os":{"id":'
    assert_output --partial '"version":'
    assert_output --partial '"codename":'
}

@test "detect_environment virt object has container / vm bools" {
    _load_detect
    run detect_environment
    assert_success
    assert_output --regexp '"virt":\{"container":(true|false|null)'
    assert_output --regexp '"vm":(true|false|null)'
}

# ── Container detection ──────────────────────────────────────────────────────

@test "running inside the test-tools container, virt.container is true" {
    _load_detect
    run detect_get_field virt.container
    assert_success
    assert_output "true"
}

# ── Single-field accessors ───────────────────────────────────────────────────

@test "detect_get_field os.id returns a non-empty string in the container" {
    _load_detect
    run detect_get_field os.id
    assert_success
    [[ -n "${output}" ]]
}

@test "detect_get_field arch matches uname -m" {
    _load_detect
    local _expected
    _expected="$(uname -m)"
    run detect_get_field arch
    assert_success
    [[ "${output}" == "${_expected}" ]]
}

@test "detect_get_field wsl is true|false (not unset)" {
    _load_detect
    run detect_get_field wsl
    assert_success
    [[ "${output}" == "true" || "${output}" == "false" ]]
}

@test "detect_get_field rejects unknown field with exit 1" {
    _load_detect
    run detect_get_field bogus.path
    assert_failure
}

@test "in test-tools container, board is empty (no SBC marker)" {
    _load_detect
    run detect_get_field board
    assert_success
    [[ -z "${output}" ]]
}

@test "detect_environment is idempotent (same JSON across two calls)" {
    _load_detect
    local _a _b
    _a="$(detect_environment)"
    _b="$(detect_environment)"
    [[ "${_a}" == "${_b}" ]]
}

# ── env-driven fields ────────────────────────────────────────────────────────

@test "detect_get_field desktop reflects XDG_CURRENT_DESKTOP" {
    _load_detect
    export XDG_CURRENT_DESKTOP="ubuntu:GNOME"
    run detect_get_field desktop
    assert_success
    assert_output "ubuntu:GNOME"
}

@test "detect_get_field desktop is empty when XDG_CURRENT_DESKTOP is unset" {
    _load_detect
    unset XDG_CURRENT_DESKTOP
    run detect_get_field desktop
    assert_success
    assert_output ""
}

@test "detect_get_field session_type reflects XDG_SESSION_TYPE" {
    _load_detect
    export XDG_SESSION_TYPE="wayland"
    run detect_get_field session_type
    assert_success
    assert_output "wayland"
}

@test "WSL env marker (WSL_DISTRO_NAME) flips wsl to true" {
    _load_detect
    [[ -e /proc/sys/fs/binfmt_misc/WSLInterop ]] && skip "real WSL host"
    export WSL_DISTRO_NAME="Ubuntu"
    run detect_get_field wsl
    assert_success
    assert_output "true"
}

@test "detect_environment JSON-escapes double quotes in env-sourced values" {
    _load_detect
    export XDG_CURRENT_DESKTOP='Weird"Desk'
    run detect_environment
    assert_success
    assert_output --partial '"desktop":"Weird\"Desk"'
}

# ── more single-field accessors ─────────────────────────────────────────────

@test "detect_get_field os.version matches /etc/os-release VERSION_ID" {
    _load_detect
    [[ -f /etc/os-release ]] || skip "no /etc/os-release in image"
    local _expected
    _expected="$(. /etc/os-release; printf '%s' "${VERSION_ID:-}")"
    run detect_get_field os.version
    assert_success
    [[ "${output}" == "${_expected}" ]]
}

@test "detect_get_field os.codename matches /etc/os-release VERSION_CODENAME" {
    _load_detect
    [[ -f /etc/os-release ]] || skip "no /etc/os-release in image"
    local _expected
    _expected="$(. /etc/os-release; printf '%s' "${VERSION_CODENAME:-}")"
    run detect_get_field os.codename
    assert_success
    [[ "${output}" == "${_expected}" ]]
}

@test "detect_get_field cpu.vendor succeeds and contains no spaces" {
    _load_detect
    run detect_get_field cpu.vendor
    assert_success
    [[ "${output}" != *" "* ]]
}

@test "detect_get_field virt.vm is true|false (not unset)" {
    _load_detect
    run detect_get_field virt.vm
    assert_success
    [[ "${output}" == "true" || "${output}" == "false" ]]
}

# ── GPU probe classification (lspci stubbed on PATH) ────────────────────────

_stub_lspci() {
    local _stubdir="${INIT_UBUNTU_TEST_SCRATCH}/stubs"
    mkdir -p "${_stubdir}"
    printf '#!/usr/bin/env bash\necho "%s"\n' "$1" > "${_stubdir}/lspci"
    chmod +x "${_stubdir}/lspci"
    export PATH="${_stubdir}:${PATH}"
}

@test "gpu.vendor classifies an NVIDIA VGA line as nvidia" {
    _load_detect
    _stub_lspci "01:00.0 VGA compatible controller: NVIDIA Corporation AD102 [GeForce RTX 4090]"
    run detect_get_field gpu.vendor
    assert_success
    assert_output "nvidia"
}

@test "gpu.model carries the lspci description after the vendor split" {
    _load_detect
    _stub_lspci "01:00.0 VGA compatible controller: NVIDIA Corporation AD102 [GeForce RTX 4090]"
    run detect_get_field gpu.model
    assert_success
    assert_output --partial "NVIDIA Corporation AD102"
}

@test "gpu.vendor classifies an AMD VGA line as amd" {
    _load_detect
    _stub_lspci "03:00.0 VGA compatible controller: Advanced Micro Devices, Inc. [AMD/ATI] Navi 31"
    run detect_get_field gpu.vendor
    assert_success
    assert_output "amd"
}

@test "gpu.vendor falls back to other for unrecognized VGA vendors" {
    _load_detect
    _stub_lspci "02:00.0 VGA compatible controller: Matrox Electronics Systems Ltd. MGA G200e"
    run detect_get_field gpu.vendor
    assert_success
    assert_output "other"
}

@test "gpu.vendor is empty when lspci shows no VGA/3D device" {
    _load_detect
    _stub_lspci "00:1f.3 Audio device: Intel Corporation Cannon Lake PCH cAVS"
    run detect_get_field gpu.vendor
    assert_success
    assert_output ""
}
