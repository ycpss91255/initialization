---
name: project-workflow-long-implement-no-schema
description: "Workflow authoring: do NOT put a StructuredOutput schema on a long implement stage; it fails to emit and errors the run"
metadata: 
  node_type: memory
  type: project
  originSessionId: 15320221-f6f9-442e-9faa-924d66c5db63
---

In the implement->review->integrate Workflow pattern, a LONG implement agent
(many tool calls / big token spend) frequently finishes its work but does NOT
call StructuredOutput at the end, so `agent(..., {schema})` throws
"subagent completed without calling StructuredOutput (after 2 in-conversation
nudges)" and the whole workflow errors -- AFTER the work is done (seen on
fish-lint wf_94eac787 ~112k tok, and LPT-sharding wf_d45041d7 ~185k tok). Adding
"you MUST call StructuredOutput" to the prompt did NOT prevent it.

**Fix (apply to all long implement workstreams):**
- Do NOT attach a schema to the implement agent. Give it a HARDCODED branch name,
  have it work + `git commit` on that branch (so the work is durable even if the
  final message is lost), and return free text (the workflow ignores it).
- The review / fix / integrate stages take the hardcoded BRANCH name and locate
  the worktree themselves with `git worktree list | grep <branch>` (or read the
  worktree path from that), instead of depending on the implement agent to return
  a worktreePath via schema. Keep schemas only on the SHORT stages (review verdict,
  integrate result) where StructuredOutput reliably fires.
- If it still errors post-work, SALVAGE: a read-only diagnostic agent finds the
  orphaned worktree by branch, assesses completeness, then a commit-then-gate
  workflow finishes it (pattern used for fish-lint -> PR #296).

**Why:** the schema requirement at the end of a long agent session is the fragile
point; committing early + locating-by-branch removes the dependency.

**Bigger root cause (added 2026-07-05):** the failure hits ANY long-running stage,
not just implement -- the LPT salvage's review/integrate stages failed the same
way after 156 min. The reason those stages run so long is they RE-RUN the local
single-pass `just -f justfile.ci coverage` (kcov over ~120 specs = 30-40 min on
this box). That is (a) slow, (b) the CPU-oversubscription culprit, AND (c)
REDUNDANT -- the authoritative AC-17 coverage check is the PR's CI sharded
coverage-merge, not the local single-pass. Fix: **review/fix/integrate stages
should run only `test-unit` + `test-integration` locally (fast) and rely on the
PR's CI for coverage.** The implement stage may run coverage once. This keeps
agent sessions short (reliable StructuredOutput) AND cuts CPU load. Note: a
failed-at-StructuredOutput integrate stage often ALREADY pushed + opened the PR +
armed auto-merge before dying -- check `gh pr list --head <branch>` and just
dual-watch the PR rather than re-running (LPT -> PR #298 this way).

**How to apply:** author future sh workstreams (security, dispatcher split, legacy
triage, version-source) with no-schema implement + branch-located later stages +
test-unit/test-integration-only gates (no local coverage). Related:
[[project-sh-completeness-program]], [[project-workflow-concurrency-ram-cap]].
