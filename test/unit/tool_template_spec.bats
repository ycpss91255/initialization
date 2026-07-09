#!/usr/bin/env bats
# test/unit/tool_template_spec.bats — conformance spec for template/tool.template.sh
#
# The tool template is the standard skeleton for ONE-OFF bash tools under
# tool/ (see doc/adr/0029-small-tool-template.md, doc/guide/small-tool-template.md).
# This spec drives a reference instantiation of the template through the
# 3 canonical contract cases plus idempotency, so downstream one-off tools
# inherit a proven shape:
#
#   1. --help          -> prints usage, exits 0
#   2. unknown arg      -> prints usage to stderr, exits 2
#   3. --dry-run        -> performs NO mutation (target file untouched)
#
# All tests run inside Docker (ADR-0004). The template honors LIB_DIR /
# REPO_ROOT so the fixture in /tmp/.../scratch can locate the real lib logger,
# and TOOL_TEMPLATE_TARGET so the reference work writes to a scratch file.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
    export LIB_DIR REPO_ROOT

    FIXTURE_DIR="${INIT_UBUNTU_TEST_SCRATCH}/tool"
    mkdir -p "${FIXTURE_DIR}"

    # Reference instantiation: a copy of the template, as a downstream author
    # would `cp template/tool.template.sh tool/<name>.sh`. Left otherwise
    # untouched so this spec exercises the real template shape.
    TOOL_FIXTURE="${FIXTURE_DIR}/reference-tool.sh"
    cp "${TEMPLATE_DIR}/tool.template.sh" "${TOOL_FIXTURE}"
    chmod +x "${TOOL_FIXTURE}"

    # Redirect the reference work at a scratch target so mutation is observable.
    TOOL_TARGET="${FIXTURE_DIR}/marker.txt"
    export TOOL_TEMPLATE_TARGET="${TOOL_TARGET}"
}

teardown() {
    teardown_test_env
}

# ── 1. --help exits 0 and prints usage ───────────────────────────────────────

@test "tool template: --help prints usage and exits 0" {
    run bash "${TOOL_FIXTURE}" --help
    [[ "${status}" -eq 0 ]] || { printf '--help exit=%s output=%s\n' "${status}" "${output}" >&2; return 1; }
    [[ "${output}" == *"Usage:"* ]] || { printf '--help missing Usage:\n%s\n' "${output}" >&2; return 1; }
}

@test "tool template: -h is an alias for --help (exit 0)" {
    run bash "${TOOL_FIXTURE}" -h
    [[ "${status}" -eq 0 ]] || { printf '-h exit=%s\n' "${status}" >&2; return 1; }
    [[ "${output}" == *"Usage:"* ]] || return 1
}

# ── 2. unknown arg exits 2 ───────────────────────────────────────────────────

@test "tool template: unknown argument prints usage to stderr and exits 2" {
    run bash "${TOOL_FIXTURE}" --bogus
    [[ "${status}" -eq 2 ]] || { printf 'unknown-arg exit=%s (want 2)\n' "${status}" >&2; return 1; }
    [[ "${output}" == *"Usage:"* ]] || { printf 'unknown-arg missing Usage:\n%s\n' "${output}" >&2; return 1; }
}

@test "tool template: unknown arg does not mutate the target" {
    run bash "${TOOL_FIXTURE}" --bogus
    [[ "${status}" -eq 2 ]] || return 1
    [[ ! -e "${TOOL_TARGET}" ]] || { printf 'target created on usage error: %s\n' "${TOOL_TARGET}" >&2; return 1; }
}

# ── 3. --dry-run performs no mutation ────────────────────────────────────────

@test "tool template: --dry-run reports intent and mutates nothing" {
    run bash "${TOOL_FIXTURE}" --dry-run
    [[ "${status}" -eq 0 ]] || { printf '--dry-run exit=%s output=%s\n' "${status}" "${output}" >&2; return 1; }
    [[ "${output}" == *"DRY-RUN"* ]] || { printf '--dry-run missing DRY-RUN marker:\n%s\n' "${output}" >&2; return 1; }
    [[ ! -e "${TOOL_TARGET}" ]] || { printf '--dry-run mutated target: %s\n' "${TOOL_TARGET}" >&2; return 1; }
}

@test "tool template: -n is an alias for --dry-run (no mutation)" {
    run bash "${TOOL_FIXTURE}" -n
    [[ "${status}" -eq 0 ]] || return 1
    [[ ! -e "${TOOL_TARGET}" ]] || return 1
}

# ── Real run + idempotency (the payload the dry-run guards) ───────────────────

@test "tool template: no-args run performs the work (exit 0, target written)" {
    run bash "${TOOL_FIXTURE}"
    [[ "${status}" -eq 0 ]] || { printf 'run exit=%s output=%s\n' "${status}" "${output}" >&2; return 1; }
    [[ -f "${TOOL_TARGET}" ]] || { printf 'run did not create target: %s\n' "${TOOL_TARGET}" >&2; return 1; }
    grep -qxF "managed-by-init-ubuntu" "${TOOL_TARGET}"
}

@test "tool template: re-run is idempotent (single marker line, no growth)" {
    run bash "${TOOL_FIXTURE}"
    [[ "${status}" -eq 0 ]] || return 1
    run bash "${TOOL_FIXTURE}"
    [[ "${status}" -eq 0 ]] || return 1
    local _count
    _count="$(grep -cxF "managed-by-init-ubuntu" "${TOOL_TARGET}")"
    [[ "${_count}" -eq 1 ]] || { printf 're-run not idempotent: %s marker lines\n' "${_count}" >&2; return 1; }
}

# ── Contract guardrails baked into the template file ─────────────────────────

@test "tool template: declares set -euo pipefail (ADR-0007 always-act)" {
    grep -qE '^set -euo pipefail$' "${TEMPLATE_DIR}/tool.template.sh"
}

@test "tool template: contains a grep-guarded idempotency check" {
    grep -q 'grep -qxF' "${TEMPLATE_DIR}/tool.template.sh"
}
