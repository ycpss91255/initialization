#!/usr/bin/env bats
# test/unit/module_fetch_hardening_spec.bats — security hardening of the
# github-release fetch/extract path in lib/module_helper.sh (security-review
# SR-01 / SR-02 / SR-03).
#
#   SR-01  the offline test seams (INIT_UBUNTU_TEST_GH_FIXTURE_DIR /
#          INIT_UBUNTU_TEST_GH_VERSION) activate ONLY under the dedicated
#          INIT_UBUNTU_TEST_MODE=1 flag — env alone can no longer swap payloads.
#   SR-02  root archive extraction rejects '..'/absolute members and passes
#          --no-same-owner.
#   SR-03  best-effort SHA-256 verification: mismatch aborts, missing warns.
#
# Env-dependent cases use the `VAR=val run ...` prefix form (not in-body
# `export`) so bats subshell state does not trip shellcheck SC2030/SC2031;
# mock / source-time-guard cases run inside `bash -c` strings shellcheck does
# not descend into. The file therefore needs no `# shellcheck disable`.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
    # shellcheck source=../../lib/logger.sh
    source "${LIB_DIR}/logger.sh"
    # shellcheck source=../../lib/general.sh
    source "${LIB_DIR}/general.sh"
    # shellcheck source=../../lib/module_helper.sh
    source "${LIB_DIR}/module_helper.sh"
}

teardown() { teardown_test_env; }

# ── SR-01: test-mode gate ────────────────────────────────────────────────────

@test "SR-01 _module_test_mode_active false unless INIT_UBUNTU_TEST_MODE=1" {
    run _module_test_mode_active
    assert_failure
    INIT_UBUNTU_TEST_MODE=0 run _module_test_mode_active
    assert_failure
    INIT_UBUNTU_TEST_MODE=1 run _module_test_mode_active
    assert_success
}

@test "SR-01 version seam is IGNORED without test mode" {
    # A sentinel real resolver survives the module_helper source when the flag
    # is absent — the seam did not shadow it.
    run bash -c "unset TTY_COLORS_READY
        source '${LIB_DIR}/logger.sh'; source '${LIB_DIR}/general.sh'
        get_github_pkg_latest_version(){ local -n _o=\"\$1\"; _o=REAL; }
        export INIT_UBUNTU_TEST_GH_VERSION=9.9.9
        unset INIT_UBUNTU_TEST_MODE
        source '${LIB_DIR}/module_helper.sh'
        _v=; get_github_pkg_latest_version _v repo; printf '%s' \"\${_v}\""
    assert_output "REAL"
}

@test "SR-01 version seam ACTIVATES with test mode" {
    run bash -c "unset TTY_COLORS_READY
        source '${LIB_DIR}/logger.sh'; source '${LIB_DIR}/general.sh'
        get_github_pkg_latest_version(){ local -n _o=\"\$1\"; _o=REAL; }
        export INIT_UBUNTU_TEST_GH_VERSION=9.9.9 INIT_UBUNTU_TEST_MODE=1
        source '${LIB_DIR}/module_helper.sh'
        _v=; get_github_pkg_latest_version _v repo; printf '%s' \"\${_v}\""
    assert_output "9.9.9"
}

@test "SR-01 fixture is_installed suppression INACTIVE without test mode" {
    # BIN_NAME=sh resolves on PATH; BIN_LINK is absent; fixture dir set but no
    # test-mode flag => the PATH fallback still fires (seam not honored).
    BIN_NAME=sh \
    BIN_LINK="${INIT_UBUNTU_TEST_SCRATCH}/nolink" \
    INIT_UBUNTU_TEST_GH_FIXTURE_DIR="${INIT_UBUNTU_TEST_SCRATCH}/fx" \
        run module_default_github_release_is_installed
    assert_success
}

@test "SR-01 fixture is_installed suppression ACTIVE with test mode" {
    BIN_NAME=sh \
    BIN_LINK="${INIT_UBUNTU_TEST_SCRATCH}/nolink" \
    INIT_UBUNTU_TEST_GH_FIXTURE_DIR="${INIT_UBUNTU_TEST_SCRATCH}/fx" \
    INIT_UBUNTU_TEST_MODE=1 \
        run module_default_github_release_is_installed
    assert_failure
}

# ── SR-02: traversal guard + --no-same-owner ─────────────────────────────────

@test "SR-02 guard accepts safe member paths" {
    printf '%s\n' 'bin/tool' './x' 'a/b/c' 'file.txt' | module_archive_members_safe
}

@test "SR-02 guard rejects a '..' member" {
    if printf '%s\n' 'a/../../etc/passwd' | module_archive_members_safe; then
        false
    fi
}

@test "SR-02 guard rejects a leading '..' member" {
    if printf '%s\n' '../evil' | module_archive_members_safe; then
        false
    fi
}

@test "SR-02 guard rejects an absolute member" {
    if printf '%s\n' '/etc/profile.d/x.sh' | module_archive_members_safe; then
        false
    fi
}

@test "SR-02 guard rejects a bare '..' member" {
    if printf '%s\n' '..' | module_archive_members_safe; then
        false
    fi
}

@test "SR-02 safe tar extract refuses a traversal tarball" {
    # Mock the listing pass to emit a '..' member; the guard must abort before
    # the real extract runs.
    run bash -c "unset TTY_COLORS_READY
        source '${LIB_DIR}/logger.sh'; source '${LIB_DIR}/general.sh'; source '${LIB_DIR}/module_helper.sh'
        tar(){ if [ \"\$1\" = -tzf ]; then printf '../evil\n'; return 0; fi; command tar \"\$@\"; }
        _module_safe_tar_extract /does-not-exist.tgz '${INIT_UBUNTU_TEST_SCRATCH}/out' 1 ''"
    assert_failure
    assert_output --partial "refusing archive"
}

@test "SR-02 safe tar extract unpacks a benign tarball" {
    local _d="${INIT_UBUNTU_TEST_SCRATCH}"
    mkdir -p "${_d}/src" "${_d}/out"
    printf 'hi' > "${_d}/src/file.txt"
    ( cd "${_d}/src" && tar -czf "${_d}/pkg.tar.gz" . )
    run _module_safe_tar_extract "${_d}/pkg.tar.gz" "${_d}/out" 0 ""
    assert_success
    [[ -f "${_d}/out/file.txt" ]]
}

@test "SR-02 archetype + per-module extraction pass --no-same-owner" {
    grep -q -- '--no-same-owner' "${LIB_DIR}/module_helper.sh"
}

# ── SR-03: best-effort SHA-256 integrity ─────────────────────────────────────

@test "SR-03 module_verify_sha256 accepts a matching digest" {
    local _f="${INIT_UBUNTU_TEST_SCRATCH}/a"
    printf 'payload' > "${_f}"
    local _h
    _h="$(sha256sum "${_f}" | awk '{print $1}')"
    module_verify_sha256 "${_f}" "${_h}"
}

@test "SR-03 module_verify_sha256 rejects a wrong digest" {
    local _f="${INIT_UBUNTU_TEST_SCRATCH}/a"
    printf 'payload' > "${_f}"
    run module_verify_sha256 "${_f}" "0000000000000000000000000000000000000000000000000000000000000000"
    assert_failure
}

@test "SR-03 module_verify_sha256 rejects a missing file" {
    run module_verify_sha256 "${INIT_UBUNTU_TEST_SCRATCH}/absent" "deadbeef"
    assert_failure
}

@test "SR-03 checksum lookup returns the right digest by asset name" {
    local _s="${INIT_UBUNTU_TEST_SCRATCH}/sums"
    printf '%s  %s\n' aaaaaaaa asset.tar.gz  > "${_s}"
    printf '%s *%s\n'  bbbbbbbb other.zip     >> "${_s}"
    [[ "$(_module_checksum_lookup "${_s}" asset.tar.gz)" == "aaaaaaaa" ]]
    [[ "$(_module_checksum_lookup "${_s}" other.zip)"    == "bbbbbbbb" ]]
    [[ -z "$(_module_checksum_lookup "${_s}" missing.tgz)" ]]
}

@test "SR-03 verify warns+proceeds when no checksum asset declared" {
    local _art="${INIT_UBUNTU_TEST_SCRATCH}/art.tar.gz"
    printf 'X' > "${_art}"
    run _module_github_release_verify_checksum "${_art}" "asset.tar.gz"
    assert_success
    assert_output --partial "skipping integrity check"
}

@test "SR-03 verify passes on a matching published digest (fixture mode)" {
    local _fx="${INIT_UBUNTU_TEST_SCRATCH}/fx"
    local _art="${INIT_UBUNTU_TEST_SCRATCH}/art.tar.gz"
    mkdir -p "${_fx}"
    printf 'PAYLOAD' > "${_art}"
    local _h
    _h="$(sha256sum "${_art}" | awk '{print $1}')"
    printf '%s  %s\n' "${_h}" 'asset.tar.gz' > "${_fx}/checksums.txt"
    INIT_UBUNTU_TEST_MODE=1 \
    INIT_UBUNTU_TEST_GH_FIXTURE_DIR="${_fx}" \
    GITHUB_CHECKSUM_ASSET=checksums.txt \
        run _module_github_release_verify_checksum "${_art}" "asset.tar.gz"
    assert_success
    assert_output --partial "sha256 verified"
}

@test "SR-03 verify REJECTS a mismatched published digest (fixture mode)" {
    local _fx="${INIT_UBUNTU_TEST_SCRATCH}/fx"
    local _art="${INIT_UBUNTU_TEST_SCRATCH}/art.tar.gz"
    mkdir -p "${_fx}"
    printf 'PAYLOAD' > "${_art}"
    printf '%s  %s\n' \
        "0000000000000000000000000000000000000000000000000000000000000000" \
        'asset.tar.gz' > "${_fx}/checksums.txt"
    INIT_UBUNTU_TEST_MODE=1 \
    INIT_UBUNTU_TEST_GH_FIXTURE_DIR="${_fx}" \
    GITHUB_CHECKSUM_ASSET=checksums.txt \
        run _module_github_release_verify_checksum "${_art}" "asset.tar.gz"
    assert_failure
    assert_output --partial "MISMATCH"
}

@test "SR-03 verify warns+proceeds when the checksum asset is absent" {
    local _fx="${INIT_UBUNTU_TEST_SCRATCH}/fx"
    local _art="${INIT_UBUNTU_TEST_SCRATCH}/art.tar.gz"
    mkdir -p "${_fx}"
    printf 'PAYLOAD' > "${_art}"
    INIT_UBUNTU_TEST_MODE=1 \
    INIT_UBUNTU_TEST_GH_FIXTURE_DIR="${_fx}" \
    GITHUB_CHECKSUM_ASSET=absent.txt \
        run _module_github_release_verify_checksum "${_art}" "asset.tar.gz"
    assert_success
    assert_output --partial "proceeding without integrity check"
}
