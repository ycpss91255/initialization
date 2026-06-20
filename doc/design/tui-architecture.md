# TUI Architecture (current state) — init_ubuntu

Complete inventory of the TUI as built today. Companion to
`tui-uiux.md` (the 0.1.0 design/decisions). The TUI is a CLI frontend
(G4 / ADR-0019): `setup_ubuntu_tui.sh` forks `setup_ubuntu` / `setup_secrets`
subcommands and sources no engine lib. Backend adapters + i18n live in
`lib/tui_backend.sh`.

Totals: ~1,819 lines (814 `setup_ubuntu_tui.sh` + 1,005 `lib/tui_backend.sh`),
10 flow nodes, 4 widgets (no input widget), 2 backends (gum > whiptail),
91 i18n keys (en + zh-TW; zh-CN/ja absent).

---

## 1. Layer diagram

```
  setup_ubuntu_tui.sh  (entrypoint)
   startup: i18n_resolve_init_ubuntu_lang · --lang/--backend parse · jq/sudo preflight
        │
   SCREEN LAYER
     _tui_main_loop
      ├─ _tui_screen_quick_setup (4 steps) ─► _tui_screen_review ─► _tui_exec_install
      ├─ _tui_screen_category ─► (Run) _tui_screen_run ─► _tui_screen_review ─► exec
      ├─ _tui_screen_manage ─► _tui_screen_manage_action ─► _tui_screen_confirm_destructive ─► _tui_exec_cli
      ├─ _tui_screen_secrets        (forks setup_secrets bare → usage+rc2 BUG)
      └─ _tui_screen_system_info    (detect + platform override)
        │
   WIDGET LAYER   tui_render_menu / _checklist / _msgbox / _yesno   → _tui_<widget>_<family>
        │
   BACKEND LAYER  gum (choose/style/confirm)        whiptail (--menu/--checklist/--msgbox/--yesno)
        │
   DATA/ACTION (forked)
     setup_ubuntu: list --json · detect --json · install [--dry-run] · <action> [--dry-run --no-deps] · config get/set
     setup_secrets: list · ssh-key generate|load|copy · token set|get · gpg generate|import · remove
```

---

## 2. Screen catalog

| Screen (fn) | Lines | Renders / widgets | Forks | Back vs Exit | Returns |
|---|---|---|---|---|---|
| `_tui_main_loop` | 689–715 | menu; title `main_title`, subtitle `main_system`; rows from `tui_main_menu_entries` | list/detect --json (data) | **Exit** = drop in-memory selections (Q43) | 0 on Exit, else dispatch+loop |
| `_tui_screen_system_info` | 236–272 | msgbox + yesno + menu | `detect` | Back = no override | 0 always; sets `TUI_PLATFORM_OVERRIDE` |
| `_tui_screen_category` | 280–309 | checklist (+ msgbox if empty) | — | Back = discard page checks | 0; `tui_selection_replace_page` on OK |
| `_tui_screen_review` | 312–361 | menu + msgbox | `install --dry-run` | Back = keep selection | 0 Proceed / 1 Back or plan-fail |
| `_tui_screen_run` | 365–376 | msgbox if empty; else Review | — | — | 0; Proceed → `_tui_exec_install` |
| `_tui_screen_quick_setup` | 481–543 | 4 steps (menu/checklist/yesno) → Review | `config set platform.override` (Proceed) | Cancel any step = abort (Q43) | 0; Proceed → exec |
| `_tui_screen_manage` | 599–645 | menu (+ msgbox error/empty); flat↔grouped toggle | `list --installed --json` | Back = exit manage | 0 (loops on toggle) |
| `_tui_screen_manage_action` | 575–593 | menu | update forks; remove/purge → confirm | Back to list | 0; action → `_tui_exec_cli` |
| `_tui_screen_confirm_destructive` | 550–570 | yesno (+ msgbox error) | `<action> --dry-run --no-deps` | Cancel forks nothing | 0; Proceed → exec |
| `_tui_screen_secrets` | 653–660 | clear + fork; `secrets_return` prompt | `setup_secrets` (bare → usage+rc2) | Enter to return | 0 always |

---

## 3. Widget layer

Dispatch: `tui_render_<w>()` → `_tui_<w>_$(_tui_backend_family)`.

| Widget | gum impl | whiptail impl | cancel signal | width/clip |
|---|---|---|---|---|
| menu | `gum choose --show-help --header "title: text hint"` (echoes LABEL → mapped to tag by index) | `whiptail --menu` H/W/MH, `--cancel-button` (echoes TAG) | gum 130 / whiptail 1 or 255 | none |
| checklist | `gum choose --no-limit --show-help [--selected csv]` (echoes labels → tags) | `whiptail --separate-output --checklist` (echoes checked tags) | same | whiptail: `_tui_clip_checklist_args` (CHAR-count — CJK BUG) |
| msgbox | `gum style` box + `press_enter` footer + `read` | `whiptail --msgbox` | n/a (rc 0) | none |
| yesno | `gum confirm [--affirmative/--negative]` | `whiptail --yesno [--yes/no-button]` | rc 1 / 255 | none |
| **input** | **MISSING** | **MISSING** | — | — |

Geometry: `TUI_HEIGHT=20 TUI_WIDTH=72 TUI_MENU_HEIGHT=10`. Cancel/yes/no
button-label spelling differs per backend (`_tui_cancel_button_args`,
`_tui_yesno_button_args`): gum `--cancel-label`/`--affirmative`, whiptail
`--cancel-button`/`--yes-button`.

Display helpers (`lib/tui_backend.sh`):
- `_tui_disp_width` (219–246), `_tui_pad_label` (251–256) — **display-width aware** (correct for CJK); used by main-menu label alignment (#197).
- `_tui_clip` (199–211), `_tui_clip_budget` (263–272) — **char-count** (CJK BUG); used by whiptail checklist description clip.

---

## 4. Navigation / interaction model

| Action | gum | whiptail |
|---|---|---|
| move | ↑/↓, j/k (vim native) | ↑/↓ |
| jump start/end | ←/→, h/l | — |
| toggle (multi) | space or x | space |
| confirm | enter | enter / Tab→button→enter |
| back | esc | Tab → `< Back >` → enter / esc |
| select-all | ctrl+a | — |

- **Hints**: gum has native footer (`--show-help`) + header hint (esc/back, #198).
  whiptail shows NO key hints (buttons only) — only the multi-select toggle is
  invisible.
- **Back vs Exit** (Q43): main-menu Exit drops in-memory selections, zero
  writes; sub-screen Back preserves the accumulator. Quick Setup Cancel before
  Proceed = pure abort.
- **Return codes**: 0 ok · 1 cancel/back · 255 whiptail esc · 130 gum esc/ctrl-c
  · 2 bad `--backend`/`--lang` · 4 no sudo.

---

## 5. i18n / CJK coverage

- `TUI_I18N` (setup_ubuntu_tui.sh 53–181): 57 keys, en + zh-TW.
- `TUI_BACKEND_I18N` (lib/tui_backend.sh 78–164): 34 keys, en + zh-TW
  (includes `gum_keys_menu`/`gum_keys_checklist` #198, form-factor labels,
  main-menu category/fixed rows, §8.4 confirm body).
- **zh-CN / ja: 0 entries** for all 91 keys → they fall back to en.
- Hardcoded (non-`i18n_t`) by design: usage text (204–230) and pre-launch
  errors (bad `--backend`/`--lang`, jq/sudo/backend-missing) — `i18n_t` not yet
  resolvable there (§8.5). Logs (`log_*`) stay English by policy.
- **CJK bugs**: `_tui_clip`/`_tui_clip_budget` use char count → whiptail
  multi-select descriptions truncate / budget at the wrong visual boundary for
  zh-TW/ja.

---

## 6. Error / failure presentation

| Failure | Source | User sees |
|---|---|---|
| detect fail | system info | msgbox `sysinfo_detect_failed` |
| list fail | main / manage | main: TUI exits rc1; manage: msgbox `manage_list_failed` |
| install plan fail | review / confirm | msgbox `review_plan_failed` / `confirm_plan_failed` |
| config persist fail | quick setup | msgbox `qs_persist_failed`, abort (no install) |
| **secrets (bare fork)** | secrets | **prints setup_secrets usage + rc2** then `secrets_return` — looks broken (FIX: §4 of tui-uiux.md) |
| jq missing | preflight | stderr error, rc1 (suggests run CLI once) |
| sudo missing | preflight | stderr error, rc4 (suggests CLI) |
| no backend | prelaunch | stderr fatal, rc1 (install whiptail / use CLI) |

---

## 7. Input collection gaps

No input/inputbox widget exists (only menu/checklist/msgbox/yesno). Operations
that therefore cannot be driven from the TUI today: token name (`token set`),
remote `user@host` (`ssh-key copy`), file path (`gpg import`), custom platform
override. All currently fall back to CLI. (Addressed by the `tui_render_input`
widget — `tui-uiux.md` §5.)

---

## 8. Tests

- Unit: `tui_backend_spec.bats` (detection, widgets both backends, JSON parse,
  selection accumulator, display helpers incl. CJK, button-label parity),
  `tui_quick_setup_spec.bats` (4-step wizard + filter pipeline + cancel=zero-fork),
  `tui_manage_spec.bats` (flat/grouped, confirm-text, secrets fork rc),
  `tui_ac10_spec.bats` (AC-10 layer 1 scripted-widget parity).
- Integration (expect pty): `tui_smoke_spec.bats` + `smoke_flow.exp` /
  `smoke_flow_gum.exp` / `lang_flow.exp` (zh-TW render);
  `tui_real_install_spec.bats` + `real_install_flow*.exp`.
- **Gaps**: Manage Installed / Manage Secrets have NO live-widget smoke; only
  en + zh-TW exercised (ja/zh-CN untested — and being dropped for 0.1.0).

---

## 9. Line-reference index

`setup_ubuntu_tui.sh`: TUI_I18N 53–181 · usage 204–230 · system_info 236–272 ·
category 280–309 · review 312–361 · run 365–376 · exec 383–393 · qs steps
408–477 · quick_setup 481–543 · confirm 550–570 · manage_action 575–593 ·
manage 599–645 · secrets 653–660 · dispatch 664–685 · main_loop 689–715 ·
main() 719–811.

`lib/tui_backend.sh`: i18n guard 59–70 · TUI_BACKEND_I18N 78–164 · constants
171–192 · clip/width helpers 199–293 · probes 297–314 · detect/init 321–352 ·
prelaunch 372–407 · require_sudo 411–422 · cli json 429–462 · ADR-0019 parse
483–503 · checklist_entries 517–530 · selection 536–563 · install_args 571–583 ·
platform 590–608 · qs entries 622–641 · installed_entries 653–673 · manage_args
687–717 · confirm_text 729–748 · main_menu_entries 751–819 · summary 823–832 ·
family/buttons 844–860 · whiptail widgets 862–914 · gum widgets 925–999 ·
dispatchers 1002–1005.
