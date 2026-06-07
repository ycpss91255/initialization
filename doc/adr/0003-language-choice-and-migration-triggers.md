# Stay on bash for v0.x; migration triggers for v0.3+

We chose bash for the implementation language because (a) the tool installs
its own dependencies — requiring Python/Go/Rust to be pre-installed creates a
chicken-and-egg bootstrap problem, (b) most module logic is shell command
orchestration (`apt-get`, `curl`, `tar`, `dpkg`) which is bash's home turf,
and (c) at v0.1 scale (~3000 LOC + ~30 modules, personal use) bash remains
within its comfort zone. We accept the known costs: heavier testing via bats,
no static types, `declare -A`/`local -n` portability edge cases, structured
data leaning on `jq`.

## Considered Options

- **Python (click + rich + pydantic)**: better testing story (pytest), real
  types, easy structured config. Ubuntu ships `python3` so bootstrap is fine.
  Rejected for v0.x because the migration cost is high (~3000 LOC + 239 tests
  + docs) and we have not yet hit bash's real limits.
- **Go (cobra + bubbletea)**: single static binary, no runtime dependency,
  great for distribution. Rejected because we don't distribute and would have
  to maintain a release pipeline for a personal-use tool.
- **Rust (clap + ratatui)**: same wins as Go but with steeper learning curve
  and slower compile times. Same rejection.

## Migration triggers (do migrate to Python when ANY of these become true)

1. **Engine surface area** — `lib/dispatcher.sh` exceeds ~1000 LOC, or the
   engine layer collectively exceeds ~5000 LOC.
2. **State complexity** — `state.json` schema operations have outgrown
   `jq` + bash. Specifically: cross-field invariants checked at every read,
   migration logic that needs algorithms more than a transform pipeline
   can express (loops, lookups across records, conditional rewrites with
   memory). ADR-0008 introduced forward-only migration via
   `migrate_<from>_to_<to>()` functions in `lib/state_migrate.sh`; each
   step uses `jq` for shape transforms and stays within bash's
   comfort zone. That alone does **not** fire this trigger. The trigger
   fires when *individual* migration steps require non-trivial logic
   beyond what `jq` + simple bash can express cleanly.
3. **TUI scope** — needs scrollable tables, async loading, real-time progress
   bars (bash + `dialog` cannot support this well).
4. **Test pain** — CI run time exceeds ~5 minutes for unit tests, or
   maintaining bats specs becomes the bottleneck on shipping features.
5. **Plugin market** — third-party modules with their own dependencies,
   sandboxing, signature verification.

When any of these fire: keep modules in bash (they're shell-command wrappers
where bash is correct), migrate the engine (`lib/*.sh`) to Python. Module
helpers stay accessible via `subprocess.run`.

## Migration trigger to Go (v1.x+)

Only if we decide to publish the tool for non-personal use and want a
single static binary. Not anticipated.

## Consequences

- Accept current testing overhead as the cost of bash.
- Do not pre-emptively introduce abstractions for "future Python migration"
  — that's speculative generality and we'll redo it anyway during migration.
- Keep `lib/*.sh` modular and well-tested so a migration is a layer swap,
  not an archaeology project.
