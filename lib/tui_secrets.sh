#!/usr/bin/env bash
# lib/tui_secrets.sh — Manage Secrets screens (ADR-0025, PRD stories 10-13)
#
# Extracted from setup_ubuntu_tui.sh (it would have pushed the entrypoint well
# past the 800-line soft cap). The TUI is a CLI frontend (G4): every flow forks
# a `setup_secrets <subcommand>` subprocess — this lib NEVER sources an engine
# lib and NEVER writes State.
#
# PRD story 10 (ADR-0025): Manage Secrets is a THREE-WAY picker — Token / GPG /
# SSH — each opening its own sub-screen with that kind's current list (story 11:
# an empty list renders "none") plus the kind's own actions. The three
# sub-screens are registered in TUI_SCREEN_REGISTRY (entrypoint) so BOTH tiers
# dispatch them identically.
#
# AC-20 / story 12: secret VALUES + passphrases are ALWAYS prompted by
# setup_secrets on its own no-echo tty — the input widget only ever collects a
# NON-secret argument (token name / user@host / GPG file path / the
# type-to-confirm name), never the value itself.
#
# The exact `setup_secrets` subcommand names (verified against setup_secrets.sh):
#   token   : `list` (top-level), `token set <name>`, `remove <name>`
#   gpg     : `gpg list`, `gpg generate`, `gpg import [<file>]`
#   ssh-key : `ssh-key list|generate|load|copy <user@host>|remove <name> --yes`
#
# Functions reference TUI_I18N (authored by the entrypoint) at CALL time, so the
# table need not exist when this lib is sourced — only when a screen runs.

# kcov-exclude-start (unreachable defensive guards: this lib is only ever
# sourced — never executed directly — and the entrypoint always sources
# tui_backend.sh first, so the standalone fallback never fires; repo convention)
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    printf "Warn: %s is a library, not an executable script.\n" "${BASH_SOURCE[0]##*/}"
    return 0 2>/dev/null
fi

# i18n + the shared dialog wrappers live in tui_backend.sh (tui_render_menu /
# msgbox / yesno / input). Guard so standalone sourcing pulls them in.
if ! declare -F tui_render_menu >/dev/null 2>&1; then
    # shellcheck source=lib/tui_backend.sh
    source "${BASH_SOURCE[0]%/*}/tui_backend.sh"
fi
# kcov-exclude-end

# ── Shared op + result feedback ──────────────────────────────────────────────

# Fork a setup_secrets subcommand, then show a plain-text OK / FAILED result
# msgbox (design §4 Q10; NO emoji — repo hard rule). The terminal is cleared so
# the forked tool owns it for its own prompts; we return to the sub-screen after.
#   _tui_secrets_run <result-label> <setup_secrets args...>
_tui_secrets_run() {
    local _label="$1"
    shift
    clear 2>/dev/null || printf '\033c'
    "${TUI_SECRETS}" "$@"
    local _rc=$?
    if [[ "${_rc}" -eq 0 ]]; then
        tui_render_msgbox "${_label}" "$(i18n_t TUI_I18N secrets_result_ok "${_label}")"
    else
        tui_render_msgbox "${_label}" \
            "$(i18n_t TUI_I18N secrets_result_fail "${_label}" "${_rc}")"
    fi
}

# Read-only overview: combine `list` + `gpg list` + `ssh-key list` into one
# msgbox. NEVER private/secret content (the subcommands only emit names / public
# material by design). Each fork's failure is folded into the text, not fatal.
_tui_secrets_overview() {
    local _text=""
    _text+="# tokens"$'\n'"$("${TUI_SECRETS}" list 2>&1)"$'\n\n'
    _text+="# gpg"$'\n'"$("${TUI_SECRETS}" gpg list 2>&1)"$'\n\n'
    _text+="# ssh-key"$'\n'"$("${TUI_SECRETS}" ssh-key list 2>&1)"
    tui_render_msgbox "$(i18n_t TUI_I18N secrets_overview_title)" "${_text}"
}

# ── Non-secret input flows (AC-20: only the arg, never the value) ────────────

# Generate SSH key: type menu (ed25519 default / ecdsa / rsa) → fork
# `ssh-key generate --type <type>` (ssh-keygen prompts the passphrase itself).
# Cancel on the type menu forks nothing.
_tui_secrets_ssh_generate() {
    local _type _back _title _help _ed _ec _rsa
    _back="$(i18n_t TUI_I18N btn_back)"
    _title="$(i18n_t TUI_I18N secrets_ssh_type_title)"
    _help="$(i18n_t TUI_I18N secrets_ssh_type_help)"
    _ed="$(i18n_t TUI_I18N secrets_ssh_type_ed25519)"
    _ec="$(i18n_t TUI_I18N secrets_ssh_type_ecdsa)"
    _rsa="$(i18n_t TUI_I18N secrets_ssh_type_rsa)"
    _type="$(TUI_CANCEL_LABEL="${_back}" tui_render_menu \
        "${_title}" "${_help}" \
        "ed25519" "${_ed}" \
        "ecdsa"   "${_ec}" \
        "rsa"     "${_rsa}")" || return 0
    _tui_secrets_run "$(i18n_t TUI_I18N secrets_ssh_gen)" \
        ssh-key generate --type "${_type}"
}

# input(user@host) → fork `ssh-key copy <user@host>`. Cancel / empty forks
# nothing (tui_render_input contract).
_tui_secrets_ssh_copy() {
    local _target _label _prompt
    _label="$(i18n_t TUI_I18N secrets_ssh_copy)"
    _prompt="$(i18n_t TUI_I18N secrets_copy_prompt)"
    _target="$(tui_render_input "${_label}" "${_prompt}")" || return 0
    _tui_secrets_run "${_label}" ssh-key copy "${_target}"
}

# input(name) → fork `token set <name>`. Only the NAME reaches argv; setup_secrets
# prompts the value (AC-20).
_tui_secrets_token_set() {
    local _name _label _prompt
    _label="$(i18n_t TUI_I18N secrets_token_set)"
    _prompt="$(i18n_t TUI_I18N secrets_token_prompt)"
    _name="$(tui_render_input "${_label}" "${_prompt}")" || return 0
    _tui_secrets_run "${_label}" token set "${_name}"
}

# input(path) → fork `gpg import <path>`. Cancel / empty forks nothing.
_tui_secrets_gpg_import() {
    local _path _label _prompt
    _label="$(i18n_t TUI_I18N secrets_gpg_import)"
    _prompt="$(i18n_t TUI_I18N secrets_gpg_import_prompt)"
    _path="$(tui_render_input "${_label}" "${_prompt}")" || return 0
    _tui_secrets_run "${_label}" gpg import "${_path}"
}

# ── Deletion flows (danger-tiered) ───────────────────────────────────────────

# Build a pick-menu from one-name-per-line list output. Prints the chosen name
# on stdout (rc 0); rc 1 when the list is empty (caller shows the empty msgbox)
# or the user cancels. <names> is newline-separated.
_tui_secrets_pick() {
    local _title="$1" _name_lines="$2"
    local -a _rows=()
    local _n
    while IFS= read -r _n; do
        [[ -n "${_n}" ]] && _rows+=("${_n}" "${_n}")
    done <<<"${_name_lines}"
    [[ "${#_rows[@]}" -eq 0 ]] && return 1
    local _back _help
    _back="$(i18n_t TUI_I18N btn_back)"
    _help="$(i18n_t TUI_I18N secrets_pick_help)"
    TUI_CANCEL_LABEL="${_back}" tui_render_menu \
        "${_title}" "${_help}" "${_rows[@]}"
}

# Delete Token: pick from `list` → single yesno → fork `remove <name>`
# (setup_secrets has no `token remove`; the canonical token delete is the
# top-level `remove <name>`). Token is the lower danger tier (yesno only).
_tui_secrets_delete_token() {
    local _names _name _label _pick_title
    _label="$(i18n_t TUI_I18N secrets_delete_token)"
    if ! _names="$("${TUI_SECRETS}" list 2>/dev/null)"; then
        tui_render_msgbox "${_label}" "$(i18n_t TUI_I18N secrets_list_failed list)"
        return 0
    fi
    _pick_title="$(i18n_t TUI_I18N secrets_pick_token_title)"
    _name="$(_tui_secrets_pick "${_pick_title}" "${_names}")" || {
        [[ -n "${_names}" ]] || tui_render_msgbox \
            "${_label}" "$(i18n_t TUI_I18N secrets_none_tokens)"
        return 0
    }
    tui_render_yesno "${_label}" \
        "$(i18n_t TUI_I18N secrets_confirm_token "${_name}")" || return 0
    _tui_secrets_run "${_label}" remove "${_name}"
}

# Delete SSH key: pick from the `ssh-key list` public-key basenames →
# TYPE-TO-CONFIRM (the user must type the exact name; irreversible) → fork
# `ssh-key remove <name> --yes`. SSH key is the higher danger tier.
_tui_secrets_delete_ssh() {
    local _names _name _typed _label _pick_title _ctitle _cprompt
    _label="$(i18n_t TUI_I18N secrets_delete_ssh)"
    _names="$(_tui_secrets_ssh_names)"
    _pick_title="$(i18n_t TUI_I18N secrets_pick_ssh_title)"
    _name="$(_tui_secrets_pick "${_pick_title}" "${_names}")" || {
        [[ -n "${_names}" ]] || tui_render_msgbox \
            "${_label}" "$(i18n_t TUI_I18N secrets_none_ssh)"
        return 0
    }
    _ctitle="$(i18n_t TUI_I18N secrets_ssh_confirm_title "${_name}")"
    _cprompt="$(i18n_t TUI_I18N secrets_ssh_confirm_prompt "${_name}")"
    _typed="$(tui_render_input "${_ctitle}" "${_cprompt}")" || return 0
    [[ "${_typed}" == "${_name}" ]] || return 0
    _tui_secrets_run "${_label}" ssh-key remove "${_name}" --yes
}

# SSH key names = the basenames of ~/.ssh/*.pub as reported by `ssh-key list`
# ("<path>.pub: <key line>"); the agent-identity section is skipped. One per
# line on stdout. The TUI re-parses the read-only list rather than touching ~.
_tui_secrets_ssh_names() {
    # The multi-line awk program's physical lines are counted by kcov as
    # uncoverable bash statements (same class as the i18n data tables), so the
    # pipe is wrapped in a kcov-exclude region; it is exercised by the SSH
    # remove + ssh kind-list specs.
    # kcov-exclude-start (awk program lines; kcov counts each as uncoverable, repo convention)
    "${TUI_SECRETS}" ssh-key list 2>/dev/null | awk '
        /^agent identities:/ { exit }
        /\.pub: / {
            n = $1; sub(/:$/, "", n); sub(/.*\//, "", n); sub(/\.pub$/, "", n)
            print n
        }'
    # kcov-exclude-end
}

# ── Inline current-list helper (PRD story 11: empty → "none") ────────────────
# A short, read-only one-line-per-entry summary of a kind's current secrets,
# folded into the sub-screen action menu's help text so the user sees what
# exists before picking an action. An empty (or failed) list renders the
# localized "none" placeholder, never a blank.
#   _tui_secrets_kind_list <token|gpg|ssh>
_tui_secrets_kind_list() {
    local _out=""
    case "$1" in
        token) _out="$("${TUI_SECRETS}" list 2>/dev/null)" ;;
        gpg)   _out="$("${TUI_SECRETS}" gpg list 2>/dev/null)" ;;
        ssh)   _out="$(_tui_secrets_ssh_names)" ;;
    esac
    if [[ -z "${_out//[[:space:]]/}" ]]; then
        i18n_t TUI_I18N secrets_none
    else
        printf '%s\n' "${_out}"
    fi
}

# ── The THREE sub-screens (registry-dispatched, both tiers) ──────────────────
# Each loops on its own action menu (Back / ESC returns to the picker) and shows
# the kind's current list inline (story 11). Like the install/manage screens
# they accept a leading <list_json> positional (the uniform registry arity) and
# simply ignore it — secrets needs no catalog data.

# Token: list / set / remove.
_tui_screen_secrets_token() {
    local _choice _back _title _help _l_list _l_set _l_remove
    while :; do
        _back="$(i18n_t TUI_I18N btn_back)"
        _title="$(i18n_t TUI_I18N secrets_token_title)"
        _help="$(i18n_t TUI_I18N secrets_pick_action_help "$(_tui_secrets_kind_list token)")"
        _l_list="$(i18n_t TUI_I18N secrets_action_list)"
        _l_set="$(i18n_t TUI_I18N secrets_token_set)"
        _l_remove="$(i18n_t TUI_I18N secrets_action_remove)"
        _choice="$(TUI_CANCEL_LABEL="${_back}" tui_render_menu \
            "${_title}" "${_help}" \
            "list"   "${_l_list}" \
            "set"    "${_l_set}" \
            "remove" "${_l_remove}")" || return 0
        case "${_choice}" in
            list)   _tui_secrets_overview ;;
            set)    _tui_secrets_token_set ;;
            remove) _tui_secrets_delete_token ;;
        esac
    done
}

# GPG: list / generate / import (deletion deferred — setup_secrets has no
# gpg-delete; design §4 / §10).
_tui_screen_secrets_gpg() {
    local _choice _back _title _help _l_list _l_gen _l_import
    while :; do
        _back="$(i18n_t TUI_I18N btn_back)"
        _title="$(i18n_t TUI_I18N secrets_gpg_title)"
        _help="$(i18n_t TUI_I18N secrets_pick_action_help "$(_tui_secrets_kind_list gpg)")"
        _l_list="$(i18n_t TUI_I18N secrets_action_list)"
        _l_gen="$(i18n_t TUI_I18N secrets_gpg_gen)"
        _l_import="$(i18n_t TUI_I18N secrets_gpg_import)"
        _choice="$(TUI_CANCEL_LABEL="${_back}" tui_render_menu \
            "${_title}" "${_help}" \
            "list"     "${_l_list}" \
            "generate" "${_l_gen}" \
            "import"   "${_l_import}")" || return 0
        case "${_choice}" in
            list)     _tui_secrets_overview ;;
            generate) _tui_secrets_run "${_l_gen}" gpg generate ;;
            import)   _tui_secrets_gpg_import ;;
        esac
    done
}

# SSH: list / generate / load / copy / remove.
_tui_screen_secrets_ssh() {
    local _choice _back _title _help _l_list _l_gen _l_load _l_copy _l_remove
    while :; do
        _back="$(i18n_t TUI_I18N btn_back)"
        _title="$(i18n_t TUI_I18N secrets_ssh_title)"
        _help="$(i18n_t TUI_I18N secrets_pick_action_help "$(_tui_secrets_kind_list ssh)")"
        _l_list="$(i18n_t TUI_I18N secrets_action_list)"
        _l_gen="$(i18n_t TUI_I18N secrets_ssh_gen)"
        _l_load="$(i18n_t TUI_I18N secrets_ssh_load)"
        _l_copy="$(i18n_t TUI_I18N secrets_ssh_copy)"
        _l_remove="$(i18n_t TUI_I18N secrets_action_remove)"
        _choice="$(TUI_CANCEL_LABEL="${_back}" tui_render_menu \
            "${_title}" "${_help}" \
            "list"     "${_l_list}" \
            "generate" "${_l_gen}" \
            "load"     "${_l_load}" \
            "copy"     "${_l_copy}" \
            "remove"   "${_l_remove}")" || return 0
        case "${_choice}" in
            list)     _tui_secrets_overview ;;
            generate) _tui_secrets_ssh_generate ;;
            load)     _tui_secrets_run "${_l_load}" ssh-key load ;;
            copy)     _tui_secrets_ssh_copy ;;
            remove)   _tui_secrets_delete_ssh ;;
        esac
    done
}

# ── Manage Secrets THREE-WAY picker (PRD story 10) ───────────────────────────
# Token / GPG / SSH → each opens its own sub-screen via the shared registry
# (so both tiers dispatch identically). Back / ESC returns to the main menu;
# every sub-screen returns here. Unlike install/manage this never exits the TUI
# (secrets management is a side trip, not a pipeline handoff).
_tui_screen_secrets() {
    local _choice _back _title _help _k_token _k_gpg _k_ssh
    while :; do
        _back="$(i18n_t TUI_I18N btn_back)"
        _title="$(i18n_t TUI_I18N secrets_title)"
        _help="$(i18n_t TUI_I18N secrets_pick_kind_help)"
        _k_token="$(i18n_t TUI_I18N secrets_kind_token)"
        _k_gpg="$(i18n_t TUI_I18N secrets_kind_gpg)"
        _k_ssh="$(i18n_t TUI_I18N secrets_kind_ssh)"
        _choice="$(TUI_CANCEL_LABEL="${_back}" tui_render_menu \
            "${_title}" "${_help}" \
            "token" "${_k_token}" \
            "gpg"   "${_k_gpg}" \
            "ssh"   "${_k_ssh}")" || return 0
        # Dispatch through the registry (#6) so the fzf + whiptail tiers route
        # the three sub-screens through ONE token->screen map.
        case "${_choice}" in
            token) _tui_invoke_screen secrets-token ;;
            gpg)   _tui_invoke_screen secrets-gpg ;;
            ssh)   _tui_invoke_screen secrets-ssh ;;
        esac
    done
}
