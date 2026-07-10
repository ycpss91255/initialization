#!/usr/bin/env bats
# test/unit/module/claude-ls_spec.bats — module/config/fish/functions/claude-ls.fish (#163)
#
# claude-ls follows ls conventions: quiet + current-folder by default,
# detail behind -l/--long, all projects behind -a/--all, bundled short
# flags (-la/-al) supported. Detail view prints the full UUID plus
# `N msg · size · model · age`; -a group headers show the real cwd; roots
# and fork children are sorted most-recent-first; an empty current folder
# prints a `No sessions found` hint.
#
# The function shells out to `python3 ~/.config/fish/_claude_sessions.py` and
# pipes the JSONL through an inline python renderer gated on the LONG/SHOW_ALL
# flags. These specs drive the real fish function against a fake helper that
# replays a controlled JSONL fixture, so they exercise flag parsing + the
# renderer end-to-end.

load "${BATS_TEST_DIRNAME}/../../helper/common"

CLAUDE_LS_FISH="${MODULE_DIR}/config/fish/functions/claude-ls.fish"

setup() {
    setup_test_env
    FAKE_HOME="${INIT_UBUNTU_TEST_SCRATCH}/home"
    mkdir -p "${FAKE_HOME}/.config/fish"
    export FAKE_HOME

    # Fake helper: replay whatever JSONL fixture the test wrote.
    cat > "${FAKE_HOME}/.config/fish/_claude_sessions.py" <<'PY'
import os, sys
with open(os.environ["CLAUDE_LS_FIXTURE"]) as fp:
    sys.stdout.write(fp.read())
PY

    FIXTURE="${INIT_UBUNTU_TEST_SCRATCH}/sessions.jsonl"
    export FIXTURE

    # A real directory to `cd` into so $PWD (and its `/`->`-` project encoding)
    # is deterministic.
    CWD_DIR="${INIT_UBUNTU_TEST_SCRATCH}/proj/demo"
    mkdir -p "${CWD_DIR}"
    export CWD_DIR
    CUR_PROJECT="$(printf '%s' "${CWD_DIR}" | sed 's#/#-#g')"
    export CUR_PROJECT
}

teardown() {
    teardown_test_env
}

# Run the real fish function against the fake helper + fixture, cd'd into
# CWD_DIR. Extra args are forwarded to claude-ls.
_claude_ls() {
    run env HOME="${FAKE_HOME}" CLAUDE_LS_FIXTURE="${FIXTURE}" \
        fish --no-config -c \
        "source '${CLAUDE_LS_FISH}'; cd '${CWD_DIR}'; claude-ls $*"
}

# Emit one JSONL session object into the fixture. Positional:
#   project session_id title forked_from last_epoch message_count size_bytes model cwd
_session() {
    python3 - "$@" >> "${FIXTURE}" <<'PY'
import json, sys
a = sys.argv[1:]
def val(i, default=""):
    return a[i] if i < len(a) and a[i] != "" else default
obj = {
    "path": "/fake/" + val(1),
    "project": val(0),
    "session_id": val(1),
    "title": val(2),
    "first_user": "",
    "forked_from": (a[3] if len(a) > 3 and a[3] not in ("", "null") else None),
    "last_epoch": (float(a[4]) if len(a) > 4 and a[4] != "" else None),
    "message_count": (int(a[5]) if len(a) > 5 and a[5] != "" else None),
    "size_bytes": (int(a[6]) if len(a) > 6 and a[6] != "" else None),
    "model": val(7),
    "cwd": val(8),
}
print(json.dumps(obj))
PY
}

_now() { date +%s; }

# ── Default view: current folder only, short id, no header ───────────────────

@test "default lists only the current folder's sessions" {
    : > "${FIXTURE}"
    _session "${CUR_PROJECT}" "11111111-1111-1111-1111-111111111111" "here_one" "" "$(_now)"
    _session "-some-other-place" "22222222-2222-2222-2222-222222222222" "elsewhere" "" "$(_now)"

    _claude_ls
    assert_success
    assert_output --partial "here_one"
    refute_output --partial "elsewhere"
}

@test "default view prints no project header and only the 8-char id" {
    : > "${FIXTURE}"
    _session "${CUR_PROJECT}" "3f5894df-aadb-49ee-abec-802ffcbdb651" "code_review" "" "$(_now)"

    _claude_ls
    assert_success
    refute_output --partial "==="
    assert_output --partial "(3f5894df)"
    refute_output --partial "3f5894df-aadb"
}

@test "empty current folder prints the No sessions hint" {
    : > "${FIXTURE}"
    _session "-nope-nope" "44444444-4444-4444-4444-444444444444" "other" "" "$(_now)"

    _claude_ls
    assert_success
    assert_output --partial "No sessions found for: ${CUR_PROJECT}"
    assert_output --partial "-a/--all"
}

# ── -a/--all: every project, real-path header ────────────────────────────────

@test "-a lists every project" {
    : > "${FIXTURE}"
    _session "${CUR_PROJECT}" "11111111-1111-1111-1111-111111111111" "here_one" "" "$(_now)"
    _session "-some-other-place" "22222222-2222-2222-2222-222222222222" "elsewhere" "" "$(_now)"

    _claude_ls -a
    assert_success
    assert_output --partial "here_one"
    assert_output --partial "elsewhere"
}

@test "-a header shows the real cwd, not the encoded project name" {
    : > "${FIXTURE}"
    _session "-x-y-z" "55555555-5555-5555-5555-555555555555" "titled" "" "$(_now)" "" "" "" "/real/path/workspace"

    _claude_ls --all
    assert_success
    assert_output --partial "=== /real/path/workspace"
    refute_output --partial "=== -x-y-z"
}

# ── -l/--long: full UUID + detail columns ────────────────────────────────────

@test "-l prints the full 36-char UUID and detail columns" {
    : > "${FIXTURE}"
    local past
    past="$(( $(_now) - 7200 ))"
    _session "${CUR_PROJECT}" "3f5894df-aadb-49ee-abec-802ffcbdb651" "code_review" \
        "" "${past}" "1355" "7340032" "claude-opus-4-8"

    _claude_ls -l
    assert_success
    assert_output --partial "3f5894df-aadb-49ee-abec-802ffcbdb651"
    assert_output --partial "1355 msg"
    assert_output --partial "7MB"
    assert_output --partial "opus-4-8"
    refute_output --partial "claude-opus-4-8"
    assert_output --partial "2h ago"
}

# ── Bundled short flags ──────────────────────────────────────────────────────

@test "-la bundles -l and -a (header + full UUID)" {
    : > "${FIXTURE}"
    _session "-x-y-z" "3f5894df-aadb-49ee-abec-802ffcbdb651" "titled" \
        "" "$(_now)" "10" "" "" "/real/path/ws"

    _claude_ls -la
    assert_success
    assert_output --partial "=== /real/path/ws"
    assert_output --partial "3f5894df-aadb-49ee-abec-802ffcbdb651"
}

# ── Recency sort ─────────────────────────────────────────────────────────────

@test "roots are ordered most-recent-first" {
    : > "${FIXTURE}"
    local now
    now="$(_now)"
    _session "${CUR_PROJECT}" "aaaaaaaa-0000-0000-0000-000000000000" "older_root"  "" "$(( now - 100000 ))"
    _session "${CUR_PROJECT}" "bbbbbbbb-0000-0000-0000-000000000000" "newer_root"  "" "${now}"

    _claude_ls
    assert_success
    # newer_root must appear before older_root in the output.
    local newer older
    newer="$(printf '%s\n' "${output}" | grep -n 'newer_root' | head -1 | cut -d: -f1)"
    older="$(printf '%s\n' "${output}" | grep -n 'older_root' | head -1 | cut -d: -f1)"
    [ "${newer}" -lt "${older}" ]
}

# ── No trailing Total line ───────────────────────────────────────────────────

@test "output has no trailing 'Total:' summary line" {
    : > "${FIXTURE}"
    _session "${CUR_PROJECT}" "11111111-1111-1111-1111-111111111111" "here_one" "" "$(_now)"

    _claude_ls
    assert_success
    refute_output --partial "Total:"
}
