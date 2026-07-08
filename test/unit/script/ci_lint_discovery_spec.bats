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
