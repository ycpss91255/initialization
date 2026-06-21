#!/usr/bin/env bash
# lib/tui_render_fzf.sh — fzf two-pane navigator (the Rich tier, ADR-0024)
#
# The Rich tier renders EVERY navigable level as one fzf two-pane screen
# (CONTEXT.md "Two-pane navigator"): the left pane is the current level and
# the right Preview pane is the LIVE detail of the cursor's row — either the
# children one level down (a branch row) or a Module's full detail (a `mod:`
# row). fzf's `--preview` command re-invokes the TUI's own `--preview <token>`
# mode, which is a PURE function of (token + forked `list --json` + the
# selection-state file). That purity is the whole testability story: every
# preview-renderer + data producer here is unit-testable without an
# interactive fzf (the live navigator is covered by the AC-10 smoke harness).
#
# Token scheme (the `--preview` argument fzf re-invokes the TUI with):
#   menu:<id>            a main-menu row (id = category | quick-setup | manage
#                        | secrets | sysinfo | help | run)
#   cat:<category>       a category branch (base | recommended | optional | ...)
#   sub:<category>:<tag> a sub-category branch (modules grouped by TAGS[0])
#   mod:<name>           a module leaf row (full detail)
#
# This lib NEVER sources engine libs and NEVER writes State: it reads the
# forked `list --json` payload and a selection-state file (which is TUI
# session memory, NOT State — Q43 / ADR-0024 #4). The G4 grep gate covers it.
#
# Public API (pure data + render; consumed by the entrypoint navigator):
#   tui_fzf_preview <token> <list_json> <selstate_file>
#       The `--preview` renderer — preview text for one token, on stdout.
#   tui_fzf_subtags <list_json> <category>
#       The TAGS[0] sub-category buckets of a category, canonical order.
#   tui_fzf_menu_rows <list_json> <selstate>
#       Main-menu navigable rows as "token<TAB>label" lines.
#   tui_fzf_cat_rows <list_json> <category> <selstate>
#       One category's child rows ("sub:" branches or "mod:" leaves).
#   tui_fzf_sub_rows <list_json> <category> <subtag> <selstate>
#       One sub-category's module leaf rows.
#   tui_fzf_sel_* (load/save/toggle/has/count/list)
#       The selection-state file accessors (session memory; the fzf --bind
#       toggles mutate the file, the --preview re-read reflects it live).
#   tui_fzf_recommended_preselect <list_json> <selstate> <form_factor>
#       Pre-select is_recommended modules (PRD D4) on first recommended entry.
#   tui_fzf_available  rc 0 when `fzf` is on PATH (tier resolution)

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    printf "Warn: %s is a library, not an executable script.\n" "${BASH_SOURCE[0]##*/}"
    return 0 2>/dev/null
fi

# i18n + the shared data layer. tui_backend.sh owns the CLI-fork helpers
# (tui_cli_list_json etc.), the category order, and TUI_BACKEND_I18N — the
# Rich tier reuses them rather than duplicating a second data path (ADR-0024
# #5 "the two frontends share one data layer"). Guard so standalone sourcing
# by the unit bats still pulls them in.
if ! declare -F i18n_t >/dev/null 2>&1; then
    # shellcheck source=lib/i18n.sh
    source "${BASH_SOURCE[0]%/*}/i18n.sh"
fi
if ! declare -F tui_categories >/dev/null 2>&1; then
    # shellcheck source=lib/tui_backend.sh
    source "${BASH_SOURCE[0]%/*}/tui_backend.sh"
fi

# ── i18n table (#242): strings the fzf tier ITSELF authors ───────────────────
# Preview-pane labels, marker legend, navigator captions. Caller pass-through
# strings (module descriptions, detect output) are NOT translated. `en.<key>`
# is the canonical English; zh-TW uses full-width punctuation. {0}{1} are
# i18n_t positional args.
# kcov-exclude-start (i18n data table; excluded from coverage — kcov counts each entry line as uncoverable, repo convention / issue #185)
declare -gA TUI_FZF_I18N=(
    # Preview-pane branch summary (children + counts).
    [en.preview_children]="Contains {0} item(s), {1} selected:"
    [zh-TW.preview_children]="包含 {0} 個項目,已選 {1} 個:"
    [en.preview_modules]="{0} module(s), {1} selected:"
    [zh-TW.preview_modules]="{0} 個模組,已選 {1} 個:"
    [en.preview_empty]="(no items)"
    [zh-TW.preview_empty]="(無項目)"

    # Module-leaf preview (full detail).
    [en.preview_status_installed]="installed"
    [zh-TW.preview_status_installed]="已安裝"
    [en.preview_status_not_installed]="not installed"
    [zh-TW.preview_status_not_installed]="未安裝"
    [en.preview_recommended_yes]="recommended for this platform"
    [zh-TW.preview_recommended_yes]="推薦用於此平台"
    [en.preview_recommended_no]="not specifically recommended"
    [zh-TW.preview_recommended_no]="非特別推薦"
    [en.preview_selected]="SELECTED"
    [zh-TW.preview_selected]="已選取"
    [en.preview_not_selected]="not selected"
    [zh-TW.preview_not_selected]="未選取"
    [en.preview_status]="Status:"
    [zh-TW.preview_status]="狀態:"
    [en.preview_tags]="Tags:"
    [zh-TW.preview_tags]="標籤:"
    [en.preview_depends_on]="Depends on:"
    [zh-TW.preview_depends_on]="相依於:"
    [en.preview_will_pull]="Will pull {0} dependency module(s)."
    [zh-TW.preview_will_pull]="將連帶安裝 {0} 個相依模組。"
    [en.preview_no_deps]="No additional dependency modules."
    [zh-TW.preview_no_deps]="沒有額外的相依模組。"
    [en.preview_none]="(none)"
    [zh-TW.preview_none]="(無)"
    [en.preview_in_selection]="In selection:"
    [zh-TW.preview_in_selection]="是否已選:"

    # Main-menu non-category preview summaries (sysinfo / secrets / manage).
    [en.preview_sysinfo]="Environment detection (platform / GPU / desktop)."
    [zh-TW.preview_sysinfo]="環境偵測(平台 / GPU / 桌面)。"
    [en.preview_secrets]="Manage Secrets: Token / GPG / SSH (forks setup_secrets)."
    [zh-TW.preview_secrets]="管理密鑰:Token / GPG / SSH(fork setup_secrets)。"
    [en.preview_manage]="Manage installed modules ({0} installed): update / remove / purge."
    [zh-TW.preview_manage]="管理已安裝模組(已安裝 {0} 個):更新 / 移除 / 清除。"
    [en.preview_quick_setup]="Guided multi-step install of the recommended set."
    [zh-TW.preview_quick_setup]="引導式多步驟安裝推薦組合。"
    [en.preview_help]="Keyboard reference for the navigator."
    [zh-TW.preview_help]="導覽器的鍵盤操作說明。"
    [en.preview_run]="Review & install the {0} module(s) you have selected."
    [zh-TW.preview_run]="檢閱並安裝你已選的 {0} 個模組。"

    # Navigator footer / row legend (the marker key shown in the fzf header).
    [en.legend]="● selected · ○ not · ★ recommended · (+N) deps"
    [zh-TW.legend]="● 已選 · ○ 未選 · ★ 推薦 · (+N) 相依"
    [en.nav_header_modules]="{0} — space: toggle · enter: down · esc: back"
    [zh-TW.nav_header_modules]="{0} — space:切換 · enter:進入 · esc:返回"
    [en.nav_header_branch]="{0} — enter: open · esc: back"
    [zh-TW.nav_header_branch]="{0} — enter:開啟 · esc:返回"

    # The synthetic "Install selected (N)" leaf row + main-menu run row.
    [en.row_install_selected]="Install selected ({0})"
    [zh-TW.row_install_selected]="安裝所選 ({0})"

    # Pre-launch fzf install prompt (tier resolution, ADR-0024 #6). Plain
    # stdin/stdout read prompt — no TUI tool is assumed at this point.
    [en.prompt_install_fzf]="Install fzf for the rich two-pane TUI? [Y/n] "
    [zh-TW.prompt_install_fzf]="是否安裝 fzf 以使用雙欄 TUI 體驗? [Y/n] "
)
# kcov-exclude-end
# Consumed by i18n_t via a nameref on the table NAME (bareword) — static
# analysis cannot follow that indirection, so read it explicitly here.
: "${TUI_FZF_I18N[@]+x}"

# ── Tier availability (ADR-0024 #6 tier resolution) ──────────────────────────
# rc 0 when fzf is on PATH. _tui_has_cmd is the mockable probe from
# tui_backend.sh (so the navigator tests can simulate "fzf present/absent").
tui_fzf_available() { _tui_has_cmd fzf; }

# ── Selection-state file (session memory; NOT State — Q43 / ADR-0024 #4) ──────
# fzf has no native multi-select pre-selection, so the page-replace model is
# abandoned: toggling a row mutates this file IMMEDIATELY and the --preview
# re-read reflects it. The file is one module name per line, sorted/unique.
# It lives in the TUI process's scratch (mktemp) and is dropped on exit —
# exactly the Q43 "never touches disk State" guarantee (it is ephemeral UI
# memory, the same role TUI_SELECTION plays for whiptail).

# Load the selection set into stdout (one name per line; empty file → nothing).
tui_fzf_sel_list() {
    local _f="$1"
    [[ -s "${_f}" ]] || return 0
    sort -u "${_f}"
}

tui_fzf_sel_count() {
    local _f="$1"
    [[ -s "${_f}" ]] || { printf '0\n'; return 0; }
    sort -u "${_f}" | grep -c .
}

# rc 0 when <name> is in the selection.
tui_fzf_sel_has() {
    local _f="$1" _name="$2"
    [[ -s "${_f}" ]] || return 1
    grep -qxF -- "${_name}" "${_f}"
}

# Add <name> to the selection (idempotent).
tui_fzf_sel_add() {
    local _f="$1" _name="$2"
    tui_fzf_sel_has "${_f}" "${_name}" && return 0
    printf '%s\n' "${_name}" >>"${_f}"
}

# Remove <name> from the selection (idempotent).
tui_fzf_sel_remove() {
    local _f="$1" _name="$2"
    [[ -s "${_f}" ]] || return 0
    local _tmp; _tmp="$(mktemp)"
    grep -vxF -- "${_name}" "${_f}" >"${_tmp}" || true
    mv -- "${_tmp}" "${_f}"
}

# Toggle <name>: the live multi-select primitive the fzf --bind calls.
tui_fzf_sel_toggle() {
    local _f="$1" _name="$2"
    if tui_fzf_sel_has "${_f}" "${_name}"; then
        tui_fzf_sel_remove "${_f}" "${_name}"
    else
        tui_fzf_sel_add "${_f}" "${_name}"
    fi
}

# Recommended pre-selection (PRD D4): add every is_recommended module that
# survives the platform filter to the selection. Reuses the SAME filter
# pipeline the whiptail Quick Setup uses (tui_qs_recommended_entries: platform
# ∋ form factor → enabled tri-state → recommended). Idempotent, so re-entering
# the recommended category does not re-add already-removed picks beyond the
# first call — the caller guards "first entry" with a marker file.
#   tui_fzf_recommended_preselect <list_json> <selstate> <form_factor>
tui_fzf_recommended_preselect() {
    local _json="$1" _f="$2" _form="$3"
    local _name _label _status
    while IFS=$'\t' read -r _name _label _status; do
        [[ "${_status}" == "on" ]] && tui_fzf_sel_add "${_f}" "${_name}"
    done < <(tui_qs_recommended_entries "${_json}" "${_form}")
    return 0  # the last loop iter may leave rc 1 (a row that was "off")
}

# ── Sub-category structure (TAGS[0] grouping, ADR-0024 #3 levels) ─────────────
# The distinct TAGS[0] buckets of a category, alphabetical — a module with no
# tags falls into the "other" bucket. A category with >1 bucket gets a
# sub-category branch screen; a single bucket goes straight to the module leaf.
tui_fzf_subtags() {
    local _json="$1" _cat="$2"
    jq -r --arg c "$2" '
        [.items[] | select(.category == $c) | (.tags[0] // "other")]
        | unique | sort | .[]
    ' <<<"${_json}"
}

# How many distinct TAGS[0] buckets a category has (drives the "branch vs
# straight-to-leaf" decision: >1 → sub-category screen, else module leaf).
tui_fzf_subtag_count() {
    tui_fzf_subtags "$1" "$2" | grep -c .
}

# ── Per-level row producers (left-pane rows: "token<TAB>label") ──────────────

# A module-leaf row label: "<glyph> <name>  <description>[ ★][ (+N)]".
#   ● selected · ○ not · ★ recommended · (+N) deps
#   _tui_fzf_mod_label <list_json> <name> <selstate>
_tui_fzf_mod_label() {
    local _json="$1" _name="$2" _f="$3"
    local _glyph='○'
    tui_fzf_sel_has "${_f}" "${_name}" && _glyph='●'
    jq -r --arg n "${_name}" --arg g "${_glyph}" '
        (.items[] | select(.name == $n)) as $m
        | ($m.depends_on // []) as $deps
        | "\($g) \($m.name)  \($m.description)"
          + (if $m.recommended == true then " ★" else "" end)
          + (if ($deps | length) > 0 then " (+\($deps | length))" else "" end)
    ' <<<"${_json}"
}

# Module leaf rows for one (category, subtag) — alphabetical by name. The leaf
# is multi-select, so the glyph reflects live selection state.
#   tui_fzf_sub_rows <list_json> <category> <subtag> <selstate>
tui_fzf_sub_rows() {
    local _json="$1" _cat="$2" _subtag="$3" _f="$4"
    local _name
    while IFS= read -r _name; do
        [[ -z "${_name}" ]] && continue
        printf 'mod:%s\t%s\n' "${_name}" "$(_tui_fzf_mod_label "${_json}" "${_name}" "${_f}")"
    done < <(jq -r --arg c "${_cat}" --arg t "${_subtag}" '
        [.items[]
         | select(.category == $c)
         | select((.tags[0] // "other") == $t)
         | .name] | sort | .[]
    ' <<<"${_json}")
}

# Category child rows. >1 sub-category → "sub:" branch rows (one per TAGS[0]
# bucket); a single bucket → "mod:" leaf rows directly (skip the redundant
# sub-category screen, ADR-0024 #3).
#   tui_fzf_cat_rows <list_json> <category> <selstate>
tui_fzf_cat_rows() {
    local _json="$1" _cat="$2" _f="$3"
    local _nsub; _nsub="$(tui_fzf_subtag_count "${_json}" "${_cat}")"
    if (( _nsub > 1 )); then
        local _sub _sel _tot
        while IFS= read -r _sub; do
            [[ -z "${_sub}" ]] && continue
            read -r _sel _tot < <(_tui_fzf_subtag_stats "${_json}" "${_cat}" "${_sub}" "${_f}")
            printf 'sub:%s:%s\t%s  %s  (%s/%s)\n' \
                "${_cat}" "${_sub}" '▸' "${_sub}" "${_sel}" "${_tot}"
        done < <(tui_fzf_subtags "${_json}" "${_cat}")
        return 0
    fi
    # Single bucket (or none): straight to the module leaf.
    local _only; _only="$(tui_fzf_subtags "${_json}" "${_cat}" | head -n1)"
    [[ -n "${_only}" ]] && tui_fzf_sub_rows "${_json}" "${_cat}" "${_only}" "${_f}"
}

# "<selected> <total>" for one sub-category bucket (preview + branch-row count).
_tui_fzf_subtag_stats() {
    local _json="$1" _cat="$2" _subtag="$3" _f="$4"
    local _sel_list; _sel_list="$(tui_fzf_sel_list "${_f}" | tr '\n' ' ')"
    jq -r --arg c "${_cat}" --arg t "${_subtag}" --arg sel " ${_sel_list} " '
        [.items[] | select(.category == $c) | select((.tags[0] // "other") == $t)]
        | "\([.[] | .name as $n | select($sel | contains(" " + $n + " "))] | length) \(length)"
    ' <<<"${_json}"
}

# "<selected> <total>" for a whole category (main-menu category-row count —
# PRD D2: SELECTED / total, NOT installed/total).
tui_fzf_category_sel_stats() {
    local _json="$1" _cat="$2" _f="$3"
    local _sel_list; _sel_list="$(tui_fzf_sel_list "${_f}" | tr '\n' ' ')"
    jq -r --arg c "${_cat}" --arg sel " ${_sel_list} " '
        [.items[] | select(.category == $c)]
        | "\([.[] | .name as $n | select($sel | contains(" " + $n + " "))] | length) \(length)"
    ' <<<"${_json}"
}

# Main-menu rows as "token<TAB>label" (PRD §8.1 order). Category rows carry a
# SELECTED/total count (PRD D2). The synthetic run row carries the live count.
#   tui_fzf_menu_rows <list_json> <selstate>
tui_fzf_menu_rows() {
    local _json="$1" _f="$2"
    printf 'menu:quick-setup\t%s\n' "$(i18n_t TUI_BACKEND_I18N menu_quick_setup_label)"
    local _cat _sel _tot _label
    while IFS= read -r _cat; do
        [[ -z "${_cat}" ]] && continue
        read -r _sel _tot < <(tui_fzf_category_sel_stats "${_json}" "${_cat}" "${_f}")
        case "${_cat}" in
            base)         _label="$(i18n_t TUI_BACKEND_I18N cat_base_label)" ;;
            recommended)  _label="$(i18n_t TUI_BACKEND_I18N cat_recommended_label "${_sel}" "${_tot}")" ;;
            optional)     _label="$(i18n_t TUI_BACKEND_I18N cat_optional_label)" ;;
            experimental) _label="$(i18n_t TUI_BACKEND_I18N cat_experimental_label)" ;;
            *)            _label="${_cat}" ;;
        esac
        # PRD D2: every category row shows SELECTED/total (even base/optional,
        # whose i18n label has no {0}/{1} slot — append the count explicitly).
        case "${_cat}" in
            recommended) : ;;  # already has (sel/tot) in the label
            *)           _label="${_label} (${_sel}/${_tot})" ;;
        esac
        printf 'menu:%s\t%s\n' "${_cat}" "${_label}"
    done < <(tui_categories "${_json}")
    printf 'menu:manage\t%s\n'  "$(i18n_t TUI_BACKEND_I18N menu_manage_label)"
    printf 'menu:secrets\t%s\n' "$(i18n_t TUI_BACKEND_I18N menu_secrets_label)"
    printf 'menu:sysinfo\t%s\n' "$(i18n_t TUI_BACKEND_I18N menu_sysinfo_label)"
    printf 'menu:help\t%s\n'    "$(i18n_t TUI_BACKEND_I18N menu_help_label)"
    printf 'menu:run\t%s\n' \
        "$(i18n_t TUI_FZF_I18N row_install_selected "$(tui_fzf_sel_count "${_f}")")"
}

# ── The --preview renderer (PURE: token + json + selstate → text) ────────────
# fzf re-invokes the TUI as `--preview <token>`; the entrypoint hands the token
# here together with the forked list JSON and the selection-state path. Each
# token kind renders a different pane:
#   menu:<id>             children of that main-menu row (counts) or a summary
#   cat:<category>        the category's children + counts
#   sub:<category>:<tag>  the bucket's modules + counts
#   mod:<name>            the module's FULL detail
# Pure — no globals beyond the i18n tables, no I/O except reading the selstate
# file path it is handed. Directly unit-testable.
tui_fzf_preview() {
    local _token="$1" _json="$2" _f="$3"
    case "${_token}" in
        mod:*)  _tui_fzf_preview_module "${_json}" "${_token#mod:}" "${_f}" ;;
        sub:*)
            local _rest="${_token#sub:}"
            _tui_fzf_preview_subcat "${_json}" "${_rest%%:*}" "${_rest#*:}" "${_f}" ;;
        cat:*)  _tui_fzf_preview_category "${_json}" "${_token#cat:}" "${_f}" ;;
        menu:*) _tui_fzf_preview_menu "${_json}" "${_token#menu:}" "${_f}" ;;
        *)      printf '%s\n' "${_token}" ;;
    esac
}

# A branch preview: header line + each child row's label, so a branch shows
# what is one level down (ADR-0024 #3). The labels already carry the ●/○
# glyph (leaf rows) or the (sel/tot) count (sub-branch rows).
#   _tui_fzf_preview_children <header> <rows-tsv>  (rows = token<TAB>label)
_tui_fzf_preview_children() {
    local _header="$1" _rows_tsv="$2"
    printf '%s\n\n' "${_header}"
    local _tok _label
    while IFS=$'\t' read -r _tok _label; do
        [[ -z "${_tok}" ]] && continue
        printf '  %s\n' "${_label}"
    done <<<"${_rows_tsv}"
}

_tui_fzf_preview_category() {
    local _json="$1" _cat="$2" _f="$3"
    local _rows; _rows="$(tui_fzf_cat_rows "${_json}" "${_cat}" "${_f}")"
    local _sel _tot
    read -r _sel _tot < <(tui_fzf_category_sel_stats "${_json}" "${_cat}" "${_f}")
    if [[ -z "${_rows}" ]]; then
        printf '%s\n' "$(i18n_t TUI_FZF_I18N preview_empty)"
        return 0
    fi
    _tui_fzf_preview_children \
        "$(i18n_t TUI_FZF_I18N preview_children "${_tot}" "${_sel}")" \
        "${_rows}"
}

_tui_fzf_preview_subcat() {
    local _json="$1" _cat="$2" _subtag="$3" _f="$4"
    local _rows; _rows="$(tui_fzf_sub_rows "${_json}" "${_cat}" "${_subtag}" "${_f}")"
    local _sel _tot
    read -r _sel _tot < <(_tui_fzf_subtag_stats "${_json}" "${_cat}" "${_subtag}" "${_f}")
    if [[ -z "${_rows}" ]]; then
        printf '%s\n' "$(i18n_t TUI_FZF_I18N preview_empty)"
        return 0
    fi
    _tui_fzf_preview_children \
        "$(i18n_t TUI_FZF_I18N preview_modules "${_tot}" "${_sel}")" \
        "${_rows}"
}

# Full module detail (ADR-0024 #3: description, tags, install status,
# recommended verdict, depends_on, "will pull N dependency modules", and the
# live in-selection state). Reads only the list JSON (no extra fork) so the
# preview stays fast and pure.
_tui_fzf_preview_module() {
    local _json="$1" _name="$2" _f="$3"
    local _none; _none="$(i18n_t TUI_FZF_I18N preview_none)"
    # One jq pass for the textual fields; selection/recommended verdicts are
    # rendered here so they read in the UI language.
    local _installed _rec _ndeps _desc _tags _deps
    {
        read -r _installed
        read -r _rec
        read -r _ndeps
        IFS= read -r _desc
        IFS= read -r _tags
        IFS= read -r _deps
    } < <(jq -r --arg n "${_name}" --arg none "${_none}" '
        (.items[] | select(.name == $n)) as $m
        | ($m.depends_on // []) as $deps
        | ($m.installed == true),
          ($m.recommended == true),
          ($deps | length),
          ($m.description // $none),
          (if (($m.tags // []) | length) == 0 then $none else ($m.tags | join(", ")) end),
          (if ($deps | length) == 0 then $none else ($deps | join(", ")) end)
    ' <<<"${_json}")

    printf '%s\n\n' "${_name}"
    printf '%s\n\n' "${_desc}"

    local _status_v
    if [[ "${_installed}" == "true" ]]; then
        _status_v="$(i18n_t TUI_FZF_I18N preview_status_installed)"
    else
        _status_v="$(i18n_t TUI_FZF_I18N preview_status_not_installed)"
    fi
    printf '%s %s\n' "$(i18n_t TUI_FZF_I18N preview_status)" "${_status_v}"

    local _rec_v
    if [[ "${_rec}" == "true" ]]; then
        _rec_v="★ $(i18n_t TUI_FZF_I18N preview_recommended_yes)"
    else
        _rec_v="$(i18n_t TUI_FZF_I18N preview_recommended_no)"
    fi
    printf '%s\n' "${_rec_v}"

    local _insel_v
    if tui_fzf_sel_has "${_f}" "${_name}"; then
        _insel_v="● $(i18n_t TUI_FZF_I18N preview_selected)"
    else
        _insel_v="○ $(i18n_t TUI_FZF_I18N preview_not_selected)"
    fi
    printf '%s %s\n\n' "$(i18n_t TUI_FZF_I18N preview_in_selection)" "${_insel_v}"

    printf '%s %s\n' "$(i18n_t TUI_FZF_I18N preview_tags)" "${_tags}"
    printf '%s %s\n' "$(i18n_t TUI_FZF_I18N preview_depends_on)" "${_deps}"
    if (( _ndeps > 0 )); then
        printf '%s\n' "$(i18n_t TUI_FZF_I18N preview_will_pull "${_ndeps}")"
    else
        printf '%s\n' "$(i18n_t TUI_FZF_I18N preview_no_deps)"
    fi
}

# Main-menu row preview: a category row previews its children/counts; the
# non-navigable-here rows (sysinfo / secrets / manage / quick-setup / help /
# run) get a sensible summary (ADR-0024 #scope-this-phase note 3).
_tui_fzf_preview_menu() {
    local _json="$1" _id="$2" _f="$3"
    case "${_id}" in
        base | recommended | optional | experimental)
            _tui_fzf_preview_category "${_json}" "${_id}" "${_f}" ;;
        sysinfo)
            printf '%s\n' "$(i18n_t TUI_FZF_I18N preview_sysinfo)" ;;
        secrets)
            printf '%s\n' "$(i18n_t TUI_FZF_I18N preview_secrets)" ;;
        manage)
            local _ninst
            _ninst="$(jq -r '[.items[] | select(.installed == true)] | length' <<<"${_json}")"
            printf '%s\n' "$(i18n_t TUI_FZF_I18N preview_manage "${_ninst}")" ;;
        quick-setup)
            printf '%s\n' "$(i18n_t TUI_FZF_I18N preview_quick_setup)" ;;
        help)
            printf '%s\n' "$(i18n_t TUI_FZF_I18N preview_help)" ;;
        run)
            printf '%s\n' "$(i18n_t TUI_FZF_I18N preview_run "$(tui_fzf_sel_count "${_f}")")" ;;
        *)
            printf '%s\n' "${_id}" ;;
    esac
}
