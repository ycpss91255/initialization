#!/usr/bin/env bats
# shellcheck disable=SC2317  # test mocks (sudo / id / dpkg / ...) are dispatched indirectly by the module under test — https://www.shellcheck.net/wiki/SC2317
# test/unit/module/docker-rootless_spec.bats — module/docker-rootless.module.sh (issue #422)
#
# Archetype D (custom). Every system-changing command goes through `sudo`,
# which is mocked by a recording stub (_mock_system) that also emulates the
# few file operations the module relies on, against a scratch root
# (DOCKER_ROOTLESS_ROOT) and a scratch home. Nothing here touches the host.
#
# Layout: smoke / metadata / detect / is_installed / dry-run / install (account,
# packages marker, subuid, linger, Delegate, setuptool, socket-wait drop-in,
# preflight refusals, AppArmor, GPU) / idempotency / upgrade / remove (reverse
# sequence, package marker, safety guards) / doctor / is_outdated / standalone.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
    export DOCKER_ROOTLESS_ROOT="${INIT_UBUNTU_TEST_SCRATCH}/root"
    export DOCKER_ROOTLESS_USER="rtuser"
    FAKE_HOME="${INIT_UBUNTU_TEST_SCRATCH}/home/rtuser"
    SUDO_LOG="${INIT_UBUNTU_TEST_SCRATCH}/sudo.log"
    PKG_DB="${INIT_UBUNTU_TEST_SCRATCH}/pkgdb"
    USER_FLAG="${INIT_UBUNTU_TEST_SCRATCH}/user_exists"
    mkdir -p "${DOCKER_ROOTLESS_ROOT}/etc" "${DOCKER_ROOTLESS_ROOT}/var/lib/systemd/linger" \
        "${DOCKER_ROOTLESS_ROOT}/etc/systemd/system" "${PKG_DB}"
    : > "${DOCKER_ROOTLESS_ROOT}/etc/subuid"
    : > "${DOCKER_ROOTLESS_ROOT}/etc/subgid"
    : > "${SUDO_LOG}"
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
    # shellcheck source=../../../module/docker-rootless.module.sh
    source "${MODULE_DIR}/docker-rootless.module.sh"
}

_standalone_module() {
    bash "${MODULE_DIR}/docker-rootless.module.sh" "$@"
}

# ── Controllable mocks ───────────────────────────────────────────────────────

_mock_have_sudo() {
    have_sudo_access() { return "${MOCK_SUDO_ACCESS_RC:-0}"; }
}

# Tiny emulated system. State lives in scratch files so it survives `run`
# subshells. MOCK_GROUPS = `id -nG` of the target account (default "rtuser").
_mock_system() {
    id() {
        case "$1" in
            -u) [[ -f "${USER_FLAG}" ]] && { printf '1500\n'; return 0; }; return 1 ;;
            -nG) printf '%s\n' "${MOCK_GROUPS:-rtuser}" ;;
        esac
    }
    getent() { printf 'rtuser:x:1500:1500::%s:/bin/bash\n' "${FAKE_HOME}"; }
    dpkg() { [[ -f "${PKG_DB}/$2" ]] && printf 'Status: install ok installed\n'; }
    sysctl() { printf '%s\n' "${MOCK_USERNS_RESTRICT:-0}"; }
    # systemctl is a PATH stub (not a function): `sudo systemctl ...` is also
    # mocked by sudo() below, and a same-named function trips SC2032. Its
    # answers come from exported MOCK_CDI_REFRESH / MOCK_USER_ACTIVE_RC.
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    cat > "${INIT_UBUNTU_TEST_SCRATCH}/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    list-unit-files) [[ "${MOCK_CDI_REFRESH:-1}" == "1" ]] && printf 'nvidia-cdi-refresh.path enabled\n' ;;
    is-active) exit "${MOCK_USER_ACTIVE_RC:-0}" ;;
esac
exit 0
STUB
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/systemctl"
    export PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}"
    sudo() {
        printf '%s\n' "$*" >> "${SUDO_LOG}"
        [[ "${1:-}" == "-H" ]] && shift
        [[ "${1:-}" == "-u" ]] && shift 2
        case "$1" in
            tee|cat|mkdir|rm|rmdir|sed|test) command "$@"; return $? ;;
            useradd)
                : > "${USER_FLAG}"; mkdir -p "${FAKE_HOME}"
                printf 'rtuser:100000:65536\n' >> "${DOCKER_ROOTLESS_ROOT}/etc/subuid"
                printf 'rtuser:100000:65536\n' >> "${DOCKER_ROOTLESS_ROOT}/etc/subgid" ;;
            usermod)
                printf 'rtuser:100000:65536\n' >> "${DOCKER_ROOTLESS_ROOT}/etc/subuid"
                printf 'rtuser:100000:65536\n' >> "${DOCKER_ROOTLESS_ROOT}/etc/subgid" ;;
            userdel) rm -f "${USER_FLAG}"; rm -rf "${FAKE_HOME}" ;;
            loginctl)
                case "$2" in
                    enable-linger) : > "${DOCKER_ROOTLESS_ROOT}/var/lib/systemd/linger/rtuser" ;;
                    disable-linger) rm -f "${DOCKER_ROOTLESS_ROOT}/var/lib/systemd/linger/rtuser" ;;
                esac ;;
            apt-get) return "${MOCK_APT_RC:-0}" ;;
            env)
                shift
                while [[ "${1:-}" == *=* ]]; do shift; done
                case "$1" in
                    dockerd-rootless-setuptool.sh)
                        mkdir -p "${FAKE_HOME}/.config/systemd/user"
                        : > "${FAKE_HOME}/.config/systemd/user/docker.service" ;;
                    apt-get)
                        [[ "${MOCK_APT_RC:-0}" == "0" ]] || return "${MOCK_APT_RC}"
                        local _a; for _a in "$@"; do
                            case "${_a}" in uidmap|docker-ce-rootless-extras) : > "${PKG_DB}/${_a}" ;; esac
                        done ;;
                esac ;;
        esac
        return 0
    }
}

# Helpers (not inline exports): shellcheck SC2030/SC2031 flag per-test var changes.
_set_cdi_refresh()    { export MOCK_CDI_REFRESH="$1"; }
_set_user_active_rc() { export MOCK_USER_ACTIVE_RC="$1"; }

_mark_user() { : > "${USER_FLAG}"; mkdir -p "${FAKE_HOME}"; }
_mark_pkg()  { : > "${PKG_DB}/$1"; }
_mark_unit() { mkdir -p "${FAKE_HOME}/.config/systemd/user"; : > "${FAKE_HOME}/.config/systemd/user/docker.service"; }

_stub_bin() {
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${INIT_UBUNTU_TEST_SCRATCH}/bin/${1}"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/${1}"
    export PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}"
}

# A fully installed rootless host.
_mark_installed_all() {
    _mark_user; _mark_unit; _mark_pkg uidmap; _mark_pkg docker-ce-rootless-extras
    printf 'rtuser:100000:65536\n' > "${DOCKER_ROOTLESS_ROOT}/etc/subuid"
    printf 'rtuser:100000:65536\n' > "${DOCKER_ROOTLESS_ROOT}/etc/subgid"
    : > "${DOCKER_ROOTLESS_ROOT}/var/lib/systemd/linger/rtuser"
}

_sudo_count() { grep -c -- "$1" "${SUDO_LOG}" || true; }

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "docker-rootless module file parses (bash -n)" {
    run bash -n "${MODULE_DIR}/docker-rootless.module.sh"
    assert_success
}

@test "docker-rootless module sources cleanly in engine mode (MODULE_STANDALONE=false)" {
    _load_module
    [[ "${MODULE_STANDALONE}" == "false" ]]
}

@test "docker-rootless defines all 10 lifecycle functions (ADR-0002)" {
    _load_module
    local _fn
    for _fn in detect is_recommended is_installed install upgrade \
               remove purge verify is_outdated doctor; do
        declare -F "${_fn}" >/dev/null || {
            printf 'missing lifecycle function: %s\n' "${_fn}" >&2
            return 1
        }
    done
}

# ── Metadata ─────────────────────────────────────────────────────────────────

@test "NAME equals the file name minus .module.sh" {
    _load_module
    [[ "${NAME}" == "docker-rootless" ]]
}

@test "metadata: CATEGORY, TAGS, RISK_LEVEL, platforms, DEPENDS_ON" {
    _load_module
    [[ "${CATEGORY}" == "optional" ]]
    [[ "${TAGS[0]}" == "container" ]]
    [[ "${RISK_LEVEL}" == "medium" ]]
    [[ " ${SUPPORTED_PLATFORMS[*]} " != *" wsl "* ]]
    [[ " ${DEPENDS_ON[*]} " == *" docker "* ]]
}

@test "DESCRIPTION is associative with en + zh-TW and en fallback works" {
    _load_module
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ -n "${DESCRIPTION[en]}" && -n "${DESCRIPTION[zh-TW]}" ]]
    [[ "$(module_get_description xx)" == "$(module_get_description en)" ]]
}

@test "SUPPORTED_UBUNTU includes 22.04 24.04 26.04" {
    _load_module
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 22.04 "* && " ${SUPPORTED_UBUNTU[*]} " == *" 24.04 "* \
        && " ${SUPPORTED_UBUNTU[*]} " == *" 26.04 "* ]]
}

@test "WARN_MESSAGE discloses that remove deletes the account" {
    _load_module
    [[ "${WARN_MESSAGE[en]}" == *"userdel -r"* ]]
}

@test "default account is 'rootless' and Delegate defaults to true" {
    unset DOCKER_ROOTLESS_USER
    _load_module
    [[ "${DOCKER_ROOTLESS_USER}" == "rootless" ]]
    [[ "${DOCKER_ROOTLESS_DELEGATE}" == "true" ]]
}

@test "is_recommended is never true (opt-in module)" {
    _load_module
    run is_recommended
    assert_failure
}

# ── detect ───────────────────────────────────────────────────────────────────

@test "detect succeeds on Ubuntu with systemd" {
    _load_module
    lsb_release() { printf 'Ubuntu\n'; }
    mkdir -p "${DOCKER_ROOTLESS_ROOT}/run/systemd/system"
    run detect
    assert_success
}

@test "detect fails on Ubuntu without systemd" {
    _load_module
    lsb_release() { printf 'Ubuntu\n'; }
    run detect
    assert_failure
}

@test "detect fails on a non-Ubuntu distro" {
    _load_module
    lsb_release() { printf 'Debian\n'; }
    mkdir -p "${DOCKER_ROOTLESS_ROOT}/run/systemd/system"
    run detect
    assert_failure
}

@test "detect fails without lsb_release" {
    _load_module
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/empty" run detect
    assert_failure
}

# ── is_installed ─────────────────────────────────────────────────────────────

@test "is_installed fails when the account does not exist" {
    _load_module; _mock_system
    run is_installed
    assert_failure
}

@test "is_installed fails when the account exists but the user unit was not generated" {
    _load_module; _mock_system
    _mark_user
    run is_installed
    assert_failure
}

@test "is_installed succeeds when the account and docker.service user unit exist" {
    _load_module; _mock_system
    _mark_user; _mark_unit
    run is_installed
    assert_success
}

@test "is_installed fails for an invalid DOCKER_ROOTLESS_USER" {
    _load_module; _mock_system
    _mark_user; _mark_unit
    DOCKER_ROOTLESS_USER="Bad User" run is_installed
    assert_failure
}

@test "is_installed fails for root" {
    _load_module; _mock_system
    DOCKER_ROOTLESS_USER="root" run is_installed
    assert_failure
}

# ── Dry-run ──────────────────────────────────────────────────────────────────

@test "install --dry-run runs nothing and writes nothing" {
    _load_module; _mock_system
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    assert_output --partial "DRY-RUN"
    [[ ! -s "${SUDO_LOG}" ]]
    [[ ! -e "${USER_FLAG}" ]]
}

@test "upgrade / remove / purge / verify / doctor dry-run are no-ops" {
    _load_module; _mock_system
    local _p
    for _p in upgrade remove purge verify doctor; do
        INIT_UBUNTU_DRY_RUN=true run "${_p}"
        assert_success
        assert_output --partial "DRY-RUN"
    done
    [[ ! -s "${SUDO_LOG}" ]]
}

@test "standalone dry-run install exits 0 and touches nothing" {
    run _standalone_module install --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
}

# ── install: fresh host ──────────────────────────────────────────────────────

@test "install requires sudo" {
    _load_module; _mock_system
    MOCK_SUDO_ACCESS_RC=1; _mock_have_sudo
    run install
    assert_failure
    assert_output --partial "sudo required"
    [[ ! -e "${USER_FLAG}" ]]
}

@test "install rejects an invalid account name before changing anything" {
    _load_module; _mock_system; _mock_have_sudo
    DOCKER_ROOTLESS_USER="Bad;User" run install
    assert_failure
    assert_output --partial "invalid DOCKER_ROOTLESS_USER"
    [[ ! -s "${SUDO_LOG}" ]]
}

@test "install on a fresh host installs both packages, creates the account, enables linger" {
    _load_module; _mock_system; _mock_have_sudo
    run install
    assert_success
    [[ -f "${PKG_DB}/uidmap" && -f "${PKG_DB}/docker-ce-rootless-extras" ]]
    [[ -e "${USER_FLAG}" ]]
    grep -q 'useradd --create-home --shell /bin/bash rtuser' "${SUDO_LOG}"
    grep -q 'loginctl enable-linger rtuser' "${SUDO_LOG}"
    [[ -e "${DOCKER_ROOTLESS_ROOT}/var/lib/systemd/linger/rtuser" ]]
}

@test "install never adds the account to the docker group or grants sudo" {
    _load_module; _mock_system; _mock_have_sudo
    run install
    assert_success
    run grep -Eq 'usermod .*-aG|usermod .*--append|gpasswd|visudo|sudoers|-G docker' "${SUDO_LOG}"
    assert_failure
}

@test "install records exactly the packages it installed in the marker" {
    _load_module; _mock_system; _mock_have_sudo
    run install
    assert_success
    local _m="${DOCKER_ROOTLESS_ROOT}/var/lib/init_ubuntu/docker-rootless/rtuser.pkgs"
    [[ -f "${_m}" ]]
    grep -qx uidmap "${_m}"
    grep -qx docker-ce-rootless-extras "${_m}"
}

@test "install records only the missing package when uidmap is already present" {
    _load_module; _mock_system; _mock_have_sudo
    _mark_pkg uidmap
    run install
    assert_success
    local _m="${DOCKER_ROOTLESS_ROOT}/var/lib/init_ubuntu/docker-rootless/rtuser.pkgs"
    run grep -qx uidmap "${_m}"
    assert_failure
    grep -qx docker-ce-rootless-extras "${_m}"
}

@test "install writes no marker when both packages were already installed" {
    _load_module; _mock_system; _mock_have_sudo
    _mark_pkg uidmap; _mark_pkg docker-ce-rootless-extras
    run install
    assert_success
    [[ ! -e "${DOCKER_ROOTLESS_ROOT}/var/lib/init_ubuntu/docker-rootless/rtuser.pkgs" ]]
    run grep -q 'apt-get install' "${SUDO_LOG}"
    assert_failure
}

@test "install fails (and creates no account) when apt-get install fails" {
    _load_module; _mock_system; _mock_have_sudo
    MOCK_APT_RC=100
    run install
    assert_failure
    [[ ! -e "${USER_FLAG}" ]]
}

@test "install adds a subuid/subgid range when the account has none" {
    _load_module; _mock_system; _mock_have_sudo
    _mark_user
    run install
    assert_success
    grep -q 'usermod --add-subuids 100000-165535 --add-subgids 100000-165535 rtuser' "${SUDO_LOG}"
}

@test "install does not touch subuid/subgid when entries exist" {
    _load_module; _mock_system; _mock_have_sudo
    _mark_user
    printf 'rtuser:200000:65536\n' > "${DOCKER_ROOTLESS_ROOT}/etc/subuid"
    printf 'rtuser:200000:65536\n' > "${DOCKER_ROOTLESS_ROOT}/etc/subgid"
    run install
    assert_success
    run grep -q 'usermod' "${SUDO_LOG}"
    assert_failure
}

@test "install writes the Delegate drop-in for user@<uid>.service and daemon-reloads" {
    _load_module; _mock_system; _mock_have_sudo
    run install
    assert_success
    local _d="${DOCKER_ROOTLESS_ROOT}/etc/systemd/system/user@1500.service.d/delegate.conf"
    [[ -f "${_d}" ]]
    grep -qx '\[Service\]' "${_d}"
    grep -qx 'Delegate=cpu cpuset io memory pids' "${_d}"
    grep -q 'systemctl daemon-reload' "${SUDO_LOG}"
}

@test "install skips the Delegate drop-in when DOCKER_ROOTLESS_DELEGATE=false" {
    _load_module; _mock_system; _mock_have_sudo
    DOCKER_ROOTLESS_DELEGATE=false run install
    assert_success
    [[ ! -e "${DOCKER_ROOTLESS_ROOT}/etc/systemd/system/user@1500.service.d/delegate.conf" ]]
}

@test "install starts user@<uid>.service before any user-level systemctl" {
    _load_module; _mock_system; _mock_have_sudo
    run install
    assert_success
    local _start _setup
    _start="$(grep -n 'systemctl start user@1500.service' "${SUDO_LOG}" | head -1 | cut -d: -f1)"
    _setup="$(grep -n 'dockerd-rootless-setuptool.sh install' "${SUDO_LOG}" | head -1 | cut -d: -f1)"
    [[ -n "${_start}" && -n "${_setup}" && "${_start}" -lt "${_setup}" ]]
}

@test "install runs dockerd-rootless-setuptool as the target account with XDG_RUNTIME_DIR" {
    _load_module; _mock_system; _mock_have_sudo
    run install
    assert_success
    grep -q -- '-H -u rtuser env XDG_RUNTIME_DIR=/run/user/1500 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1500/bus dockerd-rootless-setuptool.sh install' "${SUDO_LOG}"
}

@test "install writes the socket-wait + Restart drop-in for the user docker.service" {
    _load_module; _mock_system; _mock_have_sudo
    run install
    assert_success
    local _d="${FAKE_HOME}/.config/systemd/user/docker.service.d/10-wait-socket.conf"
    [[ -f "${_d}" ]]
    grep -qx 'Restart=on-failure' "${_d}"
    grep -qx 'RestartSec=3' "${_d}"
    grep -q 'ExecStartPost=.*timeout 60.*until \[ -S "%t/docker.sock" \]' "${_d}"
}

@test "install enables and starts docker.service as a user service" {
    _load_module; _mock_system; _mock_have_sudo
    run install
    assert_success
    grep -q 'systemctl --user enable --now docker.service' "${SUDO_LOG}"
}

# ── install: preflight refusals ──────────────────────────────────────────────

@test "install refuses an existing account that is in the docker group" {
    _load_module; _mock_system; _mock_have_sudo
    _mark_user
    MOCK_GROUPS="rtuser docker"
    run install
    assert_failure
    assert_output --partial "dedicated unprivileged account"
    run grep -q 'apt-get' "${SUDO_LOG}"
    assert_failure
}

@test "install refuses an existing account with sudo" {
    _load_module; _mock_system; _mock_have_sudo
    _mark_user
    MOCK_GROUPS="rtuser sudo"
    run install
    assert_failure
}

@test "install refuses the invoking account" {
    _load_module; _mock_system; _mock_have_sudo
    _mark_user
    SUDO_USER="rtuser" run install
    assert_failure
    assert_output --partial "invoking account"
}

@test "install warns (does not fail) when AppArmor restricts userns and no rootlesskit profile exists" {
    _load_module; _mock_system; _mock_have_sudo
    MOCK_USERNS_RESTRICT=1
    run install
    assert_success
    assert_output --partial "AppArmor restricts unprivileged user namespaces"
}

@test "install does not warn about AppArmor when a rootlesskit profile exists" {
    _load_module; _mock_system; _mock_have_sudo
    MOCK_USERNS_RESTRICT=1
    mkdir -p "${DOCKER_ROOTLESS_ROOT}/etc/apparmor.d"
    printf '/usr/bin/rootlesskit flags=(unconfined) {}\n' > "${DOCKER_ROOTLESS_ROOT}/etc/apparmor.d/usr.bin.rootlesskit"
    run install
    assert_success
    refute_output --partial "AppArmor restricts"
}

# ── GPU ──────────────────────────────────────────────────────────────────────

@test "no GPU advice on a host without NVIDIA tooling" {
    _load_module; _mock_system; _mock_have_sudo
    _set_cdi_refresh 0
    run install
    assert_success
    refute_output --partial "nvidia-cdi-refresh"
}

@test "NVIDIA host without nvidia-cdi-refresh gets a warning" {
    _load_module; _mock_system; _mock_have_sudo
    _stub_bin nvidia-smi
    _set_cdi_refresh 0
    run install
    assert_success
    assert_output --partial "nvidia-cdi-refresh unit not found"
}

@test "NVIDIA host with nvidia-cdi-refresh and default no-cgroups is silent" {
    _load_module; _mock_system; _mock_have_sudo
    _stub_bin nvidia-smi
    run install
    assert_success
    refute_output --partial "nvidia-cdi-refresh"
    refute_output --partial "no-cgroups"
}

@test "NVIDIA host with no-cgroups = true gets a warning (module never edits it)" {
    _load_module; _mock_system; _mock_have_sudo
    _stub_bin nvidia-smi
    mkdir -p "${DOCKER_ROOTLESS_ROOT}/etc/nvidia-container-runtime"
    printf '[nvidia-container-cli]\nno-cgroups = true\n' \
        > "${DOCKER_ROOTLESS_ROOT}/etc/nvidia-container-runtime/config.toml"
    run install
    assert_success
    assert_output --partial "no-cgroups = true"
    grep -q 'no-cgroups = true' "${DOCKER_ROOTLESS_ROOT}/etc/nvidia-container-runtime/config.toml"
}

# ── Idempotency ──────────────────────────────────────────────────────────────

@test "second install is a no-op (already installed) and runs no sudo command" {
    _load_module; _mock_system; _mock_have_sudo
    run install
    assert_success
    : > "${SUDO_LOG}"
    run install
    assert_success
    assert_output --partial "already installed"
    run grep -Eq 'useradd|apt-get|usermod|enable-linger|tee' "${SUDO_LOG}"
    assert_failure
}

@test "converge re-run changes no file and creates nothing new (drop-ins stable)" {
    _load_module; _mock_system; _mock_have_sudo
    run install
    assert_success
    local _d="${DOCKER_ROOTLESS_ROOT}/etc/systemd/system/user@1500.service.d/delegate.conf"
    local _before; _before="$(cksum < "${_d}")"
    : > "${SUDO_LOG}"
    run _dr_converge
    assert_success
    [[ "$(cksum < "${_d}")" == "${_before}" ]]
    run grep -Eq 'tee|useradd|enable-linger|usermod|daemon-reload|setuptool' "${SUDO_LOG}"
    assert_failure
}

# ── upgrade ──────────────────────────────────────────────────────────────────

@test "upgrade on a not-installed module runs install" {
    _load_module; _mock_system; _mock_have_sudo
    run upgrade
    assert_success
    [[ -e "${USER_FLAG}" ]]
}

@test "upgrade runs apt-get --only-upgrade for both packages and restarts docker" {
    _load_module; _mock_system; _mock_have_sudo
    _mark_installed_all
    run upgrade
    assert_success
    grep -q 'apt-get install --only-upgrade -y uidmap docker-ce-rootless-extras' "${SUDO_LOG}"
    grep -q 'systemctl --user try-restart docker.service' "${SUDO_LOG}"
}

@test "upgrade requires sudo" {
    _load_module; _mock_system
    _mark_installed_all
    MOCK_SUDO_ACCESS_RC=1; _mock_have_sudo
    run upgrade
    assert_failure
}

# ── remove ───────────────────────────────────────────────────────────────────

@test "remove on a clean host is a no-op (idempotent)" {
    _load_module; _mock_system; _mock_have_sudo
    run remove
    assert_success
    assert_output --partial "nothing to do"
    [[ ! -s "${SUDO_LOG}" ]]
}

@test "remove runs the reverse sequence in order" {
    _load_module; _mock_system; _mock_have_sudo
    run install
    assert_success
    : > "${SUDO_LOG}"
    run remove
    assert_success
    local _o
    _o="$(grep -nE 'systemctl stop user@1500.service user-runtime-dir@1500.service|loginctl disable-linger rtuser|userdel -r rtuser|systemctl daemon-reload|apt-get remove' "${SUDO_LOG}" | sed 's/^[0-9]*://')"
    [[ "${_o}" == "systemctl stop user@1500.service user-runtime-dir@1500.service
loginctl disable-linger rtuser
userdel -r rtuser
systemctl daemon-reload
apt-get remove -y docker-ce-rootless-extras uidmap" ]]
}

@test "remove deletes the account, linger, subuid/subgid entries and the Delegate drop-in" {
    _load_module; _mock_system; _mock_have_sudo
    run install
    assert_success
    run remove
    assert_success
    [[ ! -e "${USER_FLAG}" ]]
    [[ ! -e "${DOCKER_ROOTLESS_ROOT}/var/lib/systemd/linger/rtuser" ]]
    run grep -q '^rtuser:' "${DOCKER_ROOTLESS_ROOT}/etc/subuid"
    assert_failure
    run grep -q '^rtuser:' "${DOCKER_ROOTLESS_ROOT}/etc/subgid"
    assert_failure
    [[ ! -e "${DOCKER_ROOTLESS_ROOT}/etc/systemd/system/user@1500.service.d/delegate.conf" ]]
}

@test "remove cleans stale subuid/subgid lines even when userdel left them" {
    _load_module; _mock_system; _mock_have_sudo
    _mark_installed_all
    printf 'other:300000:65536\nrtuser:100000:65536\n' > "${DOCKER_ROOTLESS_ROOT}/etc/subuid"
    run remove
    assert_success
    run grep -q '^rtuser:' "${DOCKER_ROOTLESS_ROOT}/etc/subuid"
    assert_failure
    grep -q '^other:' "${DOCKER_ROOTLESS_ROOT}/etc/subuid"
}

@test "remove removes only packages this module installed" {
    _load_module; _mock_system; _mock_have_sudo
    _mark_pkg uidmap
    run install
    assert_success
    : > "${SUDO_LOG}"
    run remove
    assert_success
    grep -q 'apt-get remove -y docker-ce-rootless-extras$' "${SUDO_LOG}"
    run grep -q 'apt-get remove.*uidmap' "${SUDO_LOG}"
    assert_failure
}

@test "remove removes no packages when the module installed none (no marker)" {
    _load_module; _mock_system; _mock_have_sudo
    _mark_installed_all
    run remove
    assert_success
    run grep -q 'apt-get remove' "${SUDO_LOG}"
    assert_failure
    grep -q 'userdel -r rtuser' "${SUDO_LOG}"
}

@test "remove drops the package marker" {
    _load_module; _mock_system; _mock_have_sudo
    run install
    assert_success
    run remove
    assert_success
    [[ ! -e "${DOCKER_ROOTLESS_ROOT}/var/lib/init_ubuntu/docker-rootless/rtuser.pkgs" ]]
}

@test "remove twice succeeds (idempotent)" {
    _load_module; _mock_system; _mock_have_sudo
    run install
    assert_success
    run remove
    assert_success
    run remove
    assert_success
    assert_output --partial "nothing to do"
}

@test "remove refuses to delete an account in the docker group" {
    _load_module; _mock_system; _mock_have_sudo
    _mark_installed_all
    MOCK_GROUPS="rtuser docker"
    run remove
    assert_failure
    assert_output --partial "refusing to delete"
    run grep -q 'userdel' "${SUDO_LOG}"
    assert_failure
}

@test "remove refuses to delete the invoking account" {
    _load_module; _mock_system; _mock_have_sudo
    _mark_installed_all
    USER="rtuser" SUDO_USER="" run remove
    assert_failure
    run grep -q 'userdel' "${SUDO_LOG}"
    assert_failure
}

@test "remove still cleans subuid and marker when the account is already gone" {
    _load_module; _mock_system; _mock_have_sudo
    mkdir -p "${DOCKER_ROOTLESS_ROOT}/var/lib/init_ubuntu/docker-rootless"
    printf 'uidmap\n' > "${DOCKER_ROOTLESS_ROOT}/var/lib/init_ubuntu/docker-rootless/rtuser.pkgs"
    printf 'rtuser:100000:65536\n' > "${DOCKER_ROOTLESS_ROOT}/etc/subuid"
    run remove
    assert_success
    run grep -q '^rtuser:' "${DOCKER_ROOTLESS_ROOT}/etc/subuid"
    assert_failure
    grep -q 'apt-get remove -y uidmap' "${SUDO_LOG}"
    run grep -q 'userdel' "${SUDO_LOG}"
    assert_failure
}

@test "purge also removes the module state dir" {
    _load_module; _mock_system; _mock_have_sudo
    run install
    assert_success
    run purge
    assert_success
    [[ ! -e "${DOCKER_ROOTLESS_ROOT}/var/lib/init_ubuntu/docker-rootless" ]]
    [[ ! -e "${USER_FLAG}" ]]
}

@test "purge on a clean host succeeds" {
    _load_module; _mock_system; _mock_have_sudo
    run purge
    assert_success
}

# ── verify / is_outdated / doctor ────────────────────────────────────────────

@test "verify fails when not installed and passes (dry TEST_VERIFY_CMD) when installed" {
    _load_module; _mock_system
    run verify
    assert_failure
    _mark_user; _mark_unit
    TEST_VERIFY_CMD="true" run verify
    assert_success
}

@test "is_outdated is false when the package is not installed" {
    _load_module; _mock_system
    run is_outdated
    assert_failure
}

@test "is_outdated reflects apt list --upgradable" {
    _load_module; _mock_system
    _mark_pkg docker-ce-rootless-extras
    apt() { printf '%s' "${MOCK_UPGRADABLE:-}"; }
    MOCK_UPGRADABLE="docker-ce-rootless-extras/jammy 5:99 amd64 [upgradable from: 5:1]" run is_outdated
    assert_success
    MOCK_UPGRADABLE="" run is_outdated
    assert_failure
}

@test "doctor fails when not installed" {
    _load_module; _mock_system
    run doctor
    assert_failure
    assert_output --partial "not installed"
}

@test "doctor passes on a healthy install" {
    _load_module; _mock_system
    _mark_installed_all
    mkdir -p "${FAKE_HOME}"
    # Wrap the recording sudo: a real socket cannot exist in the scratch dir.
    eval "_sudo_base() $(declare -f sudo | tail -n +2)"
    sudo() { [[ "$1" == "test" && "$2" == "-S" ]] && return 0; _sudo_base "$@"; }
    run doctor
    assert_success
}

@test "doctor flags a missing docker.sock" {
    _load_module; _mock_system
    _mark_installed_all
    run doctor
    assert_failure
    assert_output --partial "docker.sock"
}

@test "doctor flags a missing linger and an inactive user@ service" {
    _load_module; _mock_system
    _mark_installed_all
    rm -f "${DOCKER_ROOTLESS_ROOT}/var/lib/systemd/linger/rtuser"
    _set_user_active_rc 3
    run doctor
    assert_failure
    assert_output --partial "linger is not enabled"
    assert_output --partial "is not active"
}

@test "doctor flags a privileged account" {
    _load_module; _mock_system
    _mark_installed_all
    MOCK_GROUPS="rtuser docker"
    run doctor
    assert_failure
    assert_output --partial "not a dedicated account"
}

# ── Standalone CLI ───────────────────────────────────────────────────────────

@test "standalone --help exits 0" {
    run _standalone_module --help
    assert_success
}

@test "standalone --version exits 0" {
    run _standalone_module --version
    assert_success
    assert_output --partial "docker-rootless"
}

@test "standalone unknown phase exits 2" {
    run _standalone_module bogus
    [[ "${status}" -eq 2 ]]
}

@test "standalone info prints metadata and --lang=zh-TW the translation" {
    run _standalone_module info
    assert_success
    assert_output --partial "docker-rootless"
    run _standalone_module info --lang=zh-TW
    assert_success
    assert_output --partial "Rootless Docker"
    assert_output --partial "專用"
}

@test "sourcing the module does not trigger the standalone footer" {
    run bash -c "source '${LIB_DIR}/logger.sh'; source '${LIB_DIR}/general.sh'; source '${LIB_DIR}/module_helper.sh'; source '${MODULE_DIR}/docker-rootless.module.sh'; echo sourced"
    assert_success
    assert_output --partial "sourced"
}
