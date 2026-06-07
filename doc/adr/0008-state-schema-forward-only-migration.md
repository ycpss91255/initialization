# ADR-0008: state.json forward-only migration with backup

- **Status:** Accepted
- **Date:** 2026-05-20

## Context

`${XDG_STATE_HOME}/init_ubuntu/state.json` carries a `version` SemVer field
(PRD §10.1). The tool itself ships SemVer releases (`v0.1` → `v0.2` → ...).
On upgrade the schema can change shape (new fields, renamed fields, enum
widening). Policy for what happens when an older tool version meets a
newer state — or vice versa — was undefined.

## Decision

**Forward-only migration with mandatory backup.**

On every `setup_ubuntu` startup that reads `state.json`:

1. Parse `state.json.version`.
2. If `version` is unknown (not in the migration chain registry):
   - Refuse to read. Exit code 1 with message:
     `"state.json was written by an unknown tool version "X.Y.Z". No
     migration path to current "A.B.C". Restore an older
     state.json.v*.bak or rm state.json (loses install tracking)."`
3. If `version < current_tool_state_schema_version`:
   1. Copy `state.json` → `state.json.v<old-full-semver>.bak`
      (refuse to proceed if the backup write fails — exit code 1).
      Also update `state.json.bak.latest` symlink → newest `.bak`.
   2. Run the registered migration chain `migrate_<from>_to_<to>()` in
      order, inside a sub-shell. Each step is idempotent and operates
      on a parsed jq/json structure in memory, not on the file
      directly.
   3. If any step fails (`return 1`), abort the whole migration: do
      NOT write `state.json`. Original `.bak` remains. Exit code 1
      with the failed step name in the message + log.
   4. Atomically rewrite `state.json` via tmp-file + rename (POSIX
      `rename(2)` atomic on same filesystem; `${XDG_STATE_HOME}/init_ubuntu/`
      is one fs):

      ```bash
      tmp="${state_path}.tmp.$$"
      printf '%s\n' "${migrated_payload}" > "${tmp}"
      mv -f "${tmp}" "${state_path}"
      ```

4. If `version > current_tool_state_schema_version`:
   - Refuse to read. Exit code 1 with message "state.json was written
     by a newer tool; downgrade is not supported — `git checkout` the
     matching tool version or restore an older `.bak`."
5. If `version == current`: no-op.

Migration functions live in `lib/state_migrate.sh`, one function per
hop, named exactly `migrate_<from>_to_<to>()` with `<from>` / `<to>`
being underscore-encoded SemVer (`0_1_0`, `0_2_0`). Engine composes the
chain from a static array.

The `.bak` file is **never auto-deleted**; user prunes manually.

## Alternatives considered

- **Backward-read, forward-write.** Tool reads any older version
  in-place, normalising missing fields on load. Rejected: read path
  grows a branch per historical version; lint debt accumulates
  indefinitely; ambiguous which on-disk shape is "current".
- **Explicit `setup_ubuntu migrate` subcommand.** User must run it
  before any other command works. Rejected: violates G1 "one command"
  ergonomics; extra step traps fresh-machine users post-`self-upgrade`.
- **Reject + force export/import.** Rejected: state.json is a
  cross-machine asset (§16 sync); tools must not strand it.

## Consequences

- One-shot migration keeps every read path looking only at the current
  schema. Migration code is append-only.
- Backups accumulate over many upgrades. Acceptable — `state.json` is
  small (~kB per module).
- Downgrade is explicitly unsupported. User must restore the matching
  `.bak`.
- AC additions (PRD §11):
  - **AC-30 (v0.2+):** After tool self-upgrade, `state.json.v<old>.bak`
    exists with the pre-upgrade content byte-for-byte.
  - **AC-31:** Reading a newer-than-tool state.json exits code 1
    without modifying the file.
