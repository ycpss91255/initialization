#!/usr/bin/env bats
# test/unit/small_tools_tldr_spec.bats — small-tools/{install,remove}.sh tldr fix
#
# Issue #263: tealdeer cache never installs — `tldr --update` fails inside the
# long `&&` chain and aborts the rest of install.sh. These specs encode the
# acceptance criteria as static-content assertions (the installers run apt/sudo
# and cannot be executed in a unit sandbox), guarding against regressions:
#   - the cache update is decoupled from the `&&` chain (non-fatal)
#   - a curl + unzip fallback seeds the correct tealdeer cache dir
#   - the wrong ~/.local/share/tldr layout is dropped
#   - the always-true `[ -n "<literal>" ]` guards become real path tests
#   - the tealdeer package is pinned (not the mismatched `tldr` package)
#   - the fish completion is installed where fish actually scans

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    INSTALL_SH="${REPO_ROOT}/small-tools/install.sh"
    REMOVE_SH="${REPO_ROOT}/small-tools/remove.sh"
    export INSTALL_SH REMOVE_SH
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "small-tools install.sh parses (bash -n)" {
    run bash -n "${INSTALL_SH}"
    assert_success
}

@test "small-tools remove.sh parses (bash -n)" {
    run bash -n "${REMOVE_SH}"
    assert_success
}

# ── AC1: cache update decoupled from the && chain (non-fatal) ────────────────

@test "install.sh does not chain 'tldr --update' with '&&' (would abort tail)" {
    run grep -nE 'tldr --update[[:space:]]*&&' "${INSTALL_SH}"
    assert_failure
}

@test "install.sh guards 'tldr --update' so a failure is non-fatal" {
    run grep -qE 'if ! tldr --update|tldr --update[[:space:]]*\|\|' "${INSTALL_SH}"
    assert_success
}

# ── AC2: curl + unzip fallback into the real tealdeer cache dir ──────────────

@test "install.sh has a release-zip fallback URL" {
    run grep -q 'releases/latest/download/tldr.zip' "${INSTALL_SH}"
    assert_success
}

@test "install.sh unzips the fallback into ~/.cache/tealdeer/tldr-pages" {
    run grep -q '.cache/tealdeer/tldr-pages' "${INSTALL_SH}"
    assert_success
    run grep -q 'unzip' "${INSTALL_SH}"
    assert_success
}

# ── AC3: drop the wrong ~/.local/share/tldr layout ──────────────────────────

@test "install.sh no longer touches the old ~/.local/share/tldr layout" {
    run grep -q '.local/share/tldr' "${INSTALL_SH}"
    assert_failure
}

@test "remove.sh no longer touches the old ~/.local/share/tldr layout" {
    run grep -q '.local/share/tldr' "${REMOVE_SH}"
    assert_failure
}

@test "remove.sh removes the real tealdeer cache dir" {
    run grep -q '.cache/tealdeer' "${REMOVE_SH}"
    assert_success
}

# ── AC4: no always-true `[ -n/-z "<literal>" ]` guards ──────────────────────

@test "install.sh has no always-true string-literal test guards" {
    run grep -nE '\[ -[nz] "/home' "${INSTALL_SH}"
    assert_failure
}

# ── AC5: pin tealdeer, not the mismatched `tldr` apt package ─────────────────

@test "install.sh installs the tealdeer apt package" {
    run grep -qE '^[[:space:]]*tealdeer[[:space:]]*\\?' "${INSTALL_SH}"
    assert_success
}

@test "install.sh no longer installs the mismatched 'tldr' apt package" {
    run grep -qE '^[[:space:]]*tldr[[:space:]]*\\?[[:space:]]*$' "${INSTALL_SH}"
    assert_failure
}

@test "remove.sh purges tealdeer, not the mismatched 'tldr' package" {
    run grep -qE '^[[:space:]]*tealdeer[[:space:]]*\\?' "${REMOVE_SH}"
    assert_success
    run grep -qE '^[[:space:]]*tldr[[:space:]]*\\?[[:space:]]*$' "${REMOVE_SH}"
    assert_failure
}

# ── AC6: install the fish completion where fish scans ────────────────────────

@test "install.sh installs the tldr fish completion into ~/.config/fish/completions" {
    run grep -q '.config/fish/completions/tldr.fish' "${INSTALL_SH}"
    assert_success
}
