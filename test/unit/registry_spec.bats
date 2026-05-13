#!/usr/bin/env bats
# test/unit/registry_spec.bats — lib/registry.sh

load "${BATS_TEST_DIRNAME}/../helpers/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false

    # Fake module dir with synthetic fixtures.
    FAKE_MODULE_DIR="${INIT_UBUNTU_TEST_SCRATCH}/module"
    mkdir -p "${FAKE_MODULE_DIR}"

    cat > "${FAKE_MODULE_DIR}/alpha.module.sh" <<'EOF'
NAME="alpha"
CATEGORY="base"
TAGS=("core")
SUPPORTED_UBUNTU=("22.04" "24.04")
SUPPORTED_PLATFORMS=("desktop" "server")
DEPENDS_ON=()
CONFLICTS_WITH=()
EOF

    cat > "${FAKE_MODULE_DIR}/bravo.module.sh" <<'EOF'
NAME="bravo"
CATEGORY="recommended"
TAGS=("cli")
SUPPORTED_UBUNTU=("24.04")
SUPPORTED_PLATFORMS=("desktop")
DEPENDS_ON=("alpha")
CONFLICTS_WITH=("charlie")
EOF

    cat > "${FAKE_MODULE_DIR}/charlie.module.sh" <<'EOF'
NAME="charlie"
CATEGORY="optional"
TAGS=("cli" "agent")
SUPPORTED_UBUNTU=("24.04")
SUPPORTED_PLATFORMS=("desktop")
DEPENDS_ON=("alpha")
CONFLICTS_WITH=()
EOF
}

teardown() {
    teardown_test_env
}

@test "registry_load_all populates MODULES_NAME with one entry per fixture" {
    source "${LIB_DIR}/registry.sh"
    registry_load_all "${FAKE_MODULE_DIR}"
    [[ "${MODULES_NAME[alpha]}" == *"/alpha.module.sh" ]]
    [[ "${MODULES_NAME[bravo]}" == *"/bravo.module.sh" ]]
    [[ "${MODULES_NAME[charlie]}" == *"/charlie.module.sh" ]]
}

@test "registry_load_all reads CATEGORY correctly" {
    source "${LIB_DIR}/registry.sh"
    registry_load_all "${FAKE_MODULE_DIR}"
    [[ "${MODULES_CATEGORY[alpha]}" == "base" ]]
    [[ "${MODULES_CATEGORY[bravo]}" == "recommended" ]]
    [[ "${MODULES_CATEGORY[charlie]}" == "optional" ]]
}

@test "registry_load_all reads DEPENDS_ON as space-separated string" {
    source "${LIB_DIR}/registry.sh"
    registry_load_all "${FAKE_MODULE_DIR}"
    [[ "${MODULES_DEPS[alpha]}" == "" ]]
    [[ "${MODULES_DEPS[bravo]}" == "alpha" ]]
}

@test "registry_load_all reads CONFLICTS_WITH" {
    source "${LIB_DIR}/registry.sh"
    registry_load_all "${FAKE_MODULE_DIR}"
    [[ "${MODULES_CONFLICTS[bravo]}" == "charlie" ]]
}

@test "registry_load_all reads multi-element TAGS" {
    source "${LIB_DIR}/registry.sh"
    registry_load_all "${FAKE_MODULE_DIR}"
    [[ "${MODULES_TAGS[charlie]}" == "cli agent" ]]
}

@test "registry_get_field returns the right field" {
    source "${LIB_DIR}/registry.sh"
    registry_load_all "${FAKE_MODULE_DIR}"
    run registry_get_field bravo category
    assert_output "recommended"
    run registry_get_field bravo deps
    assert_output "alpha"
    run registry_get_field bravo conflicts
    assert_output "charlie"
}

@test "registry_has reports presence correctly" {
    source "${LIB_DIR}/registry.sh"
    registry_load_all "${FAKE_MODULE_DIR}"
    run registry_has alpha
    assert_success
    run registry_has nonexistent
    assert_failure
}

@test "registry_list_names returns sorted module names" {
    source "${LIB_DIR}/registry.sh"
    registry_load_all "${FAKE_MODULE_DIR}"
    run registry_list_names
    assert_success
    [[ "${lines[0]}" == "alpha" ]]
    [[ "${lines[1]}" == "bravo" ]]
    [[ "${lines[2]}" == "charlie" ]]
}

@test "registry_list_names --category=base filters" {
    source "${LIB_DIR}/registry.sh"
    registry_load_all "${FAKE_MODULE_DIR}"
    run registry_list_names --category=base
    assert_success
    [[ "${output}" == "alpha" ]]
}

@test "registry_list_names --tag=cli filters" {
    source "${LIB_DIR}/registry.sh"
    registry_load_all "${FAKE_MODULE_DIR}"
    run registry_list_names --tag=cli
    assert_success
    [[ "${lines[0]}" == "bravo" ]]
    [[ "${lines[1]}" == "charlie" ]]
}

@test "registry_load_all rejects mismatched NAME / filename" {
    cat > "${FAKE_MODULE_DIR}/delta.module.sh" <<'EOF'
NAME="not-delta"
CATEGORY="optional"
EOF
    source "${LIB_DIR}/registry.sh"
    run registry_load_all "${FAKE_MODULE_DIR}"
    assert_failure 1
    [[ -z "${MODULES_NAME[delta]:-}" ]]
    [[ -z "${MODULES_NAME[not-delta]:-}" ]]
}

@test "registry_load_all on missing dir is a no-op (returns 0)" {
    source "${LIB_DIR}/registry.sh"
    run registry_load_all "${INIT_UBUNTU_TEST_SCRATCH}/does-not-exist"
    assert_success
}

@test "registry_load_all on real module/ at least finds docker" {
    source "${LIB_DIR}/registry.sh"
    registry_load_all "${MODULE_DIR}"
    run registry_has docker
    assert_success
}
