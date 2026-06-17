#!/usr/bin/env bats
# test/unit/script/resolve_test_tools_tag_spec.bats
#
# Tests for `script/ci/resolve_test_tools_tag.sh` (issue #113): the
# content-keyed test-tools image tag resolver. Parallel worktrees used to
# clobber the single shared `test-tools:local` tag; the tag is now
# test-tools:<first 12 hex of sha256(Dockerfile.test-tools)> so different
# Dockerfile contents map to different tags.
#
# Strategy: point the resolver at fixture Dockerfiles under
# $BATS_TEST_TMPDIR (optional $1 path override) and assert on the printed
# tag — no docker needed.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env

    SCRIPT="${REPO_ROOT}/script/ci/resolve_test_tools_tag.sh"
    FIXTURE_DOCKERFILE="${BATS_TEST_TMPDIR}/Dockerfile.test-tools"
    printf 'FROM alpine:3.20\nRUN apk add --no-cache bats\n' \
        > "${FIXTURE_DOCKERFILE}"
}

teardown() {
    teardown_test_env
}

# ── Tag shape ────────────────────────────────────────────────────────────────

@test "prints test-tools:<12 hex> for the real repo Dockerfile" {
    TEST_TOOLS_IMAGE='' run "${SCRIPT}"
    assert_success
    assert_output --regexp '^test-tools:[0-9a-f]{12}$'
}

@test "tag is the first 12 hex chars of sha256(Dockerfile.test-tools)" {
    local _expected
    _expected="test-tools:$(sha256sum "${FIXTURE_DOCKERFILE}" | cut -c1-12)"
    TEST_TOOLS_IMAGE='' run "${SCRIPT}" "${FIXTURE_DOCKERFILE}"
    assert_success
    assert_output "${_expected}"
}

# ── Content addressing (AC #113) ─────────────────────────────────────────────

@test "identical Dockerfile contents resolve to the same tag" {
    local _copy="${BATS_TEST_TMPDIR}/Dockerfile.copy"
    cp "${FIXTURE_DOCKERFILE}" "${_copy}"

    TEST_TOOLS_IMAGE='' run "${SCRIPT}" "${FIXTURE_DOCKERFILE}"
    assert_success
    local _tag_a="${output}"

    TEST_TOOLS_IMAGE='' run "${SCRIPT}" "${_copy}"
    assert_success
    assert_output "${_tag_a}"
}

@test "different Dockerfile contents resolve to different tags" {
    # The AC scenario: two worktrees, one on an older branch whose
    # Dockerfile lacks a dependency (e.g. pre-curl) — their tags must
    # differ so concurrent builds stop clobbering each other.
    local _older="${BATS_TEST_TMPDIR}/Dockerfile.older"
    printf 'FROM alpine:3.20\n' > "${_older}"

    TEST_TOOLS_IMAGE='' run "${SCRIPT}" "${FIXTURE_DOCKERFILE}"
    assert_success
    local _tag_new="${output}"

    TEST_TOOLS_IMAGE='' run "${SCRIPT}" "${_older}"
    assert_success
    refute_output "${_tag_new}"
    assert_output --regexp '^test-tools:[0-9a-f]{12}$'
}

# ── Override + error contract ────────────────────────────────────────────────

@test "explicit \$TEST_TOOLS_IMAGE override is echoed verbatim" {
    TEST_TOOLS_IMAGE="ghcr.io/example/test-tools:pinned" run "${SCRIPT}"
    assert_success
    assert_output "ghcr.io/example/test-tools:pinned"
}

@test "empty \$TEST_TOOLS_IMAGE falls through to content-keyed resolution" {
    TEST_TOOLS_IMAGE="" run "${SCRIPT}" "${FIXTURE_DOCKERFILE}"
    assert_success
    assert_output --regexp '^test-tools:[0-9a-f]{12}$'
}

@test "missing Dockerfile fails with a clear error" {
    TEST_TOOLS_IMAGE='' run "${SCRIPT}" "${BATS_TEST_TMPDIR}/does-not-exist"
    assert_failure
    assert_output --partial "Dockerfile not found"
    assert_output --partial "does-not-exist"
}

# ── Sourceable helper (consumed in-process where useful) ─────────────────────

@test "is sourceable: resolve_test_tools_tag function resolves the fixture" {
    local _expected
    _expected="test-tools:$(sha256sum "${FIXTURE_DOCKERFILE}" | cut -c1-12)"
    TEST_TOOLS_IMAGE='' run bash -c \
        "source '${SCRIPT}' && resolve_test_tools_tag '${FIXTURE_DOCKERFILE}'"
    assert_success
    assert_output "${_expected}"
}

@test "sourcing does not auto-print or exit the caller" {
    TEST_TOOLS_IMAGE='' run bash -c \
        "source '${SCRIPT}'; echo caller-still-alive"
    assert_success
    assert_output "caller-still-alive"
}
