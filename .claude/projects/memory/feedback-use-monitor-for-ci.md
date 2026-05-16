---
name: feedback-use-monitor-for-ci
description: "For CI / long-running command progress, use Monitor (not polling, not gh run watch in background, not sleep loops)"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 456378d0-8a74-4d3b-ad5f-09c8c7e42ce7
---

When watching CI runs or any long-running external process, use the **Monitor** tool to stream events. Do NOT:

- Poll with `gh run view --json status` in a loop
- Run `gh run watch` in `run_in_background` mode and then re-check it
- Use `sleep N && check` patterns to wait for state change

**Why:** Monitor streams stdout lines as notifications without burning context or tool turns. Polling wastes calls; the user explicitly corrected this on 2026-05-16.

**How to apply:** When a CI run is in_progress (or any long-running external task — deploys, remote queues, batch jobs), launch a Monitor with a command that emits per-event lines until the terminal state is reached. Example for CI: a poll loop that emits each newly-completed job and exits when all checks reach a terminal bucket. Each stdout line becomes a notification; loop exit triggers a final notification. No further polling needed.
