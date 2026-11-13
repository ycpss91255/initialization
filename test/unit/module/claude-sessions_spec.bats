#!/usr/bin/env bats
# test/unit/module/claude-sessions_spec.bats — module/config/fish/_claude_sessions.py
# and module/config/fish/functions/claude-rm.fish (#419)
#
# The helper reports a session's title as the LAST `customTitle` in its
# transcript: /branch and /rename append custom-title records long after the
# header, and the latest record is the current name. claude-rm matches titles
# through the same helper, so a renamed session can be found by its new name.

load "${BATS_TEST_DIRNAME}/../../helper/common"

HELPER_PY="${MODULE_DIR}/config/fish/_claude_sessions.py"
CLAUDE_RM_FISH="${MODULE_DIR}/config/fish/functions/claude-rm.fish"

setup() {
    setup_test_env
    FAKE_HOME="${INIT_UBUNTU_TEST_SCRATCH}/home"
    PROJ="${FAKE_HOME}/.claude/projects/-home-cyc-Desktop-arch-drawio"
    mkdir -p "${PROJ}" "${FAKE_HOME}/.config/fish" "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    cp "${HELPER_PY}" "${FAKE_HOME}/.config/fish/_claude_sessions.py"
    export FAKE_HOME PROJ

    # Stub gio so a confirmed deletion can never touch a real trash.
    cat > "${INIT_UBUNTU_TEST_SCRATCH}/bin/gio" <<STUB
#!/usr/bin/env bash
echo "gio \$*" >> "${INIT_UBUNTU_TEST_SCRATCH}/gio.log"
STUB
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/gio"
}

teardown() {
    teardown_test_env
}

# Write a transcript with an early title, many filler lines, then a rename.
#   $1 session id  $2 early title ("" = none)  $3 late title ("" = none)
_transcript() {
    python3 - "$1" "$2" "$3" > "${PROJ}/$1.jsonl" <<'PY'
import json, sys
sid, early, late = sys.argv[1:4]
if early:
    print(json.dumps({"type": "custom-title", "customTitle": early, "sessionId": sid}))
for i in range(120):
    print(json.dumps({"type": "user", "cwd": "/home/cyc/Desktop/arch_drawio",
                      "message": {"role": "user", "content": "line %d" % i}}))
if late:
    print(json.dumps({"type": "custom-title", "customTitle": late, "sessionId": sid}))
PY
}

_titles() {
    run env HOME="${FAKE_HOME}" python3 "${FAKE_HOME}/.config/fish/_claude_sessions.py"
}

_claude_rm() {
    run bash -c "printf 'n\n' | env HOME='${FAKE_HOME}' PATH='${INIT_UBUNTU_TEST_SCRATCH}/bin':\"\$PATH\" fish --no-config -c \"source '${CLAUDE_RM_FISH}'; claude-rm $*\""
}

@test "helper reports a title written past the first 50 lines" {
    _transcript "61b7d40c-00eb-41e5-9577-831fe62b61d4" "" "review_repo_split"

    _titles
    assert_success
    run jq -r '.title' <<<"${output}"
    assert_output "review_repo_split"
}

@test "helper: the last customTitle wins over an earlier one" {
    _transcript "61b7d40c-00eb-41e5-9577-831fe62b61d4" "old_name_branch" "review_repo_split"

    _titles
    assert_success
    run jq -r '.title' <<<"${output}"
    assert_output "review_repo_split"
}

@test "claude-rm matches a renamed session by its late title (#419)" {
    _transcript "61b7d40c-00eb-41e5-9577-831fe62b61d4" "old_name_branch" "review_repo_split"

    _claude_rm review_repo_split
    assert_output --partial "Found 1 session(s)"
    assert_output --partial "61b7d40c-00eb-41e5-9577-831fe62b61d4"
    assert_output --partial "Cancelled"
    # Declined at the prompt: nothing may have been trashed.
    [[ ! -e "${INIT_UBUNTU_TEST_SCRATCH}/gio.log" ]]
}

@test "claude-rm does not match the superseded early title" {
    _transcript "61b7d40c-00eb-41e5-9577-831fe62b61d4" "old_name_branch" "review_repo_split"

    _claude_rm old_name_branch
    assert_output --partial 'No session matched "old_name_branch"'
}

@test "claude-rm still falls back to a sessionId prefix" {
    _transcript "61b7d40c-00eb-41e5-9577-831fe62b61d4" "" ""

    _claude_rm 61b7d40c
    assert_output --partial "Found 1 session(s)"
}
