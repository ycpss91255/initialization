# CI Performance Audit

**Date:** 2026-07-04
**Repo:** init_ubuntu (`/home/cyc/Desktop/initialization`)
**Scope:** Wall-clock latency of the GitHub Actions CI graph (`.github/workflows/ci.yaml` + `script/ci/ci.sh`), cross-referenced against the org's shared CI template `ycpss91255-docker/base`.
**Status:** Investigation for discussion. No changes recommended for implementation yet. This audit performed exactly one write (this file) and was otherwise read-only.

---

## Executive summary

init_ubuntu's CI is **structurally well-parallelized** but **gated by a single serial tail**.

- **Current wall-clock:** ~4m41s on the latest main run (`28706884183`, 12:55:09 -> 12:59:49). The previous main run (`28679850412`, 4m17s) confirms this is stable, not a fluke.
- **Parallel efficiency:** ~7x. Aggregate job-compute across the 43+ jobs is ~2000s of CPU-seconds, executed in a 278s critical path. In aggregate the fan-out is excellent.
- **The catch:** the last ~110s of every run is a **single uncontended job** — `lint` — running 100% single-threaded ShellCheck while ~50 runners sit idle. The entire test + coverage graph finishes at 12:57:54; `lint` then runs alone until 12:59:43.
- **The build-once and no-double-run properties are already good** (content-keyed image tags, build-image/build-kcov-image reused everywhere, bats runs once under kcov — no separate test-then-coverage pass). Do not regress these.

Two changes (parallelize ShellCheck + raise the core shard count) plausibly take wall-clock from ~4m41s toward ~2m, because they attack the two long poles in order: first the serial `lint` tail, then the core kcov shards it currently hides.

**Cross-reference note:** `ycpss91255-docker/base` **was reachable** (public repo). It is the org's shared Docker/bash/bats/kcov CI template and has already solved the *next* tier of this problem (time-weighted shard partitioning, self-maintaining timings cache, dynamic shard count, per-file kcov floor, and a documented CI-ceiling ADR). init_ubuntu has already adopted base's build-once and doc-only-skip patterns; the un-adopted deltas are listed below.

---

## Ranked improvements (biggest wall-clock win first)

### 1. Parallelize ShellCheck in the `lint` job — HIGH

- **Problem (`script/ci/ci.sh:199`):** `_find_lintable_sh | xargs -0 shellcheck -x` runs ShellCheck as **one process** over all 197 scripts. No `-P` fan-out. On run `28706884183`, ShellCheck ran 12:56:08.47 -> 12:59:40.69 = **212s** of a 228s `lint` job (fish check = 0 files / <0.1s; hadolint <0.2s).
- **Why it is slow / not parallel:** GitHub runners have ~4 vCPUs; one ShellCheck thread churns while the other three idle. `-x` (source-following) re-parses shared libs per file. The whole test + coverage graph is already done at 12:57:54, so `lint` runs **uncontended** for the final ~110s — nothing overlaps it. This one line sets total CI latency (`lint` is the sole `needs` gate that `ci-passed` waits on late; see `ci.yaml:485`).
- **Proposed change:** replace the single `xargs` at `ci.sh:199` with a CPU-fanned form, e.g. `_find_lintable_sh | xargs -0 -P"$(nproc)" -n 12 shellcheck -x`, or GNU `parallel` (already baked into the test-tools image per `justfile.ci` header). `-x` resolves sourced paths per file, so batching across processes stays correct.
- **Expected speedup:** ~4x on the ShellCheck step -> ShellCheck ~55s, `lint` job ~70s. Because `lint` is the serial tail, this is a near-1:1 wall-clock cut: ~4m41s -> ~2m45s (then bounded by the coverage path).
- **Effort:** Low (one line, plus a bats assertion that lint still fails on a known-bad script).
- **Risk:** Low. Same ShellCheck, same `-x`, same file set; only the process fan-out changes. Only caveat: aggregated exit-code handling across parallel invocations must still fail the job if any batch fails (`xargs` returns 123 on any child failure — verify the `set -uo pipefail` contract in this exit-code-contract script still surfaces it).

### 2. Let `lint` start without the image tar round-trip — HIGH (scheduling)

- **Problem (`ci.yaml:209` — `lint` `needs: build-image`):** `lint` idles ~34s after `build-image` finishes (12:55:34) before ShellCheck begins (12:56:08), waiting on the image artifact upload -> download -> `docker load` round-trip.
- **Why it is slow:** `lint` only needs `shellcheck` + `hadolint` + `fish`, but it pulls the full test-tools tar to get them. That is ~34s of pure setup on the critical path.
- **Proposed change:** run ShellCheck/hadolint/fish from a tiny standalone step (or GHA layer cache / a minimal pinned image) rather than the full test-tools tar. Secondary to #1; only matters once `lint` is no longer 212s.
- **Expected speedup:** ~30s off the `lint` floor after #1 lands.
- **Effort:** Medium (touches how the lint job provisions its toolchain; must keep tool versions pinned/reproducible — see base's "no CI-only cache" principle in the adopt section).
- **Risk:** Medium — provisioning-path change; guard against version drift between lint's toolchain and the rest of CI.

### 3. Raise `CORE_SHARD_COUNT` from 4 to 8 — MEDIUM

- **Problem (`ci.yaml:258` `CORE_SHARD_COUNT: '4'`, matrix `ci.yaml:251` `core-shard: ['0','1','2','3']`; default in `ci.sh:406`):** the 4 `test-unit (core-N)` shards run **96–121s each** (core-1 actual kcov work 96s + ~14s tar download/load), while the 39 per-module shards run 23–41s. kcov forces **serial** bats (`ci.sh:320` comment context), so core specs cannot use parallel bats — the only lever is more shards.
- **Why it is slow:** with `lint` fixed (#1), the core shards + their 21s merge become the **new** critical path (~165s). Today they are hidden behind `lint`. The 4 core shards are well balanced among themselves (105/114/120/121s) via round-robin; the imbalance is core-vs-module, so splitting core further is the direct win.
- **Proposed change:** bump `CORE_SHARD_COUNT` to 8 (`ci.yaml:258` + extend the matrix list `ci.yaml:251`). Round-robin already balances, so 8 shards roughly halves the core path to ~50s.
- **Expected speedup:** core path ~110s -> ~60s (incl. the ~14s tar floor per shard). Combined with #1, targets ~2m total.
- **Effort:** Low (two edits) — but see base finding #758: past ~8 shards the win bottoms out at the largest single spec file (e.g. `tui_flow.bats`, ~105 tests), because kcov runs each file atomically.
- **Risk:** Low-Medium. Runners are abundant, but blindly overshooting the org-wide concurrent-job cap (GitHub Free = 20 concurrent, per base ADR-00000017) makes excess shards queue and pay the fixed pull+startup tax instead of running. 8 core + 39 module + build/integration will exceed 20 concurrent and partially serialize — measure, do not assume linear.

### 4. Reduce the per-job image tar round-trip — LOW

- **Problem:** every heavy job re-`docker load`s the image tar. On core-1: download 8s + load 6s = **~14s floor** before any test work, repeated across 43 shard jobs + coverage + integration (~600s aggregate compute, parallel).
- **Why it is slow:** artifact download + full-tar load is slower than a layer-cached registry pull for large images.
- **Proposed change:** push the content-keyed images to GHCR once in build-image/build-kcov-image and `docker pull` (registry pulls are layer-cached), or use `type=oci` + registry cache.
- **Expected speedup:** shaves part of the ~14s/shard floor; not on the critical path today, so low wall-clock priority.
- **Effort:** Medium. **Risk:** Low-Medium (registry auth/retention, and must preserve the reproducible/no-CI-only-cache principle).

### 5. fish syntax check is a no-op — LOW (correctness, not perf)

- **Problem (`ci.sh:170` `_find_lintable_fish`; log at 12:59:40 reports `checked 0 fish script(s)` — see `ci.sh:219`):** the prune list excludes `module/config`, `module/submodule`, `module/function`, `tool`, `small-tools` — exactly where the **579** `.fish` files live (verified: `find . -name '*.fish' | wc -l` = 579). So `fish -n` lints nothing while appearing green.
- **Why it matters:** zero perf cost, but broken fish syntax ships uncaught despite a passing check.
- **Proposed change:** audit the `_find_lintable_fish` prune list — either point it at the real fish locations or drop the check honestly.
- **Effort:** Low. **Risk:** Low-Medium (turning it on will surface real fish lint failures that must be fixed first; sequence deliberately).

---

## What init_ubuntu should adopt from `ycpss91255-docker/base`

`ycpss91255-docker/base` is reachable (public) and is the org's shared Docker/bash/bats/kcov CI template — same testing stack. It pushed the *same* serial-kcov-on-hosted-runners problem much further. Deltas below map to concrete base issue numbers.

**Already adopted (do NOT re-port):** build-image-once + tar-artifact + `docker load` (base #732/#686 -> init `build-kcov-image`, `ci.yaml:180`); concurrency keyed on PR HEAD SHA + `cancel-in-progress` for PRs (`ci.yaml:40-42`); doc-only classify skip + narrow unit matrix (`select_unit_matrix.sh`); content-keyed image tag (`resolve_kcov_tools_tag.sh`). The real remaining delta is **shard-partitioning intelligence and the per-file floor**, not the image plumbing.

**Adoptable, ranked by base's own sequencing:**

1. **Time-weighted LPT shard partition (HIGH) — base #724 / PR #731, #733.** init round-robins by spec **count** (`_partition_core_specs_for_shard`, `ci.sh:358`) with fixed count 4. base replaced count round-robin with greedy-LPT weighted by **measured per-spec kcov seconds** (count-balanced shards were ~3x time-imbalanced: 271s vs 92s). Port base's `_shard_unit_files` / `_spec_weight`; fall back to @test-count for unseen specs. This is what makes raising the shard count (#3 above) actually pay off instead of hitting diminishing returns.
2. **Self-maintaining shard-weights timings cache (HIGH) — base #733.** Each shard emits per-file seconds (bats junit) as `timings.tsv`; the coverage-merge job aggregates them; **only main pushes** save to `actions/cache` (PR runs restore read-only so PR noise never poisons weights); a miss degrades to the count fallback. init has no timings feedback loop — without one, LPT has nothing to weight by. Reuse init's existing coverage-merge job for the aggregate step.
3. **Dynamic shard count via repo var + `fromJSON` matrix (MEDIUM) — base #725 / PR #729.** A `compute-shards` job reads `vars.CI_SHARDS` (base default 8, clamp 1–12) and emits a JSON array consumed via `fromJSON`. init hardcodes count 4 (`ci.yaml:258`). GitHub-hosted exposes no capacity API, so the count must be a config var; base ADR-00000017 derives N from the 20-concurrent-job org-wide cap. Pair with LPT + timings.
4. **Split god-test-files to lower the per-file kcov floor (MEDIUM) — base #758.** kcov runs each spec **file** atomically, so the largest file is a hard floor on the slowest shard (base: `deploy_spec.bats` 97s). init has god-files like `tui_flow.bats` (~105 tests). After LPT + more shards, init's critical path bottoms out here. Split multi-concern files along real lib boundaries, preserving assertions. Sequence **after** LPT + dynamic count.
5. **A CI-ceiling ADR mirroring base ADR-00000017 (MEDIUM).** base documents: serial unsharded kcov = 522s even on a 32-core box (kcov is serial, sharding is not removable), the 20-job org-wide cap, an irreducible floor, and two principles — (a) CI must match the real `just` docker build flow (no CI-only `cache_from`), (b) every run must be clean/reproducible (no retained state). init has no documented ceiling and risks chasing speedups that cannot beat the kcov/e2e floor. Write a short init ADR measuring its own serial-kcov and e2e poles.

**Verify (LOW) — base #730 union-vs-SUM merge.** base's SUM(covered)/SUM(valid) merge double-counted shared source and drifted the rate DOWN as shard count rose (4 shards 52.9% pass; same suite at 8 shards 42.42% false-fail). init merges via `kcov --merge` (native union, `ci.sh:545`) + the AC-17 gate, so it likely dodges this — **but** confirm the AC-17 gate computes from the single merged report (`coverage/merged`), never from summed per-shard rates, before raising the shard count (#3). Add a shard-count-invariance test.

---

## Already good — do not regress

- **Build-once, reused everywhere.** build-image (22s) / build-kcov-image (16s) are content-keyed, cached (`cache-from/to type=gha`), and skipped downstream via `KCOV_TOOLS_PREBUILT=1`. Not redundant. (`ci.yaml:141-203`.)
- **No test/coverage double-run.** bats runs **once under kcov**; there is no separate plain-test pass then coverage pass. (`ci.yaml` core-shard path; `ci.sh:475`+ merge-and-gate on the merged result.)
- **High aggregate parallelism.** ~7x (≈2000s job-compute in 278s wall). The fan-out design is sound; the problem is one serial tail, not the topology.
- **Balanced core shards.** Round-robin keeps the 4 core shards even among themselves (105/114/120/121s) — the imbalance is core-vs-module, addressed by #3, not a within-core defect.
- **Concurrency dedup** keyed on PR HEAD SHA with `cancel-in-progress` for PRs only (`ci.yaml:40-42`) — deliberately narrow so main churn under serial auto-merge is not cancelled. Keep.
- **`kcov --merge` union** already in place (`ci.sh:545`) — likely immune to base #730's SUM drift. Keep; just verify the gate reads the merged report.

---

## Open questions for the maintainer

1. **ShellCheck exit-code contract:** with `-P` fan-out, do we want `xargs` (returns 123 if any child fails) or GNU `parallel` (returns count of failures)? Either must still fail `lint` deterministically under this repo's `set -uo pipefail` exit-code-contract convention. Which do you prefer?
2. **Shard budget:** do we know init's real concurrent-job ceiling on this account (Free = 20 org-wide per base ADR-00000017)? Bumping `CORE_SHARD_COUNT` to 8 pushes 8 core + 39 module + build/integration well past 20 concurrent — do we accept partial queueing, or should we adopt base's dynamic `vars.CI_SHARDS` + a clamp first?
3. **AC-17 gate source:** can we confirm the gate reads only `coverage/merged` (union) and never sums per-shard rates, before raising the shard count? (base #730 only surfaced when they raised theirs.)
4. **fish check:** turn it on (and fix whatever the 579 files surface) or remove it? It is currently a green no-op.
5. **Sequencing:** is the intended order (a) parallelize ShellCheck, (b) verify gate union-safety, (c) LPT + timings cache, (d) dynamic count, (e) god-file split, (f) ceiling ADR — or do you want the ADR first to fix the target before touching code?
6. **Lint toolchain provisioning (#2):** acceptable to give `lint` a minimal standalone toolchain, or must it keep pulling the shared image for version parity (base's no-CI-only-cache principle)?

---

*All timings from runs `28706884183` (main, 4m41s) and `28679850412` (main, 4m17s), viewed via `gh run view --json jobs`. base references from `ycpss91255-docker/base` issues #724/#733/#725/#730/#758/#732/#686 and ADR-00000017 / ADR-00000008.*
