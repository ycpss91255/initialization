# AGENTS.md

Agent-facing notes for `init_ubuntu`. This file is read automatically by
agentic CLIs (Claude Code, Codex, etc.) at the start of a session.

For richer per-domain rules and skills, see `.claude/rules/` (also installed
to `~/.claude/rules/` via `install.sh`).

Agent config has a single tool-agnostic source of truth: `hook/`, `rules/`,
`script/`, and `skills/` live under **`.agents/`** and are symlinked into
`.claude/` (so Claude Code, Codex, etc. share one copy). Edit the real files
under `.agents/`; the `.claude/` paths are symlinks. Claude-runtime entries
(`settings.json`, `projects/`, `worktrees/`) stay in `.claude/`.

## Repo at a glance

- **Personal-use modular Ubuntu environment initialization tool** — bash +
  bats, Docker-only testing.
- Single-context repo; domain glossary lives in `CONTEXT.md`.
- Folder naming is **all-singular**
  (see `doc/adr/0021-folder-naming-all-singular.md`, supersedes ADR-0005):
  every repo-owned dir is singular (`test/`, `script/`, `doc/`, `module/`,
  `template/`, `lib/`, `config/`, `changelog/`). Only two exception
  classes: upstream-imposed layouts (fish `completions/`, QMK
  `keyboards/`, etc.) keep whatever the upstream uses, and acronyms
  (`adr/`, `prd/`, `ci/`) stay as-is. File names (including ones ending
  in `s`) are out of scope — deferred to 0.2.0.
- TUI tiers are **fzf (Rich tier, two-pane navigator) preferred > whiptail
  (Fallback tier) guaranteed** (see
  `doc/adr/0024-fzf-two-pane-tui-replaces-gum.md`, supersedes ADR-0023; gum is
  dropped as a backend — it remains installable as a tool via `setup_ubuntu
  install gum`). The TUI = CLI frontend (PRD G4): it forks `setup_ubuntu
  install fzf` rather than installing inline, and `setup_ubuntu_tui.sh
  --backend fzf|whiptail` forces a tier (skips detection + the pre-launch
  fzf-install prompt) — the lever CI/QA use to test either tier.

## Hard rules

1. **Tests run inside Docker only.** Use `just -f justfile.ci test-unit` / `just -f justfile.ci test-integration` / `just -f justfile.ci coverage` (the CI gate; `just` replaced `make` per `doc/adr/0022-just-replaces-make-as-task-runner.md`). See `doc/adr/0004-tests-must-run-in-docker-only.md`. Enforced by `.claude/hook/test-must-use-docker.sh` (PreToolUse).
2. **No host package installs.** Module Action Phases (install / upgrade / remove / purge) must not run on the host.
3. **Bash + Docker scope.** Language migration triggers documented in `doc/adr/0003-language-choice-and-migration-triggers.md`.

## Script conventions

- Exit-code-contract scripts (`.claude/hook/*.sh`, `.claude/script/release-tag.sh`) default to `set -uo pipefail`. `-euo` is reserved for always-act semantics. See `doc/adr/0007-exit-code-contract-scripts-default-to-set-uo.md` for the rationale and the Exception criteria.
- New `# shellcheck disable=...` directives are gated by `.claude/hook/enforce_shellcheck_disable_approval.sh` (PreToolUse on Edit/Write/MultiEdit). Consult <https://www.shellcheck.net/wiki/SC{code}> first; if no proper fix applies, request explicit user approval via the phrase `approve SC<code>` (case-insensitive on the verb; batchable: `approve SC2034 SC1091`). Approval is read from the system-controlled session transcript — it cannot be forged.

## Agent skills

### Issue tracker

GitHub issues on `github.com/ycpss91255/initialization`, accessed via the `gh`
CLI. See `doc/agent/issue-tracker.md`.

### Triage labels

Default canonical vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`,
`ready-for-human`, `wontfix`). Labels auto-created on first apply. See
`doc/agent/triage-labels.md`.

### Domain docs

Single-context. Glossary at `CONTEXT.md`; ADRs at `doc/adr/`; module contract
at `doc/module-spec.md`; product spec at `doc/prd/init-ubuntu.prd.md`. See
`doc/agent/domain.md`.
