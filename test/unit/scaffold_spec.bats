#!/usr/bin/env bats
# test/unit/scaffold_spec.bats — spec for the dev-side scaffold generator
# (script/scaffold.sh).
#
# The generator stamps a new one-off tool or Claude hook — plus its matching
# bats spec — from the canonical templates (ADR-0029). These tests assert:
#   * stamping produces a script that sources the RIGHT bootstrap and a spec
#     with every placeholder filled;
#   * the stamped script satisfies the outward contract out of the box;
#   * the stamped spec PASSES as a stub (run under a nested bats);
#   * misuse is rejected with exit 2 (the tool/hook usage-error contract).
#
# Output is stamped into a scratch --root, never the live repo. Nested-bats
# runs mirror the repo layout with symlinks so the stub's relative loads and
# bootstrap source resolve.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    setup_test_env
    export LIB_DIR REPO_ROOT
    export LOG_LEVEL=INFO
    export LOG_COLOR=false

    SCAFFOLD="${REPO_ROOT}/script/scaffold.sh"

    # A scratch --root that mirrors the repo layout with REAL copies of the
    # dirs a stamped spec depends on. Copies (not symlinks): the test helper's
    # `pwd -P` self-location would otherwise follow a symlink back to the real
    # repo and resolve REPO_ROOT there instead of under the scratch root.
    ROOT="${INIT_UBUNTU_TEST_SCRATCH}/root"
    mkdir -p "${ROOT}/test"
    cp -r "${REPO_ROOT}/lib" "${ROOT}/lib"
    cp -r "${REPO_ROOT}/template" "${ROOT}/template"
    cp -r "${REPO_ROOT}/test/helper" "${ROOT}/test/helper"
}

teardown() { teardown_test_env; }

# ── new-tool: stamps a conforming tool + a passing spec ──────────────────────

@test "new-tool stamps a script that sources lib/tool_bootstrap.sh" {
    run bash "${SCAFFOLD}" new-tool demo-widget --root "${ROOT}"
    assert_success

    local _script="${ROOT}/tool/demo-widget.sh"
    [[ -f "${_script}" ]] || { printf 'tool not stamped: %s\n' "${_script}" >&2; return 1; }
    grep -q 'tool_bootstrap.sh' "${_script}"
    grep -q 'TOOL_NAME="demo-widget"' "${_script}"
    [[ -x "${_script}" ]] || { printf 'stamped tool not executable\n' >&2; return 1; }
}

@test "new-tool stamps a spec with every <TOOL-NAME> placeholder filled" {
    run bash "${SCAFFOLD}" new-tool demo-widget --root "${ROOT}"
    assert_success

    local _spec="${ROOT}/test/unit/tool/demo-widget_spec.bats"
    [[ -f "${_spec}" ]] || { printf 'spec not stamped: %s\n' "${_spec}" >&2; return 1; }
    run grep -c '<TOOL-NAME>' "${_spec}"
    [[ "${output}" -eq 0 ]] || { printf 'unfilled <TOOL-NAME> placeholders: %s\n' "${output}" >&2; return 1; }
    grep -q 'demo-widget' "${_spec}"
}

@test "the stamped tool satisfies the --help/unknown-arg/--dry-run contract" {
    run bash "${SCAFFOLD}" new-tool demo-widget --root "${ROOT}"
    assert_success

    local _script="${ROOT}/tool/demo-widget.sh"
    export TOOL_TEMPLATE_TARGET="${INIT_UBUNTU_TEST_SCRATCH}/demo.marker"

    run bash "${_script}" --help
    assert_success
    assert_output --partial "Usage:"

    run bash "${_script}" --nope
    assert_failure 2

    run bash "${_script}" --dry-run
    assert_success
    [[ ! -e "${TOOL_TEMPLATE_TARGET}" ]] || { printf 'dry-run mutated target\n' >&2; return 1; }

    run bash "${_script}"
    assert_success
    [[ -f "${TOOL_TEMPLATE_TARGET}" ]] || { printf 'real run did not create target\n' >&2; return 1; }
}

@test "the stamped tool spec passes as a stub (nested bats)" {
    run bash "${SCAFFOLD}" new-tool demo-widget --root "${ROOT}"
    assert_success
    run bats "${ROOT}/test/unit/tool/demo-widget_spec.bats"
    [[ "${status}" -eq 0 ]] || { printf 'nested bats failed:\n%s\n' "${output}" >&2; return 1; }
}

# ── new-hook: stamps a conforming hook + a passing spec ──────────────────────

@test "new-hook stamps a script that sources lib/hook_bootstrap.sh with the name wired in" {
    run bash "${SCAFFOLD}" new-hook demo-guard --root "${ROOT}"
    assert_success

    local _script="${ROOT}/.agents/hook/demo-guard.sh"
    [[ -f "${_script}" ]] || { printf 'hook not stamped: %s\n' "${_script}" >&2; return 1; }
    grep -q 'hook_bootstrap.sh' "${_script}"
    grep -q 'hook_bootstrap "demo-guard"' "${_script}"
    [[ -x "${_script}" ]] || { printf 'stamped hook not executable\n' >&2; return 1; }
}

@test "new-hook stamps a spec with every <HOOK-NAME> placeholder filled" {
    run bash "${SCAFFOLD}" new-hook demo-guard --root "${ROOT}"
    assert_success

    local _spec="${ROOT}/test/unit/hook/demo-guard_spec.bats"
    [[ -f "${_spec}" ]] || { printf 'spec not stamped: %s\n' "${_spec}" >&2; return 1; }
    run grep -c '<HOOK-NAME>' "${_spec}"
    [[ "${output}" -eq 0 ]] || { printf 'unfilled <HOOK-NAME> placeholders: %s\n' "${output}" >&2; return 1; }
}

@test "the stamped hook honours the exit-code contract (block 2 / allow 0)" {
    run bash "${SCAFFOLD}" new-hook demo-guard --root "${ROOT}"
    assert_success

    local _script="${ROOT}/.agents/hook/demo-guard.sh"
    local _blocked _allowed _empty
    _blocked="$(jq -n --arg c 'banned-command --now' '{tool_name:"Bash",tool_input:{command:$c}}')"
    _allowed="$(jq -n --arg c 'ls -la' '{tool_name:"Bash",tool_input:{command:$c}}')"
    _empty="$(jq -n --arg c '' '{tool_name:"Bash",tool_input:{command:$c}}')"

    run bash -c 'printf "%s" "$1" | "$2"' _ "${_blocked}" "${_script}"
    assert_failure 2
    assert_output --partial "BLOCKED"

    run bash -c 'printf "%s" "$1" | "$2"' _ "${_allowed}" "${_script}"
    assert_success

    run bash -c 'printf "%s" "$1" | "$2"' _ "${_empty}" "${_script}"
    assert_success
}

@test "the stamped hook spec passes as a stub (nested bats)" {
    run bash "${SCAFFOLD}" new-hook demo-guard --root "${ROOT}"
    assert_success
    # The stamped hook spec references .claude/hook/<name>.sh; mirror the repo's
    # .claude/hook -> .agents/hook symlink so it resolves under the scratch root.
    mkdir -p "${ROOT}/.claude"
    ln -s "${ROOT}/.agents/hook" "${ROOT}/.claude/hook"

    run bats "${ROOT}/test/unit/hook/demo-guard_spec.bats"
    [[ "${status}" -eq 0 ]] || { printf 'nested bats failed:\n%s\n' "${output}" >&2; return 1; }
}

# ── --help ───────────────────────────────────────────────────────────────────

@test "--help prints usage and exits 0" {
    run bash "${SCAFFOLD}" --help
    assert_success
    assert_output --partial "Usage:"
    assert_output --partial "new-tool"
    assert_output --partial "new-hook"
}

# ── Misuse -> exit 2 ─────────────────────────────────────────────────────────

@test "no subcommand exits 2" {
    run bash "${SCAFFOLD}"
    assert_failure 2
}

@test "unknown subcommand exits 2" {
    run bash "${SCAFFOLD}" frobnicate widget
    assert_failure 2
}

@test "missing name exits 2" {
    run bash "${SCAFFOLD}" new-tool --root "${ROOT}"
    assert_failure 2
}

@test "invalid name exits 2 and stamps nothing" {
    run bash "${SCAFFOLD}" new-tool 'Bad Name' --root "${ROOT}"
    assert_failure 2
    [[ ! -e "${ROOT}/tool" ]] || { printf 'tool dir created on invalid name\n' >&2; return 1; }
}

@test "refuses to overwrite an existing target (exit 2)" {
    run bash "${SCAFFOLD}" new-tool demo-widget --root "${ROOT}"
    assert_success
    run bash "${SCAFFOLD}" new-tool demo-widget --root "${ROOT}"
    assert_failure 2
    assert_output --partial "already exists"
}
