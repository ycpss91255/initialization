#!/usr/bin/env bats
# test/unit/fish_completions_spec.bats — fish completion files for the CLIs
#
# Covers module/config/fish/completions/{setup_ubuntu,setup_ubuntu_tui,
# setup_secrets,just}.fish. Two layers:
#
#   1. `fish -n` syntax on every file. The repo lint gate (script/ci/ci.sh
#      _find_lintable_fish) PRUNES module/config, so these completion files
#      would otherwise never be syntax-checked — this spec is their gate.
#   2. Functional smoke: `complete -C '<cmdline>'` after sourcing the file,
#      asserting the expected subcommands / flags / fixed-value sets appear.
#      `complete -C` is fish's own "what would Tab offer" entry point, so this
#      exercises the real completion engine, not a string match on the source.
#
# fish is baked into the test-tools image (dockerfile/Dockerfile.test-tools);
# the whole suite runs in Docker (ADR-0004). Each test skips cleanly if fish is
# somehow absent, so the file never hard-fails a fish-less environment.

load "${BATS_TEST_DIRNAME}/../helper/common"

COMPL_DIR="${REPO_ROOT}/module/config/fish/completions"

setup() {
    if ! command -v fish >/dev/null 2>&1; then
        skip "fish not on PATH (run inside the test-tools image)"
    fi
}

# Source one completion file then run `complete -C` for the given cmdline,
# printing fish's candidate list (one per line). The description column (after
# the tab) is left intact — the assertions match on the candidate token via
# --partial, and keeping the whole line avoids any host-shell post-processing
# (the pipe must stay inside `fish -c`, since bats' `run` is bash).
_compl() {
    local _file="$1" _line="$2"
    fish -c "source '${COMPL_DIR}/${_file}'; complete -C '${_line}'"
}

# ── 1. Syntax (the lint-gate gap-filler) ─────────────────────────────────────

@test "setup_ubuntu.fish passes fish -n" {
    run fish -n "${COMPL_DIR}/setup_ubuntu.fish"
    assert_success
}

@test "setup_ubuntu_tui.fish passes fish -n" {
    run fish -n "${COMPL_DIR}/setup_ubuntu_tui.fish"
    assert_success
}

@test "setup_secrets.fish passes fish -n" {
    run fish -n "${COMPL_DIR}/setup_secrets.fish"
    assert_success
}

@test "just.fish passes fish -n" {
    run fish -n "${COMPL_DIR}/just.fish"
    assert_success
}

# ── 2a. setup_ubuntu_tui.sh ──────────────────────────────────────────────────

@test "tui '-' offers --backend --lang --help --version" {
    run _compl setup_ubuntu_tui.fish 'setup_ubuntu_tui.sh -'
    assert_success
    assert_output --partial '--backend'
    assert_output --partial '--lang'
    assert_output --partial '--help'
    assert_output --partial '--version'
}

@test "tui --backend completes fzf whiptail gum" {
    run _compl setup_ubuntu_tui.fish 'setup_ubuntu_tui.sh --backend '
    assert_success
    assert_output --partial 'fzf'
    assert_output --partial 'whiptail'
    assert_output --partial 'gum'
}

@test "tui --lang completes en zh-TW" {
    run _compl setup_ubuntu_tui.fish 'setup_ubuntu_tui.sh --lang '
    assert_success
    assert_output --partial 'en'
    assert_output --partial 'zh-TW'
}

# ── 2b. setup_ubuntu CLI ─────────────────────────────────────────────────────

@test "setup_ubuntu bare offers the core subcommands" {
    run _compl setup_ubuntu.fish 'setup_ubuntu '
    assert_success
    for _sub in install remove purge upgrade verify list show search \
                detect doctor config sync export import; do
        assert_output --partial "${_sub}"
    done
}

@test "setup_ubuntu list --category completes the four categories" {
    run _compl setup_ubuntu.fish 'setup_ubuntu list --category '
    assert_success
    assert_output --partial 'base'
    assert_output --partial 'recommended'
    assert_output --partial 'optional'
    assert_output --partial 'experimental'
}

@test "setup_ubuntu config offers set/get/unset/show" {
    run _compl setup_ubuntu.fish 'setup_ubuntu config '
    assert_success
    assert_output --partial 'set'
    assert_output --partial 'get'
    assert_output --partial 'unset'
    assert_output --partial 'show'
}

@test "setup_ubuntu install completes module names from the cheap glob" {
    # No engine fork: names come from globbing module/*.module.sh basenames.
    run _compl setup_ubuntu.fish 'setup_ubuntu install '
    assert_success
    assert_output --partial 'fish'
    assert_output --partial 'docker'
}

# ── 2c. setup_secrets CLI ────────────────────────────────────────────────────

@test "setup_secrets bare offers ssh-key token gpg list remove" {
    run _compl setup_secrets.fish 'setup_secrets '
    assert_success
    assert_output --partial 'ssh-key'
    assert_output --partial 'token'
    assert_output --partial 'gpg'
    assert_output --partial 'list'
    assert_output --partial 'remove'
}

@test "setup_secrets ssh-key offers generate/load/copy/list/remove" {
    run _compl setup_secrets.fish 'setup_secrets ssh-key '
    assert_success
    assert_output --partial 'generate'
    assert_output --partial 'load'
    assert_output --partial 'copy'
    assert_output --partial 'list'
    assert_output --partial 'remove'
}

@test "setup_secrets ssh-key generate --type completes ed25519 ecdsa rsa" {
    run _compl setup_secrets.fish 'setup_secrets ssh-key generate --type '
    assert_success
    assert_output --partial 'ed25519'
    assert_output --partial 'ecdsa'
    assert_output --partial 'rsa'
}

@test "setup_secrets token offers set/get" {
    run _compl setup_secrets.fish 'setup_secrets token '
    assert_success
    assert_output --partial 'set'
    assert_output --partial 'get'
}

# ── 2d. just recipe-arg completion (scoped to tui / secrets) ─────────────────

@test "just tui '-' offers --backend --lang --help --version" {
    run _compl just.fish 'just tui -'
    assert_success
    assert_output --partial '--backend'
    assert_output --partial '--lang'
    assert_output --partial '--help'
    assert_output --partial '--version'
}

@test "just tui --lang completes en zh-TW" {
    run _compl just.fish 'just tui --lang '
    assert_success
    assert_output --partial 'en'
    assert_output --partial 'zh-TW'
}

@test "just tui --backend completes fzf whiptail gum" {
    run _compl just.fish 'just tui --backend '
    assert_success
    assert_output --partial 'fzf'
    assert_output --partial 'whiptail'
    assert_output --partial 'gum'
}

@test "just secrets offers the secrets subcommands" {
    run _compl just.fish 'just secrets '
    assert_success
    assert_output --partial 'ssh-key'
    assert_output --partial 'token'
    assert_output --partial 'gpg'
}
