#!/usr/bin/env bats
# test/unit/tool/resolve_publish_spec.bats
#
# Tests for `tool/davinci_resolve/resolve-publish.sh` (issue #269): the
# standalone re-encoder that transcodes DaVinci Resolve exports (AV1 / DNxHR)
# to H.264 / H.265 for sharing.
#
# Strategy: ffmpeg is not present in the test-tools image and real encoding
# is out of scope, so a fake `ffmpeg` is placed on PATH. It answers
# `-encoders` queries and, in encode mode, materialises the output file. Its
# behaviour is steered per test via env vars:
#   FAKE_FFMPEG_NO_ENCODER   omit libx264/libx265 from the -encoders listing
#   FAKE_FFMPEG_EMPTY        exit 0 but write a zero-byte output
#   FAKE_FFMPEG_FAIL_ON=<s>  exit 1 (partial output) when input path contains <s>
# The pure validation paths (usage / codec / CRF / -o) exit before ffmpeg is
# consulted, so they are asserted without the stub.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env

    # bats' `VAR=val run` prefix leaves VAR set in the file's shell after the
    # call (bash keeps assignments preceding a function). Clear the fake's
    # control vars so no test inherits a previous test's steering.
    unset FAKE_FFMPEG_NO_ENCODER FAKE_FFMPEG_EMPTY FAKE_FFMPEG_FAIL_ON

    SCRIPT="${REPO_ROOT}/tool/davinci_resolve/resolve-publish.sh"
    WORK="${BATS_TEST_TMPDIR}/work"
    FAKEBIN="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${WORK}" "${FAKEBIN}"

    INPUT="${WORK}/export.mp4"
    printf 'source-av1-bytes' >"${INPUT}"

    _install_fake_ffmpeg
}

teardown() {
    teardown_test_env
}

# Write a fake ffmpeg onto PATH. PATH is left prepended for the whole test;
# individual tests that need the real (absent) ffmpeg override PATH themselves.
_install_fake_ffmpeg() {
    cat >"${FAKEBIN}/ffmpeg" <<'EOF'
#!/usr/bin/env bash
args=("$@")
for a in "$@"; do
    if [[ "${a}" == "-encoders" ]]; then
        echo "Encoders:"
        if [[ -z "${FAKE_FFMPEG_NO_ENCODER:-}" ]]; then
            echo " V....D libx264 H.264 / AVC"
            echo " V....D libx265 H.265 / HEVC"
        fi
        echo " A....D aac AAC (Advanced Audio Coding)"
        exit 0
    fi
done
out="${args[${#args[@]}-1]}"
input=""
for ((i = 0; i < ${#args[@]}; i++)); do
    [[ "${args[i]}" == "-i" ]] && input="${args[i + 1]}"
done
if [[ -n "${FAKE_FFMPEG_FAIL_ON:-}" && "${input}" == *"${FAKE_FFMPEG_FAIL_ON}"* ]]; then
    printf 'partial' >"${out}"
    exit 1
fi
if [[ -n "${FAKE_FFMPEG_EMPTY:-}" ]]; then
    : >"${out}"
    exit 0
fi
printf 'FAKE-ENCODED-VIDEO' >"${out}"
exit 0
EOF
    chmod +x "${FAKEBIN}/ffmpeg"
    PATH="${FAKEBIN}:${PATH}"
}

# ── Usage / argument contract ────────────────────────────────────────────────

@test "no arguments prints usage and exits 1" {
    run "${SCRIPT}"
    assert_failure 1
    assert_output --partial "Usage:"
}

@test "-h prints usage and exits 0" {
    run "${SCRIPT}" -h
    assert_success
    assert_output --partial "Usage:"
}

# ── Validation errors (exit before ffmpeg) ───────────────────────────────────

@test "invalid codec reports 'codec must be h264 or h265' and exits 1" {
    run "${SCRIPT}" -c vp9 "${INPUT}"
    assert_failure 1
    assert_output --partial "codec must be h264 or h265"
}

@test "non-numeric CRF reports 'CRF must be a number' and exits 1" {
    run "${SCRIPT}" -q high "${INPUT}"
    assert_failure 1
    assert_output --partial "CRF must be a number"
}

@test "-o pointing at an existing file is rejected and exits 1" {
    local file="${WORK}/not-a-dir"
    printf 'x' >"${file}"
    run "${SCRIPT}" -o "${file}" "${INPUT}"
    assert_failure 1
    assert_output --partial "already exists and is not a directory"
}

# ── ffmpeg availability ──────────────────────────────────────────────────────

@test "missing ffmpeg reports a clear error with install hint" {
    if command -v ffmpeg >/dev/null 2>&1 && [[ "$(command -v ffmpeg)" != "${FAKEBIN}/ffmpeg" ]]; then
        skip "a real ffmpeg is on PATH in this environment"
    fi
    PATH="/usr/bin:/bin" run "${SCRIPT}" "${INPUT}"
    assert_failure 1
    assert_output --partial "ffmpeg not found"
}

@test "ffmpeg without libx264 reports the missing encoder and exits 1" {
    FAKE_FFMPEG_NO_ENCODER=1 run "${SCRIPT}" -c h264 "${INPUT}"
    assert_failure 1
    assert_output --partial "missing the libx264 encoder"
}

@test "ffmpeg without libx265 reports the missing encoder and exits 1" {
    FAKE_FFMPEG_NO_ENCODER=1 run "${SCRIPT}" -c h265 "${INPUT}"
    assert_failure 1
    assert_output --partial "missing the libx265 encoder"
}

# ── Successful transcode ─────────────────────────────────────────────────────

@test "default codec writes <stem>_h264.mp4 alongside the input" {
    run "${SCRIPT}" "${INPUT}"
    assert_success
    assert [ -s "${WORK}/export_h264.mp4" ]
}

@test "-c h265 writes <stem>_h265.mp4 alongside the input" {
    run "${SCRIPT}" -c h265 "${INPUT}"
    assert_success
    assert [ -s "${WORK}/export_h265.mp4" ]
    assert [ ! -e "${WORK}/export_h264.mp4" ]
}

@test "-o writes the output into the target directory" {
    local outdir="${WORK}/final"
    run "${SCRIPT}" -o "${outdir}" "${INPUT}"
    assert_success
    assert [ -s "${outdir}/export_h264.mp4" ]
}

# ── Failure / cleanup contract ───────────────────────────────────────────────

@test "zero-byte output is detected, removed, and exits 1" {
    FAKE_FFMPEG_EMPTY=1 run "${SCRIPT}" "${INPUT}"
    assert_failure 1
    assert_output --partial "empty file"
    assert [ ! -e "${WORK}/export_h264.mp4" ]
}

@test "ffmpeg failure removes the partial output and exits 1" {
    FAKE_FFMPEG_FAIL_ON="export" run "${SCRIPT}" "${INPUT}"
    assert_failure 1
    assert_output --partial "ffmpeg failed"
    assert [ ! -e "${WORK}/export_h264.mp4" ]
}

@test "missing input file fails that input and exits 1" {
    run "${SCRIPT}" "${WORK}/does-not-exist.mp4"
    assert_failure 1
    assert_output --partial "not found or not a regular file"
}

# ── Multiple inputs: one fails, the rest still process ───────────────────────

@test "with several inputs a single failure still processes the others" {
    local good1="${WORK}/good1.mp4"
    local bad="${WORK}/bad.mp4"
    local good2="${WORK}/good2.mp4"
    printf 'a' >"${good1}"
    printf 'b' >"${bad}"
    printf 'c' >"${good2}"

    FAKE_FFMPEG_FAIL_ON="bad" run "${SCRIPT}" "${good1}" "${bad}" "${good2}"
    assert_failure 1
    assert [ -s "${WORK}/good1_h264.mp4" ]
    assert [ -s "${WORK}/good2_h264.mp4" ]
    assert [ ! -e "${WORK}/bad_h264.mp4" ]
}
