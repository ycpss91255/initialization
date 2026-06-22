# TUI UI/UX Design — init_ubuntu 0.1.0

> **Superseded in part by ADR-0024.** Sections that frame gum as a TUI backend
> (the `gum > whiptail` resolution, the gum widget column, gum key footers) are
> historical: gum is dropped as a backend (Rich tier = fzf two-pane navigator,
> Fallback tier = whiptail; gum stays an installable tool). See
> `doc/adr/0024-fzf-two-pane-tui-replaces-gum.md` and `doc/adr/0025`.

Status: design (grilled 2026-06-20). Scope: milestone 0.1.0 (M1).
Source of truth for the TUI overhaul; each section maps to a tracking issue
(see §10). The TUI is a CLI frontend (G4 / ADR-0019): it forks
`setup_ubuntu` / `setup_secrets` subcommands and sources no engine lib.

---

## 1. Architecture (layers)

```
                          setup_ubuntu_tui.sh  (entrypoint / frontend)
  ┌───────────────────────────────────────────────────────────────────────────┐
  │ startup: resolve lang (--lang > env > config ui.lang > $LANG; en+zh-TW only)│
  │          resolve backend (--backend > TUI_BACKEND > detect: gum>whiptail)   │
  │          read ui.tui_hints  (fork: setup_ubuntu config get ui.tui_hints)    │
  │          install SIGINT trap → restore terminal, zero writes, exit 130      │
  └───────────────────────────────────────────────────────────────────────────┘
                                      │
  ── SCREEN LAYER ───────────────────┼───────────────────────────────────────────
        _tui_main_loop  (Q43: Exit drops in-memory selections; guarded if dirty)
         ├─ Quick Setup (4-step wizard) ──────────────► Review ─► exec install
         ├─ Category checklist (base/recommended/optional/experimental) ─► Run ─► Review
         ├─ Manage Installed ─► Manage Action ─► Confirm (destructive) ─► exec
         ├─ Manage Secrets  ───►  SECRETS SUB-MENU  (new; see §4)
         ├─ System Info (detect + platform override)
         └─ Help  (new; backend-aware key reference; see §3)
                                      │
  ── WIDGET LAYER ───────────────────┼───────────────────────────────────────────
        tui_render_menu / _checklist / _msgbox / _yesno / _input(NEW)
                       dispatch → _tui_<widget>_<family>
                                      │
  ── BACKEND LAYER ──────────────────┼───────────────────────────────────────────
              gum  (preferred)                       whiptail (fallback)
              choose / input / style / confirm        --menu/--checklist/--msgbox
              native footer (--show-help)             --inputbox/--yesno; buttons only
                                      │
  ── DATA / ACTION LAYER (forked) ───┼───────────────────────────────────────────
     setup_ubuntu: list --json · detect --json · install [--dry-run] · <action> · config get/set
     setup_secrets: list · ssh-key generate|load|copy · token set · gpg generate|import
                    + NEW: gpg list · ssh-key list · ssh-key remove   (read/destructive)
     (secret VALUES + passphrases are ALWAYS prompted by the tool on its own tty —
      never collected by the TUI input widget, never in argv/history; AC-20)
```

---

## 2. Navigation & interaction model

Model is identical across backends; only the keys differ. Select = activate;
Back = one level up; Exit = leave the TUI (main menu only).

| Action          | gum                               | whiptail                          |
|-----------------|-----------------------------------|-----------------------------------|
| move            | ↑/↓ **and** j/k (vim, native)     | ↑/↓                               |
| jump start/end  | ←/→ (and h/l)                     | —                                 |
| toggle (multi)  | space **or** x                    | space                             |
| confirm/select  | enter                             | enter (or Tab→button→enter)       |
| back            | esc                               | Tab → `< Back >` → enter (or esc) |
| exit (main)     | esc → exit guard (if dirty)       | `< Exit >` / esc → exit guard     |
| select-all      | ctrl+a                            | —                                 |
| quit (anywhere) | **Ctrl+C** → clean full quit      | **Ctrl+C** → clean full quit      |

- Full vim `hjkl` (h=back, l=enter) is **not** implementable: gum does not expose
  key rebinding and whiptail (newt) supports no custom keys. gum's native j/k
  (up/down) is documented in Help; nothing more is promised.
- Esc vs Ctrl+C: Esc returns rc 130 with no signal → treated as Back. Real
  Ctrl+C delivers SIGINT → the trap fires → clean full quit (distinguishable).

---

## 3. Help & hints

Per-backend help is intentionally different because the backends expose keys
differently.

- **gum**: native footer (`--show-help`) already lists toggle/navigate/submit/
  select-all; the header hint we add covers what the footer omits (esc=back, and
  main-menu esc=exit-drops-selections). Help menu entry documents j/k (vim) + esc
  semantics.
- **whiptail**: NO footer — buttons only. Help is most needed here. Help menu
  entry centers on **Tab** (the non-obvious "Tab to reach Back/Exit"), plus
  space/enter/esc. Inline hint (multi-select only): `space 勾選 · tab 到按鈕 · enter 確認`.

`ui.tui_hints` (config, default `on`): toggles the **inline** per-screen hints
(gum header hint + `--show-help`; whiptail multi-select hint). When `off`, screens
are clean and the user relies on the Help menu entry. Read once at startup via
`setup_ubuntu config get ui.tui_hints`.

A contextual `?`-key (per-screen help inside a widget) is **not possible**
(neither backend lets us intercept keys mid-dialog) — excluded.

---

## 4. Secrets sub-menu (replaces the broken usage+rc2 dump)

`Manage Secrets` opens a sub-menu instead of forking bare `setup_secrets`
(which printed usage + rc2). Secret VALUES are never collected by the TUI —
the input widget only collects non-secret args (name / user@host / file path);
the tool prompts for the value on its own no-echo tty (AC-20).

```
Manage Secrets
  列出已存密鑰 (overview)        → fork: setup_secrets list  (token names)
                                  + setup_secrets gpg list   (NEW: key id/uid/fpr)
                                  + setup_secrets ssh-key list (NEW: ~/.ssh/*.pub, agent)
                                  → read-only msgbox; NEVER secret/private content
  產生 SSH 金鑰                  → type menu (ed25519 default / ecdsa / rsa)
                                  → fork: ssh-key generate (ssh-keygen prompts passphrase)
  載入 SSH 金鑰到 agent          → fork: ssh-key load
  複製 SSH 公鑰到遠端            → input(user@host) → fork: ssh-key copy <user@host>
  設定 token                     → input(name) → fork: token set <name> (value via no-echo)
  產生 GPG 金鑰                  → fork: gpg generate
  匯入 GPG                       → input(file path) → fork: gpg import <file>
  刪除…                          → category menu:
                                     [刪除 Token]   → pick from list → single yesno → remove <name>
                                     [刪除 SSH 金鑰] → pick from list → TYPE-TO-CONFIRM → ssh-key remove
```

- `token get` is **excluded** from the TUI (would print the secret value on
  screen — shoulder-surfing). Reading a value stays CLI-only.
- Advanced `ssh-key generate` flags (`--comment` / `--file` / `--no-passphrase`)
  stay CLI-only; the TUI offers only the type choice.
- **Deletion danger tiers**: token = single yesno; SSH key = **type-to-confirm**
  (input widget; user types the key name, irreversible). GPG key deletion is
  **deferred** (setup_secrets has no gpg-delete capability; tracked for later
  evaluation — see §10).
- Every secrets op shows a brief result msgbox (success ✓ / failure ✗ + rc).

---

## 5. Input widget contract (`tui_render_input`, NEW)

`tui_render_input <title> <prompt> [default]` → `_tui_input_gum` (`gum input`) /
`_tui_input_whiptail` (`whiptail --inputbox`).

- **Cancel** (Esc / Back): abort the operation, return to the secrets menu, fork
  nothing (Q43 zero side effects).
- **Empty submit**: treated as cancel (no re-prompt; KISS).
- **Validation**: widget does only a non-empty check; name/path legality is
  enforced by `setup_secrets` (single source of truth; it already rejects path
  traversal etc.) — no duplicated ruleset.
- **No no-echo variant**: secret values never pass through this widget (§4).
- **Return**: success → input string on stdout + rc 0; cancel → nonzero
  (consistent with menu/checklist/yesno).

---

## 5b. Module detail view (#211 part 2 / #215)

A read-only detail msgbox renders a module's full `setup_ubuntu show <module>
--json` data: name, category, description, tags, depends_on, conflicts,
supported_ubuntu, supported_platforms (arrays comma-joined; absent / empty →
`(none)`). The TUI forks the engine and parses with jq — G4, no engine lib
sourced. It changes NO selection state.

**Trigger (decision):** neither gum nor whiptail can attach a per-row "info"
key inside a checklist (gum exposes no key rebinding; whiptail/newt supports no
custom keys — same constraint as the excluded in-widget `?`, §3). So the detail
view uses a **pick-then-show companion menu**, not a per-row key:

- **Category checklists** (base/recommended/optional/experimental): a
  `View details...` sentinel row is appended to the checklist. Toggling it +
  OK commits the real picks (the sentinel is filtered out — it can never be a
  module name), opens a module picker → detail box, then **re-renders the same
  checklist with selections intact**. The page is committed before the detour,
  so opening/closing the detail view never loses a selection (Q43 accumulator
  is the source of truth; the re-render reflects it).
- **Manage Installed**: a `View details` action on the per-module action menu
  (alongside Update / Remove / Purge). For an **unregistered** entry (#215 —
  present in state.json, absent from the catalog, so `show --json` fails) it
  falls back to a state-only detail (installed version + installed_at) plus a
  clear "not in the current catalog" note.

`(unregistered)` rendering: a Manage-list row for a state-only module carries an
explicit `(unregistered)` marker so it is distinguishable from a registered
module without a `TAGS[0]`. The bare `unknown` *version* is left as-is — it is
the legitimate `version_provided` default written by the engine, not a defect.

## 6. i18n policy (0.1.0)

- Officially supported: **en + zh-TW only**.
- `--lang` and `$LANG` detection accept `en` / `zh-TW`; `zh-CN` / `ja` are
  treated as invalid → fall back to `en` with the bilingual warning.
- `zh-CN` / `ja` completion is deferred to 0.2.0 (tracked issue).
- Logs (`log_*`) stay English; only user-facing stdout/TUI strings use `i18n_t`.
- Pre-launch errors (bad `--backend`/`--lang`, jq/sudo/backend missing) stay
  English by design — `i18n_t` is not yet resolvable at that point (§8.5).

---

## 7. CJK display-width rendering

- `_tui_disp_width` / `_tui_pad_label` (already shipped #197) count East-Asian
  Wide / fullwidth codepoints as 2 columns; used for main-menu label alignment.
- `_tui_clip` and `_tui_clip_budget` (whiptail multi-select description clip +
  budget) are converted from **char count** to **display width** (reusing
  `_tui_disp_width`): truncate without splitting a wide glyph, count the `…` as 1
  column. gum is unaffected (it wraps itself).

---

## 8. Exit / interrupt / zero-side-effect contract

- **Exit** (main menu): if there are unsent selections → yesno guard
  ("unsent selections — leave and discard?"); empty → leave immediately. Always
  zero file writes (Q43).
- **Back**: one level up; the Q43 selection accumulator survives across Back.
- **Ctrl+C / SIGINT**: clean full quit from anywhere — restore terminal (cursor,
  raw mode), zero writes, exit 130. No guard prompt. Distinct from Esc=Back.
- During a forked child (install / setup_secrets), Ctrl+C belongs to the child
  (e.g. install partial → CLI rc 6); the TUI shows the result on return.

---

## 9. Decision log (grilling 2026-06-20)

| # | Decision |
|---|----------|
| Q1 | Secret VALUES never enter the TUI input widget; tool owns no-echo prompts (AC-20). |
| Q2 | Input widget: cancel/empty = abort+zero-fork; widget non-empty check only; setup_secrets validates. |
| Q3 | Hints via inline (`ui.tui_hints`, default on) + a Help menu entry; no in-widget `?` key (impossible). |
| Q4 | gum gets a Help entry too (a); content covers footer-omitted keys (j/k, esc semantics). |
| Q5 | whiptail Help centered on Tab; inline hint only on multi-select. |
| vim | gum native j/k documented; full hjkl (h=back/l=enter) not implementable on either backend. |
| Q6 | Secrets sub-menu set; `token get` excluded; ssh-key generate offers a type menu. |
| Q7 | remove = pick-from-list + confirm; SSH key delete = type-to-confirm; GPG delete deferred. |
| Q8 | `_tui_clip`/`_tui_clip_budget` → display-width (CJK). |
| Q9 | 0.1.0 = en + zh-TW only; zh-CN/ja → en+warn (deferred). |
| Q10 | Every secrets op shows a brief success/failure result msgbox. |
| Q11 | Exit guard when unsent selections exist. |
| Q11b | Ctrl+C = clean full quit, terminal restored, zero writes, distinct from Esc. |
| Q12 | All of the above is 0.1.0/M1; one epic issue + per-block sub-issues; cut rc3 only after the batch lands green. |
| Q13 | Module detail view (#211/#215): read-only msgbox of `show --json`; trigger is a pick-then-show companion menu (no per-row info key — impossible on both backends); reachable from checklists (selection-preserving) + Manage; unregistered entries marked `(unregistered)` with a state-only fallback detail (§5b). |

---

## 10. Scope & issue map (milestone 0.1.0)

Epic: **TUI UI/UX overhaul (0.1.0)** — links the sub-issues below; embeds this doc.

| Sub-issue | Block | Depends on |
|-----------|-------|------------|
| A | `tui_render_input` widget (gum + whiptail) + contract (§5) | — |
| B | setup_secrets capabilities: `gpg list`, `ssh-key list`, `ssh-key remove` (§4) | — |
| C | Secrets sub-menu + flows + result msgbox (§4, §10) | A, B |
| D | Help system: Help menu entry (gum + whiptail) + `ui.tui_hints` switch (§3) | — |
| E | CJK clip → display-width (`_tui_clip`/`_tui_clip_budget`) (§7) | — |
| F | i18n restrict to en+zh-TW; zh-CN/ja → en+warn (§6) | — |
| G | Exit guard + Ctrl+C clean quit / terminal restore (§8) | — |
| — | **Deferred (0.2.0+, tracked, not built now):** GPG key deletion in TUI; zh-CN/ja translations; full-vim backend evaluation. | — |

Each sub-issue ships as its own PR with unit + (where live-widget) integration
coverage. Manage Installed / Manage Secrets currently have no live-widget smoke
— add expect-harness coverage for the secrets sub-menu under both backends.
After A–G land and main is green: cut `v0.1.0-rc3`, verify, then `v0.1.0`.
```
