#!/usr/bin/env bash
# resolve_test_tools_tag.sh — print the content-keyed test-tools image tag
#
# Issue #113: parallel agent worktrees on the same host all built and shared
# the single `test-tools:local` tag. A worktree on an older branch (e.g. a
# pre-curl Dockerfile) rebuilding the tag clobbered it for everyone else,
# producing alternating red/green e2e runs that looked like flakes. The tag
# is now content-addressed:
#
#   test-tools:<first 12 hex chars of sha256(dockerfile/Dockerfile.test-tools)>
#
# Different Dockerfile contents map to different tags (no clobbering);
# identical contents share one tag (and the docker build cache).
#
# Resolution contract (consumed by justfile.ci, ci.sh → compose.yaml):
#   1. $TEST_TOOLS_IMAGE set and non-empty → echoed verbatim (explicit
#      override; CI prebuilt path or manual pinning)
#   2. otherwise → content-keyed tag of dockerfile/Dockerfile.test-tools
#      ($1 overrides the Dockerfile path — used by the bats spec)
#   3. Dockerfile missing → exit 1 with a clear error on stderr
#
# `test-tools:local` is kept as an ALIAS tag by `just -f justfile.ci build-test-tools`
# (muscle memory; plain `docker compose run` without just still
# works — it just points at whatever this worktree built last).
#
# Spec: test/unit/script/resolve_test_tools_tag_spec.bats

# Exit-code-contract script (prints a value; exit 0/1) — per ADR-0007
# default to `set -uo pipefail` when executed directly; respect the
# caller's options when sourced (bats spec sources the function).
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    set -uo pipefail
fi

_resolve_tag_err() { printf '[resolve-test-tools-tag] ERROR: %s\n' "$*" >&2; }

# resolve_test_tools_tag [dockerfile_path]
# Prints the resolved image reference on stdout; returns 1 on failure.
resolve_test_tools_tag() {
    if [[ -n "${TEST_TOOLS_IMAGE:-}" ]]; then
        printf '%s\n' "${TEST_TOOLS_IMAGE}"
        return 0
    fi

    local _script_dir _dockerfile _hash
    _script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
    _dockerfile="${1:-${_script_dir}/../../dockerfile/Dockerfile.test-tools}"

    if [[ ! -f "${_dockerfile}" ]]; then
        _resolve_tag_err "Dockerfile not found: ${_dockerfile} — cannot derive the content-keyed test-tools tag (issue #113)"
        return 1
    fi
    if ! command -v sha256sum >/dev/null 2>&1; then
        _resolve_tag_err "sha256sum not found in PATH — required to derive the content-keyed test-tools tag"
        return 1
    fi

    _hash="$(sha256sum "${_dockerfile}" | awk '{print $1}')"
    if [[ ! "${_hash}" =~ ^[0-9a-f]{64}$ ]]; then
        _resolve_tag_err "sha256sum produced unexpected output for ${_dockerfile}"
        return 1
    fi

    printf 'test-tools:%s\n' "${_hash:0:12}"
}

# Guard: only act when executed directly, not when sourced
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    resolve_test_tools_tag "$@"
fi
