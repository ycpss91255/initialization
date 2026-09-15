#!/usr/bin/env bats
# test/unit/script/ci_lint_discovery_spec.bats
#
# Regression guard for the fish lint discovery in `script/ci/ci.sh`.
#
# Bug: `_find_lintable_fish` pruned `module/config` wholesale (copied from
# the ShellCheck pass, where those .sh files are vendored third-party
# config). But EVERY tracked *.fish file lives under module/config/fish/**
# (the maintainer's own fish config that init_ubuntu installs), so the
# prune dropped 100% of them — the fish syntax check ran over ZERO files
# and was silently a no-op.
#
# These tests source ci.sh (its `main` guard means sourcing only defines
# functions) and exercise `_find_lintable_fish` against the REAL repo, so
# the discovery can never regress back to 0 without turning this spec red.

load "${BATS_TEST_DIRNAME}/../../helper/common"

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

# ── ShellCheck discovery (gitignore-scoped file selection) ────────────────────
#
# Bug: `_find_lintable_sh` collected *.sh/*.bash/*.bats with a raw `find`, which
# also caught machine-local third-party skills installed under .agents/skills/
# (gitignored per the #150 skill-layout block). The lint then failed on files
# the repo does not own (e.g. .agents/skills/wizard/template.sh: SC2034). The
# fix intersects the find candidates with the git-visible set
# (`git ls-files --cached --others --exclude-standard`), so gitignored files are
# excluded while every repo-owned script — tracked or newly-added-untracked —
# is still linted.

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

@test "sh discovery EXCLUDES gitignored third-party skills under .agents/skills" {
    run bash -c "REPO_ROOT='${REPO_ROOT}' _discover_sh"
    assert_success
    # The machine-local third-party skill that triggered the lint failure.
    refute_output --partial ".agents/skills/wizard/template.sh"
    # Any other installed (gitignored) skill scripts stay excluded too.
    refute_output --partial ".agents/skills/git-guardrails-claude-code/"
    refute_output --partial ".agents/skills/diagnosing-bugs/"
}

@test "sh discovery still excludes vendored + holding trees" {
    run bash -c "REPO_ROOT='${REPO_ROOT}' _discover_sh"
    assert_success
    # Deprecated legacy install tree + one-off script holding area stay pruned.
    refute_output --partial "small-tools/"
    refute_output --partial "${REPO_ROOT}/tool/"
}
