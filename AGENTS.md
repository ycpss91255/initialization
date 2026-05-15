# AGENTS.md

Agent-facing notes for `init_ubuntu`. This file is read automatically by
agentic CLIs (Claude Code, Codex, etc.) at the start of a session.

For richer per-domain rules and skills, see `.claude/rules/` (also installed
to `~/.claude/rules/` via `install.sh`).

## Repo at a glance

- **Personal-use modular Ubuntu environment initialization tool** — bash +
  bats, Docker-only testing.
- Single-context repo; domain glossary lives in `CONTEXT.md`.
- Folder naming follows **plural-for-collections + singular-for-concepts**
  (see `docs/adr/0005-folder-naming-plural-for-collections.md`):
  collection dirs (`tests/`, `scripts/`, `hooks/`, `docs/`, `modules/`,
  `templates/`) are plural; concept / role / uncountable dirs (`lib/`,
  `config/`, `changelog/`) and acronyms (`adr/`, `prd/`, `ci/`) are
  singular; upstream-imposed layouts (fish `completions/`, QMK
  `keyboards/`, etc.) keep whatever the upstream uses.

## Hard rules

1. **Tests run inside Docker only.** Use `make test-unit` / `make test-integration` / `make coverage`. See `docs/adr/0004-tests-must-run-in-docker-only.md`. Enforced by `.claude/hooks/test-must-use-docker.sh` (PreToolUse).
2. **No host package installs.** Module Action Phases (install / upgrade / remove / purge) must not run on the host.
3. **Bash + Docker scope.** Language migration triggers documented in `docs/adr/0003-language-choice-and-migration-triggers.md`.

## Agent skills

### Issue tracker

GitHub issues on `github.com/ycpss91255/initialization`, accessed via the `gh`
CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default canonical vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`,
`ready-for-human`, `wontfix`). Labels auto-created on first apply. See
`docs/agents/triage-labels.md`.

### Domain docs

Single-context. Glossary at `CONTEXT.md`; ADRs at `docs/adr/`; module contract
at `docs/module-spec.md`; product spec at `docs/prd/init-ubuntu.prd.md`. See
`docs/agents/domain.md`.
