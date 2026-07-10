---
name: project-workflow-concurrency-ram-cap
description: "RAM-crisis postmortem (2026-07-05): the 30GB hog was runaway tmux-powerline, NOT the Docker workflows; diagnose the actual process before blaming workflows"
metadata: 
  node_type: memory
  type: project
  originSessionId: 15320221-f6f9-442e-9faa-924d66c5db63
---

On 2026-07-05 the 38GB dev machine hit 35/38GB used + swapping, appearing to
stall many parallel workflows. I WRONGLY blamed the workflows' kcov coverage
runs and stopped three of them. The real cause: FIVE runaway `tmux-powerline`
processes (`~/.config/tmux/plugins/tmux-powerline/powerline.sh`), each stuck ~49
min at ~6GB RSS = ~30GB. Killing those five PIDs dropped usage from 34GB to 4GB
instantly. The Docker workflows used real but MANAGEABLE RAM; they were not the
hog. (The tmux-powerline runaway is the maintainer's to fix separately.)

**Lessons:**
1. Before attributing high RAM to the workflows, READ the actual top processes'
   cmdline: `ps -eo pid,rss,etime,comm --sort=-rss | head` then
   `tr '\\0' ' ' < /proc/<PID>/cmdline`. A "bash" at 6GB is suspicious -- check
   what it is. Do not assume it is kcov/Docker.
2. The earlier "coverage gate = ~29GB, cap concurrency at 2" conclusion was WRONG
   on the REASON (that 29GB was powerline, not kcov). RAM is NOT the binding
   limit. But there IS a real CONCURRENCY cap and it is CPU: each workflow's gate
   (`ci.sh --ci-unit`) parallelizes internally to nproc (sharded bats + the
   parallel `shellcheck -P nproc` from PR #297), so N concurrent workflows spawn
   ~N*nproc busy processes. Running 4 at once drove load average to ~65 on an
   8-core box -- gates that take ~5min crawled to 25min+ (CPU-oversubscribed, NOT
   hung: confirmed via `docker stats` showing 120-159% CPU on the "stuck" ci-run
   containers). So cap concurrent workflows at ~2 for CPU reasons. Distinguish
   hung (low CPU + long) from slow (high CPU + long = oversubscription) with
   `docker stats --no-stream` before intervening.
3. Failed/stopped workflows DO orphan Docker containers (they do not auto-clean);
   remove them targeted by name prefix `docker ps -aq --filter name=wf_<runid> |
   xargs -r docker rm -f` (never prune / global ops).
4. The compose-based `just -f justfile.ci` gate recipes leak containers across
   stages (a workflow accumulates 7-10). Worth a teardown fix, but it is not the
   RAM emergency it looked like.

- NEVER run two agents/gates on the SAME worktree concurrently: they share the
  Docker `/source` bind mount, so two `ci.sh` runs racing while git mutates the
  tree produce SPURIOUS gate failures (seen 2026-07-05: a one-file deletion got
  3 overlapping agents on one worktree -> 8 bogus test-unit failures; GitHub's
  isolated CI was green). For a tiny cleanup, use ONE workflow with a proper
  integrate stage, not several ad-hoc agents on a shared worktree.

Related: [[project-workflow-long-implement-no-schema]], [[feedback-use-monitor-for-ci]].
