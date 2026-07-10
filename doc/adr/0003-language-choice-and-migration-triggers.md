# Stay on bash for v0.x; migration triggers for v0.3+

> **Update / recalibration (2026-07).** The original numeric trigger
> "engine layer collectively exceeds ~5000 LOC" has now been **crossed** —
> `lib/*.sh` is roughly **5900-6100 code lines**. The maintainer
> **consciously chooses to stay on bash** regardless. Raw LOC turned out to
> be a poor proxy: the engine grew because more modules and more tests were
> added, not because bash started fighting back. The numeric triggers below
> are therefore **replaced with qualitative ones** (see the recalibrated
> "Migration triggers" section). The real trigger is when bash's *costs*
> (testing burden, cross-platform portability bugs, structured-data
> handling) exceed the one-time cost of migrating — not when a line counter
> ticks past a round number.

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

**Recalibrated to qualitative signals.** The earlier numeric thresholds
(dispatcher LOC, ~5000-LOC engine, ~5-minute CI) were dropped because raw
size is not what makes bash painful — crossing ~5900-6100 LOC in `lib/*.sh`
changed nothing about maintainability. Migrate when the *cost of staying on
bash* clearly exceeds the *cost of porting*, as signalled by:

1. **Test maintenance becomes unmaintainable** — keeping bats specs green
   (mocking, isolation, coverage) consistently costs more than the features
   they guard, i.e. testing burden dominates the time spent shipping.
2. **Cross-platform bash bugs dominate maintenance time** — recurring
   `declare -A` / `local -n` / word-splitting / quoting portability defects
   across the target boards (x86_64 / rpi4 / rpi5 / jetson) become the
   steady-state work, rather than an occasional edge case.
3. **Structured-data handling via `jq` is the bottleneck** — `state.json`
   operations outgrow `jq` + bash: cross-field invariants checked at every
   read, or migration steps needing real algorithms (loops, cross-record
   lookups, conditional rewrites with memory) rather than a transform
   pipeline. ADR-0008's forward-only `migrate_<from>_to_<to>()` steps in
   `lib/state_migrate.sh` stay within bash's comfort zone and do **not**
   fire this trigger on their own; the trigger fires when *individual*
   steps need non-trivial logic `jq` + simple bash cannot express cleanly.
4. **TUI scope** — needs scrollable tables, async loading, real-time
   progress bars that bash + `dialog`/`fzf`/`whiptail` cannot support well.
5. **Plugin market** — third-party modules with their own dependencies,
   sandboxing, signature verification.

Rationale for the recalibration: a line count is a lagging, noisy proxy —
it grows with healthy additions (modules, tests) that do not increase per-
change friction. What actually justifies a rewrite is *friction per change*:
when testing, portability debugging, or data wrangling in bash costs more
than the migration would. LOC alone does not measure that, so it is no
longer a trigger.

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
