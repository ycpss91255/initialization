#!/usr/bin/env bats
# test/unit/tool_bootstrap_spec.bats — lib/tool_bootstrap.sh
#
# The shared bootstrap for one-off tools (tool/<name>.sh). This spec pins its
# public contract through REAL behavior:
#   - the lib refuses to run as a top-level script (library guard)
#   - tool_bootstrap turns on the always-act strict mode (-e -u + pipefail) and
#     resolves + exports LIB_DIR / REPO_ROOT (self-located from its OWN path)
#   - tool_main implements the --help(0) / --dry-run / unknown(2) CLI and
#     dispatches to the caller's do_work
#   - tool_ensure_line is grep-guarded, idempotent, and dry-run-safe
#   - tool_run refuses host package installs and honors --dry-run
#
# Strict-mode snippets run as real FILES (never `bash -c`/`-s`): under kcov the
# child needs a real BASH_SOURCE or the tracer trips the bootstrap's `set -u`
# (same kcov/BASH_SOURCE hazard documented in test/unit/module_bootstrap_spec.bats).

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
    SNIPPET="${INIT_UBUNTU_TEST_SCRATCH}/snippet.sh"
    HARNESS="${INIT_UBUNTU_TEST_SCRATCH}/harness.sh"
    TARGET="${INIT_UBUNTU_TEST_SCRATCH}/marker.txt"
}

teardown() { teardown_test_env; }

# A reference tool: sources the bootstrap, defines usage() + do_work(), and
# hands off to tool_main — exactly the shape the template stamps out.
_write_harness() {
    cat > "${HARNESS}" <<EOF
#!/usr/bin/env bash
source "${LIB_DIR}/tool_bootstrap.sh"
tool_bootstrap
usage() { printf 'Usage: harness [--dry-run]\n'; }
do_work() { tool_ensure_line "${TARGET}" "marker-line"; }
tool_main "\$@"
EOF
}

# ── Smoke + library guard ────────────────────────────────────────────────────

@test "tool_bootstrap.sh parses (bash -n)" {
    run bash -n "${LIB_DIR}/tool_bootstrap.sh"
    assert_success
}

@test "tool_bootstrap.sh refuses to run as a top-level script (library guard)" {
    run bash "${LIB_DIR}/tool_bootstrap.sh"
    assert_success
    assert_output --partial "is a library"
}

@test "sourcing tool_bootstrap.sh defines the public tool_* API" {
    cat > "${SNIPPET}" <<'EOF'
source "$1/tool_bootstrap.sh"
for f in tool_bootstrap tool_main tool_is_dry_run tool_ensure_line tool_run; do
    declare -F "$f" >/dev/null || { echo "missing $f"; exit 1; }
done
echo ALL_DEFINED
EOF
    run bash "${SNIPPET}" "${LIB_DIR}"
    assert_success
    assert_output --partial "ALL_DEFINED"
}

# ── Strict mode + path resolution ────────────────────────────────────────────

@test "tool_bootstrap turns on always-act strict mode (-e -u + pipefail)" {
    cat > "${SNIPPET}" <<'EOF'
source "$1/tool_bootstrap.sh"
tool_bootstrap
[[ "$-" == *e* ]] && echo HAS_E
[[ "$-" == *u* ]] && echo HAS_U
set -o | grep -q "pipefail.*on" && echo HAS_PIPEFAIL
EOF
    run bash "${SNIPPET}" "${LIB_DIR}"
    assert_success
    assert_output --partial "HAS_E"
    assert_output --partial "HAS_U"
    assert_output --partial "HAS_PIPEFAIL"
}

@test "tool_bootstrap self-locates + exports LIB_DIR / REPO_ROOT" {
    cat > "${SNIPPET}" <<'EOF'
unset LIB_DIR REPO_ROOT
source "$1/tool_bootstrap.sh"
tool_bootstrap
[[ "${LIB_DIR}" == "$1" ]]     && echo LIB_OK
[[ -d "${REPO_ROOT}/lib" ]]    && echo ROOT_OK
env | grep -q "^LIB_DIR="      && echo EXPORTED
EOF
    run bash "${SNIPPET}" "${LIB_DIR}"
    assert_success
    assert_output --partial "LIB_OK"
    assert_output --partial "ROOT_OK"
    assert_output --partial "EXPORTED"
}

@test "tool_bootstrap sources the repo logger (log_info available)" {
    cat > "${SNIPPET}" <<'EOF'
source "$1/tool_bootstrap.sh"
tool_bootstrap
declare -F log_info >/dev/null && echo LOGGER_OK
EOF
    run bash "${SNIPPET}" "${LIB_DIR}"
    assert_success
    assert_output --partial "LOGGER_OK"
}

# ── tool_main CLI contract ───────────────────────────────────────────────────

@test "tool_main --help prints usage and exits 0" {
    _write_harness
    run bash "${HARNESS}" --help
    assert_success
    assert_output --partial "Usage:"
}

@test "tool_main -h is an alias for --help (exit 0)" {
    _write_harness
    run bash "${HARNESS}" -h
    assert_success
    assert_output --partial "Usage:"
}

@test "tool_main unknown argument prints usage to stderr and exits 2" {
    _write_harness
    run bash "${HARNESS}" --bogus
    assert_failure 2
    assert_output --partial "Usage:"
}

@test "tool_main --dry-run performs no filesystem mutation" {
    _write_harness
    run bash "${HARNESS}" --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
    [[ ! -e "${TARGET}" ]] || { printf 'dry-run mutated target: %s\n' "${TARGET}" >&2; return 1; }
}

@test "tool_main -n is an alias for --dry-run (no mutation)" {
    _write_harness
    run bash "${HARNESS}" -n
    assert_success
    [[ ! -e "${TARGET}" ]] || return 1
}

# ── tool_ensure_line: real run + idempotency ─────────────────────────────────

@test "tool_ensure_line writes the line on a real run" {
    _write_harness
    run bash "${HARNESS}"
    assert_success
    [[ -f "${TARGET}" ]] || { printf 'run did not create target\n' >&2; return 1; }
    grep -qxF "marker-line" "${TARGET}"
}

@test "tool_ensure_line is idempotent (single line after two runs)" {
    _write_harness
    run bash "${HARNESS}"
    assert_success
    run bash "${HARNESS}"
    assert_success
    local _count
    _count="$(grep -cxF "marker-line" "${TARGET}")"
    [[ "${_count}" -eq 1 ]] || { printf 'not idempotent: %s marker lines\n' "${_count}" >&2; return 1; }
}

# ── tool_run: host-install guard + dry-run ───────────────────────────────────

@test "tool_run refuses a host package install (returns nonzero, does not run it)" {
    cat > "${SNIPPET}" <<'EOF'
source "$1/tool_bootstrap.sh"
tool_bootstrap
if tool_run "sudo apt-get install -y cowsay"; then
    echo RAN
else
    echo REFUSED
fi
EOF
    run bash "${SNIPPET}" "${LIB_DIR}"
    assert_success
    assert_output --partial "REFUSED"
    assert_output --partial "refusing host package"
}

@test "tool_run --dry-run prints intent and does not execute" {
    cat > "${SNIPPET}" <<'EOF'
source "$1/tool_bootstrap.sh"
tool_bootstrap
TOOL_DRY_RUN=true
tool_run "touch $2"
EOF
    run bash "${SNIPPET}" "${LIB_DIR}" "${TARGET}"
    assert_success
    assert_output --partial "DRY-RUN"
    [[ ! -e "${TARGET}" ]] || { printf 'dry-run tool_run executed: %s\n' "${TARGET}" >&2; return 1; }
}
