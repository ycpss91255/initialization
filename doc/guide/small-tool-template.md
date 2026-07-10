# Small-tool template (one-off bash tools)

`template/tool.template.sh` is the standard skeleton for **one-off** bash tools
that live under `tool/`. It gives every such script the same predictable shape:
a `--help`, a `--dry-run`, an explicit exit-code contract, grep-guarded
idempotent work, and `set -euo pipefail`.

See also: [ADR-0029](../adr/0029-small-tool-template.md).

The template is a **thin skeleton over a shared bootstrap**: it sources
`lib/tool_bootstrap.sh` (public API `tool_bootstrap` / `tool_main` /
`tool_is_dry_run` / `tool_ensure_line` / `tool_run`), then only defines
`usage()` + `do_work()` and calls `tool_main "$@"`. The strict mode, path
resolution, logger, argument parsing, and grep-guarded idempotent edit all live
in the bootstrap, so a tool carries near-zero boilerplate. The hook counterpart
is `lib/hook_bootstrap.sh` + `template/hook.template.sh`.

## When to use it (and when NOT to)

Use this template when the script is a genuine **one-off**: a personal host
tweak, a machine-specific sync, a "run this once" fix. It is **not** a module —
it has no `is_installed/install/upgrade/remove/purge` lifecycle, is not resolved
by the engine, and holds no `state.json` entry.

Do **not** use it when the thing is **reusable** (other machines / other users
would want it). Reusable things are modules: promote them per PRD §6.5/§6.6 and
copy one of `template/module-{apt,github-release,config,custom}.template.sh`
instead. Never grow a `tool/` script into a pseudo-module.

| Signal | One-off tool (`tool/`) | Module (`module/`) |
| --- | --- | --- |
| Reused across machines/users | no | yes |
| Needs install/remove/upgrade lifecycle | no | yes |
| Engine-resolved / has `state.json` entry | no | yes |
| Installs host packages | **never** | yes (that is its job) |

## The contract

| Invocation | Behavior | Exit |
| --- | --- | --- |
| `-h` / `--help` | print usage to **stdout** | `0` |
| (no args) | perform the work | `0` on success |
| `--dry-run` / `-n` | print what *would* change, mutate nothing | `0` |
| unknown argument | print usage to **stderr** | `2` |

This mirrors the module CLI's `0 = ok` / `2 = usage-error` convention, so tools
and modules read the same way from a script or a CI gate.

## Rules the skeleton enforces

- **`set -euo pipefail`** — a tool is in ADR-0007's *always-act* family: it
  performs side effects and any intermediate failure must abort the whole run.
  (Contrast the exit-code-*contract* scripts — hooks, `release-tag.sh` — which
  default to `set -uo` so a probe returning 1 does not abort. A tool is not a
  probe.) The historical live bugs came from missing `set -u`; this closes that.
- **Idempotency** — work is grep-guarded: it only acts when the desired state is
  absent, so re-running is safe and never duplicates changes.
- **`--dry-run`** — every mutation path has a dry-run branch that reports intent
  and changes nothing.
- **No host package installs** — a one-off tool must never `apt-get`/`dpkg`/
  `snap` install on the host (repo hard rule #2). If you need a package, it is a
  module, not a tool.
- **Optional logger** — the bootstrap sources `lib/logger.sh` for
  `log_info/log_warn/log_error`, falling back to minimal stderr shims if the
  logger is unavailable (a tool copied out of the repo).

## How to author one

```bash
cp template/tool.template.sh tool/<your-name>.sh   # kebab-case name
# 1. Fill in TOOL_NAME + TOOL_SUMMARY and the usage() body.
# 2. Replace do_work() with the real, grep-guarded, dry-run-aware work
#    (use tool_ensure_line / tool_run; read tool_is_dry_run when you branch).
# 3. Add a spec (see below) with the 3 canonical cases.
```

## How to test

Copy `template/test-tool.template.bats` as the starting point and adapt the
three canonical cases to your tool:

1. `--help` exits `0` and prints usage.
2. an unknown argument exits `2`.
3. `--dry-run` performs no mutation.

Run everything inside Docker (ADR-0004 — tests never run on the host):

```bash
just -f justfile.ci test-unit
```
