#!/usr/bin/env bats
# test/unit/fastfetch_migration_spec.bats — issue #325
#
# neofetch is archived upstream (dylanaraps/neofetch, archived 2024-07-19);
# fastfetch (fastfetch-cli/fastfetch) is the actively-maintained drop-in
# replacement. These tests encode the acceptance criteria: the small-tools
# tooling installs/removes fastfetch in place of neofetch, the docs no longer
# name neofetch as a live tool, and no stale `neofetch` reference survives.

load "${BATS_TEST_DIRNAME}/../helper/common"

SMALL_TOOLS_DIR="${REPO_ROOT}/small-tools"
SETUP_SMALL_TOOLS="${REPO_ROOT}/module/setup_small_tools.sh"

# Assert a file does NOT contain the whole word `neofetch`.
# (`run ! grep` needs bats >= 1.5.0; the run + status check is portable.)
_refute_neofetch() {
    run grep -qw neofetch "${1:?file required}"
    [ "${status}" -ne 0 ]
}

# ── small-tools legacy bundle scripts ───────────────────────────────────────

@test "small-tools/install.sh installs fastfetch, not neofetch" {
    grep -qE '^\s*fastfetch\b' "${SMALL_TOOLS_DIR}/install.sh"
    _refute_neofetch "${SMALL_TOOLS_DIR}/install.sh"
}

@test "small-tools/install.sh adds the fastfetch PPA (not in noble repos)" {
    grep -q 'ppa:zhangsongcui3371/fastfetch' "${SMALL_TOOLS_DIR}/install.sh"
}

@test "small-tools/remove.sh purges fastfetch, not neofetch" {
    grep -qE '^\s*fastfetch\b' "${SMALL_TOOLS_DIR}/remove.sh"
    _refute_neofetch "${SMALL_TOOLS_DIR}/remove.sh"
}

# ── module/setup_small_tools.sh ─────────────────────────────────────────────

@test "module/setup_small_tools.sh references fastfetch, not neofetch" {
    grep -q fastfetch "${SETUP_SMALL_TOOLS}"
    _refute_neofetch "${SETUP_SMALL_TOOLS}"
}

@test "module/setup_small_tools.sh installs fastfetch via a dedicated function" {
    grep -qE '^\s*_install_fastfetch\s*$' "${SETUP_SMALL_TOOLS}"
    grep -qE '^function _install_fastfetch\(\)' "${SETUP_SMALL_TOOLS}"
}

# ── docs ────────────────────────────────────────────────────────────────────

@test "README docs name fastfetch, not neofetch" {
    _refute_neofetch "${REPO_ROOT}/README.adoc"
    _refute_neofetch "${SMALL_TOOLS_DIR}/README.adoc"
    _refute_neofetch "${SMALL_TOOLS_DIR}/README_zh.adoc"
}

# ── repo-wide hygiene ───────────────────────────────────────────────────────

@test "no un-annotated neofetch reference survives anywhere in the repo" {
    # Per issue #325: `grep -rn neofetch` must be clean, EXCEPT intentional
    # historical mentions explicitly noted as legacy. So we flag only neofetch
    # lines that carry no legacy/retirement marker. This spec itself is excluded
    # (it must name the retired tool to describe what it enforces).
    run bash -c "grep -rIn --exclude-dir=.git \
        --exclude=fastfetch_migration_spec.bats neofetch '${REPO_ROOT}' \
        | grep -viE 'archived|retired|legacy|replaces|not neofetch|historical'"
    [ "${status}" -ne 0 ] || {
        printf 'un-annotated neofetch references:\n%s\n' "${output}" >&2
        return 1
    }
}
