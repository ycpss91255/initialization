# Standalone Mode writes single-module state; Engine Mode writes orchestration state

A Module can run in two modes: `bash module/<m>.module.sh <phase>` (Standalone)
or `setup_ubuntu <phase> <m>` (Engine). We split state-writing along the
"single-Module fact vs cross-Module orchestration" line: **Standalone writes the
Sidecar + prints WARN/POST messages but does NOT touch `state.json` or resolve
DEPENDS_ON; Engine does everything**. This lets Standalone be self-contained
enough to be useful (e.g. sharing one module with another user), while keeping
`state.json` — and its Manual flag, which only makes sense inside a dependency
graph — strictly Engine-managed.

## Considered Options

- **Workshop mode** (Standalone leaves no trace): rejected because `is_outdated`
  needs the Sidecar to compare against latest.
- **Full parity** (Standalone writes `state.json` too): rejected because giving
  someone a single module shouldn't presume init_ubuntu owns their system, and
  the Manual flag is undefined without dep resolution.

## Consequences

- Sidecar write logic lives in module helpers, not in Engine — both modes hit
  the same code path.
- `setup_ubuntu list --installed` may miss Modules installed via Standalone if
  the user never ran `setup_ubuntu import`. This is intentional.
- Future "adopt orphan modules" feature can detect Sidecar without state.json
  entry and offer import.
