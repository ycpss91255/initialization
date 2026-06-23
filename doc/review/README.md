# Post-rc review — v0.1.0-rc3

Three independent read-only reviews of the codebase at tag `v0.1.0-rc3`
(2026-06-23), one per lens. Findings are RAISED FOR DISCUSSION, not auto-fixed
(maintainer decides). Each lens has its own document:

- [security-review.md](security-review.md) — software vulnerabilities (0 CRITICAL, 1 HIGH, 4 MEDIUM, 6 LOW)
- [architecture-review.md](architecture-review.md) — system architecture (3 Strong, 9 Worth exploring, 2 Speculative, 4 ADR-drift)
- [linux-review.md](linux-review.md) — Linux / shell correctness + portability (3 CRITICAL, 7 HIGH, 9 MEDIUM, 8 LOW)

## Pivotal scope question (gates triage of everything below)

Both the Linux and architecture reviews observe that a large share of the worst
findings live in LEGACY v1 scripts (`tool/setup_wayland.sh`,
`module/setup_nvidia_driver.sh`, `small-tools/`, top-level `setup_*.sh`) rather
than the v2 module/engine/TUI surface. **Are those legacy scripts in the
supported 0.1.0 surface, or slated for removal/quarantine?** If out of scope,
~half the CRITICAL/HIGH Linux findings (F2 wayland, F3 legacy nvidia, etc.) are
moot for the tag and become "delete the legacy script" rather than "fix it".

## Cross-cutting themes

### Live-path bugs to triage regardless of the legacy question

- LINUX F1 (CRITICAL) — `lib/general.sh` `backup_file` calls `log_fatal`
  (uncatchable exit 1) when `BACKUP_DIR` is unset, and the v2 path never sets it;
  aborts config re-runs/upgrades (fish/tmux/neovim) on all targets.
- SECURITY SR-01 (HIGH) — the test-only GitHub-fetch seam
  (`INIT_UBUNTU_TEST_GH_FIXTURE_DIR` / `_GH_VERSION`, `lib/module_helper.sh`) is
  reachable in production via env vars with no test-mode gate (payload-swap).
- ARCH F1 (Strong) — per-module `doctor()` overrides are unreachable from the
  Engine (`runner_doctor` is dead code; `doctor` subcommand only runs
  `is_installed`), yet all templates tell authors the Engine calls `doctor()`.
- ARCH F2 / LINUX (version string two-sources-of-truth) — `list --installed`
  shows the static `VERSION_PROVIDED` ("latest") instead of the resolved Sidecar
  tag.

### Hardening (no single exploit, but worth a policy)

- SECURITY SR-02/SR-03 — root-privileged archive extraction without
  `--no-same-owner` / path-traversal guard; no checksum/signature verification in
  the github-release archetype or the `curl | bash` installers (unpinned `latest`).

### Documentation drift (clear must-fix, low risk)

- PRD #242 §8.5 + AC-10 and `module/gum.module.sh`'s self-description still
  describe the superseded gum two-backend model (contradict ADR-0024/0025). The
  primary product spec describes a TUI that no longer ships. Rewrite to
  fzf>whiptail. (`doc/design/*.md` are already self-flagged superseded.)

### Deepening opportunities (not urgent, post-tag)

- `lib/dispatcher.sh` (1291 lines) and `setup_ubuntu_tui.sh` (1535 lines) exceed
  the 800-line cap with clean split seams available (catalog/lifecycle/state-io;
  the fzf navigator loop belongs in `lib/tui_render_fzf.sh`).

## What the reviews confirmed is SOUND (preserve)

Architecture fundamentally solid: deep modules + real seams (archetype macros,
Environment `_environment_classify`, State migrate/io seams, the #6 registry and
#7 broker); G4 and ADR-0024/0025/0026/0027 upheld in code. Secrets subsystem
clean (`token get` kept out of the TUI, 600/700 perms, `umask 077`, `-pass
env:`); atomic state writes + flock + corruption quarantine; jq `--arg`
injection-safe; github-release arch mapping correct for all stated x86_64 +
aarch64 targets. The earlier "CRITICAL RCE" exploration leads were verified down
to LOW (repo-authored values, not attacker-controlled).
