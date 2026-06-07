# ADR-0020: nvidia-driver snapshot + restore mechanism (v1.0)

- **Status:** Proposed (v1.0 scope per PRD §13.1 Q9 / AC-21)
- **Date:** 2026-05-21

## Context

PRD §13.1 Q9 / AC-21 deferred automatic nouveau-restore on
nvidia-driver install failure to v1.0. The default ADR-0015
auto-purge-on-verify-failure flow doesn't suffice for nvidia
because `install()` performs irreversible-ish boot-path mutations:

- `apt purge` of `xserver-xorg-video-nouveau` (removes the
  fallback driver — boot may not have a graphics backend)
- `apt install` of `nvidia-driver-<ver>` (replaces kernel module
  loading config)
- `update-initramfs -u` (regenerates initramfs, GRUB sees the new
  driver on next boot)

If verify fails after these steps and the system reboots before
recovery, the user lands on a black screen with no graphical TTY.

This needs to be designed *now* even though implementation is
deferred — designing under pressure post-incident is worse than
designing during planning.

## Decision

### Pipeline (extends ADR-0015 for high-risk modules)

For modules with `RISK_LEVEL=high` AND `REBOOT_REQUIRED=true`,
`install()` follows this extended pipeline:

```
1. emit install_start (trace_id)
2. snapshot() — module-specific; freezes environment to disk
3. install() — mutates the system
4. verify() — checks the install actually works
5. if verify fails:
     - emit verify_failed
     - call restore() — module-specific reverse-of-snapshot
     - emit install_failed (cause: "verify_failed_restored")
     - exit 6
6. write state.json.installed.<m>
7. emit install_done with reboot_required_hint
```

`snapshot()` and `restore()` are new lifecycle hooks **only required**
for high-risk + reboot-required modules. Other modules use the
ADR-0015 default (`purge()` as rollback).

### Snapshot scope (nvidia-driver)

`snapshot()` captures into `${XDG_STATE_HOME}/init_ubuntu/snapshots/nvidia-driver/<timestamp>/`:

- `/etc/modprobe.d/blacklist*.conf` (any blacklist files)
- `/etc/default/grub` (kernel cmdline contains driver hints)
- `lsmod-before.txt` (currently loaded modules)
- `dpkg-list-graphics.txt` (`dpkg -l | grep -E 'nouveau|nvidia|xserver-xorg-video'`)
- `apt-mark-showmanual-graphics.txt` (which graphics pkgs were
  manually marked)
- `recovery-instructions.md` (pre-rendered text for user to read
  if automatic recovery fails)

Total snapshot size: < 1MB.

### Restore (nvidia-driver)

`restore()` reverses the snapshot:

```
1. apt purge nvidia-driver-* (remove nvidia)
2. cp <snapshot>/blacklist*.conf /etc/modprobe.d/  (restore blacklists)
3. cp <snapshot>/grub /etc/default/grub             (restore boot params)
4. apt install -y xserver-xorg-video-nouveau         (reinstall nouveau)
5. apt mark using snapshot's apt-mark file
6. update-initramfs -u                               (regenerate initramfs)
7. update-grub                                       (regenerate grub.cfg)
8. verify nouveau loaded: `modinfo nouveau >/dev/null`
```

### Snapshot location

`${XDG_STATE_HOME}/init_ubuntu/snapshots/<module-name>/<iso-timestamp>/`

Multiple snapshots accumulate. v1.0 ships no auto-prune; user
manages via `doctor --fix` (which can list and prompt for cleanup)
or manually.

### Restore failure handling

If `restore()` itself fails partway:

1. Do NOT silently continue.
2. Print pre-rendered `recovery-instructions.md` content (boot from
   GRUB recovery, mount root, run specific cmds).
3. Exit code 7.
4. state.json does not record the install (preserves
   two-state invariant from ADR-0015).
5. User must follow the recovery instructions manually.

### Post-install reboot warning

Install success path emits an unmissable warning:

```
nvidia-driver installed. Reboot REQUIRED to switch from nouveau
to nvidia.

If the new driver fails after reboot (black screen, no DM):
  1. At GRUB menu, select "Ubuntu, with Linux ... (recovery mode)"
  2. From recovery menu, choose "network — Enable networking"
  3. Choose "root — Drop to root shell prompt"
  4. Run: setup_ubuntu purge nvidia-driver
  5. Reboot — system returns to nouveau.

The pre-install snapshot is at:
  ${XDG_STATE_HOME}/init_ubuntu/snapshots/nvidia-driver/<ts>/
Manual restore script: <snapshot>/restore.sh
```

`restore.sh` is generated as part of snapshot — runnable standalone
without `setup_ubuntu` engine present, in case the system is too
broken to source helpers.

### Standalone restore script

The snapshot directory contains `restore.sh` — a self-contained
bash script (no source-from-lib dependencies) that re-runs the
same restore logic. User can:

```
bash ${XDG_STATE_HOME}/init_ubuntu/snapshots/nvidia-driver/<ts>/restore.sh
```

from any TTY / recovery shell. This is the "break glass" path when
the engine itself is unreachable.

## Alternatives considered

- **No snapshot, only `purge()` as rollback (ADR-0015 default).**
  Rejected for nvidia: `purge()` removes nvidia but doesn't
  re-install nouveau / restore initramfs. User left without a
  graphics driver.
- **Snapshot via LVM snapshot or btrfs subvolume.** Rejected:
  filesystem dependency; not portable across Ubuntu installs.
- **Skip the install entirely if RISK_LEVEL=high + can't snapshot.**
  Rejected: defeats the purpose of having the module.
- **Snapshot only the apt state, not boot configs.** Rejected:
  `update-initramfs` and `update-grub` need the pre-state to
  reverse cleanly.

## Consequences

- Two new lifecycle hooks (`snapshot`, `restore`) become part of
  the module contract for `RISK_LEVEL=high + REBOOT_REQUIRED=true`
  modules. Currently only `nvidia-driver` qualifies. ADR-0002 (10
  mandatory functions) is not violated — these are conditional
  add-ons, not new mandatory members of the 10.
- Disk usage: snapshots accumulate (~1MB each). Acceptable for now;
  add prune policy in v1.x if it becomes a problem.
- v1.0 ship gate (AC-21): nvidia install failure auto-restores
  nouveau, system still boots. Includes the standalone
  `restore.sh` self-contained recovery path.
- AC additions (all v1.0):
  - **AC-62 (v1.0):** Failed nvidia-driver install with verify
    fail leaves nouveau loaded and system bootable.
  - **AC-63 (v1.0):** `${XDG_STATE_HOME}/init_ubuntu/snapshots/nvidia-driver/<ts>/restore.sh`
    runs standalone with no `setup_ubuntu` dependencies.
  - **AC-64 (v1.0):** If `restore()` fails, exit 7 and
    `recovery-instructions.md` content printed to stderr.
