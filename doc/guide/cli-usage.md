# CLI Usage Guide

Day-to-day `setup_ubuntu` usage. The CLI deliberately mirrors apt:
if you know `apt install / remove / purge / search / show / list`,
you already know most of this tool. Normative spec: PRD §7
(`doc/prd/init-ubuntu.prd.md`).

Run it from the repo checkout as `./setup_ubuntu.sh`; the TUI
(`./setup_ubuntu_tui.sh`) is a frontend over the same subcommands.

---

## Getting the tool

```bash
sudo apt install -y git          # clean server/container only; desktop usually has it
git clone https://github.com/ycpss91255/initialization.git
cd initialization && ./setup_ubuntu_tui.sh   # or ./setup_ubuntu.sh install --recommended
```

On first run the entrypoint checks its own dependencies (`jq` / `curl`
/ `git`) and offers to apt-install anything missing (automatic with
`-y`; fails fast with instructions when sudo is unavailable).

## The apt-style daily flow

```bash
# Find something to install
./setup_ubuntu.sh search fuzzy            # like apt search
./setup_ubuntu.sh show eza                # like apt show
./setup_ubuntu.sh list --category=optional --tag=cli-essentials

# Install (deps resolved and topologically sorted automatically)
./setup_ubuntu.sh install eza
./setup_ubuntu.sh install neovim          # pulls fzf, lazygit, ... as deps

# Upgrade
./setup_ubuntu.sh upgrade neovim          # one module
./setup_ubuntu.sh upgrade                 # everything installed

# Remove vs purge (same split as apt)
./setup_ubuntu.sh remove neovim -y        # binaries gone, config kept
./setup_ubuntu.sh purge neovim -y         # binaries + config gone

# What's on this machine
./setup_ubuntu.sh list --installed
```

There is deliberately **no `update` subcommand**: the module registry
is rebuilt in-memory from local files on every run, so there is no
index to refresh (PRD Q40).

## Confirmation and dry-run

Without `-y`, `install` first prints the resolved plan and asks,
apt-style:

```
Will install: neovim + 6 deps (fzf, lazygit, ripgrep, fdfind, fnm, git-config)
Proceed? [Y/n]
```

(`install` defaults to Yes; `upgrade` is the cautious one and defaults
to `[y/N]`.) `--dry-run` propagates down the whole dep chain — every
module prints the commands it *would* run, nothing touches the
filesystem, and a summary lists all would-install modules:

```bash
./setup_ubuntu.sh install docker --dry-run
```

## One-shot machine setup

```bash
./setup_ubuntu.sh install --recommended -y    # everything the environment recommends
./setup_ubuntu.sh install --base -y           # just the base set
```

Recommendations are environment-aware: on a machine with an NVIDIA
GPU, `nvidia-driver` shows up; in WSL or a container, host-only
modules are filtered out.

## Inspecting the environment and health

```bash
./setup_ubuntu.sh detect              # form factor / os / arch / gpu / ...
./setup_ubuntu.sh detect --json | jq
./setup_ubuntu.sh doctor              # env detect + doctor() of all installed
./setup_ubuntu.sh doctor docker       # one module
./setup_ubuntu.sh verify              # post-install acceptance of all installed
```

`verify` answers "did the install complete?"; `doctor` answers "can I
use it right now?" (services, group membership, device nodes) — see
`doc/guide/troubleshooting.md`.

## Advanced flows

```bash
# Skip dependency resolution (you own the consequences)
./setup_ubuntu.sh install neovim --no-deps

# Force the install target
./setup_ubuntu.sh install neovim --install-target=user-home   # no sudo needed

# Cross-machine sync (dry-run by default; see ADR-0013)
./setup_ubuntu.sh sync user@laptop --modules=base,recommended

# Export / import state
./setup_ubuntu.sh export ~/my-state.json
./setup_ubuntu.sh import ~/my-state.json --apply

# Config-drop modules go through the normal install pipeline
./setup_ubuntu.sh install git-config

# Tool configuration
./setup_ubuntu.sh config set lang zh-TW
./setup_ubuntu.sh config show
```

## Global flags

| Flag | Effect |
|---|---|
| `-y` / `--yes` | skip confirmation prompts |
| `--dry-run` | print commands instead of executing |
| `--quiet` | warn/error only |
| `--verbose` / `-v` | debug-level output; child command output streams live |
| `--color=auto\|always\|never` | ANSI color (default `auto`: off when piped / `NO_COLOR` / `TERM=dumb`) |
| `--lang=en\|zh-TW\|zh-CN\|ja` | force message language |
| `--state-dir=<path>` | override `${XDG_STATE_HOME:-~/.local/state}/init_ubuntu` |
| `--install-target=auto\|sudo\|user-home` | where modules install (default `auto`) |
| `--profile=server\|desktop\|jetson\|...` | override detected form factor |

## Exit codes

Scriptable, stable contract (PRD §7.4):

| Code | Meaning |
|---|---|
| 0 | success / query answered "yes" |
| 1 | generic failure / query answered "no" |
| 2 | argument error (unknown subcommand, misspelled module, invalid metadata) |
| 3 | unsupported environment (non-Ubuntu / unsupported release) |
| 4 | sudo unavailable and the module does not support user-home install |
| 5 | dependency cycle / resolution failure / `CONFLICTS_WITH` triggered |
| 6 | partial failure (some modules succeeded, some failed) |
| 7 | remote / network failure (SSH sync, GitHub download, apt repo unreachable) |

Example:

```bash
if ! ./setup_ubuntu.sh install docker -y; then
    case $? in
        6) echo "partial — check the log (see troubleshooting guide)" ;;
        7) echo "network — retry later" ;;
    esac
fi
```

## Where things land

| What | Where |
|---|---|
| install state | `${XDG_STATE_HOME:-~/.local/state}/init_ubuntu/state.json` |
| per-module version sidecar | `.../init_ubuntu/versions/<name>` |
| JSONL session logs | `.../init_ubuntu/logs/<YYYY-MM-DD-HHMMSS>.jsonl` |
| tool config | `${XDG_CONFIG_HOME:-~/.config}/init_ubuntu/config.ini` (generated — edit via `config set`) |

## See also

- PRD §7 (`doc/prd/init-ubuntu.prd.md`) — full subcommand table and semantics.
- `doc/guide/troubleshooting.md` — when something fails.
- `doc/guide/module-authoring.md` — adding your own module.
- `./setup_ubuntu.sh help` — the always-current quick reference.
