#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2317  # SC2034: test setups stage module metadata vars (NAME / APT_PKGS / APT_PPA / CONFIG_PATHS / INSTALL_DIR / BIN_NAME / ...) that the function-under-test reads only after `source module_helper.sh`, so ShellCheck cannot see the cross-source use (wiki: "or export if used externally" -- arrays can't be exported). SC2317: the `sudo` / `have_sudo_access` / `is_installed` mocks are dispatched indirectly by the archetype default bodies, so ShellCheck flags their bodies as unreachable (wiki: "ignore if invoked indirectly"). Same disable set + rationale as the sibling test/unit/module_helper_spec.bats -- https://www.shellcheck.net/wiki/SC2034 + https://www.shellcheck.net/wiki/SC2317
# test/unit/module_helper_real_bodies_spec.bats -- characterization/coverage
# tests that EXECUTE the REAL (non-dry-run) mutation bodies of the archetype
# default lifecycle functions in lib/module_helper.sh.
#
# Gap closed (module-template-audit #1 + #2): the apt archetype's real-mutation
# bodies were never run by any test -- per-module specs stub install()/remove()/
# purge() wholesale, and the one reduced integration apt test is not in the kcov
# shards. Every archetype's `purge` default (the ADR-0015 rollback verb) was
# likewise only exercised in dry-run.
#
# Strategy: stub the external side-effecting commands so the real bodies run
# deterministically and offline --
#   - `sudo`             -> a function that appends its argv to a command-log and
#                           returns 0 (so `sudo apt-get ...` / `sudo apt-add-repository
#                           ...` are recorded, not executed). We assert the RIGHT
#                           apt/PPA verbs ran against the RIGHT packages.
#   - `have_sudo_access` -> overridden per-test to drive both the sudo-present and
#                           the no-sudo guard branches.
#   - `is_installed`     -> overridden to steer the skip-if-(not-)installed guards.
#   - `rm`               -> NOT stubbed; the CONFIG_PATHS / INSTALL_DIR removals run
#                           real `rm` against real scratch paths, and we assert the
#                           paths are actually gone (more faithful than a mock and
#                           it keeps bats' own rm intact).
#
# These run the real branches (NOT dry-run) so kcov counts them and the AC-17
# headroom improves. No production code is changed -- pure stubbing.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
    # shellcheck source=../../lib/logger.sh
    source "${LIB_DIR}/logger.sh"
    # shellcheck source=../../lib/general.sh
    source "${LIB_DIR}/general.sh"
    # shellcheck source=../../lib/module_helper.sh
    source "${LIB_DIR}/module_helper.sh"

    NAME="testmod"
    CMDLOG="${INIT_UBUNTU_TEST_SCRATCH}/cmdlog"
    : > "${CMDLOG}"
}

teardown() { teardown_test_env; }

# Record every `sudo ...` invocation instead of running it. Returns 0 so the
# body's `sudo apt-get install ...` (the phase's final statement) yields success.
_stub_sudo() {
    sudo() { printf 'sudo %s\n' "$*" >> "${CMDLOG}"; return 0; }
}

# -- APT install: real body (PPA add + apt-get update + install) --------------

@test "module_default_apt_install real body adds PPA then installs the packages" {
    _stub_sudo
    have_sudo_access() { return 0; }
    is_installed() { return 1; }
    APT_PKGS=(curl wget)
    APT_PPA="ppa:example/release"

    run module_default_apt_install
    assert_success

    run cat "${CMDLOG}"
    assert_line --partial "sudo apt-add-repository -y ppa:example/release"
    assert_line --partial "sudo apt-get update -qq"
    assert_line --partial "sudo apt-get install -y --no-install-recommends curl wget"
}

@test "module_default_apt_install real body without a PPA skips apt-add-repository" {
    _stub_sudo
    have_sudo_access() { return 0; }
    is_installed() { return 1; }
    APT_PKGS=(ripgrep)

    run module_default_apt_install
    assert_success

    run cat "${CMDLOG}"
    refute_line --partial "apt-add-repository"
    assert_line --partial "sudo apt-get install -y --no-install-recommends ripgrep"
}

@test "module_default_apt_install no-sudo guard aborts before any PPA when sudo is unavailable" {
    _stub_sudo
    have_sudo_access() { return 1; }
    is_installed() { return 1; }
    APT_PKGS=(curl)
    APT_PPA="ppa:example/release"

    run module_default_apt_install
    assert_failure
    assert_output --partial "no sudo"
    assert_output --partial "cannot add PPA"

    run cat "${CMDLOG}"
    refute_output --partial "apt-get"
    refute_output --partial "apt-add-repository"
}

@test "module_default_apt_install no-sudo guard (no PPA) warns manual-install and returns 1" {
    _stub_sudo
    have_sudo_access() { return 1; }
    is_installed() { return 1; }
    APT_PKGS=(curl wget)

    run module_default_apt_install
    assert_failure
    assert_output --partial "no sudo"
    assert_output --partial "install manually"
    assert_output --partial "curl wget"

    run cat "${CMDLOG}"
    refute_output --partial "apt-get"
}

@test "module_default_apt_install real body skips when already installed" {
    _stub_sudo
    have_sudo_access() { return 0; }
    is_installed() { return 0; }
    APT_PKGS=(curl)

    run module_default_apt_install
    assert_success
    assert_output --partial "already installed"

    run cat "${CMDLOG}"
    refute_output --partial "apt-get"
}

# -- APT upgrade: real body (--only-upgrade) ---------------------------------

@test "module_default_apt_upgrade real body runs apt-get install --only-upgrade" {
    _stub_sudo
    have_sudo_access() { return 0; }
    is_installed() { return 0; }
    APT_PKGS=(curl wget)

    run module_default_apt_upgrade
    assert_success

    run cat "${CMDLOG}"
    assert_line --partial "sudo apt-get update -qq"
    assert_line --partial "sudo apt-get install --only-upgrade -y curl wget"
}

@test "module_default_apt_upgrade no-sudo guard returns 1 without touching apt" {
    _stub_sudo
    have_sudo_access() { return 1; }
    is_installed() { return 0; }
    APT_PKGS=(curl)

    run module_default_apt_upgrade
    assert_failure
    assert_output --partial "no sudo"
    assert_output --partial "cannot update"

    run cat "${CMDLOG}"
    refute_output --partial "apt-get"
}

# -- APT remove: real body ---------------------------------------------------

@test "module_default_apt_remove real body runs apt-get remove on the packages" {
    _stub_sudo
    is_installed() { return 0; }
    APT_PKGS=(curl wget)

    run module_default_apt_remove
    assert_success

    run cat "${CMDLOG}"
    assert_line --partial "sudo apt-get remove -y curl wget"
}

@test "module_default_apt_remove skips when the package is not installed" {
    _stub_sudo
    is_installed() { return 1; }
    APT_PKGS=(curl)

    run module_default_apt_remove
    assert_success
    assert_output --partial "nothing to do"

    run cat "${CMDLOG}"
    refute_output --partial "apt-get"
}

# -- APT purge: real body (apt-get purge + PPA remove + CONFIG_PATHS rm) ------

@test "module_default_apt_purge real body purges packages, removes PPA, and rm's CONFIG_PATHS" {
    _stub_sudo
    have_sudo_access() { return 0; }
    APT_PKGS=(curl wget)
    APT_PPA="ppa:example/release"

    local _cfg1="${INIT_UBUNTU_TEST_SCRATCH}/cfg-a"
    local _cfg2="${INIT_UBUNTU_TEST_SCRATCH}/cfg-b"
    mkdir -p "${_cfg1}" "${_cfg2}"
    printf 'x\n' > "${_cfg1}/file"
    CONFIG_PATHS=("${_cfg1}" "${_cfg2}")

    run module_default_apt_purge
    assert_success

    run cat "${CMDLOG}"
    assert_line --partial "sudo apt-get purge -y curl wget"
    assert_line --partial "sudo apt-add-repository -y --remove ppa:example/release"

    [[ ! -e "${_cfg1}" ]]
    [[ ! -e "${_cfg2}" ]]
}

@test "module_default_apt_purge without a PPA does not call apt-add-repository --remove" {
    _stub_sudo
    have_sudo_access() { return 0; }
    APT_PKGS=(ripgrep)
    CONFIG_PATHS=()

    run module_default_apt_purge
    assert_success

    run cat "${CMDLOG}"
    assert_line --partial "sudo apt-get purge -y ripgrep"
    refute_line --partial "apt-add-repository"
}

@test "module_default_apt_purge skips PPA removal when sudo is unavailable" {
    _stub_sudo
    have_sudo_access() { return 1; }
    APT_PKGS=(curl)
    APT_PPA="ppa:example/release"
    local _cfg="${INIT_UBUNTU_TEST_SCRATCH}/cfg-c"
    mkdir -p "${_cfg}"
    CONFIG_PATHS=("${_cfg}")

    run module_default_apt_purge
    assert_success

    run cat "${CMDLOG}"
    refute_line --partial "apt-add-repository"
    [[ ! -e "${_cfg}" ]]
}

# -- github-release purge: real body (remove + CONFIG_PATHS rm loop) ----------

@test "module_default_github_release_purge real body removes install dir, link, and CONFIG_PATHS" {
    USE_SUDO=false
    BIN_NAME="faketool"

    INSTALL_DIR="${INIT_UBUNTU_TEST_SCRATCH}/opt/faketool"
    mkdir -p "${INSTALL_DIR}"
    printf 'bin\n' > "${INSTALL_DIR}/payload"

    BIN_LINK="${INIT_UBUNTU_TEST_SCRATCH}/bin/faketool"
    mkdir -p "${BIN_LINK%/*}"
    printf '#!/usr/bin/env bash\n' > "${BIN_LINK}"
    chmod +x "${BIN_LINK}"

    local _cfg1="${INIT_UBUNTU_TEST_SCRATCH}/ghcfg-a"
    local _cfg2="${INIT_UBUNTU_TEST_SCRATCH}/ghcfg-b"
    mkdir -p "${_cfg1}" "${_cfg2}"
    CONFIG_PATHS=("${_cfg1}" "${_cfg2}")

    run module_default_github_release_purge
    assert_success

    [[ ! -e "${INSTALL_DIR}" ]]
    [[ ! -e "${BIN_LINK}" ]]
    [[ ! -e "${_cfg1}" ]]
    [[ ! -e "${_cfg2}" ]]
}

@test "module_default_github_release_purge tolerates empty CONFIG_PATHS" {
    USE_SUDO=false
    BIN_NAME="faketool2"
    INSTALL_DIR="${INIT_UBUNTU_TEST_SCRATCH}/opt/faketool2"
    mkdir -p "${INSTALL_DIR}"
    BIN_LINK="${INIT_UBUNTU_TEST_SCRATCH}/bin/faketool2"
    mkdir -p "${BIN_LINK%/*}"
    : > "${BIN_LINK}"
    CONFIG_PATHS=()

    run module_default_github_release_purge
    assert_success
    [[ ! -e "${INSTALL_DIR}" ]]
    [[ ! -e "${BIN_LINK}" ]]
}

# -- config purge: real body (delegates to remove -> rm CONFIG_DEST) ----------

@test "module_default_config_purge real body deletes CONFIG_DEST" {
    CONFIG_DEST="${INIT_UBUNTU_TEST_SCRATCH}/myrc"
    printf '# init_ubuntu managed\nset background=dark\n' > "${CONFIG_DEST}"

    run module_default_config_purge
    assert_success
    [[ ! -e "${CONFIG_DEST}" ]]
}

@test "module_default_config_purge dry-run leaves CONFIG_DEST in place" {
    CONFIG_DEST="${INIT_UBUNTU_TEST_SCRATCH}/myrc"
    printf '# init_ubuntu managed\n' > "${CONFIG_DEST}"

    INIT_UBUNTU_DRY_RUN=true run module_default_config_purge
    assert_success
    [[ -f "${CONFIG_DEST}" ]]
}
