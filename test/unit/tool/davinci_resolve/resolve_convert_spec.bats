#!/usr/bin/env bats
# test/unit/tool/davinci_resolve/resolve_convert_spec.bats
#
# Tests for `tool/davinci_resolve/resolve-convert.sh` (issue #267): a
# standalone converter that transcodes H.264/AAC clips to DNxHR HQ + PCM
# so DaVinci Resolve Free on Linux (which ships no H.264/H.265/AAC decode
# licenses) can import them.
#
# Strategy: the script invokes ffmpeg via the FFMPEG_BIN seam
# (FFMPEG_BIN="${FFMPEG_BIN:-ffmpeg}"). Tests point FFMPEG_BIN at a fake
# ffmpeg stub so no real transcode (or real ffmpeg install) is needed:
#   - a "success" stub writes non-empty bytes to the output (last arg)
#   - a "fail" stub writes a partial file then exits 1
#   - an "empty" stub creates a zero-byte output then exits 0
#   - a "selective" stub fails only for inputs whose name contains "bad"
# The not-installed path points FFMPEG_BIN at a nonexistent binary.

load "${BATS_TEST_DIRNAME}/../../../helper/common"

setup() {
    setup_test_env
    SCRIPT="${REPO_ROOT}/tool/davinci_resolve/resolve-convert.sh"
    WORK="${BATS_TEST_TMPDIR}/work"
    BIN="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${WORK}" "${BIN}"
}

teardown() {
    teardown_test_env
}

# Write a fake ffmpeg that writes non-empty content to the last arg (output).
_stub_ffmpeg_ok() {
    cat > "${BIN}/ffmpeg" <<'EOF'
#!/usr/bin/env bash
out="${*: -1}"
printf 'FAKE-DNXHR-DATA' > "${out}"
exit 0
EOF
    chmod +x "${BIN}/ffmpeg"
}

# Write a fake ffmpeg that writes a partial file then fails.
_stub_ffmpeg_fail() {
    cat > "${BIN}/ffmpeg" <<'EOF'
#!/usr/bin/env bash
out="${*: -1}"
printf 'PARTIAL' > "${out}"
exit 1
EOF
    chmod +x "${BIN}/ffmpeg"
}

# Write a fake ffmpeg that exits 0 but leaves a zero-byte output.
_stub_ffmpeg_empty() {
    cat > "${BIN}/ffmpeg" <<'EOF'
#!/usr/bin/env bash
out="${*: -1}"
: > "${out}"
exit 0
EOF
    chmod +x "${BIN}/ffmpeg"
}

# Write a fake ffmpeg that fails only when the -i input contains "bad".
_stub_ffmpeg_selective() {
    cat > "${BIN}/ffmpeg" <<'EOF'
#!/usr/bin/env bash
in=""
prev=""
for a in "$@"; do
    [[ "${prev}" == "-i" ]] && in="${a}"
    prev="${a}"
done
out="${*: -1}"
if [[ "${in}" == *bad* ]]; then
    printf 'PARTIAL' > "${out}"
    exit 1
fi
printf 'OK' > "${out}"
exit 0
EOF
    chmod +x "${BIN}/ffmpeg"
}

@test "no arguments prints usage and exits 1" {
    run "${SCRIPT}"
    assert_failure
    assert_output --partial "Usage:"
}

@test "-h prints usage and exits 0" {
    run "${SCRIPT}" -h
    assert_success
    assert_output --partial "Usage:"
}

@test "missing ffmpeg reports not installed with an install hint" {
    touch "${WORK}/clip.mp4"
    FFMPEG_BIN="${BATS_TEST_TMPDIR}/nope/ffmpeg" run "${SCRIPT}" "${WORK}/clip.mp4"
    assert_failure
    assert_output --partial "ffmpeg is not installed"
    assert_output --partial "apt install ffmpeg"
}

@test "unknown option is rejected" {
    run "${SCRIPT}" --bogus
    assert_failure
    assert_output --partial "unknown option: --bogus"
}

@test "-o without a value is rejected" {
    run "${SCRIPT}" -o
    assert_failure
    assert_output --partial "'-o' requires a directory argument"
}

@test "-o pointing at an existing file is rejected" {
    _stub_ffmpeg_ok
    touch "${WORK}/clip.mp4"
    touch "${WORK}/afile"
    FFMPEG_BIN="${BIN}/ffmpeg" run "${SCRIPT}" -o "${WORK}/afile" "${WORK}/clip.mp4"
    assert_failure
    assert_output --partial "already exists and is not a directory"
}

@test "nonexistent input path is an error" {
    _stub_ffmpeg_ok
    FFMPEG_BIN="${BIN}/ffmpeg" run "${SCRIPT}" "${WORK}/nope.mp4"
    assert_failure
    assert_output --partial "not found"
}

@test "single file converts to <stem>_resolve.mov next to source" {
    _stub_ffmpeg_ok
    touch "${WORK}/clip.mp4"
    FFMPEG_BIN="${BIN}/ffmpeg" run "${SCRIPT}" "${WORK}/clip.mp4"
    assert_success
    [ -s "${WORK}/clip_resolve.mov" ]
}

@test "-o redirects output into the target directory" {
    _stub_ffmpeg_ok
    touch "${WORK}/clip.mp4"
    OUT="${BATS_TEST_TMPDIR}/out"
    FFMPEG_BIN="${BIN}/ffmpeg" run "${SCRIPT}" -o "${OUT}" "${WORK}/clip.mp4"
    assert_success
    [ -s "${OUT}/clip_resolve.mov" ]
    [ ! -e "${WORK}/clip_resolve.mov" ]
}

@test "existing _resolve.mov counterpart is skipped (idempotent)" {
    _stub_ffmpeg_ok
    touch "${WORK}/clip.mp4"
    printf 'ORIGINAL' > "${WORK}/clip_resolve.mov"
    FFMPEG_BIN="${BIN}/ffmpeg" run "${SCRIPT}" "${WORK}/clip.mp4"
    assert_success
    assert_output --partial "skip"
    run cat "${WORK}/clip_resolve.mov"
    assert_output "ORIGINAL"
}

@test "directory mode converts every video and excludes existing outputs" {
    _stub_ffmpeg_ok
    touch "${WORK}/a.mp4" "${WORK}/b.mkv"
    printf 'DONE' > "${WORK}/c_resolve.mov"
    FFMPEG_BIN="${BIN}/ffmpeg" run "${SCRIPT}" "${WORK}"
    assert_success
    [ -s "${WORK}/a_resolve.mov" ]
    [ -s "${WORK}/b_resolve.mov" ]
    # The pre-existing output must not be re-fed as an input.
    [ ! -e "${WORK}/c_resolve_resolve.mov" ]
    run cat "${WORK}/c_resolve.mov"
    assert_output "DONE"
}

@test "ffmpeg failure removes the partial output and exits 1" {
    _stub_ffmpeg_fail
    touch "${WORK}/clip.mp4"
    FFMPEG_BIN="${BIN}/ffmpeg" run "${SCRIPT}" "${WORK}/clip.mp4"
    assert_failure
    [ ! -e "${WORK}/clip_resolve.mov" ]
}

@test "zero-byte ffmpeg output is removed and exits 1" {
    _stub_ffmpeg_empty
    touch "${WORK}/clip.mp4"
    FFMPEG_BIN="${BIN}/ffmpeg" run "${SCRIPT}" "${WORK}/clip.mp4"
    assert_failure
    [ ! -e "${WORK}/clip_resolve.mov" ]
}

@test "one failing input does not stop the rest; final exit is 1" {
    _stub_ffmpeg_selective
    touch "${WORK}/good.mp4" "${WORK}/bad.mp4"
    FFMPEG_BIN="${BIN}/ffmpeg" run "${SCRIPT}" "${WORK}/good.mp4" "${WORK}/bad.mp4"
    assert_failure
    [ -s "${WORK}/good_resolve.mov" ]
    [ ! -e "${WORK}/bad_resolve.mov" ]
}
