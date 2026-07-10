# CI core-shard partition is time-weighted greedy-LPT over a committed, self-maintaining weights file

- **Status:** Accepted
- **Relates to:** issue #226 (core sub-shard matrix), issue #28 (sharded
  coverage PR gate + AC-17 merged gate), `doc/adr/0004-tests-must-run-in-docker-only.md`
- **References:** ycpss91255-docker/base ADR-00000017 (CI throughput ceiling
  and the shard/runner strategy) and its ADR-00000008 (sharded coverage PR
  gate) — the greedy-LPT + dynamic-shard-count pattern is ported from there.

## Context

The core (non-module) unit specs run under kcov as a parallel matrix
(`test-unit-core`, issue #226). Until now `ci.sh --module core-<N>`
partitioned the sorted core spec list by **count round-robin** into a
**hardcoded `CORE_SHARD_COUNT=4`**: shard `i` got every spec whose index was
`i mod 4`.

Round-robin balances the *number of specs* per shard to within one, but not
their *runtime*. A handful of specs dominate (`dispatcher_spec` ~122 `@test`,
`tui_backend_spec` ~104, `module_helper_spec` ~84, `secrets_spec` ~77), so the
CI performance audit measured the four core kcov shards at **~96-121 s each**
while the 39 per-module shards ran **~23-41 s**. The core shards were the long
pole after lint — a `~30 %` spread driven purely by which heavy specs happened
to land together.

The sibling repo `ycpss91255-docker/base` had already hit and solved this:
a time-weighted greedy-LPT (Longest Processing Time) partition fed by a
self-maintaining per-spec timings cache, plus a dynamic shard count derived
from a single repo variable (base ADR-00000017).

## Decision

**1. Replace count round-robin with time-weighted greedy-LPT.**
`script/ci/shard_partition.sh` sorts specs heaviest-first (ties broken by path
for determinism) and assigns each to the currently-lightest shard. The busiest
shard's wall time then approaches `total / N` instead of the round-robin
floor. With the committed weights and `N = 8`, the eight core shards balance to
**~52-57 s each** (verified in `test/unit/script/shard_partition_spec.bats`),
versus the audited 96-121 s.

The partition is a standalone, unit-tested script (stdin spec list → assigned
subset for shard `<index>` of `<count>`), so `ci.sh` and the test suite drive
the identical algorithm.

**2. Weights live in a COMMITTED, self-maintaining file — never a CI-only
cache.** `test/ci-shard-weights.tsv` holds `<seconds> <basename>` lines. It is
seeded from the audit's core total proportional to each spec's `@test` count,
and refreshed from REAL bats junit timings by
`just -f justfile.ci shard-weights-refresh` (which runs the core specs under
bats junit in the test-tools image, then folds the measured seconds in via
`script/ci/junit_to_weights.sh`). A spec absent from the file falls back to a
default weight inside `shard_partition.sh`, so a brand-new spec is still
partitioned proportionally until its real time is recorded.

This adapts base ADR-00000017's **no-CI-only-cache / reproducibility
principle**: base restores its weights from an Actions cache, but its governing
rule is that every CI run must be clean and reproducible from the repo. We take
that one step further here — the weights are **committed**, so the partition is
byte-for-byte reproducible locally and in CI with no cache dependency at all.
Refreshing is a data-only change (run the recipe, commit the diff); no code
changes to rebalance.

**3. Shard count is dynamic, driven by a single knob.** The hardcoded
`CORE_SHARD_COUNT=4` and the literal `core-shard: ['0','1','2','3']` matrix are
gone. `.github/workflows/ci.yaml`'s `discover` job derives the count from
`vars.CI_CORE_SHARDS` (**default 8**), emitting a 0-based index array the
`test-unit-core` matrix consumes via `fromJSON`, and the matching total as
`CORE_SHARD_COUNT`. Eight is the audit's suggested starting point for the core
kcov floor; it stays well under the org's 20-job concurrency cap alongside the
per-module matrix. Bumping the repo variable rebalances without editing the
workflow (base ADR-00000017's single-knob decision).

## Consequences

- The core shards stop being the long pole: the slowest core shard drops from
  ~121 s to ~57 s at `N = 8`.
- **Invariants preserved.** `shard_partition.sh` assigns every spec to exactly
  one shard, so the union over `0..N-1` is the whole core set with no overlap —
  the coverage-merge denominator and the AC-17 80 % merged gate (issue #28) are
  unchanged. Doc-only skip and concurrency keying are untouched.
- New specs need no manual weight entry (fallback covers them); a periodic
  `shard-weights-refresh` keeps the partition sharp. The weights test guards
  against stale entries (a weight for a deleted spec), not against missing ones.
- The mechanism generalises: raising `vars.CI_CORE_SHARDS` is the only lever
  needed if the core suite grows, up to the concurrency budget.

## Alternatives considered

- **Keep round-robin, just raise the shard count.** Rejected: more shards make
  round-robin *less* balanced per shard in relative terms when a single spec
  still pins one shard; time-weighting is what removes the spread.
- **Weights only in the Actions cache (base's exact mechanism).** Rejected for
  this repo: a committed file is strictly more reproducible (no first-run/cache-
  eviction fallback to count) and matches the repo's "one committed source of
  truth" habit. The refresh recipe keeps it current.
- **Fold module specs into the same LPT pool.** Out of scope: modules already
  run as their own fast (~23-41 s) matrix; the long pole was the core pool.
