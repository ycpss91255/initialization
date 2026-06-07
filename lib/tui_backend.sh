#!/usr/bin/env bash
# lib/tui_backend.sh — TUI backend detection + menu data helpers (PRD §8, G4)
#
# The TUI is a *frontend* of the CLI (PRD §8 / G4): it renders screens and
# collects selections only. Everything here either
#   - probes / wraps the dialog backend (`dialog` preferred, `whiptail`
#     fallback — §8.5, no auto-install), or
#   - parses ADR-0019 `list --json` / `detect --json` payloads produced by
#     forked `setup_ubuntu` subprocesses.
# This lib NEVER sources engine libs (registry / resolver / runner / state)
# and NEVER writes state — enforced by the G4 grep gate in
# test/unit/tui_backend_spec.bats.
#
# Public API:
#   tui_backend_detect            Print "dialog"|"whiptail"; rc 1 when both missing
#   tui_backend_init              Export TUI_BACKEND or print §8.5 guidance (rc 1)
#   tui_require_sudo              rc 0 when sudo usable; rc 4 + CLI hint otherwise
#   tui_cli_list_json             Fork `setup_ubuntu list --json` (validated)
#   tui_cli_detect_json           Fork `setup_ubuntu detect --json` (validated)
#   tui_categories <json>         Non-empty categories, canonical order (Q44)
#   tui_category_stats <json> <c> "<installed> <total>" for category <c>
#   tui_modules_in_category <json> <c>   Module names, alphabetical
#   tui_main_menu_entries <json>  §8.1 rows as "tag<TAB>label<TAB>description"
#   tui_system_summary <json>     §8.1 one-line header from detect --json
#   tui_render_menu / tui_render_msgbox / tui_render_yesno
#                                 Thin backend wrappers (smoke-tested by the
#                                 AC-10 harness, not by unit bats)
#
# Internal probes `_tui_has_cmd` / `_tui_has_sudo` are deliberately small
# named functions so bats can override them with mocks (same pattern as
# lib/preflight.sh).

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    printf "Warn: %s is a library, not an executable script.\n" "${BASH_SOURCE[0]##*/}"
    return 0 2>/dev/null
fi

# Canonical CATEGORY order (PRD §6.3 / module contract §9.1).
TUI_CATEGORY_ORDER='["base","recommended","optional","experimental"]'

# Backend dialog geometry. dialog autosizes with 0s but whiptail does not,
# so fixed sizes keep both backends rendering identically (§8.5).
: "${TUI_HEIGHT:=20}"
: "${TUI_WIDTH:=72}"
: "${TUI_MENU_HEIGHT:=10}"

# ── Probes (mockable) ────────────────────────────────────────────────────────

_tui_has_cmd() {
    command -v -- "$1" >/dev/null 2>&1
}

# 0 = we can escalate (root, passwordless sudo, or interactive sudo).
# Mirrors lib/preflight.sh `_preflight_has_sudo` — duplicated on purpose:
# sourcing preflight would couple the TUI to engine startup (G4).
_tui_has_sudo() {
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        return 0
    fi
    _tui_has_cmd sudo || return 1
    if sudo -n true 2>/dev/null; then
        return 0
    fi
    # sudo exists but wants a password — only viable when a tty can prompt.
    [[ -t 0 ]]
}

# ── Backend selection (§8.5) ─────────────────────────────────────────────────

# Print the chosen backend on stdout. Preference: dialog > whiptail.
tui_backend_detect() {
    if _tui_has_cmd dialog; then
        printf 'dialog\n'
        return 0
    fi
    if _tui_has_cmd whiptail; then
        printf 'whiptail\n'
        return 0
    fi
    return 1
}

# Export TUI_BACKEND, or print the §8.5 fix guidance and return 1.
# No auto-install — apt is only ever *suggested* to the user.
tui_backend_init() {
    if ! TUI_BACKEND="$(tui_backend_detect)"; then
        cat >&2 <<'EOF'
FATAL: TUI requires 'whiptail' (default Ubuntu) or 'dialog'.
       Both missing — your install is unusually stripped.
       Fix:  sudo apt install whiptail
       Or:   use CLI mode: setup_ubuntu install <module>
EOF
        return 1
    fi
    export TUI_BACKEND
}

# ── Sudo gate (PRD §8.5: no sudo → exit 4, suggest CLI mode) ────────────────

tui_require_sudo() {
    if _tui_has_sudo; then
        return 0
    fi
    cat >&2 <<'EOF'
ERROR: the TUI needs sudo to be available (module installs escalate).
       sudo is not usable here — switch to CLI mode instead:
         setup_ubuntu list
         setup_ubuntu install <module> --install-target=user-home
EOF
    return 4
}

# ── CLI fork helpers (G4 single data path) ───────────────────────────────────
# TUI_CLI is set by setup_ubuntu_tui.sh. Both helpers validate that the
# subprocess actually produced JSON so a stubbed / failing CLI surfaces as
# one clear error instead of downstream jq noise.

_tui_cli_json() {
    local _payload
    if ! _payload="$("${TUI_CLI:?TUI_CLI not set}" "$@" 2>/dev/null)"; then
        printf "ERROR: 'setup_ubuntu %s' failed\n" "$*" >&2
        return 1
    fi
    if ! jq -e . >/dev/null 2>&1 <<<"${_payload}"; then
        printf "ERROR: 'setup_ubuntu %s' did not return JSON (ADR-0019)\n" "$*" >&2
        return 1
    fi
    printf '%s\n' "${_payload}"
}

tui_cli_list_json()   { _tui_cli_json list --json; }
tui_cli_detect_json() { _tui_cli_json detect --json; }

# ── ADR-0019 payload parsing ─────────────────────────────────────────────────

# Non-empty categories present in the payload, canonical order (Q44:
# empty CATEGORYs — experimental today — never reach the main menu).
tui_categories() {
    jq -r --argjson order "${TUI_CATEGORY_ORDER}" '
        ([.items[].category] | unique) as $present
        | $order | map(select(. as $c | $present | index($c))) | .[]
    ' <<<"$1"
}

# "<installed-count> <total>" for one category.
tui_category_stats() {
    jq -r --arg c "$2" '
        [.items[] | select(.category == $c)]
        | "\([.[] | select(.installed == true)] | length) \(length)"
    ' <<<"$1"
}

# Module names in one category, alphabetical (ADR-0019 sort order).
tui_modules_in_category() {
    jq -r --arg c "$2" '
        [.items[] | select(.category == $c) | .name] | sort | .[]
    ' <<<"$1"
}

# One §8.1 category row as "tag<TAB>label<TAB>description".
_tui_category_entry() {
    local _json="$1" _cat="$2"
    local _installed _total
    read -r _installed _total <<<"$(tui_category_stats "${_json}" "${_cat}")"
    case "${_cat}" in
        base)
            printf 'base\tBase Tools\tView / toggle base modules\n' ;;
        recommended)
            printf 'recommended\tRecommended (%s/%s)\tEnvironment-aware suggestions\n' \
                "${_installed}" "${_total}" ;;
        optional)
            printf 'optional\tOptional\tBrowse optional modules\n' ;;
        experimental)
            printf 'experimental\tExperimental\tBrowse experimental modules\n' ;;
    esac
}

# Full §8.1 main-menu rows ("tag<TAB>label<TAB>description" per line).
# Category rows are derived from the live payload, so empty categories
# disappear and future non-empty ones appear without a spec change (Q44).
tui_main_menu_entries() {
    local _json="$1" _cat

    printf 'quick-setup\tQuick Setup\tInstall all recommended\n'
    while IFS= read -r _cat; do
        _tui_category_entry "${_json}" "${_cat}"
    done < <(tui_categories "${_json}")
    printf 'manage\tManage Installed\tUpdate / Remove / Purge\n'
    printf 'secrets\tManage Secrets\tsetup_secrets (SSH/GPG)\n'
    printf 'sysinfo\tSystem Info\tEnvironment detection details\n'
}

# §8.1 header line from a detect --json payload, e.g.
# "Ubuntu 24.04 / NVIDIA RTX 4090 / GNOME / x11". Null fields are skipped.
tui_system_summary() {
    jq -r '
        [ (((.os.id // "unknown") | (.[0:1] | ascii_upcase) + .[1:])
            + " " + (.os.version // "?")),
          (.gpu.model // .gpu.vendor),
          .desktop,
          .session_type ]
        | map(select(. != null and . != "")) | join(" / ")
    ' <<<"$1"
}

# ── Backend rendering wrappers ───────────────────────────────────────────────
# dialog and whiptail share the --menu/--msgbox/--yesno argument shape, so
# one wrapper per widget keeps both backends behaviorally identical (§8.2
# note). Selections come back on stdout via the fd-swap idiom. These are
# exercised by the AC-10 dual-backend smoke harness, not unit bats.

# tui_render_menu <title> <text> <tag1> <item1> [...] → chosen tag on stdout
tui_render_menu() {
    local _title="$1" _text="$2"
    shift 2
    "${TUI_BACKEND:?TUI_BACKEND not set}" --title "${_title}" \
        --menu "${_text}" "${TUI_HEIGHT}" "${TUI_WIDTH}" "${TUI_MENU_HEIGHT}" \
        "$@" 3>&1 1>&2 2>&3
}

# tui_render_msgbox <title> <text>
tui_render_msgbox() {
    "${TUI_BACKEND:?TUI_BACKEND not set}" --title "$1" \
        --msgbox "$2" "${TUI_HEIGHT}" "${TUI_WIDTH}"
}

# tui_render_yesno <title> <text> → rc 0 yes / rc 1 no
tui_render_yesno() {
    "${TUI_BACKEND:?TUI_BACKEND not set}" --title "$1" \
        --yesno "$2" "${TUI_HEIGHT}" "${TUI_WIDTH}"
}
