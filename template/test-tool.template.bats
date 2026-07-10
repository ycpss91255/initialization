#!/usr/bin/env bats
# test/unit/tool/<TOOL-NAME>_spec.bats — bats spec for tool/<TOOL-NAME>.sh
#
# Quick start:
#   1. cp template/test-tool.template.bats test/unit/tool/<your-name>_spec.bats
#   2. Replace every <TOOL-NAME> below with your tool name (no quotes).
#   3. Point TOOL_TARGET at the file your do_work() mutates, or drop the
#      indirection if your tool needs no scratch target.
#   4. Search for <TODO> markers and fill them in.
#   5. Run: just -f justfile.ci test-unit
#
# What this template covers (the tool-template outward contract — see
# lib/tool_bootstrap.sh, doc/adr/0029-small-tool-template.md):
#   - --help / -h  prints usage, exits 0
#   - unknown arg  prints usage to stderr, exits 2 (and mutates nothing)
#   - --dry-run    performs NO filesystem mutation
#   - a real run   performs the work; a re-run is idempotent
#
# All tests run inside Docker (ADR-0004). The tool honors LIB_DIR / REPO_ROOT
# so it can locate the real lib bootstrap from a scratch fixture location.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
    export LIB_DIR REPO_ROOT

    TOOL_SH="${REPO_ROOT}/tool/<TOOL-NAME>.sh"

    # <TODO>: point at the file your tool mutates so mutation is observable.
    # If your tool reads its target from an env override (like the reference
    # template's TOOL_TEMPLATE_TARGET), set it here.
    TOOL_TARGET="${INIT_UBUNTU_TEST_SCRATCH}/<TOOL-NAME>.target"
    export TOOL_TEMPLATE_TARGET="${TOOL_TARGET}"
}

teardown() {
    teardown_test_env
}

# ── 1. --help exits 0 and prints usage ───────────────────────────────────────

@test "<TOOL-NAME>: --help prints usage and exits 0" {
    run bash "${TOOL_SH}" --help
    assert_success
    assert_output --partial "Usage:"
}

@test "<TOOL-NAME>: -h is an alias for --help (exit 0)" {
    run bash "${TOOL_SH}" -h
    assert_success
    assert_output --partial "Usage:"
}

# ── 2. unknown arg exits 2 and mutates nothing ───────────────────────────────

@test "<TOOL-NAME>: unknown argument prints usage to stderr and exits 2" {
    run bash "${TOOL_SH}" --bogus
    assert_failure 2
    assert_output --partial "Usage:"
}

@test "<TOOL-NAME>: unknown arg does not mutate the target" {
    run bash "${TOOL_SH}" --bogus
    assert_failure 2
    [[ ! -e "${TOOL_TARGET}" ]] || { printf 'target created on usage error: %s\n' "${TOOL_TARGET}" >&2; return 1; }
}

# ── 3. --dry-run performs no mutation ────────────────────────────────────────

@test "<TOOL-NAME>: --dry-run reports intent and mutates nothing" {
    run bash "${TOOL_SH}" --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
    [[ ! -e "${TOOL_TARGET}" ]] || { printf '--dry-run mutated target: %s\n' "${TOOL_TARGET}" >&2; return 1; }
}

# ── Real run + idempotency ───────────────────────────────────────────────────

@test "<TOOL-NAME>: no-args run performs the work (exit 0)" {
    run bash "${TOOL_SH}"
    assert_success
    # <TODO>: assert your tool's observable effect, e.g.:
    # [[ -f "${TOOL_TARGET}" ]]
}

@test "<TOOL-NAME>: re-run is idempotent (no duplicate effect)" {
    run bash "${TOOL_SH}"
    assert_success
    run bash "${TOOL_SH}"
    assert_success
    # <TODO>: assert the effect did not accumulate on the second run.
}

# ── TODO: tool-specific behavior ─────────────────────────────────────────────
# Add tests for each meaningful branch of do_work() (each environment your tool
# reacts to; each grep-guard that short-circuits when the desired state is
# already present).
