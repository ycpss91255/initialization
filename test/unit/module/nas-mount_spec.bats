#!/usr/bin/env bats
# shellcheck disable=SC2317  # test mocks (sudo/dpkg/have_sudo_access) are dispatched indirectly when the module under test resolves shell functions — https://www.shellcheck.net/wiki/SC2317
# test/unit/module/nas-mount_spec.bats — module/nas-mount.module.sh (issue #311)
#
# Coverage per doc/module-spec.md §7: smoke / metadata / lifecycle dry-run /
# no-side-effects / is_installed state / idempotency / standalone CLI, plus
# nas-mount-specific behavior: apt driver install, autofs wiring only when the
# NAS parameters are supplied, credentials file forced to chmod 600 and kept
# out of the repo, purge wiping the maps + credentials.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
    # Never let real NAS env leak into a test.
    unset INIT_UBUNTU_NAS_HOST INIT_UBUNTU_NAS_SHARE INIT_UBUNTU_NAS_USER \
          INIT_UBUNTU_NAS_PASSWORD INIT_UBUNTU_NAS_MOUNT_BASE \
          INIT_UBUNTU_NAS_CREDENTIALS
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
    # shellcheck source=../../../module/nas-mount.module.sh
    source "${MODULE_DIR}/nas-mount.module.sh"
}

_standalone_module() {
    bash "${MODULE_DIR}/nas-mount.module.sh" "$@"
}

# ── Controllable mocks ───────────────────────────────────────────────────────

_mock_is_installed() {
    is_installed() { return "${MOCK_IS_INSTALLED_RC:-0}"; }
}

_mock_have_sudo() {
    have_sudo_access() { return "${MOCK_SUDO_ACCESS_RC:-0}"; }
}

# dpkg mock: `dpkg -l <pkg>` emits MOCK_DPKG_OUTPUT / returns MOCK_DPKG_RC.
_mock_dpkg() {
    dpkg() {
        [[ -n "${MOCK_DPKG_OUTPUT:-}" ]] && printf '%s\n' "${MOCK_DPKG_OUTPUT}"
        return "${MOCK_DPKG_RC:-0}"
    }
}

_mock_lsb_release() {
    lsb_release() {
        case "$*" in
            *-is*) printf '%s\n' "${MOCK_DISTRIB:-Ubuntu}" ;;
        esac
        return 0
    }
}

# Recording sudo mock. apt-get / systemctl are logged but NOT executed;
# filesystem ops (mkdir / chmod / rm / rmdir) run for real against scratch
# paths, and `tee` writes its piped stdin to the target file so the autofs
# maps + credentials materialise where the assertions can inspect them.
_mock_sudo_record() {
    MOCK_SUDO_LOG="${INIT_UBUNTU_TEST_SCRATCH}/sudo.log"
    : > "${MOCK_SUDO_LOG}"
    sudo() {
        printf '%s\n' "$*" >> "${MOCK_SUDO_LOG}"
        case "${1:-}" in
            apt-get|systemctl) return 0 ;;
            tee)   shift; tee "$@" >/dev/null ;;
            mkdir|chmod|rm|rmdir) "$@" ;;
            *) return 0 ;;
        esac
    }
}

# Wires a full mocked install: not installed, sudo ok, apt/systemctl inert.
_mock_install_env() {
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    _mock_have_sudo
    _mock_dpkg
    _mock_sudo_record
}

# Redirect the module's system paths into the per-test scratch dir.
_scratch_paths() {
    export INIT_UBUNTU_NAS_MOUNT_BASE="${INIT_UBUNTU_TEST_SCRATCH}/mnt-nas"
    export INIT_UBUNTU_NAS_CREDENTIALS="${INIT_UBUNTU_TEST_SCRATCH}/etc/nas/credentials"
    NAS_MASTER_MAP="${INIT_UBUNTU_TEST_SCRATCH}/auto.master.d/nas-mount.autofs"
    NAS_MAP_FILE="${INIT_UBUNTU_TEST_SCRATCH}/auto.nas-mount"
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "nas-mount module file exists" {
    [[ -f "${MODULE_DIR}/nas-mount.module.sh" ]]
}

@test "nas-mount module parses (bash -n)" {
    run bash -n "${MODULE_DIR}/nas-mount.module.sh"
    assert_success
}

@test "sourcing in engine mode sets MODULE_STANDALONE=false (no lifecycle run)" {
    _load_module
    [[ "${MODULE_STANDALONE}" == "false" ]]
}

# ── Metadata sanity ──────────────────────────────────────────────────────────

@test "nas-mount module declares NAME=nas-mount" {
    _load_module
    [[ "${NAME}" == "nas-mount" ]]
}

@test "nas-mount CATEGORY=optional" {
    _load_module
    [[ "${CATEGORY}" == "optional" ]]
}

@test "nas-mount DESCRIPTION is associative with en + zh-TW" {
    _load_module
    [[ "$(declare -p DESCRIPTION 2>/dev/null)" == 'declare -'*A* ]]
    [[ -n "$(module_get_description en)" ]]
    [[ -n "$(module_get_description zh-TW)" ]]
    [[ "$(module_get_description en)" == *"CIFS"* ]]
}

@test "nas-mount VERSION_PROVIDED=apt-managed" {
    _load_module
    [[ "${VERSION_PROVIDED}" == "apt-managed" ]]
}

@test "nas-mount TAGS contain network + storage" {
    _load_module
    [[ " ${TAGS[*]} " == *" network "* ]]
    [[ " ${TAGS[*]} " == *" storage "* ]]
}

@test "nas-mount SUPPORTED_UBUNTU covers 22.04 24.04 26.04" {
    _load_module
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 22.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 24.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 26.04 "* ]]
}

@test "nas-mount SUPPORTS_USER_HOME=false and INSTALL_TARGET_DEFAULT=sudo" {
    _load_module
    [[ "${SUPPORTS_USER_HOME}" == "false" ]]
    [[ "${INSTALL_TARGET_DEFAULT}" == "sudo" ]]
}

@test "nas-mount RISK_LEVEL=low and REBOOT_REQUIRED=false" {
    _load_module
    [[ "${RISK_LEVEL}" == "low" ]]
    [[ "${REBOOT_REQUIRED}" == "false" ]]
}

@test "nas-mount APT_PKGS include cifs-utils autofs smbclient" {
    _load_module
    local _pkg
    for _pkg in cifs-utils autofs smbclient; do
        [[ " ${APT_PKGS[*]} " == *" ${_pkg} "* ]] || {
            printf 'missing apt package: %s\n' "${_pkg}" >&2
            return 1
        }
    done
}

@test "nas-mount POST_INSTALL_MESSAGE points at the NAS env vars" {
    _load_module
    [[ "$(declare -p POST_INSTALL_MESSAGE 2>/dev/null)" == 'declare -'*A* ]]
    [[ "$(module_get_post_install_message en)" == *"INIT_UBUNTU_NAS_HOST"* ]]
    [[ -n "$(module_get_post_install_message zh-TW)" ]]
}

@test "nas-mount TEST_VERIFY_CMD checks mount.cifs + smbclient" {
    _load_module
    [[ "${TEST_VERIFY_CMD}" == *"mount.cifs"* ]]
    [[ "${TEST_VERIFY_CMD}" == *"smbclient"* ]]
}

# ── No hardcoded personal data ──────────────────────────────────────────────

@test "module source carries no hardcoded host/user/password" {
    # Strip comments first (doc examples like "e.g. 192.168.1.10" are fine),
    # then look for literal credential assignments or IP literals in code.
    run grep -nE '(password|username)=[A-Za-z0-9]|[0-9]{1,3}(\.[0-9]{1,3}){3}' \
        <(grep -vE '^[[:space:]]*#' "${MODULE_DIR}/nas-mount.module.sh")
    # grep exits 1 (no matches) when the code is clean.
    assert_failure
}

# ── Lifecycle presence ───────────────────────────────────────────────────────

@test "nas-mount defines its hand-written lifecycle functions" {
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

# ── is_installed ─────────────────────────────────────────────────────────────

@test "is_installed returns nonzero on a fresh container" {
    _load_module
    run is_installed
    assert_failure
}

@test "is_installed returns zero when dpkg reports the drivers as ii" {
    _load_module
    MOCK_DPKG_OUTPUT='ii  cifs-utils  2:7.0  amd64  cifs mount helper'
    _mock_dpkg
    run is_installed
    assert_success
}

# ── Dry-run no-ops ───────────────────────────────────────────────────────────

@test "install in dry-run mode is a no-op" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "upgrade in dry-run mode is a no-op" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run upgrade
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "remove in dry-run mode is a no-op" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run remove
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "purge in dry-run mode is a no-op" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run purge
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "verify in dry-run mode is a no-op" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run verify
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "dry-run install writes nothing under the state dir" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/nas-mount" ]]
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/state.json" ]]
}

@test "read-only phases leave the state dir untouched" {
    _load_module
    _mock_lsb_release
    detect || true
    is_installed || true
    is_recommended || true
    [[ -z "$(find "${INIT_UBUNTU_STATE_DIR}" -type f 2>/dev/null)" ]]
}

# ── is_recommended ───────────────────────────────────────────────────────────

@test "is_recommended is never auto-selected (needs site credentials)" {
    _load_module
    run is_recommended
    assert_failure
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

# ── install: apt drivers ─────────────────────────────────────────────────────

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

@test "install runs apt-get for the three driver/tool packages" {
    _load_module
    _mock_install_env
    run install
    assert_success
    run cat "${MOCK_SUDO_LOG}"
    assert_output --partial "apt-get update"
    assert_output --partial "apt-get install -y cifs-utils autofs smbclient"
}

@test "install without NAS env installs packages but does not wire autofs" {
    _load_module
    _mock_install_env
    _scratch_paths
    run install
    assert_success
    assert_output --partial "automounter not wired"
    [[ ! -e "${NAS_MASTER_MAP}" ]]
    [[ ! -e "${NAS_MAP_FILE}" ]]
}

# ── install: autofs wiring (configured) ─────────────────────────────────────

@test "install wires autofs maps when NAS env + credentials file are present" {
    _load_module
    _mock_install_env
    _scratch_paths
    INIT_UBUNTU_NAS_HOST=nas.example.lan
    INIT_UBUNTU_NAS_SHARE=media
    INIT_UBUNTU_NAS_USER=someuser
    mkdir -p "$(dirname "${INIT_UBUNTU_NAS_CREDENTIALS}")"
    printf 'username=someuser\npassword=secret\n' > "${INIT_UBUNTU_NAS_CREDENTIALS}"
    chmod 644 "${INIT_UBUNTU_NAS_CREDENTIALS}"
    run install
    assert_success
    # Master map points autofs at the indirect map for the mount base.
    run cat "${NAS_MASTER_MAP}"
    assert_output --partial "${INIT_UBUNTU_NAS_MOUNT_BASE}"
    assert_output --partial "${NAS_MAP_FILE}"
    # Indirect map wires the share to the CIFS host.
    run cat "${NAS_MAP_FILE}"
    assert_output --partial "fstype=cifs"
    assert_output --partial "://nas.example.lan/media"
    assert_output --partial "credentials=${INIT_UBUNTU_NAS_CREDENTIALS}"
}

@test "install forces the credentials file to chmod 600" {
    _load_module
    _mock_install_env
    _scratch_paths
    INIT_UBUNTU_NAS_HOST=nas.example.lan
    INIT_UBUNTU_NAS_SHARE=media
    INIT_UBUNTU_NAS_USER=someuser
    mkdir -p "$(dirname "${INIT_UBUNTU_NAS_CREDENTIALS}")"
    printf 'username=someuser\npassword=secret\n' > "${INIT_UBUNTU_NAS_CREDENTIALS}"
    chmod 644 "${INIT_UBUNTU_NAS_CREDENTIALS}"
    run install
    assert_success
    run stat -c '%a' "${INIT_UBUNTU_NAS_CREDENTIALS}"
    assert_output "600"
}

@test "install generates a chmod-600 credentials file from INIT_UBUNTU_NAS_PASSWORD" {
    _load_module
    _mock_install_env
    _scratch_paths
    INIT_UBUNTU_NAS_HOST=nas.example.lan
    INIT_UBUNTU_NAS_SHARE=media
    INIT_UBUNTU_NAS_USER=someuser
    INIT_UBUNTU_NAS_PASSWORD=hunter2
    [[ ! -e "${INIT_UBUNTU_NAS_CREDENTIALS}" ]]
    run install
    assert_success
    [[ -f "${INIT_UBUNTU_NAS_CREDENTIALS}" ]]
    run stat -c '%a' "${INIT_UBUNTU_NAS_CREDENTIALS}"
    assert_output "600"
    run cat "${INIT_UBUNTU_NAS_CREDENTIALS}"
    assert_output --partial "username=someuser"
    assert_output --partial "password=hunter2"
}

@test "install skips wiring when configured but no credentials are available" {
    _load_module
    _mock_install_env
    _scratch_paths
    INIT_UBUNTU_NAS_HOST=nas.example.lan
    INIT_UBUNTU_NAS_SHARE=media
    INIT_UBUNTU_NAS_USER=someuser
    run install
    assert_success
    assert_output --partial "skipping autofs wiring"
    [[ ! -e "${NAS_MASTER_MAP}" ]]
}

# ── Idempotency ──────────────────────────────────────────────────────────────

@test "install short-circuits when is_installed returns 0 (idempotency)" {
    _load_module
    is_installed() { return 0; }
    run install
    assert_success
    assert_output --partial "already installed"
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

@test "remove unwires autofs and apt-removes the packages when installed" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    _mock_sudo_record
    _scratch_paths
    mkdir -p "$(dirname "${NAS_MASTER_MAP}")"
    : > "${NAS_MASTER_MAP}"
    : > "${NAS_MAP_FILE}"
    run remove
    assert_success
    [[ ! -e "${NAS_MASTER_MAP}" ]]
    [[ ! -e "${NAS_MAP_FILE}" ]]
    run cat "${MOCK_SUDO_LOG}"
    assert_output --partial "apt-get remove -y cifs-utils autofs smbclient"
}

@test "purge wipes autofs maps + credentials and apt-purges (mocked sudo)" {
    _load_module
    _mock_sudo_record
    _scratch_paths
    mkdir -p "$(dirname "${NAS_MASTER_MAP}")" "$(dirname "${INIT_UBUNTU_NAS_CREDENTIALS}")"
    : > "${NAS_MASTER_MAP}"
    : > "${NAS_MAP_FILE}"
    printf 'username=x\npassword=y\n' > "${INIT_UBUNTU_NAS_CREDENTIALS}"
    run purge
    assert_success
    [[ ! -e "${NAS_MASTER_MAP}" ]]
    [[ ! -e "${NAS_MAP_FILE}" ]]
    [[ ! -e "${INIT_UBUNTU_NAS_CREDENTIALS}" ]]
    run cat "${MOCK_SUDO_LOG}"
    assert_output --partial "apt-get purge -y"
}

@test "purge on a clean system still exits 0 (idempotent)" {
    _load_module
    _mock_sudo_record
    _scratch_paths
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
    assert_output --partial "nas-mount"
    assert_output --partial "apt-managed"
}

@test "standalone: unknown phase exits 2" {
    run _standalone_module frobnicate
    assert_failure 2
}

@test "standalone: info prints metadata" {
    run _standalone_module info
    assert_success
    assert_output --partial "name:        nas-mount"
    assert_output --partial "category:    optional"
}

@test "standalone: info --lang=zh-TW prints the localized description" {
    run _standalone_module info --lang=zh-TW
    assert_success
    assert_output --partial "自動掛載"
}

@test "standalone: status reports installed + outdated fields" {
    run _standalone_module status
    assert_success
    assert_output --partial "installed:"
    assert_output --partial "outdated:"
}

@test "standalone install --dry-run exits 0 with DRY-RUN output" {
    run _standalone_module install --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "standalone detect runs (exit != 2)" {
    run _standalone_module detect
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "standalone is-installed runs (exit != 2)" {
    run _standalone_module is-installed
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "standalone is-recommended runs (exit != 2)" {
    run _standalone_module is-recommended
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "standalone: is-outdated degrades gracefully (not implemented, exit 2)" {
    run _standalone_module is-outdated
    assert_failure 2
    assert_output --partial "not implemented"
}

@test "standalone: doctor degrades gracefully (not implemented, exit 2)" {
    run _standalone_module doctor
    assert_failure 2
    assert_output --partial "not implemented"
}

# ── Engine discovery (registry scan) ────────────────────────────────────────

@test "registry discovers nas-mount under --tag=storage" {
    # shellcheck source=../../../lib/logger.sh
    source "${LIB_DIR}/logger.sh"
    # shellcheck source=../../../lib/registry.sh
    source "${LIB_DIR}/registry.sh"
    export INIT_UBUNTU_USER_MODULE_DIR="${INIT_UBUNTU_TEST_SCRATCH}/user-module"
    registry_load_all "${MODULE_DIR}"
    run registry_list_names --tag=storage
    assert_success
    assert_line "nas-mount"
}
