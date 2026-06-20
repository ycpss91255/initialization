---
name: reference-gh-oauth-token-limits
description: gh CLI OAuth user-to-server token (gho_***) with repo scope can GET/DELETE repository rulesets but cannot PATCH them; classic branch protection PUT works fine
metadata: 
  node_type: memory
  type: reference
  originSessionId: 49f35dfc-2a9b-4c0c-be0a-c23cd62cb0e3
---

# gh OAuth token capability gap for rulesets PATCH

`gh auth login` mints OAuth user-to-server tokens (`gho_***`). Even with `repo` scope + repo admin permission, these tokens hit **404 Not Found** on `PATCH /repos/{owner}/{repo}/rulesets/{id}` (GitHub disguises 403 as 404 for this endpoint; response strips `X-OAuth-Scopes` / `X-Accepted-OAuth-Scopes` headers as confirmation).

What works on the same token:
- `GET /repos/{owner}/{repo}/rulesets/{id}` — 200
- `DELETE /repos/{owner}/{repo}/rulesets/{id}` — 204
- `PUT /repos/{owner}/{repo}/branches/{branch}/protection` (classic branch protection) — 200

What does NOT work:
- `PATCH /repos/.../rulesets/{id}` — 404
- `PATCH /repos/.../rulesets/{id}` with `-f enforcement=active` (minimal field) — 404
- Direct curl with the same token — 404

## Resolution paths

1. **Classic branch protection** — use `PUT /branches/{branch}/protection` instead of rulesets. Matches the [[project-classic-branch-protection-convention]] for this org.
2. **Fine-grained PAT** with `Administration: Read and write` — `export GH_TOKEN=github_pat_...` overrides gh's OAuth token.
3. **Web UI** — `https://github.com/{owner}/{repo}/settings/rules/{id}` edits work via session cookie.

## How to apply

When asked to modify rulesets via `gh`: check `gh auth status` for `gho_` prefix; if so, propose path (1) or (3) up front rather than diagnosing the 404 from scratch. PATCH/PUT on classic branch protection endpoints is unaffected.

Reference: issue #3 close comment captured the full diagnostic trace (curl + headers).
