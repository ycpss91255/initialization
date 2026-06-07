#!/usr/bin/env bash
# setup_ubuntu_tui.sh — init_ubuntu TUI entry point (PRD §8, G4)
#
# TUI = a frontend of the CLI (PRD §8 / G4): this script renders screens
# and collects selections ONLY.
#   - Menu data comes exclusively from forked `setup_ubuntu list --json` /
#     `setup_ubuntu detect --json` subprocesses (ADR-0019 schema).
#   - Every action forks a `setup_ubuntu <subcommand>` subprocess.
#   - It never sources engine libs (registry / resolver / runner / state)
#     and never writes state — enforced by the G4 grep gate in
#     test/unit/tui_backend_spec.bats.
#
# Issue #69 scope: skeleton + main-menu rendering. Mount points for the
# follow-ups are marked in _tui_dispatch below:
#   #70  checkbox accumulator + Run / Review & Install
#   #71  Quick Setup multi-step flow
#   #72  Manage Installed (update / remove / purge)
#
# `set -uo pipefail` (not -e): dialog/whiptail return rc 1/255 for the
# Cancel button and ESC, which is normal control flow here, not an error
# (same spirit as ADR-0007 — nonzero rcs carry contract meaning).

set -uo pipefail

# ── Path resolution ──────────────────────────────────────────────────────────
SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="${SCRIPT_PATH}"
# Env-overridable so the bats e2e harness can substitute a recording mock
# CLI; real sessions never set it and fork the sibling setup_ubuntu.sh.
TUI_CLI="${TUI_CLI:-${REPO_ROOT}/setup_ubuntu.sh}"
export TUI_CLI

: "${INIT_UBUNTU_VERSION:=0.1.0-draft}"

# G4: the ONLY library the TUI sources is its own presentation helper.
# shellcheck source=lib/tui_backend.sh
source "${REPO_ROOT}/lib/tui_backend.sh"

# ── In-memory session selections (Q43: never persisted by the TUI) ──────────
# Platform override chosen on the System Info screen. Consumed as
# `--profile=<value>` on action forks (#70 / #71 wire this through);
# it is NOT written to config.ini by the TUI (G4 / §8.2.1 cancel table).
TUI_PLATFORM_OVERRIDE=""

# ── Usage ────────────────────────────────────────────────────────────────────

_tui_usage() {
    cat <<'EOF'
Usage: setup_ubuntu_tui.sh [flags]

Interactive TUI frontend for setup_ubuntu. Renders menus with dialog
(preferred) or whiptail (Ubuntu default) and forks `setup_ubuntu`
subprocesses for all data and actions.

Flags:
  -h / --help            Show this help
  --version              Show tool version

Requirements:
  - `dialog` or `whiptail` on PATH (no auto-install; see PRD §8.5)
  - sudo available (otherwise exit 4 — use the CLI instead:
    `setup_ubuntu install <module>`)

See PRD §8 for the full TUI specification.
EOF
}

# ── Screens ──────────────────────────────────────────────────────────────────

# System Info (§8.1 item 7): show forked `setup_ubuntu detect` output and
# offer a platform override (kept in TUI memory only).
_tui_screen_system_info() {
    local _detect_text
    _detect_text="$("${TUI_CLI}" detect 2>/dev/null)" || {
        tui_render_msgbox "System Info" "ERROR: 'setup_ubuntu detect' failed."
        return 0
    }
    if [[ -n "${TUI_PLATFORM_OVERRIDE}" ]]; then
        _detect_text+=$'\n'"platform override:  ${TUI_PLATFORM_OVERRIDE} (this session)"
    fi
    tui_render_msgbox "System Info" "${_detect_text}"

    if ! tui_render_yesno "Platform Override" \
        "Override the detected platform (form factor) for this session?"; then
        return 0
    fi

    local _choice
    _choice="$(tui_render_menu "Platform Override" \
        "Select a form factor (PRD §7.5 --profile):" \
        "desktop"     "Desktop / laptop" \
        "server"      "Headless server" \
        "wsl"         "Windows Subsystem for Linux" \
        "rpi-4"       "Raspberry Pi 4" \
        "rpi-5"       "Raspberry Pi 5" \
        "jetson-orin" "NVIDIA Jetson Orin" \
        "detected"    "Clear override (use auto-detection)")" || return 0

    if [[ "${_choice}" == "detected" ]]; then
        TUI_PLATFORM_OVERRIDE=""
    else
        TUI_PLATFORM_OVERRIDE="${_choice}"
    fi
}

# Placeholder screen for follow-up issues — the dispatch seam stays stable
# while #71 / #72 replace these stubs with real screens.
_tui_screen_todo() {
    tui_render_msgbox "$1" "$1 is not wired up yet (tracked in issue $2)."
}

# ── Checkbox accumulator screens (#70, Q43 / §8.2) ───────────────────────────

# One category page as a pure check-list. < OK > stores the page in the
# in-memory accumulator (tui_selection_replace_page), < Back > / ESC
# discards the page. Nothing is executed and nothing touches disk here —
# `< Run >` on the main menu is the only batch execution point.
_tui_screen_category() {
    local _cat="$1" _json="$2"
    local -a _rows=()
    local _name _label _status
    while IFS=$'\t' read -r _name _label _status; do
        _rows+=("${_name}" "${_label}" "${_status}")
    done < <(tui_checklist_entries "${_json}" "${_cat}" \
        "$(tui_selection_list | tr '\n' ' ')")

    if [[ "${#_rows[@]}" -eq 0 ]]; then
        tui_render_msgbox "Modules" "No modules in category '${_cat}'."
        return 0
    fi

    local _picked
    if ! _picked="$(TUI_CANCEL_LABEL="Back" tui_render_checklist \
        "${_cat^} Modules" \
        "Check modules to install. < OK > keeps this page, < Back > discards it." \
        "${_rows[@]}")"; then
        return 0  # Back / ESC: discard this page's changes (Q43)
    fi

    local -a _names=()
    local _line
    while IFS= read -r _line; do
        [[ -n "${_line}" ]] && _names+=("${_line}")
    done <<<"${_picked}"
    tui_selection_replace_page "${_json}" "${_cat}" "${_names[@]}"
}

# < Run > (§8.1): Review & Install — full selection list + collapsed
# "will pull N deps" summary (arch Q-A3; expandable via a details row).
# Proceed clears the screen and hands the terminal to ONE forked CLI
# install pipeline (G4 / AC-11: same path as the CLI). Back keeps the
# selections and returns to the main menu.
_tui_screen_run() {
    if [[ "$(tui_selection_count)" -eq 0 ]]; then
        tui_render_msgbox "Review & Install" "nothing selected"
        return 0
    fi

    local -a _sel=()
    mapfile -t _sel < <(tui_selection_list)

    local _plan
    if ! _plan="$(tui_cli_install_plan "${_sel[@]}")"; then
        tui_render_msgbox "Review & Install" \
            "ERROR: 'setup_ubuntu install --dry-run' failed — cannot build the plan."
        return 0
    fi
    local -a _deps=()
    mapfile -t _deps < <(tui_plan_deps "${_plan}" "${_sel[@]}")

    local _text
    _text="Will install ${#_sel[@]} module(s):"$'\n'
    _text+="$(printf '  %s\n' "${_sel[@]}")"
    if [[ "${#_deps[@]}" -gt 0 ]]; then
        _text+=$'\n'"will pull ${#_deps[@]} deps"
    fi

    local -a _entries=("proceed" "Install now (forks setup_ubuntu)")
    if [[ "${#_deps[@]}" -gt 0 ]]; then
        _entries+=("deps" "Show dependency details (${#_deps[@]})")
    fi

    local _choice
    while :; do
        if ! _choice="$(TUI_CANCEL_LABEL="Back" tui_render_menu \
            "Review & Install" "${_text}" "${_entries[@]}")"; then
            return 0  # Back / Cancel: selections stay in memory (Q43)
        fi
        case "${_choice}" in
            deps)
                tui_render_msgbox "Dependency details" \
                    "$(printf '%s\n' "${_deps[@]}")"
                ;;
            proceed)
                _tui_exec_install "${_sel[@]}"  # never returns
                ;;
        esac
    done
}

# Proceed (§8.2.1): clear the screen, fork the CLI install pipeline in the
# foreground (exec_cmd stream + Action-required aggregation render on the
# plain terminal — no --gauge/--prgbox), then exit the TUI with its rc.
_tui_exec_install() {
    local -a _argv=()
    mapfile -t _argv < <(tui_install_args "${TUI_PLATFORM_OVERRIDE}" "$@")
    clear 2>/dev/null || printf '\033c'
    "${TUI_CLI}" "${_argv[@]}"
    exit $?
}

# ── Menu action dispatch (mount points for #71 / #72) ───────────────────────

_tui_dispatch() {
    case "$1" in
        quick-setup)
            # #71: Quick Setup multi-step flow (§8.2.1) → Review → fork
            # `setup_ubuntu install ... -y` with TUI_PLATFORM_OVERRIDE
            # (reuse _tui_exec_install for the Proceed leg).
            _tui_screen_todo "Quick Setup" "#71"
            ;;
        base | recommended | optional | experimental)
            _tui_screen_category "$1" "$2"
            ;;
        run)
            _tui_screen_run
            ;;
        manage)
            # #72: Manage Installed (§8.3 / §8.4 destructive confirms).
            _tui_screen_todo "Manage Installed" "#72"
            ;;
        secrets)
            # #72: forks setup_secrets.sh (§8.1 item 6).
            _tui_screen_todo "Manage Secrets" "#72"
            ;;
        sysinfo)
            _tui_screen_system_info
            ;;
    esac
}

# ── Main menu loop (§8.1) ────────────────────────────────────────────────────

_tui_main_loop() {
    local _list_json _detect_json _summary
    _detect_json="$(tui_cli_detect_json)" || return 1
    _list_json="$(tui_cli_list_json)" || return 1
    _summary="$(tui_system_summary "${_detect_json}")"

    local _choice _tag _label _desc
    while :; do
        local -a _menu_args=()
        while IFS=$'\t' read -r _tag _label _desc; do
            _menu_args+=("${_tag}" "$(printf '%-22s %s' "${_label}" "${_desc}")")
        done < <(tui_main_menu_entries "${_list_json}")

        # < Exit > (relabeled Cancel) / ESC: drop the process and with it
        # every in-memory selection — zero side effects (Q43).
        _choice="$(TUI_CANCEL_LABEL="Exit" tui_render_menu \
            "init_ubuntu v${INIT_UBUNTU_VERSION}" \
            "System: ${_summary}" "${_menu_args[@]}")" || return 0
        _tui_dispatch "${_choice}" "${_list_json}"
    done
}

# ── Entry ────────────────────────────────────────────────────────────────────

main() {
    local _arg
    for _arg in "$@"; do
        case "${_arg}" in
            -h | --help)
                _tui_usage
                return 0
                ;;
            --version)
                printf 'init_ubuntu %s\n' "${INIT_UBUNTU_VERSION}"
                return 0
                ;;
            *)
                printf 'ERROR: unknown flag %s\n\n' "${_arg}" >&2
                _tui_usage >&2
                return 2
                ;;
        esac
    done

    tui_require_sudo || return $?
    tui_backend_init || return $?

    # The TUI parses ADR-0019 JSON with jq. jq is a CLI self-dep
    # (lib/preflight.sh installs it on the first `setup_ubuntu` run), so
    # only a never-ran-the-CLI box hits this.
    if ! _tui_has_cmd jq; then
        printf 'ERROR: jq not found. Run any setup_ubuntu command once\n' >&2
        printf '       (its preflight offers to install jq), e.g.: setup_ubuntu list\n' >&2
        return 1
    fi

    _tui_main_loop
}

main "$@"
exit $?
