# ADR-0024: fzf two-pane navigator is the rich TUI tier; whiptail is the fallback; gum is dropped

- **Status:** Accepted
- **Date:** 2026-06-21
- **Supersedes:** ADR-0023 (gum-preferred backend)
- **Relates to:** PRD G4 (TUI = CLI frontend), ADR-0019 (`list --json`
  schema the TUI reads), ADR-0025 (text input delegated to the CLI),
  ADR-0017 (user-home install path)

## Context

ADR-0023 made gum the preferred TUI backend with whiptail as fallback, and
locked the interaction model to **4 modal widgets** (`menu` / `checklist` /
`msgbox` / `yesno`) that *both* backends had to render natively. It
explicitly rejected fzf because "fzf cannot render msgbox / yesno natively"
— true under a modal-dialog model.

zh-TW verification of rc1/rc2 surfaced that the modal-dialog model has a hard
UX ceiling that no amount of polish removes:

- No master-detail. A dialog `checklist` cannot show per-row detail, so
  module descriptions / deps / "will pull N" had to be bolted on through a
  sentinel "View details..." row that opens a separate picker — universally
  disliked in review.
- No live preview. The user cannot see what a menu entry contains before
  entering it; counts and sub-items are invisible until you drill in.
- No real nesting. Categories were grouped *inside* one checklist by
  `tags[0]` instead of being navigable layers.
- Forced cross-backend alignment. "Both backends render all 4 widgets
  natively" tied the whole experience to the lowest common denominator of
  two curses-era-or-modal tools.

A grilling session (documented in the 0.1.0 TUI-redesign PRD) re-decided the
interaction model from first principles. The driving realisation: a demo
proved that `fzf --preview` delivers exactly the experience the user wants —
a **two-pane navigator** where the left pane is the current level and the
right pane *live-previews* whatever the cursor is on (a module's full
detail, or the contents/counts of the level below). Under this model fzf is
not "a backend that must also render msgbox/yesno" — those widgets stop
existing in the TUI at all (see ADR-0025). The previous fzf rejection no
longer applies because the premise it rejected (modal widgets) is gone.

## Decision

1. **The rich TUI tier is fzf (`junegunn/fzf`), used as a two-pane
   navigator. gum is dropped entirely** — all `_tui_*_gum` adapters, gum
   detection, the gum-install prompt, and gum-specific i18n are removed.
2. **whiptail stays the fallback tier**, guaranteed-present on Ubuntu, with
   **no extra dependency**. It is feature-equivalent to the fzf tier
   (nested drill-down, the secrets sub-menus, selection counts, recommended
   pre-selection) but renders degraded: detail is a separate read-only
   screen instead of a live second pane (ADR also drops whiptail's modal
   input — see ADR-0025).
3. **Every navigable level is the same two-pane screen** (main menu →
   category → sub-category → modules). The right pane always previews "what
   is one level down" for the cursor's current row:
   - on a branch row (menu entry / category / sub-category) → the children,
     with item counts and how many are currently selected;
   - on a module row → that module's full detail (description, tags,
     install status, recommended verdict, `depends_on`, "will pull N
     dependency modules").
4. **Selection is mutated live**, not committed-on-accept. fzf has no native
   multi-select pre-selection, so the page-replace model of ADR-0023 is
   abandoned: toggling a row immediately updates the in-memory selection
   accumulator (and the preview reflects it). This is what makes
   recommended-preselection (PRD D4) and cross-level accumulation work
   despite fzf's limitation.
5. **The two frontends share one data layer; only rendering + navigation is
   split** (see ADR-0026 for the file boundary). The CLI-fork helpers
   (`list/detect/show --json`), the selection accumulator, i18n resolution,
   and preference reads are shared; `render-fzf` and `render-whiptail` are
   the only divergent modules. A single entry script detects the tier and
   dispatches.
6. **Tier resolution** replaces gum>whiptail detection: prefer the fzf tier
   when `fzf` is present; offer to install it when absent and interactive
   (fork `setup_ubuntu install fzf`, same consent rule as the old
   gum-install prompt — G4: the TUI never installs inline); otherwise use
   the whiptail tier. `--backend fzf|whiptail` forces the tier and skips
   detection + the install prompt (invalid value → exit 2 with usage),
   keeping the CI/QA testability lever.

## Drivers

- **Master-detail is the user's actual mental model** (k9s / lazygit
  style): list on the left, live detail on the right. fzf `--preview`
  gives it for free; modal dialogs structurally cannot.
- **One dependency, not two.** With input/confirm delegated to the CLI
  (ADR-0025), the rich tier needs only fzf — no gum. The fallback tier
  needs nothing beyond Ubuntu's built-in whiptail.
- **Stop aligning to the lowest common denominator.** Splitting the
  frontends (per the maintainer's call) lets the fzf tier be as rich as fzf
  allows without being held back by whiptail, while whiptail still delivers
  feature-equivalence in a degraded render.

## Relation to G4 / ADR-0019

- **G4 (TUI = CLI frontend) is preserved and strengthened.** The TUI still
  forks `setup_ubuntu <subcommand>` for all data and all actions, sources no
  engine lib, and writes no state (the G4 grep gate stays green). fzf is a
  rendering tool only; the fzf `--preview` command re-invokes the TUI's own
  preview mode, which reads the same forked JSON.
- **ADR-0019 is unaffected.** Menu/detail data still comes from
  `list/detect/show --json`; the tier swap is purely a rendering concern and
  touches no JSON schema.

## Alternatives considered

- **Keep gum + whiptail (ADR-0023).** Rejected: the modal-dialog ceiling is
  the root cause of the UX complaints; polishing within it does not produce
  master-detail or nested navigation.
- **Keep gum alongside fzf** (fzf for lists, gum for input/confirm/style).
  Rejected: gum's only non-decorative roles are text input and confirm,
  both of which move to the forked CLI (ADR-0025); keeping gum for styling
  alone is not worth a second dependency.
- **A full-screen TUI framework (Go/Rust, e.g. bubbletea).** Rejected:
  breaks the "TUI = thin bash frontend that forks the CLI" architecture,
  drops the zero-dependency whiptail fallback, and is far larger than the
  problem warrants.
- **Make fzf the single tier (drop whiptail too).** Rejected: whiptail is
  the zero-install guarantee for users who decline fzf; the fallback tier
  is the reason the TUI works on a bare box.

## Consequences

- **PRD §8 is rewritten** for the two-pane navigator (new PRD; the old §8
  wireframe and §8.5 gum detection are superseded).
- **A new `module/fzf.module.sh`** (github-release static binary, multi-arch
  per ADR-0017) replaces `module/gum.module.sh` as the on-demand rich-tier
  install. gum's module is removed from TUI scope.
- **`lib/tui_backend.sh` is restructured** into a shared data layer plus
  `render-fzf` / `render-whiptail` modules; all gum adapters are deleted.
- **Testing**: the AC-10 dual-backend smoke now targets fzf + whiptail (fzf
  added to the test-tools image, gum removed); the G4 grep gate, the
  `TUI_CLI` recording-mock seam, and the per-screen entries producers are
  retained. fzf's preview-mode invocation gets its own unit coverage.
- This is a 0.1.0 blocker by the maintainer's scope decision (the first tag
  ships the redesigned TUI, not the modal-dialog one).
