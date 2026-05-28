# ADR-0013: sync conflict resolution — dry-run default, union, remote-wins-on-version

- **Status:** Accepted
- **Date:** 2026-05-20

## Context

PRD §16 describes the happy path for `setup_ubuntu sync` (push and
pull). Conflict resolution was undefined. Realistic conflicts on a
multi-machine personal setup:

1. **Version drift.** Both sides installed `docker` but at different
   versions.
2. **One-sided modules.** Remote has `obscure-tool`; local engine has
   no module definition for it (e.g. it was a user-local module in
   `${XDG_CONFIG_HOME}/init_ubuntu/modules/`).
3. **Dep snapshot divergence.** Same `neovim`, but `depends_on`
   snapshots differ because the modules' `DEPENDS_ON` metadata moved
   between installs.
4. **Uncommitted local changes.** User installed `eza` locally; sync
   pull from a machine that doesn't have it must not silently lose
   `eza`.

The tool is single-user, multi-machine (PRD §3.2). Conflicts are
rare. The cost of a wrong silent merge is high (user loses install
work or gets unexpected downgrades).

## Decision

**Dry-run by default. Union of modules. Remote wins on version /
depends_on. `manual` flag is sticky to true.**

### Default flow

```bash
setup_ubuntu sync user@host --pull         # dry-run; prints diff
setup_ubuntu sync user@host --pull --apply # actually mutate
```

`--pull` without `--apply` exits 0 after printing a structured diff;
no state changes.

### Merge rules

For each module M in `union(local.installed, remote.installed)`:

| Case | Local | Remote | Result on `--apply` |
|---|---|---|---|
| Only local | ✓ | ✗ | keep local (union) |
| Only remote, catalog known | ✗ | ✓ | install M with `remote.version_provided`, `remote.depends_on`, `remote.manual` |
| Only remote, no local module def | ✗ | ✓ | skip + warn `"module 'X' not in local catalog; ignored"` |
| Both, same version | ✓ | ✓ | no-op |
| Both, version diff | ✓ v_l | ✓ v_r | upgrade/downgrade to v_r; rewrite `depends_on` from remote |
| `manual` flag: local=true, remote=false | t | f | keep `true` (sticky, ADR-0010) |
| `manual` flag: local=false, remote=true | f | t | flip to `true` |

### Diff output format

JSONL via ADR-0006 logger schema, plus a human summary table on
stdout:

```
PULL DIFF (remote: cyc@laptop)
  + docker         install      v28.0.0  manual=false   depends=[]
  ~ neovim         upgrade      v0.10.2 -> v0.10.5      depends unchanged
  ~ eza            keep         v0.20.0  (local only)
  ! obscure-tool   skip         no local module definition
```

### What `--pull` will NOT do

- Will not delete local-only modules. To uninstall, use
  `setup_ubuntu purge <m>`. Sync is not a cleanup tool.
- Will not transfer secrets, ssh keys, or any `setup_secrets` data
  (PRD §16.4).
- Will not auto-resolve catalog mismatches. User must add the
  missing module definition first.
- Will not copy module files (`.module.sh`) by default.
  `--include-user-local-modules` opts in for user-local module
  files (see below).

### `--include-user-local-modules` (opt-in)

When the remote state references modules that don't exist in the
local catalog, the dry-run diff prints:

```
! myrust   skip   no local module definition
... 1 module not in local catalog.
    Add --include-user-local-modules to also pull user-local
    module files from <remote>.
```

With `--include-user-local-modules`, sync additionally rsyncs
`${XDG_CONFIG_HOME}/init_ubuntu/modules/` from remote to local.
**Repo-tracked modules (`./modules/*.module.sh`) are never
transferred over sync** — those belong in git and should be moved
via `git pull` / `git push`.

This is opt-in because user-local modules are executable code; an
automatic transfer would let a compromised peer push code to the
other side. The flag carries a dry-run warning:

```
WARNING: --include-user-local-modules copies executable scripts
from <user@host>. Verify trust before --apply.
```

`--apply` without the flag does not copy any module files.

### `--apply` exit semantics

Acts like a batched install/upgrade pipeline:
- Each affected module runs through the normal `install` /
  `upgrade` lifecycle (so all ACs about idempotency and failure
  reporting still hold).
- Partial failure → exit code 6 (PRD §7.4).

### Push semantics

`setup_ubuntu sync user@host` (push, no `--pull`) inverts the
direction. On the remote, the same merge rules apply with sides
swapped. Push also defaults to dry-run on the remote side; remote
prints a diff back, user re-runs with `--apply`.

## Alternatives considered

- **Remote completely overwrites local.** Rejected: lossy for any
  local-only install (case 4). Personal tool — losing work is the
  worst failure mode.
- **Three-way merge with common ancestor.** Rejected: requires
  storing the previous-sync state per peer; complexity unjustified
  for a 30-module personal-use tool.
- **Interactive prompt per conflict.** Rejected: when a user types
  `sync`, they want to know what will happen, not engage in a
  20-question Q&A. Dry-run + diff serves the same purpose without
  blocking.

## Consequences

- `--apply` is a deliberate two-step that mirrors `git pull --rebase
  --autostash` — show, then commit. Users who want yolo mode use
  `--apply -y`.
- Catalog drift across machines is surfaced explicitly. A user can
  copy missing module defs over via `rsync modules/`, then re-sync.
- `manual` sticky-to-true means a module manually installed on
  either side stays manual everywhere. Aligns with apt-mark.
- AC additions:
  - **AC-40:** `sync --pull` without `--apply` does not change
    `state.json` and exits 0.
  - **AC-41:** `sync --pull --apply` with version diff upgrades the
    local module; state.json shows remote's `version_provided` and
    `depends_on`.
  - **AC-42:** `sync --pull --apply` of a remote `manual=false`
    where local is `manual=true` keeps local `manual=true`.
