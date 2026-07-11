#!/usr/bin/env bats
# test/unit/small_tools_deprecation_spec.bats — PRD section 6.6
#
# The legacy small-tools bundle (small-tools/{install,remove}.sh and
# module/setup_small_tools.sh) is superseded by the v2 setup_ubuntu engine +
# module/*.module.sh. PRD section 6.6 schedules a deprecation notice for the
# 0.2.0 line and removal for 0.4.0 (AC-27). These tests encode that each legacy
# entrypoint (a) carries a DEPRECATED header, (b) emits a runtime deprecation
# WARNING, (c) points users at the v2 engine, and (d) still parses (the notice
# must not break the script).
#
# NOTE: these scripts run apt / sudo and rm -rf on $HOME as their first side
# effects, so they cannot be executed to completion in the unit sandbox. Like
# the existing small_tools_tldr_spec.bats / fastfetch_migration_spec.bats, the
# assertions are static (grep + `bash -n` parse), which is the established
# discipline for the small-tools legacy layer (it is excluded from the CI
# static-analysis lint scope).

load "${BATS_TEST_DIRNAME}/../helper/common"

INSTALL_SH="${REPO_ROOT}/small-tools/install.sh"
REMOVE_SH="${REPO_ROOT}/small-tools/remove.sh"
SETUP_SMALL_TOOLS="${REPO_ROOT}/module/setup_small_tools.sh"
README_EN="${REPO_ROOT}/small-tools/README.adoc"
README_ZH="${REPO_ROOT}/small-tools/README_zh.adoc"

# ── header + runtime notice: small-tools/install.sh ─────────────────────────

@test "install.sh carries a DEPRECATED header citing PRD section 6.6" {
    grep -q 'DEPRECATED (PRD section 6.6' "${INSTALL_SH}"
}

@test "install.sh emits a runtime deprecation WARNING to stderr" {
    grep -qE 'WARNING: small-tools/install.sh is DEPRECATED' "${INSTALL_SH}"
    grep -q '>&2' "${INSTALL_SH}"
}

@test "install.sh points users at the v2 engine (install --base)" {
    grep -q 'setup_ubuntu.sh install --base' "${INSTALL_SH}"
}

@test "install.sh still parses (bash -n)" {
    run bash -n "${INSTALL_SH}"
    [ "${status}" -eq 0 ]
}

# ── header + runtime notice: small-tools/remove.sh ──────────────────────────

@test "remove.sh carries a DEPRECATED header citing PRD section 6.6" {
    grep -q 'DEPRECATED (PRD section 6.6' "${REMOVE_SH}"
}

@test "remove.sh emits a runtime deprecation WARNING to stderr" {
    grep -qE 'WARNING: small-tools/remove.sh is DEPRECATED' "${REMOVE_SH}"
    grep -q '>&2' "${REMOVE_SH}"
}

@test "remove.sh points users at the v2 engine (remove/purge)" {
    grep -q 'setup_ubuntu.sh remove <module>' "${REMOVE_SH}"
}

@test "remove.sh still parses (bash -n)" {
    run bash -n "${REMOVE_SH}"
    [ "${status}" -eq 0 ]
}

# ── header + runtime notice: module/setup_small_tools.sh ────────────────────

@test "setup_small_tools.sh carries a DEPRECATED header citing PRD section 6.6" {
    grep -q 'DEPRECATED (PRD section 6.6' "${SETUP_SMALL_TOOLS}"
}

@test "setup_small_tools.sh emits a runtime deprecation warning via log_warn" {
    grep -qE 'log_warn "setup_small_tools.sh is DEPRECATED' "${SETUP_SMALL_TOOLS}"
}

@test "setup_small_tools.sh points users at the v2 engine (install --base)" {
    grep -q "setup_ubuntu install --base" "${SETUP_SMALL_TOOLS}"
}

@test "setup_small_tools.sh still parses (bash -n)" {
    run bash -n "${SETUP_SMALL_TOOLS}"
    [ "${status}" -eq 0 ]
}

# ── README deprecation banners ──────────────────────────────────────────────

@test "README.adoc carries a deprecation banner pointing to the v2 engine" {
    grep -q 'DEPRECATED (PRD section 6.6' "${README_EN}"
    grep -q 'setup_ubuntu.sh install --base' "${README_EN}"
}

@test "README_zh.adoc carries a deprecation banner pointing to the v2 engine" {
    grep -q 'PRD 第 6.6 節' "${README_ZH}"
    grep -q 'setup_ubuntu.sh install --base' "${README_ZH}"
}
