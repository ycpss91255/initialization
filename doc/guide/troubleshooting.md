# Troubleshooting Guide

What to do when an install fails or a tool stops working. The
debugging story is built around two commands and one file format:
`doctor`, `verify`, and the JSONL session log. Design background:
ADR-0006 (log schema), ADR-0009 (verify vs doctor), PRD §10.2.

---

## First moves

```bash
./setup_ubuntu.sh doctor              # environment snapshot + health of all installed
./setup_ubuntu.sh doctor docker       # one module
./setup_ubuntu.sh verify docker       # "did the install actually complete?"
```

- **`verify` fails** → the installation itself is broken (missing
  binary, bad sidecar). Re-run the install; modules are idempotent.
- **`verify` passes but `doctor` fails** → the install is fine, the
  runtime drifted: a daemon is stopped, you are not in a required
  group, a config file was hand-edited, an external repo is
  unreachable. `doctor` output names the failing check.
- **`doctor --validate-modules`** → lints module metadata; use after
  editing any `module/*.module.sh`.

## Reading the JSONL log

Every `install` / `remove` / `purge` session writes one file:

```
${XDG_STATE_HOME:-~/.local/state}/init_ubuntu/logs/<YYYY-MM-DD-HHMMSS>.jsonl
```

One JSON object per line, OTel-aligned (ADR-0006):

```json
{"timestamp":"2026-05-13T14:22:34.001234Z","severity_text":"INFO","body":"cmd_exec",
 "trace_id":"0193cdef-...","span_id":"install_docker_001",
 "attributes":{"service.name":"docker","cmd":"sudo apt-get update","exit":0,"duration_ms":1430}}
```

| Field | What it tells you |
|---|---|
| `body` | event code enum — `session_start`, `install_start`, `cmd_exec`, `dep_resolved`, `install_done`, `install_failed`, `upgrade_failed`, `action_required`, `session_end`, ... (never free text) |
| `severity_text` | `DEBUG` / `INFO` / `WARN` / `ERROR` / `FATAL` |
| `trace_id` | one per `setup_ubuntu` invocation — links every event of that session |
| `span_id` | one lifecycle operation of one module |
| `attributes.service.name` | the module (engine-level events use `"engine"`) |
| `attributes` | the payload: `cmd`, `exit`, `duration_ms`, `version`, ... |

Useful slices (`jq` is part of the tool's own preflight deps, so it is
present):

```bash
LOG=$(ls -t ~/.local/state/init_ubuntu/logs/*.jsonl | head -1)   # latest session

# Everything that went wrong
jq -c 'select(.severity_text=="ERROR" or .severity_text=="FATAL")' "$LOG"

# Every command one module ran, with exit codes and durations
jq -c 'select(.attributes."service.name"=="docker" and .body=="cmd_exec")
       | {cmd: .attributes.cmd, exit: .attributes.exit, ms: .attributes.duration_ms}' "$LOG"

# The post-install / reboot notices you may have scrolled past
jq -c 'select(.body=="action_required") | .attributes' "$LOG"

# Session verdict (exit code + ok/skipped/failed counts)
jq -c 'select(.body=="session_end")' "$LOG"
```

`lnav` also reads these files directly if you prefer interactive
exploration (`lnav ~/.local/state/init_ubuntu/logs/`).

## Chasing a trace_id

When a run fails, stdout prints the last ~20 lines of the failing
module's command output **plus a `trace_id` and the log file path** —
e.g. `→ trace_id=abc-def, see jsonl log`. The trace_id is the handle
for the whole session:

```bash
# All events of that session, in order, across all its log files
jq -c 'select(.trace_id=="abc-def")' ~/.local/state/init_ubuntu/logs/*.jsonl

# Narrow to the failure and what led to it
jq -c 'select(.trace_id=="abc-def")
       | select(.severity_text!="DEBUG")' ~/.local/state/init_ubuntu/logs/*.jsonl
```

stdout and the log never diverge: the human-readable output is a
render of the same events (PRD §7.7 / AC-35), so anything you saw on
screen is queryable, and things you did *not* see (full child-command
output, timings) are in `attributes`.

Logs rotate automatically: at most 100 files / 30 days are kept
(AC-33), so grab the file if you want to keep a post-mortem.

## Common exit codes and what to actually do

| Exit | Symptom | Move |
|---|---|---|
| 2 | unknown subcommand / misspelled module / invalid metadata | `./setup_ubuntu.sh list` to check the name; after editing a module, `doctor --validate-modules` |
| 3 | "environment not supported" | non-Ubuntu or unsupported release; check `detect`, override form factor with `--profile=` if the detection is wrong |
| 4 | sudo unavailable | use `--install-target=user-home` for modules that support it (`show <module>` → `SUPPORTS_USER_HOME`), or get sudo |
| 5 | dependency cycle / conflict | `show <module>` to inspect `DEPENDS_ON` / `CONFLICTS_WITH`; remove the conflicting module first |
| 6 | partial failure | some modules failed, the rest are fine; query the log for `install_failed` / `upgrade_failed` events, fix, re-run (idempotent) |
| 7 | network | GitHub release / apt repo / SSH unreachable; retry, check proxy; GitHub version checks cache 1h in `~/.cache/init_ubuntu/gh-latest/` |

## Specific situations

**Install succeeded but the tool misbehaves later** — `doctor <name>`.
Typical findings: `newgrp docker` / re-login needed (group), service
not running, `$PATH` missing `~/.local/bin`. These were also printed
in the end-of-session "Action required" block — recover them anytime
with the `action_required` jq query above.

**Upgrade failed** — failure policy is continue-and-report (PRD §7.6):
other modules still upgraded, the failed one was rolled back where the
archetype allows (user-home: symlink swap; config-drop: backup
restore; apt: no auto-rollback, the log suggests
`apt install <pkg>=<old-ver>`). The summary names the failure and its
trace_id.

**`state.json` corrupt** — the tool backs it up as
`state.json.corrupt.<ts>` and fails fast; it never silently rebuilds
(would lose manual/dep data). Re-running installs re-records modules,
or repair the backup by hand and move it back.

**State lock timeout** — another `setup_ubuntu` holds
`.state.lock`; the error prints the holder PID. Wait or kill it.

**Stale module index / docs** — `./script/gen-module-index.sh >
doc/module/INDEX.md` (CI checks freshness).

## When filing an issue

Attach: the command line, the printed trace_id, and the relevant
`.jsonl` file (or at minimum the `session_start` event — it embeds the
environment snapshot: form factor, OS, arch, GPU). That is everything
a human or agent needs to replay the session.

## See also

- `doc/adr/0006-otel-aligned-logger-schema.md` — why the log looks like this.
- `doc/adr/0009-verify-vs-doctor-semantic-boundary.md` — which command answers what.
- PRD §10.2 — log location, schema, retention; §7.4 — exit code contract.
- `doc/guide/cli-usage.md` — the commands referenced here.
