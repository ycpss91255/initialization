#!/usr/bin/env bats
# test/unit/tui_manage_spec.bats — Manage Installed / Manage Secrets (#72)
#
# Issue #72 (PRD §8.3 / §8.4, G4): Manage Installed lists installed modules
# (version, installed_at — data source: a forked `setup_ubuntu list
# --installed --json`), optionally grouped by TAGS[0]; Update / Remove /
# Purge fork the matching CLI subcommand. Destructive actions (Remove /
# Purge) go through the §8.4 confirm dialog that enumerates the concrete
# actions (exact forked command + dry-run-derived module plan + state.json
# change) — Cancel forks nothing. Manage Secrets forks setup_secrets and
# returns to the main menu.
#
# HOST-SAFETY: every fork target is a recording mock (TUI_CLI /
# TUI_SECRETS / scripted dialog binary) — no real CLI, widget, or secrets
# tool is touched; fixtures are inline JSON, never live state.

load "${BATS_TEST_DIRNAME}/../helper/common"

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
# state.json (ADR-0018 synced/local split) as served by
# `setup_ubuntu list --installed --json` — the §8.3 data source.
# "ghost" has no module file anymore (not in list --json) → grouped view
# must fall back to the "other" bucket instead of erroring.

FIXTURE_STATE_JSON="$(cat <<'EOF'
{
  "version": "0.1.0",
  "installed": {
    "neovim": {
      "synced": {"manual": true, "depends_on": [], "version_provided": "0.10.2",
                 "installed_at": "2026-05-13T14:25:00+08:00", "installed_by": "cli"},
      "local": {}
    },
    "docker": {
      "synced": {"manual": true, "depends_on": ["apt-essentials"], "version_provided": "27.4.0",
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

# Minimal ADR-0019 `list --json` payload: supplies TAGS[0] for grouping.
FIXTURE_LIST_JSON="$(cat <<'EOF'
{
  "schema_version": "1",
  "scope": "available",
  "filters": {"category": null, "tag": null},
  "items": [
    {"name": "docker", "category": "recommended", "tags": ["container"],
     "description": "Docker Engine", "version_provided": "apt-managed",
     "installed": true, "outdated": false, "manual": true,
     "depends_on": ["apt-essentials"], "supports_user_home": false,
     "supported_platforms": ["desktop", "server"], "supported_ubuntu": ["24.04"],
     "risk_level": "low", "reboot_required": false, "homepage": null},
    {"name": "neovim", "category": "recommended", "tags": ["editor"],
     "description": "Neovim editor", "version_provided": "v0.10.2",
     "installed": true, "outdated": false, "manual": true,
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

# ── Installed list rendering (§8.3 fixture json) ─────────────────────────────

@test "tui_installed_entries flat view lists name/version/installed_at sorted by name" {
    run tui_installed_entries "${FIXTURE_STATE_JSON}" "${FIXTURE_LIST_JSON}" flat
    assert_success
    assert_line --index 0 "$(printf 'docker\t27.4.0        2026-05-13 14:22')"
    assert_line --index 1 "$(printf 'ghost\tunknown       2026-05-13 14:31')"
    assert_line --index 2 "$(printf 'neovim\t0.10.2        2026-05-13 14:25')"
}

@test "tui_installed_entries grouped view sorts by TAGS[0] with a [tag] prefix" {
    run tui_installed_entries "${FIXTURE_STATE_JSON}" "${FIXTURE_LIST_JSON}" grouped
    assert_success
    # container < editor < other (ghost has no module file → "other").
    assert_line --index 0 "$(printf 'docker\t[container] 27.4.0        2026-05-13 14:22')"
    assert_line --index 1 "$(printf 'neovim\t[editor] 0.10.2        2026-05-13 14:25')"
    assert_line --index 2 "$(printf 'ghost\t[other] unknown       2026-05-13 14:31')"
}

@test "tui_installed_entries is empty when nothing is installed" {
    run tui_installed_entries '{"version":"0.1.0","installed":{}}' "${FIXTURE_LIST_JSON}" flat
    assert_success
    assert_output ""
}

@test "tui_installed_entries emits name<TAB>display TSV (2 fields per row)" {
    run tui_installed_entries "${FIXTURE_STATE_JSON}" "${FIXTURE_LIST_JSON}" grouped
    assert_success
    while IFS= read -r _line; do
        [ "$(awk -F'\t' '{print NF}' <<<"${_line}")" -eq 2 ]
    done <<<"${output}"
}

# ── Action command strings (G4: fork argv, never an engine call) ────────────

@test "tui_manage_args update builds the upgrade fork argv" {
    local -a _argv=()
    mapfile -t _argv < <(tui_manage_args update docker)
    [ "${_argv[*]}" = "upgrade docker -y" ]
}

@test "tui_manage_args remove builds the remove fork argv (--no-deps)" {
    local -a _argv=()
    mapfile -t _argv < <(tui_manage_args remove docker)
    [ "${_argv[*]}" = "remove --no-deps docker -y" ]
}

@test "tui_manage_args purge builds the purge fork argv (--no-deps)" {
    local -a _argv=()
    mapfile -t _argv < <(tui_manage_args purge docker)
    [ "${_argv[*]}" = "purge --no-deps docker -y" ]
}

@test "tui_manage_args rejects unknown actions" {
    run tui_manage_args frobnicate docker
    assert_failure
}

# ── Dry-run plan fork (confirm-dialog data source; §8.4) ─────────────────────

# Recording mock CLI: logs argv, replays the dispatcher's DRY-RUN output.
_make_mock_cli() {
    MOCK_CLI_LOG="${INIT_UBUNTU_TEST_SCRATCH}/cli.log"
    TUI_CLI="${INIT_UBUNTU_TEST_SCRATCH}/mock_setup_ubuntu"
    export MOCK_CLI_LOG TUI_CLI
    cat >"${TUI_CLI}" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${MOCK_CLI_LOG}"
printf '[dispatcher] DRY-RUN: would %s in this order:\n' "\$1"
printf '  - docker\n'
EOF
    chmod +x "${TUI_CLI}"
}

@test "tui_cli_manage_plan forks <action> --dry-run --no-deps and parses the order" {
    _make_mock_cli
    run tui_cli_manage_plan purge docker
    assert_success
    assert_output "docker"
    run cat "${MOCK_CLI_LOG}"
    assert_output "purge --dry-run --no-deps docker"
}

@test "tui_cli_manage_plan fails cleanly when the fork is not a dry-run" {
    _make_mock_cli
    printf '#!/usr/bin/env bash\nprintf "garbage\\n"\n' >"${TUI_CLI}"
    run tui_cli_manage_plan purge docker
    assert_failure
    assert_output --partial "ERROR"
}

@test "tui_cli_installed_json forks list --installed --json and validates JSON" {
    _make_mock_cli
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s"\nprintf "%%s\\n" %q\n' \
        "${MOCK_CLI_LOG}" "${FIXTURE_STATE_JSON}" >"${TUI_CLI}"
    run tui_cli_installed_json
    assert_success
    run cat "${MOCK_CLI_LOG}"
    assert_output "list --installed --json"
}

# ── §8.4 confirm dialog content (concrete actions) ──────────────────────────

@test "tui_manage_confirm_text purge enumerates the exact cmd, plan and state change" {
    run tui_manage_confirm_text purge docker $'docker'
    assert_success
    assert_output --partial "About to PURGE 'docker':"
    # AC: the dialog lists the actual command that will be forked.
    assert_output --partial "setup_ubuntu purge --no-deps docker -y"
    assert_output --partial "purge module: docker"
    assert_output --partial "remove 'docker' from state.json"
    assert_output --partial "config files"
}

@test "tui_manage_confirm_text remove notes that config is retained" {
    run tui_manage_confirm_text remove docker $'docker'
    assert_success
    assert_output --partial "About to REMOVE 'docker':"
    assert_output --partial "setup_ubuntu remove --no-deps docker -y"
    assert_output --partial "config files are retained"
}

# ── Proceed/Cancel button relabel (yesno wrapper) ────────────────────────────

_make_mock_widget() {
    MOCK_WIDGET_LOG="${INIT_UBUNTU_TEST_SCRATCH}/widget.log"
    TUI_BACKEND="${INIT_UBUNTU_TEST_SCRATCH}/mock_widget"
    export MOCK_WIDGET_LOG TUI_BACKEND
    cat >"${TUI_BACKEND}" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${MOCK_WIDGET_LOG}"
exit "\${MOCK_WIDGET_RC:-0}"
EOF
    chmod +x "${TUI_BACKEND}"
}

@test "tui_render_yesno relabels Yes/No to Proceed/Cancel (§8.4 buttons)" {
    _make_mock_widget
    TUI_YES_LABEL="Proceed" TUI_NO_LABEL="Cancel" run tui_render_yesno "Confirm Purge" "txt"
    assert_success
    run cat "${MOCK_WIDGET_LOG}"
    # Mock is neither named whiptail nor dialog → default (dialog) spelling.
    assert_output --partial "--yes-label Proceed"
    assert_output --partial "--no-label Cancel"
}

@test "tui_render_yesno keeps default buttons when no labels are set" {
    _make_mock_widget
    run tui_render_yesno "Q" "txt"
    assert_success
    run cat "${MOCK_WIDGET_LOG}"
    refute_output --partial "--yes-label"
}

# ── e2e: real TUI process, scripted dialog + recording forks ────────────────
# Same harness pattern as tui_backend_spec.bats: a scripted `dialog` pops
# one "rc|output" response per widget invocation; recording mocks stand in
# for setup_ubuntu (TUI_CLI) and setup_secrets (TUI_SECRETS).

_make_e2e_harness() {
    local _dir="${INIT_UBUNTU_TEST_SCRATCH}/e2e"
    mkdir -p "${_dir}/bin" "${_dir}/home"
    E2E_BIN="${_dir}/bin"
    E2E_HOME="${_dir}/home"
    E2E_RESPONSES="${_dir}/responses"
    E2E_WIDGET_LOG="${_dir}/widget.log"
    E2E_CLI_LOG="${_dir}/cli.log"
    E2E_SECRETS_LOG="${_dir}/secrets.log"
    export E2E_BIN E2E_HOME E2E_RESPONSES E2E_WIDGET_LOG E2E_CLI_LOG E2E_SECRETS_LOG

    printf '%s\n' "${FIXTURE_LIST_JSON}"   >"${_dir}/list.json"
    printf '%s\n' "${FIXTURE_DETECT_JSON}" >"${_dir}/detect.json"
    printf '%s\n' "${FIXTURE_STATE_JSON}"  >"${_dir}/state.json"

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
    "remove --dry-run --no-deps "*|"purge --dry-run --no-deps "*)
        printf '[dispatcher] DRY-RUN: would %s in this order:\n' "\$1"
        printf '  - %s\n' "\${*: -1}"
        ;;
    "upgrade "*|"remove "*|"purge "*) printf 'CLI %s pipeline output\n' "\$1" ;;
esac
EOF

    cat >"${E2E_BIN}/setup_secrets" <<EOF
#!/usr/bin/env bash
printf '%s\n' "invoked \$*" >>"${E2E_SECRETS_LOG}"
printf 'setup_secrets usage\n'
EOF
    chmod +x "${E2E_BIN}/dialog" "${E2E_BIN}/setup_ubuntu" "${E2E_BIN}/setup_secrets"
}

_run_tui_e2e() {
    # TUI_BACKEND pinned to the scripted `dialog` mock so the run bypasses
    # #171 detection / the gum install prompt (dialog is no longer detected;
    # the dispatcher routes a dialog-named binary through the whiptail family
    # whose --menu/--checklist shape the scripted mock emulates).
    run env "PATH=${E2E_BIN}:${PATH}" "HOME=${E2E_HOME}" \
        "TUI_CLI=${E2E_BIN}/setup_ubuntu" \
        "TUI_SECRETS=${E2E_BIN}/setup_secrets" \
        "TUI_BACKEND=${E2E_BIN}/dialog" \
        "${REPO_ROOT}/setup_ubuntu_tui.sh" </dev/null
}

@test "e2e: Manage Installed purge Proceed forks the exact purge command" {
    _make_e2e_harness
    cat >"${E2E_RESPONSES}" <<'EOF'
0|manage
0|docker
0|purge
0|
EOF
    _run_tui_e2e
    assert_success
    assert_output --partial "CLI purge pipeline output"
    # The confirm dialog (widget argv) carried the concrete command (§8.4).
    run cat "${E2E_WIDGET_LOG}"
    assert_output --partial "setup_ubuntu purge --no-deps docker -y"
    # Forks: the dry-run plan + the one real purge, with the exact argv.
    run grep -c "^purge" "${E2E_CLI_LOG}"
    assert_output "2"
    run tail -n1 "${E2E_CLI_LOG}"
    assert_output "purge --no-deps docker -y"
}

@test "e2e: confirm Cancel forks nothing destructive and returns to the list" {
    _make_e2e_harness
    cat >"${E2E_RESPONSES}" <<'EOF'
0|manage
0|docker
0|purge
1|
1|
1|
EOF
    _run_tui_e2e
    assert_success
    # Only the read-only dry-run fork happened — never the real purge.
    run grep -c "^purge --no-deps docker -y$" "${E2E_CLI_LOG}"
    assert_failure
    run grep -c "^purge --dry-run" "${E2E_CLI_LOG}"
    assert_output "1"
}

@test "e2e: Update forks upgrade without a destructive confirm" {
    _make_e2e_harness
    cat >"${E2E_RESPONSES}" <<'EOF'
0|manage
0|docker
0|update
EOF
    _run_tui_e2e
    assert_success
    assert_output --partial "CLI upgrade pipeline output"
    run tail -n1 "${E2E_CLI_LOG}"
    assert_output "upgrade docker -y"
    # No yes/no confirm dialog rendered for the non-destructive action.
    run grep -c -- "--yesno" "${E2E_WIDGET_LOG}"
    assert_failure
}

@test "e2e: view toggle switches the list to TAGS[0] grouping" {
    _make_e2e_harness
    cat >"${E2E_RESPONSES}" <<'EOF'
0|manage
0|view
1|
1|
EOF
    _run_tui_e2e
    assert_success
    run cat "${E2E_WIDGET_LOG}"
    # Second Manage render shows the grouped labels.
    assert_output --partial "[container]"
    assert_output --partial "[editor]"
}

@test "e2e: Manage Secrets forks setup_secrets and returns to the main menu" {
    _make_e2e_harness
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
1|
EOF
    _run_tui_e2e
    assert_success
    run cat "${E2E_SECRETS_LOG}"
    assert_output "invoked "
    # Back at the main menu after the fork: a second main-menu render
    # happened (the response file's trailing Exit was consumed).
    run grep -c -- "--menu" "${E2E_WIDGET_LOG}"
    assert_output "2"
}

@test "e2e: empty installed list shows a message instead of an empty menu" {
    _make_e2e_harness
    printf '{"version":"0.1.0","installed":{}}\n' >"${INIT_UBUNTU_TEST_SCRATCH}/e2e/state.json"
    cat >"${E2E_RESPONSES}" <<'EOF'
0|manage
0|
1|
EOF
    _run_tui_e2e
    assert_success
    run cat "${E2E_WIDGET_LOG}"
    assert_output --partial "no modules recorded as installed"
}
