# init_ubuntu

A personal-use modular Ubuntu environment initialization tool. Models package
management vocabulary on `apt` so user mental models transfer.

## Language

### Module

**Module**: a single `module/<name>.module.sh` file that declares metadata and
implements 10 lifecycle functions. Each module manages exactly one tool/feature.
_Avoid_: package, plugin, script, recipe.

**Archetype**: a pre-defined pattern for how a Module installs. Four archetypes
exist: A=apt-only, B=GitHub-release tarball, C=config-drop, D=custom hand-written.
A/B/C have helper macros that wire up lifecycle functions; D writes them all.
_Avoid_: type, kind, flavor.

**Lifecycle**: the 10 contract functions a Module must implement (or inherit
from an Archetype macro): `detect`, `is_recommended`, `is_installed`, `install`,
`upgrade`, `remove`, `purge`, `verify`, `is_outdated`, `doctor`.
_Avoid_: phase (reserved — see below), action, hook.

**Phase**: the verb invoked at runtime — same word in CLI (`setup_ubuntu install`)
and standalone (`bash module/x.module.sh install`). A Phase maps 1:1 to a
Lifecycle function plus two helper-provided phases (`info`, `status`).
_Avoid_: command, action.

### Execution

**Engine**: the orchestration layer — `setup_ubuntu` CLI + Dispatcher + Runner +
Registry + Resolver. Knows about cross-Module concerns (DEPENDS_ON tree, state.json).

**Engine Mode**: invocation via `setup_ubuntu <phase> <module>`. Engine resolves
DEPENDS_ON, updates state.json, batches Modules.

**Standalone Mode**: invocation via `bash module/<name>.module.sh <phase>`.
Single-Module direct run. Writes Sidecar + prints messages, does NOT resolve
DEPENDS_ON or update state.json.

**Dispatcher** (`lib/dispatcher.sh`): subcommand router; parses argv, calls
Runner / Resolver / Registry as needed.

**Runner** (`lib/runner.sh`): executes a Module's Lifecycle Phase inside an
isolated sub-shell with helpers pre-sourced.

**Registry** (`lib/registry.sh`): discovers Modules by globbing `module/*.module.sh`
at startup; exposes lookup by name / category / tag.

**Resolver** (`lib/resolver.sh`): topo-sorts DEPENDS_ON graph; rejects cycles.

### State

**State**: machine-written runtime facts (XDG_STATE_HOME). What's installed,
what version, when. Not user-edited.
_Avoid_: status, info.

**Config**: user-written preferences (XDG_CONFIG_HOME). Language, install
target, defaults. User edits via `setup_ubuntu config set …`.
_Avoid_: settings (overloaded).

**Sidecar**: `${XDG_STATE_HOME}/init_ubuntu/versions/<name>` file recording the
installed version of one Module. Single source of truth for "what version did
we install?", consulted by `is_outdated`. Written by both Engine and Standalone.

**Manual flag**: state.json field on each installed Module. `true` = user
explicitly named it on CLI; `false` = pulled in as a dep. Engine-only concept.

### CLI vocabulary (apt-aligned)

The CLI verbs intentionally mirror `apt`:

| `setup_ubuntu` verb | `apt` counterpart | Semantic |
|---|---|---|
| `install <m>` | `apt install` | install + deps |
| `remove <m>` | `apt remove` | remove, keep config |
| `purge <m>` | `apt purge` | remove + config |
| `upgrade [<m>]` | `apt upgrade` | upgrade Module to latest |
| `update` | `apt update` | rescan `module/` directory (registry refresh) |
| `list` | `apt list` | enumerate Modules; `--installed`/`--upgradable` flags |
| `show <m>` | `apt show` | print Module metadata |
| `search <term>` | `apt search` | search Modules |
| `doctor [<m>]` | (no apt analog) | self-diagnosis on environment + Modules |

The Module-level Lifecycle function is named `upgrade()` (not `update()`) to
avoid name collision with the Engine-level `setup_ubuntu update` (registry rescan).

## Relationships

- A **Module** belongs to exactly one **Archetype** (A, B, C, or D)
- A **Module** declares dependencies on other **Modules** via `DEPENDS_ON`;
  the **Resolver** turns this into install order
- A **Module** has exactly one **Sidecar** when installed (or none when removed)
- **Engine Mode** updates `state.json` + **Sidecar**; **Standalone Mode**
  updates **Sidecar** only
- A **Phase** maps to one **Lifecycle** function (or one of two helper-provided
  phases: `info`/`status`)

## Example dialogue

> **Dev:** "When the user runs `setup_ubuntu install neovim`, what writes the
> **Sidecar** — the **Engine** or the **Module**?"
> **Author:** "The **Module**'s `install()` writes it, via the Archetype B
> helper. Both **Engine Mode** and **Standalone Mode** hit the same code path.
> The difference is only that **Engine Mode** also writes `state.json` (with
> the **Manual flag**), while **Standalone Mode** leaves `state.json` untouched."

> **Dev:** "Is `verify` a **Phase** or a **Lifecycle** function?"
> **Author:** "Both. Every **Lifecycle** function is exposed as a **Phase** via
> the standalone CLI. `verify` plus the two helper-only **Phases** (`info` /
> `status`) make 12 total **Phases**."

## Flagged ambiguities

- "update" was overloaded across `apt update` (registry rescan), `apt upgrade`
  (version bump), and the Module's old `update()` function — resolved: Engine
  CLI uses `update` for rescan and `upgrade` for version bump; Module Lifecycle
  function is named `upgrade()` to match the version-bump semantic.
- "status" overlapped with `list --installed` — resolved: `setup_ubuntu status`
  is deprecated; use `setup_ubuntu list --installed`. Module helper `status`
  Phase (standalone only) prints installed/outdated for one Module — different
  scope, kept.
- "config" meant both Module-bundled template files (`module/config/<name>/…`)
  and user-level `config.ini`. Resolved: Module-bundled = "config template";
  user-level = **Config**. Avoid bare "config" without qualifier.
- "info" vs "show" — resolved: `setup_ubuntu show <m>` is the canonical user
  verb (apt-aligned); standalone CLI `info` Phase is an alias for the same
  output (helper-provided, no Lifecycle function needed).
- "run a test locally" — resolved: there is no "local" test execution. All
  test invocations must be `make test-unit` / `make test-integration` /
  `make coverage`, which route through `docker compose run --rm ci ...`.
  Running `bats` or `bash module/<x>.module.sh <action-phase>` on the host
  is prohibited by ADR-0004 and blocked by the PreToolUse Bash hook.
