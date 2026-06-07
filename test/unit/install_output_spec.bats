#!/usr/bin/env bats
# test/unit/install_output_spec.bats — install output pipeline (issue #66)
#
# PRD §7.2 (plan + confirm), §7.7.1 (progress + cmd_exec capture),
# §7.7.2 / AC-35 (Action required aggregation derived from JSONL events).
#
# All specs drive the public surface only: dispatcher_dispatch / runner_install
# against mock module fixtures (same harness style as dispatcher_spec /
# runner_spec).

bats_require_minimum_version 1.5.0

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false

    FAKE_MODULE_DIR="${INIT_UBUNTU_TEST_SCRATCH}/module"
    mkdir -p "${FAKE_MODULE_DIR}"

    # main module depending on two leaves — exercises the "+ N deps" plan line.
    cat > "${FAKE_MODULE_DIR}/depa.module.sh" <<'EOF'
NAME="depa"
CATEGORY="optional"
TAGS=()
SUPPORTED_UBUNTU=()
SUPPORTED_PLATFORMS=()
DEPENDS_ON=()
CONFLICTS_WITH=()
install() { return 0; }
remove()  { return 0; }
purge()   { return 0; }
EOF
    cat > "${FAKE_MODULE_DIR}/depb.module.sh" <<'EOF'
NAME="depb"
CATEGORY="optional"
TAGS=()
SUPPORTED_UBUNTU=()
SUPPORTED_PLATFORMS=()
DEPENDS_ON=()
CONFLICTS_WITH=()
install() { return 0; }
remove()  { return 0; }
purge()   { return 0; }
EOF
    cat > "${FAKE_MODULE_DIR}/main.module.sh" <<'EOF'
NAME="main"
CATEGORY="optional"
TAGS=()
SUPPORTED_UBUNTU=()
SUPPORTED_PLATFORMS=()
DEPENDS_ON=("depa" "depb")
CONFLICTS_WITH=()
install() { return 0; }
upgrade() { echo "MAIN-UPGRADE-RAN"; return 0; }
remove()  { return 0; }
purge()   { return 0; }
EOF
}

teardown() {
    teardown_test_env
}

_load_engine() {
    # shellcheck source=../../lib/logger.sh
    source "${LIB_DIR}/logger.sh"
    # shellcheck source=../../lib/general.sh
    source "${LIB_DIR}/general.sh"
    # shellcheck source=../../lib/module_helper.sh
    source "${LIB_DIR}/module_helper.sh"
    # shellcheck source=../../lib/state.sh
    source "${LIB_DIR}/state.sh"
    # shellcheck source=../../lib/config.sh
    source "${LIB_DIR}/config.sh"
    # shellcheck source=../../lib/registry.sh
    source "${LIB_DIR}/registry.sh"
    # shellcheck source=../../lib/resolver.sh
    source "${LIB_DIR}/resolver.sh"
    # shellcheck source=../../lib/runner.sh
    source "${LIB_DIR}/runner.sh"
    # shellcheck source=../../lib/dispatcher.sh
    source "${LIB_DIR}/dispatcher.sh"
    registry_load_all "${FAKE_MODULE_DIR}"
}

# ── §7.2 plan + confirm ──────────────────────────────────────────────────────

@test "install without -y prints plan with dep count and Proceed? [Y/n]" {
    _load_engine
    # Non-tty stdin: nobody can answer, so the install default (yes) applies
    # and execution continues past the prompt (here: until the root-refusal
    # or the runner, whichever comes first in the container).
    run dispatcher_dispatch install main
    assert_output --partial "Will install: main + 2 deps (depa, depb)"
    assert_output --partial "Proceed? [Y/n]"
}

@test "install -y skips the plan prompt" {
    _load_engine
    run dispatcher_dispatch install main -y
    refute_output --partial "Proceed?"
}

@test "install --dry-run never prompts" {
    _load_engine
    run dispatcher_dispatch install main --dry-run
    assert_success
    refute_output --partial "Proceed?"
}

# ── §7.7.1 progress rendering ────────────────────────────────────────────────

@test "runner_install prints [i/N] per-module progress headers" {
    _load_engine
    run runner_install depa main
    assert_success
    assert_output --partial "[1/2] depa: installing..."
    assert_output --partial "[2/2] main: installing..."
}

@test "runner_install prints checkmark success line with duration" {
    _load_engine
    run runner_install depa
    assert_success
    assert_output --regexp 'installed \([0-9]+s\)'
    assert_output --partial "✔ depa installed"
}

# Helper: register a module whose install() runs a child script via exec_cmd.
# The marker text lives only in the child script body (not in the command
# line) so "not streamed" can be asserted without matching the echoed cmd.
_register_cmdmod() {
    local _child="${INIT_UBUNTU_TEST_SCRATCH}/child.sh"
    cat > "${_child}" <<'EOF'
#!/usr/bin/env bash
echo "CHILD-STDOUT-MARKER"
echo "CHILD-STDERR-MARKER" >&2
exit "${CHILD_EXIT:-0}"
EOF
    chmod +x "${_child}"
    cat > "${FAKE_MODULE_DIR}/cmdmod.module.sh" <<EOF
NAME="cmdmod"
CATEGORY="optional"
TAGS=()
SUPPORTED_UBUNTU=()
SUPPORTED_PLATFORMS=()
DEPENDS_ON=()
CONFLICTS_WITH=()
install() { exec_cmd "${_child}"; }
remove()  { return 0; }
purge()   { return 0; }
EOF
    registry_load_all "${FAKE_MODULE_DIR}"
}

@test "exec_cmd child output is captured into JSONL cmd_exec, not streamed" {
    _load_engine
    _register_cmdmod
    export INIT_UBUNTU_LOG_FILE="${INIT_UBUNTU_TEST_SCRATCH}/session.jsonl"

    run runner_install cmdmod
    assert_success
    # Child stdout/stderr must NOT stream to the console (PRD §7.7.1)...
    refute_output --partial "CHILD-STDOUT-MARKER"
    refute_output --partial "CHILD-STDERR-MARKER"
    # ...but the highlighted command line itself is printed.
    assert_output --partial "child.sh"

    # The cmd_exec event carries exit + duration_ms + the captured output.
    run jq -r 'select(.body=="cmd_exec") | .attributes.exit' \
        "${INIT_UBUNTU_LOG_FILE}"
    assert_output "0"
    run jq -e 'select(.body=="cmd_exec") | .attributes.duration_ms >= 0' \
        "${INIT_UBUNTU_LOG_FILE}"
    assert_success
    run jq -r 'select(.body=="cmd_exec") | .attributes.output' \
        "${INIT_UBUNTU_LOG_FILE}"
    assert_output --partial "CHILD-STDOUT-MARKER"
    assert_output --partial "CHILD-STDERR-MARKER"
}

@test "verbose mode streams child output live (and still captures it)" {
    _load_engine
    _register_cmdmod
    export INIT_UBUNTU_LOG_FILE="${INIT_UBUNTU_TEST_SCRATCH}/session.jsonl"
    export INIT_UBUNTU_VERBOSE=true

    run runner_install cmdmod
    assert_success
    assert_output --partial "CHILD-STDOUT-MARKER"
    run jq -r 'select(.body=="cmd_exec") | .attributes.output' \
        "${INIT_UBUNTU_LOG_FILE}"
    assert_output --partial "CHILD-STDOUT-MARKER"
}

@test "quiet mode suppresses progress lines but keeps errors" {
    _load_engine
    cat > "${FAKE_MODULE_DIR}/boom.module.sh" <<'EOF'
NAME="boom"
CATEGORY="optional"
TAGS=()
SUPPORTED_UBUNTU=()
SUPPORTED_PLATFORMS=()
DEPENDS_ON=()
CONFLICTS_WITH=()
install() { return 1; }
remove()  { return 0; }
purge()   { return 0; }
EOF
    registry_load_all "${FAKE_MODULE_DIR}"
    export INIT_UBUNTU_QUIET=true

    run runner_install depa boom
    assert_failure 6
    # No progress headers, no checkmark lines (PRD §7.7.1 --quiet)...
    refute_output --partial "[1/2]"
    refute_output --partial "✔"
    # ...but warn/error survive.
    assert_output --partial "install failed"
}

@test "dispatcher install accepts --verbose and --quiet flags" {
    _load_engine
    run dispatcher_dispatch install main --dry-run --verbose
    assert_success
    refute_output --partial "unknown flag"
    run dispatcher_dispatch install main --dry-run --quiet
    assert_success
    refute_output --partial "unknown flag"
}

@test "failure dumps last ~20 child-output lines plus trace_id and log path" {
    _load_engine
    _register_cmdmod
    export INIT_UBUNTU_LOG_FILE="${INIT_UBUNTU_TEST_SCRATCH}/session.jsonl"
    # Child emits 30 numbered lines then fails: the dump must contain the
    # tail (line-30) but not the head (line-1).
    cat > "${INIT_UBUNTU_TEST_SCRATCH}/child.sh" <<'EOF'
#!/usr/bin/env bash
for i in $(seq 1 30); do echo "child-line-${i}"; done
exit 1
EOF

    run runner_install cmdmod
    assert_failure 6
    assert_output --partial "child-line-30"
    # tail ~20 of 30 lines keeps 11..30; the exact line "child-line-1" is cut.
    refute_output --partial $'child-line-1\n'
    assert_output --partial "trace_id="
    assert_output --partial "${INIT_UBUNTU_LOG_FILE}"
}

# ── §7.7.2 Action required aggregation (AC-35) ───────────────────────────────

@test "Action required block is derived from action_required JSONL events (AC-35)" {
    _load_engine
    export INIT_UBUNTU_LOG_FILE="${INIT_UBUNTU_TEST_SCRATCH}/session.jsonl"
    cat > "${FAKE_MODULE_DIR}/pim.module.sh" <<'EOF'
NAME="pim"
CATEGORY="optional"
TAGS=()
SUPPORTED_UBUNTU=()
SUPPORTED_PLATFORMS=()
DEPENDS_ON=()
CONFLICTS_WITH=()
declare -A POST_INSTALL_MESSAGE=(
    [en]="Run 'newgrp pim' or re-login to use pim."
)
REBOOT_REQUIRED=true
install() { return 0; }
remove()  { return 0; }
purge()   { return 0; }
EOF
    registry_load_all "${FAKE_MODULE_DIR}"

    run runner_install pim
    assert_success
    assert_output --partial "Action required"

    # Both kinds were emitted as structured events (module-spec §4.10).
    run jq -r 'select(.body=="action_required") | .attributes.kind' \
        "${INIT_UBUNTU_LOG_FILE}"
    assert_line "post_install"
    assert_line "reboot"

    # AC-35: block content identical to the events — every service.name +
    # message pair from `jq 'select(.body=="action_required")'` must appear
    # verbatim in the rendered block.
    run runner_install pim
    local _pairs
    _pairs="$(jq -r 'select(.body=="action_required")
        | .attributes["service.name"] + "\t" + .attributes.message' \
        "${INIT_UBUNTU_LOG_FILE}" | sort -u)"
    [ -n "${_pairs}" ]
    local _svc _msg
    while IFS=$'\t' read -r _svc _msg; do
        assert_output --partial "${_svc}"
        assert_output --partial "${_msg}"
    done <<< "${_pairs}"
}

@test "modules without post-install hints render no Action required block" {
    _load_engine
    export INIT_UBUNTU_LOG_FILE="${INIT_UBUNTU_TEST_SCRATCH}/session.jsonl"
    run runner_install depa
    assert_success
    refute_output --partial "Action required"
}

@test "upgrade without -y keeps Proceed? [y/N] and non-tty default aborts" {
    _load_engine
    # Upgrade keeps the conservative [y/N] default (PRD §7.6): a non-tty
    # stdin means nobody can answer, so the default (no) applies and the
    # runner is never reached.
    run dispatcher_dispatch upgrade main
    assert_failure 1
    assert_output --partial "Proceed? [y/N]"
    assert_output --partial "Aborted"
    refute_output --partial "MAIN-UPGRADE-RAN"
}
