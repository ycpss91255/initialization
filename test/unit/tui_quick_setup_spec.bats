#!/usr/bin/env bats
# test/unit/tui_quick_setup_spec.bats — Quick Setup wizard (#71, PRD §8.2.1)
#
# Covers:
#   - Step-2/3/4 data helpers in lib/tui_backend.sh: §15.3 platform filter
#     first, Q36 `[modules.<n>] enabled` tri-state second, engine-computed
#     `recommended` (is_recommended) preselect last.
#   - Wizard e2e against a scripted mock backend + recording mock CLI:
#     four-step flow → Review → Proceed forks ONE `install <picked...> -y`
#     whose argv contains ONLY user-picked modules (the §8.2.1 manual-flag
#     matrix is guaranteed structurally: deps the engine pulls are never
#     named, so they stay manual=false).
#   - Platform override deferred write: `config set platform.override` is
#     forked ONLY on Proceed, never during prepare (§8.2.1 cancel table).
#   - Cancel before Proceed = pure cancel: zero forks with side effects,
#     zero file writes (fs snapshot).
#   - SIGINT-after-Proceed contract surface: the forked CLI's exit 6
#     (partial install) propagates as the TUI exit code, with the CLI
#     pipeline's partial summary passed through verbatim.
#
# HOST-SAFETY: every fork is a recorded mock; no real dialog/whiptail,
# no real setup_ubuntu, no host writes outside $BATS_TEST_TMPDIR.

load "${BATS_TEST_DIRNAME}/../helper/common"

# shellcheck source=../../lib/tui_backend.sh
source "${LIB_DIR}/tui_backend.sh"

setup() {
    setup_test_env
    # Clip helper (#168) counts characters; pin UTF-8 so the budget assertion
    # matches under CI's C/POSIX kcov image (see tui_backend_spec.bats).
    export LC_ALL=C.UTF-8
}

teardown() {
    teardown_test_env
}

# ── ADR-0019 fixture with the #71 additive fields ────────────────────────────
# `recommended` (engine is_recommended() result) and `enabled` (Q36 config
# tri-state) are additive per ADR-0019 ("adding new fields is non-breaking");
# absent = null = "engine did not force anything".
#
# recommended category:
#   docker        desktop+server   recommended=true            → shown, on
#   neovim        desktop+server   recommended=true            → shown, on
#   nvidia-driver desktop only     recommended=false           → shown, off
#   font          desktop only     recommended=true            → platform-gated
#   tmux          all              enabled=true  (Q36 force)   → shown, on
#   disabled-mod  all              enabled=false (Q36 exclude) → never shown
# optional / cli-essentials tag: eza fdfind fnm fzf lazygit ripgrep zoxide
# optional / agent tag: claude-code (recommended=true), codex, gemini

FIXTURE_QS_LIST_JSON="$(cat <<'EOF'
{
  "schema_version": "1",
  "scope": "available",
  "filters": {"category": null, "tag": null},
  "items": [
    {"name": "apt-essentials", "category": "base", "tags": ["core"],
     "description": "Foundation apt packages", "version_provided": "apt-managed",
     "installed": true, "outdated": false, "manual": false, "depends_on": [],
     "supports_user_home": false, "supported_platforms": ["desktop", "server", "wsl"],
     "supported_ubuntu": ["24.04"], "risk_level": "low", "reboot_required": false,
     "homepage": null},
    {"name": "docker", "category": "recommended", "tags": ["container"],
     "description": "Docker Engine", "version_provided": "apt-managed",
     "installed": false, "outdated": null, "manual": null, "depends_on": null,
     "supports_user_home": false, "supported_platforms": ["desktop", "server"],
     "supported_ubuntu": ["24.04"], "risk_level": "low", "reboot_required": false,
     "homepage": null, "recommended": true},
    {"name": "neovim", "category": "recommended", "tags": ["editor"],
     "description": "Neovim editor", "version_provided": "v0.10.2",
     "installed": false, "outdated": null, "manual": null, "depends_on": null,
     "supports_user_home": true, "supported_platforms": ["desktop", "server"],
     "supported_ubuntu": ["24.04"], "risk_level": "low", "reboot_required": false,
     "homepage": null, "recommended": true},
    {"name": "nvidia-driver", "category": "recommended", "tags": ["driver"],
     "description": "NVIDIA driver", "version_provided": "apt-managed",
     "installed": false, "outdated": null, "manual": null, "depends_on": null,
     "supports_user_home": false, "supported_platforms": ["desktop"],
     "supported_ubuntu": ["24.04"], "risk_level": "high", "reboot_required": true,
     "homepage": null, "recommended": false},
    {"name": "font", "category": "recommended", "tags": ["desktop"],
     "description": "Nerd fonts", "version_provided": "github-release",
     "installed": false, "outdated": null, "manual": null, "depends_on": null,
     "supports_user_home": true, "supported_platforms": ["desktop"],
     "supported_ubuntu": ["24.04"], "risk_level": "low", "reboot_required": false,
     "homepage": null, "recommended": true},
    {"name": "tmux", "category": "recommended", "tags": ["terminal"],
     "description": "Terminal multiplexer", "version_provided": "apt-managed",
     "installed": false, "outdated": null, "manual": null, "depends_on": null,
     "supports_user_home": false, "supported_platforms": ["desktop", "server", "wsl"],
     "supported_ubuntu": ["24.04"], "risk_level": "low", "reboot_required": false,
     "homepage": null, "recommended": false, "enabled": true},
    {"name": "disabled-mod", "category": "recommended", "tags": ["misc"],
     "description": "Force-excluded by config", "version_provided": "apt-managed",
     "installed": false, "outdated": null, "manual": null, "depends_on": null,
     "supports_user_home": false, "supported_platforms": ["desktop", "server", "wsl"],
     "supported_ubuntu": ["24.04"], "risk_level": "low", "reboot_required": false,
     "homepage": null, "recommended": true, "enabled": false},
    {"name": "eza", "category": "optional", "tags": ["cli-essentials"],
     "description": "ls alternative", "version_provided": "github-release",
     "installed": false, "outdated": null, "manual": null, "depends_on": null,
     "supports_user_home": true, "supported_platforms": ["desktop", "server", "wsl"],
     "supported_ubuntu": ["24.04"], "risk_level": "low", "reboot_required": false,
     "homepage": null},
    {"name": "fdfind", "category": "optional", "tags": ["cli-essentials"],
     "description": "find alternative", "version_provided": "github-release",
     "installed": false, "outdated": null, "manual": null, "depends_on": null,
     "supports_user_home": true, "supported_platforms": ["desktop", "server", "wsl"],
     "supported_ubuntu": ["24.04"], "risk_level": "low", "reboot_required": false,
     "homepage": null},
    {"name": "fnm", "category": "optional", "tags": ["cli-essentials"],
     "description": "Node version manager", "version_provided": "github-release",
     "installed": false, "outdated": null, "manual": null, "depends_on": null,
     "supports_user_home": true, "supported_platforms": ["desktop", "server", "wsl"],
     "supported_ubuntu": ["24.04"], "risk_level": "low", "reboot_required": false,
     "homepage": null},
    {"name": "fzf", "category": "optional", "tags": ["cli-essentials"],
     "description": "Fuzzy finder", "version_provided": "github-release",
     "installed": false, "outdated": null, "manual": null, "depends_on": null,
     "supports_user_home": true, "supported_platforms": ["desktop", "server", "wsl"],
     "supported_ubuntu": ["24.04"], "risk_level": "low", "reboot_required": false,
     "homepage": null},
    {"name": "lazygit", "category": "optional", "tags": ["cli-essentials"],
     "description": "git TUI", "version_provided": "github-release",
     "installed": false, "outdated": null, "manual": null, "depends_on": null,
     "supports_user_home": true, "supported_platforms": ["desktop", "server", "wsl"],
     "supported_ubuntu": ["24.04"], "risk_level": "low", "reboot_required": false,
     "homepage": null},
    {"name": "ripgrep", "category": "optional", "tags": ["cli-essentials"],
     "description": "grep alternative", "version_provided": "github-release",
     "installed": false, "outdated": null, "manual": null, "depends_on": null,
     "supports_user_home": true, "supported_platforms": ["desktop", "server", "wsl"],
     "supported_ubuntu": ["24.04"], "risk_level": "low", "reboot_required": false,
     "homepage": null},
    {"name": "zoxide", "category": "optional", "tags": ["cli-essentials"],
     "description": "cd alternative", "version_provided": "github-release",
     "installed": false, "outdated": null, "manual": null, "depends_on": null,
     "supports_user_home": true, "supported_platforms": ["desktop", "server", "wsl"],
     "supported_ubuntu": ["24.04"], "risk_level": "low", "reboot_required": false,
     "homepage": null},
    {"name": "claude-code", "category": "optional", "tags": ["agent"],
     "description": "Anthropic agent CLI", "version_provided": "npm",
     "installed": false, "outdated": null, "manual": null, "depends_on": null,
     "supports_user_home": true, "supported_platforms": ["desktop", "server", "wsl"],
     "supported_ubuntu": ["24.04"], "risk_level": "low", "reboot_required": false,
     "homepage": null, "recommended": true},
    {"name": "codex", "category": "optional", "tags": ["agent"],
     "description": "OpenAI agent CLI", "version_provided": "npm",
     "installed": false, "outdated": null, "manual": null, "depends_on": null,
     "supports_user_home": true, "supported_platforms": ["desktop", "server", "wsl"],
     "supported_ubuntu": ["24.04"], "risk_level": "low", "reboot_required": false,
     "homepage": null},
    {"name": "gemini", "category": "optional", "tags": ["agent"],
     "description": "Google agent CLI", "version_provided": "npm",
     "installed": false, "outdated": null, "manual": null, "depends_on": null,
     "supports_user_home": true, "supported_platforms": ["desktop", "server", "wsl"],
     "supported_ubuntu": ["24.04"], "risk_level": "low", "reboot_required": false,
     "homepage": null}
  ],
  "count": 17,
  "generated_at": "2026-06-07T00:00:00+08:00"
}
EOF
)"

FIXTURE_QS_DETECT_JSON='{"os":{"id":"ubuntu","version":"24.04","codename":"noble"},"arch":"x86_64","cpu":{"vendor":"GenuineIntel"},"gpu":{"vendor":"nvidia","model":"NVIDIA RTX 4090"},"desktop":"GNOME","session_type":"x11","virt":{"container":false,"vm":false},"wsl":false,"board":null,"form_factor":"desktop"}'

# ── Effective form factor (Step 1) ───────────────────────────────────────────

@test "tui_effective_form_factor falls back to the detect payload" {
    run tui_effective_form_factor "${FIXTURE_QS_DETECT_JSON}" ""
    assert_success
    assert_output "desktop"
}

@test "tui_effective_form_factor: the wizard override wins over detection" {
    run tui_effective_form_factor "${FIXTURE_QS_DETECT_JSON}" "rpi-5"
    assert_success
    assert_output "rpi-5"
}

@test "tui_platform_choices lists the §7.5 form factors as TSV" {
    run tui_platform_choices
    assert_success
    [ "${#lines[@]}" -eq 6 ]
    assert_line --index 0 "$(printf 'desktop\tDesktop / laptop')"
    assert_line --partial "server"
    assert_line --partial "wsl"
    assert_line --partial "rpi-4"
    assert_line --partial "rpi-5"
    assert_line --partial "jetson-orin"
}

# ── Step 2: recommended entries (§15.3 platform → Q36 enabled → recommended) ─

@test "tui_qs_recommended_entries emits FULL descriptions, unclipped (#183)" {
    # #183: the QS producer no longer clips (the #168 budget moved into the
    # whiptail adapter). Even at an absurdly tiny width the producer must emit
    # the whole description and inject no ellipsis — gum renders full text.
    TUI_WIDTH=24 run tui_qs_recommended_entries "${FIXTURE_QS_LIST_JSON}" desktop
    assert_success
    refute_output --partial "…"
    # full fixture descriptions survive verbatim (would be clipped at width 24).
    assert_line --partial "$(printf '\tTerminal multiplexer\t')"
    assert_line --partial "$(printf '\tDocker Engine\t')"
}

@test "tui_qs_recommended_entries preselects is_recommended modules" {
    run tui_qs_recommended_entries "${FIXTURE_QS_LIST_JSON}" desktop
    assert_success
    assert_line "$(printf 'docker\tDocker Engine\ton')"
    assert_line "$(printf 'neovim\tNeovim editor\ton')"
    assert_line "$(printf 'font\tNerd fonts\ton')"
}

@test "tui_qs_recommended_entries shows recommended=false rows unchecked" {
    run tui_qs_recommended_entries "${FIXTURE_QS_LIST_JSON}" desktop
    assert_success
    assert_line "$(printf 'nvidia-driver\tNVIDIA driver\toff')"
}

@test "tui_qs_recommended_entries: Q36 enabled=true force-includes checked" {
    # tmux has recommended=false but enabled=true → on regardless.
    run tui_qs_recommended_entries "${FIXTURE_QS_LIST_JSON}" desktop
    assert_success
    assert_line "$(printf 'tmux\tTerminal multiplexer\ton')"
}

@test "tui_qs_recommended_entries: Q36 enabled=false force-excludes the row" {
    # disabled-mod has recommended=true but enabled=false → never shown.
    run tui_qs_recommended_entries "${FIXTURE_QS_LIST_JSON}" desktop
    assert_success
    refute_output --partial "disabled-mod"
}

@test "tui_qs_recommended_entries filters SUPPORTED_PLATFORMS before anything" {
    # form=server: font + nvidia-driver are desktop-only → dropped even
    # though recommended; the platform gate runs first (§15.3).
    run tui_qs_recommended_entries "${FIXTURE_QS_LIST_JSON}" server
    assert_success
    refute_output --partial "font"
    refute_output --partial "nvidia-driver"
    assert_line --partial "docker"
    assert_line --partial "neovim"
    assert_line --partial "tmux"
}

@test "tui_qs_recommended_entries never leaks other categories" {
    run tui_qs_recommended_entries "${FIXTURE_QS_LIST_JSON}" desktop
    assert_success
    refute_output --partial "apt-essentials"
    refute_output --partial "eza"
    refute_output --partial "claude-code"
}

# ── Steps 3/4: tag entries (cli-essentials suite, agent multi-select) ────────

@test "tui_qs_tag_entries lists the cli-essentials suite alphabetically, off" {
    run tui_qs_tag_entries "${FIXTURE_QS_LIST_JSON}" cli-essentials desktop
    assert_success
    [ "${#lines[@]}" -eq 7 ]
    assert_line --index 0 "$(printf 'eza\tls alternative\toff')"
    assert_line --index 1 "$(printf 'fdfind\tfind alternative\toff')"
    assert_line --index 6 "$(printf 'zoxide\tcd alternative\toff')"
}

@test "tui_qs_tag_entries preselects recommended agent CLIs (claude-code)" {
    run tui_qs_tag_entries "${FIXTURE_QS_LIST_JSON}" agent desktop
    assert_success
    [ "${#lines[@]}" -eq 3 ]
    assert_line "$(printf 'claude-code\tAnthropic agent CLI\ton')"
    assert_line "$(printf 'codex\tOpenAI agent CLI\toff')"
    assert_line "$(printf 'gemini\tGoogle agent CLI\toff')"
}

@test "tui_qs_tag_entries platform-filters tag rows too" {
    # rpi-4 is not in any optional module's supported_platforms → empty.
    run tui_qs_tag_entries "${FIXTURE_QS_LIST_JSON}" cli-essentials rpi-4
    assert_success
    assert_output ""
}

# ── Wizard e2e: scripted backend + recording mock CLI (§8.2.1) ───────────────
# Same harness shape as tui_backend_spec.bats: a scripted `dialog` pops one
# "rc|output" response per widget invocation; a mock `setup_ubuntu`
# (TUI_CLI) serves the fixtures and logs every fork to $E2E_CLI_LOG.

_make_qs_harness() {
    local _dir="${INIT_UBUNTU_TEST_SCRATCH}/qs"
    mkdir -p "${_dir}/bin" "${_dir}/home"
    E2E_BIN="${_dir}/bin"
    E2E_HOME="${_dir}/home"               # fs-snapshot target (must stay empty)
    E2E_RESPONSES="${_dir}/responses"     # popped one per widget invocation
    E2E_WIDGET_LOG="${_dir}/widget.log"
    E2E_CLI_LOG="${_dir}/cli.log"
    E2E_INSTALL_RC_FILE="${_dir}/install_rc"
    export E2E_BIN E2E_HOME E2E_RESPONSES E2E_WIDGET_LOG E2E_CLI_LOG \
           E2E_INSTALL_RC_FILE

    printf '%s\n' "${FIXTURE_QS_LIST_JSON}"   >"${_dir}/list.json"
    printf '%s\n' "${FIXTURE_QS_DETECT_JSON}" >"${_dir}/detect.json"

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

    # Mock CLI: logs argv; `install` honors an optional canned exit code so
    # the SIGINT-after-Proceed partial-install contract (exit 6) can replay.
    cat >"${E2E_BIN}/setup_ubuntu" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${E2E_CLI_LOG}"
case "\$*" in
    "list --json")   cat "${_dir}/list.json" ;;
    "detect --json") cat "${_dir}/detect.json" ;;
    "config set "*)  : ;;
    "install --dry-run "*)
        printf '[dispatcher] DRY-RUN: would install in this order:\n'
        printf '  - fzf\n  - ripgrep\n  - fdfind\n  - fnm\n'
        printf '  - neovim\n  - lazygit\n  - eza\n'
        ;;
    "install "*)
        printf 'CLI pipeline output\n'
        if [[ -f "${E2E_INSTALL_RC_FILE}" ]]; then
            printf 'partial summary: 2 ok / 5 not run\n'
            exit "\$(cat "${E2E_INSTALL_RC_FILE}")"
        fi
        ;;
esac
EOF
    chmod +x "${E2E_BIN}/dialog" "${E2E_BIN}/setup_ubuntu"
}

_run_qs_e2e() {
    # TUI_BACKEND pinned to the scripted `dialog` mock so the run bypasses
    # #171 detection / the gum install prompt (dialog is no longer a detected
    # backend; the dispatcher routes a dialog-named binary through the
    # whiptail family, whose --menu/--checklist shape the mock emulates).
    run env "PATH=${E2E_BIN}:${PATH}" "HOME=${E2E_HOME}" \
        "TUI_CLI=${E2E_BIN}/setup_ubuntu" \
        "TUI_BACKEND=${E2E_BIN}/dialog" \
        "${REPO_ROOT}/setup_ubuntu_tui.sh"
}

@test "e2e qs: four steps -> Review -> Proceed forks one named-only install" {
    _make_qs_harness
    # quick-setup → Step1 continue → Step2 keep only neovim → Step3 pick
    # lazygit+eza → Step4 uncheck everything (OK, empty) → Review → Proceed
    # → pre-install summary (#213) confirm Yes.
    cat >"${E2E_RESPONSES}" <<'EOF'
0|quick-setup
0|continue
0|neovim\n
0|pick
0|eza\nlazygit\n
0|
0|proceed
0|
EOF
    _run_qs_e2e
    assert_success
    assert_output --partial "CLI pipeline output"
    # §8.2.1 manual-flag matrix, structurally: the ONE real install fork
    # names exactly the user-picked modules (manual=true via the CLI's
    # named-install path)...
    run tail -n1 "${E2E_CLI_LOG}"
    assert_output "install neovim eza lazygit -y"
    # ...and the engine-pulled deps are NEVER named on any fork argv, so
    # they stay manual=false (fzf/ripgrep/fdfind/fnm in the §8.2.1 example).
    run grep -E "^install .*(fzf|ripgrep|fdfind|fnm)" "${E2E_CLI_LOG}"
    assert_failure
}

@test "e2e qs: Review builds the plan from a dry-run fork of the picks" {
    _make_qs_harness
    cat >"${E2E_RESPONSES}" <<'EOF'
0|quick-setup
0|continue
0|neovim\n
0|pick
0|eza\nlazygit\n
0|
0|proceed
0|
EOF
    _run_qs_e2e
    assert_success
    # The dry-run plan is forked twice (read-only): once for the Review screen
    # and once for the #213 pre-install summary — both over the same argv.
    run grep -c "^install --dry-run neovim eza lazygit$" "${E2E_CLI_LOG}"
    assert_output "2"
}

@test "e2e qs: platform override is written to config ONLY at Proceed" {
    _make_qs_harness
    # Step1 override → server → continue; Step2 keep docker; Step3 skip;
    # Step4 keep claude-code; Review → Proceed → pre-install summary Yes.
    cat >"${E2E_RESPONSES}" <<'EOF'
0|quick-setup
0|override
0|server
0|continue
0|docker\n
0|skip
0|claude-code\n
0|proceed
0|
EOF
    _run_qs_e2e
    assert_success
    # The config write happened exactly once, on the Proceed leg: it must
    # appear AFTER the (last) dry-run fork and BEFORE the install fork.
    run grep -c "^config set platform.override server$" "${E2E_CLI_LOG}"
    assert_output "1"
    local _dry _cfg _inst
    _dry="$(grep -n "^install --dry-run" "${E2E_CLI_LOG}" | tail -n1 | cut -d: -f1)"
    _cfg="$(grep -n "^config set" "${E2E_CLI_LOG}" | cut -d: -f1)"
    _inst="$(grep -n "^install --profile" "${E2E_CLI_LOG}" | cut -d: -f1)"
    [ "${_cfg}" -gt "${_dry}" ]
    [ "${_inst}" -gt "${_cfg}" ]
    # The install fork rides the override as --profile (§7.5).
    run tail -n1 "${E2E_CLI_LOG}"
    assert_output "install --profile=server docker claude-code -y"
}

@test "e2e qs: override narrows Step 2 to the overridden platform" {
    _make_qs_harness
    # Override to server: font/nvidia-driver (desktop-only) must not be
    # offered, so checking "everything on the page" cannot include them.
    cat >"${E2E_RESPONSES}" <<'EOF'
0|quick-setup
0|override
0|server
0|continue
0|docker\nneovim\ntmux\n
0|skip
0|
0|proceed
0|
EOF
    _run_qs_e2e
    assert_success
    run tail -n1 "${E2E_CLI_LOG}"
    assert_output "install --profile=server docker neovim tmux -y"
    # The Step-2 checklist argv itself never offered desktop-only rows.
    run grep -E "font|nvidia-driver" "${E2E_WIDGET_LOG}"
    assert_failure
}

@test "e2e qs: cancel mid-wizard is a pure cancel (zero forks, zero writes)" {
    _make_qs_harness
    # Override chosen at Step1, then Cancel at Step 3 → back to the main
    # menu → Exit. Nothing may have been persisted anywhere.
    cat >"${E2E_RESPONSES}" <<'EOF'
0|quick-setup
0|override
0|server
0|continue
0|docker\n
1|
1|
EOF
    _run_qs_e2e
    assert_success
    run grep -E "^(config set|install)" "${E2E_CLI_LOG}"
    assert_failure
    run find "${E2E_HOME}" -mindepth 1
    assert_output ""
}

@test "e2e qs: cancel on the Review screen before Proceed writes nothing" {
    _make_qs_harness
    # Full prepare with an override, but back out at Review → main menu →
    # Exit. The dry-run plan fork is read-only and allowed; no config set,
    # no real install.
    cat >"${E2E_RESPONSES}" <<'EOF'
0|quick-setup
0|override
0|server
0|continue
0|docker\n
0|skip
0|
1|
1|
EOF
    _run_qs_e2e
    assert_success
    run grep -c "^config set" "${E2E_CLI_LOG}"
    assert_failure
    run grep -E "^install ([^-]|-[^-]|--[^d])" "${E2E_CLI_LOG}"
    assert_failure
    run find "${E2E_HOME}" -mindepth 1
    assert_output ""
}

@test "e2e qs: nothing selected across all steps reports and forks nothing" {
    _make_qs_harness
    cat >"${E2E_RESPONSES}" <<'EOF'
0|quick-setup
0|continue
0|
0|skip
0|
0|
1|
EOF
    _run_qs_e2e
    assert_success
    run cat "${E2E_WIDGET_LOG}"
    assert_output --partial "nothing selected"
    run grep -E "^(config set|install)" "${E2E_CLI_LOG}"
    assert_failure
}

@test "e2e qs: SIGINT-after-Proceed contract — CLI exit 6 propagates with partial summary" {
    _make_qs_harness
    printf '6\n' >"${E2E_INSTALL_RC_FILE}"
    cat >"${E2E_RESPONSES}" <<'EOF'
0|quick-setup
0|continue
0|neovim\n
0|pick
0|eza\nlazygit\n
0|
0|proceed
0|
EOF
    _run_qs_e2e
    # §8.2.1 stage table: after Proceed the CLI pipeline owns the terminal;
    # the engine prints the partial summary and exits 6 — the TUI execs it
    # in the foreground and exits with the same code.
    assert_failure 6
    assert_output --partial "partial summary"
}
