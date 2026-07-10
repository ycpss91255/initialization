#!/usr/bin/env bats
# test/unit/hook_bootstrap_spec.bats — lib/hook_bootstrap.sh
#
# The shared bootstrap for Claude hooks (.claude/hook/<name>.sh). This spec pins
# its public contract through REAL behavior:
#   - the lib refuses to run as a top-level script (library guard)
#   - hook_bootstrap turns on the exit-code-contract strict mode (set -u +
#     pipefail, NOT -e) and resolves + exports LIB_DIR / REPO_ROOT
#   - hook_read_input / hook_command / hook_field parse the stdin JSON payload
#   - hook_allow exits 0 (pass); hook_block prints "[hook:<name>] BLOCKED — ..."
#     to stderr and exits 2 (block)
#   - hook_context emits a non-blocking additionalContext object + exits 0
#
# Hooks are driven as subprocesses (stdin JSON -> exit code + stderr), the same
# way Claude Code invokes a PreToolUse hook. Snippets/fixtures run as real FILES
# (kcov + set -u BASH_SOURCE hazard; see module_bootstrap_spec.bats).

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    setup_test_env
    SNIPPET="${INIT_UBUNTU_TEST_SCRATCH}/snippet.sh"
    HOOKF="${INIT_UBUNTU_TEST_SCRATCH}/fixture-hook.sh"
}

teardown() { teardown_test_env; }

_json() { jq -n --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}'; }

# Feed a command's JSON to the fixture hook on stdin, the way Claude Code does.
_run() {
    run bash -c "printf '%s' \"\$1\" | '${HOOKF}'" _ "$(_json "$1")"
}

# A reference hook: source the bootstrap, read input, decide, allow/block —
# exactly the shape the hook template stamps out.
_write_decider() {
    cat > "${HOOKF}" <<EOF
#!/usr/bin/env bash
source "${LIB_DIR}/hook_bootstrap.sh"
hook_bootstrap "myhook"
hook_read_input
cmd="\$(hook_command)"
[[ -z "\${cmd}" ]] && hook_allow
if [[ "\${cmd}" == *bad* ]]; then
    hook_block "bad command detected" "do X instead"
fi
hook_allow
EOF
    chmod +x "${HOOKF}"
}

# ── Smoke + library guard ────────────────────────────────────────────────────

@test "hook_bootstrap.sh parses (bash -n)" {
    run bash -n "${LIB_DIR}/hook_bootstrap.sh"
    assert_success
}

@test "hook_bootstrap.sh refuses to run as a top-level script (library guard)" {
    run bash "${LIB_DIR}/hook_bootstrap.sh"
    assert_success
    assert_output --partial "is a library"
}

@test "sourcing hook_bootstrap.sh defines the public hook_* API" {
    cat > "${SNIPPET}" <<'EOF'
source "$1/hook_bootstrap.sh"
for f in hook_bootstrap hook_read_input hook_field hook_command hook_allow hook_block hook_context; do
    declare -F "$f" >/dev/null || { echo "missing $f"; exit 1; }
done
echo ALL_DEFINED
EOF
    run bash "${SNIPPET}" "${LIB_DIR}"
    assert_success
    assert_output --partial "ALL_DEFINED"
}

# ── Strict mode + path resolution (exit-code-contract: -u + pipefail, NOT -e) ─

@test "hook_bootstrap turns on set -u + pipefail but NOT -e" {
    cat > "${SNIPPET}" <<'EOF'
source "$1/hook_bootstrap.sh"
hook_bootstrap "snip"
[[ "$-" == *u* ]] && echo HAS_U
[[ "$-" != *e* ]] && echo NO_E
set -o | grep -q "pipefail.*on" && echo HAS_PIPEFAIL
EOF
    run bash "${SNIPPET}" "${LIB_DIR}"
    assert_success
    assert_output --partial "HAS_U"
    assert_output --partial "NO_E"
    assert_output --partial "HAS_PIPEFAIL"
}

@test "hook_bootstrap self-locates + exports LIB_DIR / REPO_ROOT" {
    cat > "${SNIPPET}" <<'EOF'
unset LIB_DIR REPO_ROOT
source "$1/hook_bootstrap.sh"
hook_bootstrap "snip"
[[ "${LIB_DIR}" == "$1" ]]  && echo LIB_OK
[[ -d "${REPO_ROOT}/lib" ]] && echo ROOT_OK
env | grep -q "^LIB_DIR="   && echo EXPORTED
EOF
    run bash "${SNIPPET}" "${LIB_DIR}"
    assert_success
    assert_output --partial "LIB_OK"
    assert_output --partial "ROOT_OK"
    assert_output --partial "EXPORTED"
}

# ── stdin parsing ────────────────────────────────────────────────────────────

@test "hook_command extracts .tool_input.command from the stdin payload" {
    cat > "${HOOKF}" <<EOF
#!/usr/bin/env bash
source "${LIB_DIR}/hook_bootstrap.sh"
hook_bootstrap "echocmd"
hook_read_input
printf 'CMD=[%s]\n' "\$(hook_command)"
EOF
    chmod +x "${HOOKF}"
    _run "git push origin main"
    assert_success
    assert_output --partial "CMD=[git push origin main]"
}

@test "hook_field returns empty for an absent field" {
    cat > "${HOOKF}" <<EOF
#!/usr/bin/env bash
source "${LIB_DIR}/hook_bootstrap.sh"
hook_bootstrap "fieldtest"
hook_read_input
printf 'CWD=[%s]\n' "\$(hook_field '.cwd')"
EOF
    chmod +x "${HOOKF}"
    _run "ls"
    assert_success
    assert_output --partial "CWD=[]"
}

# ── Block path (exit 2 + repo-standard message) ──────────────────────────────

@test "hook_block blocks with exit 2 and the repo-standard message" {
    _write_decider
    _run "run something bad now"
    assert_failure 2
    assert_output --partial "[hook:myhook] BLOCKED"
    assert_output --partial "bad command detected"
    assert_output --partial "do X instead"
}

# ── Allow path (exit 0) ──────────────────────────────────────────────────────

@test "hook_allow allows an unrelated command (exit 0, no block message)" {
    _write_decider
    _run "ls -la"
    assert_success
    refute_output --partial "BLOCKED"
}

@test "empty command is allowed (exit 0)" {
    _write_decider
    _run ""
    assert_success
    refute_output --partial "BLOCKED"
}

# ── Non-blocking context injection ───────────────────────────────────────────

@test "hook_context emits additionalContext JSON and exits 0" {
    cat > "${HOOKF}" <<EOF
#!/usr/bin/env bash
source "${LIB_DIR}/hook_bootstrap.sh"
hook_bootstrap "ctx"
hook_read_input
hook_context "remember to sync"
EOF
    chmod +x "${HOOKF}"
    _run "anything"
    assert_success
    assert_output --partial '"additionalContext"'
    assert_output --partial "remember to sync"
    assert_output --partial "PreToolUse"
}
