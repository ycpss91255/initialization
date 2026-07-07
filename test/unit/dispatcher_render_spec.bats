#!/usr/bin/env bats
# test/unit/dispatcher_render_spec.bats — lib/dispatcher_render.sh
#
# Focused unit specs for the render primitives extracted from the dispatcher
# god-file (architecture-review E1). These cover the ONE canonical
# implementation that used to be copy-pasted across list --json / show --json:
#   _dispatcher_json_str_array   bash array → JSON string array
#   _dispatcher_module_probe     source a module once → recommended + description
# The end-to-end behavior of list/show --json remains asserted by
# dispatcher_spec.bats; this file only pins the shared seams.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false

    FAKE_MODULE_DIR="${INIT_UBUNTU_TEST_SCRATCH}/module"
    mkdir -p "${FAKE_MODULE_DIR}"
}

teardown() {
    teardown_test_env
}

_load_render() {
    # shellcheck source=../../lib/logger.sh
    source "${LIB_DIR}/logger.sh"
    # shellcheck source=../../lib/general.sh
    source "${LIB_DIR}/general.sh"
    # shellcheck source=../../lib/i18n.sh
    source "${LIB_DIR}/i18n.sh"
    # shellcheck source=../../lib/dispatcher.sh
    source "${LIB_DIR}/dispatcher.sh"
}

@test "_dispatcher_json_str_array renders a bash array as a JSON string array" {
    _load_render
    local -a _arr=("git" "curl" "a b")
    run _dispatcher_json_str_array "${_arr[@]}"
    assert_success
    # jq escapes each element; whitespace element stays a single string.
    assert_output '["git","curl","a b"]'
}

@test "_dispatcher_json_str_array on an empty array yields []" {
    _load_render
    local -a _arr=()
    run _dispatcher_json_str_array "${_arr[@]+"${_arr[@]}"}"
    assert_success
    assert_output '[]'
}

@test "_dispatcher_json_str_array jq-escapes special characters" {
    _load_render
    run _dispatcher_json_str_array 'quote"me' 'back\slash'
    assert_success
    assert_output '["quote\"me","back\\slash"]'
}

@test "_dispatcher_module_probe emits recommended token then description" {
    _load_render
    cat > "${FAKE_MODULE_DIR}/rec.module.sh" <<'EOF'
NAME="rec"
CATEGORY="recommended"
declare -A DESCRIPTION=( [en]="A recommended module" )
is_recommended() { return 0; }
install() { return 0; }
EOF
    run _dispatcher_module_probe "${FAKE_MODULE_DIR}/rec.module.sh" en
    assert_success
    assert_line --index 0 'true'
    assert_line --index 1 'A recommended module'
}

@test "_dispatcher_module_probe degrades to null for a missing file" {
    _load_render
    run _dispatcher_module_probe "${FAKE_MODULE_DIR}/does-not-exist.sh" en
    assert_success
    assert_output 'null'
}

@test "_dispatcher_module_description drops the recommended token" {
    _load_render
    cat > "${FAKE_MODULE_DIR}/desc.module.sh" <<'EOF'
NAME="desc"
CATEGORY="optional"
declare -A DESCRIPTION=( [en]="Only the description" [zh-TW]="只有描述" )
install() { return 0; }
EOF
    run _dispatcher_module_description "${FAKE_MODULE_DIR}/desc.module.sh"
    assert_success
    assert_output 'Only the description'
}

@test "_dispatcher_module_description honors INIT_UBUNTU_LANG" {
    _load_render
    cat > "${FAKE_MODULE_DIR}/desc.module.sh" <<'EOF'
NAME="desc"
CATEGORY="optional"
declare -A DESCRIPTION=( [en]="Only the description" [zh-TW]="只有描述" )
install() { return 0; }
EOF
    INIT_UBUNTU_LANG=zh-TW run _dispatcher_module_description "${FAKE_MODULE_DIR}/desc.module.sh"
    assert_success
    assert_output '只有描述'
}

@test "_dispatcher_module_description prints nothing when DESCRIPTION is absent" {
    _load_render
    cat > "${FAKE_MODULE_DIR}/bare.module.sh" <<'EOF'
NAME="bare"
CATEGORY="optional"
install() { return 0; }
EOF
    run _dispatcher_module_description "${FAKE_MODULE_DIR}/bare.module.sh"
    assert_success
    assert_output ''
}
