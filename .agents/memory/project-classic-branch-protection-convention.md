---
name: project-classic-branch-protection-convention
description: ycpss91255* org repos use classic branch protection (not rulesets) for main; ci-passed aggregator pattern
metadata: 
  node_type: memory
  type: project
  originSessionId: 49f35dfc-2a9b-4c0c-be0a-c23cd62cb0e3
---

# Branch protection convention: classic, not rulesets

`ycpss91255*` org repos govern `main` via **classic branch protection** (`PUT /repos/.../branches/main/protection`), not the newer Rulesets API.

**Why:** `gh` OAuth token can write classic protection but not ruleset PATCH (see [[reference-gh-oauth-token-limits]]). Sticking to classic keeps governance changes scriptable via `gh`.

**How to apply:**

- New repo lockdown — use `PUT /branches/main/protection` mirroring `ycpss91255-docker/ros_distro` or `ycpss91255-docker/base` (both have identical shape: `ci-passed` strict + `enforce_admins: true` + `allow_force_pushes: false` + `allow_deletions: false`).
- init_ubuntu adds `required_approving_review_count: 1` on top (self-PR drill); others run at 0.
- CI workflow must expose a single aggregator job (`ci-passed` on init_ubuntu, `ci-rollup` on base) that depends on all real jobs with `if: always()`. Required status checks reference only the aggregator — never individual job names — so doc-only PRs that skip heavy jobs still get unblocked.
- If a future task asks to "migrate to rulesets" / "use the new Rulesets API": flag the OAuth token limitation, and require either a fine-grained PAT with `Administration: write` or Web UI edits.
