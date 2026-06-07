#!/usr/bin/env bats
# test/unit/module/nvidia-driver_spec.bats — module/nvidia-driver.module.sh
#
# Batch-A backfill (issue #123). Per Q29: smoke / metadata / lifecycle
# dry-run / no-side-fx / sidecar semantics (ADR-0001) / idempotency (AC-5) /
# standalone CLI (AC-25) / module-specific behaviors (custom archetype:
# graphics-drivers PPA + ubuntu-drivers autoinstall, GPU detect via lspci,
# desktop-only + container-excluded is_recommended, RISK_LEVEL=high with
# REBOOT_REQUIRED=true — snapshot/restore gate per ADR-0020).
#
# Version truth is apt/ubuntu-drivers-owned: the module intentionally writes
# no Sidecar and implements neither is_outdated() nor doctor() (both optional
# per doc/module-spec.md §lifecycle; standalone CLI degrades to exit 2).

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
}

teardown() {
    teardown_test_env
}

_load_module() {
    # shellcheck source=../../../lib/logger.sh
    source "${LIB_DIR}/logger.sh"
    # shellcheck source=../../../lib/general.sh
    source "${LIB_DIR}/general.sh"
    # shellcheck source=../../../lib/module_helper.sh
    source "${LIB_DIR}/module_helper.sh"
    # shellcheck source=../../../module/nvidia-driver.module.sh
    source "${MODULE_DIR}/nvidia-driver.module.sh"
}

# _standalone_module runs the module as a self-contained CLI (the same
# entry users hit when they type `bash module/nvidia-driver.module.sh ...`).
_standalone_module() {
    bash "${MODULE_DIR}/nvidia-driver.module.sh" "$@"
}

# ── Controllable mocks ───────────────────────────────────────────────────────
# Each shadowed function is defined exactly once and parameterized via
# MOCK_* variables, so every definition stays reachable for the linter
# (avoids SC2317 without disable directives).

# is_installed mock: MOCK_IS_INSTALLED_RC (0 = installed, 1 = not).
_mock_is_installed() {
    is_installed() { return "${MOCK_IS_INSTALLED_RC:-0}"; }
}

# sudo mock: records the full argv into MOCK_SUDO_LOG (one line per call)
# and executes nothing.
#   MOCK_SUDO_RC          — exit code for every call (default 0)
#   MOCK_SUDO_FAIL_MATCH  — fail (rc 1) only calls whose argv contains this
_mock_sudo() {
    MOCK_SUDO_LOG="${INIT_UBUNTU_TEST_SCRATCH}/sudo.log"
    : > "${MOCK_SUDO_LOG}"
    have_sudo_access() { return 0; }
    sudo() {
        printf '%s\n' "$*" >> "${MOCK_SUDO_LOG}"
        if [[ -n "${MOCK_SUDO_FAIL_MATCH:-}" \
            && "$*" == *"${MOCK_SUDO_FAIL_MATCH}"* ]]; then
            return 1
        fi
        return "${MOCK_SUDO_RC:-0}"
    }
}

# lspci mock: MOCK_LSPCI_OUTPUT controls the PCI listing the module greps.
_mock_lspci() {
    lspci() { printf '%s\n' "${MOCK_LSPCI_OUTPUT:-}"; }
}

_LSPCI_NVIDIA='01:00.0 VGA compatible controller: NVIDIA Corporation GA102 [GeForce RTX 3080]'
_LSPCI_INTEL='00:02.0 VGA compatible controller: Intel Corporation UHD Graphics 630'

# systemd-detect-virt mock: MOCK_VIRT_CONTAINER_RC (0 = inside a container).
_mock_virt() {
    systemd-detect-virt() { return "${MOCK_VIRT_CONTAINER_RC:-1}"; }
}

# nvidia-smi fake binary so the real is_installed() finds it on PATH.
_mock_nvidia_smi_bin() {
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    printf '#!/usr/bin/env bash\nprintf "NVIDIA-SMI 550.00\\n"\n' \
        > "${INIT_UBUNTU_TEST_SCRATCH}/bin/nvidia-smi"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/nvidia-smi"
}

_sidecar_file() {
    printf '%s/versions/nvidia-driver' "${INIT_UBUNTU_STATE_DIR}"
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "nvidia-driver module file exists" {
    [[ -f "${MODULE_DIR}/nvidia-driver.module.sh" ]]
}

@test "nvidia-driver module parses (bash -n)" {
    run bash -n "${MODULE_DIR}/nvidia-driver.module.sh"
    assert_success
}

@test "sourcing in engine mode exits 0 and runs no lifecycle" {
    run _load_module
    assert_success
    refute_output --partial "DRY-RUN"
}

@test "engine mode does not invoke module_standalone_main" {
    _load_module
    [[ "${MODULE_STANDALONE}" == "false" ]]
}

# ── Metadata (doc/module-spec.md §3, PRD §9.1) ──────────────────────────────

@test "NAME=nvidia-driver matches the filename stem" {
    _load_module
    [[ "${NAME}" == "nvidia-driver" ]]
}

@test "VERSION_PROVIDED=ubuntu-recommended (ubuntu-drivers picks it)" {
    _load_module
    [[ "${VERSION_PROVIDED}" == "ubuntu-recommended" ]]
}

@test "CATEGORY=optional" {
    _load_module
    [[ "${CATEGORY}" == "optional" ]]
}

@test "TAGS contains gpu, nvidia and hardware" {
    _load_module
    [[ " ${TAGS[*]} " == *" gpu "* ]]
    [[ " ${TAGS[*]} " == *" nvidia "* ]]
    [[ " ${TAGS[*]} " == *" hardware "* ]]
}

@test "DEPENDS_ON is exactly apt-essentials (Q39)" {
    _load_module
    [[ "${#DEPENDS_ON[@]}" -eq 1 ]]
    [[ "${DEPENDS_ON[0]}" == "apt-essentials" ]]
}

@test "DESCRIPTION is associative with en + zh-TW entries" {
    _load_module
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ -n "$(module_get_description en)" ]]
    [[ -n "$(module_get_description zh-TW)" ]]
}

@test "POST_INSTALL_MESSAGE mentions the mandatory reboot" {
    _load_module
    [[ "$(module_get_post_install_message en)" == *"Reboot"* ]]
    [[ -n "$(module_get_post_install_message zh-TW)" ]]
}

@test "WARN_MESSAGE warns about the desktop session (high-risk driver swap)" {
    _load_module
    [[ "$(module_get_warn_message en)" == *"GPU"* ]]
    [[ -n "$(module_get_warn_message zh-TW)" ]]
}

@test "SUPPORTED_UBUNTU includes 22.04 24.04 26.04" {
    _load_module
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 22.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 24.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 26.04 "* ]]
}

@test "SUPPORTED_PLATFORMS is exactly desktop (no rpi/jetson driver swap)" {
    _load_module
    [[ "${#SUPPORTED_PLATFORMS[@]}" -eq 1 ]]
    [[ "${SUPPORTED_PLATFORMS[0]}" == "desktop" ]]
}

@test "SUPPORTS_USER_HOME=false (system-wide kernel driver)" {
    _load_module
    [[ "${SUPPORTS_USER_HOME}" == "false" ]]
}

@test "RISK_LEVEL=high (ADR-0020 snapshot/restore gate)" {
    _load_module
    [[ "${RISK_LEVEL}" == "high" ]]
}

@test "REBOOT_REQUIRED=true" {
    _load_module
    [[ "${REBOOT_REQUIRED}" == "true" ]]
}

@test "INSTALL_TARGET_DEFAULT=sudo" {
    _load_module
    [[ "${INSTALL_TARGET_DEFAULT}" == "sudo" ]]
}

@test "HOMEPAGE points at the graphics-drivers PPA" {
    _load_module
    [[ "${HOMEPAGE}" == *"graphics-drivers"* ]]
}

@test "APT_PPA is ppa:graphics-drivers/ppa" {
    _load_module
    [[ "${APT_PPA}" == "ppa:graphics-drivers/ppa" ]]
}

@test "TEST_VERIFY_CMD exercises nvidia-smi" {
    _load_module
    [[ "${TEST_VERIFY_CMD}" == *"nvidia-smi"* ]]
}

# ── Lifecycle presence (5 mandatory + implemented optionals) ─────────────────

@test "all 5 mandatory + install/upgrade/verify lifecycle functions defined" {
    _load_module
    local _fn
    for _fn in detect is_recommended is_installed install upgrade \
               remove purge verify; do
        declare -F "${_fn}" >/dev/null || {
            printf 'missing lifecycle function: %s\n' "${_fn}" >&2
            return 1
        }
    done
}

@test "optional is_outdated/doctor intentionally absent (apt owns versions)" {
    _load_module
    ! declare -F is_outdated >/dev/null
    ! declare -F doctor >/dev/null
}

# ── Lifecycle dry-run (AC-12 pattern: log only, no side effects) ─────────────

@test "install --dry-run exits 0 and logs DRY-RUN" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "upgrade --dry-run exits 0 and logs DRY-RUN" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run upgrade
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "remove --dry-run exits 0 and logs DRY-RUN" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run remove
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "purge --dry-run exits 0 and logs DRY-RUN" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run purge
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "verify --dry-run exits 0 and logs DRY-RUN" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run verify
    assert_success
    assert_output --partial "DRY-RUN"
}

# ── No side effects ──────────────────────────────────────────────────────────

@test "dry-run install never shells out to sudo and writes no state" {
    _load_module
    _mock_sudo
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    [[ ! -s "${MOCK_SUDO_LOG}" ]]
    [[ -z "$(find "${INIT_UBUNTU_STATE_DIR}" -type f 2>/dev/null)" ]]
}

@test "dry-run remove never shells out to sudo" {
    _load_module
    _mock_sudo
    INIT_UBUNTU_DRY_RUN=true run remove
    assert_success
    [[ ! -s "${MOCK_SUDO_LOG}" ]]
}

@test "detect / is_installed / is_recommended leave the state dir untouched" {
    _load_module
    MOCK_LSPCI_OUTPUT="${_LSPCI_NVIDIA}"
    _mock_lspci
    detect || true
    is_installed || true
    is_recommended || true
    [[ -z "$(find "${INIT_UBUNTU_STATE_DIR}" -type f 2>/dev/null)" ]]
}

@test "standalone dry-run install creates no files in a scratch HOME" {
    local _home="${INIT_UBUNTU_TEST_SCRATCH}/home"
    mkdir -p "${_home}"
    HOME="${_home}" XDG_STATE_HOME="${_home}/.local/state" \
        run _standalone_module install --dry-run
    assert_success
    [[ -z "$(find "${_home}" -mindepth 1 2>/dev/null)" ]]
}

# ── is_installed: nvidia-smi on PATH ─────────────────────────────────────────

@test "is_installed returns zero when nvidia-smi is on PATH" {
    _load_module
    _mock_nvidia_smi_bin
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run is_installed
    assert_success
}

@test "is_installed returns nonzero when nvidia-smi is absent" {
    _load_module
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/empty-bin"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/empty-bin" run is_installed
    assert_failure
}

# ── detect: lspci reports an NVIDIA device ───────────────────────────────────

@test "detect succeeds when lspci lists an NVIDIA controller" {
    _load_module
    MOCK_LSPCI_OUTPUT="${_LSPCI_NVIDIA}"
    _mock_lspci
    run detect
    assert_success
}

@test "detect matches case-insensitively (grep -i nvidia)" {
    _load_module
    MOCK_LSPCI_OUTPUT='01:00.0 3D controller: nVidia Corporation GP107M'
    _mock_lspci
    run detect
    assert_success
}

@test "detect fails when only a non-NVIDIA GPU is present" {
    _load_module
    MOCK_LSPCI_OUTPUT="${_LSPCI_INTEL}"
    _mock_lspci
    run detect
    assert_failure
}

@test "detect fails gracefully when lspci is unavailable" {
    _load_module
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/empty-bin"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/empty-bin" run detect
    assert_failure
}

# ── is_recommended: desktop + bare metal + GPU + not installed ───────────────

@test "is_recommended succeeds: desktop, no container, GPU, not installed" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    MOCK_VIRT_CONTAINER_RC=1
    _mock_virt
    MOCK_LSPCI_OUTPUT="${_LSPCI_NVIDIA}"
    _mock_lspci
    INIT_UBUNTU_FORM_FACTOR="desktop" run is_recommended
    assert_success
}

@test "is_recommended fails when the driver is already installed" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    INIT_UBUNTU_FORM_FACTOR="desktop" run is_recommended
    assert_failure
}

@test "is_recommended fails on a non-desktop form factor" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    INIT_UBUNTU_FORM_FACTOR="server" run is_recommended
    assert_failure
}

@test "is_recommended fails inside a container (systemd-detect-virt)" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    MOCK_VIRT_CONTAINER_RC=0
    _mock_virt
    MOCK_LSPCI_OUTPUT="${_LSPCI_NVIDIA}"
    _mock_lspci
    INIT_UBUNTU_FORM_FACTOR="desktop" run is_recommended
    assert_failure
}

@test "is_recommended fails when no NVIDIA GPU is detected" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    MOCK_VIRT_CONTAINER_RC=1
    _mock_virt
    MOCK_LSPCI_OUTPUT="${_LSPCI_INTEL}"
    _mock_lspci
    INIT_UBUNTU_FORM_FACTOR="desktop" run is_recommended
    assert_failure
}

# ── install: PPA + prereqs + ubuntu-drivers autoinstall ──────────────────────

@test "install skips when already installed (AC-5 idempotent fast path)" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    _mock_sudo
    run install
    assert_success
    assert_output --partial "already installed"
    [[ ! -s "${MOCK_SUDO_LOG}" ]]
}

@test "install fails without sudo access" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    have_sudo_access() { return 1; }
    run install
    assert_failure
    assert_output --partial "sudo required"
}

@test "install aborts when lspci shows no NVIDIA GPU" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    _mock_sudo
    MOCK_LSPCI_OUTPUT="${_LSPCI_INTEL}"
    _mock_lspci
    run install
    assert_failure
    assert_output --partial "no NVIDIA GPU detected"
    [[ ! -s "${MOCK_SUDO_LOG}" ]]
}

@test "install adds the PPA, installs prereqs and runs autoinstall" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    _mock_sudo
    MOCK_LSPCI_OUTPUT="${_LSPCI_NVIDIA}"
    _mock_lspci
    run install
    assert_success
    grep -qF -- 'add-apt-repository -y ppa:graphics-drivers/ppa' "${MOCK_SUDO_LOG}"
    grep -qF -- 'apt-get update -qq' "${MOCK_SUDO_LOG}"
    grep -qF -- 'apt-get install -y --no-install-recommends ubuntu-drivers-common linux-headers-generic dkms' "${MOCK_SUDO_LOG}"
    grep -qF -- 'ubuntu-drivers autoinstall' "${MOCK_SUDO_LOG}"
}

@test "install warns that a reboot is required" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    _mock_sudo
    MOCK_LSPCI_OUTPUT="${_LSPCI_NVIDIA}"
    _mock_lspci
    run install
    assert_success
    assert_output --partial "reboot required"
}

@test "install tolerates an add-apt-repository failure (warn + continue)" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    _mock_sudo
    MOCK_SUDO_FAIL_MATCH="add-apt-repository"
    MOCK_LSPCI_OUTPUT="${_LSPCI_NVIDIA}"
    _mock_lspci
    run install
    assert_success
    grep -qF -- 'ubuntu-drivers autoinstall' "${MOCK_SUDO_LOG}"
}

@test "install fails when the prereq apt install fails" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    _mock_sudo
    MOCK_SUDO_FAIL_MATCH="--no-install-recommends"
    MOCK_LSPCI_OUTPUT="${_LSPCI_NVIDIA}"
    _mock_lspci
    run install
    assert_failure
    assert_output --partial "prereq install failed"
}

@test "install fails when ubuntu-drivers autoinstall fails" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    _mock_sudo
    MOCK_SUDO_FAIL_MATCH="ubuntu-drivers autoinstall"
    MOCK_LSPCI_OUTPUT="${_LSPCI_NVIDIA}"
    _mock_lspci
    run install
    assert_failure
    assert_output --partial "autoinstall failed"
}

# ── Sidecar semantics (ADR-0001): apt owns the version, no Sidecar ──────────

@test "install writes no Sidecar (apt/ubuntu-drivers owns version truth)" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    _mock_sudo
    MOCK_LSPCI_OUTPUT="${_LSPCI_NVIDIA}"
    _mock_lspci
    run install
    assert_success
    [[ ! -e "$(_sidecar_file)" ]]
}

@test "install never touches state.json (ADR-0001 / AC-23 pattern)" {
    _load_module
    printf '{"schema_version":"0.1.0","installed":{}}\n' \
        > "${INIT_UBUNTU_STATE_DIR}/state.json"
    local _before; _before="$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")"
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    _mock_sudo
    MOCK_LSPCI_OUTPUT="${_LSPCI_NVIDIA}"
    _mock_lspci
    run install
    assert_success
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")" == "${_before}" ]]
}

@test "remove leaves a foreign Sidecar alone (module never owned one)" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '550.00\n' > "$(_sidecar_file)"
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    _mock_sudo
    run remove
    assert_success
    [[ -f "$(_sidecar_file)" ]]
}

# ── upgrade: apt --only-upgrade nvidia-driver-* ──────────────────────────────

@test "upgrade fails without sudo access" {
    _load_module
    have_sudo_access() { return 1; }
    run upgrade
    assert_failure
    assert_output --partial "sudo required"
}

@test "upgrade runs apt-get update + --only-upgrade nvidia-driver-*" {
    _load_module
    _mock_sudo
    run upgrade
    assert_success
    grep -qF -- 'apt-get update -qq' "${MOCK_SUDO_LOG}"
    grep -qF -- 'apt-get install --only-upgrade -y nvidia-driver-*' "${MOCK_SUDO_LOG}"
}

@test "upgrade tolerates a failing --only-upgrade (best-effort)" {
    _load_module
    _mock_sudo
    MOCK_SUDO_FAIL_MATCH="--only-upgrade"
    run upgrade
    assert_success
}

# ── remove / purge ───────────────────────────────────────────────────────────

@test "remove skips when not installed (idempotent fast path)" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    _mock_sudo
    run remove
    assert_success
    assert_output --partial "not installed"
    [[ ! -s "${MOCK_SUDO_LOG}" ]]
}

@test "remove purges nvidia-* and autoremoves when installed" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    _mock_sudo
    run remove
    assert_success
    grep -qF -- 'apt-get purge -y nvidia-*' "${MOCK_SUDO_LOG}"
    grep -qF -- 'apt autoremove -y' "${MOCK_SUDO_LOG}"
}

@test "remove warns about the nouveau fallback reboot" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    _mock_sudo
    run remove
    assert_success
    assert_output --partial "nouveau"
}

@test "remove tolerates a failing apt purge (best-effort)" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    _mock_sudo
    MOCK_SUDO_FAIL_MATCH="purge"
    run remove
    assert_success
}

@test "remove is idempotent — second run still exits 0 (AC-5)" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    _mock_sudo
    run remove
    assert_success
    run remove
    assert_success
}

@test "purge removes packages and drops the PPA" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    _mock_sudo
    run purge
    assert_success
    grep -qF -- 'apt-get purge -y nvidia-*' "${MOCK_SUDO_LOG}"
    grep -qF -- 'add-apt-repository -y --remove ppa:graphics-drivers/ppa' "${MOCK_SUDO_LOG}"
}

@test "purge on a clean system still drops the PPA and exits 0" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    _mock_sudo
    run purge
    assert_success
    grep -qF -- 'add-apt-repository -y --remove ppa:graphics-drivers/ppa' "${MOCK_SUDO_LOG}"
}

@test "purge tolerates a failing PPA removal (best-effort)" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    _mock_sudo
    MOCK_SUDO_FAIL_MATCH="--remove"
    run purge
    assert_success
}

# ── verify (module_default_verify) ───────────────────────────────────────────

@test "verify fails when not installed" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    run verify
    assert_failure
}

@test "verify passes when installed and TEST_VERIFY_CMD succeeds" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    TEST_VERIFY_CMD="true"
    run verify
    assert_success
}

@test "verify fails when TEST_VERIFY_CMD fails (nvidia-smi broken)" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    TEST_VERIFY_CMD="false"
    run verify
    assert_failure
}

# ── Engine discovery (registry scan) ─────────────────────────────────────────

@test "registry discovers nvidia-driver under --tag=gpu" {
    # shellcheck source=../../../lib/logger.sh
    source "${LIB_DIR}/logger.sh"
    # shellcheck source=../../../lib/registry.sh
    source "${LIB_DIR}/registry.sh"
    export INIT_UBUNTU_USER_MODULE_DIR="${INIT_UBUNTU_TEST_SCRATCH}/user-module"
    registry_load_all "${MODULE_DIR}"
    run registry_list_names --tag=gpu
    assert_success
    assert_output --partial "nvidia-driver"
}

# ── Standalone CLI (AC-25) ───────────────────────────────────────────────────

@test "standalone: with no args prints usage + exits 2" {
    run _standalone_module
    assert_failure 2
    assert_output --partial "Usage:"
}

@test "standalone: --help shows phases" {
    run _standalone_module --help
    assert_success
    assert_output --partial "install"
    assert_output --partial "remove"
    assert_output --partial "purge"
}

@test "standalone: --version prints NAME + VERSION_PROVIDED" {
    run _standalone_module --version
    assert_success
    assert_output --partial "nvidia-driver"
    assert_output --partial "ubuntu-recommended"
}

@test "standalone: unknown phase returns exit 2" {
    run _standalone_module frobnicate
    assert_failure 2
}

@test "standalone: info prints metadata incl. risk + reboot" {
    run _standalone_module info
    assert_success
    assert_output --partial "name:        nvidia-driver"
    assert_output --partial "category:    optional"
    assert_output --partial "gpu"
    assert_output --partial "risk:        high"
    assert_output --partial "reboot:      required"
}

@test "standalone: info --lang=zh-TW prints localized description" {
    run _standalone_module info --lang=zh-TW
    assert_success
    assert_output --partial "驅動"
}

@test "standalone: status reports installed + outdated fields" {
    run _standalone_module status
    assert_success
    assert_output --partial "installed:"
    assert_output --partial "outdated:    (no is_outdated)"
}

@test "standalone: install --dry-run exits 0 with DRY-RUN output" {
    run _standalone_module install --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "standalone: upgrade --dry-run exits 0" {
    run _standalone_module upgrade --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "standalone: remove --dry-run exits 0" {
    run _standalone_module remove --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "standalone: purge --dry-run exits 0" {
    run _standalone_module purge --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "standalone: verify --dry-run exits 0" {
    run _standalone_module verify --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "standalone: detect is implemented (exit != 2)" {
    run _standalone_module detect
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "standalone: is-installed is implemented (exit != 2)" {
    run _standalone_module is-installed
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "standalone: is-recommended is implemented (exit != 2)" {
    run _standalone_module is-recommended
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "standalone: is-outdated degrades gracefully (optional, exit 2)" {
    run _standalone_module is-outdated
    assert_failure 2
    assert_output --partial "not implemented"
}

@test "standalone: doctor degrades gracefully (optional, exit 2)" {
    run _standalone_module doctor
    assert_failure 2
    assert_output --partial "not implemented"
}
