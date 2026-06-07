# ADR-0017: user-home install path layout standardization

- **Status:** Accepted
- **Date:** 2026-05-20

## Context

PRD §3.3 says user-home install goes to `$HOME/.local/{bin,lib,share}`
but does not specify:
- How multiple versions of the same module coexist.
- How `remove` / `purge` tracks files to delete.
- Whether PATH / MANPATH need user setup.
- Whether helper API standardises the layout.

Without policy, every archetype-B module re-invents the layout,
producing drift (some use `$HOME/.local/eza`, some `$HOME/.eza/`,
some unpack into `$HOME/.local/bin/eza-data/`).

## Decision

### Layout standard

```
$HOME/.local/
├── bin/                                   # binaries (or symlinks)
├── lib/init_ubuntu/<name>/<version>/      # versioned unpack
├── lib/init_ubuntu/<name>/current → <version>/
├── share/man/manN/<name>.N                # man pages
├── share/<name>/                          # runtime data (mirror system)
├── share/bash-completion/completions/<name>
├── share/fish/vendor_completions.d/<name>.fish
└── share/zsh/site-functions/_<name>
```

`lib/init_ubuntu/` is the namespaced root for everything this tool
unpacks. It coexists with user-installed software in `lib/` without
collision.

### Multi-version coexistence

- Unpack into `$HOME/.local/lib/init_ubuntu/<name>/<version>/`.
- Maintain `$HOME/.local/lib/init_ubuntu/<name>/current` symlink →
  `<version>/`.
- `$HOME/.local/bin/<name>` symlink →
  `../lib/init_ubuntu/<name>/current/bin/<name>`.
- `upgrade` writes new version dir, swaps `current` symlink, removes
  old version dir.

### Removal tracking

No explicit file manifest. Removal works by convention:

- `rm -rf $HOME/.local/lib/init_ubuntu/<name>/`
- `$HOME/.local/bin/<name>` — only delete if `readlink` resolves
  inside `$HOME/.local/lib/init_ubuntu/<name>/` (defensive: never
  touch a symlink the user pointed elsewhere).
- man page + completions: filename matches `<name>.*` AND resolves
  into our lib tree.

The defensive checks protect users who have their own
`$HOME/.local/bin/eza` that they prefer over the init_ubuntu copy.

### PATH / MANPATH

- Ubuntu 22.04+ default `.bashrc` and `~/.profile` already prepend
  `$HOME/.local/bin` to PATH (systemd user environment + standard
  shipped dotfiles). Verify on session start; if absent, the
  `shell.module.sh` install path injects it.
- `man` automatically searches `$HOME/.local/share/man/`. No
  explicit MANPATH config needed.
- Shell completion paths (`bash-completion`, fish
  `vendor_completions.d`, zsh `site-functions`) are scanned by
  default if the user has a normal shell config.

### Helper API

`lib/module_helper.sh` adds:

```bash
# Unpacks <tarball> into $HOME/.local/lib/init_ubuntu/<NAME>/<VERSION>/,
# swaps `current` symlink, places $HOME/.local/bin/<BIN> symlink.
module_default_user_home_install <name> <version> <tarball-url>

# Reverse: rm versioned dir + defensive symlink removal.
module_default_user_home_purge <name>

# Idempotent upgrade: download new, swap current, rm old.
module_default_user_home_upgrade <name> <new-version> <tarball-url>
```

Archetype B (`module_use_github_release_archetype`) routes to these
when `INIT_UBUNTU_INSTALL_TARGET=user-home`. Authors don't write
path logic by hand.

### Sudo vs user-home dispatch

Archetype helpers branch on `INIT_UBUNTU_INSTALL_TARGET`:

| Target | Archetype A (apt) | Archetype B (github-release) | Archetype C (config-drop) |
|---|---|---|---|
| `sudo` | `sudo apt-get install` | `/opt/<name>` + `/usr/local/bin/<name>` | system paths |
| `user-home` | exit code 4 (apt is sudo-only; `SUPPORTS_USER_HOME=false` enforced) | `$HOME/.local/lib/init_ubuntu/<name>/<version>` | `$HOME/.config/<name>/` |

Archetype A modules with `SUPPORTS_USER_HOME=true` are rare — only
modules whose pkg ships a portable tarball alternative get the
override (e.g. `git` could user-home-install from source — but in
practice we don't).

## Alternatives considered

- **Flat unpack into `$HOME/.local/`** (no `init_ubuntu/` namespace).
  Rejected: collides with user-installed software; uninstall
  ambiguity.
- **One dir per module under `$HOME/.<name>`** (dotfile style).
  Rejected: violates XDG; breaks completion / man auto-discovery.
- **Single version (overwrite on upgrade)**. Rejected: blocks
  rollback-by-symlink-swap; upgrade becomes lossy.

## Consequences

- All archetype-B user-home installs converge on one layout.
  `setup_ubuntu list --installed` for user-home modules can show
  version info by inspecting `current → vX.Y.Z` symlinks.
- Future feature "rollback to previous version" is one symlink swap
  away (versioned dirs are kept until upgrade rm them).
- AC additions:
  - **AC-53:** `setup_ubuntu install eza --install-target=user-home`
    places binary at `$HOME/.local/bin/eza` and unpack at
    `$HOME/.local/lib/init_ubuntu/eza/v<x.y>/`.
  - **AC-54:** `setup_ubuntu purge eza` removes both, leaves
    `$HOME/.local/bin/eza` alone if its symlink target is outside
    `$HOME/.local/lib/init_ubuntu/eza/`.
  - **AC-55:** `setup_ubuntu upgrade eza` keeps the old version dir
    until the new install + verify succeeds; on failure (ADR-0015
    auto-purge runs), the old `current` symlink is preserved.
