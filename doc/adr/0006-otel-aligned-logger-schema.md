# ADR-0006: OTel-aligned structured logger schema

- **Status:** Accepted (decision only; implementation tracked by #8)
- **Date:** 2026-05-16
- **Refs:**
  - Project author's observability playbook
    ("Debug 資訊架構：從 print 到 Observability", 2026-05-12 Notion)
  - OpenTelemetry Logs Data Model — https://opentelemetry.io/docs/specs/otel/logs/data-model/
  - OpenTelemetry Semantic Conventions — https://opentelemetry.io/docs/specs/semconv/
  - W3C Trace Context — https://www.w3.org/TR/trace-context/
  - lnav JSON log format — https://docs.lnav.org/en/latest/formats.html

## Context

`lib/logger.sh` `log_event` already emits JSONL — a strong head start
compared to plain `printf` debug logs (see commits 3150157, 4502ecc).
The current shape:

```jsonl
{"ts":"2026-05-12T14:23:11+08:00","level":"info","module":"docker","event":"install_start","manual":true,"version_provided":"v1"}
```

Strengths:
- Already JSON Lines (machine-queryable with `jq` / `lnav`)
- Event vocabulary is enum-like (`install_start`, `install_done`,
  `install_failed`, `session_start`, `session_end`, `cmd_exec`) — not
  free-text sentences
- Auto-typed (numbers + booleans not quoted)

Gaps for agent-driven log analysis (the primary downstream consumer):

1. **No correlation across calls.** A `setup_ubuntu install docker
   apt-essentials` produces 30+ events; nothing links them as a single
   trace.
2. **Field names diverge from OpenTelemetry Logs Data Model.** Future
   migration to any OTel-aware tool (Grafana Loki, SigNoz, Datadog,
   etc.) needs schema re-mapping.
3. **Business payload is at the top level.** Mixed with metadata,
   makes attribute-only queries clumsier.
4. **No `code.filepath` / `code.lineno`.** Can't jump from a log line
   back to source.
5. **`log_info` / `log_warn` / `log_error` don't mirror to JSONL.**
   Human-readable TTY messages (often containing real failure
   context) never reach `${INIT_UBUNTU_LOG_FILE}` — agent analysis
   misses them.

The Notion writeup names "**add trace_id**" as the single
highest-ROI action, and the simplest cost-conscious investment as
"adopt the OTel schema field names without adopting the OTel SDK".

For init_ubuntu (bash, single-host, single-user, no microservices)
the trade-off is clean:
- SDK + Collector + OTLP exporter — overkill, defer indefinitely
- Schema alignment — write-once, future-proof, near-zero cost

## Decision

Migrate `log_event` JSONL schema to mirror the OpenTelemetry Logs
Data Model + W3C Trace Context, **without** adopting the OTel SDK
or Collector.

### Target schema

```jsonl
{
  "timestamp": "2026-05-12T14:23:11.234567Z",
  "severity_text": "INFO",
  "body": "install_start",
  "trace_id": "0193cdef-1234-7abc-89de-1234567890ab",
  "span_id": "install_docker_001",
  "attributes": {
    "service.name": "docker",
    "service.lang": "bash",
    "code.filepath": "lib/runner.sh",
    "code.lineno": 46,
    "manual": true,
    "version_provided": "v1"
  }
}
```

Field-by-field rationale:

| Field | Source | Rationale |
|---|---|---|
| `timestamp` | OTel | Replaces `ts`; ISO 8601 + **UTC + microseconds** (cross-machine debug compatibility) |
| `severity_text` | OTel | Replaces `level`; UPPERCASE per spec |
| `body` | OTel | Replaces `event`; constrained event vocabulary, NEVER free-text |
| `trace_id` | W3C Trace Context | Per-`setup_ubuntu`-invocation correlation ID |
| `span_id` | W3C | Per-(phase, module) sub-span — `_runner_run_phase` assigns it |
| `attributes` | OTel | Container for business payload + SemConv fields |
| `attributes.service.name` | OTel SemConv | Replaces top-level `module`; dot-not-underscore per spec |
| `attributes.service.lang` | OTel SemConv | Always `"bash"` for this tool |
| `attributes.code.filepath` / `code.lineno` | OTel SemConv | `BASH_SOURCE[1]` / `BASH_LINENO[0]` of caller |

### trace_id format

UUID v7 (RFC 9562 — time-ordered, sortable) preferred. Fallback chain:

1. `uuidgen` (util-linux) — generate v4 UUID if v7 unavailable
2. `python3 -c 'import uuid; print(uuid.uuid7())'` — only Python 3.13+
3. `date +%s%N` (nanosecond unix time as decimal string)

Set once at `setup_ubuntu.sh` entry, exported as
`INIT_UBUNTU_TRACE_ID`, inherited by all sub-shells (including the
`bash --noprofile -c "..."` form `_runner_run_phase` uses).

### span_id format

Composed: `${PHASE}_${MODULE}_${COUNTER}` where COUNTER is per-trace
monotonic. Example: `install_docker_001`. Sortable, human-grokkable,
no UUID overhead per event.

### Log file rotation

`${INIT_UBUNTU_LOG_FILE}` legacy global is replaced with
`${XDG_STATE_HOME}/init_ubuntu/logs/<trace_id>.jsonl` — one file per
session. A `latest` symlink keeps a stable path for `tail -f` users.
Old jsonl files retained per a `INIT_UBUNTU_LOG_RETENTION_DAYS`
config (default 30).

### Bridge: `log_info` / `log_warn` / `log_error` → JSONL too

The text loggers gain a JSONL mirror call: every `log_info "[name]
msg"` also emits `log_event info <name> message msg="..."` so the
JSONL stream is the complete record. TTY output unchanged.

### Tooling

`doc/guide/log-queries.md` ships:
- A copy-pasteable `~/.lnav/formats/installed/init_ubuntu.json` with
  `opid-field: trace_id` (gives `lnav Shift+T` free timeline view)
- 5+ `jq` snippets for common queries (failures per module, p99
  duration per phase, trace by id, ...)

## Alternatives considered

### A. Status quo (keep current schema)

- Pros: zero work
- Cons: every gap above persists; no clean migration path to any
  future tool

Rejected. Lock-in cost grows with every new event added.

### B. Adopt OTel SDK + Collector

- Pros: real observability stack — Loki / Tempo / Mimir integration
  for free; spans become real (not just IDs)
- Cons:
  - OTel for bash doesn't exist; would need to spawn a Python sidecar
    that proxies events
  - Collector adds a deploy dependency for a single-user tool
  - Massive complexity for queries we'd anyway run with `jq` /
    `lnav` for the foreseeable future
- Notion playbook explicitly recommends *against* this at the current
  scale ("把 OTel 當「schema 規範」用,不要當「framework」用")

Rejected. Returns mismatched with cost.

### C. Custom schema (no OTel alignment)

- Pros: free to design exactly what we want
- Cons: any future tool integration needs a custom mapper; field
  names will inevitably collide with industry conventions

Rejected. OTel SemConv is the de-facto answer for these field names;
there's no benefit to reinventing.

## Consequences

### Positive

- Future migration to OTel-aware tooling is rename-free
- Single trace_id grep collapses a session's event stream into one
  view — directly addresses the "agent-friendly analysis" goal
- `service.name` / `code.*` SemConv fields are immediately useful
  for human debugging too
- `lnav opid-field` gives a free TUI timeline view per trace

### Negative

- Breaking change to log file shape — any external parser breaks.
  Acceptable because:
  - Project is pre-v0.1.0 (no released parsers exist outside the
    project)
  - CHANGELOG `[Unreleased]` will document the schema migration
- Slight per-event overhead: extra `attributes.code.filepath` lookup
  via `BASH_SOURCE[1]`. Benchmark before declaring this matters.

### Migration plan

Tracked by issue #8. Phases:

1. **Schema rename + nest payload** + `service.name` / `service.lang`
   / `code.*` SemConv fields. Update all existing `log_event`
   callers in `lib/`. Update `test/unit/logger_spec.bats` expected
   shapes.
2. **`trace_id` + `span_id` propagation.** Generate at
   `setup_ubuntu.sh` entry, inherit via env. Update
   `_runner_run_phase` to manage span lifecycle.
3. **Per-session log file rotation** + `latest` symlink.
4. **`doc/guide/log-queries.md`** with lnav format + jq snippets.

Implementation gated on PRs #4 / #6 / #7 merging first (to avoid
CHANGELOG and `lib/runner.sh` merge conflicts).

## What this ADR explicitly does NOT decide

- Adding metrics collection (separate from logs; Notion §1 "Three
  Pillars" — logs is just one)
- Adding distributed tracing in the OTel sense (no microservices to
  trace yet)
- TUI / web log viewer beyond `lnav`
- Cross-machine log shipping
