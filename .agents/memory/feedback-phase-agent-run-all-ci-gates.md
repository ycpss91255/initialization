---
name: feedback-phase-agent-run-all-ci-gates
description: Implementation sub-agents must run test-unit AND test-integration AND coverage in Docker before reporting green — not a subset
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 15320221-f6f9-442e-9faa-924d66c5db63
---

When delegating an implementation phase to a worktree sub-agent, the agent's
"green" report MUST come from running all three Docker gates:
`just -f justfile.ci test-unit`, `just -f justfile.ci test-integration`, and
`just -f justfile.ci coverage`. A subset is not enough.

**Why:** the phase-2 (fzf navigator) agent ran only test-unit + coverage and
reported green, but it had made `--backend` reject `gum` while the AC-10/AC-11
dual-backend smoke in `test/integration/tui/` still drives `--backend gum`.
test-integration (which the agent skipped) caught it only on CI, costing a
red PR + a fix round-trip. test-unit and test-integration exercise different
surfaces (integration runs the TUI smoke harness + real installs); passing one
says nothing about the other.

**How to apply:** put "run test-unit AND test-integration AND coverage, all
green, before reporting" explicitly in every phase-agent prompt. On a red CI
job, check `gh pr checks <n>` first to see WHICH job failed before assuming the
gate is coverage. Relates to [[feedback-autonomous-test-gap-remediation]] and
[[project-ci-lint-covers-bats]].
