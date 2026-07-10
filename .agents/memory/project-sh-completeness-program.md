---
name: project-sh-completeness-program
description: "Definition-of-done for the post-rc \"make the shell layer complete\" program (before returning to TUI)"
metadata: 
  node_type: memory
  type: project
  originSessionId: 15320221-f6f9-442e-9faa-924d66c5db63
---

STATUS 2026-07-05: **COMPLETE.** All 6 scopes landed (PRs #291-#323): bugs
(#292), security (#306), hook specs (#323 = hook layer now 100% spec-covered,
maintainer chose to cover all 9 incl. advisory reminders), architecture
deepenings (#307 dispatcher split, #299 doctor-wiring, #304 version-source),
legacy triage (#320 delete-17 + setup_wayland fix, #321 fish_variables, #322
trash->module closing #275/#277), pyramid (#295, #305). Legacy KEPT by maintainer
decision: install.sh/remove.sh (until the ~6 monitor tools + others get modules
per PRD setup_small_tools split), tmux READMEs (deferred). Next up when resumed:
either the PRD setup_small_tools per-tool module split (which then unblocks
deleting install.sh), or revisit the parked TUI backlog.

After v0.1.0-rc3 the maintainer deferred TUI polish and asked to "fully handle
the sh layer first" (2026-07-04). Completion bar = **complete AND covering the
whole test pyramid**, not just correctness. Scope:

1. Fix the v2-path bugs from the post-rc reviews (doc/review/): Linux F1
   `backup_file` CRITICAL (BACKUP_DIR unset -> uncatchable exit 1 aborts config
   re-runs), dispatcher `set --` word-splitting, etc.
2. Security hardening (security-review.md): the `INIT_UBUNTU_TEST_GH_*` test-seam
   is production-reachable (gate it), root-privileged archive extraction needs
   `--no-same-owner` + path-traversal guard, add checksum/signature verification
   to the github-release archetype + curl|bash installers.
3. Hook test gaps: ~9 of 14 `.claude/hook/*.sh` lack specs (test-must-use-docker,
   enforce_semver_tag_via_script, check_changelog_drift, enforce_gh_body_file,
   enforce_gh_english, remind_* ...). Add block-path + allow-path specs.
4. Architecture deepenings (architecture-review.md): split `lib/dispatcher.sh`
   (1291-line god-file), wire the per-module `doctor()` override (runner_doctor
   is dead code; the Engine `doctor` only runs is_installed), fix the version
   two-sources (`list --installed` shows static `latest`, not the Sidecar tag).
5. Legacy `tool/` + `small-tools/` = **per-script triage** (maintainer chose
   this): promote issue-backed ones (trash-maintenance -> a proper module for
   #275/#277) with tests; delete or mark-deprecated the truly-dead ones already
   replaced by v2 (old nvidia/wayland etc). These dirs are ci.sh-excluded today.
6. Full pyramid coverage for all the above.

**TUI status (2026-07-04):** BACKLOGGED. The maintainer is now leaning toward
NOT maintaining the terminal TUI at all (CLI-only), or at least deferring any
TUI decision until the whole CLI/engine/module architecture is essentially
complete. Do not grill or build TUI now. The 6 residual TUI UX gaps are recorded
in doc/review/tui-feedback-traceability.md as the backlog. HTML is a separate
future-additive idea (not a replacement), also parked.

**Why:** solidify the CLI/engine/module/hook shell foundation (the product the
maintainer actually ships) before any TUI reconsideration. **How to apply:** drive each workstream via
worktree + TDD + implement->review->PR->automerge; per
[[feedback-autonomous-test-gap-remediation]] do NOT ask to fix bugs / close
test gaps -- only ask on genuine product/scope forks. TUI work is parked and
recorded in doc/review/tui-feedback-traceability.md. Related:
[[project-coverage-shards-unit-only]], [[feedback-phase-agent-run-all-ci-gates]].
