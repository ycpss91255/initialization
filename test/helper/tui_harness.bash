#!/usr/bin/env bash
# test/helper/tui_harness.bash — reusable TUI test harness (AC-10, both layers)
#
# Shared by:
#   - test/unit/tui_backend_spec.bats          (#69/#70 unit + scripted e2e)
#   - test/unit/tui_ac10_spec.bats             (AC-10 layer 1: dual-backend
#                                               command-string suite)
#   - test/integration/tui/tui_smoke_spec.bats (AC-10 layer 2: expect smoke
#                                               on the REAL widgets)
#
# Provides:
#   FIXTURE_LIST_JSON / FIXTURE_DETECT_JSON   ADR-0019 payload fixtures
#   tui_harness_farm <bindir>                 sealed-PATH symlink farm
#   tui_harness_mock_cli <bindir> <datadir> <logfile>
#                                             recording mock `setup_ubuntu`
#   tui_e2e_make_harness [dialog|whiptail]    scripted-widget e2e harness
#   tui_e2e_run                               run the real TUI under it
#
# Load AFTER helper/common (needs INIT_UBUNTU_TEST_SCRATCH + bats-assert).

# ── ADR-0019 fixtures ────────────────────────────────────────────────────────
# Minimal `list --json` payload: base/recommended/optional populated,
# experimental EMPTY (mirrors the current catalog — Q44 case).

FIXTURE_LIST_JSON="$(cat <<'EOF'
{
  "schema_version": "1",
  "scope": "available",
  "filters": {"category": null, "tag": null},
  "items": [
    {"name": "curl", "category": "base", "tags": ["http"],
     "description": "HTTP client", "version_provided": "apt-managed",
     "installed": true, "outdated": false, "manual": false,
     "depends_on": [], "supports_user_home": false,
     "supported_platforms": ["desktop", "server"], "supported_ubuntu": ["24.04"],
     "risk_level": "low", "reboot_required": false, "homepage": null},
    {"name": "docker", "category": "recommended", "tags": ["container"],
     "description": "Docker Engine", "version_provided": "apt-managed",
     "installed": true, "outdated": false, "manual": true,
     "depends_on": ["curl"], "supports_user_home": false,
     "supported_platforms": ["desktop", "server"], "supported_ubuntu": ["24.04"],
     "risk_level": "low", "reboot_required": false, "homepage": "https://docs.docker.com/"},
    {"name": "neovim", "category": "recommended", "tags": ["editor"],
     "description": "Neovim editor", "version_provided": "v0.10.2",
     "installed": false, "outdated": null, "manual": null,
     "depends_on": null, "supports_user_home": true,
     "supported_platforms": ["desktop", "server", "wsl"], "supported_ubuntu": ["24.04"],
     "risk_level": "low", "reboot_required": false, "homepage": "https://neovim.io/"},
    {"name": "eza", "category": "optional", "tags": ["cli-essentials"],
     "description": "ls alternative", "version_provided": "github-release",
     "installed": false, "outdated": null, "manual": null,
     "depends_on": null, "supports_user_home": true,
     "supported_platforms": ["desktop", "server", "wsl"], "supported_ubuntu": ["24.04"],
     "risk_level": "low", "reboot_required": false, "homepage": "https://eza.rocks/"},
    {"name": "zoxide", "category": "optional", "tags": ["cli-essentials"],
     "description": "cd alternative", "version_provided": "github-release",
     "installed": false, "outdated": null, "manual": null,
     "depends_on": null, "supports_user_home": true,
     "supported_platforms": ["desktop", "server", "wsl"], "supported_ubuntu": ["24.04"],
     "risk_level": "low", "reboot_required": false, "homepage": null},
    {"name": "claude-code", "category": "optional", "tags": ["agent"],
     "description": "Anthropic agent CLI", "version_provided": "npm",
     "installed": false, "outdated": null, "manual": null,
     "depends_on": null, "supports_user_home": true,
     "supported_platforms": ["desktop", "server", "wsl"], "supported_ubuntu": ["24.04"],
     "risk_level": "low", "reboot_required": false, "homepage": null}
  ],
  "count": 6,
  "generated_at": "2026-06-07T00:00:00+08:00"
}
EOF
)"
export FIXTURE_LIST_JSON

# `detect --json` fixture (lib/detect.sh shape + form_factor splice).
FIXTURE_DETECT_JSON="$(cat <<'EOF'
{"os":{"id":"ubuntu","version":"24.04","codename":"noble"},"arch":"x86_64","cpu":{"vendor":"GenuineIntel"},"gpu":{"vendor":"nvidia","model":"NVIDIA RTX 4090"},"desktop":"GNOME","session_type":"x11","virt":{"container":false,"vm":false},"wsl":false,"board":null,"form_factor":"desktop"}
EOF
)"
export FIXTURE_DETECT_JSON

# ── Sealed-PATH symlink farm ─────────────────────────────────────────────────
# Backend detection (`command -v`) must see ONLY the backend the test put
# there — the container's real dialog/whiptail can never shadow it. The
# farm carries every external command the TUI + mocks need at runtime
# (everything else is bash builtins); `bash` itself is required because
# `#!/usr/bin/env bash` resolves bash through the sealed PATH.

# cut/mktemp/mv/rm are added for the fzf Rich tier (ADR-0024): the navigator
# slices the token column with `cut`, allocates the selection-state file with
# `mktemp`, and the selstate accessors rewrite it via `mv`/`rm`.
TUI_HARNESS_FARM_CMDS=(bash dirname jq awk sort tr cat sed head grep cut mktemp mv rm)

tui_harness_farm() {
    local _bindir="$1" _cmd _path
    for _cmd in "${TUI_HARNESS_FARM_CMDS[@]}"; do
        if ! _path="$(command -v "${_cmd}")"; then
            printf 'tui_harness: missing host command: %s\n' "${_cmd}" >&2
            return 1
        fi
        ln -sf "${_path}" "${_bindir}/${_cmd}"
    done
}

# ── Recording mock `setup_ubuntu` (TUI_CLI override) ─────────────────────────
# Serves the ADR-0019 fixtures from <datadir>, logs every fork to <logfile>.
# Future TUI screens (#71 Quick Setup, #72 Manage Installed) extend the
# `case` table here so both test layers pick the new subcommands up.

tui_harness_mock_cli() {
    local _bindir="$1" _datadir="$2" _logfile="$3"
    printf '%s\n' "${FIXTURE_LIST_JSON}"   >"${_datadir}/list.json"
    printf '%s\n' "${FIXTURE_DETECT_JSON}" >"${_datadir}/detect.json"
    # MOCK_TUI_HINTS (read from the env at fork time) lets a test choose what
    # `config get ui.tui_hints` returns ("off" / "on" / unset → empty). The
    # TUI reads this ONCE at startup (#203); the logged line is the single-read
    # assertion grep target.
    cat >"${_bindir}/setup_ubuntu" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${_logfile}"
case "\$*" in
    "config get ui.tui_hints") printf '%s\n' "\${MOCK_TUI_HINTS:-}" ;;
    "list --json")   cat "${_datadir}/list.json" ;;
    "detect --json") cat "${_datadir}/detect.json" ;;
    detect)          cat "${_datadir}/detect.json" ;;
    "install --dry-run "*)
        printf '[dispatcher] DRY-RUN: would install in this order:\n'
        printf '  - fzf\n  - neovim\n  - eza\n  - zoxide\n'
        ;;
    "install "*) printf 'CLI pipeline output\n' ;;
esac
EOF
    chmod +x "${_bindir}/setup_ubuntu"
}

# ── Scripted-widget e2e harness (AC-10 layer 1) ──────────────────────────────
# Drives the REAL setup_ubuntu_tui.sh process with a scripted widget binary
# (named `dialog` or `whiptail`) — each invocation pops one "rc|output"
# line from $E2E_RESPONSES (a canned user interaction) and replays it like
# the live widget (output on stderr, rc as button), logging argv.
#
# Usage:
#   tui_e2e_make_harness whiptail     # or: tui_e2e_make_harness  (dialog)
#   cat >"${E2E_RESPONSES}" <<'EOF' ... EOF
#   tui_e2e_run

tui_e2e_make_harness() {
    local _widget="${1:-dialog}"
    local _dir="${INIT_UBUNTU_TEST_SCRATCH}/e2e-${_widget}"
    rm -rf "${_dir}"
    mkdir -p "${_dir}/bin" "${_dir}/home"
    E2E_BIN="${_dir}/bin"
    E2E_HOME="${_dir}/home"               # fs-snapshot target (must stay empty)
    E2E_RESPONSES="${_dir}/responses"     # popped one per widget invocation
    E2E_WIDGET_LOG="${_dir}/widget.log"
    E2E_CLI_LOG="${_dir}/cli.log"
    # Absolute path to the scripted widget — pinned into TUI_BACKEND by
    # tui_e2e_run so the run bypasses #171 detection / the gum install prompt.
    E2E_WIDGET_PATH="${E2E_BIN}/${_widget}"
    export E2E_BIN E2E_HOME E2E_RESPONSES E2E_WIDGET_LOG E2E_CLI_LOG \
           E2E_WIDGET_PATH

    tui_harness_farm "${E2E_BIN}"
    tui_harness_mock_cli "${E2E_BIN}" "${_dir}" "${E2E_CLI_LOG}"

    cat >"${E2E_BIN}/${_widget}" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${E2E_WIDGET_LOG}"
_line="\$(head -n1 "${E2E_RESPONSES}")"
sed -i 1d "${E2E_RESPONSES}"
_rc="\${_line%%|*}"
_out="\${_line#*|}"
[[ -n "\${_out}" ]] && printf '%b' "\${_out}" >&2
exit "\${_rc}"
EOF
    chmod +x "${E2E_BIN}/${_widget}"
}

# Run the real TUI under the sealed harness PATH (bats `run` semantics).
# TUI_BACKEND is pinned to the scripted-widget mock path so the run bypasses
# #171 backend detection / the gum install prompt entirely: the adapter
# dispatcher keys on the basename, so a mock named `dialog`/`whiptail` routes
# through the whiptail family (the shared --menu/--checklist shape these
# scripted widgets emulate), regardless of detection preference.
tui_e2e_run() {
    # MOCK_TUI_HINTS reaches the forked mock `setup_ubuntu` so a test can drive
    # the startup `config get ui.tui_hints` read (#203). `env` resets the
    # environment to the listed vars only, so it must be passed explicitly.
    run env "PATH=${E2E_BIN}" "HOME=${E2E_HOME}" \
        "TUI_CLI=${E2E_BIN}/setup_ubuntu" \
        "TUI_BACKEND=${E2E_WIDGET_PATH}" \
        "MOCK_TUI_HINTS=${MOCK_TUI_HINTS:-}" \
        "${REPO_ROOT}/setup_ubuntu_tui.sh"
}
