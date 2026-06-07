#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2317  # SC2034: test setups stage module metadata vars (NAME / APT_PKGS / ...) that the function-under-test reads after sourcing module_helper. SC2317: test mocks (is_installed/install) dispatched indirectly via the module's macro wrappers — https://www.shellcheck.net/wiki/SC2034 + https://www.shellcheck.net/wiki/SC2317
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

# ── Archetype macros: 6 functions each ──────────────────────────────────────

@test "module_use_apt_archetype defines 7 lifecycle functions" {
    module_use_apt_archetype
    local _fn
    for _fn in is_installed install upgrade remove purge verify is_outdated; do
        declare -F "${_fn}" >/dev/null || { printf "missing %s\n" "${_fn}" >&2; return 1; }
    done
}

@test "module_use_github_release_archetype defines 6 lifecycle functions" {
    module_use_github_release_archetype
    local _fn
    for _fn in is_installed install upgrade remove purge verify; do
        declare -F "${_fn}" >/dev/null || { printf "missing %s\n" "${_fn}" >&2; return 1; }
    done
}

@test "module_use_config_archetype defines 6 lifecycle functions" {
    module_use_config_archetype
    local _fn
    for _fn in is_installed install upgrade remove purge verify; do
        declare -F "${_fn}" >/dev/null || { printf "missing %s\n" "${_fn}" >&2; return 1; }
    done
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
