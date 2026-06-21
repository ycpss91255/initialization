#!/usr/bin/env bats
# shellcheck disable=SC2317  # test mocks (e.g. command_v) dispatched indirectly when docker module's install() resolves shell functions — https://www.shellcheck.net/wiki/SC2317
# test/unit/module/docker_spec.bats — module/docker.module.sh (issue #123)
#
# Coverage per PRD Q29: smoke / metadata / lifecycle dry-run / no-side-fx /
# sidecar semantics (ADR-0001: apt-managed, never touches state.json) /
# idempotency (AC-5) / standalone CLI (AC-25) / module-specific behaviors
# (custom Docker apt-repo wiring, docker group, container guard).

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
    # shellcheck source=../../../module/docker.module.sh
    source "${MODULE_DIR}/docker.module.sh"
}

# _standalone_module runs the module as a self-contained CLI (the same
# entry users hit when they type `bash module/docker.module.sh ...`).
_standalone_module() {
    bash "${MODULE_DIR}/docker.module.sh" "$@"
}

# ── Controllable mocks ───────────────────────────────────────────────────────
# Each shadowed command is defined exactly once and parameterized via MOCK_*
# variables (vscode_spec pattern), so every definition stays reachable for
# the linter without extra disable directives.

# is_installed mock: MOCK_IS_INSTALLED_RC (0 = installed, 1 = not).
_mock_is_installed() {
    is_installed() { return "${MOCK_IS_INSTALLED_RC:-0}"; }
}

# have_sudo_access mock: MOCK_SUDO_ACCESS_RC (0 = sudo available).
_mock_have_sudo() {
    have_sudo_access() { return "${MOCK_SUDO_ACCESS_RC:-0}"; }
}

# Sandbox HOME into the per-test scratch dir (helper, not inline in the
# @test bodies: shellcheck SC2030/SC2031 flag cross-test var modification).
_use_scratch_home() {
    export HOME="${INIT_UBUNTU_TEST_SCRATCH}/home"
    mkdir -p "${HOME}"
}

# Recording sudo mock: every invocation is appended to MOCK_SUDO_LOG.
# Stdin-consuming subcommands (gpg, tee) drain the pipe so upstream
# writers never see EPIPE; tee content is captured to MOCK_TEE_CAPTURE.
_mock_sudo_record() {
    MOCK_SUDO_LOG="${INIT_UBUNTU_TEST_SCRATCH}/sudo.log"
    : > "${MOCK_SUDO_LOG}"
    sudo() {
        printf '%s\n' "$*" >> "${MOCK_SUDO_LOG}"
        case "${1:-}" in
            gpg) cat > /dev/null ;;
            tee) cat > "${MOCK_TEE_CAPTURE:-/dev/null}" ;;
        esac
        return 0
    }
}

# lsb_release mock: MOCK_CODENAME answers -cs (empty = simulate failure);
# MOCK_DISTRIB answers -is (default Ubuntu).
_mock_lsb_release() {
    lsb_release() {
        case "$*" in
            *-cs*) [[ -n "${MOCK_CODENAME:-}" ]] && printf '%s\n' "${MOCK_CODENAME}" ;;
            *-is*) printf '%s\n' "${MOCK_DISTRIB:-Ubuntu}" ;;
        esac
        return 0
    }
}

# dpkg mock: --print-architecture answers amd64; `dpkg -l <pkg>` emits
# MOCK_DPKG_OUTPUT and returns MOCK_DPKG_RC.
_mock_dpkg() {
    dpkg() {
        if [[ "${1:-}" == "--print-architecture" ]]; then
            printf 'amd64\n'
            return 0
        fi
        [[ -n "${MOCK_DPKG_OUTPUT:-}" ]] && printf '%s\n' "${MOCK_DPKG_OUTPUT}"
        return "${MOCK_DPKG_RC:-0}"
    }
}

# curl mock: emits a fake PGP key so the keyring pipe has bytes to drain.
_mock_curl() {
    curl() { printf 'FAKE-PGP-KEY\n'; }
}

# Wires the full mocked-install environment (not installed, sudo ok).
_mock_install_env() {
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    _mock_have_sudo
    _mock_sudo_record
    _mock_lsb_release
    _mock_dpkg
    _mock_curl
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "docker module file exists" {
    [[ -f "${MODULE_DIR}/docker.module.sh" ]]
}

@test "docker module parses (bash -n)" {
    run bash -n "${MODULE_DIR}/docker.module.sh"
    assert_success
}

@test "sourcing in engine mode sets MODULE_STANDALONE=false (no lifecycle run)" {
    _load_module
    [[ "${MODULE_STANDALONE}" == "false" ]]
}

# ── Metadata sanity ──────────────────────────────────────────────────────────

@test "docker module declares NAME=docker" {
    _load_module
    [[ "${NAME}" == "docker" ]]
}

@test "docker DESCRIPTION is associative and module_get_description returns text" {
    _load_module
    # Must be associative — `declare -A` (possibly with -g flag).
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ "$(module_get_description en)" == "Docker Engine + Compose plugin" ]]
    [[ "$(module_get_description zh-TW)" == "Docker 容器引擎 + Compose 外掛" ]]
}

@test "docker module CATEGORY=recommended" {
    _load_module
    [[ "${CATEGORY}" == "recommended" ]]
}

@test "docker module declares curl as a dependency" {
    _load_module
    [[ " ${DEPENDS_ON[*]} " == *" curl "* ]]
}

@test "docker module declares SUPPORTS_USER_HOME=false" {
    _load_module
    [[ "${SUPPORTS_USER_HOME}" == "false" ]]
}

@test "docker module SUPPORTED_UBUNTU includes 22.04 24.04 26.04" {
    _load_module
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 22.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 24.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 26.04 "* ]]
}

@test "docker module VERSION_PROVIDED=apt-managed" {
    _load_module
    [[ "${VERSION_PROVIDED}" == "apt-managed" ]]
}

@test "docker module TAGS contains container + devops" {
    _load_module
    [[ " ${TAGS[*]} " == *" container "* ]]
    [[ " ${TAGS[*]} " == *" devops "* ]]
}

@test "docker module RISK_LEVEL=low and REBOOT_REQUIRED=false" {
    _load_module
    [[ "${RISK_LEVEL}" == "low" ]]
    [[ "${REBOOT_REQUIRED}" == "false" ]]
}

@test "docker module INSTALL_TARGET_DEFAULT=sudo" {
    _load_module
    [[ "${INSTALL_TARGET_DEFAULT}" == "sudo" ]]
}

@test "docker HOMEPAGE points at docs.docker.com" {
    _load_module
    [[ "${HOMEPAGE}" == *"docs.docker.com"* ]]
}

@test "docker SUPPORTED_PLATFORMS covers desktop server wsl" {
    _load_module
    [[ " ${SUPPORTED_PLATFORMS[*]} " == *" desktop "* ]]
    [[ " ${SUPPORTED_PLATFORMS[*]} " == *" server "* ]]
    [[ " ${SUPPORTED_PLATFORMS[*]} " == *" wsl "* ]]
}

@test "docker POST_INSTALL_MESSAGE tells the user about the docker group" {
    _load_module
    [[ "$(declare -p POST_INSTALL_MESSAGE 2>/dev/null)" == 'declare -'*A* ]]
    [[ "$(module_get_post_install_message en)" == *"newgrp docker"* ]]
    [[ -n "$(module_get_post_install_message zh-TW)" ]]
}

@test "docker WARN_MESSAGE is a declared associative array" {
    _load_module
    [[ "$(declare -p WARN_MESSAGE 2>/dev/null)" == 'declare -'*A* ]]
}

@test "docker APT_PKGS pins the five upstream engine packages" {
    _load_module
    [[ "${#APT_PKGS[@]}" -eq 5 ]]
    local _pkg
    for _pkg in docker-ce docker-ce-cli containerd.io \
                docker-buildx-plugin docker-compose-plugin; do
        [[ " ${APT_PKGS[*]} " == *" ${_pkg} "* ]] || {
            printf 'missing apt package: %s\n' "${_pkg}" >&2
            return 1
        }
    done
}

@test "docker CONFIG_PATHS covers /var/lib/docker and /etc/docker" {
    _load_module
    [[ " ${CONFIG_PATHS[*]} " == *" /var/lib/docker "* ]]
    [[ " ${CONFIG_PATHS[*]} " == *" /etc/docker "* ]]
}

@test "docker TEST_VERIFY_CMD is declared for module_default_verify" {
    _load_module
    [[ -n "${TEST_VERIFY_CMD}" ]]
}

# ── Lifecycle presence ───────────────────────────────────────────────────────
# docker hand-writes its lifecycle (custom apt-repo setup; no archetype
# macro). is_outdated/doctor are not implemented yet — the standalone CLI
# tests below pin the graceful degradation for those two.

@test "docker defines its 8 hand-written lifecycle functions" {
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

# ── is_installed: relies on dpkg ─────────────────────────────────────────────

@test "is_installed returns nonzero when dpkg does not report docker-ce as installed" {
    _load_module
    run is_installed
    assert_failure
}

@test "is_installed returns zero when dpkg reports docker-ce as ii" {
    _load_module
    MOCK_DPKG_OUTPUT='ii  docker-ce  28.0.0  amd64  container engine'
    _mock_dpkg
    run is_installed
    assert_success
}

# ── Dry-run behavior ─────────────────────────────────────────────────────────

@test "install in dry-run mode does not execute (no sudo, no apt)" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "remove in dry-run mode is a no-op" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run remove
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "purge in dry-run mode is a no-op (does not touch /etc/docker etc.)" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run purge
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "upgrade in dry-run mode is a no-op" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run upgrade
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "verify in dry-run mode is a no-op" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run verify
    assert_success
    assert_output --partial "DRY-RUN"
}

# ── No side effects ──────────────────────────────────────────────────────────

@test "dry-run install writes nothing under the state dir" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/docker" ]]
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/state.json" ]]
}

@test "dry-run purge leaves scratch CONFIG_PATHS in place" {
    _load_module
    CONFIG_PATHS=("${INIT_UBUNTU_TEST_SCRATCH}/etc-docker")
    mkdir -p "${CONFIG_PATHS[0]}"
    : > "${CONFIG_PATHS[0]}/daemon.json"
    INIT_UBUNTU_DRY_RUN=true run purge
    assert_success
    [[ -f "${CONFIG_PATHS[0]}/daemon.json" ]]
}

@test "read-only phases leave the state dir untouched" {
    _load_module
    _mock_lsb_release
    detect || true
    is_installed || true
    is_recommended || true
    [[ -z "$(find "${INIT_UBUNTU_STATE_DIR}" -type f 2>/dev/null)" ]]
}

# ── Sidecar semantics (ADR-0001) ─────────────────────────────────────────────
# docker is apt-managed: dpkg is the version source of truth, so the module
# writes no Sidecar. What ADR-0001 still demands: the module never touches
# state.json (engine-only file) in any mode.

@test "mocked install writes no sidecar and never touches state.json (AC-23 pattern)" {
    _load_module
    _mock_install_env
    printf '{"schema_version":"0.1.0","installed":{}}\n' \
        > "${INIT_UBUNTU_STATE_DIR}/state.json"
    local _before; _before="$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")"
    MOCK_CODENAME=noble
    USER=testuser run install
    assert_success
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/docker" ]]
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")" == "${_before}" ]]
}

@test "dry-run remove leaves a pre-existing sidecar in place" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf 'apt-managed\n' > "${INIT_UBUNTU_STATE_DIR}/versions/docker"
    INIT_UBUNTU_DRY_RUN=true run remove
    assert_success
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/docker" ]]
}

# ── install: custom Docker apt-repo wiring (mocked sudo) ────────────────────

@test "install fails fast without sudo access" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    MOCK_SUDO_ACCESS_RC=1
    _mock_have_sudo
    run install
    assert_failure
    assert_output --partial "sudo required"
}

@test "install fails when the Ubuntu codename cannot be detected" {
    _load_module
    _mock_install_env
    MOCK_CODENAME=""
    run install
    assert_failure
    assert_output --partial "codename"
}

@test "install writes the signed-by docker.list entry for the detected codename" {
    _load_module
    _mock_install_env
    MOCK_CODENAME=noble
    MOCK_TEE_CAPTURE="${INIT_UBUNTU_TEST_SCRATCH}/docker.list"
    USER=testuser run install
    assert_success
    run cat "${MOCK_TEE_CAPTURE}"
    assert_output --partial "signed-by=/etc/apt/keyrings/docker.gpg"
    assert_output --partial "arch=amd64"
    assert_output --partial "noble stable"
}

@test "install runs apt-get for all five packages and adds the user to the docker group" {
    _load_module
    _mock_install_env
    MOCK_CODENAME=noble
    USER=testuser run install
    assert_success
    run cat "${MOCK_SUDO_LOG}"
    assert_output --partial "apt-get update"
    assert_output --partial "apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
    assert_output --partial "usermod -aG docker testuser"
}

# ── upgrade ──────────────────────────────────────────────────────────────────

@test "upgrade falls back to install when not installed" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    install() { : > "${INIT_UBUNTU_TEST_SCRATCH}/install-called"; }
    run upgrade
    assert_success
    assert_output --partial "running install instead"
    [[ -f "${INIT_UBUNTU_TEST_SCRATCH}/install-called" ]]
}

@test "upgrade runs apt --only-upgrade when already installed" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    _mock_have_sudo
    _mock_sudo_record
    run upgrade
    assert_success
    run cat "${MOCK_SUDO_LOG}"
    assert_output --partial "--only-upgrade"
}

@test "upgrade fails without sudo when already installed" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    MOCK_SUDO_ACCESS_RC=1
    _mock_have_sudo
    run upgrade
    assert_failure
    assert_output --partial "sudo required"
}

# ── remove / purge ───────────────────────────────────────────────────────────

@test "remove skips when not installed (idempotent no-op)" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    run remove
    assert_success
    assert_output --partial "not installed"
    run remove
    assert_success
}

@test "remove calls apt-get remove for the docker packages when installed" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    _mock_sudo_record
    run remove
    assert_success
    run cat "${MOCK_SUDO_LOG}"
    assert_output --partial "apt-get remove -y docker-ce"
}

@test "purge wipes HOME config and drops the apt source + keyring (mocked sudo)" {
    _load_module
    _mock_sudo_record
    _use_scratch_home
    CONFIG_PATHS=("${HOME}/.docker")
    mkdir -p "${CONFIG_PATHS[0]}"
    : > "${CONFIG_PATHS[0]}/config.json"
    run purge
    assert_success
    [[ ! -e "${CONFIG_PATHS[0]}" ]]
    run cat "${MOCK_SUDO_LOG}"
    assert_output --partial "apt-get purge -y"
    assert_output --partial "rm -f /etc/apt/sources.list.d/docker.list"
    assert_output --partial "rm -f /etc/apt/keyrings/docker.gpg"
}

@test "purge on a clean system still exits 0 (idempotent)" {
    _load_module
    _mock_sudo_record
    _use_scratch_home
    CONFIG_PATHS=("${HOME}/.docker")
    run purge
    assert_success
}

# ── verify ───────────────────────────────────────────────────────────────────

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

# ── Idempotency hint ─────────────────────────────────────────────────────────

@test "install short-circuits when is_installed returns 0 (idempotency)" {
    _load_module
    is_installed() { return 0; }
    run install
    assert_success
    assert_output --partial "already installed"
}

# ── Recommendation logic ─────────────────────────────────────────────────────

@test "is_recommended returns nonzero when already installed" {
    _load_module
    is_installed() { return 0; }
    run is_recommended
    assert_failure
}

@test "is_recommended returns nonzero inside a container" {
    _load_module
    is_installed() { return 1; }
    systemd-detect-virt() {
        [[ "$*" == *"--container"* ]] && return 0
        return 1
    }
    export -f systemd-detect-virt
    run is_recommended
    assert_failure
}

@test "is_recommended returns 0 when not installed and not in a container" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    systemd-detect-virt() { return 1; }
    export -f systemd-detect-virt
    run is_recommended
    assert_success
}

# ── detect ───────────────────────────────────────────────────────────────────

@test "detect succeeds on Ubuntu (mocked lsb_release)" {
    _load_module
    _mock_lsb_release
    MOCK_DISTRIB=Ubuntu
    run detect
    assert_success
}

@test "detect fails on a non-Ubuntu distro" {
    _load_module
    _mock_lsb_release
    MOCK_DISTRIB=Debian
    run detect
    assert_failure
}

@test "detect fails when lsb_release is not on PATH" {
    _load_module
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/empty-bin"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/empty-bin" run detect
    assert_failure
}

# ── Engine discovery (registry scan) ────────────────────────────────────────

@test "registry discovers docker under --tag=container" {
    # shellcheck source=../../../lib/logger.sh
    source "${LIB_DIR}/logger.sh"
    # shellcheck source=../../../lib/registry.sh
    source "${LIB_DIR}/registry.sh"
    export INIT_UBUNTU_USER_MODULE_DIR="${INIT_UBUNTU_TEST_SCRATCH}/user-module"
    registry_load_all "${MODULE_DIR}"
    run registry_list_names --tag=container
    assert_success
    assert_line "docker"
}

# ── Dual-mode standalone CLI (AC-25) ─────────────────────────────────────────

@test "standalone: with no args prints usage + exits 2" {
    run _standalone_module
    assert_failure 2
    assert_output --partial "Usage:"
}

@test "standalone: --help shows the lifecycle phases" {
    run _standalone_module --help
    assert_success
    assert_output --partial "install"
    assert_output --partial "remove"
    assert_output --partial "purge"
}

@test "standalone: --version prints NAME + VERSION_PROVIDED" {
    run _standalone_module --version
    assert_success
    assert_output --partial "docker"
    assert_output --partial "apt-managed"
}

@test "standalone: unknown phase exits 2" {
    run _standalone_module frobnicate
    assert_failure 2
}

@test "standalone: info prints metadata" {
    run _standalone_module info
    assert_success
    assert_output --partial "name:        docker"
    assert_output --partial "category:    recommended"
    assert_output --partial "container"
    assert_output --partial "curl"
}

@test "standalone: info --lang=zh-TW prints the localized description" {
    run _standalone_module info --lang=zh-TW
    assert_success
    assert_output --partial "容器引擎"
}

@test "standalone: status reports installed + outdated fields" {
    run _standalone_module status
    assert_success
    assert_output --partial "installed:"
    assert_output --partial "outdated:"
}

@test "AC-25 standalone install --dry-run exits 0 with DRY-RUN output" {
    run _standalone_module install --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "AC-25 standalone upgrade --dry-run exits 0" {
    run _standalone_module upgrade --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "AC-25 standalone remove --dry-run exits 0" {
    run _standalone_module remove --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "AC-25 standalone purge --dry-run exits 0" {
    run _standalone_module purge --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "AC-25 standalone verify --dry-run exits 0" {
    run _standalone_module verify --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "AC-25 standalone detect runs (exit != 2)" {
    run _standalone_module detect
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "AC-25 standalone is-installed runs (exit != 2)" {
    run _standalone_module is-installed
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "AC-25 standalone is-recommended runs (exit != 2)" {
    run _standalone_module is-recommended
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "standalone: is-outdated degrades gracefully (not implemented yet, exit 2)" {
    # docker does not implement is_outdated (apt-managed; AC-25 backlog).
    # Pin the CLI contract: clear message + exit 2 instead of a crash.
    run _standalone_module is-outdated
    assert_failure 2
    assert_output --partial "not implemented"
}

@test "standalone: doctor degrades gracefully (not implemented yet, exit 2)" {
    run _standalone_module doctor
    assert_failure 2
    assert_output --partial "not implemented"
}

@test "standalone dry-run install creates no files in a scratch HOME" {
    local _home="${INIT_UBUNTU_TEST_SCRATCH}/home-clean"
    mkdir -p "${_home}"
    HOME="${_home}" XDG_STATE_HOME="" INIT_UBUNTU_STATE_DIR="" \
        run _standalone_module install --dry-run
    assert_success
    [[ -z "$(find "${_home}" -mindepth 1 2>/dev/null)" ]]
}
