#!/usr/bin/env bats
# test/unit/cli_input_validation_spec.bats — CLI input validation at boundaries
#
# Stream S3 (audit #178, non-functional coverage): drive the REAL
# setup_ubuntu.sh entry point with pathological / malicious argv and assert
# the tool rejects them cleanly — proper exit code + diagnostic, never a
# crash, never a path traversal, never argument injection into a shell.
#
# All cases below use root-safe subcommands (verify / list / show / detect /
# export / import / config / search) or --dry-run, so they run under the test
# container's default user without tripping the EUID-0 install refusal
# (lib/dispatcher.sh _dispatcher_lifecycle, PRD §10).
#
# Exit-code contract (PRD §7.4):
#   2 — usage error (unknown subcommand / flag / module, bad args)
#   5 — dependency cycle
# A clean rejection means: non-zero exit (no segfault / unbound-var crash) AND
# a human-readable diagnostic on stderr.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
    # Pin width/locale logic deterministically (repo convention).
    export LC_ALL=C.UTF-8
    SETUP="${REPO_ROOT}/setup_ubuntu.sh"
}

teardown() {
    teardown_test_env
}

# ── Unknown subcommand ───────────────────────────────────────────────────────

@test "unknown subcommand is rejected with exit 2 and a hint" {
    run bash "${SETUP}" frobnicate
    assert_failure 2
    assert_output --partial "unknown subcommand"
    assert_output --partial "--help"
}

@test "subcommand with leading dash typo is rejected (exit 2)" {
    run bash "${SETUP}" --instal docker
    assert_failure 2
}

@test "subcommand that looks like a path is rejected, not executed" {
    # A subcommand argument that resembles a filesystem path must be treated
    # as an unknown subcommand string — never sourced / executed.
    run bash "${SETUP}" ../../etc/passwd
    assert_failure 2
    assert_output --partial "unknown subcommand"
    # The literal path content must never be echoed back as if read.
    refute_output --partial "root:x:0:0"
}

# ── Misspelled / nonexistent module names ────────────────────────────────────

@test "install of a nonexistent module fails fast with exit 2 (resolver unknown)" {
    run bash "${SETUP}" install does-not-exist --dry-run
    assert_failure 2
    assert_output --partial "unknown module"
}

@test "remove of a nonexistent module fails fast with exit 2" {
    run bash "${SETUP}" remove does-not-exist --dry-run
    assert_failure 2
}

@test "show of a nonexistent module is rejected with exit 2" {
    run bash "${SETUP}" show does-not-exist
    assert_failure 2
    assert_output --partial "unknown module"
}

@test "misspelled module name (dockr) is not silently resolved to docker" {
    run bash "${SETUP}" install dockr --dry-run
    assert_failure 2
    refute_output --partial "- docker"
}

@test "search of a nonsense keyword reports no match cleanly (exit 0)" {
    # search is a query, not a mutation: an unmatched keyword is valid input
    # and must report 'no match' rather than error or crash.
    run bash "${SETUP}" search zzz-no-such-keyword-zzz
    assert_success
    assert_output --partial "no module matches"
}

# ── Malformed flags ──────────────────────────────────────────────────────────

@test "unknown global-looking flag on list is rejected with exit 2" {
    run bash "${SETUP}" list --bogus-flag
    assert_failure 2
    assert_output --partial "unknown flag"
}

@test "unknown flag on install is rejected with exit 2" {
    run bash "${SETUP}" install docker --no-such-flag --dry-run
    assert_failure 2
    assert_output --partial "unknown flag"
}

@test "empty --category= filters to nothing without crashing (exit 0)" {
    # An empty category value is a degenerate-but-parseable filter: list must
    # still emit a well-formed result (header or 'no modules'), never crash.
    run bash "${SETUP}" list --category=
    assert_success
}

@test "empty --category= with --json still emits well-formed JSON" {
    run bash "${SETUP}" list --category= --json
    assert_success
    echo "${output}" | jq -e '.items | type == "array"' > /dev/null
}

@test "bogus --category=value yields an empty list, not a crash (exit 0)" {
    run bash "${SETUP}" list --category=not-a-real-category
    assert_success
    refute_output --partial "docker"
}

@test "invalid --color value is rejected with exit 2 (global flag guard)" {
    run bash "${SETUP}" --color=banana list
    assert_failure 2
}

@test "detect rejects an unexpected positional arg with exit 2" {
    run bash "${SETUP}" detect surprise-positional
    assert_failure 2
    assert_output --partial "no positional"
}

# ── Bad language input (env-driven; whitelist {en,zh-TW,zh-CN,ja}) ────────────
# There is no --lang flag; language comes from INIT_UBUNTU_LANG / config
# (lib/i18n.sh i18n_sanitize_lang). A bad value must NOT crash: it falls back
# to "en" with a bilingual warning on stderr and the command still succeeds.

@test "garbage INIT_UBUNTU_LANG falls back to en without crashing" {
    INIT_UBUNTU_LANG="../../etc; rm -rf /" run bash "${SETUP}" list
    assert_success
    # The poisoned value is reported back %q-quoted, never executed.
    refute_output --partial "rm -rf /"
}

@test "garbage INIT_UBUNTU_LANG emits a fallback warning to stderr" {
    run bash -c "INIT_UBUNTU_LANG='klingon' bash '${SETUP}' list 2>&1 1>/dev/null"
    assert_output --partial "en"
}

@test "config set ui.lang accepts a value but resolution sanitizes a bad one" {
    # config layer is a dumb key/value store; the whitelist is enforced at
    # resolution. A bad stored value must not break a later read-only run.
    bash "${SETUP}" config set ui.lang klingon
    run bash "${SETUP}" list
    assert_success
}

# ── Path-traversal / absolute-path arguments to export ───────────────────────
# `export <file>` legitimately writes wherever the user points (PRD §7.2
# example: `export ~/my-state.json`). The boundary contract under test: the
# file is written EXACTLY at the literal path given and NOWHERE else — a
# traversal-style or absolute arg must not escape into an unrelated location,
# and the path string must never be interpreted by a shell.

@test "export to a traversal path writes only the literal target, no escape" {
    local _base="${INIT_UBUNTU_TEST_SCRATCH}/exp"
    mkdir -p "${_base}/sub"
    local _target="${_base}/sub/../out.json"
    run bash "${SETUP}" export "${_target}"
    assert_success
    # The '..' resolves to _base/out.json — written there, not above _base.
    [[ -f "${_base}/out.json" ]]
    # Nothing leaked to the scratch root or above it.
    [[ ! -e "${INIT_UBUNTU_TEST_SCRATCH}/out.json" ]]
    run jq -e '.modules | type == "array"' "${_base}/out.json"
    assert_success
}

@test "export with a command-substitution-ish filename does not execute it" {
    local _marker="${INIT_UBUNTU_TEST_SCRATCH}/PWNED"
    # A filename containing shell metacharacters must be treated as a literal
    # path component, never evaluated. If it were eval'd, the marker file would
    # appear. Build the literal '$(...)' from a printf'd dollar so no
    # single-quoted command-substitution string sits in this source file.
    local _dollar; _dollar="$(printf '\x24')"
    local _name="${_dollar}(touch ${_marker}).json"
    run bash "${SETUP}" export "${INIT_UBUNTU_TEST_SCRATCH}/${_name}"
    # Whether the odd filename is accepted or rejected, the side effect MUST
    # NOT happen: no marker file was created by shell evaluation.
    [[ ! -e "${_marker}" ]]
}

@test "export to a nonexistent directory fails without writing elsewhere" {
    local _bad="${INIT_UBUNTU_TEST_SCRATCH}/no-such-dir/out.json"
    run bash "${SETUP}" export "${_bad}"
    assert_failure
    [[ ! -e "${_bad}" ]]
}

# ── Path-traversal / injection arguments to import ───────────────────────────

@test "import of a nonexistent file fails cleanly (no crash)" {
    run bash "${SETUP}" import "${INIT_UBUNTU_TEST_SCRATCH}/missing-payload.json"
    assert_failure
    # Diagnostic on stderr, not a bash unbound-variable / jq stacktrace.
    refute_output --partial "unbound variable"
    refute_output --partial "syntax error"
}

@test "import of an absolute system path that is not a payload fails cleanly" {
    # Pointing import at /etc/hostname (exists, not a valid payload) must be
    # rejected by the schema/version guard, never partially applied.
    run bash "${SETUP}" import /etc/hostname
    assert_failure
    # state.json must still report zero installed (dry-run default; nothing applied).
    local _state="${INIT_UBUNTU_STATE_DIR}/state.json"
    if [[ -f "${_state}" ]]; then
        run jq -r '.installed | length' "${_state}"
        assert_output "0"
    fi
}

@test "import of a payload missing the version field is rejected (exit 2)" {
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/noversion.json"
    echo '{"modules":[]}' > "${_payload}"
    run bash "${SETUP}" import "${_payload}"
    assert_failure 2
    assert_output --partial "version"
}

# ── Injection-ish module names (metacharacters must stay inert) ──────────────
# A module name carrying shell metacharacters must be handled as a plain
# string: looked up in the registry, found absent, and rejected with exit 2 —
# never word-split, globbed, or executed.

@test "module name with a semicolon+rm is treated as one inert unknown name" {
    local _marker="${INIT_UBUNTU_TEST_SCRATCH}/INJECTED"
    run bash "${SETUP}" install "docker; touch ${_marker}" --dry-run
    assert_failure 2
    [[ ! -e "${_marker}" ]]
}

@test "module name with backticks does not run a command substitution" {
    local _marker="${INIT_UBUNTU_TEST_SCRATCH}/BACKTICK"
    run bash "${SETUP}" show '`touch '"${_marker}"'`'
    assert_failure 2
    [[ ! -e "${_marker}" ]]
}

@test "module name with dollar-paren substitution stays inert" {
    local _marker="${INIT_UBUNTU_TEST_SCRATCH}/DOLLAR"
    run bash "${SETUP}" show '$(touch '"${_marker}"')'
    assert_failure 2
    [[ ! -e "${_marker}" ]]
}

@test "module name of a path-traversal string is an unknown module, not a read" {
    run bash "${SETUP}" show "../../../etc/passwd"
    assert_failure 2
    assert_output --partial "unknown module"
    refute_output --partial "root:x:0:0"
}

@test "module name with a glob does not expand against the filesystem" {
    # '*' must not match real module files; it is one literal unknown name.
    run bash "${SETUP}" show '*'
    assert_failure 2
    assert_output --partial "unknown module"
}

@test "verify of an injection-style module name reports cleanly, runs nothing" {
    local _marker="${INIT_UBUNTU_TEST_SCRATCH}/VERIFY_INJECT"
    run bash "${SETUP}" verify "nope && touch ${_marker}"
    # verify of an unknown module is allowed to exit 0/non-0 depending on the
    # runner, but it must NEVER execute the injected command.
    [[ ! -e "${_marker}" ]]
    refute_output --partial "command not found: touch"
}

# ── config key validation ────────────────────────────────────────────────────

@test "config get of a non-dotted key is rejected with exit 2" {
    run bash "${SETUP}" config get notdotted
    assert_failure 2
    assert_output --partial "section.key"
}

@test "config set without a value is rejected with exit 2" {
    run bash "${SETUP}" config set ui.lang
    assert_failure 2
}

@test "unknown config action is rejected with exit 2" {
    run bash "${SETUP}" config bogus-action
    assert_failure 2
    assert_output --partial "unknown config action"
}
