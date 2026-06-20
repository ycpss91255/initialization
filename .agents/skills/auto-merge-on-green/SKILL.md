# auto-merge-on-green

Arm GitHub-native auto-merge on a PR and watch it land, using a single
`Monitor` so state transitions stream in without busy-poll sleeps. Composes
the `wait-pr-ci` monitoring primitive (which stays a pure status watcher).

Use this right after `gh pr create` (the `remind_ci_auto_merge.sh` hook nudges
you to). The actual merge is done by GitHub server-side, so it lands even if
the session ends — this skill's job is to arm it, give you visibility, and keep
it unblocked under `strict` branch protection.

## How

Wrap the orchestration script in one `Monitor`:

```
Monitor(
  description: "PR #<n> auto-merge",
  command: ".claude/script/auto-merge-on-green.sh --repo <OWNER>/<REPO> --pr <n>",
  timeout_ms: 1800000,   # 30 min
  persistent: false,     # exits on MERGED / FAIL
)
```

The script:

1. Idempotently arms `gh pr merge <n> --auto --squash --delete-branch`.
2. Polls `gh pr view --json state,mergeStateStatus,statusCheckRollup` — keyed
   on `mergeStateStatus`, so it is **repo-agnostic** (no hardcoded check name;
   GitHub enforces whatever checks branch protection requires).
3. Prints one `PR<n>: state=… merge=… ci=…` snapshot per transition.

| Condition | Action |
|---|---|
| `state=MERGED` | exit 0 — GitHub landed it |
| `mergeStateStatus=BEHIND` | `gh pr update-branch` (GitHub native auto-merge does NOT auto-update a stale branch under `strict`); re-triggers CI |
| `mergeStateStatus=DIRTY` | exit 1 — merge conflict, rebase needed |
| required check failed (`ci=fail` + `BLOCKED`) | exit 1, report — **auto-merge left armed**, so a fix-push merges automatically |
| `CLEAN`/`UNSTABLE`/pending | keep waiting for `MERGED` |
| `ci=none` (no workflow run on the head) past `--retrigger-grace` (default 180s) | push an empty commit via the git API to force a CI run — fires at most once per run; `--no-retrigger` disables. Closes the "pushed but no CI triggered" gap (a push that lost the concurrency race) without a local checkout |
| `BLOCKED` with nothing pending/failed past `--grace` (default 90s) | exit 1 — blocked by a non-CI gate (e.g. required review) or a repo whose requirements never clear |
| no PR / empty view | exit 1 — nothing to merge |

Exit codes: `0` MERGED, `1` FAIL, `2` arg error, `124` max-iterations (tests).

## When NOT to use

- You only want to watch CI without merging → use `wait-pr-ci` directly.
- A tag/release push (no PR) → use `wait-pr-ci`'s tag flow (`wait-tag-ci.sh`).

## Notes

- Squash + delete-branch is the default merge method (`--merge-method`,
  `--no-delete-branch` to change).
- Degraded case: if the session ends AND the branch later goes `BEHIND`,
  GitHub native auto-merge stalls until someone runs `gh pr update-branch`
  (a GitHub merge queue would close this gap; out of scope here).
- `--no-arm` polls without arming (for tests / pre-armed PRs); `--interval 0`
  + `--max-iterations N` make the loop deterministic under test.

## See also

- `.claude/script/auto-merge-on-green.sh` — the implementation (`--help`).
- `wait-pr-ci` skill — the monitoring primitive this composes.
