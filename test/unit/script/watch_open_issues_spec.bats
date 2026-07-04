#!/usr/bin/env bats
# test/unit/script/watch_open_issues_spec.bats
#
# Tests for `.claude/script/watch-open-issues.sh` (open-issue CHANGE-WATCHER,
# a Monitor-companion script following the auto-merge-on-green.sh pattern).
#
# Strategy:
#   - The core diff logic is a PURE function `watch_issues_diff <prev> <cur>`
#     that reads two "number<TAB>updatedAt<TAB>title" snapshot files and prints
#     NEW/UPDATED/CLOSED lines. It touches no network, so it is sourced and
#     called directly against crafted fixture files (fully deterministic).
#   - Arg-handling cases (--help / unknown flag / missing --repo) exit before
#     any fetch, so a trivial `gh` PATH-stub suffices.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    SCRIPT="${REPO_ROOT}/.claude/script/watch-open-issues.sh"
    STUB_DIR="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${STUB_DIR}"
    # Trivial gh stub: never reached by the arg-error paths, but on PATH so a
    # stray call cannot hit the real network.
    cat > "${STUB_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "${STUB_DIR}/gh"
    export PATH="${STUB_DIR}:${PATH}"

    PREV="${BATS_TEST_TMPDIR}/prev.tsv"
    CUR="${BATS_TEST_TMPDIR}/cur.tsv"
    export PREV CUR
}

teardown() {
    teardown_test_env
}

# Emit a snapshot fixture line: number<TAB>updatedAt<TAB>title
_snap() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }

_diff() { run bash -c "source '${SCRIPT}'; watch_issues_diff '${PREV}' '${CUR}'"; }

# ── Pure diff function: NEW / UPDATED / CLOSED ───────────────────────────────

@test "watch_issues_diff: brand-new issue -> NEW line" {
    : > "${PREV}"
    _snap 7 2026-07-04T10:00:00Z "add fzf pane" > "${CUR}"
    _diff
    assert_success
    assert_output --partial "NEW #7 add fzf pane"
}

@test "watch_issues_diff: same number, changed updatedAt -> UPDATED line" {
    _snap 7 2026-07-04T10:00:00Z "add fzf pane" > "${PREV}"
    _snap 7 2026-07-04T11:30:00Z "add fzf pane" > "${CUR}"
    _diff
    assert_success
    assert_output --partial "UPDATED #7 add fzf pane"
    refute_output --partial "NEW #7"
}

@test "watch_issues_diff: number gone from cur -> CLOSED line" {
    _snap 7 2026-07-04T10:00:00Z "add fzf pane" > "${PREV}"
    : > "${CUR}"
    _diff
    assert_success
    assert_output --partial "CLOSED #7"
}

@test "watch_issues_diff: unchanged updatedAt -> no output (quiet)" {
    _snap 7 2026-07-04T10:00:00Z "add fzf pane" > "${PREV}"
    _snap 7 2026-07-04T10:00:00Z "add fzf pane" > "${CUR}"
    _diff
    assert_success
    assert_output ""
}

@test "watch_issues_diff: mixed NEW + UPDATED + CLOSED in one pass" {
    {
        _snap 3 2026-07-01T09:00:00Z "old kept"
        _snap 7 2026-07-04T10:00:00Z "will change"
        _snap 9 2026-07-02T08:00:00Z "will close"
    } > "${PREV}"
    {
        _snap 3 2026-07-01T09:00:00Z "old kept"
        _snap 7 2026-07-04T11:30:00Z "will change"
        _snap 12 2026-07-04T12:00:00Z "brand new"
    } > "${CUR}"
    _diff
    assert_success
    assert_output --partial "NEW #12 brand new"
    assert_output --partial "UPDATED #7 will change"
    assert_output --partial "CLOSED #9"
    refute_output --partial "#3"
}

# ── Arg handling ─────────────────────────────────────────────────────────────

@test "--help exits 0 and prints usage" {
    run "${SCRIPT}" --help
    assert_success
    assert_output --partial "watch-open-issues.sh"
    assert_output --partial "--repo"
}

@test "unknown flag exits 2" {
    run "${SCRIPT}" --repo o/r --bogus
    assert_failure 2
    assert_output --partial "unknown"
}

@test "missing --repo exits 2" {
    run "${SCRIPT}" --once
    assert_failure 2
    assert_output --partial "--repo is required"
}

@test "--repo as the last token exits 2, does not hang" {
    run "${SCRIPT}" --repo
    assert_failure 2
    assert_output --partial "--repo needs a value"
}

@test "--interval as the last token exits 2, does not hang" {
    run "${SCRIPT}" --repo o/r --interval
    assert_failure 2
    assert_output --partial "--interval needs a value"
}

@test "--state-file as the last token exits 2, does not hang" {
    run "${SCRIPT}" --repo o/r --state-file
    assert_failure 2
    assert_output --partial "--state-file needs a value"
}

@test "--interval 0 exits 2 (rejects busy-spin)" {
    run "${SCRIPT}" --repo o/r --interval 0 --once
    assert_failure 2
    assert_output --partial "--interval must be a positive integer"
}

@test "--interval non-numeric exits 2" {
    run "${SCRIPT}" --repo o/r --interval abc --once
    assert_failure 2
    assert_output --partial "--interval must be a positive integer"
}

# ── --once baseline arm (offline, gh stubbed to a canned issue list) ─────────

@test "--once on a fresh state-file arms the baseline: 'watch armed: N issues'" {
    cat > "${STUB_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
# Emulate `gh issue list ... --json number,updatedAt,title`.
cat <<'JSON'
[
  {"number": 7, "updatedAt": "2026-07-04T10:00:00Z", "title": "add fzf pane"},
  {"number": 9, "updatedAt": "2026-07-02T08:00:00Z", "title": "whiptail parity"}
]
JSON
EOF
    chmod +x "${STUB_DIR}/gh"
    local sf="${BATS_TEST_TMPDIR}/state.tsv"
    : > "${sf}"
    run "${SCRIPT}" --repo o/r --once --state-file "${sf}"
    assert_success
    assert_output --partial "watch armed: 2 issues"
}

@test "zero open issues: arms once, then stays quiet on the next cycle" {
    cat > "${STUB_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
echo '[]'
EOF
    chmod +x "${STUB_DIR}/gh"
    local sf="${BATS_TEST_TMPDIR}/state.tsv"
    : > "${sf}"
    run "${SCRIPT}" --repo o/r --once --state-file "${sf}"
    assert_success
    assert_output --partial "watch armed: 0 issues"
    # Second cycle against the same empty-but-armed baseline: no re-arm, silent.
    run "${SCRIPT}" --repo o/r --once --state-file "${sf}"
    assert_success
    refute_output --partial "watch armed"
    assert_output ""
}
