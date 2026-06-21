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
# Absolute path to THIS script — the fzf navigator's --preview / --toggle
# binds re-invoke it (ADR-0024). Env-overridable so the AC-10 fzf smoke
# harness can point fzf at a recording wrapper.
TUI_SELF="${TUI_SELF:-${REPO_ROOT}/setup_ubuntu_tui.sh}"
export TUI_SELF
# Env-overridable so the bats e2e harness can substitute a recording mock
# CLI; real sessions never set it and fork the sibling setup_ubuntu.sh.
TUI_CLI="${TUI_CLI:-${REPO_ROOT}/setup_ubuntu.sh}"
export TUI_CLI
# Same override seam for the Manage Secrets fork target (§8.1 item 6).
TUI_SECRETS="${TUI_SECRETS:-${REPO_ROOT}/setup_secrets.sh}"
export TUI_SECRETS

: "${INIT_UBUNTU_VERSION:=0.1.0-draft}"

# G4: the ONLY libraries the TUI sources are its own presentation helpers.
# tui_backend.sh = the shared data layer + the whiptail fallback tier;
# tui_render_fzf.sh = the fzf Rich tier (two-pane navigator, ADR-0024). Both
# source lib/i18n.sh themselves, so i18n_t is available here too. Neither
# sources an engine lib — the G4 grep gate covers all three files.
# shellcheck source=lib/tui_backend.sh
source "${REPO_ROOT}/lib/tui_backend.sh"
# shellcheck source=lib/tui_render_fzf.sh
source "${REPO_ROOT}/lib/tui_render_fzf.sh"

# Resolve the UI language once (env > config ui.lang > $LANG, sanitized). The
# TUI never sources the engine, so config_get is absent here and resolution
# lands on INIT_UBUNTU_LANG / $LANG — exactly the entrypoint contract (#185).
i18n_resolve_init_ubuntu_lang

# ── i18n table (#185): strings setup_ubuntu_tui.sh ITSELF authors ────────────
# Screen titles, prompts, confirmations, status text the TUI frontend writes.
# Module descriptions / detect output / plan bullets are CLI pass-through and
# are NOT translated. `en.<key>` is byte-identical to the prior literal; zh-TW
# uses full-width punctuation. {0}{1} are i18n_t positional args.
# kcov-exclude-start (i18n data table; excluded from coverage — kcov counts each entry line as uncoverable, issue #185)
declare -gA TUI_I18N=(
    # System Info screen (_tui_screen_system_info).
    [en.title_system_info]="System Info"
    [zh-TW.title_system_info]="系統資訊"
    [en.sysinfo_detect_failed]="ERROR: 'setup_ubuntu detect' failed."
    [zh-TW.sysinfo_detect_failed]="錯誤:'setup_ubuntu detect' 執行失敗。"
    [en.sysinfo_override_line]="platform override:  {0} (this session)"
    [zh-TW.sysinfo_override_line]="平台覆寫:  {0} (本工作階段)"
    [en.title_platform_override]="Platform Override"
    [zh-TW.title_platform_override]="平台覆寫"
    [en.override_question]="Override the detected platform (form factor) for this session?"
    [zh-TW.override_question]="是否在本工作階段覆寫偵測到的平台 (硬體型態)?"
    [en.override_clear]="Clear override (use auto-detection)"
    [zh-TW.override_clear]="清除覆寫 (改用自動偵測)"
    [en.select_form_factor]="Select a form factor (PRD §7.5 --profile):"
    [zh-TW.select_form_factor]="選擇硬體型態 (PRD §7.5 --profile):"

    # Category checklist screen (_tui_screen_category).
    [en.title_modules]="Modules"
    [zh-TW.title_modules]="模組"
    [en.no_modules_in_cat]="No modules in category '{0}'."
    [zh-TW.no_modules_in_cat]="類別 '{0}' 中沒有模組。"
    [en.cat_modules_title]="{0} Modules"
    [zh-TW.cat_modules_title]="{0} 模組"
    [en.check_modules_help]="Check modules to install. < OK > keeps this page, < Back > discards it."
    [zh-TW.check_modules_help]="勾選要安裝的模組。< OK > 保留此頁,< Back > 捨棄此頁。"

    # Review & Install screen (_tui_screen_review).
    [en.title_review]="Review & Install"
    [zh-TW.title_review]="檢閱並安裝"
    [en.review_plan_failed]="ERROR: 'setup_ubuntu install --dry-run' failed — cannot build the plan."
    [zh-TW.review_plan_failed]="錯誤:'setup_ubuntu install --dry-run' 執行失敗 — 無法產生安裝計畫。"
    [en.review_will_install]="Will install {0} module(s):"
    [zh-TW.review_will_install]="將安裝 {0} 個模組:"
    [en.review_proceed]="Install now (forks setup_ubuntu)"
    [zh-TW.review_proceed]="立即安裝 (fork setup_ubuntu)"
    [en.nothing_selected]="nothing selected"
    [zh-TW.nothing_selected]="未選擇任何項目"

    # Quick Setup wizard (_tui_qs_* / _tui_screen_quick_setup).
    [en.title_qs_platform]="Quick Setup — Platform Override"
    [zh-TW.title_qs_platform]="快速安裝 — 平台覆寫"
    [en.title_qs_step2]="Quick Setup — Step 2/4: Recommended modules"
    [zh-TW.title_qs_step2]="快速安裝 — 步驟 2/4:推薦模組"
    [en.qs_step2_help]="{0} / {1} will be installed — adjust and press OK."
    [zh-TW.qs_step2_help]="將安裝 {0} / {1} 個 — 調整後按 OK。"
    [en.title_qs_step3_suite]="Quick Setup — Step 3/4: CLI Essentials suite? ({0} tools)"
    [zh-TW.title_qs_step3_suite]="快速安裝 — 步驟 3/4:CLI 必備套件? ({0} 項工具)"
    [en.qs_step3_all]="Yes, install all"
    [zh-TW.qs_step3_all]="是,全部安裝"
    [en.qs_step3_pick]="Pick individually"
    [zh-TW.qs_step3_pick]="逐項挑選"
    [en.qs_step3_skip]="Skip"
    [zh-TW.qs_step3_skip]="略過"
    [en.title_qs_step3_pick]="Quick Setup — Step 3/4: CLI Essentials"
    [zh-TW.title_qs_step3_pick]="快速安裝 — 步驟 3/4:CLI 必備套件"
    [en.title_qs_step4]="Quick Setup — Step 4/4: AI agent CLI? (multi-select)"
    [zh-TW.title_qs_step4]="快速安裝 — 步驟 4/4:AI agent CLI? (可多選)"
    [en.title_qs_step1]="Quick Setup — Step 1/4: Confirm platform"
    [zh-TW.title_qs_step1]="快速安裝 — 步驟 1/4:確認平台"
    [en.qs_step1_detected]="Detected: {0}"
    [zh-TW.qs_step1_detected]="偵測結果:{0}"
    [en.qs_step1_form_factor]="Form factor: {0}"
    [zh-TW.qs_step1_form_factor]="硬體型態:{0}"
    [en.qs_step1_continue]="Yes, continue"
    [zh-TW.qs_step1_continue]="是,繼續"
    [en.qs_step1_override]="Override platform"
    [zh-TW.qs_step1_override]="覆寫平台"
    [en.title_quick_setup]="Quick Setup"
    [zh-TW.title_quick_setup]="快速安裝"
    [en.qs_persist_failed]="ERROR: failed to persist the platform override — nothing was installed."
    [zh-TW.qs_persist_failed]="錯誤:無法儲存平台覆寫 — 未安裝任何項目。"
    # #213(a): richer per-step context (counts / what each choice includes).
    [en.qs_step3_pick_help_rich]="Check the tools to install ({0} in the suite)."
    [zh-TW.qs_step3_pick_help_rich]="勾選要安裝的工具 (套件共 {0} 項)。"
    [en.qs_step4_help_rich]="Check the agent CLIs to install ({0} available, {1} recommended)."
    [zh-TW.qs_step4_help_rich]="勾選要安裝的 agent CLI (共 {0} 項,推薦 {1} 項)。"
    [en.qs_step3_suite_choice]="{0}: install the whole suite ({1} tools), pick individually, or skip."
    [zh-TW.qs_step3_suite_choice]="{0}:安裝整組套件 ({1} 項工具)、逐項挑選,或略過。"
    # #213(b): final pre-install summary (reuses the Review provenance lines).
    [en.title_qs_summary]="Quick Setup — Pre-install Summary"
    [zh-TW.title_qs_summary]="快速安裝 — 安裝前摘要"
    [en.qs_summary_intro]="The following {0} module(s) will be installed:"
    [zh-TW.qs_summary_intro]="將安裝以下 {0} 個模組:"

    # Manage Installed (#72, §8.3 / §8.4).
    [en.confirm_action_title]="Confirm {0}"
    [zh-TW.confirm_action_title]="確認{0}"
    [en.confirm_plan_failed]="ERROR: 'setup_ubuntu {0} --dry-run' failed — cannot enumerate the plan."
    [zh-TW.confirm_plan_failed]="錯誤:'setup_ubuntu {0} --dry-run' 執行失敗 — 無法列出計畫。"
    [en.btn_proceed]="Proceed"
    [zh-TW.btn_proceed]="繼續"
    [en.btn_cancel]="Cancel"
    [zh-TW.btn_cancel]="取消"
    [en.btn_back]="Back"
    [zh-TW.btn_back]="返回"
    [en.btn_exit]="Exit"
    [zh-TW.btn_exit]="離開"
    # Exit guard (#206): shown only when the in-memory selection is non-empty.
    [en.exit_guard_title]="Unsent selections"
    [zh-TW.exit_guard_title]="尚未送出的選擇"
    [en.exit_guard_text]="You have {0} unsent selection(s). Leave and discard them?"
    [zh-TW.exit_guard_text]="你有 {0} 個尚未送出的選擇。離開並捨棄?"
    [en.manage_title]="Manage '{0}'"
    [zh-TW.manage_title]="管理 '{0}'"
    [en.manage_action_help]="Pick an action (forks the setup_ubuntu CLI — G4):"
    [zh-TW.manage_action_help]="選擇動作 (fork setup_ubuntu CLI — G4):"
    [en.manage_update]="Upgrade to the latest version"
    [zh-TW.manage_update]="升級到最新版本"
    [en.manage_remove]="Remove (config retained)"
    [zh-TW.manage_remove]="移除 (保留設定)"
    [en.manage_purge]="Remove + delete config (destructive)"
    [zh-TW.manage_purge]="移除 + 刪除設定 (具破壞性)"
    [en.title_manage_installed]="Manage Installed"
    [zh-TW.title_manage_installed]="管理已安裝項目"
    [en.manage_list_failed]="ERROR: 'setup_ubuntu list --installed --json' failed."
    [zh-TW.manage_list_failed]="錯誤:'setup_ubuntu list --installed --json' 執行失敗。"
    [en.manage_none_installed]="(no modules recorded as installed)"
    [zh-TW.manage_none_installed]="(沒有已安裝的模組紀錄)"
    [en.manage_toggle_group]="Switch view: group by tag"
    [zh-TW.manage_toggle_group]="切換檢視:依標籤分組"
    [en.manage_toggle_flat]="Switch view: flat list"
    [zh-TW.manage_toggle_flat]="切換檢視:平面清單"
    [en.manage_list_help]="Module / Version / Installed at — pick one to manage:"
    [zh-TW.manage_list_help]="模組 / 版本 / 安裝時間 — 選一項進行管理:"

    # Module detail view (#211 part 2 / #215). A "View details..." companion
    # entry (checklist + Manage action menu) opens a READ-ONLY detail msgbox —
    # neither backend can add a per-row info key inside a checklist, so a
    # separate pick-then-show menu is the trigger (design §2 / doc note).
    [en.detail_title]="Details: {0}"
    [zh-TW.detail_title]="詳細資訊:{0}"
    [en.detail_view_entry]="View details..."
    [zh-TW.detail_view_entry]="檢視詳細資訊…"
    [en.detail_pick_title]="View module details"
    [zh-TW.detail_pick_title]="檢視模組詳細資訊"
    [en.detail_pick_help]="Pick a module to view (read-only; your selections are kept):"
    [zh-TW.detail_pick_help]="選擇要檢視的模組 (唯讀;不影響你的選擇):"
    [en.detail_failed]="ERROR: 'setup_ubuntu show {0} --json' failed and no state data is available."
    [zh-TW.detail_failed]="錯誤:'setup_ubuntu show {0} --json' 執行失敗,且沒有可用的 state 資料。"
    [en.manage_detail]="View details (read-only)"
    [zh-TW.manage_detail]="檢視詳細資訊 (唯讀)"

    # Manage Secrets sub-menu (_tui_screen_secrets, #202 / design §4).
    [en.secrets_title]="Manage Secrets"
    [zh-TW.secrets_title]="管理密鑰"
    [en.secrets_help]="Pick a secrets action (forks setup_secrets — G4):"
    [zh-TW.secrets_help]="選擇密鑰動作 (fork setup_secrets — G4):"
    [en.secrets_list]="List existing secrets (overview)"
    [zh-TW.secrets_list]="列出已存密鑰 (總覽)"
    [en.secrets_ssh_gen]="Generate SSH key"
    [zh-TW.secrets_ssh_gen]="產生 SSH 金鑰"
    [en.secrets_ssh_load]="Load SSH key to agent"
    [zh-TW.secrets_ssh_load]="載入 SSH 金鑰到 agent"
    [en.secrets_ssh_copy]="Copy SSH public key to remote"
    [zh-TW.secrets_ssh_copy]="複製 SSH 公鑰到遠端"
    [en.secrets_token_set]="Set token"
    [zh-TW.secrets_token_set]="設定 token"
    [en.secrets_gpg_gen]="Generate GPG key"
    [zh-TW.secrets_gpg_gen]="產生 GPG 金鑰"
    [en.secrets_gpg_import]="Import GPG key"
    [zh-TW.secrets_gpg_import]="匯入 GPG 金鑰"
    [en.secrets_delete]="Delete..."
    [zh-TW.secrets_delete]="刪除…"

    # Result feedback (every op; plain text, NO emoji).
    [en.secrets_result_ok]="{0}: OK"
    [zh-TW.secrets_result_ok]="{0}:成功"
    [en.secrets_result_fail]="{0}: FAILED (rc={1})"
    [zh-TW.secrets_result_fail]="{0}:失敗 (rc={1})"
    [en.secrets_overview_title]="Secrets overview"
    [zh-TW.secrets_overview_title]="密鑰總覽"

    # SSH key type menu (Generate SSH key).
    [en.secrets_ssh_type_title]="SSH key type"
    [zh-TW.secrets_ssh_type_title]="SSH 金鑰類型"
    [en.secrets_ssh_type_help]="Pick a key type (advanced flags stay CLI-only):"
    [zh-TW.secrets_ssh_type_help]="選擇金鑰類型 (進階選項僅限 CLI):"
    [en.secrets_ssh_type_ed25519]="ed25519 (recommended)"
    [zh-TW.secrets_ssh_type_ed25519]="ed25519 (建議)"
    [en.secrets_ssh_type_ecdsa]="ecdsa"
    [zh-TW.secrets_ssh_type_ecdsa]="ecdsa"
    [en.secrets_ssh_type_rsa]="rsa"
    [zh-TW.secrets_ssh_type_rsa]="rsa"

    # Input prompts (non-secret args only — never the value, AC-20).
    [en.secrets_copy_prompt]="Remote target (user@host):"
    [zh-TW.secrets_copy_prompt]="遠端目標 (user@host):"
    [en.secrets_token_prompt]="Token name (the value is prompted securely next):"
    [zh-TW.secrets_token_prompt]="Token 名稱 (稍後會安全地提示輸入值):"
    [en.secrets_gpg_import_prompt]="Path to the GPG key file to import:"
    [zh-TW.secrets_gpg_import_prompt]="要匯入的 GPG 金鑰檔路徑:"

    # Delete category menu + danger tiers.
    [en.secrets_delete_title]="Delete a secret"
    [zh-TW.secrets_delete_title]="刪除密鑰"
    [en.secrets_delete_help]="Pick what to delete (GPG key deletion is not yet supported):"
    [zh-TW.secrets_delete_help]="選擇要刪除的項目 (尚未支援刪除 GPG 金鑰):"
    [en.secrets_delete_token]="Delete Token"
    [zh-TW.secrets_delete_token]="刪除 Token"
    [en.secrets_delete_ssh]="Delete SSH key"
    [zh-TW.secrets_delete_ssh]="刪除 SSH 金鑰"
    [en.secrets_pick_token_title]="Delete Token"
    [zh-TW.secrets_pick_token_title]="刪除 Token"
    [en.secrets_pick_ssh_title]="Delete SSH key"
    [zh-TW.secrets_pick_ssh_title]="刪除 SSH 金鑰"
    [en.secrets_pick_help]="Pick the target to delete:"
    [zh-TW.secrets_pick_help]="選擇要刪除的目標:"
    [en.secrets_none_tokens]="No stored tokens to delete."
    [zh-TW.secrets_none_tokens]="沒有可刪除的已存 token。"
    [en.secrets_none_ssh]="No SSH keys found to delete."
    [zh-TW.secrets_none_ssh]="找不到可刪除的 SSH 金鑰。"
    [en.secrets_list_failed]="ERROR: could not list secrets ({0})."
    [zh-TW.secrets_list_failed]="錯誤:無法列出密鑰 ({0})。"
    [en.secrets_confirm_token]="Delete token '{0}'? This cannot be undone."
    [zh-TW.secrets_confirm_token]="刪除 token '{0}'?此操作無法復原。"
    [en.secrets_ssh_confirm_title]="Delete SSH key '{0}'"
    [zh-TW.secrets_ssh_confirm_title]="刪除 SSH 金鑰 '{0}'"
    [en.secrets_ssh_confirm_prompt]="IRREVERSIBLE. Type the key name '{0}' to confirm:"
    [zh-TW.secrets_ssh_confirm_prompt]="此操作無法復原。請輸入金鑰名稱 '{0}' 以確認:"

    # Main menu loop (_tui_main_loop).
    [en.main_title]="init_ubuntu v{0}"
    [zh-TW.main_title]="init_ubuntu v{0}"
    [en.main_system]="System: {0}"
    [zh-TW.main_system]="系統:{0}"

    # Help screen (#203, design §3). The body is backend-aware and authored by
    # the backend lib (tui_help_text); the entrypoint only owns the title.
    [en.title_help]="Help — keyboard reference"
    [zh-TW.title_help]="說明 — 鍵盤操作"
)
# kcov-exclude-end
# TUI_I18N is consumed by i18n_t via a nameref on the table NAME passed as a
# bareword argument — static analysis cannot follow that indirection, so make
# the read explicit here to keep shellcheck honest (no disable directive).
: "${TUI_I18N[@]+x}"

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

Interactive TUI frontend for setup_ubuntu. The rich tier is an fzf two-pane
navigator (ADR-0024); whiptail is the zero-dependency fallback. All data and
actions fork `setup_ubuntu` subprocesses (G4).

Flags:
  -h / --help            Show this help
  --version              Show tool version
  --backend fzf|whiptail Force the rendering tier (skips detection and the
                         install prompt). Invalid value → exit 2.
  --lang <code>          Force the UI language for this session
                         (en|zh-TW); overrides $LANG / config.
                         Invalid value → falls back to en with a warning.

Requirements:
  - `fzf` (rich tier) or `whiptail` (fallback) on PATH. fzf absent +
    interactive → you are offered `setup_ubuntu install fzf`; otherwise
    whiptail (no auto-install — the TUI forks the CLI; see ADR-0024).
  - sudo available (otherwise exit 4 — use the CLI instead:
    `setup_ubuntu install <module>`)

See PRD §8 for the full TUI specification.
EOF
}

# ── Screens ──────────────────────────────────────────────────────────────────

# System Info (§8.1 item 7): show forked `setup_ubuntu detect` output and
# offer a platform override (kept in TUI memory only).
_tui_screen_system_info() {
    local _detect_text _title_si
    _title_si="$(i18n_t TUI_I18N title_system_info)"
    _detect_text="$("${TUI_CLI}" detect 2>/dev/null)" || {
        tui_render_msgbox "${_title_si}" "$(i18n_t TUI_I18N sysinfo_detect_failed)"
        return 0
    }
    if [[ -n "${TUI_PLATFORM_OVERRIDE}" ]]; then
        _detect_text+=$'\n'"$(i18n_t TUI_I18N sysinfo_override_line "${TUI_PLATFORM_OVERRIDE}")"
    fi
    tui_render_msgbox "${_title_si}" "${_detect_text}"

    local _title_po
    _title_po="$(i18n_t TUI_I18N title_platform_override)"
    if ! tui_render_yesno "${_title_po}" \
        "$(i18n_t TUI_I18N override_question)"; then
        return 0
    fi

    local -a _choices=()
    local _tag _desc
    while IFS=$'\t' read -r _tag _desc; do
        _choices+=("${_tag}" "${_desc}")
    done < <(tui_platform_choices)
    _choices+=("detected" "$(i18n_t TUI_I18N override_clear)")

    local _choice
    _choice="$(tui_render_menu "${_title_po}" \
        "$(i18n_t TUI_I18N select_form_factor)" \
        "${_choices[@]}")" || return 0

    if [[ "${_choice}" == "detected" ]]; then
        TUI_PLATFORM_OVERRIDE=""
    else
        TUI_PLATFORM_OVERRIDE="${_choice}"
    fi
}

# ── Module detail view (#211 part 2 / #215) ──────────────────────────────────
# Read-only msgbox showing a module's full `show --json` data. Reachable from
# the category checklists (via a "View details..." companion entry) AND from
# Manage Installed (via a "View details" action). The detail view forks
# `setup_ubuntu show <module> --json` (G4) and renders the parsed fields; it
# changes no selection state, so opening/closing it never disturbs the Q43
# accumulator. For an UNREGISTERED installed module (#215) the show fork fails
# (the name is gone from the registry) — when a state.json payload is supplied
# the view falls back to the state-only detail + a not-in-catalog note.

# Sentinel row name for the checklist "View details..." companion entry. It is
# never a real module name (module names are catalog identifiers), so it can
# never collide with a selection — it is filtered out before the page commits.
TUI_DETAIL_SENTINEL="__details__"

#   _tui_screen_detail <module> [<state_json>]
_tui_screen_detail() {
    local _module="$1" _state="${2:-}"
    local _title; _title="$(i18n_t TUI_I18N detail_title "${_module}")"
    local _show
    if _show="$(tui_cli_show_json "${_module}")"; then
        tui_render_msgbox "${_title}" "$(tui_detail_text "${_show}")"
        return 0
    fi
    # show --json failed → unregistered (or unknown) module.
    if [[ -n "${_state}" ]]; then
        tui_render_msgbox "${_title}" \
            "$(tui_detail_unregistered_text "${_module}" "${_state}")"
        return 0
    fi
    tui_render_msgbox "${_title}" "$(i18n_t TUI_I18N detail_failed "${_module}")"
}

# Pick-a-module-then-show-detail menu used by the checklist companion entry.
# <names> is a newline-separated module-name list (the current category's
# rows). Cancel / empty forks nothing and returns to the checklist with the
# accumulator untouched.
#   _tui_screen_detail_picker <names>
_tui_screen_detail_picker() {
    local _names="$1"
    local -a _rows=()
    local _n
    while IFS= read -r _n; do
        [[ -n "${_n}" ]] && _rows+=("${_n}" "${_n}")
    done <<<"${_names}"
    [[ "${#_rows[@]}" -eq 0 ]] && return 0
    local _choice
    _choice="$(TUI_CANCEL_LABEL="$(i18n_t TUI_I18N btn_back)" tui_render_menu \
        "$(i18n_t TUI_I18N detail_pick_title)" \
        "$(i18n_t TUI_I18N detail_pick_help)" "${_rows[@]}")" || return 0
    _tui_screen_detail "${_choice}"
}

# ── Checkbox accumulator screens (#70, Q43 / §8.2) ───────────────────────────

# One category page as a pure check-list. < OK > stores the page in the
# in-memory accumulator (tui_selection_replace_page), < Back > / ESC
# discards the page. Nothing is executed and nothing touches disk here —
# `< Run >` on the main menu is the only batch execution point.
_tui_screen_category() {
    local _cat="$1" _json="$2"
    # Loop so the "View details..." companion entry (#211) can show a detail
    # msgbox and return to the SAME checklist with selections intact: each pass
    # re-derives the rows from the persistent accumulator (tui_selection_list),
    # so the just-committed page is reflected and nothing is lost.
    while :; do
        local -a _rows=()
        local _name _label _status
        while IFS=$'\t' read -r _name _label _status; do
            _rows+=("${_name}" "${_label}" "${_status}")
        done < <(tui_checklist_entries "${_json}" "${_cat}" \
            "$(tui_selection_list | tr '\n' ' ')")

        if [[ "${#_rows[@]}" -eq 0 ]]; then
            tui_render_msgbox "$(i18n_t TUI_I18N title_modules)" \
                "$(i18n_t TUI_I18N no_modules_in_cat "${_cat}")"
            return 0
        fi

        # Companion "View details..." row: a sentinel checklist entry. Neither
        # backend can attach a per-row info key inside a checklist, so toggling
        # this row + OK opens a module picker → detail msgbox (filtered out of
        # the committed page below). It renders unchecked every pass.
        _rows+=("${TUI_DETAIL_SENTINEL}" "$(i18n_t TUI_I18N detail_view_entry)" "off")

        local _picked
        if ! _picked="$(TUI_CANCEL_LABEL="$(i18n_t TUI_I18N btn_back)" tui_render_checklist \
            "$(i18n_t TUI_I18N cat_modules_title "${_cat^}")" \
            "$(i18n_t TUI_I18N check_modules_help)" \
            "${_rows[@]}")"; then
            return 0  # Back / ESC: discard this page's changes (Q43)
        fi

        local -a _names=()
        local _line _wants_detail="false"
        while IFS= read -r _line; do
            [[ -z "${_line}" ]] && continue
            if [[ "${_line}" == "${TUI_DETAIL_SENTINEL}" ]]; then
                _wants_detail="true"
                continue  # never a real selection — filtered out (#211)
            fi
            _names+=("${_line}")
        done <<<"${_picked}"
        # Commit the real picks regardless: opening details does not discard the
        # page, so the user's checkbox state survives the detail round trip.
        tui_selection_replace_page "${_json}" "${_cat}" "${_names[@]}"

        if [[ "${_wants_detail}" == "true" ]]; then
            _tui_screen_detail_picker \
                "$(tui_modules_in_category "${_json}" "${_cat}")"
            continue  # back to the same checklist, selections preserved
        fi
        return 0
    done
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
    local _list_json="$1"
    shift
    local -a _sel=("$@")

    local _title_rv
    _title_rv="$(i18n_t TUI_I18N title_review)"
    local _plan
    if ! _plan="$(tui_cli_install_plan "${_sel[@]}")"; then
        tui_render_msgbox "${_title_rv}" \
            "$(i18n_t TUI_I18N review_plan_failed)"
        return 1
    fi

    # #214: per-item dependency provenance — "(your selection)" vs "(required
    # by X)" — instead of a flat "+N deps" count. Heading carries the total
    # module count (picks + pulled deps), the body lists every module with its
    # origin (tui_review_text, resolver plan order).
    local _total _text
    _total="$(printf '%s\n' "${_plan}" | grep -c .)"
    _text="$(i18n_t TUI_I18N review_will_install "${_total}")"$'\n'
    _text+="$(tui_review_text "${_list_json}" "${_plan}" "${_sel[@]}")"

    if ! TUI_CANCEL_LABEL="$(i18n_t TUI_I18N btn_back)" tui_render_menu \
        "${_title_rv}" "${_text}" \
        "proceed" "$(i18n_t TUI_I18N review_proceed)" >/dev/null; then
        return 1  # Back / Cancel: the caller owns what survives
    fi
    return 0
}

# < Run > (§8.1): Review & Install over the Q43 accumulator. Back keeps
# the selections and returns to the main menu.
_tui_screen_run() {
    local _list_json="$1"
    if [[ "$(tui_selection_count)" -eq 0 ]]; then
        tui_render_msgbox "$(i18n_t TUI_I18N title_review)" \
            "$(i18n_t TUI_I18N nothing_selected)"
        return 0
    fi

    local -a _sel=()
    mapfile -t _sel < <(tui_selection_list)
    _tui_screen_review "${_list_json}" "${_sel[@]}" || return 0
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
    tui_render_menu "$(i18n_t TUI_I18N title_qs_platform)" \
        "$(i18n_t TUI_I18N select_form_factor)" "${_choices[@]}"
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

    tui_render_checklist "$(i18n_t TUI_I18N title_qs_step2)" \
        "$(i18n_t TUI_I18N qs_step2_help "${_on}" "$(( ${#_rows[@]} / 3 ))")" \
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

    # #213(a): richer step context — the suite-choice line names the tools and
    # spells out what each choice includes (whole suite count / pick / skip).
    local _help
    _help="$(i18n_t TUI_I18N qs_step3_suite_choice "${_joined}" "${#_names[@]}")"

    local _choice
    _choice="$(tui_render_menu \
        "$(i18n_t TUI_I18N title_qs_step3_suite "${#_names[@]}")" \
        "${_help}" \
        "all"  "$(i18n_t TUI_I18N qs_step3_all)" \
        "pick" "$(i18n_t TUI_I18N qs_step3_pick)" \
        "skip" "$(i18n_t TUI_I18N qs_step3_skip)")" || return 1
    case "${_choice}" in
        all)  printf '%s\n' "${_names[@]}" ;;
        pick) tui_render_checklist "$(i18n_t TUI_I18N title_qs_step3_pick)" \
                  "$(i18n_t TUI_I18N qs_step3_pick_help_rich "${#_names[@]}")" \
                  "${_rows[@]}" || return 1 ;;
        skip) : ;;
    esac
}

# Step 4/4: AI agent CLI multi-select (recommended ones preselected).
_tui_qs_step4() {
    local -a _rows=()
    local _name _label _status _on=0
    while IFS=$'\t' read -r _name _label _status; do
        _rows+=("${_name}" "${_label}" "${_status}")
        [[ "${_status}" == "on" ]] && _on=$((_on + 1))
    done < <(tui_qs_tag_entries "$1" agent "$2")
    [[ "${#_rows[@]}" -eq 0 ]] && return 0

    # #213(a): richer context — how many agent CLIs are offered / preselected.
    tui_render_checklist "$(i18n_t TUI_I18N title_qs_step4)" \
        "$(i18n_t TUI_I18N qs_step4_help_rich "$(( ${#_rows[@]} / 3 ))" "${_on}")" \
        "${_rows[@]}"
}

# #213: final PRE-INSTALL SUMMARY before the fork. Re-forks the dry-run plan
# (read-only) and lists EVERY module that will actually be installed — the
# user's picks AND the engine-pulled deps — each with its provenance
# (tui_summary_text). yes = proceed, no / ESC = pure cancel (rc 1).
#   _tui_qs_preinstall_summary <list_json> <module...>
_tui_qs_preinstall_summary() {
    local _list_json="$1"
    shift
    local _plan
    _plan="$(tui_cli_install_plan "$@")" || return 0
    local _total _text
    _total="$(printf '%s\n' "${_plan}" | grep -c .)"
    _text="$(i18n_t TUI_I18N qs_summary_intro "${_total}")"$'\n'
    _text+="$(tui_summary_text "${_list_json}" "${_plan}" "$@")"
    TUI_YES_LABEL="$(i18n_t TUI_I18N review_proceed)" \
    TUI_NO_LABEL="$(i18n_t TUI_I18N btn_back)" tui_render_yesno \
        "$(i18n_t TUI_I18N title_qs_summary)" "${_text}"
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
            "$(i18n_t TUI_I18N title_qs_step1)" \
            "$(i18n_t TUI_I18N qs_step1_detected "${_summary}")"$'\n'"$(i18n_t TUI_I18N qs_step1_form_factor "${_form}")" \
            "continue" "$(i18n_t TUI_I18N qs_step1_continue)" \
            "override" "$(i18n_t TUI_I18N qs_step1_override)")" || return 0
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
        tui_render_msgbox "$(i18n_t TUI_I18N title_quick_setup)" \
            "$(i18n_t TUI_I18N nothing_selected)"
        return 0
    fi

    # Review backing out before Proceed = pure cancel: the override and
    # the picks die with this function's locals (§8.2.1 cancel table).
    _tui_screen_review "${_list_json}" "${_sel[@]}" || return 0

    # #213: a final PRE-INSTALL SUMMARY listing EVERY module that will be
    # installed (picks AND engine-pulled deps, with provenance) before the
    # fork. Decline = pure cancel (no override write, no install fork).
    _tui_qs_preinstall_summary "${_list_json}" "${_sel[@]}" || return 0

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
            tui_render_msgbox "$(i18n_t TUI_I18N title_quick_setup)" \
                "$(i18n_t TUI_I18N qs_persist_failed)"
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
    local _confirm_title
    _confirm_title="$(i18n_t TUI_I18N confirm_action_title "${_action^}")"
    local _plan
    if ! _plan="$(tui_cli_manage_plan "${_action}" "${_module}")"; then
        tui_render_msgbox "${_confirm_title}" \
            "$(i18n_t TUI_I18N confirm_plan_failed "${_action}")"
        return 0
    fi
    local _text
    _text="$(tui_manage_confirm_text "${_action}" "${_module}" "${_plan}")"
    if ! TUI_YES_LABEL="$(i18n_t TUI_I18N btn_proceed)" \
         TUI_NO_LABEL="$(i18n_t TUI_I18N btn_cancel)" tui_render_yesno \
        "${_confirm_title}" "${_text}"; then
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
    local _module="$1" _state="${2:-}" _action
    _action="$(TUI_CANCEL_LABEL="$(i18n_t TUI_I18N btn_back)" tui_render_menu \
        "$(i18n_t TUI_I18N manage_title "${_module}")" \
        "$(i18n_t TUI_I18N manage_action_help)" \
        "detail" "$(i18n_t TUI_I18N manage_detail)" \
        "update" "$(i18n_t TUI_I18N manage_update)" \
        "remove" "$(i18n_t TUI_I18N manage_remove)" \
        "purge"  "$(i18n_t TUI_I18N manage_purge)")" || return 0
    case "${_action}" in
        detail)
            # Read-only (#211 / #215): forks `show --json`; for an unregistered
            # entry the show fails and the state-only fallback kicks in.
            _tui_screen_detail "${_module}" "${_state}"
            ;;
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
            tui_render_msgbox "$(i18n_t TUI_I18N title_manage_installed)" \
                "$(i18n_t TUI_I18N manage_list_failed)"
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
            tui_render_msgbox "$(i18n_t TUI_I18N title_manage_installed)" \
                "$(i18n_t TUI_I18N manage_none_installed)"
            return 0
        fi

        local _toggle
        _toggle="$(i18n_t TUI_I18N manage_toggle_group)"
        [[ "${_mode}" == "grouped" ]] && _toggle="$(i18n_t TUI_I18N manage_toggle_flat)"
        _rows+=("view" "<< ${_toggle} >>")

        local _choice
        if ! _choice="$(TUI_CANCEL_LABEL="$(i18n_t TUI_I18N btn_back)" tui_render_menu \
            "$(i18n_t TUI_I18N title_manage_installed)" \
            "$(i18n_t TUI_I18N manage_list_help)" \
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
        _tui_screen_manage_action "${_choice}" "${_state_json}"
    done
}

# ── Manage Secrets sub-menu (#202, design §4) ────────────────────────────────
# A sub-menu instead of forking bare setup_secrets (which printed usage + rc2).
# Each flow forks `setup_secrets <subcommand>` (G4 — the TUI never sources the
# engine). Secret VALUES + passphrases are ALWAYS prompted by setup_secrets on
# its own no-echo tty (AC-20): the input widget only collects non-secret args
# (name / user@host / file path), never the value itself.

# Fork a setup_secrets subcommand, then show a plain-text OK / FAILED result
# msgbox (design §4 Q10; NO emoji — repo hard rule). The terminal is cleared so
# the forked tool owns it for its own prompts; we return to the sub-menu after.
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

# 1. Read-only overview: combine `list` + `gpg list` + `ssh-key list` into one
# msgbox. NEVER private/secret content (the subcommands only emit names / public
# material by design). Each fork's failure is folded into the text, not fatal.
_tui_secrets_overview() {
    local _text=""
    _text+="# tokens"$'\n'"$("${TUI_SECRETS}" list 2>&1)"$'\n\n'
    _text+="# gpg"$'\n'"$("${TUI_SECRETS}" gpg list 2>&1)"$'\n\n'
    _text+="# ssh-key"$'\n'"$("${TUI_SECRETS}" ssh-key list 2>&1)"
    tui_render_msgbox "$(i18n_t TUI_I18N secrets_overview_title)" "${_text}"
}

# 2. Generate SSH key: type menu (ed25519 default / ecdsa / rsa) → fork
# `ssh-key generate --type <type>` (ssh-keygen prompts the passphrase itself).
# Cancel on the type menu forks nothing.
_tui_secrets_ssh_generate() {
    local _type
    _type="$(TUI_CANCEL_LABEL="$(i18n_t TUI_I18N btn_back)" tui_render_menu \
        "$(i18n_t TUI_I18N secrets_ssh_type_title)" \
        "$(i18n_t TUI_I18N secrets_ssh_type_help)" \
        "ed25519" "$(i18n_t TUI_I18N secrets_ssh_type_ed25519)" \
        "ecdsa"   "$(i18n_t TUI_I18N secrets_ssh_type_ecdsa)" \
        "rsa"     "$(i18n_t TUI_I18N secrets_ssh_type_rsa)")" || return 0
    _tui_secrets_run "$(i18n_t TUI_I18N secrets_ssh_gen)" \
        ssh-key generate --type "${_type}"
}

# 4 / 5 / 7. input(non-secret arg) → fork the subcommand. Cancel / empty submit
# (tui_render_input contract) forks nothing.
#   _tui_secrets_input_then <label> <prompt-key> <setup_secrets args...> <arg-placeholder>
# The collected value is appended as the LAST setup_secrets argument.
_tui_secrets_ssh_copy() {
    local _target
    _target="$(tui_render_input "$(i18n_t TUI_I18N secrets_ssh_copy)" \
        "$(i18n_t TUI_I18N secrets_copy_prompt)")" || return 0
    _tui_secrets_run "$(i18n_t TUI_I18N secrets_ssh_copy)" \
        ssh-key copy "${_target}"
}

_tui_secrets_token_set() {
    local _name
    _name="$(tui_render_input "$(i18n_t TUI_I18N secrets_token_set)" \
        "$(i18n_t TUI_I18N secrets_token_prompt)")" || return 0
    # Only the NAME reaches argv; setup_secrets prompts the value (AC-20).
    _tui_secrets_run "$(i18n_t TUI_I18N secrets_token_set)" \
        token set "${_name}"
}

_tui_secrets_gpg_import() {
    local _path
    _path="$(tui_render_input "$(i18n_t TUI_I18N secrets_gpg_import)" \
        "$(i18n_t TUI_I18N secrets_gpg_import_prompt)")" || return 0
    _tui_secrets_run "$(i18n_t TUI_I18N secrets_gpg_import)" \
        gpg import "${_path}"
}

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
    TUI_CANCEL_LABEL="$(i18n_t TUI_I18N btn_back)" tui_render_menu \
        "${_title}" "$(i18n_t TUI_I18N secrets_pick_help)" "${_rows[@]}"
}

# 8a. Delete Token: pick from `list` → single yesno → fork `remove <name>`
# (setup_secrets has no `token remove`; the canonical token delete is the
# top-level `remove <name>`). Token is the lower danger tier (yesno only).
_tui_secrets_delete_token() {
    local _names _name
    if ! _names="$("${TUI_SECRETS}" list 2>/dev/null)"; then
        tui_render_msgbox "$(i18n_t TUI_I18N secrets_delete_token)" \
            "$(i18n_t TUI_I18N secrets_list_failed list)"
        return 0
    fi
    _name="$(_tui_secrets_pick "$(i18n_t TUI_I18N secrets_pick_token_title)" \
        "${_names}")" || {
        [[ -n "${_names}" ]] || tui_render_msgbox \
            "$(i18n_t TUI_I18N secrets_delete_token)" \
            "$(i18n_t TUI_I18N secrets_none_tokens)"
        return 0
    }
    tui_render_yesno "$(i18n_t TUI_I18N secrets_delete_token)" \
        "$(i18n_t TUI_I18N secrets_confirm_token "${_name}")" || return 0
    _tui_secrets_run "$(i18n_t TUI_I18N secrets_delete_token)" remove "${_name}"
}

# 8b. Delete SSH key: pick from the `ssh-key list` public-key basenames →
# TYPE-TO-CONFIRM (the user must type the exact name; irreversible) → fork
# `ssh-key remove <name> --yes`. SSH key is the higher danger tier.
_tui_secrets_delete_ssh() {
    local _names _name _typed
    _names="$(_tui_secrets_ssh_names)"
    _name="$(_tui_secrets_pick "$(i18n_t TUI_I18N secrets_pick_ssh_title)" \
        "${_names}")" || {
        [[ -n "${_names}" ]] || tui_render_msgbox \
            "$(i18n_t TUI_I18N secrets_delete_ssh)" \
            "$(i18n_t TUI_I18N secrets_none_ssh)"
        return 0
    }
    _typed="$(tui_render_input \
        "$(i18n_t TUI_I18N secrets_ssh_confirm_title "${_name}")" \
        "$(i18n_t TUI_I18N secrets_ssh_confirm_prompt "${_name}")")" || return 0
    [[ "${_typed}" == "${_name}" ]] || return 0
    _tui_secrets_run "$(i18n_t TUI_I18N secrets_delete_ssh)" \
        ssh-key remove "${_name}" --yes
}

# SSH key names = the basenames of ~/.ssh/*.pub as reported by `ssh-key list`
# ("<path>.pub: <key line>"); the agent-identity section is skipped. One per
# line on stdout. The TUI re-parses the read-only list rather than touching ~.
_tui_secrets_ssh_names() {
    "${TUI_SECRETS}" ssh-key list 2>/dev/null | awk '
        /^agent identities:/ { exit }
        /\.pub: / {
            n = $1; sub(/:$/, "", n); sub(/.*\//, "", n); sub(/\.pub$/, "", n)
            print n
        }'
}

# 8. Delete... category menu: only Token + SSH key (GPG deletion is deferred —
# setup_secrets has no gpg-delete; design §4 / §10).
_tui_secrets_delete_menu() {
    local _cat
    _cat="$(TUI_CANCEL_LABEL="$(i18n_t TUI_I18N btn_back)" tui_render_menu \
        "$(i18n_t TUI_I18N secrets_delete_title)" \
        "$(i18n_t TUI_I18N secrets_delete_help)" \
        "del-token" "$(i18n_t TUI_I18N secrets_delete_token)" \
        "del-ssh"   "$(i18n_t TUI_I18N secrets_delete_ssh)")" || return 0
    case "${_cat}" in
        del-token) _tui_secrets_delete_token ;;
        del-ssh)   _tui_secrets_delete_ssh ;;
    esac
}

# Secrets sub-menu loop. Back / ESC on the sub-menu returns to the main menu;
# every leaf flow returns here. Unlike install/manage this never exits the TUI
# (secrets management is a side trip, not a pipeline handoff).
_tui_screen_secrets() {
    while :; do
        local _choice
        _choice="$(TUI_CANCEL_LABEL="$(i18n_t TUI_I18N btn_back)" tui_render_menu \
            "$(i18n_t TUI_I18N secrets_title)" \
            "$(i18n_t TUI_I18N secrets_help)" \
            "list"       "$(i18n_t TUI_I18N secrets_list)" \
            "ssh-gen"    "$(i18n_t TUI_I18N secrets_ssh_gen)" \
            "ssh-load"   "$(i18n_t TUI_I18N secrets_ssh_load)" \
            "ssh-copy"   "$(i18n_t TUI_I18N secrets_ssh_copy)" \
            "token-set"  "$(i18n_t TUI_I18N secrets_token_set)" \
            "gpg-gen"    "$(i18n_t TUI_I18N secrets_gpg_gen)" \
            "gpg-import" "$(i18n_t TUI_I18N secrets_gpg_import)" \
            "delete"     "$(i18n_t TUI_I18N secrets_delete)")" || return 0
        case "${_choice}" in
            list)       _tui_secrets_overview ;;
            ssh-gen)    _tui_secrets_ssh_generate ;;
            ssh-load)   _tui_secrets_run "$(i18n_t TUI_I18N secrets_ssh_load)" ssh-key load ;;
            ssh-copy)   _tui_secrets_ssh_copy ;;
            token-set)  _tui_secrets_token_set ;;
            gpg-gen)    _tui_secrets_run "$(i18n_t TUI_I18N secrets_gpg_gen)" gpg generate ;;
            gpg-import) _tui_secrets_gpg_import ;;
            delete)     _tui_secrets_delete_menu ;;
        esac
    done
}

# ── Help screen (#203, design §3) ────────────────────────────────────────────
# A read-only msgbox of the backend-aware key reference. gum's native footer
# omits j/k + esc semantics; whiptail has no footer at all and Tab (to reach the
# Back/Exit buttons) is the non-obvious key — so each backend gets its own body
# (tui_help_text, authored in the backend lib). This menu entry is the ONLY
# help mechanism: a contextual `?`-key inside a widget is impossible on both
# backends (neither lets us intercept keys mid-dialog).
_tui_screen_help() {
    tui_render_msgbox "$(i18n_t TUI_I18N title_help)" \
        "$(tui_help_text "$(_tui_backend_family)")"
}

# ── fzf two-pane navigator (Rich tier, ADR-0024) ─────────────────────────────
# Every navigable level is one fzf screen: the left pane is the level's rows
# (token<TAB>label), the right Preview pane re-invokes THIS script as
# `--preview <token>` (a pure function of token + the forked list JSON + the
# selection-state file). Selection is mutated LIVE — space toggles the cursor
# row's module in the selstate file and refreshes the preview in place (fzf has
# no native multi pre-selection, ADR-0024 #4). Enter descends / activates; ESC
# (exit 130) goes up one level.
#
# The selection-state file is TUI session memory (NOT State, Q43): it is a
# mktemp wiped on exit, the fzf-tier analogue of TUI_SELECTION.

# Run one fzf level. <rows-tsv> is "token<TAB>label" lines; <header> is the
# top caption; <selstate> the selection file; <multi> "1" enables the live
# space-toggle bind (module leaves only). Prints the chosen TOKEN on stdout;
# rc 130 = ESC (caller treats as "up one level"), other nonzero = no choice.
#   _tui_fzf_run <rows-tsv> <header> <selstate> <multi>
_tui_fzf_run() {
    local _rows_tsv="$1" _header="$2" _selstate="$3" _multi="$4"
    # The preview command re-invokes this very script in --preview mode. fzf
    # passes the highlighted line's FIRST field ({1}) as the token (rows are
    # tab-delimited, so --with-nth hides the token column from the visible
    # list while --delimiter keeps {1} addressable).
    local -a _bind=()
    if [[ "${_multi}" == "1" ]]; then
        # space: toggle the cursor row's module in the selstate, then refresh
        # the Preview pane so the selection state (● SELECTED / ○ not, the live
        # counts) updates immediately (ADR-0024 #4). NOTE: the LEFT-pane row
        # glyph is re-derived only on the next level redraw (reload would need
        # a stateful --rows re-invocation carrying the level context); the
        # authoritative live signal is the right pane. Re-entering the level
        # repaints the left glyphs. (A later phase can add the reload.)
        _bind=(--bind "space:execute-silent(${TUI_SELF} --toggle {1} ${_selstate})+refresh-preview")
    fi
    "${TUI_BACKEND:-fzf}" \
        --ansi --delimiter $'\t' --with-nth=2.. \
        --header "${_header}" \
        --preview "${TUI_SELF} --preview {1} ${_selstate}" \
        --preview-window 'right,55%,wrap' \
        "${_bind[@]}" \
        <<<"${_rows_tsv}" | cut -f1
    return "${PIPESTATUS[0]}"
}

# The module leaf level: list the (category, subtag) modules + a synthetic
# "Install selected (N)" row, multi-select live. Enter on a module is a no-op
# (space toggles); Enter on the run row → Review → fork install.
#   _tui_nav_leaf <list_json> <category> <subtag> <selstate>
_tui_nav_leaf() {
    local _json="$1" _cat="$2" _subtag="$3" _selstate="$4"
    while :; do
        local _rows _header _token
        _rows="$(tui_fzf_sub_rows "${_json}" "${_cat}" "${_subtag}" "${_selstate}")"
        _rows+=$'\n'"menu:run"$'\t'"$(i18n_t TUI_FZF_I18N row_install_selected "$(tui_fzf_sel_count "${_selstate}")")"
        _header="$(i18n_t TUI_FZF_I18N nav_header_modules "${_subtag}")"$'\n'"$(i18n_t TUI_FZF_I18N legend)"
        _token="$(_tui_fzf_run "${_rows}" "${_header}" "${_selstate}" 1)" || return 0
        case "${_token}" in
            menu:run) _tui_nav_run "${_json}" "${_selstate}"; return 0 ;;
            *)        : ;;  # Enter on a module is a no-op (space toggles)
        esac
    done
}

# A category level: either sub-category branches (>1 TAGS[0] bucket) or — when
# a single bucket — straight to the module leaf. Recommended pre-selection
# (PRD D4) fires on first entry into the recommended category.
#   _tui_nav_category <list_json> <detect_json> <category> <selstate>
_tui_nav_category() {
    local _json="$1" _detect="$2" _cat="$3" _selstate="$4"
    if [[ "${_cat}" == "recommended" && -z "${TUI_RECO_PRESELECTED:-}" ]]; then
        local _form; _form="$(tui_effective_form_factor "${_detect}" "${TUI_PLATFORM_OVERRIDE}")"
        tui_fzf_recommended_preselect "${_json}" "${_selstate}" "${_form}"
        TUI_RECO_PRESELECTED=1
    fi
    local _nsub; _nsub="$(tui_fzf_subtag_count "${_json}" "${_cat}")"
    if (( _nsub <= 1 )); then
        local _only; _only="$(tui_fzf_subtags "${_json}" "${_cat}" | head -n1)"
        [[ -n "${_only}" ]] && _tui_nav_leaf "${_json}" "${_cat}" "${_only}" "${_selstate}"
        return 0
    fi
    while :; do
        local _rows _header _token
        _rows="$(tui_fzf_cat_rows "${_json}" "${_cat}" "${_selstate}")"
        _header="$(i18n_t TUI_FZF_I18N nav_header_branch "${_cat}")"
        _token="$(_tui_fzf_run "${_rows}" "${_header}" "${_selstate}" 0)" || return 0
        case "${_token}" in
            sub:*) local _rest="${_token#sub:}"
                   _tui_nav_leaf "${_json}" "${_rest%%:*}" "${_rest#*:}" "${_selstate}" ;;
        esac
    done
}

# Review the live selection, then fork the install pipeline (reuses the shared
# whiptail Review screen + _tui_exec_install — same single CLI path, G4).
#   _tui_nav_run <list_json> <selstate>
_tui_nav_run() {
    local _json="$1" _selstate="$2"
    local -a _sel=()
    mapfile -t _sel < <(tui_fzf_sel_list "${_selstate}")
    if [[ "${#_sel[@]}" -eq 0 ]]; then
        tui_render_msgbox "$(i18n_t TUI_I18N title_review)" \
            "$(i18n_t TUI_I18N nothing_selected)"
        return 0
    fi
    # ADR-0025: confirmation belongs to the forked CLI; the Review screen here
    # is the navigator's read-only plan view, then _tui_exec_install forks the
    # one CLI pipeline (which owns the go-ahead).
    _tui_screen_review "${_json}" "${_sel[@]}" || return 0
    _tui_exec_install "${_sel[@]}"  # never returns
}

# The main-menu level + the navigator loop. Manage / Secrets / System Info /
# Help still route to the EXISTING whiptail screens for THIS phase (folded into
# the navigator later) — but their main-menu preview shows a sensible summary.
#   _tui_nav_main <list_json> <detect_json> <selstate>
_tui_nav_main() {
    local _json="$1" _detect="$2" _selstate="$3"
    while :; do
        local _rows _header _token
        _rows="$(tui_fzf_menu_rows "${_json}" "${_selstate}")"
        _header="$(i18n_t TUI_I18N main_title "${INIT_UBUNTU_VERSION}")"$'\n'"$(i18n_t TUI_I18N main_system "$(tui_system_summary "${_detect}")")"
        _token="$(_tui_fzf_run "${_rows}" "${_header}" "${_selstate}" 0)" || {
            # ESC on the main menu: exit (selections are dropped — Q43). No
            # disk write either way; the selstate temp dies with the process.
            return 0
        }
        case "${_token}" in
            menu:quick-setup) _tui_screen_quick_setup "${_json}" "${_detect}" ;;
            menu:base | menu:recommended | menu:optional | menu:experimental)
                _tui_nav_category "${_json}" "${_detect}" "${_token#menu:}" "${_selstate}" ;;
            menu:manage)  _tui_screen_manage "${_json}" ;;
            menu:secrets) _tui_screen_secrets ;;
            menu:sysinfo) _tui_screen_system_info ;;
            menu:help)    _tui_screen_help ;;
            menu:run)     _tui_nav_run "${_json}" "${_selstate}" ;;
        esac
    done
}

# Tier resolution (ADR-0024 #6). Prints "fzf" | "whiptail" on stdout; rc 1 +
# the §8.5 fatal guidance only when NO tier is possible (neither fzf nor
# whiptail). Mirrors the old gum prelaunch shape (so the same consent rule
# applies — G4: the TUI forks `setup_ubuntu install fzf`, never installs
# inline). Flow:
#   fzf present                      → fzf (no prompt)
#   fzf absent + interactive (-t 0)  → plain stdin read prompt (default Yes)
#       yes → fork `setup_ubuntu install fzf`, re-check; success → fzf, else
#             warn + whiptail
#       no  → whiptail
#   fzf absent + non-interactive     → whiptail silently
#   fzf absent + no whiptail         → §8.5 fatal (rc 1)
_tui_resolve_tier() {
    if tui_fzf_available; then
        printf 'fzf\n'
        return 0
    fi
    if ! _tui_has_cmd whiptail; then
        tui_backend_init >/dev/null  # reuse the §8.5 fatal guidance + rc 1
        return 1
    fi
    if ! _tui_stdin_is_tty; then
        printf 'whiptail\n'  # non-interactive: no prompt
        return 0
    fi
    i18n_t TUI_FZF_I18N prompt_install_fzf >&2
    local _ans=""
    read -r _ans || _ans=""
    case "${_ans}" in
        [Nn] | [Nn][Oo]) printf 'whiptail\n'; return 0 ;;
    esac
    # Yes (default): fork the CLI to install fzf (G4 — never install here).
    # The fork's stdout is redirected to stderr so command-substitution callers
    # capture ONLY the resolved tier name.
    if "${TUI_CLI:?TUI_CLI not set}" install fzf >&2 && tui_fzf_available; then
        printf 'fzf\n'
        return 0
    fi
    printf 'WARN: fzf install failed — falling back to whiptail.\n' >&2
    printf 'whiptail\n'
}

# fzf-tier entry: fork the two JSON payloads once, allocate the selstate temp,
# run the navigator, then wipe the temp (Q43 — TUI memory only; it never
# becomes State). The only path that does NOT return here is the install
# Proceed leg (_tui_exec_install `exit`s the process); that exit reclaims the
# whole process, so the leftover mktemp is swept by the OS tmp lifecycle —
# acceptable, and it keeps the cleanup statically reachable (no trap).
_tui_fzf_main_loop() {
    local _json _detect _selstate _rc
    _detect="$(tui_cli_detect_json)" || return 1
    _json="$(tui_cli_list_json)" || return 1
    _selstate="$(mktemp)"
    _tui_nav_main "${_json}" "${_detect}" "${_selstate}"
    _rc=$?
    rm -f -- "${_selstate}"
    return "${_rc}"
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
            _tui_screen_run "$2"
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
        help)
            _tui_screen_help
            ;;
    esac
}

# ── Exit / interrupt handling (#206) ─────────────────────────────────────────

# Exit guard: if the in-memory selection accumulator is non-empty, confirm
# before dropping it (Q43 still holds — zero file writes either way). Empty
# selection → exit immediately (no nag). Returns 0 to exit, 1 to stay.
_tui_confirm_exit() {
    local _n; _n="$(tui_selection_count)"
    (( _n > 0 )) || return 0
    TUI_YES_LABEL="$(i18n_t TUI_I18N btn_exit)" \
    TUI_NO_LABEL="$(i18n_t TUI_I18N btn_cancel)" \
        tui_render_yesno "$(i18n_t TUI_I18N exit_guard_title)" \
            "$(i18n_t TUI_I18N exit_guard_text "${_n}")"
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
            # Display-width-aware pad (not printf '%-22s', which counts chars
            # and so leaves zh-TW / ja double-width labels ragged — issue: the
            # main-menu description column did not line up under --lang zh-TW).
            _menu_args+=("${_tag}" "$(_tui_pad_label "${_label}" 22) ${_desc}")
        done < <(tui_main_menu_entries "${_list_json}")

        # < Exit > (relabeled Cancel) / ESC: drop the process and with it every
        # in-memory selection — zero side effects (Q43). Guard the drop when
        # selections are pending (#206): confirm → exit, decline → stay.
        _choice="$(TUI_CANCEL_LABEL="$(i18n_t TUI_I18N btn_exit)" tui_render_menu \
            "$(i18n_t TUI_I18N main_title "${INIT_UBUNTU_VERSION}")" \
            "$(i18n_t TUI_I18N main_system "${_summary}")" "${_menu_args[@]}")" || {
            _tui_confirm_exit && return 0
            continue
        }
        _tui_dispatch "${_choice}" "${_list_json}" "${_detect_json}"
    done
}

# ── ui.tui_hints startup read (#203, design §3) ──────────────────────────────
# Resolve the inline-hint switch ONCE at startup and export TUI_HINTS (1/0) for
# the backend hint code (lib/tui_backend.sh). The TUI is a CLI frontend
# (ADR-0019 / G4): the value is FORKED from `setup_ubuntu config get
# ui.tui_hints`, never sourced. The key may be unset (no config_get capability
# here, an empty value, or a non-zero rc) — all of those degrade to the default
# ON. Only an explicit "off" (case-insensitive, whitespace-trimmed) turns the
# inline hints off; any other value is ON (default/unset/garbage → 1).
_tui_read_hints() {
    local _val
    _val="$("${TUI_CLI}" config get ui.tui_hints 2>/dev/null)" || _val=""
    _val="${_val//[[:space:]]/}"
    if [[ "${_val,,}" == "off" ]]; then
        TUI_HINTS=0
    else
        TUI_HINTS=1
    fi
    export TUI_HINTS
}

# ── Entry ────────────────────────────────────────────────────────────────────

main() {
    # fzf re-invocation modes (ADR-0024). These run BEFORE everything else
    # (no sudo gate, no tier resolution, no screen draw): fzf forks the script
    # purely to render a preview pane or to toggle a selection. They print and
    # exit, so they must short-circuit the normal launch path.
    #   --preview <token> <selstate>  → print the Preview pane text for <token>
    #   --toggle  <name>  <selstate>  → flip <name> in the selstate (live pick)
    #   --rows           <selstate>  → re-emit the current level's rows (reload)
    case "${1:-}" in
        --preview)
            local _pv_json
            _pv_json="$(tui_cli_list_json)" || return 1
            tui_fzf_preview "${2:-}" "${_pv_json}" "${3:-}"
            return 0
            ;;
        --toggle)
            # The bind passes the row TOKEN ({1}); only module-leaf rows
            # (mod:<name>) are togglable — strip the prefix to the bare module
            # name and ignore any non-mod token (defensive: branch rows have no
            # space bind, so this should never fire on them).
            local _tg="${2:-}"
            [[ "${_tg}" == mod:* ]] && tui_fzf_sel_toggle "${3:-}" "${_tg#mod:}"
            return 0
            ;;
    esac

    # (Ctrl+C SIGINT trap deferred: a signal trap inside the TUI subprocess
    # deadlocks kcov ptrace in the coverage unit shard, so it is reimplemented
    # kcov-safe in a #206 follow-up. The exit guard below stays.)
    # --backend is parsed BEFORE detection (#171): a valid value forces
    # TUI_BACKEND and skips BOTH detection and the gum install prompt; an
    # invalid value is a usage error (exit 2).
    local _forced_tier=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                _tui_usage
                return 0
                ;;
            --version)
                printf 'init_ubuntu %s\n' "${INIT_UBUNTU_VERSION}"
                return 0
                ;;
            # --backend forces the TIER (ADR-0024): fzf (Rich) or whiptail
            # (Fallback). It skips detection AND the install prompt; an invalid
            # value is a usage error (exit 2). gum is dropped from the set.
            --backend)
                case "${2:-}" in
                    fzf | whiptail)
                        _forced_tier="$2"
                        shift 2
                        ;;
                    *)
                        printf 'ERROR: --backend requires fzf|whiptail (got %s)\n\n' \
                            "${2:-<missing>}" >&2
                        _tui_usage >&2
                        return 2
                        ;;
                esac
                ;;
            --backend=*)
                case "${1#--backend=}" in
                    fzf | whiptail)
                        _forced_tier="${1#--backend=}"
                        shift
                        ;;
                    *)
                        printf 'ERROR: --backend requires fzf|whiptail (got %s)\n\n' \
                            "${1#--backend=}" >&2
                        _tui_usage >&2
                        return 2
                        ;;
                esac
                ;;
            # --lang forces the UI language for this session, overriding the
            # source-time resolution (env > config > $LANG, line ~45). i18n_t
            # reads INIT_UBUNTU_LANG at render time, so setting it here (before
            # any screen draws) is enough. An invalid value is NOT a usage
            # error: i18n_sanitize_lang downgrades it to "en" with a bilingual
            # warning — same contract as the engine entrypoint (#185).
            --lang)
                shift
                export INIT_UBUNTU_LANG="${1:-en}"
                i18n_sanitize_lang INIT_UBUNTU_LANG setup_ubuntu_tui
                shift || true
                ;;
            --lang=*)
                export INIT_UBUNTU_LANG="${1#--lang=}"
                i18n_sanitize_lang INIT_UBUNTU_LANG setup_ubuntu_tui
                shift
                ;;
            *)
                printf 'ERROR: unknown flag %s\n\n' "$1" >&2
                _tui_usage >&2
                return 2
                ;;
        esac
    done

    tui_require_sudo || return $?

    # Tier resolution (ADR-0024 #6, supersedes the #171 gum>whiptail flow).
    # Precedence:
    #   1. --backend fzf|whiptail  → force the tier, skip detection + prompt
    #   2. pre-set TUI_BACKEND      → env override → whiptail tier (the AC-10
    #                                 harness pins a widget path here; the fzf
    #                                 tier is selected by name/presence, never
    #                                 by a bare TUI_BACKEND value)
    #   3. otherwise                → fzf present → Rich; else offer to install
    #                                 fzf (interactive, G4 fork) → Rich; else
    #                                 whiptail Fallback
    local _tier=""
    if [[ -n "${_forced_tier}" ]]; then
        _tier="${_forced_tier}"
    elif [[ -n "${TUI_BACKEND:-}" ]]; then
        _tier="whiptail"  # env-pinned widget (harness / CI) → fallback render
    else
        _tier="$(_tui_resolve_tier)" || return $?
    fi

    # The whiptail Fallback tier needs a concrete backend binary; the fzf Rich
    # tier needs none here (its navigator invokes fzf directly). When the env
    # already pinned TUI_BACKEND (harness), honor it; otherwise the fallback
    # binary is literally `whiptail`.
    if [[ "${_tier}" == "whiptail" && -z "${TUI_BACKEND:-}" ]]; then
        TUI_BACKEND="whiptail"
    fi
    export TUI_BACKEND

    # The TUI parses ADR-0019 JSON with jq. jq is a CLI self-dep
    # (lib/preflight.sh installs it on the first `setup_ubuntu` run), so
    # only a never-ran-the-CLI box hits this.
    if ! _tui_has_cmd jq; then
        printf 'ERROR: jq not found. Run any setup_ubuntu command once\n' >&2
        printf '       (its preflight offers to install jq), e.g.: setup_ubuntu list\n' >&2
        return 1
    fi

    # #203: resolve ui.tui_hints once (single fork), before any screen draws.
    _tui_read_hints

    if [[ "${_tier}" == "fzf" ]]; then
        _tui_fzf_main_loop
    else
        _tui_main_loop
    fi
}

main "$@"
exit $?
