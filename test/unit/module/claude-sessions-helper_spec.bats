#!/usr/bin/env bats
# test/unit/module/claude-sessions-helper_spec.bats
#   module/config/fish/_claude_sessions.py
#
# The helper enumerates Claude Code sessions under ~/.claude/projects and dumps
# one JSON object per line. Issue #161 reworks it to:
#   - visit directory-type sessions (UUID-named dirs with subagents/ but no
#     top-level <uuid>.jsonl), enriched from the subagent transcripts,
#   - emit per-session metadata (last_epoch, message_count, size_bytes, model,
#     cwd) on every record,
#   - dedup file-type vs directory-type by session id (seen_ids).

load "${BATS_TEST_DIRNAME}/../../helper/common"

HELPER="${MODULE_DIR}/config/fish/_claude_sessions.py"

FILE_UUID="11111111-1111-1111-1111-111111111111"
DIR_UUID="22222222-2222-2222-2222-222222222222"

setup() {
    setup_test_env
    FAKE_HOME="${INIT_UBUNTU_TEST_SCRATCH}/home"
    PROJECTS="${FAKE_HOME}/.claude/projects"
    mkdir -p "${PROJECTS}"
    export FAKE_HOME PROJECTS
}

teardown() {
    teardown_test_env
}

# Build a file-type session: ~/.claude/projects/proj-file/<uuid>.jsonl
_make_file_session() {
    local dir="${PROJECTS}/proj-file"
    mkdir -p "${dir}"
    cat > "${dir}/${FILE_UUID}.jsonl" <<EOF
{"type":"user","cwd":"/work/repo-a","timestamp":"2026-01-01T10:00:00Z","message":{"content":"hello world first line"}}
{"type":"assistant","timestamp":"2026-01-01T10:01:00Z","message":{"model":"claude-opus-4-8","content":"hi"}}
{"type":"assistant","customTitle":"My Titled Session","timestamp":"2026-01-01T10:02:00Z","message":{"model":"claude-opus-4-8","content":"more"}}
EOF
}

# Build a directory-type session with no top-level <uuid>.jsonl.
_make_dir_session() {
    local base="${PROJECTS}/proj-dir/${DIR_UUID}/subagents"
    mkdir -p "${base}"
    cat > "${base}/agent-abc.meta.json" <<EOF
{"description":"subagent task description here"}
EOF
    cat > "${base}/agent-abc.jsonl" <<EOF
{"type":"user","cwd":"/work/repo-b","timestamp":"2026-02-02T12:00:00Z","message":{"content":"do the thing"}}
{"type":"assistant","timestamp":"2026-02-02T12:05:00Z","message":{"model":"claude-sonnet-4-6","content":"done"}}
EOF
}

_run_helper() {
    HOME="${FAKE_HOME}" run python3 "${HELPER}"
}

# Extract the record whose session_id == $1 from JSONL on stdout, pretty-print
# a single field $2 via python.
_field() {
    local sid="$1" key="$2"
    printf '%s\n' "${output}" | python3 -c '
import json,sys
sid,key=sys.argv[1],sys.argv[2]
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    d=json.loads(line)
    if d.get("session_id")==sid:
        v=d.get(key)
        print("" if v is None else v)
        break
' "${sid}" "${key}"
}

@test "helper: file-type session record carries new metadata keys" {
    _make_file_session
    _run_helper
    [ "${status}" -eq 0 ]

    # New keys must be present and populated for a file-type session.
    [ "$(_field "${FILE_UUID}" model)" = "claude-opus-4-8" ]
    [ "$(_field "${FILE_UUID}" cwd)" = "/work/repo-a" ]
    [ "$(_field "${FILE_UUID}" title)" = "My Titled Session" ]

    # message_count counts user+assistant messages (3 here).
    [ "$(_field "${FILE_UUID}" message_count)" = "3" ]

    # size_bytes and last_epoch are populated (non-empty, non-zero).
    local size epoch
    size="$(_field "${FILE_UUID}" size_bytes)"
    epoch="$(_field "${FILE_UUID}" last_epoch)"
    [ -n "${size}" ] && [ "${size}" != "0" ]
    [ -n "${epoch}" ] && [ "${epoch}" != "0" ]
}

@test "helper: directory-type session is enumerated and enriched from subagents" {
    _make_dir_session
    _run_helper
    [ "${status}" -eq 0 ]

    # The UUID directory (no top-level <uuid>.jsonl) must appear.
    printf '%s\n' "${output}" | grep -q "\"session_id\": \"${DIR_UUID}\""

    # first_user comes from the meta.json description.
    [ "$(_field "${DIR_UUID}" first_user)" = "subagent task description here" ]

    # cwd and model are derived from the subagent transcript.
    [ "$(_field "${DIR_UUID}" cwd)" = "/work/repo-b" ]
    [ "$(_field "${DIR_UUID}" model)" = "claude-sonnet-4-6" ]

    # message_count from the transcript (2 messages).
    [ "$(_field "${DIR_UUID}" message_count)" = "2" ]
}

@test "helper: file and directory sessions coexist without double counting" {
    _make_file_session
    _make_dir_session
    _run_helper
    [ "${status}" -eq 0 ]

    # Exactly two records total.
    local count
    count="$(printf '%s\n' "${output}" | grep -c 'session_id')"
    [ "${count}" -eq 2 ]

    # Each id appears exactly once.
    [ "$(printf '%s\n' "${output}" | grep -c "\"${FILE_UUID}\"")" -eq 1 ]
    [ "$(printf '%s\n' "${output}" | grep -c "\"${DIR_UUID}\"")" -eq 1 ]
}
