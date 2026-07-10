# ADR-0025: the TUI collects no free-form text; input and confirmation are delegated to the forked CLI

- **Status:** Accepted
- **Date:** 2026-06-21
- **Relates to:** ADR-0024 (fzf two-pane TUI), PRD G4 (TUI = CLI frontend),
  AC-20 (secret values prompted on the tool's own no-echo tty)

> **Deferred — design-accepted, not built in 0.1.0.** The decision below
> ("the TUI collects no free-form text; input and confirmation are
> delegated to the forked CLI") is NOT realized. The code still uses
> `tui_render_input` — the TUI continues to render free-form text input
> in-widget — so `tui_render_input` was not removed, and the CLI's
> interactive-when-missing prompt mode was not built. Treat everything
> below as the intended design, not current behaviour.

## Context

The fzf rich tier (ADR-0024) does navigation, selection, and live preview,
but **fzf is not a text-input tool** — it filters an existing list, it
cannot collect an arbitrary new string. The flows that need free-form text
are all in Manage Secrets: a token name, a `user@host` copy target, a GPG
key-file path, and the type-the-name confirmation for SSH-key deletion.

ADR-0023's answer was a `tui_render_input` widget (gum `input` / whiptail
`--inputbox`, added in #233/#200). With gum dropped, the options for those
prompts are: keep a widget (gum or whiptail), use bash `read`, or push the
prompt into the forked CLI itself.

AC-20 already establishes the relevant pattern: secret *values* and
passphrases are never collected by the TUI — `setup_secrets` prompts them on
its own no-echo tty. The non-secret args (name / host / path) were the only
text the TUI still collected.

## Decision

**The TUI collects no free-form text and renders no confirmation dialog.
All text entry and all confirmation happen in the forked CLI subprocess, on
its own tty.**

1. **`tui_render_input` is removed** from both tiers (the #233/#200 widget
   is retired). Neither the fzf tier nor the whiptail tier owns a text-input
   widget.
2. **Confirmation moves to the CLI too.** Destructive actions
   (remove / purge / secret deletion) and the install go-ahead are confirmed
   by the forked CLI's own prompt (e.g. the existing `-y` / apt-style
   "Proceed?" path), not by a TUI yes/no dialog. The TUI's job ends at
   "fork the right subcommand".
3. **The relevant CLI subcommands gain an interactive-when-missing mode**:
   when a required non-secret arg is absent, the subcommand prompts for it
   on its tty instead of erroring. This applies to the secrets flows that
   the TUI used to pre-collect (`token set <name>`, `ssh-key copy <target>`,
   `gpg import <path>`, the SSH-key delete confirmation). Secret values stay
   on the tool's no-echo tty exactly as AC-20 requires.
4. **The TUI clears the screen and hands the terminal to the CLI** for these
   flows (the existing `_tui_secrets_run` clear-then-fork pattern), then
   returns to the navigator on completion.

## Drivers

- **It lets the rich tier need only fzf** — no gum, no second dependency,
  no bash-`read` screens that look bare next to fzf.
- **It is the most faithful expression of G4.** "The TUI is a thin frontend
  that forks the CLI" becomes literally true: the TUI never reads a
  character of user text; the engine owns every interactive prompt.
- **It removes a whole class of widget complexity** (cancel/empty/`--`-guard
  semantics, per-backend input adapters, no-echo variants) from the TUI.

## Alternatives considered

- **Keep gum for input/confirm only.** Rejected: a second dependency for two
  prompts; see ADR-0024.
- **bash `read` for input + fzf two-item list for confirm.** Rejected: the
  input screens look bare, and it duplicates prompting logic the CLI can own
  once for both the CLI and TUI entry points.
- **Keep whiptail `--inputbox` in the fallback tier only.** Rejected:
  divergent input models across tiers, and it keeps the input widget alive
  for no real gain over CLI delegation.

## Consequences

- **CLI/secrets subcommands grow an interactive-when-missing prompt mode** —
  a small, well-scoped engine change, and it benefits direct CLI users too.
- **The fzf tier is input-free**; the navigator is purely
  move / toggle / descend / back.
- **Tests**: `tui_render_input` specs are retired; new coverage targets the
  CLI subcommands' interactive-when-missing prompts. AC-20 (no secret value
  through the TUI) is preserved structurally and gets easier to argue (the
  TUI now touches no input at all).
