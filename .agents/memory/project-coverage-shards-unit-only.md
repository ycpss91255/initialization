---
name: project-coverage-shards-unit-only
description: AC-17 merged coverage gate counts UNIT bats only; expect/integration smoke is not in the kcov shards
metadata: 
  node_type: memory
  type: project
  originSessionId: 15320221-f6f9-442e-9faa-924d66c5db63
---

CI's AC-17 80% merged coverage gate (`just -f justfile.ci coverage-merge`, run from
the sharded `coverage-unit` jobs = `ci.sh --unit-only --kcov`) traces UNIT bats specs
only. The expect-based integration smoke (`test/integration/tui/*.exp`,
`just -f justfile.ci test-integration`) is NOT in the kcov shards.

Consequence: new code reachable ONLY through an expect smoke shows up as uncovered and
drags the merge down (PR #258 hit 79.95% < 80% because the new `lib/tui_secrets.sh`
secrets sub-screens were driven only by `smoke_flow_whiptail_parity.exp`). The forked
entrypoint IS traced under kcov (a `tui_e2e_run`-style UNIT test that forks
`setup_ubuntu_tui.sh` covers sourced libs), so the fix is to add a UNIT bats e2e-harness
test (`test/helper/tui_harness.bash`) that drives the screen through the fork.

**Why:** the local single-pass `just -f justfile.ci coverage` number != the CI sharded
merge; a green single-pass run can still fail the merged gate by a hair.
**How to apply:** when adding TUI screens/libs, cover them with UNIT e2e-harness specs,
not just expect smoke. To debug a merge-gate miss: `gh run download <runId> -n
coverage-report`, parse `kcov-merged/cobertura.xml` for per-file uncovered line numbers.
Related: [[project-kcov-merge-exclude-region]], [[feedback-phase-agent-run-all-ci-gates]].
