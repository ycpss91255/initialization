# Linux-Concepts / Shell-Correctness Review

- Date: 2026-06-23
- Tag: v0.1.0-rc3 (commit b6c88bc), main checkout at /home/cyc/Desktop/initialization
- Lens: Linux/bash correctness + cross-platform portability across the maintainer's
  targets (x86_64 desktop/server, Raspberry Pi 4/5, Jetson, WSL; Ubuntu
  22.04 / 24.04 / 26.04). NOT an architecture or security review (those have
  separate docs; deep security is deferred there).
- Mode: READ-ONLY. No code was modified. This document RAISES problems for the
  maintainer to decide on; it does not resolve them.

Scope note: `.worktree/` agent worktrees were excluded (not part of the
codebase). Coverage spanned the `lib/` engine, the v2 `module/*.module.sh`
modules, the legacy v1 `module/setup_*.sh` + `module/anydesk.sh` + `small-tools/`
scripts, `tool/` helper scripts, the entrypoints, and the github-release
archetype + arch-mapping logic. Findings were verified against the source on
disk and against live upstream release asset names where relevant.

---

## Executive summary

Severity counts:

- CRITICAL: 3
- HIGH: 7
- MEDIUM: 9
- LOW: 8 (plus a sizeable verified-correct list)

Overall the v2 engine (`lib/`) is in good shape: atomic state writes, the
corruption quarantine, jq `--arg`/`--argjson` injection-safety, the
fork-style sub-shell isolation in the runner, the XDG base-dir fallbacks, and
the ADR-0007 `set -uo` vs `set -euo` split are all implemented correctly. The
github-release arch mapping is correct for every one of the maintainer's actual
targets (x86_64 + aarch64) — no module would install a wrong-arch binary on a
stated target.

The three CRITICALs are concentrated where they hurt most for a re-runnable,
multi-platform tool:

1. `backup_file` `log_fatal`-aborts every config-module re-run because
   `BACKUP_DIR` is never set in the v2 path (fish/tmux/neovim).
2. `tool/setup_wayland.sh` sources a path that does not exist — the script is
   100% non-functional on every target.
3. The legacy `module/setup_nvidia_driver.sh` desktop-NVIDIA path is NOT
   Jetson-guarded.

Top 3 by blast radius:

- F1 (CRITICAL) — `backup_file` unset-`BACKUP_DIR` fatal aborts fish/tmux/neovim
  config re-runs/upgrades on ALL targets, all Ubuntu versions.
- F2 (CRITICAL) — `tool/setup_wayland.sh` broken `source` path; aborts
  immediately on ALL targets.
- F3 (CRITICAL) — `module/setup_nvidia_driver.sh` can install a desktop NVIDIA
  driver on a Jetson (aarch64), breaking the L4T BSP.

---

## Findings

### F1 — CRITICAL — `backup_file` aborts config re-runs (BACKUP_DIR never set in v2)

- File:line: `lib/general.sh:268-271` (root cause); callers
  `module/fish.module.sh:85`, `module/tmux.module.sh:84`,
  `module/neovim.module.sh:85`.
- Concept: `set -e` / `exit` semantics inside a function; the `|| true` guard
  cannot catch an `exit`.
- Breakage + target: `backup_file()` does `log_fatal "BACKUP_DIR is not set."`,
  and `log_fatal` is `_logger_print ...; exit 1` (`lib/logger.sh:176`).
  `BACKUP_DIR` is set ONLY in the legacy v1 `module/setup_*.sh` scripts; it is
  never set anywhere in the v2 path (`lib/runner.sh`, `lib/dispatcher.sh`,
  `lib/module_bootstrap.sh`, `setup_ubuntu.sh` — confirmed by grep). On a FIRST
  install the modules guard `backup_file` behind `[[ -d <config> ]]`, so the
  branch is skipped and it works. On any RE-RUN / upgrade where the config
  already exists, `backup_file` runs, sees `BACKUP_DIR` empty, and `exit 1`
  terminates the module sub-shell. The trailing `|| true` does NOT help: the
  `exit` fires inside `backup_file` before `||` is ever evaluated. Affects ALL
  targets, all Ubuntu versions. Re-dropping config on upgrade is a documented
  use case for these modules.
- Contrast (proof it is a real gap): `module/claude-code-config.module.sh:99-103`
  explicitly defaults `BACKUP_DIR` before calling the archetype upgrade,
  with a comment that "backup_file ... log_fatals when BACKUP_DIR is unset."
  fish/tmux/neovim lack that precaution.
- Remediation options (pick one): (a) set/export a default `BACKUP_DIR`
  (e.g. `${state_dir}/backup/<name>`) in `module_bootstrap`/runner before any
  install; (b) default `BACKUP_DIR` in each of fish/tmux/neovim like
  claude-code-config does; (c) make `backup_file` itself default `BACKUP_DIR`
  instead of fataling.
- Confidence: HIGH (log_fatal=exit verified; no BACKUP_DIR in v2 path verified).

### F2 — CRITICAL — `tool/setup_wayland.sh` broken source path; non-functional

- File:line: `tool/setup_wayland.sh:6-8`.
- Concept: relative `source` path resolution.
- Breakage + target: `SCRIPT_PATH` resolves to `tool/`, then it sources
  `${SCRIPT_PATH}/../function/logger.sh` and `../function/general.sh`. There is
  no `function/` directory at the repo root (the helpers live at
  `module/function/` and `lib/`). Verified: `tool/../function` does not exist.
  Under the script's `set -euo pipefail`, the `source` fails and the script
  exits before any logic. Affects ALL targets, all Ubuntu versions.
- Remediation option: repoint the source at the real helper dir
  (`../module/function/` or `../lib/`) consistent with what the script consumes.
- Confidence: HIGH (verified on disk).

### F3 — CRITICAL — `module/setup_nvidia_driver.sh` not Jetson-guarded

- File:line: `module/setup_nvidia_driver.sh` (detection ~line 54; PPA add ~72;
  package install ~105-109).
- Concept: platform detection / wrong-driver-on-Jetson.
- Breakage + target: detection is purely
  `sudo lshw -C display | grep -qi "nvidia"`. On a Jetson (Tegra integrated GPU)
  `lshw` display output commonly contains "NVIDIA Tegra", so this can pass; the
  script then adds `ppa:graphics-drivers/ppa` and installs a desktop
  `nvidia-driver-NNN` + `nvidia-cuda-toolkit`/`nvidia-cudnn`. Desktop proprietary
  drivers must NEVER be installed on Jetson/L4T — it breaks the BSP. No
  `/etc/nv_tegra_release` exclusion and no `uname -m` guard. Affects Jetson
  (aarch64), 22.04/24.04. (The v2 `nvidia-driver.module.sh:42` does this
  correctly with `SUPPORTED_PLATFORMS=("desktop")` + form-factor/container gates;
  this legacy script does not.)
- Remediation option: early-abort when `/etc/nv_tegra_release` exists or
  `uname -m` is `aarch64`; or retire this script in favor of
  `nvidia-driver.module.sh`.
- Confidence: HIGH.

### F4 — HIGH — Migration runs OUTSIDE the state flock (concurrent-write race)

- File:line: `lib/state.sh:254` (state_init called before lock at 261-273);
  `lib/state_migrate.sh:185-214`.
- Concept: locking / critical-section boundary.
- Breakage + target: `_state_locked_write` calls `state_init` (line 254)
  BEFORE opening fd 9 / taking the flock (the lock is acquired only inside the
  subshell). `state_init` -> `_state_run_migration` -> `state_migrate_run`,
  which reads `state.json`, backs it up, and does its OWN unlocked tmp-file +
  `mv`. The per-process `_STATE_MIGRATION_DONE` guard only dedupes within one
  process. Two concurrent `setup_ubuntu` runs (or a TUI fork + CLI) against an
  old-schema state can both pass the version check, both migrate, both `mv`;
  the migrator's `cat "${_path}"` can read a state another process is mid-
  replacing. The whole point of the lock is bypassed for the migration path.
  Affects any host where two invocations overlap. Individual `mv`s are atomic so
  bytes are not torn, but migration logic can run against an already-migrated or
  in-flux file.
- Remediation option: acquire the flock FIRST, then run init/migrate/write
  inside the same lock; or give `state_migrate_run` its own flock and re-check
  the on-disk version after acquiring.
- Confidence: HIGH.

### F5 — HIGH — `dispatcher_dispatch` re-splits argv (`set --` unquoted)

- File:line: `lib/dispatcher.sh:1249`.
- Concept: word-splitting + globbing on an unquoted expansion.
- Breakage + target: `set -- ${DISPATCHER_ARGV[@]+"${DISPATCHER_ARGV[@]}"}` —
  the inner `"${DISPATCHER_ARGV[@]}"` is quoted, but the OUTER expansion is not,
  so the result is subject to a second round of word-splitting and globbing. An
  argv element containing whitespace (`show "my module"`) or a glob char
  (a module name with `* ? [`) gets re-split / glob-expanded. Affects any
  invocation with such arguments, all targets. The safe idiom is used correctly
  elsewhere (e.g. dispatcher.sh:298, 1196).
- Remediation option: `set -- "${DISPATCHER_ARGV[@]}"` (bash 4.4+, i.e. all
  targets, handles empty arrays under `set -u` fine).
- Confidence: HIGH.

### F6 — HIGH — `nvidia-driver.module.sh` upgrade glob never matches; remove glob over-purges

- File:line: `module/nvidia-driver.module.sh:107` (upgrade), `:113` (remove).
- Concept: apt does not shell-glob package names; literal vs apt-pattern.
- Breakage + target: `apt-get install --only-upgrade nvidia-driver-*` — the
  shell does not expand `*` (no matching files in CWD), so apt receives the
  literal `nvidia-driver-*` and errors "Unable to locate package"; with the
  `|| true` it silently no-ops. So `upgrade()` does nothing on desktop targets.
  Separately, `apt-get purge -y 'nvidia-*'` DOES glob inside apt (apt treats it
  as a pattern), so it fires — but it over-purges, removing
  `nvidia-container-toolkit` / `libnvidia-*` runtime libs that
  `setup_docker.sh` installed.
- Remediation option: enumerate installed packages via
  `dpkg-query -W -f='${Package}\n' 'nvidia-driver-*'` and pass the real names;
  scope purge to `nvidia-driver-*`/`nvidia-dkms-*` rather than the catch-all.
- Confidence: HIGH (upgrade no-op); MEDIUM (purge breadth is by-design risk).

### F7 — HIGH — `tool/dual_system_time_sync.sh` deprecated tooling + wrong dual-boot RTC approach

- File:line: `tool/dual_system_time_sync.sh:8-14`.
- Concept: time/RTC management on systemd; deprecated `ntpdate`.
- Breakage + target: `apt-get install -y ntpdate` may fail on 24.04/26.04
  (superseded by `systemd-timesyncd`/`chrony`); on a box already running
  timesyncd, ntpdate can't bind the NTP socket. `hwclock --localtime --systohc`
  for Windows dual-boot is the wrong mechanism: the correct fix is
  `timedatectl set-local-rtc 1 --adjust-system-clock`. Writing localtime via
  raw hwclock while systemd still believes the RTC is UTC causes per-boot drift.
  No `set -euo pipefail`, so a failed ntpdate is ignored and a wrong time is
  written to the RTC. Affects 24.04/26.04 (ntpdate availability) and any
  dual-boot box (RTC mode mismatch).
- Remediation option: replace with `timedatectl set-ntp true` +
  `timedatectl set-local-rtc 1` for the Windows dual-boot case; drop manual
  `hwclock`/`ntpdate`.
- Confidence: MEDIUM-HIGH.

### F8 — HIGH — `module/setup_shell.sh` SSH file typo + create-only-if-dir-missing

- File:line: `module/setup_shell.sh:98-103` (typo at ~102), `:145` (chsh).
- Concept: secrets/SSH file handling + idempotency; `/etc/shells` + `chsh`.
- Breakage + target: (a) filename typo `enviroment` (should be `environment`) —
  the intended `~/.ssh/environment` is never read by ssh/fish. (b) The whole
  `mkdir 700 / touch / chmod 600` block only runs when `~/.ssh` does NOT exist;
  if `~/.ssh` already exists but the file does not, it is never created and
  existing dir perms are never corrected. (c) `sudo chsh -s "$(which fish)"`
  fails if the fish path is not in `/etc/shells`; under `set -euo pipefail`
  that aborts at the end; on WSL the login-shell switch can break the WSL launch
  flow and the prior shell is not backed up. Affects all targets (typo);
  existing-`~/.ssh` users; WSL (UX).
- Remediation option: fix spelling; create/chmod the file independently of the
  dir-existence check; `grep -qx "$(command -v fish)" /etc/shells` (append if
  missing) before `chsh`; skip/opt-in the shell switch on WSL.
- Confidence: HIGH (typo verified at line 102).

### F9 — HIGH — neovim hard-codes x86_64 asset; arm64 targets get NO neovim (also lazygit/eza/yazi)

- File:line: `module/neovim.module.sh:50,71`; same pattern in
  `module/lazygit.module.sh:56,93`, `module/eza.module.sh:72,113`,
  `module/yazi.module.sh:80,125`.
- Concept: arch gating in `detect()` vs available upstream assets.
- Breakage + target: `GITHUB_ASSET_PATTERN` is wired to the x86_64 tarball and
  `detect() { [[ "$(uname -m)" == "x86_64" ]]; }`. On rpi4/rpi5 and Jetson
  (`uname -m`=aarch64) `detect()` returns false, so the module is correctly
  HIDDEN — no crash, no wrong binary. But it means neovim/lazygit/eza/yazi are
  simply UNAVAILABLE on every arm64 target the maintainer uses, even though
  upstream publishes arm64 assets (e.g. `nvim-linux-arm64.tar.gz`). This is a
  silent functional gap, not an error. `SUPPORTED_PLATFORMS` lists platforms,
  not arch, so nothing surfaces the gap to the user.
- Remediation option: add an arch case-map (aarch64 -> the arm64 asset) and
  broaden `detect()` to accept aarch64 (the robust github-release modules
  fzf/gum/lazydocker already do exactly this); OR explicitly document these as
  x86_64-only so the maintainer is not surprised on the Pi/Jetson.
- Confidence: HIGH.

### F10 — HIGH — No `DEBIAN_FRONTEND=noninteractive` anywhere; debconf can hang non-interactive/Docker runs

- File:line: repo-wide (grep for `DEBIAN_FRONTEND` returns nothing); apt sites
  include `lib/general.sh` (`apt_pkg_manager`), `lib/module_helper.sh:124,136`,
  `module/docker.module.sh:116-117`, `module/setup_docker.sh`.
- Concept: apt/debconf interactivity in unattended contexts.
- Breakage + target: any package whose postinst opens a debconf prompt (e.g.
  kernel/keyboard/grub-adjacent pulls, some -dev metapackages) will block on a
  TTY-less run (Docker-based testing, server SSH-without-PTY, sync remote
  invocations). The maintainer's own Docker-only test harness is the most
  exposed. Most of the tools here are quiet, so it is latent rather than
  constant.
- Remediation option: export `DEBIAN_FRONTEND=noninteractive` (and consider
  `APT::Get::Assume-Yes` / `-o Dpkg::Options::=--force-confold` policy) around
  the apt-managed install paths.
- Confidence: MEDIUM (latent; depends on the package set pulled).

### F11 — MEDIUM — `~/.ssh` (and config-drop parent dirs) created with default umask before chmod

- File:line: `lib/module_helper.sh:467` (`mkdir -p "${_dest_dir}"`) then `:480`
  (`chmod CONFIG_DIR_MODE`); reached by `module/ssh-config.module.sh:55-56`.
- Concept: TOCTOU window on directory permissions.
- Breakage + target: the config-drop archetype `mkdir -p`s the dest parent with
  the inherited umask (0755 under umask 022), then tightens to 700 a few lines
  later. There is a window where `~/.ssh` exists at 0755. End-state is correct
  (mode 600 file, 700 dir both ARE enforced via CONFIG_MODE/CONFIG_DIR_MODE).
  Low risk for the single-maintainer personal-use target; matters only on a
  shared/multi-user host.
- Remediation option: `(umask 077; mkdir -p "${_dest_dir}")` or
  `mkdir -p -m 700` for the parent before the copy.
- Confidence: HIGH on mechanism; severity MEDIUM (LOW for the stated use case).

### F12 — MEDIUM — Temp-file leaks on signal (no traps): state, migration, import

- File:line: `lib/state.sh:259,274` (no trap on `${_path}.XXXXXX`);
  `lib/state_migrate.sh:208` (`${_path}.tmp.$$`); `lib/dispatcher.sh:751`
  (`/tmp/init_ubuntu_import_plan.XXXXXX.json`); also the github-release
  archetype `lib/module_helper.sh:339-375` and `module/font.module.sh:70-83`.
- Concept: trap/cleanup correctness.
- Breakage + target: `mktemp` files are removed only on the normal path; a
  SIGINT/SIGTERM between create and cleanup leaves orphans in the state dir or
  /tmp. Not corruption (the `mv`s are atomic), just litter that accumulates
  across interrupted runs. Any target.
- Remediation option: `trap 'rm -f "${_tmp}"' RETURN` (or an EXIT trap scoped to
  a subshell) at each create site.
- Confidence: HIGH.

### F13 — MEDIUM — `logger_prune_logs` active-log exclusion can fail on a relative log path

- File:line: `lib/logger.sh:328-389` (esp. the active-file compare ~line 375).
- Concept: path canonicalization before an equality test.
- Breakage + target: the active-log exclusion compares the glob result
  (`${_dir}/name.jsonl`, possibly `./name.jsonl` when `_dir` is `.`) against
  `${INIT_UBUNTU_LOG_FILE}`. If the log file was given as a bare relative
  filename, the strings differ and the active log is NOT matched — so the
  count/age prune rule could delete the log currently being written. Only
  triggers when `INIT_UBUNTU_LOG_FILE` is a relative bare name (setup_ubuntu
  does not set it that way, so latent). The docstring promises the active log is
  never deleted.
- Remediation option: canonicalize both paths (`readlink -f`) before comparing,
  or compare basenames.
- Confidence: MEDIUM.

### F14 — MEDIUM — `module/setup_docker.sh` pins NVIDIA container toolkit `1.17.8-1`; brittle + socket chmod race

- File:line: `module/setup_docker.sh:115-122` (version pin), `:149-154`
  (manual `chown/chmod` of `/var/run/docker.sock` before restart).
- Concept: hardcoded version pin + systemd-managed socket race.
- Breakage + target: requesting exact `=1.17.8-1` for four packages fails once
  the repo stops serving that version (toolkit moves fast); aarch64 (Jetson)
  version availability differs. The manual `chown root:docker`/`chmod 660` on
  the socket races with `docker.socket`, which recreates the socket on restart;
  on a fresh install the socket may not exist yet, so the `chown` fails (and
  under the legacy script's flow that can abort).
- Remediation option: drop the exact pin (or make it env-overridable with an
  unpinned fallback); rely on `docker.socket` instead of the manual chmod, or
  guard with `[[ -S /var/run/docker.sock ]]`.
- Confidence: MEDIUM.

### F15 — MEDIUM — `module/setup_nvidia_driver.sh` pipx-from-git without `git` dep / PEP 668 handling

- File:line: `module/setup_nvidia_driver.sh:128`.
- Concept: pip on externally-managed environments (PEP 668).
- Breakage + target: `pipx install git+...nvitop` needs `git` (not in the dep
  list) and assumes pipx is present. The well-engineered
  `jetson-stats.module.sh:200-234` detects PEP 668 and falls back pip<->pipx;
  this legacy script does not. Fails on hosts without git.
- Remediation option: install from PyPI (`pipx install nvitop`) and ensure git
  is a dep if the git URL is kept.
- Confidence: MEDIUM.

### F16 — MEDIUM — `_claude_config_localize` sed rewrite is too broad

- File:line: `module/claude-code-config.module.sh:181` (applied at :141, :196).
- Concept: over-broad substitution.
- Breakage + target: `s#/home/[A-Za-z0-9._-]+#${HOME}#g` rewrites EVERY
  `/home/<name>` in the file, not just the template author's. A legitimate
  reference to another user's `/home/otheruser/...` path gets clobbered to
  `$HOME`. Also drives `is_outdated` drift detection, which only converges when
  all home paths equal `$HOME`. (`$HOME` on Ubuntu has no `#`, so the `s#...#`
  delimiter is safe in practice.)
- Remediation option: anchor the rewrite to the known template-author prefix,
  or use a sentinel placeholder in the template instead of a real `/home/...`.
- Confidence: MEDIUM.

### F17 — MEDIUM — Network-dependent installs report success on partial failure (fish plugins, fonts)

- File:line: `module/fish.module.sh:92-107` (`_install_fisher_plugins`),
  `module/font.module.sh:67-84` (+ `is_installed` at `:53-58`).
- Concept: error handling / idempotency under flaky network.
- Breakage + target: both swallow failures (`|| log_warn ... return 0`,
  `continue`), so a transient network failure yields a "successful" install
  with missing plugins/fonts and no non-zero exit. The font `is_installed`
  only checks the directory exists, so a dir left by a failed `unzip` reports
  installed-but-empty. Most likely on rpi/Jetson behind flaky networks.
  (`unzip -qo` overwrite makes re-runs idempotent — that part is fine.)
- Remediation option: have font `is_installed` require at least one
  `*.ttf`/`*.otf`; surface plugin/font failures as a non-zero or recorded
  degraded state.
- Confidence: HIGH on mechanism.

### F18 — MEDIUM — `fish chsh` / default-shell uses `${USER}`; WSL caveat

- File:line: `module/fish.module.sh:114`.
- Concept: environment assumptions (`$USER` not always set) + WSL shell switch.
- Breakage + target: `sudo chsh -s "${_fish_path}" "${USER}"` — `$USER` is not
  guaranteed in non-login/`su`/CI contexts; if empty, `chsh` targets the wrong
  user or errors. On WSL the default-shell change often does not take effect
  for the WSL launch flow, so the "open a new terminal" hint is misleading.
- Remediation option: use `$(id -un)` instead of `${USER}`; add a WSL note that
  the default shell may need `wsl.conf`/relaunch.
- Confidence: MEDIUM.

### F19 — MEDIUM — `tool/setup_terminal_font_size.sh` unvalidated input into sed; meaningless on WSL/headless

- File:line: `tool/setup_terminal_font_size.sh:5-12`.
- Concept: input validation at a system boundary.
- Breakage + target: a `read` value is interpolated straight into a `sed`
  replacement against `/etc/default/console-setup`; a value with `/` or sed
  metacharacters corrupts the substitution, and a malformed entry can break
  console-setup on next boot. `setupcon` is Linux-VT only — meaningless on WSL
  (no VT) and headless servers.
- Remediation option: validate against `^[0-9]+x[0-9]+$`; skip on WSL/no-VT.
- Confidence: MEDIUM.

### F20 — LOW — Legacy `module/anydesk.sh` + `small-tools/` use `apt` (not `apt-get`) in scripts; no `set`

- File:line: `module/anydesk.sh:3,4,21,22`; `small-tools/install.sh` (many).
- Concept: apt CLI stability + missing strict mode.
- Breakage + target: apt itself warns "do not use apt in scripts" (its CLI is
  unstable across releases and emits a progress-bar/format that can change);
  `apt-get`/`apt-cache` are the scripting interfaces. These legacy scripts also
  have no `set -euo pipefail`, so failures chain silently. AnyDesk's repo
  (`deb.anydesk.com ... all main`) is amd64/i386 only — no arm64 — so a manual
  install on an aarch64 desktop-classified box fails at apt.
- Remediation option: migrate to `apt-get`; add strict mode; gate AnyDesk on
  `dpkg --print-architecture` = amd64. (Lower priority since these are the
  pre-v2 generation; the v2 `module/anydesk.module.sh` is the maintained path.)
- Confidence: HIGH on the apt-in-scripts point.

### F21 — LOW — codex / zoxide build the asset name unconditionally; standalone install bypasses detect()

- File:line: `module/codex.module.sh:60-64`; `module/zoxide.module.sh:63,160`.
- Concept: arch validation only in `detect()`, not in `install()`.
- Breakage + target: both compute `GITHUB_ASSET_PATTERN` from raw `uname -m`
  at source time. For the maintainer's targets (x86_64/aarch64) this is exactly
  correct (codex/zoxide musl triples use those literal tokens). On an
  unsupported arch (armv7l) `detect()` correctly hides them in ENGINE mode, but
  a STANDALONE `bash module/<x>.module.sh install` does not call `detect()`
  first and would attempt a 404 download. Contained (the shared gzip/HTTP sniff
  turns it into a loud failure, not a wrong binary) and armv7l is outside the
  stated targets.
- Remediation option: have `install()`/`upgrade()` short-circuit on `! detect()`,
  or use an explicit arch case-map like fzf/gum/lazydocker.
- Confidence: HIGH.

### F22 — LOW — `cp -r src dest` re-run nesting (fish/neovim) once F1 is fixed

- File:line: `module/fish.module.sh:88`, `module/neovim.module.sh:88`.
- Concept: `cp -r` into an existing directory copies INTO it.
- Breakage + target: on a re-run where dest exists, `cp -r src dest` produces
  `dest/src/...` nesting. Currently masked by F1 (the `backup_file` abort fires
  first). If F1 is fixed without an `rm -rf dest` (or `cp -rT`/`cp -a` replace
  semantics) first, re-runs would create `~/.config/fish/fish/...`.
- Remediation option: `rm -rf "${dest}"` before `cp -r`, or `cp -rT`.
- Confidence: MEDIUM (currently latent).

### F23 — LOW — `module/setup_shell.sh` / `small-tools` `chsh -s "$(which fish)"` + `/etc/ssh` sed edits

- File:line: `small-tools/install.sh:143,166-167`.
- Concept: idempotency of system-file sed edits + `/etc/shells`.
- Breakage + target: the `sed -i` toggles on `/etc/ssh/ssh_config`
  (`ForwardX11`, `AllowTcpForwarding`) are not marker-guarded and edit a global
  config; re-runs are mostly idempotent (the regex only matches commented
  lines) but there is no backup. `chsh` `/etc/shells` concern as in F8.
- Remediation option: back up `/etc/ssh/ssh_config` before editing; verify the
  fish path is in `/etc/shells`. (Legacy generation; low priority.)
- Confidence: MEDIUM.

### F24 — LOW — JSON numeric coercion in logger can emit invalid JSON for leading-zero values

- File:line: `lib/logger.sh:211-303` (numeric regex `^-?[0-9]+$`).
- Concept: JSON number validity.
- Breakage + target: a value like `007` matches the numeric regex and is emitted
  as a bare `007`, which is invalid JSON. Unlikely in practice (the attribute
  values here are durations/exit codes/counts). Any target if such a value ever
  flows through.
- Remediation option: only treat as a number when it has no superfluous leading
  zero, else quote it.
- Confidence: HIGH that it is theoretical.

### F25 — LOW — `tool/copy_neovim_local_config.sh` destructive backup + missing-source; marked unfinished

- File:line: `tool/copy_neovim_local_config.sh:3` (`#TODO: wait review`),
  `:18-22`.
- Concept: backup race + missing-source handling.
- Breakage + target: `mv config config.bak || true` clobbers any prior
  `config.bak` (no timestamp) and continues if `config` is absent; the
  subsequent `cp -r "${USER_CONF_DIR}/user"` has no source-exists check, so
  under `set -euo pipefail` a missing source aborts after the backup was moved,
  leaving no `config`. `TARGET_USER_DIR` is computed but unused.
- Remediation option: guard the source path before `mv`; timestamp the backup;
  remove the unused var. Header says it is awaiting review.
- Confidence: MEDIUM.

### F26 — LOW — `tool/copy_gnome_terminal_config.sh` no shebang/`set`; dump-then-load is a no-op; GNOME-only

- File:line: `tool/copy_gnome_terminal_config.sh:1-4`.
- Concept: script structure / sequencing.
- Breakage + target: no shebang, no `set`; it dumps then immediately loads from
  the same just-written backup (effectively a no-op as written). GNOME-only
  (irrelevant on WSL/headless/Wayland-only).
- Remediation option: split dump vs load, or gate load behind an argument.
- Confidence: HIGH.

### F27 — LOW — `tool/trash-maintenance.sh` `read` loop breaks on filenames with newlines

- File:line: `tool/trash-maintenance.sh:42`.
- Concept: NUL- vs newline-delimited iteration.
- Breakage + target: the `find ... | sort | cut | while IFS= read -r` loop uses
  newline as the delimiter; a trashed filename containing a newline would split
  the record. The script is otherwise solid (`set -euo pipefail`, `rm -rf --`,
  env-overridable caps). Low likelihood.
- Remediation option: use `-printf '...\0'` / `read -d ''` NUL delimiting.
- Confidence: HIGH.

---

## Verified correct (coverage the maintainer can rely on)

Engine / libs:

- ADR-0007 `set` convention is applied correctly: always-act entrypoints
  (`setup_ubuntu.sh:11`, `setup_secrets.sh:25`) use `set -euo pipefail`;
  exit-code-contract scripts (`setup_ubuntu_tui.sh:22`, the hooks,
  `release-tag.sh:25`) use `set -uo pipefail`. The libs declare no `set` flags
  and inherit the entrypoint's strict mode — not masking errors.
- `lib/state.sh` atomic write: jq output to a same-dir `${_path}.XXXXXX` temp,
  then `mv` (atomic rename) under an flock. Lock-free readers never see a torn
  state. The `( ... ) 9>>lock; _rc=$?` pattern correctly captures the subshell
  exit under `inherit_errexit`. flock-without-`-w` busybox fallback (polling
  `flock -n` with a `SECONDS` deadline) is correct.
- Corruption guard (`state.sh:122-143`): quarantine-then-fail, never a silent
  rebuild. Migration backup-before-mutate (`state_migrate.sh`) is mandatory and
  aborts before touching the original.
- jq injection safety: all module/user data flows through `--arg`/`--argjson`
  (state.sh, state_io.sh, dispatcher.sh). No string interpolation into filters.
  Consistently applied.
- `lib/logger.sh` JSON hand-assembly escapes `\`, `"`, newline, CR, tab in the
  correct order (backslash first); the closing braces are balanced.
- XDG base-dir fallbacks are correct everywhere: `XDG_STATE_HOME` ->
  `~/.local/state`, `XDG_CONFIG_HOME` -> `~/.config`, all under `init_ubuntu/`.
- Empty-array `"${arr[@]}"` expansions are safe under `set -u` on the targets
  (Ubuntu 22.04 bash 5.1 / 24.04 bash 5.2, both >= 4.4); hot spots additionally
  use the `${arr[@]+...}` guard.
- `lib/runner.sh` fork-style `( ... )` sub-shell isolation (rather than
  `bash -c`) keeps `set -u` + kcov coverage instrumentation happy and scopes
  module side effects; the phase exit code is captured explicitly and not
  overwritten by the post-emit block.
- `lib/preflight.sh` sudo detection (root / passwordless / interactive-TTY) and
  the `sudo -n true` probe are correct.
- `lib/secrets.sh`: secrets travel via stdin/stdout pipes only (never argv,
  never history); the passphrase rides the openssl child env via `-pass env:`;
  encrypted-file dir is `umask 077` + `chmod 700`, the `.enc` is written to a
  temp then `mv`-renamed and `chmod 600`. `read -rs` on `/dev/tty`. Name
  validation rejects path separators / dot-dot / leading dashes. Backend
  autoselect (pass -> gnome-keyring -> encrypted-file) is sound.
- `setup_secrets.sh` ssh-key generate: `( umask 077; mkdir -p ~/.ssh )`,
  delegates passphrase entry to ssh-keygen's own TTY prompt; remove path is
  traversal-guarded under `~/.ssh`.
- `lib/sync.sh`: hardened SSH opts (`StrictHostKeyChecking=yes`, `BatchMode=yes`,
  `PasswordAuthentication=no`, `ConnectTimeout=10`); payload carries no secrets;
  remote-without-tool is a hard stop (exit 7) with a bootstrap hint rather than
  auto-rsync. mktemp + cleanup on the push/pull temp files.

github-release arch mapping (verified against live upstream asset names):

- fzf (`amd64`/`arm64`/`armv7`), gum (`x86_64`/`arm64`/`armv7`), lazydocker
  (`x86_64`/`arm64`/`armv7`/`armv6`) use explicit case-maps, fail loudly on
  unsupported arch, gzip-sniff the download, and gate `detect()` on the map.
  Robust across x86_64 and aarch64 (rpi4/rpi5/Jetson/ARM-WSL).
- codex (`x86_64`/`aarch64` musl) and zoxide (`x86_64`/`aarch64` musl) pass
  `uname -m` straight through, which is exactly correct for the maintainer's
  targets because those upstream triples use the raw `uname -m` tokens.
- notion `.deb` maps `x86_64`->amd64, `aarch64`->arm64; gates to the `desktop`
  form factor (correct). claude-code and fnm delegate arch to their upstream
  install scripts, which ship x64+arm64 Linux builds; their `detect()` arch
  lists match. No module would install a wrong-arch binary on any stated target.

Modules:

- `git.module.sh` (pure apt archetype), `git-config.module.sh` (drops a
  `~/.gitconfig` file, never runs `git config --global`, so it cannot clobber
  individual user values; ships no hardcoded identity), `vscode.module.sh`
  (modern deb822 source + dearmored keyring under `/etc/apt/keyrings`,
  `Architectures: amd64,arm64,armhf`, idempotent keyring fetch),
  `claude-code-config.module.sh` (JSON marker avoidance so no `#` is injected
  into JSON; correct 755/644 modes; defaults BACKUP_DIR — the one module that
  handles F1 correctly).
- fish config files (`config.fish`, `conf.d/*.fish`) use correct fish syntax
  (no bash leaking in); `fish_add_path` is idempotent (no duplicate-append).
- `jetson-stats.module.sh` is correctly Jetson-scoped (`detect()` on form-factor
  OR `/etc/nv_tegra_release`; PEP 668-aware pip<->pipx fallback). `font.module.sh`
  upgrade uses `rm -rf "${_FONTS_DIR:?}/..."` (the `:?` guard prevents
  `rm -rf /`).
- `module/setup_docker.sh` arch (`dpkg --print-architecture`) and codename
  (`${UBUNTU_CODENAME:-$VERSION_CODENAME}`) detection is robust across
  22.04/24.04/26.04. `install-nvidia-driver.sh` (upstream nvitop installer)
  correctly refuses WSL and non-Ubuntu, and uses correct raw-TTY `getc` +
  EXIT-trap display-manager restart; it is x86-desktop-oriented and fails late
  (rather than mis-installing) on aarch64.

---

## Open questions for the maintainer

1. F1/F9 priority: F1 (BACKUP_DIR fatal) silently breaks config re-runs today;
   F9 (arm64 neovim/lazygit/eza/yazi gap) silently denies those tools on the
   Pi/Jetson. Both are "silent" — do you want them fixed before tagging 0.1.0
   final, or documented as known limitations for the RC?

2. Legacy v1 scripts (`module/setup_*.sh`, `module/anydesk.sh`, `small-tools/`,
   several `tool/*.sh`): F2, F3, F6, F7, F8, F15, F20, F23, F25, F26 all live in
   this pre-v2 generation. Are these still in the supported surface for 0.1.0,
   or slated for removal/migration to the module archetype? Your answer changes
   the severity of roughly half this report.

3. armv7l (32-bit ARM): not in your stated targets, but several modules
   partially handle it (fzf/gum/lazydocker map it; codex/zoxide build a 404
   name behind `detect()`). Do you ever run a 32-bit Pi userland, or is
   aarch64-only a safe assumption so the armv7l edges can be ignored?

4. Ubuntu 26.04: the v2 templates/modules list `26.04` in `SUPPORTED_UBUNTU`,
   but is 26.04 actually validated yet, or aspirational? `jetson-stats` omits
   26.04 (likely correct given L4T cadence) — confirm that is intentional.

5. DEBIAN_FRONTEND (F10): do you want a global `noninteractive` default around
   the apt paths, given Docker-only testing is the most exposed to debconf
   hangs?

6. State concurrency (F4): do you ever run two `setup_ubuntu` invocations (or a
   TUI fork plus a CLI) against the same machine concurrently? If single-run is
   guaranteed, F4 drops to LOW.
