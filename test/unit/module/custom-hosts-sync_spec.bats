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

# ── detect(): systemctl gate ─────────────────────────────────────────────────

@test "detect succeeds when systemctl is on PATH" {
    _load_module
    local _bin="${INIT_UBUNTU_TEST_SCRATCH}/detectbin"
    mkdir -p "${_bin}"
    printf '#!/usr/bin/env bash\n' > "${_bin}/systemctl"
    chmod +x "${_bin}/systemctl"
    PATH="${_bin}:${PATH}" run detect
    assert_success
}

@test "detect fails when systemctl is absent (no systemd)" {
    _load_module
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/emptybin" run detect
    assert_failure
}

# ── is_recommended: already-installed short-circuit ──────────────────────────

@test "is_recommended is false when the module is already installed" {
    _load_module
    _mock_is_installed
    MOCK_IS_INSTALLED_RC=0 run is_recommended
    assert_failure
}

# ── upgrade() ────────────────────────────────────────────────────────────────

@test "upgrade in dry-run mode is a no-op" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run upgrade
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "upgrade re-deploys the tracked files with the real HOME substituted" {
    _load_module
    _use_scratch_home
    _mock_have_sudo
    _mock_sudo_record
    MOCK_SUDO_ACCESS_RC=0 run upgrade
    assert_success
    # Re-deployed script + units; placeholder gone.
    run cat "${MOCK_TEE_DIR}/sync-custom-hosts"
    assert_success
    refute_output --partial "__USER_HOME__"
    run cat "${MOCK_SUDO_LOG}"
    assert_output --partial "systemctl enable --now custom-hosts-sync.path"
}

@test "upgrade without sudo access fails with a clear error" {
    _load_module
    _mock_have_sudo
    MOCK_SUDO_ACCESS_RC=1 run upgrade
    assert_failure
    assert_output --partial "sudo required"
}

# ── remove() real path ───────────────────────────────────────────────────────

@test "remove on a clean container short-circuits (not installed)" {
    _load_module
    run remove
    assert_success
    assert_output --partial "not installed"
}

@test "remove disables the units and deletes the deployed files" {
    _load_module
    _mock_is_installed
    _mock_have_sudo
    _mock_sudo_record
    MOCK_IS_INSTALLED_RC=0 MOCK_SUDO_ACCESS_RC=0 run remove
    assert_success
    run cat "${MOCK_SUDO_LOG}"
    assert_output --partial "systemctl disable --now custom-hosts-sync.path"
    assert_output --partial "systemctl disable --now custom-hosts-sync.service"
    assert_output --partial "rm -f /etc/systemd/system/custom-hosts-sync.path"
}

@test "remove without sudo access fails with a clear error" {
    _load_module
    _mock_is_installed
    _mock_have_sudo
    MOCK_IS_INSTALLED_RC=0 MOCK_SUDO_ACCESS_RC=1 run remove
    assert_failure
    assert_output --partial "sudo required"
}

# ── purge() real path ────────────────────────────────────────────────────────

@test "purge removes the units and wipes the user master directory" {
    _load_module
    _use_scratch_home
    _mock_is_installed
    _mock_have_sudo
    _mock_sudo_record
    mkdir -p "${HOME}/.config/hosts-custom"
    printf '10.0.0.1 keep.me\n' > "${HOME}/.config/hosts-custom/hosts.custom"
    MOCK_IS_INSTALLED_RC=0 MOCK_SUDO_ACCESS_RC=0 run purge
    assert_success
    [[ ! -d "${HOME}/.config/hosts-custom" ]]
}

# ── verify() ─────────────────────────────────────────────────────────────────

@test "verify fails on a clean container (sync script absent)" {
    _load_module
    run verify
    assert_failure
}

# ── is_outdated() ────────────────────────────────────────────────────────────

# Point the deployed-file globals at scratch paths so drift can be simulated
# without touching /usr/local/bin or /etc.
_stage_deployed() {
    local _stage="${INIT_UBUNTU_TEST_SCRATCH}/deployed"
    mkdir -p "${_stage}"
    CHS_SCRIPT="${_stage}/sync-custom-hosts"
    CHS_SERVICE="${_stage}/custom-hosts-sync.service"
    CHS_PATH_UNIT="${_stage}/custom-hosts-sync.path"
    # Render the committed templates the same way _chs_deploy_files does.
    sed "s#__USER_HOME__#${HOME}#g" "${CHS_SRC}/sync-custom-hosts" > "${CHS_SCRIPT}"
    chmod 0755 "${CHS_SCRIPT}"
    cp "${CHS_SRC}/custom-hosts-sync.service" "${CHS_SERVICE}"
    sed "s#__USER_HOME__#${HOME}#g" "${CHS_SRC}/custom-hosts-sync.path" > "${CHS_PATH_UNIT}"
}

@test "is_outdated returns nonzero when the module is not installed" {
    _load_module
    run is_outdated
    assert_failure
}

@test "is_outdated is false when deployed files match the committed templates" {
    _load_module
    _use_scratch_home
    _stage_deployed
    run is_outdated
    assert_failure
}

@test "is_outdated is true when the deployed sync script has drifted" {
    _load_module
    _use_scratch_home
    _stage_deployed
    printf '\n# drift\n' >> "${CHS_SCRIPT}"
    run is_outdated
    assert_success
}

# ── doctor() ─────────────────────────────────────────────────────────────────

@test "doctor warns and fails when the module is not installed" {
    _load_module
    run doctor
    assert_failure
    assert_output --partial "not installed"
}

@test "doctor fails when the sync script is missing or not executable" {
    _load_module
    _mock_is_installed
    CHS_SCRIPT="${INIT_UBUNTU_TEST_SCRATCH}/not-there"
    MOCK_IS_INSTALLED_RC=0 run doctor
    assert_failure
    assert_output --partial "not executable"
}

@test "doctor fails when the sync script has bash syntax errors" {
    _load_module
    _mock_is_installed
    CHS_SCRIPT="${INIT_UBUNTU_TEST_SCRATCH}/broken-sync"
    printf '#!/usr/bin/env bash\nif then fi\n' > "${CHS_SCRIPT}"
    chmod +x "${CHS_SCRIPT}"
    MOCK_IS_INSTALLED_RC=0 run doctor
    assert_failure
    assert_output --partial "syntax errors"
}

# Put a fake `systemctl` on PATH whose `is-active` subcommand exits with the
# given code (a PATH stub, not a shell function, so it does not trip SC2032 on
# the module's `sudo systemctl` call sites).
_stub_systemctl() {
    local _bin="${INIT_UBUNTU_TEST_SCRATCH}/sctlbin"
    mkdir -p "${_bin}"
    cat > "${_bin}/systemctl" <<EOF
#!/usr/bin/env bash
[[ "\$1" == "is-active" ]] && exit ${1}
exit 0
EOF
    chmod +x "${_bin}/systemctl"
    printf '%s' "${_bin}"
}

@test "doctor warns but succeeds when the path unit is not active" {
    _load_module
    _mock_is_installed
    CHS_SCRIPT="${INIT_UBUNTU_TEST_SCRATCH}/ok-sync"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${CHS_SCRIPT}"
    chmod +x "${CHS_SCRIPT}"
    local _bin; _bin="$(_stub_systemctl 1)"   # is-active -> inactive (nonzero)
    MOCK_IS_INSTALLED_RC=0 PATH="${_bin}:${PATH}" run doctor
    assert_success
    assert_output --partial "not active"
}

@test "doctor succeeds cleanly when the path unit is active" {
    _load_module
    _mock_is_installed
    CHS_SCRIPT="${INIT_UBUNTU_TEST_SCRATCH}/ok-sync"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${CHS_SCRIPT}"
    chmod +x "${CHS_SCRIPT}"
    local _bin; _bin="$(_stub_systemctl 0)"   # is-active -> active
    MOCK_IS_INSTALLED_RC=0 PATH="${_bin}:${PATH}" run doctor
    assert_success
}

# ── Standalone CLI (AC-25) ───────────────────────────────────────────────────

@test "standalone info runs and prints the module name" {
    run _standalone_module info
    assert_success
    assert_output --partial "custom-hosts-sync"
}
