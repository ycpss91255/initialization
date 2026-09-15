#!/usr/bin/env bats
# test/unit/script/ci_lint_discovery_spec.bats
#
# Regression guards for the lint file discovery in `script/ci/ci.sh`.
#
# Fish bug: `_find_lintable_fish` pruned `module/config` wholesale (copied
# from the ShellCheck pass, where those .sh files are vendored third-party
# config). But EVERY tracked *.fish file lives under module/config/fish/**
# (the maintainer's own fish config that init_ubuntu installs), so the
# prune dropped 100% of them — the fish syntax check ran over ZERO files
# and was silently a no-op.
#
# These tests source ci.sh (its `main` guard means sourcing only defines
# functions) and exercise `_find_lintable_fish` against the REAL repo, so
# the discovery can never regress back to 0 without turning this spec red.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() { setup_test_env; }
teardown() { teardown_test_env; }

# Emit the fish discovery as newline-delimited paths (from its NUL stream).
_discover_fish() {
    # shellcheck source=/dev/null  # real ci.sh; sourcing only defines funcs
    source "${REPO_ROOT}/script/ci/ci.sh"
    _find_lintable_fish | tr '\0' '\n'
}
export -f _discover_fish

# Emit the ShellCheck discovery as newline-delimited paths (from its NUL stream).
_discover_sh() {
    # shellcheck source=/dev/null  # real ci.sh; sourcing only defines funcs
    source "${REPO_ROOT}/script/ci/ci.sh"
    _find_lintable_sh | tr '\0' '\n'
}
export -f _discover_sh

@test "fish discovery finds a NONZERO number of fish files over the repo" {
    run bash -c "REPO_ROOT='${REPO_ROOT}' _discover_fish | grep -c '\.fish$'"
    assert_success
    # Before the fix this was exactly 0 (module/config was pruned).
    [ "${output}" -gt 0 ]
}

@test "fish discovery includes the maintainer's fish config under module/config/fish" {
    run bash -c "REPO_ROOT='${REPO_ROOT}' _discover_fish"
    assert_success
    assert_line --partial "module/config/fish/config.fish"
    assert_line --partial "module/config/fish/functions/docker-run.fish"
}

@test "fish discovery still excludes vendored + legacy fish paths" {
    run bash -c "REPO_ROOT='${REPO_ROOT}' _discover_fish"
    assert_success
    # fnm-generated shell integration (vendored) stays pruned.
    refute_output --partial "fnm_shell_config"
    # Deprecated legacy install tree stays pruned.
    refute_output --partial "small-tools/"
}

# ── ShellCheck discovery: real-repo smoke ────────────────────────────────────
#
# Bug: `_find_lintable_sh` collected *.sh/*.bash/*.bats with a raw `find`, which
# also caught machine-local third-party skills installed under .agents/skills/
# (gitignored per the #150 skill-layout block). The lint then failed on files
# the repo does not own (e.g. .agents/skills/wizard/template.sh: SC2034). The
# fix intersects the find candidates with the git-visible set
# (`git ls-files --cached --others --exclude-standard`), so gitignored files are
# excluded while every repo-owned script — tracked or newly-added-untracked —
# is still linted.
#
# The real-repo checks below only prove the discovery is alive and the prunes
# hold; they cannot prove the gitignore scoping (a clean CI checkout has no
# machine-local files to exclude, so a raw `find` would pass them too). The
# fixture section further down is the actual regression guard.

@test "sh discovery finds a NONZERO number of shell scripts over the repo" {
    run bash -c "REPO_ROOT='${REPO_ROOT}' _discover_sh | grep -cE '\.(sh|bash|bats)$'"
    assert_success
    # The git safety valve falls back to raw find output when git is
    # unavailable, so this stays nonzero in every environment.
    [ "${output}" -gt 0 ]
}

@test "sh discovery includes repo-owned tracked scripts" {
    run bash -c "REPO_ROOT='${REPO_ROOT}' _discover_sh"
    assert_success
    # ci.sh lints itself; a tracked, non-pruned script must still be selected.
    assert_line --partial "script/ci/ci.sh"
}

@test "sh discovery still excludes vendored + holding trees" {
    run bash -c "REPO_ROOT='${REPO_ROOT}' _discover_sh"
    assert_success
    # Deprecated legacy install tree + one-off script holding area stay pruned.
    refute_output --partial "small-tools/"
    refute_output --partial "${REPO_ROOT}/tool/"
}

# ── ShellCheck discovery: throwaway git-repo fixture ─────────────────────────
#
# Hermetic guard for the git-visible intersection. Each test builds its own
# repo under $BATS_TEST_TMPDIR with every shape `_find_lintable_sh`
# discriminates on, then runs the REAL function against it:
#
#   lib/tracked.sh, lib/tracked.bash, test/tracked_spec.bats  tracked
#   lib/forced.local.sh        tracked (add -f) AND matches the *.local.sh
#                              ignore pattern -> tracked wins, still linted
#   lib/untracked.sh           untracked, NOT ignored -> linted
#   .agents/skills/repo-owned/run.sh   tracked via the !negation -> linted
#   .agents/skills/third-party/template.sh   present on disk, gitignored
#                              (the #150 machine-local skill shape) -> EXCLUDED
#   small-tools/legacy.sh, tool/oneoff.sh   tracked but in a prune dir -> EXCLUDED
#
# ci.sh derives REPO_ROOT (readonly) from its own location, so the fixture
# carries a copy at <fixture>/script/ci/ci.sh; sourcing THAT copy is what roots
# the discovery at the fixture instead of the real repo.

_FIXTURE_SCRIPTS=(
    lib/tracked.sh lib/tracked.bash test/tracked_spec.bats
    lib/forced.local.sh .agents/skills/repo-owned/run.sh
    small-tools/legacy.sh tool/oneoff.sh
)

# _make_fixture [git|plain] — build the layout above under $BATS_TEST_TMPDIR
# and (default `git`) turn it into a committed work tree. Sets FIXTURE.
_make_fixture() {
    local _mode="${1:-git}" _f
    FIXTURE="${BATS_TEST_TMPDIR}/fixture"
    mkdir -p "${FIXTURE}/script/ci" "${FIXTURE}/lib" "${FIXTURE}/test" \
        "${FIXTURE}/.agents/skills/repo-owned" \
        "${FIXTURE}/.agents/skills/third-party" \
        "${FIXTURE}/small-tools" "${FIXTURE}/tool"
    cp "${REPO_ROOT}/script/ci/ci.sh" "${FIXTURE}/script/ci/ci.sh"
    for _f in "${_FIXTURE_SCRIPTS[@]}"; do
        printf '#!/usr/bin/env bash\ntrue\n' > "${FIXTURE}/${_f}"
    done
    # Mirrors the real .gitignore #150 block: everything under .agents/skills/
    # is machine-local except the negated repo-owned entries.
    printf '%s\n' '.agents/skills/*' '!.agents/skills/repo-owned' '*.local.sh' \
        > "${FIXTURE}/.gitignore"

    if [[ "${_mode}" == "git" ]]; then
        git init -q -b main "${FIXTURE}"
        git -C "${FIXTURE}" config user.email t@e.st
        git -C "${FIXTURE}" config user.name tester
        git -C "${FIXTURE}" add -A
        # Tracked despite matching an ignore pattern (tracked wins over ignore).
        git -C "${FIXTURE}" add -f lib/forced.local.sh
        git -C "${FIXTURE}" commit -q -m fixture
    fi

    # Written AFTER the commit so they are on disk only: one repo-owned
    # (untracked, not ignored) and one machine-local (gitignored) script.
    printf '#!/usr/bin/env bash\ntrue\n' > "${FIXTURE}/lib/untracked.sh"
    printf '#!/usr/bin/env bash\ntrue\n' \
        > "${FIXTURE}/.agents/skills/third-party/template.sh"
}

# Emit the ShellCheck discovery of the ci.sh copy under $FIXTURE_ROOT as
# fixture-relative paths, one per line (REPO_ROOT here is the fixture's own
# readonly value set by the sourced copy, so the strip is exact).
_discover_sh_in_fixture() {
    # shellcheck source=/dev/null  # fixture copy of ci.sh; sourcing only defines funcs
    source "${FIXTURE_ROOT}/script/ci/ci.sh"
    local _f
    while IFS= read -r -d '' _f; do
        printf '%s\n' "${_f#"${REPO_ROOT}/"}"
    done < <(_find_lintable_sh)
}
export -f _discover_sh_in_fixture

_run_fixture_discovery() {
    run bash -c "FIXTURE_ROOT='${FIXTURE}' _discover_sh_in_fixture"
    assert_success
}

@test "fixture: tracked scripts are selected, including one that also matches a .gitignore pattern" {
    _make_fixture
    _run_fixture_discovery
    assert_line "lib/tracked.sh"
    # The git pathspec must cover every extension the find clause does.
    assert_line "lib/tracked.bash"
    assert_line "test/tracked_spec.bats"
    # Tracked wins over ignore: `git add -f` + a matching *.local.sh rule.
    assert_line "lib/forced.local.sh"
    # A repo-owned skill negated back in under .agents/skills/ is linted.
    assert_line ".agents/skills/repo-owned/run.sh"
}

@test "fixture: an untracked but NOT-ignored script is selected" {
    _make_fixture
    _run_fixture_discovery
    assert_line "lib/untracked.sh"
}

@test "fixture: a gitignored script present on disk is EXCLUDED" {
    _make_fixture
    _run_fixture_discovery
    # RED without the git intersection: a raw find returns this file.
    refute_line ".agents/skills/third-party/template.sh"
    # Sanity: the exclusion is per-file, not a wholesale skills prune.
    assert_line ".agents/skills/repo-owned/run.sh"
}

@test "fixture: tracked scripts under prune dirs (small-tools/, tool/) stay EXCLUDED" {
    _make_fixture
    _run_fixture_discovery
    refute_line "small-tools/legacy.sh"
    refute_line "tool/oneoff.sh"
    refute_line --partial "small-tools/"
    refute_line --partial "tool/"
}

@test "fixture: NOT a git work tree -> falls back to raw find, prunes still apply" {
    _make_fixture plain
    _run_fixture_discovery
    # Nothing is git-visible, so the safety valve lints everything find
    # returns (including what git WOULD have ignored) rather than nothing.
    assert_line "lib/tracked.sh"
    assert_line "lib/untracked.sh"
    assert_line "lib/forced.local.sh"
    assert_line ".agents/skills/third-party/template.sh"
    refute_line --partial "small-tools/"
    refute_line --partial "tool/"
}

@test "fixture: git unavailable on PATH -> falls back to raw find, prunes still apply" {
    _make_fixture
    # A `git` shim that fails like a missing binary shadows the real one for
    # the discovery only (the fixture above was built with the real git).
    local _shim="${BATS_TEST_TMPDIR}/nogit"
    mkdir -p "${_shim}"
    printf '#!/bin/sh\nexit 127\n' > "${_shim}/git"
    chmod +x "${_shim}/git"
    run bash -c "PATH='${_shim}:${PATH}' FIXTURE_ROOT='${FIXTURE}' _discover_sh_in_fixture"
    assert_success
    assert_line "lib/tracked.sh"
    assert_line "lib/untracked.sh"
    assert_line ".agents/skills/third-party/template.sh"
    refute_line --partial "small-tools/"
    refute_line --partial "tool/"
}
