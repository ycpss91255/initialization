#!/usr/bin/env bats
# test/unit/module_helpers_spec.bats — direct unit tests on lib/module_helpers.sh
#
# Tests the helper functions in isolation (no module file):
#   - module_i18n_get with various languages + fallback to en
#   - module_dryrun_guard / skip_if_installed / skip_if_not_installed
#   - module_use_apt_archetype defines 6 lifecycle functions
#   - module_use_github_release_archetype defines 6 lifecycle functions
#   - module_use_config_archetype defines 6 lifecycle functions
#   - module_default_apt_install in dry-run does not call apt-get
#   - module_default_config_install drops a marker

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
    # shellcheck disable=SC1091
    source "${LIB_DIR}/logger.sh"
    # shellcheck disable=SC1091
    source "${LIB_DIR}/general.sh"
    # shellcheck disable=SC1091
    source "${LIB_DIR}/module_helpers.sh"

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

@test "module_use_apt_archetype defines 6 lifecycle functions" {
    module_use_apt_archetype
    local _fn
    for _fn in is_installed install update remove purge verify; do
        declare -F "${_fn}" >/dev/null || { printf "missing %s\n" "${_fn}" >&2; return 1; }
    done
}

@test "module_use_github_release_archetype defines 6 lifecycle functions" {
    module_use_github_release_archetype
    local _fn
    for _fn in is_installed install update remove purge verify; do
        declare -F "${_fn}" >/dev/null || { printf "missing %s\n" "${_fn}" >&2; return 1; }
    done
}

@test "module_use_config_archetype defines 6 lifecycle functions" {
    module_use_config_archetype
    local _fn
    for _fn in is_installed install update remove purge verify; do
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
    DESCRIPTION=("en:my test module")
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
