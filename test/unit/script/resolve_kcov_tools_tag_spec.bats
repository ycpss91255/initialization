#!/usr/bin/env bats
# test/unit/script/resolve_kcov_tools_tag_spec.bats
#
# Tests for `script/ci/resolve_kcov_tools_tag.sh` (issue #226): the
# content-keyed kcov-tools image tag resolver. Same content-addressing
# scheme as the test-tools resolver (issue #113) — the tag is
# kcov-tools:<first 12 hex of sha256(Dockerfile.kcov-tools)> so different
# Dockerfile contents map to different tags (no clobbering across parallel
# worktrees).
#
# Strategy: point the resolver at fixture Dockerfiles under
# $BATS_TEST_TMPDIR (optional $1 path override) and assert on the printed
# tag — no docker needed.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env

    SCRIPT="${REPO_ROOT}/script/ci/resolve_kcov_tools_tag.sh"
    FIXTURE_DOCKERFILE="${BATS_TEST_TMPDIR}/Dockerfile.kcov-tools"
    printf 'FROM kcov/kcov\nRUN apt-get install -y bats\n' \
        > "${FIXTURE_DOCKERFILE}"
}

teardown() {
    teardown_test_env
}

# ── Tag shape ────────────────────────────────────────────────────────────────

@test "prints kcov-tools:<12 hex> for the real repo Dockerfile" {
    KCOV_TOOLS_IMAGE='' run "${SCRIPT}"
    assert_success
    assert_output --regexp '^kcov-tools:[0-9a-f]{12}$'
}

@test "tag is the first 12 hex chars of sha256(Dockerfile.kcov-tools)" {
    local _expected
    _expected="kcov-tools:$(sha256sum "${FIXTURE_DOCKERFILE}" | cut -c1-12)"
    KCOV_TOOLS_IMAGE='' run "${SCRIPT}" "${FIXTURE_DOCKERFILE}"
    assert_success
    assert_output "${_expected}"
}

# ── Content addressing (issue #226) ──────────────────────────────────────────

@test "identical Dockerfile contents resolve to the same tag" {
    local _copy="${BATS_TEST_TMPDIR}/Dockerfile.copy"
    cp "${FIXTURE_DOCKERFILE}" "${_copy}"

    KCOV_TOOLS_IMAGE='' run "${SCRIPT}" "${FIXTURE_DOCKERFILE}"
    assert_success
    local _tag_a="${output}"

    KCOV_TOOLS_IMAGE='' run "${SCRIPT}" "${_copy}"
    assert_success
    assert_output "${_tag_a}"
}

@test "different Dockerfile contents resolve to different tags" {
    local _other="${BATS_TEST_TMPDIR}/Dockerfile.other"
    printf 'FROM kcov/kcov\n' > "${_other}"

    KCOV_TOOLS_IMAGE='' run "${SCRIPT}" "${FIXTURE_DOCKERFILE}"
    assert_success
    local _tag_new="${output}"

    KCOV_TOOLS_IMAGE='' run "${SCRIPT}" "${_other}"
    assert_success
    refute_output "${_tag_new}"
    assert_output --regexp '^kcov-tools:[0-9a-f]{12}$'
}

# ── Override + error contract ────────────────────────────────────────────────

@test "explicit \$KCOV_TOOLS_IMAGE override is echoed verbatim" {
    KCOV_TOOLS_IMAGE="ghcr.io/example/kcov-tools:pinned" run "${SCRIPT}"
    assert_success
    assert_output "ghcr.io/example/kcov-tools:pinned"
}

@test "empty \$KCOV_TOOLS_IMAGE falls through to content-keyed resolution" {
    KCOV_TOOLS_IMAGE="" run "${SCRIPT}" "${FIXTURE_DOCKERFILE}"
    assert_success
    assert_output --regexp '^kcov-tools:[0-9a-f]{12}$'
}

@test "missing Dockerfile fails with a clear error" {
    KCOV_TOOLS_IMAGE='' run "${SCRIPT}" "${BATS_TEST_TMPDIR}/does-not-exist"
    assert_failure
    assert_output --partial "Dockerfile not found"
    assert_output --partial "does-not-exist"
}

# ── Sourceable helper (consumed in-process where useful) ─────────────────────

@test "is sourceable: resolve_kcov_tools_tag function resolves the fixture" {
    local _expected
    _expected="kcov-tools:$(sha256sum "${FIXTURE_DOCKERFILE}" | cut -c1-12)"
    KCOV_TOOLS_IMAGE='' run bash -c \
        "source '${SCRIPT}' && resolve_kcov_tools_tag '${FIXTURE_DOCKERFILE}'"
    assert_success
    assert_output "${_expected}"
}

@test "sourcing does not auto-print or exit the caller" {
    KCOV_TOOLS_IMAGE='' run bash -c \
        "source '${SCRIPT}'; echo caller-still-alive"
    assert_success
    assert_output "caller-still-alive"
}
