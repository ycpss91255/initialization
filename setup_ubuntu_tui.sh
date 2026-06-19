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
# Issue #69 scope: skeleton + main-menu rendering. Follow-ups (all landed):
#   #70  checkbox accumulator + Run / Review & Install
#   #71  Quick Setup multi-step wizard (§8.2.1)
#   #72  Manage Installed (update / remove / purge) + Manage Secrets
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
# Same override seam for the Manage Secrets fork target (§8.1 item 6).
TUI_SECRETS="${TUI_SECRETS:-${REPO_ROOT}/setup_secrets.sh}"
export TUI_SECRETS

: "${INIT_UBUNTU_VERSION:=0.1.0-draft}"

# G4: the ONLY library the TUI sources is its own presentation helper.
# shellcheck source=lib/tui_backend.sh
source "${REPO_ROOT}/lib/tui_backend.sh"

# ── In-memory session selections (Q43: never persisted by the TUI) ──────────
# Platform override chosen on the System Info screen. Consumed as
# `--profile=<value>` on action forks; it is NOT written to config.ini by
# the TUI (G4 / §8.2.1 cancel table).
TUI_PLATFORM_OVERRIDE=""
# The Quick Setup Step-1 override (§8.2.1) is deliberately NOT a global:
# it lives in _tui_screen_quick_setup's locals during prepare and reaches
# config.ini only on the Proceed leg, via a forked
# `setup_ubuntu config set platform.override <v>` (the TUI itself never
# writes the file).
# Manage Installed view mode (§8.3 "group by TAGS[0]" toggle). Session-only,
# like every other piece of TUI state.
TUI_MANAGE_GROUPED="false"

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

    local -a _choices=()
    local _tag _desc
    while IFS=$'\t' read -r _tag _desc; do
        _choices+=("${_tag}" "${_desc}")
    done < <(tui_platform_choices)
    _choices+=("detected" "Clear override (use auto-detection)")

    local _choice
    _choice="$(tui_render_menu "Platform Override" \
        "Select a form factor (PRD §7.5 --profile):" \
        "${_choices[@]}")" || return 0

    if [[ "${_choice}" == "detected" ]]; then
        TUI_PLATFORM_OVERRIDE=""
    else
        TUI_PLATFORM_OVERRIDE="${_choice}"
    fi
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

# Review & Install screen shared by < Run > (#70) and Quick Setup (#71):
#   _tui_screen_review <module...>
# Full selection list + collapsed "will pull N deps" summary (arch Q-A3;
# expandable via a details row). Pure decision screen: rc 0 = the user
# chose Proceed (the caller forks the ONE CLI install pipeline — G4 /
# AC-11: same path as the CLI), rc 1 = Back / Cancel / plan failure; the
# caller decides what selection memory survives (Run: the Q43 accumulator
# stays; Quick Setup: the wizard locals die with the caller → pure cancel).
_tui_screen_review() {
    local -a _sel=("$@")

    local _plan
    if ! _plan="$(tui_cli_install_plan "${_sel[@]}")"; then
        tui_render_msgbox "Review & Install" \
            "ERROR: 'setup_ubuntu install --dry-run' failed — cannot build the plan."
        return 1
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
            return 1  # Back / Cancel: the caller owns what survives
        fi
        case "${_choice}" in
            deps)
                tui_render_msgbox "Dependency details" \
                    "$(printf '%s\n' "${_deps[@]}")"
                ;;
            proceed)
                return 0
                ;;
        esac
    done
}

# < Run > (§8.1): Review & Install over the Q43 accumulator. Back keeps
# the selections and returns to the main menu.
_tui_screen_run() {
    if [[ "$(tui_selection_count)" -eq 0 ]]; then
        tui_render_msgbox "Review & Install" "nothing selected"
        return 0
    fi

    local -a _sel=()
    mapfile -t _sel < <(tui_selection_list)
    _tui_screen_review "${_sel[@]}" || return 0
    _tui_exec_install "${_sel[@]}"  # never returns
}

# Shared Proceed leg (§8.2.1 execution model): clear the screen, fork ONE
# CLI pipeline in the foreground (exec_cmd stream + Action-required
# aggregation render on the plain terminal — no --gauge/--prgbox), then
# exit the TUI with its rc. Used by Run/Proceed (#70), Quick Setup (#71)
# and the Manage Installed actions (#72) — G4 single execution path.
_tui_exec_cli() {
    clear 2>/dev/null || printf '\033c'
    "${TUI_CLI}" "$@"
    exit $?
}

_tui_exec_install() {
    local -a _argv=()
    mapfile -t _argv < <(tui_install_args "${TUI_PLATFORM_OVERRIDE}" "$@")
    _tui_exec_cli "${_argv[@]}"
}

# ── Quick Setup wizard (#71, §8.2.1) ─────────────────────────────────────────
# Four prepare steps accumulate picks into FUNCTION-LOCAL memory, then the
# shared Review screen executes via _tui_qs_proceed. Prepare is pure
# memory (§8.2.1 cancel table): Cancel / ESC at any step returns to the
# main menu having forked nothing that writes — no config.ini write, no
# state write. SIGINT during prepare kills the TUI process outright with
# the same zero-side-effect guarantee; SIGINT after Proceed lands in the
# foreground CLI pipeline, which finishes the current step, prints the
# partial summary and exits 6 (ADR-0015 partial-install policy) — the
# exec in _tui_exec_install propagates that rc as the TUI's own.

# Step 1 submenu: pick an override form factor. Prints the choice;
# rc != 0 = Cancel (keep the current value).
_tui_qs_platform_menu() {
    local -a _choices=()
    local _tag _desc
    while IFS=$'\t' read -r _tag _desc; do
        _choices+=("${_tag}" "${_desc}")
    done < <(tui_platform_choices)
    tui_render_menu "Quick Setup — Platform Override" \
        "Select a form factor (PRD §7.5 --profile):" "${_choices[@]}"
}

# Steps 2-4 below print the picked module names (one per line) on stdout;
# rc != 0 = Cancel / ESC → the wizard aborts (pure cancel). A step with no
# offerable modules prints nothing and succeeds (skipped transparently).

# Step 2/4: recommended modules, is_recommended-preselected (Q36-filtered).
_tui_qs_step2() {
    local -a _rows=()
    local _name _label _status _on=0
    while IFS=$'\t' read -r _name _label _status; do
        _rows+=("${_name}" "${_label}" "${_status}")
        [[ "${_status}" == "on" ]] && _on=$((_on + 1))
    done < <(tui_qs_recommended_entries "$1" "$2")
    [[ "${#_rows[@]}" -eq 0 ]] && return 0

    tui_render_checklist "Quick Setup — Step 2/4: Recommended modules" \
        "${_on} / $(( ${#_rows[@]} / 3 )) will be installed — adjust and press OK." \
        "${_rows[@]}"
}

# Step 3/4: the CLI-essentials suite — whole suite / pick / skip (§8.2.1).
_tui_qs_step3() {
    local -a _rows=() _names=()
    local _name _label _status
    while IFS=$'\t' read -r _name _label _status; do
        _rows+=("${_name}" "${_label}" "${_status}")
        _names+=("${_name}")
    done < <(tui_qs_tag_entries "$1" cli-essentials "$2")
    [[ "${#_rows[@]}" -eq 0 ]] && return 0

    local _joined
    _joined="$(printf '%s / ' "${_names[@]}")"
    _joined="${_joined% / }"

    local _choice
    _choice="$(tui_render_menu \
        "Quick Setup — Step 3/4: CLI Essentials suite? (${#_names[@]} tools)" \
        "${_joined}" \
        "all"  "Yes, install all" \
        "pick" "Pick individually" \
        "skip" "Skip")" || return 1
    case "${_choice}" in
        all)  printf '%s\n' "${_names[@]}" ;;
        pick) tui_render_checklist "Quick Setup — Step 3/4: CLI Essentials" \
                  "Check the tools to install." "${_rows[@]}" || return 1 ;;
        skip) : ;;
    esac
}

# Step 4/4: AI agent CLI multi-select (recommended ones preselected).
_tui_qs_step4() {
    local -a _rows=()
    local _name _label _status
    while IFS=$'\t' read -r _name _label _status; do
        _rows+=("${_name}" "${_label}" "${_status}")
    done < <(tui_qs_tag_entries "$1" agent "$2")
    [[ "${#_rows[@]}" -eq 0 ]] && return 0

    tui_render_checklist "Quick Setup — Step 4/4: AI agent CLI? (multi-select)" \
        "Check the agent CLIs to install." "${_rows[@]}"
}

# §8.2.1 wizard driver: Step 1 platform confirm → Steps 2-4 accumulate →
# Review & Install (shared screen) → Proceed leg.
_tui_screen_quick_setup() {
    local _list_json="$1" _detect_json="$2"
    local _override="" _form _summary _choice _picked
    _summary="$(tui_system_summary "${_detect_json}")"

    # Step 1/4: confirm platform. An override only updates wizard memory;
    # re-render the confirmation so the user approves the final value.
    while :; do
        _form="$(tui_effective_form_factor "${_detect_json}" "${_override}")"
        _choice="$(tui_render_menu \
            "Quick Setup — Step 1/4: Confirm platform" \
            "Detected: ${_summary}"$'\n'"Form factor: ${_form}" \
            "continue" "Yes, continue" \
            "override" "Override platform")" || return 0
        [[ "${_choice}" == "continue" ]] && break
        if _picked="$(_tui_qs_platform_menu)"; then
            _override="${_picked}"
        fi
    done

    local -a _sel=()
    local _out _line
    _out="$(_tui_qs_step2 "${_list_json}" "${_form}")" || return 0
    while IFS= read -r _line; do
        [[ -n "${_line}" ]] && _sel+=("${_line}")
    done <<<"${_out}"
    _out="$(_tui_qs_step3 "${_list_json}" "${_form}")" || return 0
    while IFS= read -r _line; do
        [[ -n "${_line}" ]] && _sel+=("${_line}")
    done <<<"${_out}"
    _out="$(_tui_qs_step4 "${_list_json}" "${_form}")" || return 0
    while IFS= read -r _line; do
        [[ -n "${_line}" ]] && _sel+=("${_line}")
    done <<<"${_out}"

    if [[ "${#_sel[@]}" -eq 0 ]]; then
        tui_render_msgbox "Quick Setup" "nothing selected"
        return 0
    fi

    # Review backing out before Proceed = pure cancel: the override and
    # the picks die with this function's locals (§8.2.1 cancel table).
    _tui_screen_review "${_sel[@]}" || return 0

    # Proceed leg: the ONE point where the Step-1 override leaves TUI
    # memory (§8.2.1 "not written to config.ini until Review"). Persisting
    # goes through a `setup_ubuntu config set` fork (G4: the TUI never
    # writes config itself), then the shared exec leg forks the install
    # pipeline with `--profile=<override>` and the user-picked names only —
    # which is what makes the ADR-0010 manual-flag matrix structural:
    # named modules get manual=true via the CLI's requested-modules path,
    # engine-pulled deps stay manual=false (they never appear on this argv).
    if [[ -n "${_override}" ]]; then
        if ! "${TUI_CLI}" config set platform.override "${_override}"; then
            tui_render_msgbox "Quick Setup" \
                "ERROR: failed to persist the platform override — nothing was installed."
            return 0
        fi
        TUI_PLATFORM_OVERRIDE="${_override}"
    fi
    _tui_exec_install "${_sel[@]}"  # never returns
}

# ── Manage Installed (#72, §8.3 / §8.4) ──────────────────────────────────────

# §8.4 destructive confirm: enumerate the concrete actions (exact forked
# command, dry-run-derived module plan, state.json change), then
# Proceed / Cancel. Cancel forks nothing and returns to the module list.
_tui_screen_confirm_destructive() {
    local _action="$1" _module="$2"
    local _plan
    if ! _plan="$(tui_cli_manage_plan "${_action}" "${_module}")"; then
        tui_render_msgbox "Confirm ${_action^}" \
            "ERROR: 'setup_ubuntu ${_action} --dry-run' failed — cannot enumerate the plan."
        return 0
    fi
    local _text
    _text="$(tui_manage_confirm_text "${_action}" "${_module}" "${_plan}")"
    if ! TUI_YES_LABEL="Proceed" TUI_NO_LABEL="Cancel" tui_render_yesno \
        "Confirm ${_action^}" "${_text}"; then
        return 0  # Cancel / ESC: nothing was forked
    fi
    local -a _argv=()
    mapfile -t _argv < <(tui_manage_args "${_action}" "${_module}")
    _tui_exec_cli "${_argv[@]}"  # never returns
}

# Per-module action menu: Update forks straight away (non-destructive —
# §8.4 only gates Remove / Purge); Remove / Purge route through the
# confirm dialog. < Back > returns to the module list.
_tui_screen_manage_action() {
    local _module="$1" _action
    _action="$(TUI_CANCEL_LABEL="Back" tui_render_menu \
        "Manage '${_module}'" \
        "Pick an action (forks the setup_ubuntu CLI — G4):" \
        "update" "Upgrade to the latest version" \
        "remove" "Remove (config retained)" \
        "purge"  "Remove + delete config (destructive)")" || return 0
    case "${_action}" in
        update)
            local -a _argv=()
            mapfile -t _argv < <(tui_manage_args update "${_module}")
            _tui_exec_cli "${_argv[@]}"  # never returns
            ;;
        remove | purge)
            _tui_screen_confirm_destructive "${_action}" "${_module}"
            ;;
    esac
}

# §8.3 Manage Installed: list installed modules (version + installed_at,
# data source: forked `setup_ubuntu list --installed --json`), with a
# flat ↔ group-by-TAGS[0] view toggle. State is re-forked on every loop
# pass so the list never goes stale behind an action.
_tui_screen_manage() {
    local _list_json="$1"
    while :; do
        local _state_json
        if ! _state_json="$(tui_cli_installed_json)"; then
            tui_render_msgbox "Manage Installed" \
                "ERROR: 'setup_ubuntu list --installed --json' failed."
            return 0
        fi

        local _mode="flat"
        [[ "${TUI_MANAGE_GROUPED}" == "true" ]] && _mode="grouped"
        local -a _rows=()
        local _name _disp
        while IFS=$'\t' read -r _name _disp; do
            _rows+=("${_name}" "${_disp}")
        done < <(tui_installed_entries "${_state_json}" "${_list_json}" "${_mode}")

        if [[ "${#_rows[@]}" -eq 0 ]]; then
            tui_render_msgbox "Manage Installed" \
                "(no modules recorded as installed)"
            return 0
        fi

        local _toggle="Switch view: group by tag"
        [[ "${_mode}" == "grouped" ]] && _toggle="Switch view: flat list"
        _rows+=("view" "<< ${_toggle} >>")

        local _choice
        if ! _choice="$(TUI_CANCEL_LABEL="Back" tui_render_menu \
            "Manage Installed" \
            "Module / Version / Installed at — pick one to manage:" \
            "${_rows[@]}")"; then
            return 0  # Back / ESC → main menu
        fi
        if [[ "${_choice}" == "view" ]]; then
            if [[ "${TUI_MANAGE_GROUPED}" == "true" ]]; then
                TUI_MANAGE_GROUPED="false"
            else
                TUI_MANAGE_GROUPED="true"
            fi
            continue
        fi
        _tui_screen_manage_action "${_choice}"
    done
}

# ── Manage Secrets (#72, §8.1 item 6) ────────────────────────────────────────

# Fork setup_secrets (a standalone interactive sub-tool — it owns the
# terminal and all sensitive prompts, AC-20) and come back to the main
# menu afterwards. Unlike install/manage actions the TUI does NOT exit:
# secrets management is a side trip, not a pipeline handoff.
_tui_screen_secrets() {
    clear 2>/dev/null || printf '\033c'
    "${TUI_SECRETS}"
    local _rc=$?
    printf '\n[setup_secrets exited %d] Press Enter to return to the menu...' "${_rc}"
    read -r REPLY || true
    return 0
}

# ── Menu action dispatch ─────────────────────────────────────────────────────

_tui_dispatch() {
    case "$1" in
        quick-setup)
            _tui_screen_quick_setup "$2" "$3"
            ;;
        base | recommended | optional | experimental)
            _tui_screen_category "$1" "$2"
            ;;
        run)
            _tui_screen_run
            ;;
        manage)
            _tui_screen_manage "$2"
            ;;
        secrets)
            _tui_screen_secrets
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
        # #169: landing on a non-selectable section separator is a no-op —
        # re-loop without dispatching any action.
        [[ "${_choice}" == "${TUI_MENU_SEPARATOR:--}" ]] && continue
        _tui_dispatch "${_choice}" "${_list_json}" "${_detect_json}"
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
