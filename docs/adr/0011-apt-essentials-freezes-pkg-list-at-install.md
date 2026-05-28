# ADR-0011: apt-essentials installs a universal devel pkg list, filtered by compatibility, frozen at install

- **Status:** Accepted
- **Date:** 2026-05-20
- **Revised:** 2026-05-20 (premise corrected: this repo targets devel
  platforms across all form factors; platform variation is
  compatibility-only, not use-case-based)

## Context

`apt-essentials.module.sh` is the module that lays down the universal
devel toolchain expected on every machine `init_ubuntu` runs on.

The original PRD §6.1 framing treated this as a use-case split
(desktop gets `build-essential` / `htop` / `unzip` / `jq`; server
gets a minimal set). That framing was wrong: **every machine this
repo touches is a devel platform** — workstation, laptop, RPi,
Jetson, WSL. A user who runs `setup_ubuntu` on an RPi is using it as
a dev box, not as a thin appliance. They want `htop`, `build-essential`,
`jq` etc. just as much as on a desktop.

The only legitimate reason to *omit* a package on a given platform
is:

1. **Hard incompatibility** — the package doesn't build / install on
   that architecture (rare for the essentials set).
2. **Functional duplication** — another module installs the same
   capability with a better-fitting binary on that platform.

This corrected premise leaves a much smaller platform-dependent
variation. But the freezing mechanism still has value: it pins the
exact pkg set installed against this host so `is_installed` /
`upgrade` are deterministic across reboots, sessions, and any later
detection drift.

## Decision

**One universal devel pkg list. Platform filter excludes only
incompatibles. Freeze the resolved list at install time.**

### Universal devel base

```
git vim curl wget ca-certificates
build-essential htop unzip jq software-properties-common
```

Same list across desktop, server, RPi, Jetson, WSL by default.

### Compatibility filter

Engine applies a known-incompatibility map before the install call.
Examples:

| Platform | Excluded | Reason |
|---|---|---|
| `container` | `build-essential` (typically) | image bloat; rebuild from `Dockerfile` if needed |
| `wsl` | (none currently) | — |
| `jetson-orin` | (none currently) | Jetson SDK ships these |

This map lives next to the module (`apt-essentials.module.sh` global
array `INCOMPAT_BY_PLATFORM`). Adding an exclusion is a single-line
edit.

### State shape (apt-essentials only)

```json
"apt-essentials": {
  "manual": true,
  "depends_on": [],
  "frozen_pkgs": ["git", "vim", "curl", "build-essential", "htop", "..."],
  "frozen_platform": "rpi-5"
}
```

`frozen_pkgs` records what was actually installed (after compat
filter). `frozen_platform` is a diagnostic breadcrumb showing where
this state was generated.

### Lifecycle behaviour

| Function | Behaviour |
|---|---|
| `install` | Detect platform. Apply compat filter to universal list. Install resulting set. Write `frozen_pkgs` + `frozen_platform`. |
| `is_installed` | `dpkg -l ${frozen_pkgs[*]}` all present. |
| `is_outdated` | `apt list --upgradable` against `frozen_pkgs`. |
| `upgrade` | Use `frozen_pkgs`. Do not redetect platform. |
| `remove` / `purge` | Remove `frozen_pkgs`. |
| `verify` | All `frozen_pkgs` present + `apt --version` works. |
| `doctor` | Compare current platform's universal-minus-compat list vs `frozen_pkgs`. Warn on drift (no auto-fix). |

### Sync interaction

ADR-0013 says "remote wins on version". Since the universal pkg list
is the same across platforms, `frozen_pkgs` rarely differs between
peers. Sync pull applies the remote `frozen_pkgs` directly via the
normal install pipeline; the local install() re-applies the compat
filter and discards anything the local platform can't handle. Net
effect: convergence to the universal set, locally pruned for
compatibility.

### When the universal list grows

Adding a package to the universal base is a metadata edit in
`apt-essentials.module.sh`. On next `setup_ubuntu upgrade
apt-essentials`, the new pkg is installed and `frozen_pkgs` is
updated. No re-detect or re-freeze of platform.

## Alternatives considered

- **Use-case-based variation (original ADR-0011 draft).** Rejected:
  framing was wrong. RPi-as-dev-box and desktop-as-dev-box want the
  same essentials.
- **No freeze, recompute every call.** Rejected: `is_installed`
  becomes nondeterministic if the platform detector flips between
  sessions (headless reboot after GNOME install).
- **Monotonic add-only.** Rejected: drift not catchable by `doctor`
  without a baseline.

## Consequences

- One module (`apt-essentials`) carries the `frozen_pkgs` /
  `frozen_platform` fields. Engine treats them as opaque to other
  code paths.
- Sync conflict (Q14 in this session) dissolves: `frozen_pkgs`
  rarely diverges between peers, and where it does (compat-driven)
  the local install pipeline self-corrects via the compat filter.
- Platform switches no longer require `purge + install` for
  apt-essentials in typical cases — the same list applies. Only
  matters when compat filter previously excluded something that the
  new platform now supports.
- AC additions:
  - **AC-36:** Installing apt-essentials on RPi writes
    `frozen_platform = "rpi-5"` and `frozen_pkgs` includes `htop`,
    `build-essential`, `jq`.
  - **AC-37:** Adding a pkg to apt-essentials' universal list and
    running `setup_ubuntu upgrade apt-essentials` updates
    `frozen_pkgs` and installs the new pkg.
  - **AC-37b:** Sync pull of apt-essentials from a peer whose
    `frozen_pkgs` includes a pkg in the local compat-exclude list
    silently skips that pkg (local compat filter wins).
