# ADR-0018: state.json splits synced and local fields

- **Status:** Accepted (amended 2026-06-07 — see [Amendment](#amendment-2026-06-07-export-payload-is-synced-only))
- **Date:** 2026-05-20
- **Related:** ADR-0011 (apt-essentials freeze), ADR-0013 (sync conflict),
  ADR-0017 (user-home install layout)

## Context

Several fields in `state.json.installed.<m>` are environment-specific
and should not propagate across machines:

- `frozen_pkgs` / `frozen_platform` (apt-essentials, ADR-0011) — the
  pkg set this host actually installed.
- `install_target_resolved` (`sudo` vs `user-home`) — whether the
  install went through apt or user-home unpack on this host.
- Any future field describing local snapshots (e.g. recovery
  snapshot path, locally chosen mirror).

Sync / import / export of state.json across machines should carry
machine-portable facts only ("what's installed and which version"),
and let the receiver's engine re-resolve everything else from its
own environment.

Without an explicit split, sync (ADR-0013 "remote wins on version")
would clobber local-only fields with remote values, breaking the
receiver's setup.

## Decision

Restructure `state.json.installed.<m>` into two sub-objects:
`synced` and `local`.

### Shape

```json
"installed": {
  "neovim": {
    "synced": {
      "manual": true,
      "depends_on": ["fzf", "lazygit", "ripgrep", "fdfind", "fnm"],
      "version_provided": "v0.10.2",
      "installed_at": "2026-05-13T14:25:01+08:00",
      "installed_by": "init_ubuntu@v0.1.0"
    },
    "local": {
      "install_target_resolved": "user-home",
      "user_home_root": "/home/cyc/.local/lib/init_ubuntu/neovim"
    }
  },
  "apt-essentials": {
    "synced": {
      "manual": true,
      "depends_on": [],
      "version_provided": "apt-managed",
      "installed_at": "2026-05-13T14:20:11+08:00",
      "installed_by": "init_ubuntu@v0.1.0"
    },
    "local": {
      "frozen_pkgs": ["git", "vim", "..."],
      "frozen_platform": "desktop"
    }
  }
}
```

### Field assignment rule

A field belongs in `synced` if it answers "**what** is installed"
in a machine-portable way. It belongs in `local` if it answers
"**how / where** it landed on this machine".

| Field | Section |
|---|---|
| `manual` | synced |
| `depends_on` | synced |
| `version_provided` | synced |
| `installed_at` | synced |
| `installed_by` | synced |
| `install_target_resolved` | local |
| `user_home_root` | local |
| `frozen_pkgs` (apt-essentials) | local |
| `frozen_platform` (apt-essentials) | local |

### Sync / import / export semantics

- **Export** writes `synced` only — the same payload shape as sync
  over the wire; the `local` half never leaves the host on any path.
  *(Amended 2026-06-07; the original decision had export carry both
  halves for backup/audit — see Amendment.)*
- **Import** reads `synced` from the file, then for each module
  invokes the local install pipeline. The local install
  (re-)derives `local` fields from the current environment. Result:
  same "what is installed" (per `synced`), correct "how" (per local
  reality).
- **Sync push / pull** transmits `synced` only over the wire. The
  receiver's install pipeline produces `local` fields locally.

### Migration (ADR-0008)

Pre-ADR state.json had a flat shape. The `migrate_<old>_to_<new>`
function moves existing fields into `synced` and creates empty
`local: {}` (or backfills `frozen_*` / `install_target_resolved`
when detectable from filesystem inspection — best-effort).

## Alternatives considered

- **Per-field "local-only" annotation list.** Maintain an array
  somewhere of "these field names are local". Rejected: implicit
  knowledge; new code paths forget to consult the list.
- **Two separate files: state.json + state.local.json.** Rejected:
  invariants between them (every installed.<m> must appear in both)
  are easier to violate; one consistent file is simpler.
- **Sync transmits everything, receiver post-processes to fix
  local fields.** Rejected: receiver must know which fields to
  re-derive — same as the implicit annotation problem.

## Consequences

- `state.json.installed.<m>` is one level deeper. Every consumer
  (engine, `list`, `sync`, `doctor`) reads from the right sub-object.
- Sync conflict resolution (ADR-0013) simplifies: only `synced`
  fields participate in conflict logic; `local` is never compared
  across peers.
- Import / export between machines with different install-target
  capabilities works: a `sudo` machine's export installs cleanly
  onto a user-home-only machine without mismatched paths.
- AC additions:
  - **AC-56:** Export of state.json on machine A and import on
    machine B (no sudo) reinstalls all modules via user-home and
    `local.install_target_resolved = "user-home"` on B even though
    A had `"sudo"`.
  - **AC-57:** Sync pull from a remote with
    `apt-essentials.local.frozen_pkgs = [..., systemd-container]`
    onto a local machine where that pkg isn't installable causes
    the local install pipeline to apply its own compat filter; the
    remote's `local` section is never copied verbatim.

## Amendment (2026-06-07): export payload is synced-only

- **Trigger:** issue #95, aligning this ADR with the merged
  implementation of issue #43 (PR #92).

**What changed.** As originally written, the "Sync / import / export
semantics" section had **export** write the full structure (both
`synced` and `local`) so the output file could double as a
backup/audit artifact, while sync transmitted `synced` only. The
implementation that shipped (issue #43's acceptance criteria, PR #92)
uses one uniform payload shape instead: **export, import, and sync
all carry `synced` only**, and the receiver always rebuilds `local`
via its own install pipeline. The Decision section above has been
updated in place to match; this amendment records the original
wording and the reason for the change.

**Why.** A payload that sometimes contains `local` (export file) and
sometimes does not (sync wire) reintroduces exactly the problem this
ADR rejected under Alternatives: every consumer of a payload must
know which fields to ignore or re-derive. One payload shape means
one import code path — `import` never has to decide whether a
`local` section is trustworthy, because a well-formed payload never
has one (and a hostile payload's `local` section is ignored, which
PR #92 covers with a test).

**Backup is out of scope.** The export payload is a transport
format, not a backup format. Losing `local` on export is acceptable
because every `local` field is re-derivable from the receiving
environment by definition (that is what makes it `local`). If a
full-fidelity backup of state.json (including `local`) is ever
wanted, that is a new decision — e.g. a dedicated `state backup`
verb with its own ADR — not an extension of this one.
