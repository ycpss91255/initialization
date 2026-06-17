# justfile — init_ubuntu user-facing entry points
#
# Auto-discovered: run `just <verb> [args…]` from the repo root. This is
# the HOST-side user interface — thin pass-through wrappers around the
# entry scripts (`setup_ubuntu.sh`, `setup_ubuntu_tui.sh`,
# `setup_secrets.sh`, `run_claude.sh`, `install-nvidia-driver.sh`).
#
# The CI / test gate lives in a separate file: `just -f justfile.ci <recipe>`
# (1:1 port of the retired Makefile; see ADR-0022). This split mirrors
# ycpss91255-docker/base (justfile = user, justfile.ci = CI).
#
# Relation to ADR-0004 / .claude/hook/test-must-use-docker.sh:
#   These verbs run the REAL host installer — that is the intended use for
#   a USER on their own machine (`just install <module>`). It is NOT a
#   contradiction with the Docker-only test rule: ADR-0004 and the hook
#   govern an AGENT running Module Action Phases (install/upgrade/remove/
#   purge) or bats on the host, which stays blocked. User-facing recipes
#   here pass straight through to setup_ubuntu.sh; the hook never sees them
#   (the user runs `just`, not the agent), so user-facing != agent-facing.
#
# `just` itself must be installed on the dev host manually (CI provisions
# it via extractions/setup-just; the test-tools image via `apk add just`).

# Show available recipes.
default:
    @just --list

# ── init_ubuntu CLI (setup_ubuntu.sh) ────────────────────────────────────────
# All args pass straight through, so flags like --dry-run / --json / --force
# work unchanged: `just install --dry-run docker`, `just list --json`.

# Install modules (with deps, topologically sorted): `just install <module>…`.
install *args:
    ./setup_ubuntu.sh install {{ args }}

# Remove modules (config retained): `just remove <module>…`.
remove *args:
    ./setup_ubuntu.sh remove {{ args }}

# Remove modules + their config: `just purge <module>…`.
purge *args:
    ./setup_ubuntu.sh purge {{ args }}

# Run upgrade() for the given modules (or all installed): `just upgrade [<module>…]`.
upgrade *args:
    ./setup_ubuntu.sh upgrade {{ args }}

# Run verify() for the given modules (or all installed): `just verify [<module>…]`.
verify *args:
    ./setup_ubuntu.sh verify {{ args }}

# List registered modules (--installed for the state.json view, --json for machine output).
list *args:
    ./setup_ubuntu.sh list {{ args }}

# Print a module's metadata: `just show <module>`.
show *args:
    ./setup_ubuntu.sh show {{ args }}

# Print host environment (--json for machine output).
detect *args:
    ./setup_ubuntu.sh detect {{ args }}

# Diff state.json vs system reality.
doctor *args:
    ./setup_ubuntu.sh doctor {{ args }}

# Get/set/unset/show config: `just config set <section.key> <value>`.
config *args:
    ./setup_ubuntu.sh config {{ args }}

# Show tool version.
version *args:
    ./setup_ubuntu.sh version {{ args }}

# Escape hatch: pass an arbitrary subcommand through to setup_ubuntu.sh.
cli *args:
    ./setup_ubuntu.sh {{ args }}

# ── TUI (setup_ubuntu_tui.sh) ────────────────────────────────────────────────

# Launch the interactive TUI front-end.
tui *args:
    ./setup_ubuntu_tui.sh {{ args }}

# ── Secrets sub-tool (setup_secrets.sh) ──────────────────────────────────────

# Manage SSH keys / tokens / GPG: `just secrets ssh-key generate …`.
secrets *args:
    ./setup_secrets.sh {{ args }}

# ── NVIDIA driver helper (install-nvidia-driver.sh) ──────────────────────────

# Install / upgrade the NVIDIA driver: `just nvidia-driver [--latest] [--dry-run] …`.
nvidia-driver *args:
    bash ./install-nvidia-driver.sh {{ args }}

# ── Claude Code session helper (run_claude.sh) ───────────────────────────────

# Resume the Claude Code session for this repo.
claude *args:
    ./run_claude.sh {{ args }}
