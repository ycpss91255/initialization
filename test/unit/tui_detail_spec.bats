#!/usr/bin/env bats
# test/unit/tui_detail_spec.bats — module detail view (#211 part 2, #215)
#
# #211 part 2 (PRD §8, G4): a READ-ONLY detail view (msgbox) that shows the
# full `setup_ubuntu show <module> --json` data — description, category, tags,
# depends_on, conflicts, supported_ubuntu, supported_platforms — reachable
# from the category checklists AND from Manage Installed. The engine
# `show --json` already exists (lib/dispatcher.sh). The TUI forks it (G4: no
# engine lib sourced) and parses the payload with jq.
#
# #215 (Manage Installed clarity): a state.json entry whose module is no longer
# in the catalog (registry/list --json) must render CLEARLY as "(unregistered)"
# instead of a bare row, and its detail action must show the state.json facts
# plus a "not in current catalog" note (the show --json fork fails rc!=0 for it).
#
# HOST-SAFETY: every fork target is a recording mock (TUI_CLI / scripted dialog
# binary); fixtures are inline JSON, never live state.

load "${BATS_TEST_DIRNAME}/../helper/common"
load "${BATS_TEST_DIRNAME}/../helper/tui_harness"

# shellcheck source=../../lib/tui_backend.sh
source "${LIB_DIR}/tui_backend.sh"

setup() {
    setup_test_env
    unset TUI_BACKEND 2>/dev/null || true
}

teardown() {
    teardown_test_env
}

# ── Fixtures ─────────────────────────────────────────────────────────────────
# `show <module> --json` payload (ADR-0019 / #211 schema): exactly the fields
# the detail view renders.

FIXTURE_SHOW_JSON="$(cat <<'EOF'
{
  "name": "docker",
  "category": "recommended",
  "description": "Docker Engine and CLI",
  "tags": ["container", "devops"],
  "depends_on": ["curl"],
  "conflicts": ["podman"],
  "supported_ubuntu": ["22.04", "24.04"],
  "supported_platforms": ["desktop", "server"]
}
EOF
)"

# A module with empty arrays + null description (additive fields optional).
FIXTURE_SHOW_SPARSE_JSON="$(cat <<'EOF'
{
  "name": "neovim",
  "category": "recommended",
  "description": null,
  "tags": [],
  "depends_on": [],
  "conflicts": [],
  "supported_ubuntu": ["24.04"],
  "supported_platforms": []
}
EOF
)"

# state.json with an unregistered entry ("ghost" — no module file / not in the
# catalog) plus a normal one. version_provided "unknown" is the legitimate
# state default (lib/state.sh / lib/runner.sh write it when a module exports no
# VERSION_PROVIDED) — NOT a stale artifact.
FIXTURE_STATE_JSON="$(cat <<'EOF'
{
  "version": "0.1.0",
  "installed": {
    "docker": {
      "synced": {"manual": true, "depends_on": ["curl"], "version_provided": "27.4.0",
                 "installed_at": "2026-05-13T14:22:00+08:00", "installed_by": "cli"},
      "local": {}
    },
    "ghost": {
      "synced": {"manual": false, "depends_on": [], "version_provided": "unknown",
                 "installed_at": "2026-05-13T14:31:00+08:00", "installed_by": "cli"},
      "local": {}
    }
  }
}
EOF
)"

FIXTURE_LIST_JSON="$(cat <<'EOF'
{
  "schema_version": "1",
  "scope": "available",
  "filters": {"category": null, "tag": null},
  "items": [
    {"name": "docker", "category": "recommended", "tags": ["container"],
     "description": "Docker Engine", "version_provided": "apt-managed",
     "installed": true, "outdated": false, "manual": true,
     "depends_on": ["curl"], "supports_user_home": false,
     "supported_platforms": ["desktop", "server"], "supported_ubuntu": ["24.04"],
     "risk_level": "low", "reboot_required": false, "homepage": null},
    {"name": "neovim", "category": "recommended", "tags": ["editor"],
     "description": "Neovim editor", "version_provided": "v0.10.2",
     "installed": false, "outdated": null, "manual": null,
     "depends_on": null, "supports_user_home": true,
     "supported_platforms": ["desktop", "server", "wsl"], "supported_ubuntu": ["24.04"],
     "risk_level": "low", "reboot_required": false, "homepage": null}
  ],
  "count": 2,
  "generated_at": "2026-06-07T00:00:00+08:00"
}
EOF
)"

FIXTURE_DETECT_JSON='{"os":{"id":"ubuntu","version":"24.04","codename":"noble"},"arch":"x86_64","cpu":{"vendor":"GenuineIntel"},"gpu":{"vendor":null,"model":null},"desktop":null,"session_type":"tty","virt":{"container":false,"vm":false},"wsl":false,"board":null,"form_factor":"server"}'

# ── tui_cli_show_json (G4 fork: show <module> --json) ────────────────────────

_make_mock_show_cli() {
    MOCK_CLI_LOG="${INIT_UBUNTU_TEST_SCRATCH}/cli.log"
    TUI_CLI="${INIT_UBUNTU_TEST_SCRATCH}/mock_setup_ubuntu"
    export MOCK_CLI_LOG TUI_CLI
    cat >"${TUI_CLI}" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${MOCK_CLI_LOG}"
case "\$*" in
    "show docker --json") printf '%s\n' ${FIXTURE_SHOW_JSON@Q} ;;
    "show "*"--json")
        printf '[dispatcher] ERROR: unknown module\n' >&2
        exit 2
        ;;
esac
EOF
    chmod +x "${TUI_CLI}"
}

@test "tui_cli_show_json forks show <module> --json and validates JSON" {
    _make_mock_show_cli
    run tui_cli_show_json docker
    assert_success
    assert_output --partial '"name": "docker"'
    run cat "${MOCK_CLI_LOG}"
    assert_output "show docker --json"
}

@test "tui_cli_show_json fails for an unregistered module (show rc!=0)" {
    _make_mock_show_cli
    run tui_cli_show_json ghost
    assert_failure
}

# ── tui_detail_text: readable label:value lines, arrays comma-joined ─────────

@test "tui_detail_text renders the #211 fields with arrays comma-joined" {
    run tui_detail_text "${FIXTURE_SHOW_JSON}"
    assert_success
    assert_output --partial "docker"
    assert_output --partial "recommended"
    assert_output --partial "Docker Engine and CLI"
    assert_output --partial "container, devops"
    assert_output --partial "curl"
    assert_output --partial "podman"
    assert_output --partial "22.04, 24.04"
    assert_output --partial "desktop, server"
}

@test "tui_detail_text shows the full depends_on / conflicts / ubuntu / platforms labels" {
    run tui_detail_text "${FIXTURE_SHOW_JSON}"
    assert_success
    # Every #211 field is labelled (en strings).
    assert_output --partial "Tags:"
    assert_output --partial "Depends on:"
    assert_output --partial "Conflicts:"
    assert_output --partial "Supported Ubuntu:"
    assert_output --partial "Supported platforms:"
}

@test "tui_detail_text renders empty arrays / null description as (none)" {
    run tui_detail_text "${FIXTURE_SHOW_SPARSE_JSON}"
    assert_success
    # neovim has null description + empty tags/depends_on/conflicts/platforms.
    assert_output --partial "(none)"
}

@test "tui_detail_text is read-only: never emits a setup_ubuntu fork command" {
    run tui_detail_text "${FIXTURE_SHOW_JSON}"
    assert_success
    refute_output --partial "setup_ubuntu"
    refute_output --partial "install"
    refute_output --partial "remove"
}

# ── #215: unregistered installed entries are clearly labelled ────────────────

@test "tui_installed_entries marks an unregistered module (not in list --json)" {
    run tui_installed_entries "${FIXTURE_STATE_JSON}" "${FIXTURE_LIST_JSON}" flat
    assert_success
    # docker is in the catalog → no marker; ghost is NOT → "(unregistered)".
    assert_output --partial "(unregistered)"
    # The marker must attach to ghost specifically (ghost row carries it).
    local _ghost_row
    _ghost_row="$(grep '^ghost' <<<"${output}")"
    [[ "${_ghost_row}" == *"(unregistered)"* ]]
}

@test "tui_installed_entries does not mark a registered module" {
    run tui_installed_entries "${FIXTURE_STATE_JSON}" "${FIXTURE_LIST_JSON}" flat
    assert_success
    # The docker row (registered) must not carry the marker.
    local _docker_row
    _docker_row="$(grep '^docker' <<<"${output}")"
    [[ "${_docker_row}" != *"(unregistered)"* ]]
}

@test "tui_installed_entries grouped view buckets unregistered modules clearly" {
    run tui_installed_entries "${FIXTURE_STATE_JSON}" "${FIXTURE_LIST_JSON}" grouped
    assert_success
    assert_output --partial "(unregistered)"
}

@test "tui_installed_entries still emits name<TAB>display TSV (2 fields per row)" {
    run tui_installed_entries "${FIXTURE_STATE_JSON}" "${FIXTURE_LIST_JSON}" flat
    assert_success
    while IFS= read -r _line; do
        [ "$(awk -F'\t' '{print NF}' <<<"${_line}")" -eq 2 ]
    done <<<"${output}"
}

# ── #215: detail text for an unregistered entry (state.json + catalog note) ──

@test "tui_detail_unregistered_text shows state facts + a not-in-catalog note" {
    run tui_detail_unregistered_text ghost "${FIXTURE_STATE_JSON}"
    assert_success
    assert_output --partial "ghost"
    # version_provided + installed_at from state.json.
    assert_output --partial "unknown"
    assert_output --partial "2026-05-13"
    # The clear "not in current catalog" note.
    assert_output --partial "catalog"
}

# ── e2e: detail view reachable from a checklist WITHOUT losing selections ────
# Same scripted-dialog harness as tui_manage_spec / tui_ac10. A "View
# details..." companion entry lets the user pick a module and read its detail
# msgbox; the in-memory selection accumulator survives the round trip.

_make_e2e_detail_harness() {
    local _dir="${INIT_UBUNTU_TEST_SCRATCH}/e2e"
    mkdir -p "${_dir}/bin" "${_dir}/home"
    E2E_BIN="${_dir}/bin"
    E2E_HOME="${_dir}/home"
    E2E_RESPONSES="${_dir}/responses"
    E2E_WIDGET_LOG="${_dir}/widget.log"
    E2E_CLI_LOG="${_dir}/cli.log"
    export E2E_BIN E2E_HOME E2E_RESPONSES E2E_WIDGET_LOG E2E_CLI_LOG

    printf '%s\n' "${FIXTURE_LIST_JSON}"   >"${_dir}/list.json"
    printf '%s\n' "${FIXTURE_DETECT_JSON}" >"${_dir}/detect.json"
    printf '%s\n' "${FIXTURE_STATE_JSON}"  >"${_dir}/state.json"
    printf '%s\n' "${FIXTURE_SHOW_JSON}"   >"${_dir}/show.json"

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
    "list --json")             cat "${_dir}/list.json" ;;
    "detect --json")           cat "${_dir}/detect.json" ;;
    "list --installed --json") cat "${_dir}/state.json" ;;
    "show docker --json")      cat "${_dir}/show.json" ;;
    "show neovim --json")      cat "${_dir}/show.json" ;;
    "show ghost --json")
        printf '[dispatcher] ERROR: unknown module ghost\n' >&2
        exit 2
        ;;
    "install --dry-run "*)
        printf '[dispatcher] DRY-RUN: would install in this order:\n'
        printf '  - docker\n'
        ;;
    "install "*) printf 'CLI install pipeline output\n' ;;
esac
EOF
    chmod +x "${E2E_BIN}/dialog" "${E2E_BIN}/setup_ubuntu"
}

_run_tui_e2e() {
    run env "PATH=${E2E_BIN}:${PATH}" "HOME=${E2E_HOME}" \
        "TUI_CLI=${E2E_BIN}/setup_ubuntu" \
        "TUI_BACKEND=${E2E_BIN}/dialog" \
        "${REPO_ROOT}/setup_ubuntu_tui.sh" </dev/null
}

@test "e2e: checklist detail view forks show --json and renders the fields" {
    _make_e2e_detail_harness
    # recommended checklist: check ONLY the "View details..." sentinel (no real
    # module → empty accumulator → clean main-menu exit, no exit guard).
    # ADR-0024 D10: recommended has 2 TAGS[0] buckets, so a sub-category menu
    # precedes the checklist; drill into container, then Back out of it.
    # Widget invocation order:
    #   1 main menu      → recommended
    #   2 sub-cat menu   → container
    #   3 checklist      → sentinel only (commits nothing)
    #   4 detail picker  → docker
    #   5 detail msgbox  → enter
    #   6 checklist again→ Back (discard, accumulator still empty)
    #   7 sub-cat menu   → Back
    #   8 main menu      → Exit (empty selection → no guard)
    cat >"${E2E_RESPONSES}" <<'EOF'
0|recommended
0|container
0|__details__\n
0|docker
0|
1|
1|
1|
EOF
    _run_tui_e2e
    assert_success
    # The detail msgbox text carried the show --json fields.
    run cat "${E2E_WIDGET_LOG}"
    assert_output --partial "Docker Engine and CLI"
    # The show --json fork actually happened (G4).
    run grep -c "^show docker --json$" "${E2E_CLI_LOG}"
    assert_output "1"
}

@test "e2e: opening then closing the detail view keeps checklist selections" {
    _make_e2e_detail_harness
    # ADR-0024 D10: recommended drills into the container bucket (docker) first.
    # 1) recommended → container sub-category
    # 2) checklist: check docker + the details sentinel → OK
    # 3) details picker: pick docker → msgbox → Back to checklist
    # 4) re-rendered checklist: OK with docker still checked (no new toggles)
    # 5) sub-cat menu Back → Run → Review Proceed: install includes docker.
    cat >"${E2E_RESPONSES}" <<'EOF'
0|recommended
0|container
0|docker\n__details__\n
0|docker
0|
0|docker\n
1|
0|run
0|proceed
EOF
    _run_tui_e2e
    assert_success
    assert_output --partial "CLI install pipeline output"
    # The install fork carried docker — the selection was not lost by the
    # detail round trip.
    run tail -n1 "${E2E_CLI_LOG}"
    assert_output --partial "install"
    assert_output --partial "docker"
}

@test "e2e: Manage Installed detail action shows a registered module's detail" {
    _make_e2e_detail_harness
    cat >"${E2E_RESPONSES}" <<'EOF'
0|manage
0|docker
0|detail
0|
1|
1|
EOF
    _run_tui_e2e
    assert_success
    run grep -c "^show docker --json$" "${E2E_CLI_LOG}"
    assert_output "1"
    run cat "${E2E_WIDGET_LOG}"
    assert_output --partial "Docker Engine and CLI"
}

@test "e2e: Manage Installed detail action on an unregistered entry shows the catalog note" {
    _make_e2e_detail_harness
    cat >"${E2E_RESPONSES}" <<'EOF'
0|manage
0|ghost
0|detail
0|
1|
1|
EOF
    _run_tui_e2e
    assert_success
    # show ghost --json fails (rc 2); the TUI falls back to the state-only
    # detail with a not-in-catalog note instead of crashing.
    run cat "${E2E_WIDGET_LOG}"
    assert_output --partial "catalog"
}
