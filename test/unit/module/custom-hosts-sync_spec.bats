#!/usr/bin/env bats
# shellcheck disable=SC2317  # test mocks (sudo/have_sudo_access/is_installed) dispatched indirectly when the module under test resolves shell functions — https://www.shellcheck.net/wiki/SC2317
# test/unit/module/custom-hosts-sync_spec.bats — module/custom-hosts-sync.module.sh (issue #145)
#
# Covers: metadata sanity, is_installed on a clean container, dry-run no-ops,
# install idempotency short-circuit, is_recommended svpn heuristic, presence of
# the committed template files + __USER_HOME__ placeholders, a mocked install()
# that asserts the placeholder is substituted with the real $HOME (no hardcoded
# username), and the real sync-custom-hosts merge logic (managed block, F5
# gateway line preserved, idempotency, entry removal, missing master).

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
    CHS_SRC="${MODULE_DIR}/config/custom-hosts-sync"
    SYNC_SCRIPT="${CHS_SRC}/sync-custom-hosts"
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
    # shellcheck source=../../../module/custom-hosts-sync.module.sh
    source "${MODULE_DIR}/custom-hosts-sync.module.sh"
}

_standalone_module() {
    bash "${MODULE_DIR}/custom-hosts-sync.module.sh" "$@"
}

# ── Controllable mocks ───────────────────────────────────────────────────────
_mock_is_installed() {
    is_installed() { return "${MOCK_IS_INSTALLED_RC:-0}"; }
}

_mock_have_sudo() {
    have_sudo_access() { return "${MOCK_SUDO_ACCESS_RC:-0}"; }
}

_use_scratch_home() {
    export HOME="${INIT_UBUNTU_TEST_SCRATCH}/home"
    mkdir -p "${HOME}"
}

# Recording sudo mock: appends every call to MOCK_SUDO_LOG; `sudo tee <path>`
# routes captured stdin into MOCK_TEE_DIR/<basename>.
_mock_sudo_record() {
    MOCK_SUDO_LOG="${INIT_UBUNTU_TEST_SCRATCH}/sudo.log"
    MOCK_TEE_DIR="${INIT_UBUNTU_TEST_SCRATCH}/tee"
    mkdir -p "${MOCK_TEE_DIR}"
    : > "${MOCK_SUDO_LOG}"
    sudo() {
        printf '%s\n' "$*" >> "${MOCK_SUDO_LOG}"
        case "${1:-}" in
            tee) cat > "${MOCK_TEE_DIR}/$(basename "${2:-out}")" ;;
            *) : ;;
        esac
        return 0
    }
}

# ── Metadata sanity ──────────────────────────────────────────────────────────

@test "module declares NAME=custom-hosts-sync" {
    _load_module
    [[ "${NAME}" == "custom-hosts-sync" ]]
}

@test "CATEGORY is one of base|recommended|optional|experimental" {
    _load_module
    case "${CATEGORY}" in
        base|recommended|optional|experimental) :;;
        *) printf "unexpected CATEGORY=%s\n" "${CATEGORY}" >&2; return 1 ;;
    esac
}

@test "declares no module dependencies (self-contained)" {
    _load_module
    [[ "${#DEPENDS_ON[@]}" -eq 0 ]]
}

@test "INSTALL_TARGET_DEFAULT is sudo (writes to /etc and /usr/local/bin)" {
    _load_module
    [[ "${INSTALL_TARGET_DEFAULT}" == "sudo" ]]
}

# ── is_installed on a clean container ────────────────────────────────────────

@test "is_installed returns nonzero on a fresh test container" {
    _load_module
    run is_installed
    assert_failure
}

# ── Dry-run no-ops ───────────────────────────────────────────────────────────

@test "install in dry-run mode is a no-op" {
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

@test "purge in dry-run mode is a no-op" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run purge
    assert_success
    assert_output --partial "DRY-RUN"
}

# ── Idempotency: install short-circuits when already installed ────────────────

@test "install short-circuits when already installed" {
    _load_module
    _mock_is_installed
    MOCK_IS_INSTALLED_RC=0 run install
    assert_success
    assert_output --partial "already installed"
}

# ── is_recommended: svpn heuristic ───────────────────────────────────────────

@test "is_recommended is false when svpn (F5 client) is absent" {
    _load_module
    _mock_is_installed
    # Not installed, and svpn not on PATH -> not recommended.
    MOCK_IS_INSTALLED_RC=1 PATH="${INIT_UBUNTU_TEST_SCRATCH}/emptybin" run is_recommended
    assert_failure
}

@test "is_recommended is true when svpn is present and not installed" {
    _load_module
    _mock_is_installed
    local _bin="${INIT_UBUNTU_TEST_SCRATCH}/fakebin"
    mkdir -p "${_bin}"
    printf '#!/usr/bin/env bash\n' > "${_bin}/svpn"
    chmod +x "${_bin}/svpn"
    MOCK_IS_INSTALLED_RC=1 PATH="${_bin}:${PATH}" run is_recommended
    assert_success
}

# ── Committed template files + placeholders ──────────────────────────────────

@test "committed template files all exist" {
    [[ -f "${CHS_SRC}/hosts.custom.example" ]]
    [[ -f "${CHS_SRC}/sync-custom-hosts" ]]
    [[ -f "${CHS_SRC}/custom-hosts-sync.service" ]]
    [[ -f "${CHS_SRC}/custom-hosts-sync.path" ]]
}

@test "sync-custom-hosts carries the __USER_HOME__ placeholder (no hardcoded home)" {
    grep -q "__USER_HOME__" "${CHS_SRC}/sync-custom-hosts"
}

@test "custom-hosts-sync.path carries the __USER_HOME__ placeholder" {
    grep -q "__USER_HOME__" "${CHS_SRC}/custom-hosts-sync.path"
}

@test "no committed source hardcodes a real /home/<user> path" {
    run grep -REn "/home/[a-z]" "${CHS_SRC}" module/custom-hosts-sync.module.sh
    assert_failure
}

@test "service unit ExecStart points at the deployed script" {
    grep -q "ExecStart=/usr/local/bin/sync-custom-hosts" "${CHS_SRC}/custom-hosts-sync.service"
}

# ── install(): placeholder substituted with the real HOME, files deployed ─────

@test "install substitutes __USER_HOME__ with the real HOME and seeds the master list" {
    _load_module
    _use_scratch_home
    _mock_have_sudo
    _mock_sudo_record
    MOCK_SUDO_ACCESS_RC=0 run install
    assert_success

    # Master list seeded from the example, user-owned under HOME.
    [[ -f "${HOME}/.config/hosts-custom/hosts.custom" ]]

    # Deployed sync script: placeholder replaced with the real HOME, none left.
    run cat "${MOCK_TEE_DIR}/sync-custom-hosts"
    assert_success
    assert_output --partial "${HOME}/.config/hosts-custom/hosts.custom"
    refute_output --partial "__USER_HOME__"

    # Deployed path unit: watches the real master list, placeholder gone.
    run cat "${MOCK_TEE_DIR}/custom-hosts-sync.path"
    assert_output --partial "PathChanged=${HOME}/.config/hosts-custom/hosts.custom"
    refute_output --partial "__USER_HOME__"

    # Path unit enabled.
    run cat "${MOCK_SUDO_LOG}"
    assert_output --partial "systemctl enable --now custom-hosts-sync.path"
}

@test "install does not clobber an existing master list" {
    _load_module
    _use_scratch_home
    _mock_have_sudo
    _mock_sudo_record
    mkdir -p "${HOME}/.config/hosts-custom"
    printf '10.1.2.3 preexisting.entry\n' > "${HOME}/.config/hosts-custom/hosts.custom"
    MOCK_SUDO_ACCESS_RC=0 run install
    assert_success
    run cat "${HOME}/.config/hosts-custom/hosts.custom"
    assert_output --partial "preexisting.entry"
}

# ── Core sync logic (the deployed sync-custom-hosts) ─────────────────────────
# Exercised via the CUSTOM_HOSTS_MASTER / CUSTOM_HOSTS_FILE env seams so no real
# /etc/hosts is touched.

_setup_sync_fixture() {
    HOSTS_FILE="${INIT_UBUNTU_TEST_SCRATCH}/etc-hosts"
    MASTER_FILE="${INIT_UBUNTU_TEST_SCRATCH}/hosts.custom"
    cat > "${HOSTS_FILE}" <<'HOSTS'
127.0.0.1 localhost
127.0.1.1 mymachine
203.0.113.9 vpn.f5.gateway  #F5 Networks Inc. :File modified by VPN process
HOSTS
    cat > "${MASTER_FILE}" <<'MASTER'
10.0.0.10 host.example-a
192.0.2.50 host.example-c
MASTER
}

_run_sync() {
    CUSTOM_HOSTS_MASTER="${MASTER_FILE}" CUSTOM_HOSTS_FILE="${HOSTS_FILE}" \
        run bash "${SYNC_SCRIPT}"
}

@test "sync merges master entries into a managed block and preserves the F5 line" {
    _setup_sync_fixture
    _run_sync
    assert_success
    run cat "${HOSTS_FILE}"
    assert_output --partial "# >>> custom-hosts (managed"
    assert_output --partial "# <<< custom-hosts (managed) <<<"
    assert_output --partial "10.0.0.10 host.example-a"
    assert_output --partial "192.0.2.50 host.example-c"
    # F5 gateway line and other unmanaged content survive untouched.
    assert_output --partial "vpn.f5.gateway"
    assert_output --partial "127.0.0.1 localhost"
}

@test "sync is idempotent: a second run leaves the file byte-identical" {
    _setup_sync_fixture
    _run_sync
    assert_success
    local _first
    _first="$(cat "${HOSTS_FILE}")"
    _run_sync
    assert_success
    [[ "$(cat "${HOSTS_FILE}")" == "${_first}" ]]
}

@test "sync removes an entry from /etc/hosts once it is dropped from the master" {
    _setup_sync_fixture
    _run_sync
    assert_success
    grep -q "host.example-a" "${HOSTS_FILE}"
    # Drop host.example-a from the master and re-sync.
    printf '192.0.2.50 host.example-c\n' > "${MASTER_FILE}"
    _run_sync
    assert_success
    run grep "host.example-a" "${HOSTS_FILE}"
    assert_failure
    grep -q "host.example-c" "${HOSTS_FILE}"
}

@test "sync exits 0 and leaves /etc/hosts untouched when the master is missing" {
    _setup_sync_fixture
    rm -f "${MASTER_FILE}"
    local _before
    _before="$(cat "${HOSTS_FILE}")"
    _run_sync
    assert_success
    [[ "$(cat "${HOSTS_FILE}")" == "${_before}" ]]
}

# ── Standalone CLI (AC-25) ───────────────────────────────────────────────────

@test "standalone info runs and prints the module name" {
    run _standalone_module info
    assert_success
    assert_output --partial "custom-hosts-sync"
}
