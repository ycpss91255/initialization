# ADR-0014: drop `config load` subcommand in favor of archetype C install

- **Status:** Accepted
- **Date:** 2026-05-20
- **Supersedes part of:** PRD §13.1 Q6

## Context

PRD §13.1 Q6 originally answered "how do `module/config/*` get
applied?" with two mechanisms:

1. Each config bundle gets a paired `<name>-config.module.sh`
   (archetype C — config-drop) handling install / remove.
2. **Additionally** a `setup_ubuntu config load` subcommand was
   proposed for "batch apply".

This creates two paths to the same outcome, with overlapping
ownership:

- `setup_ubuntu install git-config` (via archetype C install)
- `setup_ubuntu config load git-config` (via load subcommand)

The `config` subcommand family also handles `config.ini` ops
(`get|set|unset|show`) — overloading the word "config" between
"user preferences" and "dotfile bundles" violates the CONTEXT.md
naming rule ("avoid bare 'config' without qualifier").

## Decision

Drop `config load` from the CLI surface. Config bundles are
installed via the standard archetype C lifecycle.

### How users actually apply config bundles

| Intent | Command |
|---|---|
| Single config bundle | `setup_ubuntu install git-config` |
| All config bundles in one shot | `setup_ubuntu install --tag=config` (Deferred — see note below) |
| Single bundle without engine state tracking | `bash module/git-config.module.sh install` (standalone) |
| Sync config bundles across machines | `setup_ubuntu sync user@host --modules=git-config,fish-config` |

> **Deferred-until-built:** the `install --tag=<t>` batch path is not yet
> wired. As shipped, `setup_ubuntu install --tag=config` is rejected with
> exit 2 — `install`'s flag parser treats `--tag=*` as an unknown flag.
> The batch-install-by-tag path described in this table is a design
> intent, not current behaviour; single-bundle install
> (`setup_ubuntu install git-config`) works today.

### CLI surface after change

The `config` subcommand family now means **`config.ini` operations
only**:

- `setup_ubuntu config get <key>`
- `setup_ubuntu config set <key> <value>`
- `setup_ubuntu config unset <key>`
- `setup_ubuntu config show [--json]`

No `config load`. Dotfile bundle installation is just regular
module installation.

### Module naming requirement

Config bundle modules carry `"config"` somewhere in `TAGS`.
Examples: `git-config` (`TAGS=("config" "git")`), `fish-config`
(`TAGS=("config" "fish")`), `tmux-config`, `claude-code-config`.

### `--tag=X` selector semantics

`--tag=X` matches modules where `X` appears **anywhere** in TAGS,
not only `TAGS[0]`. Rationale:

- `TAGS[0]` is reserved for **TUI grouping** (display purpose; PRD
  §6.3 "TAGS[0] 決定 TUI 分組"). It is presentation, not search.
- `--tag=X` is **search intent**; users expect `apt search`-style
  loose matching. Constraining it to first-tag-only makes secondary
  tags useless.

| Module | TAGS | Matches `--tag=config`? | Matches `--tag=git`? |
|---|---|---|---|
| `git-config` | `("config", "git")` | ✓ | ✓ |
| `docker` | `("container", "devops")` | ✗ | ✗ |
| `lazygit` | `("cli-essentials", "git")` | ✗ | ✓ |

`search` subcommand follows the same rule. `show` prints the full
TAGS list.

## Alternatives considered

- **Keep both paths.** Rejected: ambiguity about which to use, and
  `config load` is just `install --tag=config` in disguise.
- **Make `config load` an alias.** Rejected: alias for a single
  flag-form invocation is noise. CLI surface stays smaller.
- **Rename `config` (config.ini) family to `pref` / `setting`.**
  Considered but rejected — `config` is the strongest name and
  this ADR resolves the overlap by dropping the other use.

## Consequences

- One less subcommand in PRD §7.2. PRD §13.1 Q6 marked superseded.
- Config bundle authors follow the same archetype C contract as any
  other config-drop module; no special pipeline.
- TUI "Manage Installed" can group config bundles by `TAGS[0]=config`
  uniformly with other tagged groups.
- AC additions:
  - **AC-43:** `setup_ubuntu install --tag=config` installs every
    module where `"config"` appears **anywhere** in `TAGS` (not only
    `TAGS[0]`, which is reserved for TUI grouping) and exits 0.
  - **AC-44:** `setup_ubuntu config load` returns exit code 2
    (unknown subcommand) — the alias is not silently maintained.
