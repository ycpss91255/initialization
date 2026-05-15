#!/usr/bin/env bats
# test/unit/template_smoke_spec.bats — verify template/module.template.sh
#
# Smoke-tests a copy of the template (with TODOs filled) through the full
# standalone CLI surface. Catches drift at the template level so downstream
# modules don't inherit broken behavior.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
    export INIT_UBUNTU_LANG=en
    # Template header honors LIB_DIR / REPO_ROOT env vars, so a fixture in
    # /tmp/.../scratch/module/ can still locate the real lib helpers.
    export LIB_DIR REPO_ROOT

    FIXTURE_DIR="${INIT_UBUNTU_TEST_SCRATCH}/module"
    mkdir -p "${FIXTURE_DIR}"
    SMOKE="${FIXTURE_DIR}/smoke.module.sh"

    # Fill the visible <TODO ...> placeholders. Keep the rest untouched so
    # this spec exercises the actual template shape, not a stripped variant.
    sed \
        -e 's|<TODO-kebab-case-name>|smoke|g' \
        -e 's|<TODO: apt-managed \| latest \| v1.2.3>|test|g' \
        -e 's|<TODO: one-line English description (< 80 chars)>|smoke module|g' \
        -e 's|<TODO: 一行繁中描述 (< 50 字元)>|測試 module|g' \
        -e 's|<TODO: base \| recommended \| optional \| experimental>|optional|g' \
        -e 's|<TODO-primary-tag>|test|g' \
        "${TEMPLATE_DIR}/module.template.sh" > "${SMOKE}"
    chmod +x "${SMOKE}"
}

teardown() {
    teardown_test_env
}

# ── Standalone CLI surfaces ─────────────────────────────────────────────────

@test "template smoke: --help lists all phases" {
    run bash "${SMOKE}" --help
    assert_success
    for _p in install update remove purge verify detect is-installed is-recommended status info; do
        assert_output --partial "${_p}"
    done
    assert_output --partial "--dry-run"
    assert_output --partial "--lang="
}

@test "template smoke: --version prints NAME + VERSION_PROVIDED" {
    run bash "${SMOKE}" --version
    assert_success
    assert_output --partial "smoke"
    assert_output --partial "test"
}

@test "template smoke: no args prints usage + exit 2" {
    run bash "${SMOKE}"
    assert_failure 2
    assert_output --partial "Usage:"
}

@test "template smoke: unknown phase returns exit 2" {
    run bash "${SMOKE}" nope
    assert_failure 2
}

@test "template smoke: install --dry-run succeeds with DRY-RUN log" {
    run bash "${SMOKE}" install --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "template smoke: update --dry-run succeeds (update falls back to install)" {
    run bash "${SMOKE}" update --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "template smoke: remove --dry-run succeeds" {
    run bash "${SMOKE}" remove --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "template smoke: purge --dry-run succeeds" {
    run bash "${SMOKE}" purge --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "template smoke: verify --dry-run succeeds" {
    run bash "${SMOKE}" verify --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "template smoke: is-installed returns 1 on fresh fixture" {
    run bash "${SMOKE}" is-installed
    assert_failure 1
}

@test "template smoke: is-outdated returns exit 2 (optional, not implemented)" {
    # is_outdated is OPTIONAL — template leaves it commented out, so the
    # standalone main should reject the phase with a clear message.
    run bash "${SMOKE}" is-outdated
    assert_failure 2
    assert_output --partial "is_outdated"
}

@test "template smoke: doctor returns exit 2 (optional, not implemented)" {
    run bash "${SMOKE}" doctor
    assert_failure 2
}

# ── Engine-side projections (status / info) ─────────────────────────────────

@test "template smoke: info prints name + description + category" {
    run bash "${SMOKE}" info
    assert_success
    assert_output --partial "name:"
    assert_output --partial "smoke"
    assert_output --partial "description:"
    assert_output --partial "smoke module"
    assert_output --partial "category:"
    assert_output --partial "optional"
}

@test "template smoke: info --lang=zh-TW returns Chinese description" {
    run bash "${SMOKE}" info --lang=zh-TW
    assert_success
    assert_output --partial "測試 module"
}

@test "template smoke: status prints installed:no on fresh fixture" {
    run bash "${SMOKE}" status
    assert_success
    assert_output --partial "installed:"
    assert_output --partial "no"
}

# ── Source-mode behavior (the other half of dual-mode) ──────────────────────

@test "template smoke: sourcing does NOT auto-execute footer" {
    run bash -c "
        source '${LIB_DIR}/logger.sh'
        source '${LIB_DIR}/general.sh'
        source '${LIB_DIR}/module_helpers.sh'
        source '${SMOKE}'
        declare -F install >/dev/null && echo INSTALL_DEFINED
        declare -F update  >/dev/null && echo UPDATE_DEFINED
        declare -F remove  >/dev/null && echo REMOVE_DEFINED
        declare -F purge   >/dev/null && echo PURGE_DEFINED
        declare -F verify  >/dev/null && echo VERIFY_DEFINED
        [[ \"\${NAME}\" == 'smoke' ]] && echo NAME_LOADED
        [[ \"\${MODULE_STANDALONE}\" == 'false' ]] && echo STANDALONE_FALSE
    "
    assert_success
    assert_output --partial "INSTALL_DEFINED"
    assert_output --partial "UPDATE_DEFINED"
    assert_output --partial "REMOVE_DEFINED"
    assert_output --partial "PURGE_DEFINED"
    assert_output --partial "VERIFY_DEFINED"
    assert_output --partial "NAME_LOADED"
    assert_output --partial "STANDALONE_FALSE"
    refute_output --partial "Usage:"
}

# ── No side-effect leakage in dry-run ───────────────────────────────────────

@test "template smoke: install --dry-run does not call apt-get / curl / sudo" {
    STUB_DIR="${INIT_UBUNTU_TEST_SCRATCH}/stubs"
    STUB_LOG="${INIT_UBUNTU_TEST_SCRATCH}/stub.log"
    mkdir -p "${STUB_DIR}"
    : > "${STUB_LOG}"
    local _bin
    for _bin in apt-get curl sudo; do
        cat > "${STUB_DIR}/${_bin}" <<EOF
#!/usr/bin/env bash
echo "${_bin}: \$*" >> "${STUB_LOG}"
exit 1
EOF
        chmod +x "${STUB_DIR}/${_bin}"
    done

    PATH="${STUB_DIR}:${PATH}" run bash "${SMOKE}" install --dry-run
    assert_success
    [[ ! -s "${STUB_LOG}" ]]
}
