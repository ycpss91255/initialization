---
name: feedback-autonomous-test-gap-remediation
description: "Don't ask permission to fix bugs / close test gaps — drive autonomously via workflows"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 15320221-f6f9-442e-9faa-924d66c5db63
---

When work reveals a bug or a test-coverage gap, **do not ask the user whether to fix it or how to scope it** — just fix it and close the gap. Drive it autonomously, using a Workflow with parallel agents where the work decomposes (the user's standing preference: "能用 workflow 的就用", and "這種事情不用問").

**Why:** the user treats "currently failing / untested" as an obvious, standing mandate — "目前來看就是沒有通過測試,需要持續修復" (2026-06-19). Asking for permission on each fix/test-gap is friction they explicitly rejected.

**How to apply:** file the tracking issue(s), build the fix + regression test (workflow + worktree + TDD per [[project-release-tag-ceremony]] / the repo's Docker-only `just` flow), verify in the foreground (per [[feedback-subagent-no-background-verify]]), PR + auto-merge. Only stop to ask when there's a genuine *product/scope* fork (e.g. which feature to build, whether to cut a release tag — release tags ARE outward/irreversible and still need a yes).

Concrete example that set this: the module_helper-not-sourced bug (real install of github-release modules broken) slipped through all tests because no test exercised the real non-dry-run engine path (dry-run is dispatcher plan-only; unit `_load_engine` self-sources module_helper; CI base-install was apt-only). The fix + a `verify gum` regression + a keystone real-engine-lifecycle integration harness were expected as autonomous follow-through, not a question.
