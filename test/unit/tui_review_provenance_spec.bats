#!/usr/bin/env bats
# test/unit/tui_review_provenance_spec.bats — Review dependency provenance (#214)
# + Quick Setup pre-install summary (#213), e2e against scripted widgets.
#
# Covers:
#   - The Review screen shows per-item provenance ("(your selection)" vs
#     "(required by X)") for a fixture where a pick pulls a dep via depends_on
#     (NOT a flat "+N deps" count).
#   - The Quick Setup pre-install summary lists picks + pulled deps before the
#     install is forked.
#   - The forked install command string is UNCHANGED (byte-identical argv) —
#     the AC-10 guarantee: only what the screens DISPLAY changed.
#
# HOST-SAFETY: every fork is a recorded mock; no real dialog/whiptail, no real
# setup_ubuntu, no host writes outside the test scratch.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    setup_test_env
    export LC_ALL=C.UTF-8
}

teardown() {
    teardown_test_env
}

# Fixture where docker depends_on apt-essentials, so picking docker genuinely
# pulls apt-essentials — the provenance must attribute it to docker.
_PROV_FIXTURE_LIST='{
  "schema_version": "1", "scope": "available",
  "filters": {"category": null, "tag": null},
  "items": [
    {"name": "apt-essentials", "category": "base", "tags": ["core"],
     "description": "Foundation apt packages", "version_provided": "apt-managed",
     "installed": false, "outdated": null, "manual": null, "depends_on": [],
     "supports_user_home": false, "supported_platforms": ["desktop","server"],
     "supported_ubuntu": ["24.04"], "risk_level": "low",
     "reboot_required": false, "homepage": null},
    {"name": "docker", "category": "recommended", "tags": ["container"],
     "description": "Docker Engine", "version_provided": "apt-managed",
     "installed": false, "outdated": null, "manual": null,
     "depends_on": ["apt-essentials"], "supports_user_home": false,
     "supported_platforms": ["desktop","server"], "supported_ubuntu": ["24.04"],
     "risk_level": "low", "reboot_required": false, "homepage": null,
     "recommended": true}
  ], "count": 2, "generated_at": "2026-06-07T00:00:00+08:00"
}'

_PROV_FIXTURE_DETECT='{"os":{"id":"ubuntu","version":"24.04","codename":"noble"},"arch":"x86_64","cpu":{"vendor":"GenuineIntel"},"gpu":{"vendor":"nvidia","model":"x"},"desktop":"GNOME","session_type":"x11","virt":{"container":false,"vm":false},"wsl":false,"board":null,"form_factor":"desktop"}'

# Scripted widget + recording mock CLI. The dry-run emits the resolver order
# (apt-essentials before docker), mirroring docker's depends_on.
_make_prov_harness() {
    local _dir="${INIT_UBUNTU_TEST_SCRATCH}/prov"
    mkdir -p "${_dir}/bin" "${_dir}/home"
    E2E_BIN="${_dir}/bin"
    E2E_HOME="${_dir}/home"
    E2E_RESPONSES="${_dir}/responses"
    E2E_WIDGET_LOG="${_dir}/widget.log"
    E2E_CLI_LOG="${_dir}/cli.log"
    export E2E_BIN E2E_HOME E2E_RESPONSES E2E_WIDGET_LOG E2E_CLI_LOG

    printf '%s\n' "${_PROV_FIXTURE_LIST}"   >"${_dir}/list.json"
    printf '%s\n' "${_PROV_FIXTURE_DETECT}" >"${_dir}/detect.json"

    cat >"${E2E_BIN}/dialog" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${E2E_WIDGET_LOG}"
_line="\$(head -n1 "${E2E_RESPONSES}")"
sed -i 1d "${E2E_RESPONSES}"
_rc="\${_line%%|*}"
_out="\${_line#*|}"
[[ -n "\${_out}" ]] && printf '%b' "\${_out}" >&2
exit "\${_rc}"
EOF
    cat >"${E2E_BIN}/setup_ubuntu" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${E2E_CLI_LOG}"
case "\$*" in
    "list --json")   cat "${_dir}/list.json" ;;
    "detect --json") cat "${_dir}/detect.json" ;;
    "config set "*)  : ;;
    "install --dry-run "*)
        printf '[dispatcher] DRY-RUN: would install in this order:\n'
        printf '  - apt-essentials\n  - docker\n'
        ;;
    "install "*) printf 'CLI pipeline output\n' ;;
esac
EOF
    chmod +x "${E2E_BIN}/dialog" "${E2E_BIN}/setup_ubuntu"
}

_run_prov_e2e() {
    run env "PATH=${E2E_BIN}:${PATH}" "HOME=${E2E_HOME}" \
        "TUI_CLI=${E2E_BIN}/setup_ubuntu" \
        "TUI_BACKEND=${E2E_BIN}/dialog" \
        "${REPO_ROOT}/setup_ubuntu_tui.sh"
}

# ── Run-path Review screen: per-item provenance ──────────────────────────────

@test "e2e review: shows '(your selection)' and '(required by docker)'" {
    _make_prov_harness
    # recommended page → check docker → Run → Review (read body) → proceed.
    cat >"${E2E_RESPONSES}" <<'EOF'
0|recommended
0|docker\n
0|run
0|proceed
EOF
    _run_prov_e2e
    assert_success
    # The Review menu body (rendered by tui_review_text) carries per-item
    # provenance — these strings only ever come from the Review screen.
    run cat "${E2E_WIDGET_LOG}"
    assert_output --partial "docker (your selection)"
    assert_output --partial "apt-essentials (required by docker)"
    # #214: the Review menu line itself replaced the flat "+N deps" count with
    # the per-item listing (the category-checklist row's own hint is a separate
    # screen and out of scope here; tui_review_text's unit test guards the body).
    run grep -- "--title Review & Install" "${E2E_WIDGET_LOG}"
    refute_output --partial "will pull"
}

@test "e2e review: forked install argv is unchanged (byte-identical, AC-10)" {
    _make_prov_harness
    cat >"${E2E_RESPONSES}" <<'EOF'
0|recommended
0|docker\n
0|run
0|proceed
EOF
    _run_prov_e2e
    assert_success
    assert_output --partial "CLI pipeline output"
    # The display changed; the argv did NOT — only the user-picked module is
    # named (apt-essentials stays an engine-pulled dep, never on argv).
    run tail -n1 "${E2E_CLI_LOG}"
    assert_output "install docker -y"
}

# ── Quick Setup pre-install summary (#213) ───────────────────────────────────

@test "e2e qs summary: lists picks AND pulled deps before the fork" {
    _make_prov_harness
    # quick-setup → Step1 continue → Step2 keep docker. Steps 3/4 have no rows
    # in this fixture (no cli-essentials / agent modules) so they fork no widget
    # and pop no response. Review proceed → pre-install summary → Yes.
    cat >"${E2E_RESPONSES}" <<'EOF'
0|quick-setup
0|continue
0|docker\n
0|proceed
0|
EOF
    _run_prov_e2e
    assert_success
    assert_output --partial "CLI pipeline output"
    # The summary widget body listed every module that will be installed.
    run cat "${E2E_WIDGET_LOG}"
    assert_output --partial "Pre-install Summary"
    assert_output --partial "docker (your selection)"
    assert_output --partial "apt-essentials (required by docker)"
}

@test "e2e qs summary: decline at the summary forks no install (pure cancel)" {
    _make_prov_harness
    # ...same prepare, but answer No (rc 1) at the pre-install summary. The QS
    # picks are function-local, so the main-menu Exit needs no guard prompt.
    cat >"${E2E_RESPONSES}" <<'EOF'
0|quick-setup
0|continue
0|docker\n
0|proceed
1|
1|
EOF
    _run_prov_e2e
    assert_success
    # Dry-run plan forks are read-only and allowed; a REAL install is not.
    run grep -E "^install ([^-]|-[^-])" "${E2E_CLI_LOG}"
    assert_failure
}
