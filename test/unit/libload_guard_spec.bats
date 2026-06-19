#!/usr/bin/env bats
# test/unit/libload_guard_spec.bats — entrypoint lib-load contract guard (#177)
#
# Cheap UNIT guard for the contract that masked the module_helper omission
# behind #174: setup_ubuntu.sh MUST source every lib the runner's module
# sub-shell needs. The runner sources each module in a `(...)` sub-shell that
# INHERITS functions from the parent (the setup_ubuntu.sh shell), so the
# archetype macros + lifecycle helpers from lib/module_helper.sh must be
# defined by the entrypoint — otherwise a real (non-dry-run) install of any
# archetype module dies with `module_use_*_archetype: command not found`.
#
# Why this catches what the existing suites missed (issue #177 / #174):
#   - e2e_spec.bats only drives --dry-run, which is dispatcher plan-only and
#     never reaches the runner / module source step.
#   - the per-module specs use a `_load_module` / `_load_engine` helper that
#     PRE-SOURCES lib/module_helper.sh, so the macros are present regardless
#     of whether the entrypoint sourced it — exactly the masking that let the
#     bug ship.
#
# This spec deliberately does NEITHER. It runs the REAL setup_ubuntu.sh as the
# entry point against a fixture github-release module injected via
# INIT_UBUNTU_USER_MODULE_DIR, routed through the root-safe `verify` subcommand
# (verify -> runner_verify -> source module sub-shell). The fixture calls the
# archetype macro at top level (so SOURCING it already requires module_helper)
# and its verify() dumps `declare -F` for the contract functions, which the
# entrypoint's loaded environment must have provided via inheritance.

bats_require_minimum_version 1.5.0

load "${BATS_TEST_DIRNAME}/../helper/common"

# The lifecycle/archetype contract the runner's module sub-shell inherits from
# the setup_ubuntu.sh parent shell. Dropping any source line for the lib that
# defines these from the entrypoint must make this spec fail.
CONTRACT_FNS=(
    module_use_apt_archetype
    module_use_github_release_archetype
    module_use_config_archetype
    module_dryrun_guard
    module_skip_if_installed
    _module_github_release_fetch_and_install
)

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false

    # Isolate every entrypoint-mutated path into the per-test scratch dir so a
    # real `verify` run never touches the real filesystem or the user's $HOME.
    SCRATCH_HOME="${INIT_UBUNTU_TEST_SCRATCH}/home"
    mkdir -p "${SCRATCH_HOME}"

    # Inject a single fixture module via the user-module discovery seam so we
    # never write into the repo's module/ dir. The fixture is a real
    # github-release archetype module: it calls the macro at top level (so the
    # runner cannot even SOURCE it without module_helper), then overrides
    # verify() to report which contract functions it inherited from the parent.
    USER_MODULE_DIR="${INIT_UBUNTU_TEST_SCRATCH}/user-module"
    mkdir -p "${USER_MODULE_DIR}"

    cat > "${USER_MODULE_DIR}/libguard-fixture.module.sh" <<'EOF'
NAME="libguard-fixture"
CATEGORY="optional"
TAGS=()
SUPPORTED_UBUNTU=()
SUPPORTED_PLATFORMS=()
DEPENDS_ON=()
CONFLICTS_WITH=()

# github-release archetype data (never fetched: verify is overridden below).
GITHUB_REPO="example/libguard-fixture"
BIN_NAME="libguard-fixture"
INSTALL_DIR="/opt/libguard-fixture"

# Top-level archetype macro call. If the entrypoint did NOT source
# lib/module_helper.sh, the runner's `source <module>` aborts right here with
# `module_use_github_release_archetype: command not found`.
module_use_github_release_archetype

# Override verify() (the macro set it to module_default_verify) to report the
# contract function table the module sub-shell inherited from the entrypoint.
verify() {
    local _fn _missing=0
    for _fn in \
        module_use_apt_archetype \
        module_use_github_release_archetype \
        module_use_config_archetype \
        module_dryrun_guard \
        module_skip_if_installed \
        _module_github_release_fetch_and_install
    do
        if declare -F "${_fn}" >/dev/null 2>&1; then
            printf 'LIBGUARD-FN-OK %s\n' "${_fn}"
        else
            printf 'LIBGUARD-FN-MISSING %s\n' "${_fn}"
            _missing=1
        fi
    done
    return "${_missing}"
}
EOF
}

teardown() {
    teardown_test_env
}

# Run the REAL entrypoint with the fixture wired in. No lib pre-sourcing here:
# whatever the contract functions resolve to comes solely from setup_ubuntu.sh.
_run_entrypoint_verify() {
    HOME="${SCRATCH_HOME}" \
    XDG_CONFIG_HOME="${INIT_UBUNTU_TEST_SCRATCH}/xdg-config" \
    XDG_STATE_HOME="${INIT_UBUNTU_TEST_SCRATCH}/xdg-state" \
    INIT_UBUNTU_USER_MODULE_DIR="${USER_MODULE_DIR}" \
        run bash "${REPO_ROOT}/setup_ubuntu.sh" verify libguard-fixture
}

@test "fixture github-release module is sourced by the real entrypoint runner" {
    # Sourcing alone exercises the top-level macro call. Pre-#174 (no
    # module_helper sourced by the entrypoint) this fails with
    # `module_use_github_release_archetype: command not found`.
    _run_entrypoint_verify
    refute_output --partial "command not found"
    refute_output --partial "module_use_github_release_archetype:"
}

@test "entrypoint defines every archetype macro + lifecycle helper for module sub-shells" {
    _run_entrypoint_verify
    assert_success
    local _fn
    for _fn in "${CONTRACT_FNS[@]}"; do
        assert_output --partial "LIBGUARD-FN-OK ${_fn}"
        refute_output --partial "LIBGUARD-FN-MISSING ${_fn}"
    done
}

@test "module_use_apt_archetype is inherited by the entrypoint module sub-shell" {
    _run_entrypoint_verify
    assert_output --partial "LIBGUARD-FN-OK module_use_apt_archetype"
}

@test "module_use_github_release_archetype is inherited by the entrypoint module sub-shell" {
    _run_entrypoint_verify
    assert_output --partial "LIBGUARD-FN-OK module_use_github_release_archetype"
}

@test "module_use_config_archetype is inherited by the entrypoint module sub-shell" {
    _run_entrypoint_verify
    assert_output --partial "LIBGUARD-FN-OK module_use_config_archetype"
}

@test "module_dryrun_guard is inherited by the entrypoint module sub-shell" {
    _run_entrypoint_verify
    assert_output --partial "LIBGUARD-FN-OK module_dryrun_guard"
}

@test "module_skip_if_installed is inherited by the entrypoint module sub-shell" {
    _run_entrypoint_verify
    assert_output --partial "LIBGUARD-FN-OK module_skip_if_installed"
}

@test "_module_github_release_fetch_and_install is inherited by the entrypoint module sub-shell" {
    _run_entrypoint_verify
    assert_output --partial "LIBGUARD-FN-OK _module_github_release_fetch_and_install"
}
