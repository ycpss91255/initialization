#!/usr/bin/env bash
# test/helper/tui_real_install.bash — helpers for the AC-11 TUI → Proceed →
# REAL install integration spec (issue #178, stream S2).
#
# The gap this closes: the AC-10 smoke (tui_smoke_spec.bats) stops at < Exit >
# and forks NOTHING that installs — its TUI_CLI is a recording mock. No test
# ever drove the TUI's Proceed leg into the REAL install pipeline
#   setup_ubuntu_tui.sh (Run → Review → Proceed)
#     → forks setup_ubuntu install <picks> -y
#       → dispatcher → runner → source module → archetype macro → lifecycle
# proving CLI/TUI parity on the SAME engine the keystone harness (#175) covers
# — not a stub.
#
# Design (two seams, one process):
#   - DATA seam: the TUI reads its menu from `${TUI_CLI} list/detect --json`.
#     A wrapper CLI (this file builds it) answers those reads from a CONTROLLED
#     fixture (gum as the lone Optional module) so the pty navigation is
#     deterministic — exactly the deterministic-data discipline the smoke uses.
#   - REAL engine: for EVERY non-data subcommand (install / install --dry-run)
#     the SAME wrapper `exec`s the real setup_ubuntu.sh with the #175 offline
#     github-release seam set, so the Proceed fork runs the real dispatcher →
#     runner → module → archetype → extract → state.json → Sidecar → binary.
#
# Non-root: the dispatcher install refuses EUID 0 (PRD §10); the container is
# root. So the TUI (and its forked install) run as a freshly-created non-root
# user — reusing the engine_lifecycle.bash provisioning (sourced read-only).
#
# Load AFTER helper/common AND helper/engine_lifecycle (this file builds on the
# ENGINE_LT_* user/scratch contract those provide).

# tri_make_list_fixture — write a `list --json` payload with gum as the ONLY
# Optional module (and nothing else), so:
#   - the main menu has exactly one category row (Optional), making Run a
#     fixed number of rows down from the top;
#   - the Optional checklist has gum at row 0 (sort_by tags[0],name), so a
#     single Space toggles it.
# Mirrors the real gum metadata (github-release, user-home, no deps shown:
# depends_on=[] keeps the "(will pull N deps)" hint off and the Review plan a
# single line — the real --no-deps install the wrapper forks matches this).
tri_make_list_fixture() {
    cat <<'EOF'
{
  "schema_version": "1",
  "scope": "available",
  "filters": {"category": null, "tag": null},
  "items": [
    {"name": "gum", "category": "optional", "tags": ["cli-essentials", "tui"],
     "description": "glamorous shell scripts toolkit", "version_provided": "github-release",
     "installed": false, "outdated": null, "manual": null,
     "depends_on": [], "supports_user_home": true,
     "supported_platforms": ["desktop", "server", "wsl"], "supported_ubuntu": ["24.04"],
     "risk_level": "low", "reboot_required": false, "homepage": "https://github.com/charmbracelet/gum"}
  ],
  "count": 1,
  "generated_at": "2026-06-19T00:00:00+08:00"
}
EOF
}

# tri_make_detect_fixture — minimal `detect --json` for the System Info /
# header path (the Run flow never opens it, but the main menu summary reads it).
tri_make_detect_fixture() {
    cat <<'EOF'
{"os":{"id":"ubuntu","version":"24.04","codename":"noble"},"arch":"x86_64","cpu":{"vendor":"GenuineIntel"},"gpu":{"vendor":null,"model":null},"desktop":null,"session_type":null,"virt":{"container":true,"vm":false},"wsl":false,"board":null,"form_factor":"server"}
EOF
}

# tri_setup_env — build the sealed run dir for the real-install flow:
#   * symlink farm (sealed PATH; carries the ONE backend under test too)
#   * controlled list/detect fixtures
#   * a wrapper `setup_ubuntu` that routes data reads → fixtures and
#     install/dry-run → the REAL setup_ubuntu.sh as the non-root user, with
#     the #175 gh seam + INIT_UBUNTU_NO_DEPS (so gum installs offline without
#     dragging its apt-essentials dep onto the apt-less alpine harness).
#
# Requires (from engine_lifecycle.bash, called first by the spec setup):
#   ENGINE_LT_USER ENGINE_LT_HOME ENGINE_LT_STATE ENGINE_LT_CONFIG
#   ENGINE_LT_FIXTURE ENGINE_LT_BACKUP
# Exports:
#   TRI_DIR        run dir (sealed)
#   TRI_BIN        sealed PATH dir (farm + wrapper + backend)
#   TRI_CLI        wrapper setup_ubuntu path (TUI_CLI for the run)
#   TRI_CLI_LOG    every wrapper invocation argv, one per line
tri_setup_env() {
    local _backend="${1:?backend}"
    local _gh_version="${2:?gh version}"

    TRI_DIR="${ENGINE_LT_SCRATCH}/tui-real-install"
    TRI_BIN="${TRI_DIR}/bin"
    TRI_CLI="${TRI_BIN}/setup_ubuntu"
    TRI_CLI_LOG="${TRI_DIR}/cli.log"
    export TRI_DIR TRI_BIN TRI_CLI TRI_CLI_LOG
    rm -rf "${TRI_DIR}"
    mkdir -p "${TRI_BIN}"

    tri_make_list_fixture   >"${TRI_DIR}/list.json"
    tri_make_detect_fixture >"${TRI_DIR}/detect.json"

    # The symlink farm (sealed PATH) + the live backend binary, same recipe as
    # the smoke harness so `command -v ${_backend}` resolves to the real one.
    tui_harness_farm "${TRI_BIN}"
    # `expect`/`su`/`env` aren't needed inside the farm (the wrapper uses
    # absolute paths), but the wrapper does `exec bash <real>`; `bash` is
    # already in the farm. The real install also needs the host toolchain
    # (tar, gzip, sed, mktemp, date, chmod, ln, mkdir, rm, cp, install, id,
    # uname) — those live on the system PATH the wrapper restores before exec.
    local _real
    if ! _real="$(command -v "${_backend}")"; then
        printf 'tri_setup_env: backend not in image: %s\n' "${_backend}" >&2
        return 1
    fi
    ln -sf "${_real}" "${TRI_BIN}/${_backend}"

    # The TUI's startup gate (tui_require_sudo) demands `sudo` be USABLE before
    # it draws anything — a non-root, sudo-less harness would bail with the
    # "switch to CLI mode" error. gum is a user-home / no-sudo module
    # (USE_SUDO=false), so the real install NEVER escalates; only the startup
    # probe (`sudo -n true`) needs to pass. A tiny passwordless shim satisfies
    # the probe without granting any privilege: `sudo -n true` → rc 0, and any
    # real `sudo <cmd>` (never reached for gum) just runs <cmd> as-is. This is
    # a harness seam, NOT a TUI/lib edit.
    cat >"${TRI_BIN}/sudo" <<'EOF'
#!/usr/bin/env bash
# probe form: `sudo -n true` (and friends) → succeed without escalating.
if [[ "$1" == "-n" ]]; then shift; fi
[[ "$#" -eq 0 || "$1" == "true" ]] && exit 0
# passthrough (unused by user-home gum): run the command unprivileged.
exec "$@"
EOF
    chmod +x "${TRI_BIN}/sudo"

    # The wrapper. Data reads → fixtures (deterministic pty nav). Everything
    # else (install, install --dry-run) → REAL setup_ubuntu.sh with:
    #   - the offline github-release seam (#175): version constant + fixture dir
    #   - INIT_UBUNTU_NO_DEPS=true: gum's apt-essentials dep can't install on
    #     the apt-less alpine harness; --no-deps scopes the real install to gum
    #     (the engine keystone proves the same scoping). The TUI forks WITHOUT
    #     --no-deps, so we inject it via the env contract the dispatcher honors
    #     (`: "${INIT_UBUNTU_NO_DEPS:=false}"`), NOT by editing the TUI.
    #   - a SYSTEM PATH restore so the real install finds tar/gzip/etc — the
    #     sealed farm PATH the TUI runs under is intentionally minimal.
    # The wrapper logs argv first so the spec can prove the Proceed fork hit
    # the real `install` path (not a mock, not a dry-run-only stub).
    cat >"${TRI_CLI}" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${TRI_CLI_LOG}"
case "\$*" in
    "list --json")   cat "${TRI_DIR}/list.json" ;;
    "detect --json") cat "${TRI_DIR}/detect.json" ;;
    detect)          cat "${TRI_DIR}/detect.json" ;;
    *)
        # Real engine. Restore a real PATH (the TUI runs under the sealed
        # farm), wire the scratch dirs + the offline gh seam, then exec the
        # real entrypoint so its rc becomes the wrapper's rc (TUI propagates).
        export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        export HOME="${ENGINE_LT_HOME}"
        export INIT_UBUNTU_STATE_DIR="${ENGINE_LT_STATE}"
        export INIT_UBUNTU_CONFIG_DIR="${ENGINE_LT_CONFIG}"
        export BACKUP_DIR="${ENGINE_LT_BACKUP}"
        export INIT_UBUNTU_NO_DEPS=true
        export INIT_UBUNTU_TEST_GH_VERSION="${_gh_version}"
        export INIT_UBUNTU_TEST_GH_FIXTURE_DIR="${ENGINE_LT_FIXTURE}"
        export LOG_COLOR=false LOG_LEVEL=INFO
        exec bash "${REPO_ROOT}/setup_ubuntu.sh" "\$@"
        ;;
esac
EOF
    chmod +x "${TRI_CLI}"

    chown -R "${ENGINE_LT_USER}:${ENGINE_LT_USER}" "${TRI_DIR}"
}

# tri_run_flow <flow.exp> [extra exp args...]
#   Drive the real TUI on a pseudo-tty AS THE NON-ROOT USER (su), with the
#   sealed farm PATH + the wrapper as TUI_CLI. The expect flow walks
#   Run → Review → Proceed; the wrapper's exec then runs the real install.
#   Populates bats $status/$output via `run`.
#
# `su` re-resolves the environment, so every var the expect lib reads is set
# explicitly on the command line. expect itself is invoked by absolute path
# (resolved on the bats/root PATH) because the sealed farm omits it — the farm
# only needs to seal what the TUI's OWN `command -v` probes (the backend).
tri_run_flow() {
    local _flow="${1:?flow.exp}"; shift
    local _expect
    _expect="$(command -v expect)" || {
        printf 'tri_run_flow: expect not found\n' >&2
        return 1
    }
    run su "${ENGINE_LT_USER}" -c \
        "TUI_ENTRY='${REPO_ROOT}/setup_ubuntu_tui.sh' \
         TUI_FARM='${TRI_BIN}' \
         TUI_HOME='${ENGINE_LT_HOME}' \
         TUI_CLI_MOCK='${TRI_CLI}' \
         '${_expect}' '${_flow}' ${*}"
}

# tri_assert_real_install_forked — the wrapper log must show the Proceed leg
# forked the REAL `install` action (not list/detect, not a dry-run-only stub).
# The dry-run plan fork (Review screen) is expected too, but a bare `install …`
# WITHOUT --dry-run is the load-bearing proof of the real pipeline fork.
tri_assert_real_install_forked() {
    [[ -f "${TRI_CLI_LOG}" ]] || {
        printf 'tri_assert: no wrapper log at %s\n' "${TRI_CLI_LOG}" >&2
        return 1
    }
    # A line that starts with `install ` and does NOT contain `--dry-run`.
    grep -E '^install( |$)' "${TRI_CLI_LOG}" | grep -qv -- '--dry-run'
}
