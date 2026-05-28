# ADR-0019: `list --json` schema for agent consumption

- **Status:** Accepted
- **Date:** 2026-05-21

## Context

PRD §7.2 lists `--json` on the `list` subcommand but does not
specify the output schema. AI agents (`claude-code`, `codex`,
`gemini`) consume `list --json` to answer questions like "what's
installed?", "what's outdated?", "is X available?".

Without a stable schema, agents and downstream scripts must
re-derive shape from prose, leading to flaky parsing.

`list` accepts a primary scope flag (`--available` / `--installed` /
`--upgradable`) and secondary filters (`--category=X`, `--tag=X`).
The JSON must express both, plus a unified per-module record shape.

## Decision

### Top-level shape

```json
{
  "schema_version": "1",
  "scope": "installed",
  "filters": {
    "category": null,
    "tag": null
  },
  "items": [ /* per-module records */ ],
  "count": 12,
  "generated_at": "2026-05-21T09:33:00+08:00"
}
```

| Field | Type | Notes |
|---|---|---|
| `schema_version` | string | "1" until breaking change; bump on rename/removal |
| `scope` | `"available"` \| `"installed"` \| `"upgradable"` | Mirrors primary flag; defaults to `"available"` when no flag given |
| `filters` | object | `null` per slot when filter not applied |
| `items[]` | array | Filtered module records |
| `count` | number | `items.length` (redundant for jq convenience) |
| `generated_at` | ISO 8601 | Generation timestamp for cache logic |

### Per-module item shape

```json
{
  "name": "neovim",
  "category": "recommended",
  "tags": ["editor"],
  "description": "Neovim editor with nvimdots config",
  "version_provided": "v0.10.2",
  "installed": true,
  "outdated": false,
  "manual": true,
  "depends_on": ["fzf", "lazygit", "ripgrep", "fdfind", "fnm"],
  "supports_user_home": true,
  "supported_platforms": ["desktop", "server", "wsl", "rpi-5", "jetson-orin"],
  "supported_ubuntu": ["22.04", "24.04", "26.04"],
  "risk_level": "low",
  "reboot_required": false,
  "homepage": "https://neovim.io/"
}
```

| Field | Type | When |
|---|---|---|
| `name` | string | always |
| `category` | enum | always (from metadata) |
| `tags` | string[] | always (from metadata `TAGS`) |
| `description` | string | always; reflects `INIT_UBUNTU_LANG` (fallback `en`) |
| `version_provided` | string | always (from metadata) |
| `installed` | boolean | always |
| `outdated` | boolean \| null | `null` if `installed=false` |
| `manual` | boolean \| null | `null` if `installed=false` |
| `depends_on` | string[] \| null | `null` if `installed=false`; from state snapshot otherwise |
| `supports_user_home` | boolean | from metadata `SUPPORTS_USER_HOME` |
| `supported_platforms` | string[] | from metadata `SUPPORTED_PLATFORMS` |
| `supported_ubuntu` | string[] | from metadata `SUPPORTED_UBUNTU` |
| `risk_level` | `"low"` \| `"medium"` \| `"high"` | from metadata |
| `reboot_required` | boolean | from metadata |
| `homepage` | string \| null | from metadata, may be empty |

### Sort order

Default: alphabetical by `name`. Stable across invocations on the
same state.

### Where each field comes from

- Catalog-side (always available from `modules/*.module.sh`
  metadata): `name`, `category`, `tags`, `description`,
  `version_provided`, `supports_user_home`, `supported_platforms`,
  `supported_ubuntu`, `risk_level`, `reboot_required`, `homepage`.
- State-side (only when `installed=true`): `installed`, `outdated`,
  `manual`, `depends_on`.
- Computed (state + catalog): `outdated` (from `is_outdated()` —
  offline by default per ADR-0009; `--online` flag refreshes).

### `--online` interaction

`is_outdated` defaults to offline (Sidecar / `apt list --upgradable`
cached info, ADR-0009). `list --upgradable` / `list --json` with
`--online` refreshes GitHub release cache (TTL 1h per ADR-0017
upgrade flow) before computing `outdated`.

### Stability guarantees

- Field names are case-sensitive snake_case (matches OTel SemConv
  attribute style, ADR-0006).
- Adding new fields is non-breaking. Renaming or removing requires
  `schema_version` bump.
- `null` is used explicitly (never omitted) for fields that don't
  apply to the current scope.

## Alternatives considered

- **Pretty-printed table (no JSON).** Rejected: agent consumption
  motivates this ADR; humans use the default tabular `list`
  without `--json`.
- **Mirror state.json shape (synced/local sub-objects).** Rejected:
  `list --json` is a flattened agent-facing view; the dual-object
  split is a storage concern. Users of `list` don't care which
  fields came from where.
- **OTel-style attributes wrapper (`{attributes: {...}}`).**
  Rejected: ADR-0006 OTel schema is for log events; `list --json`
  is config data, different domain. Flat record is more usable.

## Consequences

- Agents can parse `list --json` with a stable schema across tool
  versions in the same major schema (`schema_version=1`).
- Future fields can be added without breakage; downstream consumers
  can ignore unknown keys.
- `count` redundancy with `items.length` is acceptable — saves one
  `jq length` per call.
- AC additions:
  - **AC-58:** `setup_ubuntu list --json` produces valid JSON
    conforming to this schema (validated by a `jq` selector +
    schema check in CI).
  - **AC-59:** `setup_ubuntu list --installed --json` items all
    have `installed=true`, non-null `manual`, `depends_on`.
  - **AC-60:** `setup_ubuntu list --upgradable --json` items all
    have `outdated=true`.
  - **AC-61:** Adding a new metadata field to a module surfaces as
    a new JSON field; existing fields unchanged (no rename).
