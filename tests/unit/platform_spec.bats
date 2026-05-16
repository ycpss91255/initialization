#!/usr/bin/env bats
# shellcheck disable=SC1091  # test sources libs via runtime ${LIB_DIR}; static-resolution misses the path — https://www.shellcheck.net/wiki/SC1091
# tests/unit/platform_spec.bats — lib/platform.sh

load "${BATS_TEST_DIRNAME}/../helpers/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
}

teardown() {
    teardown_test_env
}

_load_platform() {
    # shellcheck disable=SC1091  # dynamic source path ($VAR resolved at runtime) — https://www.shellcheck.net/wiki/SC1091
    source "${LIB_DIR}/platform.sh"
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "lib/platform.sh sources without error" {
    run bash -c "source '${LIB_DIR}/platform.sh'"
    assert_success
}

@test "platform_classify is defined" {
    run bash -c "source '${LIB_DIR}/platform.sh' && declare -F platform_classify"
    assert_success
    assert_output --partial "platform_classify"
}

@test "platform_export_env is defined" {
    run bash -c "source '${LIB_DIR}/platform.sh' && declare -F platform_export_env"
    assert_success
    assert_output --partial "platform_export_env"
}

# ── Priority rules: fixture JSON drives each branch ──────────────────────────

@test "WSL beats container even when both are signalled" {
    _load_platform
    local _json='{"os":{"id":"ubuntu","version":"24.04","codename":"noble"},"arch":"x86_64","cpu":{"vendor":"GenuineIntel"},"gpu":{"vendor":null,"model":null},"desktop":null,"session_type":null,"virt":{"container":true,"vm":false},"wsl":true,"board":null}'
    run platform_classify "${_json}"
    assert_success
    assert_output "wsl"
}

@test "container wins over vm" {
    _load_platform
    local _json='{"os":{"id":"ubuntu","version":"24.04","codename":"noble"},"arch":"x86_64","cpu":{"vendor":"GenuineIntel"},"gpu":{"vendor":null,"model":null},"desktop":null,"session_type":null,"virt":{"container":true,"vm":true},"wsl":false,"board":null}'
    run platform_classify "${_json}"
    assert_success
    assert_output "container"
}

@test "vm classifies as vm when not container/wsl" {
    _load_platform
    local _json='{"os":{"id":"ubuntu","version":"24.04","codename":"noble"},"arch":"x86_64","cpu":{"vendor":"GenuineIntel"},"gpu":{"vendor":null,"model":null},"desktop":null,"session_type":null,"virt":{"container":false,"vm":true},"wsl":false,"board":null}'
    run platform_classify "${_json}"
    assert_success
    assert_output "vm"
}

@test "raspberry-pi-4 board -> rpi-4" {
    _load_platform
    local _json='{"os":{"id":"ubuntu","version":"24.04","codename":"noble"},"arch":"aarch64","cpu":{"vendor":"ARM"},"gpu":{"vendor":null,"model":null},"desktop":null,"session_type":null,"virt":{"container":false,"vm":false},"wsl":false,"board":"raspberry-pi-4"}'
    run platform_classify "${_json}"
    assert_success
    assert_output "rpi-4"
}

@test "raspberry-pi-5 board -> rpi-5" {
    _load_platform
    local _json='{"os":{"id":"ubuntu","version":"24.04","codename":"noble"},"arch":"aarch64","cpu":{"vendor":"ARM"},"gpu":{"vendor":null,"model":null},"desktop":null,"session_type":null,"virt":{"container":false,"vm":false},"wsl":false,"board":"raspberry-pi-5"}'
    run platform_classify "${_json}"
    assert_success
    assert_output "rpi-5"
}

@test "jetson-orin board -> jetson-orin" {
    _load_platform
    local _json='{"os":{"id":"ubuntu","version":"22.04","codename":"jammy"},"arch":"aarch64","cpu":{"vendor":"ARM"},"gpu":{"vendor":"nvidia","model":"Tegra"},"desktop":null,"session_type":null,"virt":{"container":false,"vm":false},"wsl":false,"board":"jetson-orin"}'
    run platform_classify "${_json}"
    assert_success
    assert_output "jetson-orin"
}

@test "non-empty desktop + no SBC + bare-metal -> desktop" {
    _load_platform
    local _json='{"os":{"id":"ubuntu","version":"24.04","codename":"noble"},"arch":"x86_64","cpu":{"vendor":"GenuineIntel"},"gpu":{"vendor":"nvidia","model":"RTX 4090"},"desktop":"GNOME","session_type":"x11","virt":{"container":false,"vm":false},"wsl":false,"board":null}'
    run platform_classify "${_json}"
    assert_success
    assert_output "desktop"
}

@test "empty desktop + x86_64 + bare-metal -> server" {
    _load_platform
    local _json='{"os":{"id":"ubuntu","version":"24.04","codename":"noble"},"arch":"x86_64","cpu":{"vendor":"GenuineIntel"},"gpu":{"vendor":null,"model":null},"desktop":null,"session_type":null,"virt":{"container":false,"vm":false},"wsl":false,"board":null}'
    run platform_classify "${_json}"
    assert_success
    assert_output "server"
}

@test "empty desktop + aarch64 + bare-metal -> server" {
    _load_platform
    local _json='{"os":{"id":"ubuntu","version":"24.04","codename":"noble"},"arch":"aarch64","cpu":{"vendor":"ARM"},"gpu":{"vendor":null,"model":null},"desktop":null,"session_type":null,"virt":{"container":false,"vm":false},"wsl":false,"board":null}'
    run platform_classify "${_json}"
    assert_success
    assert_output "server"
}

@test "exotic arch + no desktop -> unknown" {
    _load_platform
    local _json='{"os":{"id":"ubuntu","version":"24.04","codename":"noble"},"arch":"riscv64","cpu":{"vendor":null},"gpu":{"vendor":null,"model":null},"desktop":null,"session_type":null,"virt":{"container":false,"vm":false},"wsl":false,"board":null}'
    run platform_classify "${_json}"
    assert_success
    assert_output "unknown"
}

# ── platform_export_env ────────────────────────────────────────────────────

@test "platform_export_env exports INIT_UBUNTU_FORM_FACTOR" {
    _load_platform
    local _json='{"os":{"id":"ubuntu","version":"24.04","codename":"noble"},"arch":"x86_64","cpu":{"vendor":"GenuineIntel"},"gpu":{"vendor":null,"model":null},"desktop":"GNOME","session_type":"x11","virt":{"container":false,"vm":false},"wsl":false,"board":null}'
    platform_export_env "${_json}"
    [[ "${INIT_UBUNTU_FORM_FACTOR}" == "desktop" ]]
}

# ── No-arg path delegates to detect_environment ─────────────────────────────

@test "platform_classify with no arg falls back to detect_environment()" {
    source "${LIB_DIR}/detect.sh"
    source "${LIB_DIR}/platform.sh"
    run platform_classify
    assert_success
    case "${output}" in
        desktop|server|rpi-4|rpi-5|jetson-orin|wsl|container|vm|unknown) :;;
        *) printf "unexpected form_factor: %s\n" "${output}" >&2; return 1 ;;
    esac
}

@test "platform_classify without detect.sh sourced and no arg fails with hint" {
    _load_platform
    run platform_classify
    assert_failure
    assert_output --partial "detect_environment not loaded"
}
