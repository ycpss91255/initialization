# ADR-0010: orphan removal via forward-dep snapshot + scan

- **Status:** Accepted
- **Date:** 2026-05-20

## Context

PRD §13.1 Q10 decided `purge` / `remove --with-orphans` only removes
deps that are no longer required by other installed modules — but
left the algorithm and the supporting state shape undefined.

Two candidate state representations exist:

- **Reverse-dep maintained:** each `state.installed.<m>` carries a
  `dependents_of` list; engine updates it on every `install` / `remove`.
- **Forward-dep snapshot:** each `state.installed.<m>` carries the
  snapshot of `DEPENDS_ON` taken at install time. Orphan check at
  remove time scans all other modules' lists.

## Decision

**Forward-dep snapshot.** Mirrors `apt-mark auto/manual`.

### State shape

```json
{
  "installed": {
    "neovim": {
      "version_provided": "v0.10.2",
      "installed_at": "2026-05-13T14:25:01+08:00",
      "manual": true,
      "depends_on": ["fzf", "lazygit", "ripgrep", "fdfind", "fnm"]
    },
    "fzf": {
      "version_provided": "v0.50.0",
      "installed_at": "2026-05-13T14:20:11+08:00",
      "manual": false,
      "depends_on": []
    }
  }
}
```

`depends_on` is the **snapshot** of `DEPENDS_ON` from the module's
metadata at install time. Engine writes it. Standalone mode does not
(ADR-0001 — standalone never touches state.json).

`dependents_of` from the previous PRD draft is **removed**. Reverse
queries are computed on demand from the forward-dep snapshots.

### `manual` semantics

- `true` — user named the module explicitly on a CLI / TUI install.
- `false` — engine pulled it in as a transitive dep.

**Sticky-to-true rule:** once set to `true`, never auto-flip back.
Only `remove` / `purge` drops the record entirely.

#### Manual flag transition table

| Operation | manual before | manual after |
|---|---|---|
| `install X` (explicit) | absent | `true` |
| `install X` (explicit), X was `false` (dep) | `false` | **flip to `true`** |
| `install X` (explicit), X was `true` | `true` | `true` (no-op) |
| `install Y` pulled X as dep, X absent | absent | `false` |
| `install Y` pulled X as dep, X was `false` | `false` | `false` |
| `install Y` pulled X as dep, X was `true` | `true` | `true` (sticky) |
| `install X --no-deps`, X absent | absent | `true` (X explicit) |
| `remove X` / `purge X` | any | (record removed) |

### `depends_on` semantics

`depends_on` records the **actual dep set installed in the same
session**, not the static metadata `DEPENDS_ON`.

| Operation | depends_on snapshot |
|---|---|
| `install X` (full deps) | every dep actually installed (transitively or skipped-already-present) |
| `install X --no-deps` | `[]` |
| `install X` (some deps fail, others succeed) | the deps that succeeded (or N/A — see ADR-0015: parent install fails so X isn't in state at all) |

This means `setup_ubuntu install neovim --no-deps` writes
`neovim.depends_on = []` even though metadata `DEPENDS_ON =
["fzf", "lazygit", ...]`. The snapshot reflects reality, not
intent.

`doctor` warns when `state.installed.<m>.depends_on` is a strict
subset of `metadata.DEPENDS_ON` — surfaces the `--no-deps` install
to the user later.

### Orphan algorithm

```
purge_with_orphans(targets):
  to_remove = set(targets)
  loop:
    new_orphans = {}
    for each M in state.installed where M not in to_remove:
      if M.manual == true:
        continue
      living_dependents = { M' in state.installed - to_remove
                             : M in M'.depends_on }
      if living_dependents == {}:
        new_orphans += M
    if new_orphans == {}:
      break
    to_remove += new_orphans

  for M in topo_sort_reverse(to_remove, edges=depends_on):
    M.purge()           # or M.remove() for `remove --with-orphans`
  remove to_remove from state.json
```

### Key invariants

1. **Iterative.** Removing an orphan can produce new orphans. Loop
   to fixed point.
2. **Topo-reverse.** Purge leaves first, roots last. Use
   `depends_on` snapshots as the edge set.
3. **Manual is sticky.** A `manual=true` module is never an orphan
   candidate, even if no one depends on it.
4. **Standalone irrelevant.** Standalone mode does not write
   state.json (ADR-0001), so `depends_on` and `manual` only have
   meaning in engine mode.

### Migration

State files written before this ADR have no `depends_on` field.
ADR-0008 migration step `migrate_<old>_to_<new>` backfills it from
each module's current metadata `DEPENDS_ON`. This is a best-effort
reconstruction — if metadata has drifted since install, the snapshot
may be wrong; user can rebuild with `setup_ubuntu doctor --fix`
(v1.x).

## Alternatives considered

- **Reverse-dep maintained (`dependents_of` per module).** Rejected:
  requires updating two records on every `install` / `remove`
  (the module itself + every dep). Doubles the write surface and the
  chance of inconsistency. No query-time benefit at our scale
  (30 modules — O(n²) scan is microseconds).
- **No `--with-orphans` support, manual cleanup only.** Rejected:
  PRD §13.1 Q10 already committed to the flag; removing it now
  changes the apt-aligned UX (`apt autoremove` exists).
- **Adopt `apt-mark` directly via shelling out.** Rejected: apt-mark
  only tracks dpkg packages; modules include GitHub-release binaries
  and config drops that apt doesn't know about.

## Consequences

- One write path: install writes `manual` + `depends_on`; remove
  deletes the record. No reverse-dep bookkeeping.
- Orphan check is O(n × max-dep-list); for n=30 and max ~7 deps that's
  ~210 comparisons. Negligible.
- The `depends_on` snapshot drifts from metadata over time (module
  authors change `DEPENDS_ON` between releases). Acceptable: the
  snapshot reflects *what was actually installed*, which is the
  question orphan-detection asks. `doctor --fix` (v1.x) can re-sync.
- AC additions:
  - **AC-33:** `setup_ubuntu install neovim` writes
    `state.installed.neovim.depends_on` = current `DEPENDS_ON`.
  - **AC-34:** `setup_ubuntu purge neovim --with-orphans` removes
    `fzf` (no other dependent, `manual=false`) but keeps `fish`
    (`manual=true`).
  - **AC-35:** Purge order in AC-34 is `neovim → fzf → ...` (leaf
    first per topo-reverse).
