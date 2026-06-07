# ADR-0015: verify failure equals install failure for state.json

- **Status:** Accepted
- **Date:** 2026-05-20
- **Supersedes part of:** PRD §13.2 Q15 ("verify 失敗 → log warn 但
  state.json 照記 installed")

## Context

Two overlapping rules emerged from grilling:

- **Partial install policy (this session, Q1):** failure during
  `install()` means the module is absent from `state.json.installed`.
- **PRD §13.2 Q15:** `install` auto-runs `verify`. If `verify`
  fails, the original wording was "log warn but state.json still
  records installed".

These conflict. If verify failure leaves the module in `installed`
with a warn-only marker, downstream consumers (`list --installed`,
`doctor`, `sync`) must filter on a status field that doesn't
otherwise exist. Adds three-state where two suffice.

Verify exists to catch the case where `install()` thought it
succeeded but the user-facing artefact isn't actually usable
(binary missing from PATH, broken symlink, packaged but no daemon).
It is part of the install pipeline, not an optional after-step.

## Decision

`verify` failure during the auto-install chain is treated as
install failure. `state.json.installed.<m>` is not written. Exit
code 6 (partial failure).

### Auto-install pipeline (one transaction)

```
trace_id = new_uuid
emit install_start
run install()
if install exit != 0:
  emit install_failed
  exit 6
run verify()
if verify exit != 0:
  emit verify_failed (severity: ERROR)
  emit cleanup_start
  run purge()                              # auto-rollback via existing lifecycle
  if purge exit != 0:
    emit cleanup_failed (severity: ERROR,
                         attributes.message: "manual cleanup required")
  else:
    emit cleanup_done
  emit install_failed (rolled-up, attributes.cause: "verify_failed")
  exit 6
write state.json.installed.<m>
emit install_done
```

Both `install()` and `verify()` must succeed before the state is
written. Either failure produces the same observable outcome:
module absent from state, exit code 6, structured failure event in
the log.

### Side-effect rollback on verify failure

`install()` may have produced side effects before verify ran (apt
repo entries, binaries in `/opt`, symlinks, config files). These
must not become orphans.

Resolution: on verify failure, the pipeline **automatically calls
the module's `purge()`** to undo the install. This works because:

- `purge()` is mandatory (ADR-0002, 10-lifecycle contract).
- `purge()` is idempotent (PRD §5.1 G3).
- `purge()` is the canonical "remove everything this module
  installed" verb — exactly what's needed here.

No new mechanism (no rollback registry, no partial-state flag).
The contract already covers it.

If `purge()` itself fails, the pipeline emits `cleanup_failed` with
a clear "manual cleanup required" message pointing at the failing
step. state.json still does not record the module (preserving the
two-state invariant). User runs `setup_ubuntu purge <name>` to
retry manually, or investigates the module's purge() for a bug.

### What about transient verify failures?

The case "binary really is installed but verify saw a stale shell
PATH" exists. Policy:

- Hint emitted on `verify_failed`:
  `"verify failed; if you suspect stale PATH, open a new shell and
  run: setup_ubuntu install <name>"`
- `install` is idempotent (G3, AC-5). Re-running in a fresh shell
  re-invokes `install()` (which detects already-installed and
  skips), then re-runs `verify()` (which now sees the new PATH).
  On success, state.json is finally written.

This means a flaky verify costs the user one re-run, not silent
state inconsistency.

### Manual `verify` invocation

`setup_ubuntu verify <m>` (standalone, post-install) is a separate
flow. It reports pass/fail but does **not** mutate state. Verifying
an already-installed module that suddenly fails verify does not
remove it from state — that's `doctor` territory.

## Alternatives considered

- **Keep PRD §13.2 Q15 wording (warn-only).** Rejected: introduces
  a third state ("installed but unverified") that every state
  reader must handle.
- **Mark as `verify_failed: true` on the state record.** Rejected:
  same problem, plus the recovery path is muddled — does
  `setup_ubuntu install <m>` retry? Auto-purge?
- **Skip verify in the auto chain; verify only on user request.**
  Rejected: defeats the point of catching install bugs early. AC-22
  / AC-24 imply verify must run automatically.

## Consequences

- One clean state predicate: `M in state.installed` iff install +
  verify both succeeded. No status flag.
- Module authors must write `verify()` carefully — flaky verify =
  flaky installs from the user's perspective. `TEST_VERIFY_CMD`
  default should be a fast, deterministic check (`docker --version`,
  not `docker run hello-world`).
- AC additions:
  - **AC-45:** When `install()` succeeds but `TEST_VERIFY_CMD` fails,
    `setup_ubuntu install <m>` exits 6 and `state.installed.<m>`
    does not exist.
  - **AC-46:** The verify-failure log event includes `trace_id`
    matching the `install_start` event from the same session
    (ADR-0006).
  - **AC-47:** On verify failure, the module's `purge()` is invoked
    automatically; apt repo entries, /opt directories, and symlinks
    that `install()` created are all gone after exit. The log shows
    `cleanup_start` → `cleanup_done` events.
  - **AC-48:** If automatic `purge()` itself fails, the log emits a
    `cleanup_failed` event with a path-pointing message, exit code
    is still 6, and `state.installed.<m>` does not exist.
