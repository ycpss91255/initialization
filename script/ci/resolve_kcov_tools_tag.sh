#!/usr/bin/env bash
# resolve_kcov_tools_tag.sh — print the content-keyed kcov-tools image tag
#
# Issue #226: the coverage path now runs in a baked image
# (dockerfile/Dockerfile.kcov-tools = kcov/kcov + the bats toolchain) so the
# per-shard kcov jobs skip the ~20-30s runtime apt-install. The tag is
# content-addressed (same pattern as resolve_test_tools_tag.sh, issue #113):
#
#   kcov-tools:<first 12 hex chars of sha256(dockerfile/Dockerfile.kcov-tools)>
#
# Different Dockerfile contents map to different tags (no clobbering across
# parallel worktrees); identical contents share one tag (and build cache).
#
# Resolution contract (consumed by justfile.ci, ci.sh → compose.yaml):
#   1. $KCOV_TOOLS_IMAGE set and non-empty → echoed verbatim (explicit
#      override; CI prebuilt path or manual pinning)
#   2. otherwise → content-keyed tag of dockerfile/Dockerfile.kcov-tools
#      ($1 overrides the Dockerfile path — used by the bats spec)
#   3. Dockerfile missing → exit 1 with a clear error on stderr
#
# Spec: test/unit/script/resolve_kcov_tools_tag_spec.bats

# Exit-code-contract script (prints a value; exit 0/1) — per ADR-0007
# default to `set -uo pipefail` when executed directly; respect the
# caller's options when sourced (bats spec sources the function).
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    set -uo pipefail
fi

_resolve_kcov_tag_err() { printf '[resolve-kcov-tools-tag] ERROR: %s\n' "$*" >&2; }

# resolve_kcov_tools_tag [dockerfile_path]
# Prints the resolved image reference on stdout; returns 1 on failure.
resolve_kcov_tools_tag() {
    if [[ -n "${KCOV_TOOLS_IMAGE:-}" ]]; then
        printf '%s\n' "${KCOV_TOOLS_IMAGE}"
        return 0
    fi

    local _script_dir _dockerfile _hash
    _script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
    _dockerfile="${1:-${_script_dir}/../../dockerfile/Dockerfile.kcov-tools}"

    if [[ ! -f "${_dockerfile}" ]]; then
        _resolve_kcov_tag_err "Dockerfile not found: ${_dockerfile} — cannot derive the content-keyed kcov-tools tag (issue #226)"
        return 1
    fi
    if ! command -v sha256sum >/dev/null 2>&1; then
        _resolve_kcov_tag_err "sha256sum not found in PATH — required to derive the content-keyed kcov-tools tag"
        return 1
    fi

    _hash="$(sha256sum "${_dockerfile}" | awk '{print $1}')"
    if [[ ! "${_hash}" =~ ^[0-9a-f]{64}$ ]]; then
        _resolve_kcov_tag_err "sha256sum produced unexpected output for ${_dockerfile}"
        return 1
    fi

    printf 'kcov-tools:%s\n' "${_hash:0:12}"
}

# Guard: only act when executed directly, not when sourced
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    resolve_kcov_tools_tag "$@"
fi
