# Test-pyramid review — v0.1.0-rc3

Read-only audit of test completeness against the test pyramid (2026-07-03,
tag `v0.1.0-rc3`). Companion to the three post-rc reviews in this directory.

## Verdict

The suite is a healthy pyramid: a wide, near-complete unit base, a thin
integration middle for cross-module flows, and a small expect-driven E2E top.
Shape is correct for a bash tool (most logic is pure and tested at the unit
layer through the module contract). No ice-cream-cone or hourglass anti-pattern.

| Layer | Files | @test | Source coverage |
|---|---|---|---|
| Unit (base) | 94 | 4076 | every `lib/*.sh` has a spec; all 39 `module/*.module.sh` have a spec; `script/` has 8 specs for 6 scripts |
| Integration (middle) | 5 | 21 | engine lifecycle, state export/import, sync-ssh, TUI real-install, TUI smoke |
| E2E (top, expect) | 5 | n/a | lang, real-install, smoke, fzf-smoke, whiptail-parity |

Ratio 4076 : 21 : 5. Bottom-heaviness is appropriate here: modules are
verified through their lifecycle contract at the unit layer, so the middle and
top layers only need to prove the cross-module wiring, not re-test each module.

## Confirmed out of scope (not a gap)

`script/ci/ci.sh:139-158` explicitly excludes `small-tools/` (845 lines) and
`tool/` (443 lines) from lint and coverage, documented as "legacy install
scripts, replaced by module/" and a "one-off holding area (PRD 6.5/6.6)". These
legacy v1 scripts (`tool/setup_wayland.sh`, `module/setup_nvidia_driver.sh`,
etc.) are therefore a DECLARED out-of-scope surface for 0.1.0; their lack of
tests is intentional, not a pyramid gap. This settles the open question the
architecture + linux reviews raised: the linux-review F2/F3 CRITICALs sit in
this excluded surface and should be triaged as "remove / quarantine the legacy
script", not "add tests / fix".

## Gap: enforcement hooks are under-tested

14 hooks live under `.claude/hook/`; roughly 5 have a dedicated spec, ~9 do not.
The untested set includes several that guard the project's hard rules and thus
carry real regression risk if silently broken:

- `test-must-use-docker.sh` — enforces ADR-0004 (tests run in Docker only)
- `enforce_semver_tag_via_script.sh` — blocks ad-hoc `git tag v*`
- `check_changelog_drift.sh` — requires a CHANGELOG entry for code changes
- `enforce_gh_body_file.sh` / `enforce_gh_english.sh` — gate GitHub artifacts
- `remind_no_emoji.sh`, `remind_main_sync.sh`, `remind_workflow_tdd.sh`,
  `check_main_fresh_before_worktree.sh` — advisory reminders (lower risk)

Tested hooks (for reference): approval_check, disable_diff,
enforce_gh_issue_template, enforce_long_job_timeout,
enforce_shellcheck_disable_approval, remind_ci_auto_merge, transcript_reader,
worktree_create.

Enforcement hooks (the first five above) are the meaningful gap: they are the
executable guarantee behind the repo's hard rules, yet nothing proves they
still fire on the inputs they must block. Advisory reminders are lower priority.

### Remediation options (not applied)

1. Add `test/unit/hook/*_spec.bats` for the five enforcement hooks, asserting
   both the block path (exit 2 + message) and the allow path, mirroring the
   existing hook specs (e.g. `enforce_long_job_timeout_spec.bats`). Strong.
2. Cover only `test-must-use-docker.sh` + `enforce_semver_tag_via_script.sh`
   (the two with the highest blast radius) now; defer the rest. Pragmatic.
3. Accept as-is: hooks are dev-tooling, not shipped product. Records the
   decision but leaves the guard-rails unverified. Weakest.

## Open question for the maintainer

Are the `.claude/hook/` enforcement hooks considered in-scope for the test
requirement (they are tool-agnostic repo infrastructure under `.agents/`), or
deliberately exempt as tooling? The answer decides whether the gap above is
worth closing before the next tag.
