# ADR-0023: gum is the preferred TUI backend (gum > whiptail; dialog dropped)

- **Status:** Accepted
- **Date:** 2026-06-19
- **Relates to:** PRD G4 (TUI = CLI frontend), ADR-0019 (`list --json`
  schema the TUI reads), ADR-0017 (user-home install path)

## Context

`setup_ubuntu_tui.sh` is one of the three frontends (CLI / TUI / secrets)
that all delegate to the same Engine (PRD §4). The TUI is a thin frontend:
it reads `setup_ubuntu list --json` / `detect --json`, collects the user's
intent through 4 contract widgets — `menu` / `checklist` / `msgbox` /
`yesno` — then forks `setup_ubuntu <subcommand> <modules…>` to do the work
(PRD G4). It sources **no** engine lib and writes **no** state, so AC-11
(CLI/TUI install parity) holds structurally.

`lib/tui_backend.sh` is the unified contract for those 4 widgets. The
original design (PRD §8.5) detected `dialog` first, then `whiptail`, then
fell back to a fatal "install whiptail" message. Both `dialog` and
`whiptail` are curses-era tools that look dated.

The HTML+JS analogy already governs this layer: the TUI is the markup, the
backend is the rendering engine. Different engines paint pixels their own
way; the contract aligns **behavior/results, not pixels** — identical input
args, identical stdout result (the selected **tag**), identical exit-code
semantics across backends. Adding a backend therefore costs an
alignment burden: every backend must render all 4 widgets and agree on the
result contract.

A grilling session settled the direction: prefer a modern backend, keep the
set minimal, and keep `whiptail` as the always-present fallback.

## Decision

1. **gum (`charmbracelet/gum`) is the preferred TUI backend; `whiptail` is
   the fallback; `dialog` is dropped** from scope. Detection order is
   **gum > whiptail** (no more `dialog`).
2. **The backend set is exactly two: gum + whiptail.** Both can render all
   4 contract widgets natively, so neither needs a shimmed widget. Keeping
   it to two minimizes the cross-backend alignment burden.
3. **whiptail stays the guaranteed fallback.** Ubuntu Server/Desktop ship
   `whiptail` (Priority: important), so the existing fatal path
   ("`sudo apt install whiptail`, or use CLI mode") is essentially never
   reached. `whiptail` adapters are unchanged from the current code.
4. **Each contract widget becomes a dispatcher** → `_tui_<widget>_<backend>`.
   The frontend is unchanged: it still passes `tag item [status]` and still
   reads back the **tag**. gum adapters:
   - `menu` → `gum choose` over the **items**; map the choice back to its
     **tag by index** (gum has no hidden value, and index-mapping is safe
     under duplicate labels).
   - `checklist` → `gum choose --no-limit`; checked items map to tags, one
     tag per line (matching the whiptail `--separate-output` contract).
   - `msgbox` → `gum style` / `gum format` the text + single-key continue.
   - `yesno` → `gum confirm` (native exit 0/1).
5. **Exit-code normalization is part of the contract:** `0` = confirm,
   non-zero = cancel/Back. gum Esc/Ctrl-C (130) and whiptail cancel (1)
   both map to non-zero; adapters must not swallow it.
6. **gum visual style = defaults** (no custom theme — KISS). Out of scope.
7. **gum install is github-release only** (a new `module/gum.module.sh`,
   multi-arch static binary → covers x86_64, rpi4/5, Jetson, per ADR-0017
   user-home install). The apt / charm-repo path is out of scope.
8. **The TUI never installs anything itself** (PRD G4). When gum is absent:
   - **interactive** (`[[ -t 0 ]]`) → a plain stdin/stdout `read` prompt
     (default **Yes**): "Install gum for a nicer TUI? \[Y/n]". On yes →
     fork `setup_ubuntu install gum`, re-detect, launch with gum. On no →
     whiptail. The prompt is plain text because no TUI tool is assumed at
     that point.
   - **non-interactive** → no prompt, use whiptail.
9. **`--backend gum|whiptail`** forces `TUI_BACKEND` and **skips detection
   + the install prompt** (invalid value → exit 2 with usage). It is the
   testability lever that lets CI/QA force either backend regardless of what
   is installed (`just tui --backend whiptail` works via the existing
   pass-through recipe — no justfile change).

## Drivers

- **Modern UX.** gum is a single static Go binary with a contemporary look;
  `dialog`/`whiptail` look dated.
- **Multi-arch static binary.** gum ships amd64 / arm64 / armv7 releases,
  covering every target platform (x86_64, rpi4/5, Jetson) with no compile
  step and no sudo (user-home install per ADR-0017).
- **Fewer backends to align.** Dropping `dialog` and not pursuing `fzf`
  leaves two backends that both render all 4 widgets natively — the minimal
  set that still keeps a guaranteed fallback. Less cross-backend alignment,
  less maintenance.

## Relation to G4 / ADR-0019

- **G4 (TUI = CLI frontend) is preserved.** gum changes only how the 4
  widgets are *rendered*; the frontend still collects intent and forks the
  CLI. `lib/tui_backend.sh` still sources no engine lib (the G4 grep gate
  stays green). The install-gum prompt does not break G4 either — the TUI
  forks `setup_ubuntu install gum` rather than installing inline.
- **ADR-0019 is unaffected.** The TUI still reads menu data from
  `list --json` / `detect --json`; the backend swap is purely a rendering
  concern and touches no JSON schema.
- **Contract = behavior, not pixels.** Consistent with the HTML+JS framing:
  gum and whiptail render the same logical widget differently, but the
  args, the stdout tag result, and the exit-code semantics are identical.

## Reconciliation with in-flight TUI work

- **#168 (row clip).** gum manages its own width, so the `_tui_clip`
  budget applies to whiptail; gum rows must not double-clip.
- **#169 (section separators).** The non-selectable divider row must render
  acceptably under gum `choose` (or the per-backend difference is
  documented).

## Alternatives considered

- **Keep dialog as a third backend.** Rejected: three backends triples the
  alignment burden for no UX gain over gum, and `dialog` looks no better
  than `whiptail`.
- **Add `fzf` as a backend.** Rejected: `fzf` cannot render `msgbox` /
  `yesno` natively, so it would need shimmed widgets — breaking the
  "every backend renders all 4 natively" property.
- **gum via apt / charm repo.** Rejected (per grilling): adds an apt source
  and needs sudo; the github-release static binary installs to user-home
  with no sudo and covers all arches.
- **Custom gum theme.** Rejected: KISS — defaults are good enough for 0.1.0.
- **Auto-install gum without asking.** Rejected: violates G4 / the
  "no install without user consent" rule; hence the interactive prompt and
  the non-interactive whiptail fallback.

## Consequences

- A new optional binary dependency (gum) — but it is install-on-demand
  (prompted, never forced), user-home, multi-arch, and the whiptail
  fallback guarantees the TUI works with zero new dependencies.
- Testing parity must cover **both** backends: gum adapter tag/index
  mapping, detection order (gum > whiptail), `--backend` parsing, the
  read-prompt branches (mock `command -v gum` + the install fork), and the
  AC-10 live smoke against both gum and whiptail (`gum` added to the
  test-tools image).
- PRD §8.5 detection pseudocode, the §4 / §5 TUI notes, and the AC-10 dual
  backend wording change from `dialog` to `gum`.
- This narrows and supersedes the earlier "0.2.0 pluggable backend" idea:
  the backend set is fixed at gum + whiptail for 0.1.0.
