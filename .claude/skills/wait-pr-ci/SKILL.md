---
name: wait-pr-ci
description: Wait for GitHub CI to settle — PR-scoped checks or tag/branch-scoped workflow runs — via the Monitor tool, instead of busy-polling with sleep loops.
---

# wait-pr-ci

Wait for GitHub CI to finish before merging or releasing, using `Monitor` so each state transition streams in as a notification and the agent isn't blocked on busy-poll sleeps.

Three flavours, one script each:

| Flavour | Script | When |
|---|---|---|
| **PR-scoped** (statusCheckRollup) | `.claude/script/wait-pr-ci.sh` | After `gh pr create` — single repo, one or several PRs, waiting to merge once green. |
| **Multi-repo PR-scoped** | `.claude/script/wait-pr-ci-batch.sh` | After `/batch-template-upgrade` opens N PRs across N downstream repos — one Monitor for the whole batch instead of N parallel streams. |
| **Tag/branch-scoped** (`gh run list --branch <ref>`) | `.claude/script/wait-tag-ci.sh` | After `git push origin <tag>` triggered `on: push: tags:` workflows like `release-test-tools` or `release-worker` — waiting to verify the release pipeline. |

All three are intentionally siblings — same output shape, same exit codes (`0` = ALL_DONE, `1` = FAIL, `2` = arg error, `124` = max-iter exhausted), same Monitor-wrap pattern. CLI shape differs: `wait-pr-ci.sh` takes `--repo` + `--prs`; `wait-pr-ci-batch.sh` takes positional `<repo>:<pr>` pairs; `wait-tag-ci.sh` takes `--repo` + `--branch`.

### Cwd assumption (worktree gap, refs #63)

The example `Monitor` blocks below use bare relative paths like `.claude/script/wait-pr-ci.sh`. Monitor inherits the agent's cwd at the moment the tool is invoked, and the relative path resolves under whatever that cwd is. Two cases to watch:

| Agent cwd | Behaviour |
|---|---|
| docker_harness root (`/home/.../docker`) | resolves to `<docker>/.claude/script/...` — works |
| worktree of docker_harness (`worktree/docker_harness-NN/`) | the worktree carries `.claude/` — works |
| worktree of a DIFFERENT downstream repo (e.g. `worktree/ros1_bridge-NN/`) | that worktree has NO `.claude/script/`; Monitor exits 127 with `No such file or directory` and no events stream |

`${CLAUDE_PROJECT_DIR}` is set by Claude Code only inside hook script env (the `command:` field of `.claude/settings.json` hook entries), not inside Bash / Monitor tool subprocesses — testing it via `echo "$CLAUDE_PROJECT_DIR"` from a Monitor or Bash command returns empty. So it cannot be used in these examples.

Until a workable absolute-path mechanism lands (issue #63 lists candidates), the safest pattern is: ensure the agent's cwd is the harness root or a docker_harness worktree before launching Monitor. If the agent is in a downstream-repo worktree, either `cd` to the harness root first (the example is a one-line bash prefix: `cd /home/.../docker && .claude/script/...` — Monitor's command field is a bash string), or pass an absolute path inline.

## PR-scoped — `wait-pr-ci.sh`

```
Monitor(
  description: "PR #<num> CI",   # or "PR #N1 + #N2 CI" for batches
  command: ".claude/script/wait-pr-ci.sh --repo <OWNER>/<REPO> --prs <CSV>",
  timeout_ms: 1800000,           # 30 min single PR; 2400000 (40 min) for batches
  persistent: false,             # script exits naturally on ALL_DONE / FAIL
)
```

The script prints one snapshot block (`PR<n>: checks=... mergeable=...` + `---`) per state transition, exits 0 on `ALL_DONE`, exits 1 on `FAIL <pr>`. 45s default poll interval — override with `--interval <sec>`.

**Per-repo `--check-filter`** (default matches base's `test` + `Integration ...`):

| Repo | Required checks | `--check-filter` |
|---|---|---|
| `base`, `multi_run` | `test` + `Integration E2E (...)` | (default) |
| `docker_harness` (this repo) | `bats + shellcheck + hadolint` (single-job test workflow) | `'.name=="bats + shellcheck + hadolint"'` |
| Single-target container repos (`agent/*`, most `app/*`) | `call-docker-build / docker-build` | `'.name=="call-docker-build / docker-build"'` |
| Multi-distro env repos (`env/ros_distro`, `env/ros2_distro`) | `ci-passed` (matrix aggregator) | `'.name=="ci-passed"'` |
| Multi-distro app repo (`app/ros1_bridge` post-#54) | `ci-summary` (in-repo aggregator) | `'.name=="ci-summary"'` |
| `.github` (org profile, post-topics-taxonomy) | `lint` (yaml structure + shellcheck) | `'.name=="lint"'` |

Multi-distro repos use a build matrix that produces `build (<distro>) / docker-build` shards plus a top-level aggregator job (`ci-passed` or `ci-summary`); the literal `call-docker-build / docker-build` filter never matches their PRs and they hang on `no-checks` forever. Use the aggregator filter instead.

`.github` doc-only PRs (most commonly `profile/*.md` updates — README and translations) bypass the `lint` job entirely. The workflow's `paths:` filter restricts triggers to `topics.yaml`, `script/sync-topics.sh`, and the workflow file itself, so unrelated paths produce zero check runs and the rollup sits at `no-checks` indefinitely (the `.name=="lint"` filter does not short-circuit `no-checks` — it polls forever). Skip `wait-pr-ci` for those PRs and merge directly after review; the `.github` repo's branch protection requires a PR but no status check, so doc-only PRs can land without CI.

Cross-repo batches: see `wait-pr-ci-batch.sh` below. For N=2-3 spawning N parallel single-repo Monitors is fine; from N=4+ the notification streams get noisy and `wait-pr-ci-batch.sh` aggregates them into one. Mixed repo categories in one batch (e.g. single-target containers + multi-distro env repos) need per-repo `--check-filter <repo>=<expr>` overrides — see below.

## Multi-repo PR-scoped — `wait-pr-ci-batch.sh`

```
Monitor(
  description: "batch PR CI (N repos)",
  command: ".claude/script/wait-pr-ci-batch.sh <repo>:<pr> <repo>:<pr> ... [--check-filter <expr>]",
  timeout_ms: 2400000,            # 40 min for batches
  persistent: false,
)
```

Positional pairs use short form (`ai_agent:28` — owner defaults to `ycpss91255-docker`, override with `--owner`) or full form (`other-org/repo:5`). Output line per pair:

```
ycpss91255-docker/ai_agent#28: checks=all-pass mergeable=MERGEABLE
ycpss91255-docker/claude_code#27: checks=pending mergeable=MERGEABLE
...
---
```

`ALL_DONE` / `FAIL <owner>/<repo>#<pr>` final lines, same as the single-repo flavour. `--check-filter` accepts two forms — a bare jq expression (global, applies to every pair) or `<repo>=<expr>` (per-repo override applied only when the pair's repo matches `<repo>`). The detection rule is: LHS of the first `=` must be a pure identifier (`[A-Za-z0-9_/-]+`) and RHS must not start with `=`; anything else is global. `<repo>` may be short (`ros_distro`) or full (`owner/repo`); short matches against the pair's basename, full matches the normalized `<owner>/<repo>`. Pairs that match no per-repo entry fall back to the global filter. The flag is repeatable; if the same repo key is given twice, the last occurrence wins.

Mixed-category batch example (single-target containers default to `call-docker-build / docker-build`, multi-distro env repos override to `ci-passed`, `ros1_bridge` to `ci-summary`):

```
.claude/script/wait-pr-ci-batch.sh \
  ai_agent:39 claude_code:38 codex_cli:37 gemini_cli:36 \
  ros_distro:3 ros2_distro:3 ros1_bridge:56 \
  --check-filter '.name=="call-docker-build / docker-build"' \
  --check-filter 'ros_distro=.name=="ci-passed"' \
  --check-filter 'ros2_distro=.name=="ci-passed"' \
  --check-filter 'ros1_bridge=.name=="ci-summary"'
```

Pairs with `wait-pr-ci.sh` for single-repo cases — same skill, same patterns, just batched.

## Tag/branch-scoped — `wait-tag-ci.sh`

```
Monitor(
  description: "tag v0.12.2 CI",
  command: ".claude/script/wait-tag-ci.sh --repo <OWNER>/<REPO> --branch <tag-or-branch>",
  timeout_ms: 1800000,
  persistent: false,
)
```

Same output shape (`<run-name>: <status>/<conclusion>` + `---`), same exit codes. Default `--check-filter` is `'true'` (all runs); narrow with e.g. `'.name=="release"'`. `--limit <N>` caps `gh run list` page size (default 10).

If the tag was just pushed, the first iteration may see no runs yet (`total == 0`); the loop keeps polling until at least one run appears, then waits for all to complete. This naturally handles the "GitHub took 30s to schedule the workflow" gap.

## Behaviour (both scripts)

- Each state transition prints exactly one snapshot block. Steady states print nothing.
- `ALL_DONE` is the final notification — that's the cue to merge / release.
- On any `FAIL`, the script prints `FAIL <name>` and exits 1. Investigate before retrying.
- `--max-iterations <N>` caps iterations for tests; production callers leave it unset and rely on `Monitor` `timeout_ms`.
- **SKIPPED counts as success-equivalent** in the all-pass check (refs #86). GitHub itself treats `SKIPPED` as non-blocking for branch protection, so a doc-only-short-circuit pattern that fires `if: needs.classify.outputs.code_changed == 'true'` on the heavy jobs (skipping them on doc-only PRs) reaches `ALL_DONE` instead of hanging. `FAILURE` / `CANCELLED` / `TIMED_OUT` still trip `FAIL`. Applies to `wait-pr-ci.sh` + `wait-pr-ci-batch.sh` (uppercase `SKIPPED`) and `wait-tag-ci.sh` (lowercase `skipped`, matching the `gh run list` JSON shape).

## False-positive ALL_DONE guard — `--min-checks <N>`

Two race conditions used to produce premature `ALL_DONE` and have been fixed by guards added in front of the original `all(.conclusion == "SUCCESS")` jq check:

1. **Subset-rollup race** — right after a PR is opened, GitHub's PR rollup may briefly return only a SUBSET of the expected checks (e.g. `Integration E2E` already `COMPLETED/SUCCESS` while `test` has not registered yet). The original `all(.conclusion == "SUCCESS")` over `[{SUCCESS}]` evaluates to `true` (jq's `all` is vacuously true on a single-success list), reporting false all-pass. Fixed by the `length < min_checks` guard.

2. **In-progress visible check** — a check that is registered but still running has `status: "IN_PROGRESS"` with empty `conclusion`. The original pipeline correctly reported `pending` here (because `"" != "SUCCESS"`), but the new explicit `any(.status != null and .status != "COMPLETED")` guard catches the case earlier and produces an actionable label.

The status guard is unconditional and applies on every poll. The `--min-checks <N>` guard is **opt-in** (default 1, preserving backwards-compatible behaviour). Caller decides how many checks the workflow ought to register:

| Repo / filter | Suggested `--min-checks` |
|---|---|
| `base`, `multi_run` (default filter `test + Integration ...`) | `2` |
| `docker_harness` (single `bats + shellcheck + hadolint`) | `1` (default; can omit) |
| Single-target container repos (single `call-docker-build / docker-build`) | `1` (default) |
| Multi-distro env / app repos (single aggregator: `ci-passed` / `ci-summary`) | `1` (default) |
| `.github` (single `lint`) | `1` (default) |

For `wait-pr-ci-batch.sh`, `--min-checks` accepts the same two forms as `--check-filter`: a bare integer (global default for every pair) or `<repo>=<N>` per-repo override. Detection rule mirrors `--check-filter` exactly. Mixed-category batch example combining filter + min-checks overrides:

```
.claude/script/wait-pr-ci-batch.sh \
  base:42 ai_agent:39 ros_distro:3 ros1_bridge:56 \
  --check-filter 'base=.name=="test" or (.name|startswith("Integration"))' \
  --check-filter '.name=="call-docker-build / docker-build"' \
  --check-filter 'ros_distro=.name=="ci-passed"' \
  --check-filter 'ros1_bridge=.name=="ci-summary"' \
  --min-checks 'base=2'
```

## Stale-rollup guards (force-push race)

Two additional guards (refs ycpss91255-docker/docker_harness#60, ycpss91255/initialization#22) catch the case where the script is launched immediately after a `git push --force-with-lease`. GitHub takes 10-60 seconds to retrigger CI on the new head; during that window the PR rollup either still shows the old head's results, returns empty, or shows the new head with only some checks queued. Without these guards, the "still shows old head" sub-case results in immediate false ALL_DONE because the previous run's `ci-summary=pass` matches the success filter.

1. **Watch-start completedAt guard** — captured at script start. Inside the `all(.conclusion == "SUCCESS")` branch, the rollup is treated as carry-over from a prior head ONLY when every filter-matched check has `completedAt` set AND every one of those values falls in the window `(watch_start - stale_window, watch_start)`. Inside that window → demote to `pending`; older than that → trust as legitimate prior run and emit `all-pass`. The `--stale-window <seconds>` flag controls the window width (default 120s — covers GitHub's observed 10-60s retrigger latency plus buffer). `--stale-window 0` restores the original always-demote behaviour. Backwards-compatible: only fires when every matching check has `completedAt` (real GitHub API always populates it; existing test stubs without the field keep working).

    Issue #22 motivation: launching `wait-pr-ci.sh` against a PR whose CI completed long before — e.g. hours later, manual verification flow — would otherwise hang forever because every `completedAt < watch_start`. The stale-window cap bounds the guard to the actual race window.

2. **`headRefOid` change guard** — captured per PR / per pair across iterations. When the current `headRefOid` differs from the value seen on the previous poll, emit one `[head-moved] PR<n> <old7>..<new7>` (or `[head-moved] <owner>/<repo>#<pr> <old7>..<new7>` for the batch script) log line and force the per-PR state to `pending` for that poll iteration. The next poll re-evaluates against the new head normally. One stale PR in the batch does not abort the rest.

Both guards apply to `wait-pr-ci.sh` and `wait-pr-ci-batch.sh` symmetrically. `--stale-window` fires automatically with its default; override only for unusual workflows.

## Anti-patterns

- **`sleep 60` between manual `gh pr checks` / `gh run list`** — burns a cache-miss with nothing to show; the agent's context fills with noisy poll output.
- **`gh pr merge --auto`** for the first merge — fine for queueing, but you don't get the failure-mode visibility the Monitor stream gives.
- **`gh run watch`** — polls a single workflow; PR-level rollup or branch-level run-list already aggregates matrix shards.
- **Inlining the loop in the Monitor `command`** — Claude Code's bash AST parser warns on parameter expansions like `${pair%:*}` ("Contains simple_expansion") and `<<<"$s"` ("Unhandled node type: string"); historically also choked on `[[ a != b ]]` (Monitor's eval wrapper escapes `!` to `\!`). Calling a permanent script side-steps all three.

## Pairing with merge / release

Once `ALL_DONE` arrives:

```bash
# PR
gh pr merge <PR> --repo <OWNER>/<REPO> --squash --delete-branch

# Tag (release flow continues per .claude/commands/release.md)
```

If PR merge fails with `not mergeable: branch is not up to date`, the head moved between rollup and merge. For dependabot PRs:

```bash
gh pr comment <PR> --repo <OWNER>/<REPO> --body "@dependabot rebase"
# then re-invoke wait-pr-ci on the same PR (CI re-runs on the rebased head)
```

For non-bot PRs, rebase locally + force-push, then re-invoke.

## See also

- `.claude/script/wait-pr-ci.sh` / `.claude/script/wait-pr-ci-batch.sh` / `.claude/script/wait-tag-ci.sh` — the polling implementations. `--help` prints usage.
- doc/process/release.md → "## CI 監控（PR open 後）" — the project-level rule pointing back here.
- `.claude/commands/pr.md` — full PR workflow, calls this skill at step 6 ("Wait for CI").
- `.claude/commands/release.md` — release / tag workflow that should call the tag flavour after pushing the tag.
