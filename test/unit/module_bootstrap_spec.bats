#!/usr/bin/env bats
# test/unit/module_bootstrap_spec.bats — lib/module_bootstrap.sh (arch deepening #3)
#
# The dual-mode module header was extracted into one `module_bootstrap`
# function. This spec pins its contract:
#   - standalone sourcing brings in the lib helpers + sets strict mode +
#     resolves and exports MODULE_DIR / REPO_ROOT / LIB_DIR (self-located from
#     the bootstrap's OWN path, not the caller's BASH_SOURCE)
#   - engine-mode invocation is a no-op (no re-source / no clobber of the libs
#     the runner already loaded)
#   - the lib file refuses to run as a top-level script (library guard)
#
# Standalone behaviour runs strict mode (`set -euo pipefail`). Under kcov the
# child must be a real script FILE, not `bash -s`/`bash -c`: a fresh stdin/-c
# shell leaves BASH_SOURCE unset, and kcov's ptrace instrumentation reads
# BASH_SOURCE on every command — under `set -u` that aborts with
# "BASH_SOURCE: unbound variable". A script file gives BASH_SOURCE a value, so
# the assertion exercises the real bootstrap instead of tripping the tracer.
# (Same class of kcov/BASH_SOURCE hazard documented in lib/runner.sh.) Each
# snippet is materialised via a quoted here-doc (`<<'EOF'`) so $1 / ${LIB_DIR}
# reach the child verbatim and the bats shell never expands them.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
    SNIPPET="${INIT_UBUNTU_TEST_SCRATCH}/snippet.sh"
}

teardown() { teardown_test_env; }

# Run the already-written ${SNIPPET} as `bash <file> LIB_DIR MODULE_DIR` so the
# child has a real BASH_SOURCE (kcov-safe under the bootstrap's set -u).
_run_snippet() {
    run bash "${SNIPPET}" "${LIB_DIR}" "${MODULE_DIR}"
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "module_bootstrap.sh parses (bash -n)" {
    run bash -n "${LIB_DIR}/module_bootstrap.sh"
    assert_success
}

@test "module_bootstrap.sh refuses to run as a top-level script (library guard)" {
    run bash "${LIB_DIR}/module_bootstrap.sh"
    assert_success
    assert_output --partial "is a library"
}

@test "sourcing module_bootstrap.sh defines the module_bootstrap function" {
    cat > "${SNIPPET}" <<'EOF'
source "$1/module_bootstrap.sh"
declare -F module_bootstrap >/dev/null && echo DEFINED
EOF
    _run_snippet
    assert_success
    assert_output --partial "DEFINED"
}

# ── Engine mode: no-op ───────────────────────────────────────────────────────

@test "module_bootstrap is a no-op when MODULE_STANDALONE != true (no clobber)" {
    cat > "${SNIPPET}" <<'EOF'
source "$1/module_bootstrap.sh"
MODULE_STANDALONE="false"
# Sentinel: if the bootstrap re-sourced module_helper.sh this would be
# overwritten by the real archetype macro. It must survive untouched.
module_use_apt_archetype() { printf "SENTINEL"; }
module_bootstrap
[[ "$(module_use_apt_archetype)" == "SENTINEL" ]] && echo NOOP
EOF
    _run_snippet
    assert_success
    assert_output --partial "NOOP"
}

@test "module_bootstrap engine no-op does not source the libs" {
    cat > "${SNIPPET}" <<'EOF'
source "$1/module_bootstrap.sh"
MODULE_STANDALONE="false"
module_bootstrap
# A bare shell that only sourced the bootstrap must NOT have log_info
# (defined by logger.sh) after the no-op path.
if declare -F log_info >/dev/null; then echo SOURCED; else echo NOT_SOURCED; fi
EOF
    _run_snippet
    assert_success
    assert_output --partial "NOT_SOURCED"
}

@test "engine-mode module source is a no-op (libs preloaded, not re-sourced)" {
    cat > "${SNIPPET}" <<'EOF'
set -uo pipefail
source "$1/logger.sh"
source "$1/general.sh"
source "$1/module_helper.sh"
MODULE_STANDALONE=false
source "$2/ripgrep.module.sh"
[[ "${MODULE_STANDALONE}" == "false" ]] || { echo "standalone leaked"; exit 1; }
declare -F install >/dev/null || { echo "install missing"; exit 1; }
echo OK
EOF
    _run_snippet
    assert_success
    assert_output --partial "OK"
}

# ── Standalone mode: helpers + strict mode + paths ────────────────────────────

@test "standalone module_bootstrap pulls in logger + general + module_helper" {
    cat > "${SNIPPET}" <<'EOF'
MODULE_STANDALONE=true
source "$1/module_bootstrap.sh"
module_bootstrap
declare -F log_info                 >/dev/null || { echo "no log_info"; exit 1; }
declare -F module_i18n_get          >/dev/null || { echo "no module_i18n_get"; exit 1; }
declare -F module_use_apt_archetype >/dev/null || { echo "no archetype"; exit 1; }
echo OK
EOF
    _run_snippet
    assert_success
    assert_output --partial "OK"
}

@test "standalone module_bootstrap turns on strict mode (-e -u + pipefail)" {
    cat > "${SNIPPET}" <<'EOF'
MODULE_STANDALONE=true
source "$1/module_bootstrap.sh"
module_bootstrap
[[ "$-" == *e* ]] && echo HAS_E
[[ "$-" == *u* ]] && echo HAS_U
set -o | grep -q "pipefail.*on" && echo HAS_PIPEFAIL
EOF
    _run_snippet
    assert_success
    assert_output --partial "HAS_E"
    assert_output --partial "HAS_U"
    assert_output --partial "HAS_PIPEFAIL"
}

@test "standalone module_bootstrap resolves + exports MODULE_DIR/REPO_ROOT/LIB_DIR" {
    cat > "${SNIPPET}" <<'EOF'
MODULE_STANDALONE=true
source "$1/module_bootstrap.sh"
module_bootstrap
printf "LIB_DIR=%s\n" "${LIB_DIR}"
# MODULE_DIR must point at the real module/ dir (config-drop modules read
# ${MODULE_DIR}/config/...).
[[ -f "${MODULE_DIR}/ripgrep.module.sh" ]] && echo MODULE_DIR_OK
[[ -d "${REPO_ROOT}/lib" ]] && echo REPO_ROOT_OK
# exported -> visible to a child process
env | grep -q "^MODULE_DIR=" && echo EXPORTED
EOF
    _run_snippet
    assert_success
    assert_output --partial "MODULE_DIR_OK"
    assert_output --partial "REPO_ROOT_OK"
    assert_output --partial "EXPORTED"
    assert_output --partial "LIB_DIR=${LIB_DIR}"
}

@test "module_bootstrap self-locates LIB_DIR from its own path when env is unset" {
    cat > "${SNIPPET}" <<'EOF'
unset LIB_DIR REPO_ROOT MODULE_DIR
MODULE_STANDALONE=true
source "$1/module_bootstrap.sh"
module_bootstrap
[[ "${LIB_DIR}" == "$1" ]] && echo SELF_LOCATED
EOF
    _run_snippet
    assert_success
    assert_output --partial "SELF_LOCATED"
}

@test "env-provided LIB_DIR takes precedence over self-location" {
    local _custom="${INIT_UBUNTU_TEST_SCRATCH}/custom-lib"
    mkdir -p "${_custom}"
    cp "${LIB_DIR}/logger.sh" "${LIB_DIR}/general.sh" \
       "${LIB_DIR}/module_helper.sh" "${_custom}/"
    [[ -f "${LIB_DIR}/i18n.sh" ]] && cp "${LIB_DIR}/i18n.sh" "${_custom}/"
    cat > "${SNIPPET}" <<'EOF'
MODULE_STANDALONE=true
source "$1/module_bootstrap.sh"
module_bootstrap
printf "LIB_DIR=%s\n" "${LIB_DIR}"
EOF
    run env LIB_DIR="${_custom}" bash "${SNIPPET}" "${LIB_DIR}"
    assert_success
    assert_output --partial "LIB_DIR=${_custom}"
}
