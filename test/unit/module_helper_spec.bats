#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2317,SC2030,SC2031  # SC2034: test setups stage module metadata vars (NAME / APT_PKGS / ...) that the function-under-test reads after sourcing module_helper. SC2317: test mocks (is_installed/install) dispatched indirectly via the module's macro wrappers. SC2030/SC2031: bats `@test`/`run` run in a subshell; test setups `export INIT_UBUNTU_DRY_RUN/INIT_UBUNTU_LOG_FILE=...` inside that subshell to stage env for the function-under-test (same rationale as i18n_spec.bats) — https://www.shellcheck.net/wiki/SC2034 + https://www.shellcheck.net/wiki/SC2317 + https://www.shellcheck.net/wiki/SC2030
# test/unit/module_helper_spec.bats — direct unit tests on lib/module_helper.sh
#
# Tests the helper functions in isolation (no module file):
#   - module_i18n_get with various languages + fallback to en
#   - module_dryrun_guard / skip_if_installed / skip_if_not_installed
#   - module_use_apt_archetype defines 7 lifecycle functions
#   - module_use_github_release_archetype defines 6 lifecycle functions
#   - module_use_config_archetype defines 6 lifecycle functions
#   - module_default_apt_install in dry-run does not call apt-get
#   - module_default_config_install drops a marker

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
}

teardown() { teardown_test_env; }

# ── i18n ────────────────────────────────────────────────────────────────────

@test "module_i18n_get returns matching lang" {
    declare -A DESCRIPTION=([en]="hello" [zh-TW]="你好" [ja]="こんにちは")
    [[ "$(module_i18n_get DESCRIPTION en)" == "hello" ]]
    [[ "$(module_i18n_get DESCRIPTION zh-TW)" == "你好" ]]
    [[ "$(module_i18n_get DESCRIPTION ja)" == "こんにちは" ]]
}

@test "module_i18n_get falls back to en on unknown lang" {
    declare -A DESCRIPTION=([en]="hello" [zh-TW]="你好")
    [[ "$(module_i18n_get DESCRIPTION fr)" == "hello" ]]
}

@test "module_i18n_get returns empty on missing field" {
    declare -A DESCRIPTION=()
    [[ -z "$(module_i18n_get DESCRIPTION en)" ]]
}

@test "module_i18n_get handles values containing ':'" {
    declare -A DESCRIPTION=([en]="see https://example.com:80 for details")
    [[ "$(module_i18n_get DESCRIPTION en)" == "see https://example.com:80 for details" ]]
}

@test "module_i18n_get honors INIT_UBUNTU_LANG when no arg given" {
    declare -A DESCRIPTION=([en]="hello" [zh-TW]="你好")
    INIT_UBUNTU_LANG=zh-TW
    [[ "$(module_i18n_get DESCRIPTION)" == "你好" ]]
}

@test "module_get_description / _post_install_message wrappers work" {
    declare -A DESCRIPTION=([en]="desc")
    declare -A POST_INSTALL_MESSAGE=([en]="post")
    declare -A WARN_MESSAGE=([en]="warn")
    [[ "$(module_get_description en)"          == "desc" ]]
    [[ "$(module_get_post_install_message en)" == "post" ]]
    [[ "$(module_get_warn_message en)"         == "warn" ]]
}

# ── Generic guards ──────────────────────────────────────────────────────────

@test "module_dryrun_guard returns 0 when INIT_UBUNTU_DRY_RUN=true" {
    INIT_UBUNTU_DRY_RUN=true run module_dryrun_guard install "doing X"
    assert_success
    assert_output --partial "DRY-RUN"
    assert_output --partial "doing X"
}

@test "module_dryrun_guard returns 1 when not dry-run" {
    INIT_UBUNTU_DRY_RUN=false run module_dryrun_guard install "doing X"
    assert_failure
}

@test "module_skip_if_installed returns 0 when is_installed succeeds" {
    is_installed() { return 0; }
    run module_skip_if_installed
    assert_success
    assert_output --partial "already installed"
}

@test "module_skip_if_installed returns 1 when is_installed fails" {
    is_installed() { return 1; }
    run module_skip_if_installed
    assert_failure
}

@test "module_skip_if_not_installed returns 0 when not installed" {
    is_installed() { return 1; }
    run module_skip_if_not_installed
    assert_success
    assert_output --partial "nothing to do"
}

# ── Archetype macros: full lifecycle (ADR-0002 all-10) ──────────────────────
#
# After the deepening refactor the macros emit ALL the archetype-defaultable
# functions — the 6 mutation phases plus is_installed, is_outdated, verify,
# doctor, and the module_provided_version Sidecar hook. Only detect() and
# is_recommended() stay module-defined.

@test "module_use_apt_archetype defines the full archetype-default lifecycle" {
    module_use_apt_archetype
    local _fn
    for _fn in is_installed install upgrade remove purge verify is_outdated \
               doctor module_provided_version; do
        declare -F "${_fn}" >/dev/null || { printf "missing %s\n" "${_fn}" >&2; return 1; }
    done
}

@test "module_use_github_release_archetype defines the full archetype-default lifecycle" {
    module_use_github_release_archetype
    local _fn
    for _fn in is_installed install upgrade remove purge verify is_outdated \
               doctor module_provided_version; do
        declare -F "${_fn}" >/dev/null || { printf "missing %s\n" "${_fn}" >&2; return 1; }
    done
}

@test "module_use_config_archetype defines the full archetype-default lifecycle" {
    module_use_config_archetype
    local _fn
    for _fn in is_installed install upgrade remove purge verify is_outdated \
               doctor module_provided_version; do
        declare -F "${_fn}" >/dev/null || { printf "missing %s\n" "${_fn}" >&2; return 1; }
    done
}

# detect() + is_recommended() stay module-defined (the macros do NOT emit them).
@test "archetype macros do NOT emit detect or is_recommended" {
    module_use_apt_archetype
    run ! declare -F detect
    run ! declare -F is_recommended
}

@test "archetype macros can be overridden after the call" {
    module_use_apt_archetype
    install() { echo "custom-install"; return 7; }
    run install
    assert_failure 7
    assert_output --partial "custom-install"
}

# ── APT archetype dry-run behavior ──────────────────────────────────────────

@test "module_default_apt_install dry-run does not call apt-get" {
    STUB_DIR="${INIT_UBUNTU_TEST_SCRATCH}/stubs"
    mkdir -p "${STUB_DIR}"
    cat > "${STUB_DIR}/apt-get" <<'EOF'
#!/usr/bin/env bash
echo "apt-get called" >&2
exit 1
EOF
    chmod +x "${STUB_DIR}/apt-get"

    APT_PKGS=(curl wget)
    INIT_UBUNTU_DRY_RUN=true
    PATH="${STUB_DIR}:${PATH}" run module_default_apt_install
    assert_success
    assert_output --partial "DRY-RUN"
    refute_output --partial "apt-get called"
}

@test "module_default_apt_is_installed returns 1 on empty APT_PKGS" {
    APT_PKGS=()
    run module_default_apt_is_installed
    assert_failure
}

# ── Config archetype: drops a real file ─────────────────────────────────────

@test "module_default_config_install drops file with marker" {
    CONFIG_DEST="${INIT_UBUNTU_TEST_SCRATCH}/myrc"
    CONFIG_STUB="set background=dark"
    is_installed() { module_default_config_is_installed; }
    run module_default_config_install
    assert_success
    [[ -f "${CONFIG_DEST}" ]]
    grep -q "init_ubuntu managed" "${CONFIG_DEST}"
    grep -q "set background=dark" "${CONFIG_DEST}"
}

@test "module_default_config_is_installed detects marker" {
    CONFIG_DEST="${INIT_UBUNTU_TEST_SCRATCH}/myrc"
    printf '# init_ubuntu managed\nset background=dark\n' > "${CONFIG_DEST}"
    run module_default_config_is_installed
    assert_success
}

@test "module_default_config_is_installed fails when marker missing" {
    CONFIG_DEST="${INIT_UBUNTU_TEST_SCRATCH}/myrc"
    printf 'set background=dark\n' > "${CONFIG_DEST}"
    run module_default_config_is_installed
    assert_failure
}

@test "module_default_config_install dry-run does not touch fs" {
    CONFIG_DEST="${INIT_UBUNTU_TEST_SCRATCH}/myrc"
    CONFIG_STUB="set background=dark"
    INIT_UBUNTU_DRY_RUN=true run module_default_config_install
    assert_success
    [[ ! -e "${CONFIG_DEST}" ]]
}

# ── Standalone info / status (engine-side aggregators) ──────────────────────

@test "module_standalone_info prints metadata fields" {
    NAME="testmod"
    VERSION_PROVIDED="v1.0"
    CATEGORY="optional"
    declare -A DESCRIPTION=([en]="my test module")
    HOMEPAGE="https://example.com"
    run module_standalone_info
    assert_success
    assert_output --partial "name:"
    assert_output --partial "testmod"
    assert_output --partial "version:"
    assert_output --partial "v1.0"
    assert_output --partial "description:"
    assert_output --partial "my test module"
    assert_output --partial "homepage:"
}

@test "module_standalone_status prints installed/outdated" {
    NAME="testmod"
    VERSION_PROVIDED="v1.0"
    is_installed() { return 0; }
    run module_standalone_status
    assert_success
    assert_output --partial "installed:"
    assert_output --partial "yes"
    assert_output --partial "no is_outdated"
}

@test "module_standalone_status reports outdated when is_outdated returns 0" {
    NAME="testmod"
    is_installed() { return 0; }
    is_outdated()  { return 0; }
    run module_standalone_status
    assert_success
    assert_output --partial "outdated:"
    assert_output --partial "yes"
}

@test "module_standalone_status reports not installed" {
    NAME="testmod"
    is_installed() { return 1; }
    run module_standalone_status
    assert_success
    assert_output --partial "installed:   no"
}

# ── Sidecar version file (ADR-0001 / module-spec §4.7.4) ────────────────────

@test "module_sidecar_write + get_version round-trips under INIT_UBUNTU_STATE_DIR" {
    module_sidecar_write testmod v1.2.3
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/testmod" ]]
    run module_sidecar_get_version testmod
    assert_success
    assert_output "v1.2.3"
}

@test "module_sidecar_get_version returns 1 when no record exists" {
    run module_sidecar_get_version never-written
    assert_failure
}

@test "module_sidecar_remove drops the version record" {
    module_sidecar_write testmod v1
    module_sidecar_remove testmod
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/testmod" ]]
    run module_sidecar_get_version testmod
    assert_failure
}

@test "module_sidecar_write is a no-op under dry-run (AC-12)" {
    INIT_UBUNTU_DRY_RUN=true module_sidecar_write testmod v1
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/testmod" ]]
}

@test "module_sidecar_remove is a no-op under dry-run (AC-12)" {
    module_sidecar_write testmod v1
    INIT_UBUNTU_DRY_RUN=true module_sidecar_remove testmod
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/testmod" ]]
}

# ── module_provided_version defaults (phase-invocation Sidecar hook) ─────────

@test "module_default_provided_version returns VERSION_PROVIDED" {
    VERSION_PROVIDED="9.9.9"
    run module_default_provided_version
    assert_success
    assert_output "9.9.9"
}

@test "module_default_apt_provided_version returns the dpkg version of APT_PKGS[0]" {
    APT_PKGS=(curl wget)
    VERSION_PROVIDED="apt-managed"
    dpkg-query() { printf '8.5.0-2ubuntu1'; }
    run module_default_apt_provided_version
    assert_success
    assert_output "8.5.0-2ubuntu1"
}

@test "module_default_apt_provided_version falls back to VERSION_PROVIDED when dpkg is empty" {
    APT_PKGS=(curl)
    VERSION_PROVIDED="apt-managed"
    dpkg-query() { return 1; }
    run module_default_apt_provided_version
    assert_success
    assert_output "apt-managed"
}

@test "module_default_github_release_provided_version returns MODULE_GH_RESOLVED_VERSION" {
    MODULE_GH_RESOLVED_VERSION="0.17.0"
    VERSION_PROVIDED="latest"
    run module_default_github_release_provided_version
    assert_success
    assert_output "0.17.0"
}

@test "module_default_github_release_provided_version preserves the existing Sidecar on idempotent re-install" {
    # MODULE_GH_RESOLVED_VERSION unset (skip-if-installed short-circuit) — must
    # NOT clobber the recorded version with the VERSION_PROVIDED fallback.
    NAME="ghtest"
    unset MODULE_GH_RESOLVED_VERSION
    VERSION_PROVIDED="latest"
    module_sidecar_write ghtest "0.16.2"
    run module_default_github_release_provided_version
    assert_success
    assert_output "0.16.2"
}

@test "module_default_github_release_provided_version falls back to VERSION_PROVIDED when no Sidecar" {
    NAME="ghtest-none"
    unset MODULE_GH_RESOLVED_VERSION
    VERSION_PROVIDED="latest"
    run module_default_github_release_provided_version
    assert_success
    assert_output "latest"
}

@test "module_default_config_provided_version returns VERSION_PROVIDED" {
    VERSION_PROVIDED="1.0"
    run module_default_config_provided_version
    assert_success
    assert_output "1.0"
}

# ── module_default_github_release_is_outdated ───────────────────────────────

@test "github is_outdated returns 1 when not installed" {
    NAME="ghtest"
    is_installed() { return 1; }
    run module_default_github_release_is_outdated
    assert_failure
}

@test "github is_outdated returns 1 when no Sidecar recorded" {
    NAME="ghtest"
    GITHUB_REPO="o/r"
    is_installed() { return 0; }
    get_github_pkg_latest_version() { local -n _o="${1}"; _o="2.0.0"; }
    run module_default_github_release_is_outdated
    assert_failure
}

@test "github is_outdated returns 0 when Sidecar differs from latest" {
    NAME="ghtest"
    GITHUB_REPO="o/r"
    is_installed() { return 0; }
    module_sidecar_write ghtest "1.0.0"
    get_github_pkg_latest_version() { local -n _o="${1}"; _o="2.0.0"; }
    run module_default_github_release_is_outdated
    assert_success
}

@test "github is_outdated returns 1 when Sidecar matches latest" {
    NAME="ghtest"
    GITHUB_REPO="o/r"
    is_installed() { return 0; }
    module_sidecar_write ghtest "2.0.0"
    get_github_pkg_latest_version() { local -n _o="${1}"; _o="2.0.0"; }
    run module_default_github_release_is_outdated
    assert_failure
}

# ── module_default_config_is_outdated ───────────────────────────────────────

@test "config is_outdated always returns 1 (no upstream version channel)" {
    run module_default_config_is_outdated
    assert_failure
}

# ── module_default_doctor (baseline runtime health) ─────────────────────────

@test "module_default_doctor passes when is_installed succeeds" {
    is_installed() { return 0; }
    run module_default_doctor
    assert_success
}

@test "module_default_doctor fails and warns when not installed" {
    is_installed() { return 1; }
    run module_default_doctor
    assert_failure
    assert_output --partial "doctor: not installed"
}

# ── _module_sidecar_after_phase (the phase-invocation wrapper) ───────────────

@test "_module_sidecar_after_phase install writes the sidecar via module_provided_version" {
    module_provided_version() { printf 'v2.0.0'; }
    _module_sidecar_after_phase install testmod
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/testmod" ]]
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/testmod")" == "v2.0.0" ]]
}

@test "_module_sidecar_after_phase upgrade refreshes the sidecar" {
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.0.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/testmod"
    module_provided_version() { printf '2.0.0'; }
    _module_sidecar_after_phase upgrade testmod
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/testmod")" == "2.0.0" ]]
}

@test "_module_sidecar_after_phase remove deletes the sidecar" {
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.0.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/testmod"
    _module_sidecar_after_phase remove testmod
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/testmod" ]]
}

@test "_module_sidecar_after_phase purge deletes the sidecar" {
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.0.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/testmod"
    _module_sidecar_after_phase purge testmod
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/testmod" ]]
}

@test "_module_sidecar_after_phase falls back to VERSION_PROVIDED when no override" {
    VERSION_PROVIDED="fallback-ver"
    # No module_provided_version defined in this test scope.
    unset -f module_provided_version 2>/dev/null || true
    _module_sidecar_after_phase install testmod
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/testmod")" == "fallback-ver" ]]
}

@test "_module_sidecar_after_phase is a no-op under dry-run" {
    module_provided_version() { printf 'v2.0.0'; }
    INIT_UBUNTU_DRY_RUN=true _module_sidecar_after_phase install testmod
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/testmod" ]]
}

@test "_module_sidecar_after_phase is a no-op for read-only phases" {
    module_provided_version() { printf 'v2.0.0'; }
    _module_sidecar_after_phase verify testmod
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/testmod" ]]
    _module_sidecar_after_phase doctor testmod
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/testmod" ]]
}

@test "module_standalone_main install writes the sidecar at the invocation layer" {
    NAME="testmod"
    VERSION_PROVIDED="1.2.3"
    install() { return 0; }
    run module_standalone_main install
    assert_success
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/testmod" ]]
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/testmod")" == "1.2.3" ]]
}

@test "module_standalone_main install does NOT write the sidecar when install fails" {
    NAME="testmod"
    VERSION_PROVIDED="1.2.3"
    install() { return 1; }
    run module_standalone_main install
    assert_failure
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/testmod" ]]
}

@test "module_standalone_main remove clears the sidecar at the invocation layer" {
    NAME="testmod"
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.2.3\n' > "${INIT_UBUNTU_STATE_DIR}/versions/testmod"
    remove() { return 0; }
    run module_standalone_main remove
    assert_success
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/testmod" ]]
}

# ── Standalone CLI entry: module_standalone_main ────────────────────────────

@test "module_standalone_main --help prints usage, exit 0" {
    run module_standalone_main --help
    assert_success
    assert_output --partial "Usage: bash module/"
    assert_output --partial "install"
}

@test "module_standalone_main --version prints '<name> <version>'" {
    NAME="testmod"
    VERSION_PROVIDED="v1.0"
    run module_standalone_main --version
    assert_success
    assert_output "testmod v1.0"
}

@test "module_standalone_main with unknown argument returns 2" {
    run module_standalone_main --bogus
    assert_failure 2
    assert_output --partial "Unknown argument"
}

@test "module_standalone_main without a phase returns 2 with usage" {
    run module_standalone_main
    assert_failure 2
    assert_output --partial "Usage: bash module/"
}

@test "module_standalone_main info routes to module_standalone_info" {
    NAME="testmod"
    declare -A DESCRIPTION=([en]="my module")
    run module_standalone_main info
    assert_success
    assert_output --partial "name:"
    assert_output --partial "testmod"
}

@test "module_standalone_main is-installed maps to is_installed() exit code" {
    is_installed() { return 0; }
    run module_standalone_main is-installed
    assert_success
    is_installed() { return 1; }
    run module_standalone_main is-installed
    assert_failure
}

@test "module_standalone_main is-outdated without implementation returns 2" {
    run module_standalone_main is-outdated
    assert_failure 2
    assert_output --partial "not implemented"
}

@test "module_standalone_main install runs the module's install()" {
    install() { echo "install-ran"; }
    run module_standalone_main install
    assert_success
    assert_output --partial "install-ran"
}

@test "module_standalone_main --dry-run exports INIT_UBUNTU_DRY_RUN for the phase" {
    install() { printf '%s\n' "${INIT_UBUNTU_DRY_RUN:-unset}"; }
    run module_standalone_main install --dry-run
    assert_success
    assert_output "true"
}

@test "module_standalone_main --lang=<code> drives i18n output of info" {
    NAME="testmod"
    declare -A DESCRIPTION=([en]="hello" [zh-TW]="你好")
    run module_standalone_main --lang=zh-TW info
    assert_success
    assert_output --partial "你好"
}

# ── module_default_verify ───────────────────────────────────────────────────

@test "module_default_verify fails when is_installed fails" {
    is_installed() { return 1; }
    run module_default_verify
    assert_failure
    assert_output --partial "verify failed"
}

@test "module_default_verify runs TEST_VERIFY_CMD when declared" {
    is_installed() { return 0; }
    TEST_VERIFY_CMD="echo verify-cmd-ran"
    run module_default_verify
    assert_success
    assert_output --partial "verify-cmd-ran"
}

@test "module_default_verify propagates TEST_VERIFY_CMD failure" {
    is_installed() { return 0; }
    TEST_VERIFY_CMD="false"
    run module_default_verify
    assert_failure
}

@test "module_default_verify dry-run skips checks" {
    is_installed() { return 1; }
    INIT_UBUNTU_DRY_RUN=true run module_default_verify
    assert_success
    assert_output --partial "DRY-RUN"
}

# ── APT archetype: upgrade fallback + is_outdated ───────────────────────────

@test "module_default_apt_upgrade falls back to install when not installed" {
    APT_PKGS=(curl)
    is_installed() { return 1; }
    install() { echo "install-called"; }
    run module_default_apt_upgrade
    assert_success
    assert_output --partial "running install instead"
    assert_output --partial "install-called"
}

@test "module_default_apt_is_outdated detects an upgradable package" {
    STUB_DIR="${INIT_UBUNTU_TEST_SCRATCH}/stubs"
    mkdir -p "${STUB_DIR}"
    cat > "${STUB_DIR}/apt" <<'EOF'
#!/usr/bin/env bash
printf 'Listing... Done\ncurl/jammy-updates 8.0 amd64 [upgradable from: 7.0]\n'
EOF
    chmod +x "${STUB_DIR}/apt"
    APT_PKGS=(curl)
    PATH="${STUB_DIR}:${PATH}" run module_default_apt_is_outdated
    assert_success
}

@test "module_default_apt_is_outdated returns 1 when package not upgradable" {
    STUB_DIR="${INIT_UBUNTU_TEST_SCRATCH}/stubs"
    mkdir -p "${STUB_DIR}"
    cat > "${STUB_DIR}/apt" <<'EOF'
#!/usr/bin/env bash
printf 'Listing... Done\nother-pkg/jammy 1.0 amd64 [upgradable from: 0.9]\n'
EOF
    chmod +x "${STUB_DIR}/apt"
    APT_PKGS=(curl)
    PATH="${STUB_DIR}:${PATH}" run module_default_apt_is_outdated
    assert_failure
}

@test "module_default_apt_is_outdated returns 1 on empty APT_PKGS" {
    APT_PKGS=()
    run module_default_apt_is_outdated
    assert_failure
}

# ── GitHub-release archetype: is_installed ──────────────────────────────────

@test "module_default_github_release_is_installed fails without BIN_NAME" {
    BIN_NAME=""
    run module_default_github_release_is_installed
    assert_failure
}

@test "module_default_github_release_is_installed detects executable BIN_LINK" {
    BIN_NAME="faketool"
    BIN_LINK="${INIT_UBUNTU_TEST_SCRATCH}/faketool"
    printf '#!/usr/bin/env bash\n' > "${BIN_LINK}"
    chmod +x "${BIN_LINK}"
    run module_default_github_release_is_installed
    assert_success
}

@test "module_default_github_release_is_installed fails when neither link nor PATH hit" {
    BIN_NAME="definitely-not-on-path-xyz"
    BIN_LINK="${INIT_UBUNTU_TEST_SCRATCH}/missing-link"
    run module_default_github_release_is_installed
    assert_failure
}

# ── Config archetype: remove / upgrade ──────────────────────────────────────

@test "module_default_config_remove deletes the dest file" {
    CONFIG_DEST="${INIT_UBUNTU_TEST_SCRATCH}/myrc"
    printf '# init_ubuntu managed\n' > "${CONFIG_DEST}"
    run module_default_config_remove
    assert_success
    [[ ! -e "${CONFIG_DEST}" ]]
}

@test "module_default_config_remove dry-run leaves the file" {
    CONFIG_DEST="${INIT_UBUNTU_TEST_SCRATCH}/myrc"
    printf '# init_ubuntu managed\n' > "${CONFIG_DEST}"
    INIT_UBUNTU_DRY_RUN=true run module_default_config_remove
    assert_success
    [[ -f "${CONFIG_DEST}" ]]
}

@test "module_default_config_upgrade re-drops config with the marker" {
    CONFIG_DEST="${INIT_UBUNTU_TEST_SCRATCH}/myrc"
    CONFIG_STUB="set background=light"
    BACKUP_DIR="${INIT_UBUNTU_TEST_SCRATCH}/backup"
    printf 'old content without marker\n' > "${CONFIG_DEST}"
    run module_default_config_upgrade
    assert_success
    grep -q "init_ubuntu managed" "${CONFIG_DEST}"
    grep -q "set background=light" "${CONFIG_DEST}"
}

# ── Engine-side aggregators: action_required events (AC-35) ─────────────────

@test "module_emit_post_install is a no-op when POST_INSTALL_MESSAGE undeclared" {
    export INIT_UBUNTU_LOG_FILE="${INIT_UBUNTU_TEST_SCRATCH}/events.jsonl"
    run module_emit_post_install
    assert_success
    [[ ! -s "${INIT_UBUNTU_LOG_FILE}" ]]
}

@test "module_emit_post_install emits action_required JSONL (kind=post_install)" {
    export INIT_UBUNTU_LOG_FILE="${INIT_UBUNTU_TEST_SCRATCH}/events.jsonl"
    declare -A POST_INSTALL_MESSAGE=([en]="restart your shell")
    run module_emit_post_install
    assert_success
    run jq -r 'select(.body == "action_required") | .attributes.kind' "${INIT_UBUNTU_LOG_FILE}"
    assert_success
    assert_output "post_install"
    run jq -r 'select(.body == "action_required") | .attributes.message' "${INIT_UBUNTU_LOG_FILE}"
    assert_output --partial "restart your shell"
}

@test "module_emit_reboot_required is a no-op when REBOOT_REQUIRED is not true" {
    export INIT_UBUNTU_LOG_FILE="${INIT_UBUNTU_TEST_SCRATCH}/events.jsonl"
    REBOOT_REQUIRED=false
    run module_emit_reboot_required
    assert_success
    [[ ! -s "${INIT_UBUNTU_LOG_FILE}" ]]
}

@test "module_emit_reboot_required emits action_required JSONL (kind=reboot)" {
    export INIT_UBUNTU_LOG_FILE="${INIT_UBUNTU_TEST_SCRATCH}/events.jsonl"
    REBOOT_REQUIRED=true
    run module_emit_reboot_required
    assert_success
    run jq -r 'select(.body == "action_required") | .attributes.kind' "${INIT_UBUNTU_LOG_FILE}"
    assert_success
    assert_output "reboot"
}

# ── github-release URL regression (one-char typo broke every real install) ──

@test "github-release fetch URL uses releases/latest/download (not latests)" {
    run grep -n 'releases/latests' "${LIB_DIR}/module_helper.sh"
    assert_failure
    run grep -n 'releases/latest/download' "${LIB_DIR}/module_helper.sh"
    assert_success
}
