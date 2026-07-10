# Changelog

All notable changes to `init_ubuntu` are documented here.

The format is based on
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).
This project adheres to [Semantic Versioning 2.0.0](https://semver.org/),
with project-specific bump rules (see `doc/process/release.md`):

- **X bump** (`v1.0.0`, `v2.0.0`) — ceremonial; requires explicit user ACK.
- **Y bump** (`v0.1.0`, `v0.2.0`) — features + breaking changes; requires
  `vX.Y.0-rcN` tag with passing CI before promotion to `vX.Y.0`.
- **Z bump** (`v0.1.1`, `v0.1.2`) — bug fix only; no RC, no ACK.

PR-time CHANGELOG entries: add to `[Unreleased]` as part of the change PR,
not deferred to release. `release-tag.sh` promotes `[Unreleased]` →
`[vX.Y.Z] - YYYY-MM-DD` automatically.

---

## [Unreleased]

### Changed

- **`install`/`remove`/`purge` now hard-error on `--force` and `--with-orphans`
  instead of silently ignoring them** (`lib/dispatcher_lifecycle.sh`): both flags
  carry destructive intent, and their real semantics (ADR-0012 soft/hard filter,
  ADR-0010 forward-dep orphan scan) are design-accepted but not built. Rather
  than accept a destructive-intent flag and no-op it, the dispatcher now exits 2
  with a clear "not yet implemented" message. Other unbuilt lifecycle flags
  (`--base` / `--recommended` / `--all-base` / `--category=` / `--install-target=`
  / `--profile=`) keep their non-destructive stub-warn behavior. Covered by new
  `test/unit/dispatcher_spec.bats` cases.
- **Retired the dead apt-essentials state migration and freeze machinery**
  (`lib/state_migrate.sh`, `lib/state.sh`): the `0.1.0 -> 0.2.0` apt-essentials
  split migration (and its ADR-0011 `frozen_pkgs` / `frozen_platform` handling)
  was removed — schema 0.1.0 was never released, so no on-disk state carries it,
  and no live module uses freeze. The forward-only migration FRAMEWORK (ADR-0008:
  chain + mandatory backup + replay + atomic write) is kept intact and now ships
  with no migration hops, ready for the first real future migration. Specs
  (`state_migrate_spec.bats`, `state_interface_spec.bats`) now exercise the
  framework with a synthetic in-shell hop instead of the retired one.

### Documentation

- **ADR honest-marking + back-link sweep** (`doc/adr/`): adopted the convention
  that "Accepted" means implemented and every design-accepted-but-unbuilt
  decision carries a visible Deferred marker. Reconciled ADRs 0001, 0003, 0005,
  0006, 0007, 0010, 0011, 0012, 0013, 0014, 0015, 0016, 0017, 0018, 0019, 0022,
  0024, 0025, and 0027 with the shipped code (Deferred markers, back-links,
  renamed `file` secrets backend to `encrypted-file`, recalibrated the bash->
  Python triggers from LOC to qualitative, corrected AC-43, fixed the ADR-0024
  cross-reference, and more).

- **Restored the merged unit-coverage AC-17 gate above 80%** (`test/unit/module/custom-hosts-sync_spec.bats`,
  `test/unit/config_spec.bats`, `test/unit/state_io_spec.bats`,
  `test/unit/tui_backend_branches_spec.bats`, plus `kcov-exclude` markers in
  `lib/config.sh` / `lib/state_io.sh` / `lib/tui_backend.sh`): merged unit
  coverage had slipped to 79.89% after narrow-matrix PR merges landed
  undercovered code (those runs report coverage but do not enforce the gate).
  New behavioral unit tests exercise the previously-untested lifecycle of the
  `custom-hosts-sync` module (`detect` / `upgrade` / `remove` / `purge` /
  `verify` / `is_outdated` / `doctor`, network + systemd boundary stubbed) —
  taking that module from 57.9% to ~94% — and cover the library source-guard
  and jq-unavailable branches of `lib/config.sh` / `lib/state_io.sh` and the
  `lib/tui_backend.sh` source guard. The awk/jq program bodies in those three
  libs are wrapped in the repo's existing `kcov-exclude` markers because kcov
  cannot trace lines executed inside an awk/jq subprocess (it counts every such
  string-literal line as never-hit, the same artifact the i18n data tables are
  already excluded for) — their behaviour stays covered through the public
  interface. Also regenerated the drifted module count in `doc/module/INDEX.md`
  (45 -> 46) that a prior narrow-matrix merge left stale.
- **`claude-ls` session helper enumerates directory-type sessions and emits
  per-session metadata** (`module/config/fish/_claude_sessions.py`, issue #161):
  the helper now visits UUID-named session *directories* (subagent runs with
  `subagents/*.meta.json` + `subagents/agent-*.jsonl` but no top-level
  `<uuid>.jsonl`), enriching cwd / model / timestamps / size / message count
  from the subagent transcripts, and every record — file-type and
  directory-type alike — now carries `last_epoch`, `message_count`,
  `size_bytes`, `model`, and `cwd` for the `-l` detail view. File-type
  (`*.jsonl`) sessions are unchanged and deduped by session id so nothing is
  double-counted. The test image (`dockerfile/Dockerfile.test-tools`) gains
  `python3` so the helper can be unit-tested under the Docker-only gate.

### Security

- **Hardened the github-release fetch/extract path** (`lib/module_helper.sh`
  plus `module/fzf.module.sh` / `module/yazi.module.sh` /
  `module/lazydocker.module.sh`), per the security review (`doc/review/security-review.md`):
  - **SR-01 (HIGH) — production-reachable test seam closed.** The offline test
    seams `INIT_UBUNTU_TEST_GH_FIXTURE_DIR` / `INIT_UBUNTU_TEST_GH_VERSION` were
    gated only on the variable being non-empty, so a poisoned env (rc file,
    env-preserving sudo policy, compromised parent) could swap the install
    payload with no test harness present. They now activate ONLY when the
    dedicated `INIT_UBUNTU_TEST_MODE=1` flag is set — a signal production never
    sets and the bats harness always does. A fixture var set without the flag is
    ignored (a warning is logged) and the real download runs.
  - **SR-02 (MEDIUM) — safe archive extraction.** A shared
    `_module_safe_tar_extract` / `_module_safe_unzip_extract` pair (backed by a
    directly-testable `module_archive_members_safe` guard) now rejects any
    archive member with an absolute path or a `..` component before extracting,
    and root `tar` extraction passes `--no-same-owner --no-same-permissions` so a
    malicious/MITM archive cannot restore archived owner/uid/setuid bits or
    escape `INSTALL_DIR`. Wired into the shared archetype default and the
    fzf/yazi/lazydocker direct fetchers.
  - **SR-03 (MEDIUM) — best-effort SHA-256 verification.** When a module declares
    `GITHUB_CHECKSUM_ASSET`, the release's checksums file is fetched from the same
    release, the artifact digest is verified before extraction, and a MISMATCH
    aborts the install. Releases without a declared/available checksum log a clear
    warning and proceed (many upstreams publish none), so no github-release
    install hard-fails. Helpers: `module_verify_sha256`, `_module_checksum_lookup`,
    `_module_github_release_verify_checksum`.
  - Covered by `test/unit/module_fetch_hardening_spec.bats`; the seam-gated
    lifecycle tests set `INIT_UBUNTU_TEST_MODE=1` via the shared harnesses.

### Fixed

- **`setup_ubuntu doctor` now invokes each module's `doctor()` override**
  (architecture-review F1): previously the Engine `doctor` subcommand ran only
  the state.json-vs-reality drift report and never called a module's `doctor()`,
  while `runner_doctor()` sat as dead code and all four `template/*.template.sh`
  files promised the opposite ("Engine calls this from `setup_ubuntu doctor`").
  `doctor` now AUGMENTS the drift report with the per-module health check: with
  no args it runs `doctor()` across every installed module, with `doctor
  <module>...` it scopes to the named modules (unknown names → exit 2). The
  Diag-class exit code (PRD §7.4) is nonzero when EITHER the drift report OR a
  module's `doctor()` fails, so `runner_doctor()` is reachable and the template
  contract is true. Modules without a `doctor()` override fall back to
  `is_installed` (ADR-0002 / ADR-0009), wired in `lib/runner.sh` so the doctor
  phase no longer aborts on an unimplemented `doctor()`.
### Added

- **Shell completion for `setup_ubuntu`** (issue #166): a Bash completion
  script (`module/config/bash/setup_ubuntu.bash`, `complete -F _setup_ubuntu`)
  and a fish completion (`module/config/fish/completions/setup_ubuntu.fish`,
  `complete -c setup_ubuntu`). Level 1 completes subcommands and global flags;
  the module-taking subcommands (`install` / `remove` / `purge` / `upgrade` /
  `verify` / `show`) complete module NAMES derived live from
  `setup_ubuntu list`, so completion always tracks the registry. `just install
  <TAB>` is intentionally not covered — `just` completes recipe names, not
  recipe args; run `setup_ubuntu install <TAB>` directly.
- **`resolve-publish.sh` DaVinci Resolve re-encoder** (`tool/davinci_resolve/resolve-publish.sh`,
  issue #269): a standalone helper that transcodes Resolve Free exports (AV1 /
  DNxHR) to H.264 (default, CRF 18) or H.265 (`-c h265`) via ffmpeg, since
  Resolve Free on Linux cannot export H.264/H.265 directly. Supports `-q CRF`
  and `-o OUTDIR`, writes `<stem>_<codec>.mp4` (audio re-encoded to AAC 192k),
  validates codec/CRF/`-o`/encoder availability up front, removes partial or
  zero-byte outputs on failure, and keeps processing the remaining inputs when
  one fails (final exit 1). The encoder-availability probe captures
  `ffmpeg -encoders` before grepping it, avoiding a `set -o pipefail` +
  `grep -q` SIGPIPE false-negative that would spuriously report a present
  encoder as missing.
- **`docker-tool/set-address-pool.sh`** (`script/docker-tool/set-address-pool.sh`,
  issue #270): a standalone root-only config tool that pins Docker's
  `default-address-pools` in `/etc/docker/daemon.json` to `172.16.0.0/12`
  sliced into `/24` blocks (4096 concurrent subnets, base/size overridable as
  args). Docker's built-in pool is only 15 `/16` blocks and, once exhausted
  under heavy `docker-compose` churn, silently overflows into `192.168.0.0/16`
  — surprising anyone monitoring the host's network. The script backs up the
  existing `daemon.json` (`.bak.<timestamp>`), merges via `jq` preserving other
  keys (e.g. `runtimes`), validates the candidate with `dockerd --validate`
  before it ever touches the live file (leaving the original untouched on
  failure), cleans up its scratch file via `trap ... EXIT`, and prints — but
  does not run — the `systemctl restart docker` step so the operator can check
  restart policies first. `DOCKER_DAEMON_JSON_PATH` overrides the target path
  for testing. Covered by `test/unit/script/set_address_pool_spec.bats`.
- **`claude-ls` follows `ls` conventions** (`module/config/fish/functions/claude-ls.fish`,
  issue #163): quiet + current-folder by default (`$PWD` mapped to Claude's
  `/`->`-` project encoding), with `-a`/`--all` restoring the all-projects view
  and `-l`/`--long` adding the full 36-char UUID plus a `N msg · size · model ·
  age` detail line (model has the `claude-` prefix stripped; age is relative).
  Short flags bundle (`-la`/`-al`); `-a` group headers now show the session's
  real `cwd` instead of the lossy encoded project name; roots and fork children
  sort most-recent-first; an empty current folder prints a `No sessions found`
  hint; the per-line `cwd` and trailing `Total:` line were dropped. Supersedes
  #128 and #137. The test image now bundles `python3`
  (`dockerfile/Dockerfile.test-tools`) so the renderer is exercised end-to-end.
- **`resolve-convert` tool** (`tool/davinci_resolve/resolve-convert.sh`, issue
  #267): a standalone converter that transcodes H.264/AAC clips to DNxHR HQ +
  PCM `.mov` so DaVinci Resolve Free on Linux (which ships no H.264/H.265/AAC
  decode licenses) can import phone/screen-recording footage. Accepts single
  files or directories (batch: `mp4/mov/mkv/avi/m4v`), writes
  `<stem>_resolve.mov` beside each source or into a `-o DIR` target, is
  idempotent (skips sources that already have a `_resolve.mov` counterpart and
  never re-feeds outputs as inputs), and cleans up partial/empty outputs on
  ffmpeg failure or interrupt. The `ffmpeg` binary is overridable via
  `FFMPEG_BIN` for testing.
- **auto-power-profile tool** (`tool/battery/`, issue #260): switches the
  power-profiles-daemon profile from the current power source -- `performance`
  on AC, `balanced` on battery above 25%, `power-saver` at or below 25%
  (`THRESHOLD=25` at the top of the decision script). Two triggers cover both
  cases: a udev `power_supply` rule for instant AC plug/unplug, and a
  `OnUnitActiveSec=2min` systemd timer for the battery threshold crossing. The
  decision script only calls `powerprofilesctl set` when the target differs
  from the current profile and logs each real switch via
  `logger -t auto-power-profile`. `install-auto-power-profile.sh` self-elevates
  with sudo and installs the script, unit, timer, and udev rule; nothing holds
  a username or home path (power state is read from `/sys/class/power_supply`,
  overridable via `$POWER_SUPPLY_ROOT` for tests).
- **`nas-mount` module — CIFS/SMB NAS auto-mount** (`module/nas-mount.module.sh`,
  issue #311): installs the mount driver (`cifs-utils`), the on-demand
  automounter (`autofs`), and the discovery/check tool (`smbclient`). When the
  site-specific NAS parameters are supplied at runtime via environment
  (`INIT_UBUNTU_NAS_HOST` / `_SHARE` / `_USER`, optional `_PASSWORD` /
  `_MOUNT_BASE` / `_CREDENTIALS`), `install` wires an autofs indirect map so the
  share mounts on access; otherwise it installs the packages and prints a hint.
  Credentials stay out of the repo — an existing credentials file is reused or
  one is generated from `INIT_UBUNTU_NAS_PASSWORD`, always forced to
  `chmod 600`; no host/user/password is ever hardcoded. `verify` smoke-tests
  `mount.cifs` + `smbclient`; `remove`/`purge` unwire the maps (purge also wipes
  the credentials). Never auto-selected in Quick Setup (needs site credentials).
- **`f5-split-dns` tool** (`tool/f5-split-dns/`, issue #146): a per-user opt-in
  tool that pins the company DNS server plus a `~<COMPANY_DOMAIN>` routing domain
  onto the F5 BIG-IP Edge VPN interface (`tun0`) via `resolvectl`, so
  load-balanced internal hosts (e.g. the mail server) resolve to in-tunnel
  addresses instead of their public A records. Ships `f5-split-dns.sh` (reads
  `$F5_SPLIT_DNS_CONF` from a per-install systemd drop-in; no secrets, no
  hardcoded username), a `f5-split-dns.service` oneshot unit bound to the
  `tun0` device (`WantedBy`/`BindsTo`, so it applies on connect and auto-clears
  on disconnect), a `config.example` template (real values live only in the
  uncommitted per-user `~/.config/f5-split-dns/config`), an `install.sh` that
  derives the config path from `$SUDO_USER`, and a `README.adoc`. Behavior is
  pinned by `test/unit/f5_split_dns_spec.bats` (stubs `resolvectl`/`ip`/`logger`
  on PATH; the `tool/` tree is a declared shellcheck-out-of-scope surface).
- **`kvm` module — libvirt/QEMU virtualization stack** (`module/kvm.module.sh`,
  issue #310): a new apt-archetype module installing `qemu-kvm`,
  `libvirt-daemon-system`, `libvirt-clients`, `bridge-utils`, `virt-manager`,
  and `ovmf`, then adding the invoking user to the `libvirt` + `kvm` groups.
  `install()` overrides the archetype to run the group-add after apt;
  `doctor()` probes `virsh list --all` reachability plus `kvm-ok`
  acceleration; `POST_INSTALL_MESSAGE` notes the re-login / `newgrp libvirt`
  requirement. `CATEGORY=optional`, recommended only on desktop/server bare
  metal. Replaces the manual snippet that previously lived in `TODO.md`.
- **GitHub issue/PR review-approval hook** (`.claude/hook/enforce_gh_review_approval.sh`,
  issue #34): a PreToolUse (Bash) hook that denies `gh issue create|edit` and
  `gh pr create|edit` until the session transcript contains an explicit user
  approval phrase — `approve issue` / `issue ok` for issues, `approve pr` /
  `pr ok` for PRs, or `skip review` as the explicit opt-out. This enforces the
  draft-in-zh-TW → user review → translate-to-English → create flow so the user
  sees the draft before it lands on a public, indexed repo, closing the gap that
  `enforce_gh_english.sh` (English-only, not approval) left open. Approval is
  read from the system-controlled transcript so it cannot be forged; emergency
  bypass is `ECC_ALLOW_GH_REVIEW=1`. The flow is documented in
  `.agents/rules/common/development-workflow.md` (+ zh translation).
  - **Wired into `.claude/settings.json`** as a PreToolUse/Bash hook so it
    actually runs in a live session (an unregistered hook is inert); a
    `settings.json`-registration test guards the wiring against silent rot.
  - **Per-draft scoping.** Approval is scoped to the current draft, not the
    whole session: once the agent has already run a `gh <kind> create|edit`, the
    next publish of the same kind needs a fresh approval that post-dates that
    prior create (`_last_publish_line_index` finds the boundary; approvals
    before it are ignored). Previously a single `approve issue` authorized every
    later `gh issue create` in the session — including a different, unreviewed
    issue. The boundary is per-kind, so an issue publish never invalidates a pr
    approval. Covered by `test/unit/hook/enforce_gh_review_approval_spec.bats`.
- **`claude-monitor` module** (`module/claude-monitor.module.sh`, issue #315):
  a new custom-archetype module that installs the `claude-monitor` Claude Code
  usage-monitor TUI via `pipx` (user-home scope, no sudo except the one-time
  pipx bootstrap via apt when absent). Implements the full ADR-0002 ten-function
  lifecycle: `pipx install/upgrade/uninstall`, `is_installed` via the on-PATH
  shim or `pipx list`, `is_outdated` via `pipx runpip ... list --outdated`, and
  a `doctor` that checks the launcher answers `--version`. Sidecar version comes
  from `pipx list --short` (falls back to `pipx-managed`). Auto-registered by
  the `*.module.sh` registry scan; covered by
  `test/unit/module/claude-monitor_spec.bats`.
- **LibreOffice module** (`module/libreoffice.module.sh`, issue #312): a v2
  contract module riding the apt archetype. Installs LibreOffice via the
  upstream `ppa:libreoffice/ppa` (explicit repository choice — tracks the
  fresh point releases rather than the distro-archive version frozen into a
  given Ubuntu release); the PPA is added on install and removed on purge, and
  `~/.config/libreoffice` is cleared on purge only. Desktop-only:
  `SUPPORTED_PLATFORMS=("desktop")` and `is_recommended()` never pre-ticks on
  headless server / WSL / SBC form factors. Covered by
  `test/unit/module/libreoffice_spec.bats`.
- **`tmuxp` module — apt to pipx migration** (`module/tmuxp.module.sh`, issue
  #313): tmuxp is now a first-class custom-archetype module installed via
  user-level `pipx install tmuxp` (newer upstream release + venv isolation)
  instead of riding along as an apt package in the legacy
  `module/setup_small_tools.sh` flow. `install()` migrates a pre-existing
  apt-owned tmuxp away (`sudo apt-get remove -y tmuxp python3-libtmux`) when
  apt owns it and sudo is available, and apt-installs `pipx` if missing. All 10
  lifecycle functions are implemented; `setup_small_tools.sh` no longer
  apt-installs `tmuxp`.
- **glow module** (`module/glow.module.sh`, issue #314): `glow` (the
  charmbracelet CLI markdown renderer) is now installable as a module — it was
  a yazi markdown-preview dependency that no module installed. GitHub-release
  archetype (`charmbracelet/glow`, versioned goreleaser tarball with
  `--strip-components=1`), full 10-function lifecycle, Sidecar (ADR-0001). The
  yazi module now surfaces glow in its `POST_INSTALL_MESSAGE` (installable on
  demand via `setup_ubuntu install glow`) rather than hard-wiring it as a
  `DEPENDS_ON` (Q39: module-names-only, yazi runs fine without it). Covered by
  `test/unit/module/glow_spec.bats` and an extended `yazi_spec.bats`.
- **Hook enforcement specs** (`test/unit/hook/`): unit specs for every
  previously-untested `.claude/hook/*.sh`, bringing the hook layer to 100%
  spec coverage. New specs cover `test-must-use-docker`,
  `enforce_semver_tag_via_script`, `check_changelog_drift`,
  `enforce_gh_body_file`, `enforce_gh_english`, `remind_no_emoji`,
  `remind_main_sync`, `remind_workflow_tdd`, and
  `check_main_fresh_before_worktree` — each asserting the real block/deny path
  and the allow/silent path (plus meaningful edge branches).
- **`trash-maintenance` promoted to a v2 module** (`module/trash-maintenance.module.sh`,
  custom archetype): the legacy `tool/trash-maintenance.sh` one-off is now a
  proper lifecycle module and the single source of truth for trash retention.
  `install` deploys the corrected cleanup script
  (`module/config/trash-maintenance/trash-maintenance.sh`) to `~/.local/bin/`,
  schedules it via a marked daily user crontab entry
  (`# init_ubuntu:trash-maintenance`, no sudo), and disables GNOME's own trash
  auto-delete (`org.gnome.desktop.privacy remove-old-trash-files false`) so
  `gsd-housekeeping` never fights the script (issue #275). `remove`/`purge`
  strip the cron entry + script and `gsettings reset` the GNOME key back to
  default; `purge` also wipes the log. The gsettings/cron effects are
  desktop/host-only, so unit tests
  (`test/unit/module/trash-maintenance_spec.bats`) assert the module CONTAINS
  the right commands and exercise the cron seam against a stubbed `crontab`.

- **`script/watch-open-issues.sh` open-issue CHANGE-WATCHER**
  (`test/unit/script/watch_open_issues_spec.bats`): a Monitor-companion poll
  script (same shape as `auto-merge-on-green.sh` / `wait-pr-ci.sh`) that a
  maintainer session wraps in a single Monitor to get timely notification when
  any OPEN GitHub issue changes. Each cycle snapshots
  `gh issue list --state open` to a stable `number<TAB>updatedAt<TAB>title`
  stream and diffs it against the previous snapshot; it prints a dated header
  plus `NEW #n` / `UPDATED #n` / `CLOSED #n` lines only when something changed
  (quiet otherwise, so Monitor fires only on real changes), arming with a
  one-line `watch armed: N issues` baseline on start. The comparison lives in a
  PURE, offline-unit-testable function `watch_issues_diff <prev> <cur>` that
  reads two snapshot files and touches no network; the main loop owns the
  `gh` fetch, the sleep, and graceful handling of transient fetch failures.
  Exit-code-contract script (`set -uo pipefail`, ADR-0007): `0` normal, `2`
  arg error. Args: `--repo` (required), `--interval` (default 180),
  `--state-file`, `--once`, `-h|--help`.
- **Standard template for one-off bash tools** (`template/tool.template.sh`) +
  matching conformance spec (`test/unit/tool_template_spec.bats`), guide
  (`doc/guide/small-tool-template.md`) and ADR-0029. Gives `tool/` one-off
  scripts a proven skeleton: `--help`, `--dry-run`, the `0=ok / 2=usage-error`
  exit-code contract, grep-guarded idempotent work, and `set -euo pipefail`
  (ADR-0007 always-act — closes the missing-`set -u` bug class an audit found
  across the ~16 untested one-off scripts). The template draws the tool-vs-module
  line explicitly: one-offs use this; reusable tools are promoted to modules
  (PRD §6.5/§6.6). No existing tools are retrofitted by this change.
### Changed

- **Time-balanced CI core-shard partition** (`script/ci/shard_partition.sh`,
  `script/ci/ci.sh`, `.github/workflows/ci.yaml`; ADR-0028): the core
  (non-module) unit-test matrix now partitions specs by **measured runtime**
  via greedy-LPT (Longest Processing Time) instead of count round-robin. The
  audit measured the four core kcov shards at ~96-121 s each (the long pole
  after lint) because a few heavy specs pinned individual shards; the new
  partition balances the eight default shards to ~52-57 s each. Weights live in
  a committed, self-maintaining file (`test/ci-shard-weights.tsv`, refreshed
  from real bats junit timings via `just -f justfile.ci shard-weights-refresh`
  and `script/ci/junit_to_weights.sh`) — reproducible from the repo, not a
  CI-only cache (base ADR-00000017's no-CI-only-cache principle). The shard
  count is now dynamic: `vars.CI_CORE_SHARDS` (default 8, up from a hardcoded
  4) drives a `fromJSON` matrix. Every spec still runs exactly once, so the
  coverage-merge denominator and the AC-17 80 % gate are unchanged.

- **`claude-code-config` statusline switches from the `cc-statusline` Claude
  plugin to the `ccstatusline` global binary** (sirmalloc/ccstatusline; #231,
  also resolves #116). The launcher `module/config/claude/run-statusline.sh`
  is renamed to `run-ccstatusline.sh` and now execs the `ccstatusline` binary,
  feeding it the real tmux pane width minus the flexMode `-8` offset and
  post-processing reset timers with an NBSP-aware sed pipeline (5 rules,
  single-highest-unit only). A new `ccstatusline.settings.json` template ships
  the maintainer-verified two-row layout (version 3) and is dropped to the XDG
  config path (`${XDG_CONFIG_HOME:-~/.config}/ccstatusline/settings.json`);
  `settings.json` drops the obsolete `cc-statusline` marketplace/plugin
  entries and points `statusLine.command` at `run-ccstatusline.sh`. Install
  best-effort provisions the binary via `npm install -g ccstatusline`
  (skippable under `INIT_UBUNTU_STATUSLINE_NO_BINARY` so no host package
  install runs from a test path).
### Added

- **Archetype real-mutation-body coverage unit tests**
  (`test/unit/module_helper_real_bodies_spec.bats`): closes the highest-risk
  gap in the module archetype layer (module-template-audit #1 + #2). The apt
  archetype's REAL (non-dry-run) lifecycle bodies were never executed by any
  test — per-module specs stub `install()`/`remove()`/`purge()` wholesale, and
  the one integration apt test is reduced and not in the kcov shards. The new
  specs stub the external side-effecting commands (`sudo`, `have_sudo_access`,
  `is_installed`; real `rm` against scratch paths) and drive the real branches
  of `module_default_apt_install` (PPA add via `apt-add-repository`, both
  no-sudo guards, `apt-get update`/`install`), `module_default_apt_upgrade`
  (`--only-upgrade` + no-sudo guard), `module_default_apt_remove`, and
  `module_default_apt_purge` (`apt-get purge` + PPA `--remove` +
  `CONFIG_PATHS` rm loop). Also covers the `purge` default of the
  github-release archetype (`module_default_github_release_purge`: remove +
  `CONFIG_PATHS` loop) and the config archetype
  (`module_default_config_purge`) — `purge` is the ADR-0015 rollback verb and
  was previously only exercised in dry-run. Test-only; no production code
  changed.
- **tmux keybindings + continuum auto-restore** (`module/config/tmux/tmux.conf`):
  a no-prefix `M-m` zoom toggle (`resize-pane -Z`, issue #265); arrow-key mirrors
  for every `hjkl` binding — `M-Arrow` resize, `prefix + Arrow` swap window/pane,
  `C-Arrow`/`M-C-Arrow` window/pane/session navigation, and `C-Arrow` copy-mode-vi
  pane navigation — reusing the exact commands and flags of their vi-key
  counterparts (issue #245); and `@continuum-restore 'on'` so the last saved
  session auto-restores on tmux server start (issue #266). Existing `hjkl`
  bindings are unchanged.
- **`ctop` fish tool wrapper** (`module/config/fish/functions/ctop.fish`):
  the Ubuntu-packaged `ctop` is broken on cgroup v2 hosts (cannot locate
  cgroup mountpoints) and the upstream `bcicen/ctop` binary panics in
  termbox under `$TERM=tmux-256color`. The wrapper overrides `TERM` to a
  termbox-safe `screen-256color` for the call only, escalates with
  `sudo -E`, and dispatches to the absolute `/usr/local/bin/ctop` path so
  plain `ctop` works from any tmux pane (issue #271).
- **`custom-hosts-sync` module** (`module/custom-hosts-sync.module.sh` +
  `module/config/custom-hosts-sync/`, issue #145): keeps custom `/etc/hosts`
  name->IP entries from being reverted by the F5 BIG-IP Edge VPN client
  (`svpn`), which snapshots `/etc/hosts` on connect and restores it wholesale
  on disconnect/reboot. A systemd `.path` unit watches `/etc/hosts` and the
  user master list (`~/.config/hosts-custom/hosts.custom`) and re-merges the
  master list into an idempotent managed block whenever either changes, so a
  revert is corrected within seconds and edits to the master list apply on
  save. The sync script writes only when content actually changes (never loops
  on its own inotify event) and leaves the F5 gateway line untouched. The
  committed script and `.path` unit carry a `__USER_HOME__` placeholder that
  `install()` substitutes with the real `$HOME` at deploy time, so no username
  is hardcoded in version control. Optional module, `svpn`-gated
  `is_recommended`.
- **Module-iterating contract-conformance meta-test**
  (`test/unit/module/contract_conformance_spec.bats`): a single meta-test that
  DISCOVERS every `module/*.module.sh` dynamically (so new/edited modules are
  auto-covered) and asserts each satisfies the shared contract
  (`doc/module-spec.md` + ADR-0002) — all 10 mandatory lifecycle functions
  defined, required metadata well-formed (`NAME` matches the filename stem;
  `CATEGORY`/`SUPPORTED_PLATFORMS`/`RISK_LEVEL` in their allowed sets;
  `DESCRIPTION` associative with an `en` entry; `TAGS`/`SUPPORTED_UBUNTU`
  non-empty), and a known lifecycle-binding mechanism (archetype macro or
  hand-written custom lifecycle). Closes the audit gap where the 39 modules were
  only covered by ad-hoc per-module specs with no cross-module contract sweep.
  Surfaces one documented, self-cleaning deviation from ADR-0002: the custom
  modules `docker`, `font`, and `nvidia-driver` omit `is_outdated()`/`doctor()`
  (blessed by their own specs; `doc/module-spec.md` §4.1 still lists these as
  "optional", conflicting with ADR-0002 — flagged for the maintainer, quarantined
  in an allowlist that turns red if any gap is later closed).

### Changed

- **CI ShellCheck lint now runs in parallel across CPUs** (`script/ci/ci.sh`
  `_run_shellcheck`): the lint step previously piped all ~197 scripts to a
  single `xargs -0 shellcheck -x` process (~212s serial and the critical-path
  CI tail). It now forks one `shellcheck` per `${SHELLCHECK_BATCH:-40}`-file
  batch across `$(nproc)` workers via
  `xargs -0 -P "$(nproc)" -n "${SHELLCHECK_BATCH:-40}" shellcheck -x`. The
  fail-on-violation signal is preserved: `xargs` returns 123 (not 1) when any
  batched child reports a violation, so the code captures the exit status and
  `_die`s on ANY nonzero (never comparing against a single expected code), and
  the lint step still exits nonzero on any violation. `-x` continues to
  resolve `source`d files from disk regardless of batch, so batching does not
  change WHICH files/sources are linted. Covered by new unit tests in
  `test/unit/script/ci_spec.bats` (fail-signal on violation, pass when clean,
  and a violation hidden among many batches still fails via xargs 123).

### Fixed

- **`small-tools/install.sh` tealdeer cache seeding no longer aborts the
  installer** (issue #263): `tldr --update` sat inside the long `&&` chain, so a
  broken-ZIP failure from tealdeer's own downloader short-circuited the chain and
  silently skipped every later step (tpm clone, tmux config, tmux-powerline, ssh
  setup, ranger plugins). The cache update is now decoupled and non-fatal, with a
  curl + unzip fallback into the real `~/.cache/tealdeer/tldr-pages` cache. Also
  drops the dead `~/.local/share/tldr` handling and the always-true
  `[ -n "<literal>" ]` guards (now real `[ -d ]` path tests), pins the `tealdeer`
  package (not the mismatched `tldr` apt package), adds `unzip`, and installs the
  fish `tldr` completion where fish actually scans (`~/.config/fish/completions`).
  `small-tools/remove.sh` mirrors the cache-path/package fix.
- **Claude Code settings templates ship no hardcoded `/home/<user>` paths**
  (#100): `module/config/claude/settings.json` and `settings.statusline.json`
  now carry a `__HOME__` sentinel for the `statusLine.command` path instead of
  a template-author home prefix, and the machine-specific, fnm-Node-version-
  pinned `sandbox.seccomp.applyPath` field is dropped (Claude Code locates the
  seccomp helper itself). `module/claude-code-config.module.sh`
  `_claude_config_localize` now resolves the `__HOME__` sentinel to the current
  `$HOME` on drop, replacing the over-broad `/home/<user>` rewrite that could
  clobber legitimate foreign paths (linux-review F16). Covered by unit tests in
  `test/unit/module/claude-code-config_spec.bats`.
- **fish no longer leaks focus-event sequences (`ESC[I` / `^[[I`) into external
  commands** (#164): under tmux (`focus-events on`) + fish 4.x, fish injects a
  focus-in sequence around command launch (fish-shell#12232) that a plain shell
  script does not consume, so it appears as literal input and can corrupt an
  interactive `read` (e.g. capturing `\e[Itest` instead of `test`). New
  `conf.d` snippet
  (`module/config/fish/conf.d/disable_focus_during_commands.fish`) disables
  focus reporting (`ESC[?1004l`) on `fish_preexec`; fish re-enables it on its
  next prompt and nvim on startup, so tmux `focus-events on` stays on and
  nvim's `FocusGained` autoread keeps working. Covered by unit tests in
  `test/unit/module/fish_spec.bats`.
- **tmux config now installs to the XDG path `~/.config/tmux/tmux.conf`**
  (#138): `module/tmux.module.sh` `_install_tmux_config()` dropped `tmux.conf`
  to the legacy `~/.tmux.conf`, but modern tmux reads the XDG path and the
  config's own `source-file` reload binding targets
  `~/.config/tmux/tmux.conf`. Every `install` / `upgrade` therefore missed the
  active location and the repo silently diverged from the host. The install
  target, its backup-before-overwrite, the dry-run description, and the
  `POST_INSTALL_MESSAGE` reload hint all move to `~/.config/tmux/tmux.conf`.
  `~/.tmux.conf` stays in `CONFIG_PATHS` as a legacy cleanup path so `purge`
  still removes stale copies. Covered by unit tests
  (`test/unit/module/tmux_spec.bats`).
- **`trash-maintenance` cleanup no longer silently no-ops** (issue #277), with
  the two latent bugs reproduced under PATH-stub tests before fixing:
  (1) `trash-empty` is invoked without `-f` — that option does not exist on
  older trash-cli (0.17.x) and errored out the age-based purge, and is a no-op
  on newer versions; (2) `current_kb()` now captures whatever partial total
  `du` printed and swallows a non-zero `du` exit (defaulting to `0`), so a
  single permission-denied subpath under `Trash/files` can no longer abort the
  run under `set -euo pipefail` before the size-cap comparison and eviction
  loop execute. The default `MAX_GB` cap drops from 50 to 30. `TODO.md`'s
  "Trash 自動維護" section and `module/config/gsettings_config` are updated to
  match (defaults, no `-f`, GNOME auto-delete disabled, `old-files-age`
  dropped). The old `tool/trash-maintenance.sh` copy is removed.

- **`list --installed` now shows the resolved Sidecar version instead of the
  static `VERSION_PROVIDED` literal** (architecture-review F2 +
  module-template-audit): the Sidecar (`versions/<name>`) records the version
  actually pinned at install time (e.g. `0.44.1`), but `lib/dispatcher.sh`
  `_dispatcher_list_installed` rendered the VERSION column from state.json's
  `synced.version_provided` — the module's declared literal, often the `latest`
  sentinel — so users saw `latest` rather than what was really installed. This
  was two parallel sources of truth for the installed version. A new
  `_dispatcher_installed_version` helper reads the Sidecar via
  `module_sidecar_get_version` as the single source of truth for the INSTALLED
  version, falling back to `version_provided` only when no Sidecar exists
  (module records none, or a pre-Sidecar install). `version_provided` keeps its
  meaning as the declared/catalog version; only the installed-version display
  changed. Covered by unit tests in `test/unit/dispatcher_spec.bats`.
- **CI fish syntax check now actually lints the fish config** (`script/ci/ci.sh`):
  `_find_lintable_fish` pruned `module/config` wholesale (copied from the
  ShellCheck pass, where the .sh files there are vendored third-party config).
  But every tracked `*.fish` file lives under `module/config/fish/**` — the
  maintainer's own fish config that init_ubuntu installs — so the prune dropped
  100% of them: the `fish -n` check ran over ZERO files and was silently a
  no-op. Discovery now prunes only the one genuinely vendored fish path
  (`module/config/neovim/fnm_shell_config`, the fnm-generated shell
  integration) while keeping the deprecated/holding/v1 prunes, so all 21
  real fish scripts are checked. New regression spec
  (`test/unit/script/ci_lint_discovery_spec.bats`) asserts the discovery
  returns a nonzero count over the repo so it cannot silently regress to 0
  again. No fish syntax violations surfaced once the files were actually
  checked.
- **`backup_file` no longer aborts config re-runs/upgrades when `BACKUP_DIR`
  is unset** (linux-review F1, CRITICAL): `lib/general.sh` `backup_file` called
  `log_fatal` — an `exit 1` a caller's `|| true` cannot catch — whenever
  `BACKUP_DIR` was empty. The v2 path (`runner` / `module_bootstrap` / `lib`)
  never sets `BACKUP_DIR`, so any config-type module (fish / tmux / neovim /
  ssh-config, etc.) that backed up an existing config on a re-run or upgrade
  aborted the entire run on all targets. `backup_file` now defaults
  `BACKUP_DIR` into the tool's state dir
  (`${INIT_UBUNTU_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/init_ubuntu}/backup/<timestamp>`,
  the same base convention as `state_get_path()`), warns once, and continues —
  backups still work when a dir is provided. The now-redundant per-module
  `BACKUP_DIR` pre-seed in `module/claude-code-config.module.sh` upgrade is
  removed. Covered by unit tests (`test/unit/general_spec.bats`,
  `test/unit/module/ssh-config_spec.bats`) and a real engine-lifecycle
  integration test (`test/integration/lifecycle/engine_lifecycle_spec.bats`).
- **yazi `<Right>` arrow now opens files like `l` / `<Enter>`** (#272): added a
  `<Right>` entry to `mgr.prepend_keymap` in `module/config/yazi/keymap.toml`
  routed through the same `plugin smart-enter` run, so pressing `<Right>` on a
  regular file opens it via the configured opener instead of silently no-oping.
- **yazi routes `application/xml` (and `*+xml`) to code preview/spot and
  `$EDITOR`** (#162): `module/config/yazi/yazi.toml` now maps
  `application/{xml,xml-dtd}` and `application/*+xml` to the `edit` opener and
  to the `code` spotter/previewer (new `prepend_spotters` block + prepended
  `prepend_previewers` entries), so `.xml` files preview with syntax
  highlighting and open in `$EDITOR` instead of falling through to `file` /
  `xdg-open`. ZIP-based Office formats (`*.docx`/`*.xlsx`) are excluded — they
  are not `*+xml` and keep their `archive` handling.
- **`claude-rm` resolves customTitle on fork / resumed sessions** (#33):
  `module/config/fish/functions/claude-rm.fish` only read line 1 of each
  session `.jsonl` when matching a `customTitle`, so fork / resumed sessions —
  whose first line is `leafUuid` / `permissionMode` / a file-history snapshot
  and whose `customTitle` appears on a later line — always reported
  `No session matched` even though Tab completion listed the title. The
  resolver now scans the first 50 lines and selects the `customTitle` line
  (`head -50 | grep -m1 '"customTitle"'`), matching the 50-line window
  `_claude_sessions.py` uses for completion. Covered by content assertions in
  `test/unit/module/fish_spec.bats`.
- **`tool/setup_wayland.sh` no longer aborts on a missing helper path**: the
  script sourced `../function/logger.sh` and `../function/general.sh`, but no
  `function/` dir exists at the repo root, so under `set -euo pipefail` it
  aborted before doing anything. Repointed both sources to the live helpers
  (`lib/logger.sh` + `lib/general.sh`), which define every function the script
  uses (`have_sudo_access`, `log_info`/`log_warn`/`log_fatal`, `exec_cmd`).
  Behavior is otherwise unchanged.

### Changed

- **`lib/dispatcher.sh` split into four cohesive libs** (architecture-review
  E1): the 1291-line dispatcher god-file (well over the 800-line cap) is now a
  ~281-line thin orchestrator that owns only global-flag parsing, the shared
  i18n table, and subcommand routing. Its handler clusters moved to sibling
  libs sourced by the orchestrator: `lib/dispatcher_render.sh`
  (module-metadata → JSON / description renderers), `lib/dispatcher_catalog.sh`
  (`list` / `show` / `search` / `detect`), `lib/dispatcher_lifecycle.sh`
  (`install` / `remove` / `purge` / `upgrade` / `verify` / `doctor`), and
  `lib/dispatcher_state_io.sh` (`status` / `export` / `import` / `config` /
  `sync`). The module-metadata-as-JSON renderer that was copy-pasted three
  times is deduped into single `_dispatcher_json_str_array` (array → JSON
  string array) and `_dispatcher_module_probe` (source a module once →
  recommended + description) primitives used everywhere. Pure refactor:
  identical subcommands, output, exit codes, and JSON; the existing
  `dispatcher_spec` / engine / integration-lifecycle specs stay green
  unchanged, with a focused `test/unit/dispatcher_render_spec.bats` pinning the
  new render seams.
- **yazi config drops keys removed upstream in v26.5.6** (#273): removed the
  inert `title_format` (`[mgr]`) and `micro_workers` / `macro_workers`
  (`[tasks]`) keys from `module/config/yazi/yazi.toml`. All three matched
  Yazi's shipped defaults (never customized) and were removed upstream; the
  rest of `[mgr]` / `[tasks]` is unchanged.

### Removed

- **ranger module** (issue #319, supersedes #61): yazi (#60) is now the daily
  file manager across machines, so the redundant ranger catalog entry is
  dropped. Removed `module/ranger.module.sh`, `module/config/ranger/rifle.conf`,
  and `test/unit/module/ranger_spec.bats`; dropped the `_install_ranger` helper
  (plus its `ranger_devicons` / `ranger-zoxide` / `ranger-fzf-filter` plugin
  wiring) from `module/setup_small_tools.sh` and the `ranger` package +
  `ranger_devicons` steps from `small-tools/install.sh` / `remove.sh`; removed
  the ranger usage snippets from the READMEs and the obsolete ranger `r()`
  cd-on-exit note from `TODO.md` (yazi already returns the last cwd on exit).
  Regenerated `doc/module/INDEX.md` (44 -> 43 modules) and updated the PRD
  module table. This is a **catalog-only drop**: no removal module runs
  `apt remove ranger` at deploy time, so already-installed copies are left in
  place for the user to uninstall manually if desired.
- Remove stale machine-local `small-tools/config/fish/fish_variables`; portable
  fish config lives in `module/config/fish/`.
- **17 superseded legacy scripts from the deprecated holding areas**
  (`doc/review/legacy-disposition.md`): the v1 remove scripts under `tool/remove/`
  (`remove_docker.sh`, `remove_font.sh`, `remove_neovim.sh`,
  `remove_nvidia_driver.sh`) and the legacy `small-tools/` config/tool payload
  (`config/fish/config.fish`, the `config/fish/functions/` helpers
  `docker-build-run` / `docker-exec` / `efc` / `ehk` / `etc` / `sfc` / `stc` /
  `system-update-upgrade`, `config/ssh/ssh_config`, `config/tmux/tmux.conf`,
  `config/.vimrc`, `tools/eza.sh`). All are superseded by the v2 `module/`
  equivalents and nothing live sources them; both `tool/` and `small-tools/` are
  already CI-excluded holding areas (`script/ci/ci.sh` lint/kcov prune,
  `.codecov.yaml` ignore).

## [v0.1.0-rc3] - 2026-06-23

### Added

- **`lib/tui_backend.sh` branch-coverage unit tests**
  (`test/unit/tui_backend_branches_spec.bats`): focused in-process tests for the
  CLI-fork error paths (`_tui_cli_json` ADR-0019 non-JSON guard;
  `tui_cli_install_plan` / `tui_cli_manage_plan` fork-failed + no-plan paths),
  the data-broker single error surface (`_tui_broker_fail` msgbox branch and the
  detect-cache accessor error) and the `_tui_category_entry` unknown-category
  default. Recovers per-file coverage lost when the gum adapters were dropped
  (ADR-0024); no runtime change.

- **whiptail Fallback tier reaches feature parity with the fzf Rich tier**
  (ADR-0024 D10 — feature-equivalent, render-degraded): the whiptail screens now
  match the navigator feature-for-feature. Nested category drill-down (main ->
  category -> sub-category menu -> checklist leaf; a single TAGS[0] bucket goes
  straight to the leaf), main/category-menu counts are SELECTED/total (PRD D2),
  `is_recommended` modules are pre-selected on first entry into the recommended
  category (PRD D4, idempotent via the shared `TUI_RECO_PRESELECTED` session
  guard), and module detail stays reachable on the read-only detail screen. The
  bucketing (`tui_subtags` / `tui_subtag_count`), the SELECTED/total counts
  (`tui_category_sel_stats`) and the recommended pre-selection set
  (`tui_recommended_preselect_modules`) are now pure producers in the shared
  data layer that BOTH tiers wrap (the fzf wrappers delegate to them), so the
  two tiers cannot drift. Manage Secrets becomes a three-way Token / GPG / SSH
  picker (extracted to `lib/tui_secrets.sh`), each kind a registry-dispatched
  sub-screen showing that kind's current list (empty -> "none", PRD story 11)
  plus its actions (Token: list/set/remove; GPG: list/generate/import; SSH:
  list/generate/load/copy/remove); per ADR-0025 every text input forks the
  `setup_secrets` CLI on its own no-echo tty (the TUI never renders a value
  widget). A parity test asserts both tiers produce the same `setup_ubuntu
  install` fork argv for an identical selection, and a live-whiptail expect
  smoke covers the drill-down, the three secrets sub-menus and Run -> Proceed.

- **fzf two-pane navigator (Rich tier)** for the install-pick flow (ADR-0024,
  ADR-0025): every navigable level (main menu -> category -> sub-category ->
  module leaf) is one fzf two-pane screen — left pane is the current level, the
  right Preview pane live-renders the cursor row (children + counts on a branch
  row, full module detail on a module row) via a pure `--preview <token>` mode
  the script re-invokes (token kinds `menu:`/`cat:`/`sub:`/`mod:`). Live
  multi-select (space toggles the cursor row), main-menu category count is now
  SELECTED/total (not installed/total), and `is_recommended` modules are
  pre-selected on first entry into the recommended category. Tier resolution
  prefers `fzf` (offering `setup_ubuntu install fzf` when absent + interactive,
  per G4) and falls back to the existing whiptail screens; `--backend
  fzf|whiptail` forces the path. No TUI text-input/confirm widget — the forked
  CLI owns the install go-ahead (ADR-0025). Manage / Secrets / System Info /
  Help still route to the existing screens this phase.

- **TUI screen registry + session data broker** (front-matter deepenings #6 /
  #7, ADR-0024 #5 shared data layer): one `TUI_SCREEN_REGISTRY` maps a menu
  token to its leaf-screen handler (`manage` / `secrets` / `sysinfo` / `help`),
  and a small `_tui_invoke_screen` dispatcher (stripping a leading `menu:` for
  the fzf tier) replaces the duplicated token->screen `case` arms that lived in
  all three dispatch sites (the fzf `_tui_nav_main`, the whiptail
  `_tui_main_loop`'s `_tui_dispatch`, and `_tui_dispatch`); category-browse /
  run / quick-setup rows keep their bespoke handling. The data broker
  (`tui_broker_init` / `tui_broker_list_json` / `tui_broker_detect_json`) forks
  `list --json` + `detect --json` ONCE per session, caches both to temp files,
  serves cached accessors with no re-fork, and funnels every fork failure
  through ONE error path (a single msgbox + clean abort). The fzf `--preview`
  cache (`TUI_LIST_CACHE`) is folded into the broker (`TUI_BROKER_LIST_CACHE`),
  with the fork-fallback preserved for direct `--preview` / test calls.
  Per-query forks (`show <module> --json`, install/manage dry-run plans, the
  live `list --installed --json` Manage view) stay direct. An injectable
  cache-file seam keeps it unit-testable while G4 stays intact (no engine lib
  sourced).

- **8 per-tool base modules split from `apt-essentials`** (ADR-0026): `git`,
  `vim`, `curl`, `wget`, `jq`, `build-essential`, `htop`, `unzip` — each
  `CATEGORY=base`, archetype-A apt (exactly one apt package), `DEPENDS_ON=()`,
  independently installable and removable. `ca-certificates` and
  `software-properties-common` are no longer modules; they are treated as
  transitive apt dependencies (`ca-certificates` pulled by curl/wget/git,
  `software-properties-common` installed by any PPA-adding module).

- **state.json forward-only migration `lib/state_migrate.sh`** (ADR-0008,
  schema 0.1.0→0.2.0): converts an installed `apt-essentials` state entry into
  individual installed entries for `git` / `vim` / `curl` / `wget` / `jq` (the
  5 former-bundle packages that are now modules), each `synced.manual=true`.

- **TUI Help system + `ui.tui_hints` inline-hint switch** (#203, design §3): the
  main menu gains a backend-aware **Help** entry (after System Info, before
  Run) that documents what each backend hides — the gum body covers j/k (vim
  motion) and esc semantics (on the main menu esc exits and drops unsent
  selections) that gum's native footer omits; the whiptail body centers on
  **Tab** (the non-obvious key to reach the `< Back >` / `< Exit >` buttons),
  plus space/enter/esc. A contextual `?`-key inside a widget is impossible on
  both backends, so the Help entry is the mechanism. New config switch
  `ui.tui_hints` (default ON) toggles the INLINE per-screen hints (the gum
  header hint + `gum --show-help`; the whiptail multi-select hint line); when
  `off` screens render clean and the user relies on the Help entry. The TUI is a
  CLI frontend (ADR-0019 / G4): it reads the value ONCE at startup by forking
  `setup_ubuntu config get ui.tui_hints` (never sources the engine) and threads
  it as a single exported `TUI_HINTS` global; an unset key / empty value / error
  degrades to the default ON, and only an explicit `off` turns hints off. en +
  zh-TW strings added for both backends.

- **TUI module detail view** (#211 part 2): a read-only detail msgbox shows a
  module's full `setup_ubuntu show <module> --json` data — description,
  category, tags, depends_on, conflicts, supported_ubuntu, supported_platforms
  (arrays comma-joined, empty/absent fields shown as `(none)`). It is reachable
  from the category checklists (base / recommended / optional / experimental)
  via a `View details...` companion entry AND from Manage Installed via a
  `View details` action. Neither gum nor whiptail can attach a per-row info key
  inside a checklist, so the trigger is a pick-then-show menu: on a checklist
  the companion entry opens a module picker → detail box and returns to the
  SAME checklist with selections intact (the read-only view forks `show --json`
  and touches no selection state). The TUI forks the engine (G4 — sources no
  engine lib); en + zh-TW strings added.

- **TUI Review screen now shows per-item dependency provenance** (#214): the
  Review & Install screen previously rendered a flat "will pull N deps" count
  that did not say which selection pulled each dependency. It now lists every
  module in resolver plan order, each annotated with its origin — a user pick
  shows `<module> (your selection)` and an engine-pulled dependency shows
  `<dep> (required by <module>)`. Provenance is computed in the TUI from the
  `depends_on` graph in `setup_ubuntu list --json` (the same source the
  basic-first checklist sort uses; the resolver stays the single dep
  authority — the TUI only attributes the plan, never re-resolves it). The
  forked install command's argv is unchanged: only the display changed.
  Consistent across gum and whiptail; en + zh-TW strings added.
- **TUI Quick Setup shows richer context + a pre-install summary** (#213): each
  wizard step now spells out what each choice includes (the CLI-essentials
  suite line names the tools and the whole-suite count; the agent-CLI step
  reports how many are offered and preselected). Before the install is forked,
  Quick Setup now shows a final PRE-INSTALL SUMMARY (reusing the Review
  provenance listing) of EVERY module that will actually be installed — the
  user's picks AND the dependencies pulled in for them — so nothing installs
  unseen. Declining the summary is a pure cancel (no platform-override write,
  no install fork). Consistent across gum and whiptail; en + zh-TW strings
  added.
- **TUI Manage Secrets is now a real sub-menu** (#202): `Manage Secrets`
  previously forked bare `setup_secrets`, which just printed usage and exited
  rc2. It now opens a sub-menu (design §4) whose entries each fork a
  `setup_secrets` subcommand (G4 — the TUI sources no engine lib): list
  existing secrets (read-only overview combining `list` + `gpg list` +
  `ssh-key list`; never secret/private contents), generate SSH key (ed25519 /
  ecdsa / rsa type menu), load SSH key to agent, copy SSH public key to remote
  (input user@host), set token (input name only — the value is prompted by
  `setup_secrets` on its own no-echo tty, never via the TUI; AC-20), generate
  GPG key, import GPG (input file path), and delete (category menu Token / SSH
  key with danger tiers: token = single yes/no confirm, SSH key =
  type-to-confirm). Every op now shows a plain-text result box (`OK` /
  `FAILED (rc=N)`) instead of the raw `[setup_secrets exited N]` dump.
  `token get` is excluded (it would print the secret on screen) and GPG key
  deletion is deferred (no `setup_secrets` gpg-delete capability yet). Consistent
  across gum and whiptail; en + zh-TW strings added.

### Changed

- **`lib/tui_secrets.sh` Manage Secrets screens hoist their per-render i18n
  label lookups into locals** (test-coverage refactor, behavior-identical). Each
  sub-screen menu / input / pick previously built its widget call inline as
  `_var="$(... $(i18n_t ...) ...)"`; the nested command substitutions on the
  assignment's opening line are counted by kcov as unexecuted even when the
  screen runs, holding the file at 73.5%. The labels are now fetched into named
  locals first, so the menu/input calls reference plain `${vars}` and the screen
  bodies, list-render branches ("none" vs populated) and per-action CLI-fork
  dispatch are attributed correctly; the file rises to ~96% under the new
  in-process `test/unit/tui_secrets_e2e_spec.bats`. No user-visible change.

- **Sidecar write/remove moved to the phase-invocation layer + archetype macros
  now emit all 10 Lifecycle functions** (architecture deepening #2 + #4;
  ADR-0027, refines ADR-0001 on *where* and ADR-0002 on macro completeness). A
  Module's `install()`/`upgrade()`/`remove()`/`purge()` no longer writes/removes
  the Sidecar; one shared `_module_sidecar_after_phase` helper does it from BOTH
  invokers — the Engine runner (`lib/runner.sh`) and Standalone
  (`module_standalone_main`) — after a successful phase, recording the version
  from the new archetype-defaulted, per-module-overridable `module_provided_version`
  hook (apt -> `dpkg-query`; github-release -> resolved release tag via
  `MODULE_GH_RESOLVED_VERSION`, preserving the existing Sidecar on an idempotent
  re-install; config / generic -> `VERSION_PROVIDED`). The
  `module_use_*_archetype` macros now wire `is_outdated` and `doctor`
  (`module_default_doctor` = `is_installed` + warn) in addition to the mutation
  phases; only `detect` + `is_recommended` stay module-defined. `doctor` is now
  read-only (warns about a missing Sidecar, never heals it). The per-module
  `module_sidecar_*` calls, `_xxx_pkg_version` helpers, and redundant
  hand-written `is_outdated`/`doctor` stubs were removed across the module set;
  genuine overrides (metadata self-check, Sidecar-drift detection,
  version-compare `is_outdated`, daemon checks) stay. Module unit tests that
  asserted a Sidecar after calling `install()` directly now route through the
  invoker (`module_standalone_main`).
- **Extracted the repeated dual-mode module header into one
  `lib/module_bootstrap.sh`** (architecture deepening #3): every
  `module/*.module.sh` used to carry ~17 identical lines (set
  `MODULE_STANDALONE` from the BASH_SOURCE-vs-`$0` test, then in standalone
  mode `set -euo pipefail; shopt -s inherit_errexit`, resolve `MODULE_DIR` /
  `REPO_ROOT` / `LIB_DIR`, and source `logger.sh` + `general.sh` +
  `module_helper.sh`). That boilerplate now lives in a single `module_bootstrap`
  function; each module's header collapses to a ~4-line stub that sources the
  bootstrap and calls `module_bootstrap`. The bootstrap self-locates from its
  OWN path (it lives in `lib/`), so it does not depend on the caller's
  `BASH_SOURCE`; it keeps the exact same set options + the same three libs
  sourced in the same order, so behavior is byte-identical. Engine mode is a
  no-op (`module_bootstrap` returns early when `MODULE_STANDALONE != true`; the
  runner already pre-sourced the libs and set strict mode in the sub-shell) —
  ADR-0001's standalone/engine boundary and the G4 dual-mode behavior are
  unchanged. The 4 `template/module-*.template.sh` headers adopt the same stub.
  New `test/unit/module/module_bootstrap_spec.bats` pins the contract.

- **Merged `lib/detect.sh` + `lib/platform.sh` into one deep `lib/environment.sh`
  (Environment module)**: internally layered — private `_probe_*` (I/O) under a
  private `_classify` (pure form_factor logic) — behind a small surface,
  `environment_snapshot()` (full `{os, arch, gpu, …, form_factor}` JSON) plus
  `environment_field <path>`. Callers (dispatcher `detect`, runner) now fetch
  the snapshot once instead of calling detect + classify separately. The
  `setup_ubuntu detect` output (human and `--json`) is byte-identical
  (ADR-0019-adjacent contract; pinned by a golden test). Backward-compat
  aliases `detect_environment` / `detect_get_field` / `platform_classify` /
  `platform_export_env` are kept. `detect_spec.bats` + `platform_spec.bats`
  folded into `environment_spec.bats`. New glossary term **Environment** in
  `CONTEXT.md` (avoid the bare term *platform*, now an internal classify step).
- **State presented as ONE module through `lib/state.sh`** (architecture
  deepening #1): `lib/state_migrate.sh` (forward-only migration) and
  `lib/state_io.sh` (cross-machine import/export) are now INTERNAL SEAMS reached
  only through the external State interface (`state_init`, the `record_*`
  writers, the field accessors, the io export/import functions). The
  forward-only migration chain (ADR-0008) is folded into `state_init`: on
  startup `state_init` runs validate → migrate → ready internally, so the engine
  no longer calls `state_migrate_run` directly (the separate
  `state_migrate_run || exit 1` call in `setup_ubuntu.sh` was removed; a failed
  migration is still fatal and `state_init` surfaces the non-zero path, leaving
  the original file + its `.bak` untouched). The three files stay physically
  separate (combined > 800 lines) but converge on a single interface; migration
  is replayed at most once per process. New end-to-end interface test
  (`test/unit/state_interface_spec.bats`) drives init(old-version file) →
  migrate → record → export through the interface; the seam specs
  (`state_migrate_spec.bats` / `state_io_spec.bats`) keep covering the internals.

- **Dependent modules rewired from the `apt-essentials` bundle to specific tool
  deps** (ADR-0026): `docker`→`curl`; `anydesk`→`curl`; `fish`→`curl`,`shell`;
  `font`→`curl`,`unzip`; `fzf`→`curl`; `lazygit`→`curl`,`git`;
  `neovim`→`curl`,`git-config`; `jetson-stats`→`git`,`curl`; `gum`→`curl`;
  `shell`→`git`,`curl`; `notion`→`curl`; `git-config`→`git`;
  `nvidia-driver`→`git`,`curl`; `vscode`→`curl`; `tmux`→`git`,`curl`;
  `qmk-firmware`→`git`,`build-essential`.

- **State schema version bumped 0.1.0 → 0.2.0** (ADR-0026 / ADR-0008): the
  first schema change since MVP; triggers the forward-only migration in
  `lib/state_migrate.sh`.

- **Removed the main-menu section separators** (#216): the `------` divider
  rows confused navigation — gum / whiptail have no non-selectable row, so a
  divider could be landed on and pressing it re-rendered the menu with the
  cursor reset to the top (it looked like a jump to Quick Setup). The three
  logical groups are now conveyed by row ordering alone; every visible row is a
  real, selectable action. Dropped `TUI_MENU_SEPARATOR` / `_tui_menu_separator`
  and the main-loop sentinel guard.

- **i18n officially supports en + zh-TW only for 0.1.0** (#205): `--lang` and
  `$LANG` auto-detection previously accepted `zh-CN` / `ja` but rendered English
  (claimed support, delivered en). `i18n_detect_lang` now resolves unsupported
  locales to `en` silently, and `i18n_sanitize_lang` rejects `zh-CN` / `ja` →
  `en` with a warning (the warning fires only on an explicit unsupported
  `--lang`, not on auto-detect). zh-CN / ja translations are deferred to 0.2.0
  (#208). `--lang` help and the supported set now read `en | zh-TW`.

### Removed

- **gum as a TUI backend** (ADR-0024): the `_tui_*_gum` adapter family, gum
  detection / preference, the pre-launch gum-install prompt (#171), the
  gum-specific i18n entries (`prompt_install_gum`, `gum_keys_*`, `help_gum`,
  the gum `press_enter` footer), the `--backend gum` accept, and the gum
  backend smoke / expect fixtures (`smoke_flow_gum.exp`,
  `real_install_flow_gum.exp`) are all removed. The Rich tier is fzf and the
  Fallback tier is whiptail (ADR-0024); `--backend gum` is now a usage error
  (exit 2) that hints `setup_ubuntu install gum`. gum remains a fully
  supported INSTALLABLE TOOL (`module/gum.module.sh`, archetype B) — only its
  role as a dialog backend is dropped. The test-tools image no longer bundles
  the gum binary.

- **The `apt-essentials` bundle module** (ADR-0026): split into 8 independent
  per-tool base modules (git, vim, curl, wget, jq, build-essential, htop,
  unzip). `ca-certificates` and `software-properties-common` are no longer
  modules — they are now treated as transitive apt dependencies pulled by the
  tools that need them, not user-facing catalog entries.

### Fixed

- **fzf navigator preview no longer re-forks `setup_ubuntu list --json` per
  cursor move** (perf): the navigator caches the list JSON to a temp file once
  at session start and exports its path; the `--preview` re-invocation reads the
  cache instead of re-sourcing the engine and rescanning every module on every
  keystroke (the "sub-menu / preview lag"). Falls back to a fork when the cache
  is absent (direct `--preview` calls / tests).

- **fzf module-leaf rows no longer print the literal `null`** for a module
  whose `description` is JSON null (malformed/forked payload): `_tui_fzf_mod_label`
  now falls back to an empty description (`// ""`), matching the preview
  renderer's existing `// $none` guard, so a row reads `o name ` instead of
  `o name  null` (ADR-0019 description-is-a-string contract).
- **State migration `0.1.0 -> 0.2.0` rebuilds each split tool's `local`
  sub-object empty** (ADR-0008 synced-vs-local split): the per-tool entries
  (git/vim/curl/wget/jq) the apt-essentials split creates now always land with
  `local: {}` instead of preserving a pre-existing entry's stale machine-specific
  facts (resolved install targets, `last_verified_at`). Those host-derived
  values must never forward-carry across machines — they are re-derived on the
  next run.

- **fzf Rich tier could not enter its delegated dialog screens** (ADR-0024):
  in the fzf two-pane navigator, Quick Setup / Manage / Secrets / System Info /
  Review / msgbox still render through the existing `tui_render_*` whiptail
  dialog screens. Those screens abort on the `${TUI_BACKEND:?TUI_BACKEND not
  set}` guard, but the fzf tier left `TUI_BACKEND` unset — so selecting Quick
  Setup (and the other delegated rows) died with "TUI_BACKEND not set"
  (user-visible: "cannot enter Quick Setup", "other screens flash"). The fzf
  tier now defaults `TUI_BACKEND=whiptail` when nothing pinned it and drives
  fzf itself via the dedicated `TUI_FZF_BIN` seam (so the navigator no longer
  keys the fzf invocation off `TUI_BACKEND`). Added the missing fzf-tier AC-10
  layer-2 live smoke (`test/integration/tui/harness/smoke_flow_fzf.exp` +
  `tui_smoke_spec.bats`) which drives the REAL fzf navigator into the delegated
  whiptail Step-1 screen and back — the regression guard that would have caught
  this (the prior AC-10/AC-11 smoke only covered gum + whiptail). `fzf` added
  to the test-tools image for it.

- **CI concurrency no longer starves a commit of its run**: the workflow
  `concurrency.group` is now keyed on the PR head SHA instead of `github.ref`
  (`refs/pull/N/merge`, which GitHub recomputes when the base moves). Under
  serial auto-merge that ref churn let `cancel-in-progress` cancel a distinct
  commit's run, leaving a head with no CI run ("pushed but no CI triggered").
  Keying on head SHA dedups only redundant same-commit events; residual no-runs
  from GitHub not firing the event are still recovered by the
  auto-merge-on-green empty-commit re-trigger (#232).
- **TUI Manage Installed labels unregistered entries clearly** (#215): a
  state.json entry whose module is no longer in the catalog (`list --json` /
  registry) — a deleted module file or a stale test install — used to render
  with a bare `[other]` tag, indistinguishable from a registered module that
  merely lacks a `TAGS[0]`. Such rows now carry an explicit `(unregistered)`
  marker, and the new `View details` action falls back (when `show --json`
  fails for the missing module) to the facts state.json actually holds
  (installed version + installed_at) plus a `not in the current catalog` note,
  instead of crashing or showing nothing. Note: the bare `unknown` *version* is
  not a bug — it is the legitimate state.json default (`lib/state.sh` /
  `lib/runner.sh` write `version_provided=unknown` when a module exports no
  `VERSION_PROVIDED`), so it is left as-is.

- **`setup_apt_mirror` no-op detection was dead code** (#152, via #172): a brace
  typo `cmp -s "{$_file}"` (instead of `"${_file}"`) made `cmp` open a literal
  `{/path` that never exists, so it always reported "differ" — the branch that
  detects "the mirror rewrite changed nothing" never fired, silently treating a
  no-op as success. Fixed both occurrences in `lib/general.sh`. Added a
  regression test for the no-op path (the existing apt-mirror tests only
  exercised the positive rewrite, where the typo is invisible). Thanks to
  @Jah-yee for the fix.

- **whiptail multi-select descriptions truncated at the wrong boundary under
  zh-TW / ja**: `_tui_clip` / `_tui_clip_budget` measured by character count, so
  double-width CJK glyphs over-ran the whiptail box and the clip cut at the wrong
  visual column. Both now measure by display width (via `_tui_disp_width`):
  `_tui_clip` reserves one column for the `…`, never splits a wide glyph, and the
  per-page budget sizes the tag column by display width. 5 new unit cases. (#204)

- **System Info (and any gum msgbox/yesno) crashed when content started with
  `-`**: `gum style` / `gum confirm` parsed forked text beginning with
  `------ init_ubuntu environment ------` (the `detect` banner) as a flag and
  aborted with `unknown flag`. `_tui_msgbox_gum` / `_tui_yesno_gum` now pass a
  `--` guard before the positional text so arbitrary content can never be
  misread as a flag. Regression test added.

- **gum TUI screens did not show how to select or go back**: the gum menu /
  checklist relied on gum's native footer, which is easy to miss / can be
  clipped and never advertises `Esc`, while the passed-in help text described
  whiptail's `< OK >` / `< Back >` buttons (which gum has no equivalent for).
  Added localized keybind hints to the gum header (`gum_keys_menu` /
  `gum_keys_checklist` in `TUI_BACKEND_I18N`) plus an explicit `--show-help`,
  so every gum screen shows `space/x: toggle · enter: confirm · esc: back`
  (menus: `enter: select · esc: back`). gum-only — whiptail renders the
  buttons natively. (gum toggles a multi-select row with space or x.) 2 new
  unit cases.

- **TUI main-menu description column was ragged under zh-TW / ja** (CJK
  alignment): `_tui_main_loop` padded the menu label with `printf '%-22s'`,
  which counts characters, not terminal columns — East-Asian Wide labels
  (each CJK glyph is 2 display columns) under-padded, so the description
  column did not line up (visible with `just tui --lang=zh-TW`). Added
  display-width primitives `_tui_disp_width` / `_tui_pad_label` to
  `lib/tui_backend.sh` (wide/fullwidth codepoints count as 2) and switched the
  main menu to `_tui_pad_label`, so zh-TW / ja labels align the same as ASCII.
  5 new unit cases.

- **gum TUI over-truncated module descriptions; `show` omitted the description**
  (issue #183): the #168 whiptail clip budget (sized for whiptail's 72-col
  modal box) was applied in the SHARED checklist entries producers
  (`tui_checklist_entries` / `_tui_qs_entries` in `lib/tui_backend.sh`), so the
  gum backend — which manages its own width — received pre-clipped items and
  showed `…` unnecessarily on a full terminal. Moved the clip out of the
  producers into the whiptail adapter only (`_tui_checklist_whiptail` via the
  new `_tui_clip_checklist_args` / `_tui_clip_budget` helpers): whiptail still
  clips to its box (no #168 regression), gum now renders the full
  `[tag] description`. Separately, `setup_ubuntu show <module>`
  (`_dispatcher_show`) printed name/file/category/tags/deps/conflicts/ubuntu/
  platforms but never the description; it now prints a localized `description:`
  line (honors `INIT_UBUNTU_LANG` via the same module-i18n probe `list --json`
  uses, fully offline).

- **Real engine install of github-release (and config/custom) modules was
  broken**: `setup_ubuntu.sh` never sourced `lib/module_helper.sh`, so a real
  (non-dry-run) `setup_ubuntu install gum` (or fzf/eza/lazygit/…) died with
  `module_use_github_release_archetype: command not found`. The runner sources
  each module in a subshell that inherits the archetype macros / lifecycle
  helpers from the parent, but the entrypoint never loaded them. Fixed by
  sourcing `module_helper.sh` in `setup_ubuntu.sh`. It went unnoticed because
  `--dry-run` is dispatcher plan-only (never reaches the runner) and the unit
  `_load_engine` helper sourced `module_helper.sh` itself. Added an e2e
  regression that drives the real runner path via `verify gum`
  (`test/unit/e2e_spec.bats`).

### Added

- **`show --json` machine-readable module detail** (#211, part 1):
  `setup_ubuntu show <module> --json` now emits a single JSON object for one
  module (`name`, `category`, `description`, `tags`, `depends_on`, `conflicts`,
  `supported_ubuntu`, `supported_platforms`) — the structured record the
  upcoming TUI module-detail and Manage-detail views consume. stdout is JSON
  only (warnings/errors stay on stderr, same guarantee as `list --json`); an
  unknown module exits 2 with no stdout. The plain (non-`--json`) `show` view is
  unchanged. JSON keys/strings are jq-escaped, reusing the same helpers and
  isolated-subshell description probe as the `list --json` catalog view.

- **TUI exit guard** (#206): pressing Exit on the main menu with unsent
  selections now asks to confirm before discarding them (empty selection
  leaves immediately; Q43 still holds — zero file writes either way). The
  clean-Ctrl+C SIGINT trap originally bundled here is deferred to a follow-up:
  a signal trap inside the TUI subprocess deadlocks kcov ptrace in the coverage
  unit shard, so it needs a kcov-safe reimplementation.

- **`setup_ubuntu_tui.sh --lang <code>` forces the UI language** (en|zh-TW)
  for the session, overriding the source-time resolution (env >
  config `ui.lang` > `$LANG`). `just tui --lang=zh-TW` now renders the TUI in
  zh-TW without touching `$LANG` or config. An invalid value is not a usage
  error — `i18n_sanitize_lang` downgrades it to `en` with a bilingual warning,
  matching the engine entrypoint contract (#185). Deliberately scoped to the
  TUI entrypoint (no global dispatcher flag). Covered by a live-widget
  `--lang zh-TW` render smoke (`lang_flow.exp`, asserts 系統 / 離開 on the real
  whiptail main menu).

- **`WorktreeCreate` hook → worktrees at repo-root `.worktree/`**
  (`.agents/hook/worktree_create.sh`): Claude Code's agent/workflow git
  worktrees now land in a dedicated, gitignored `<repo>/.worktree/<name>`
  instead of the upstream default `.claude/worktrees/` — kept in-repo (easy to
  manage) but out of `.claude/`. The lint/coverage `find` in `script/ci/ci.sh`
  now prunes `.worktree`, `.claude/worktrees`, and `worktree`, so per-worktree
  full-repo copies are never scanned (that scan once wedged a lint run ~54 min).
  7 bats cases; unsafe names rejected; stdout carries only the path.

- **`enforce_long_job_timeout` PreToolUse hook**: blocks a known-long
  FOREGROUND Bash command (full `just` test/coverage/lint, `kcov`,
  `docker build`, `docker compose run`) that has neither `run_in_background:
  true` nor a `timeout` param (a self-wrapped `timeout(1)` also passes).
  Prevents hung jobs from wedging the session indefinitely (a lint run once
  stalled 54 min, a coverage run 25 min). Detection is per-sub-command on a
  quote-stripped copy (split on `; && || |` + newlines, leading `cd`/`sudo`/
  `env`/`VAR=` wrappers stripped, text-carrier launchers like git/gh/grep/echo
  skipped), so trigger words and separators inside commit messages, JSON test
  payloads, or `gh` bodies do not false-positive — verified by the hook
  blocking its own first dogfood command.

- **Traditional Chinese (zh-TW) for the TUI frontend + backend labels**
  (issue #185 Phase 2): every user-facing string the TUI itself authors now
  routes through the `i18n_t` helper and localizes under
  `INIT_UBUNTU_LANG=zh-TW`. `setup_ubuntu_tui.sh` resolves the UI language
  once at startup (`i18n_resolve_init_ubuntu_lang`) and adds a `TUI_I18N`
  table covering the main menu, System Info, category checklists, Review &
  Install, the Quick Setup wizard, Manage Installed / destructive-action
  confirms, and button captions; `lib/tui_backend.sh` adds a
  `TUI_BACKEND_I18N` table for its own default widget labels (category /
  menu rows, form-factor choices, the gum install prompt, the §8.4 confirm
  body). Caller pass-through text (module descriptions, ADR-0019 payload
  fields, `setup_ubuntu detect`/dry-run output) is left as-is — only the
  TUI's own strings translate, and both gum and whiptail render the
  localized labels identically. English output is byte-identical to before.

- **Real engine-lifecycle integration harness** (issue #175 / #176): a new
  `test/integration/lifecycle/engine_lifecycle_spec.bats` drives the REAL
  non-dry-run path `setup_ubuntu.sh → dispatcher → runner → source module →
  archetype macro → lifecycle fn` as a non-root user (install refuses root),
  one module per archetype — github-release (`gum`: install → state.json →
  verify → idempotent re-install → remove → upgrade with Sidecar bump),
  config (`ssh-config`) and custom (`claude-code-config`) at full fidelity,
  apt (`tmux`) at reduced level on the apt-less alpine image. It asserts no
  `command not found` / no undefined-phase, so it catches the #174 bug class
  the prior suite missed; the AC-1/2/3 integration matrix now exercises a
  github-release module across ubuntu 22.04/24.04/26.04. To keep it offline
  and deterministic, `lib/module_helper.sh`'s github-release archetype honors
  two **test-only** env seams (no-ops in production): `INIT_UBUNTU_TEST_GH_
  FIXTURE_DIR` (install a pre-staged tarball instead of fetching, while the
  real gzip-sniff / tar-extract / symlink still run) and
  `INIT_UBUNTU_TEST_GH_VERSION` (deterministic version in place of the GitHub
  API lookup). The `test-tools` image gains `file` + `tar` for the real
  extract path.

- **AC-11 TUI → Proceed → REAL install integration test** (issue #178): a new
  `test/integration/tui/tui_real_install_spec.bats` drives the live TUI on a
  pseudo-tty through `Run → Review → Proceed` and proves the TUI forks the
  REAL `setup_ubuntu install` pipeline (CLI/TUI parity, PRD G4) — the AC-10
  smoke stopped at `< Exit >` with a recording-mock CLI and never reached a
  real install. A wrapper CLI serves the menu's `list/detect --json` reads
  from a controlled fixture (gum as the lone Optional module → deterministic
  navigation) while routing the Proceed fork to the real `setup_ubuntu.sh`,
  reusing the #175 offline github-release seam + `INIT_UBUNTU_NO_DEPS` so gum
  installs offline as a non-root user; the spec asserts the module actually
  landed (state.json + Sidecar + binary). Covers whiptail (always) and gum
  (skips when absent from the image). Test-only; no production code changed.

- **gum as the preferred TUI backend** (issue #171, ADR-0023): a new
  `module/gum.module.sh` (github-release archetype, multi-arch asset
  selection `gum_<ver>_Linux_{x86_64,arm64,armv7}.tar.gz`, user-home install
  to `~/.local/bin` with Sidecar version tracking + `upgrade()`, discoverable
  via `list`) installs `charmbracelet/gum`. `lib/tui_backend.sh` gains native
  gum adapters for all four contract widgets — `menu` → `gum choose` (choice
  mapped back to its tag by index), `checklist` → `gum choose --no-limit`
  (one tag per line), `msgbox` → `gum style`/`gum format`, `yesno` →
  `gum confirm` — at default (untheme) styling. A new
  `setup_ubuntu_tui.sh --backend gum|whiptail` flag forces `TUI_BACKEND` and
  skips both detection and the install prompt (invalid value → exit 2 with
  usage), letting CI/QA force either backend; `just tui --backend whiptail`
  works through the existing pass-through recipe. `gum` is added to the
  test-tools image so the AC-10 dual-backend live smoke runs against both
  gum and whiptail.

### Changed

- **Hook & skill text is now English** (was zh in places): hook comments and
  emitted messages (`remind_ci_auto_merge`, `check_main_fresh_before_worktree`,
  `remind_main_sync`, `check_changelog_drift`) and the `wait-pr-ci` skill are
  English — agent-tooling is English-only (zh stays in `rules/zh/`). The
  detection ranges in `enforce_gh_english.sh` keep their CJK by design (that IS
  the banned-character pattern). Also: `remind_ci_auto_merge` now appends a
  **dual-watch** reminder to its PR/auto-merge nudges — pair the auto-merge
  Monitor with an independent background watchdog so a silently-dead primary
  Monitor never strands the loop.

- **Memory canonical store moved to `.agents/memory/`** (was
  `.claude/projects/memory/`): joins `hook/rules/script/skills` as a
  tool-agnostic, shareable source of truth that other agent CLIs can read, and
  is exposed the SAME way they are — a tracked `.claude/memory` →
  `../.agents/memory` symlink (uniform with `.claude/hook` → `../.agents/hook`).
  Claude's HOME-side `~/.claude/projects/<key>/memory` symlink targets
  `.claude/memory`, so the resolve chain is HOME → `.claude/memory` →
  `.agents/memory/`. The `projects/<key>/` layer is Claude's fixed HOME
  convention (HOME-only); the repo has nothing under `.claude/projects/`.
  `.gitignore` tracks `.agents/memory/**` + the `.claude/memory` symlink and
  ignores all of `.claude/projects/`.

- **`.claude/worktrees/` is now gitignored**: Claude Code's transient
  agent/workflow git worktrees are runtime scratch (auto-cleaned), never
  vendored. (Their base location is a fixed `.claude/worktrees/` convention but
  can be relocated out-of-tree via a `WorktreeCreate` hook if desired.)

- **`.claude/skills` is now a single whole-dir symlink to `.agents/skills`**
  (was 37 per-item symlinks): the tracked-vs-machine-local distinction already
  lives at the canonical end (`.agents/skills/` tracks the repo-owned skills,
  gitignores third-party ones), so the per-item layer in `.claude/skills/` was
  redundant. Now uniform with `.claude/{hook,rules,script}`; new skills appear
  automatically without adding a `.claude` symlink. `.gitignore` drops the
  per-item `.claude/skills/*` block.

- **`hook/`, `rules/`, `script/` are now canonical under `.agents/`, symlinked
  from `.claude/`**: extends the #151 skills pattern (real files live under
  `.agents/<dir>`; `.claude/<dir>` is a symlink) to the rest of the vendorable
  agent config, so there is a single tool-agnostic source of truth that other
  agentic CLIs can share, not a `.claude`-only copy. All existing
  `.claude/hook/…` / `.claude/script/…` / `.claude/rules/…` path references
  (settings.json, specs, docs) resolve transparently through the symlinks.
  Runtime/Claude-specific entries stay in `.claude/` (`settings.json`,
  `settings.local.json`, `projects/`, `worktrees/` — moving the latter two
  would break the memory symlink and live git worktrees).

- **TUI backend detection is now gum > whiptail** (issue #171, ADR-0023):
  pre-launch detection prefers `gum` when present. When gum is absent and the
  session is interactive (`[[ -t 0 ]]`), a plain stdin/stdout `read` prompt
  (default Yes) offers to install gum — on yes the TUI forks
  `setup_ubuntu install gum` (it never installs inline, per G4), re-detects,
  and launches with gum; on no it uses whiptail. Non-interactive sessions
  skip the prompt and use whiptail. The four widgets in `lib/tui_backend.sh`
  became dispatchers (`_tui_<widget>_<backend>`); the whiptail adapters are
  unchanged, the frontend contract is unchanged (still passes `tag item
  [status]`, still reads back the tag), and exit codes still normalize to
  `0`=confirm / non-zero=cancel across both backends.

### Removed

- **`dialog` TUI backend** (issue #171, ADR-0023): `dialog` is dropped from
  the backend set, which is now exactly gum + whiptail (both render all four
  contract widgets natively). The `dialog`-first detection branch and the
  `dialog`-specific fatal-guidance wording are gone.

### Fixed

- **TUI checklist rows no longer overflow the box** (issue #168): the
  category browse checklists (`base`/`recommended`/`optional`) and the Quick
  Setup steps passed the full module description as the checklist item text,
  so long descriptions wrapped/overflowed past the `TUI_WIDTH=72` border on
  both dialog and whiptail. A new pure helper `_tui_clip <string> <max>`
  truncates with a single-char ellipsis `…`, and `_tui_clip_items` clips each
  checklist item to a per-page budget of
  `TUI_WIDTH − longest-name − 8` (checkbox + tag-column gutter chrome),
  floored to 20. Only the displayed `[tag] description` is clipped; the
  selectable module name/tag is left intact.

- **`setup_ubuntu list --json` (catalog view) now emits JSON** (issue #165):
  it was stubbed (printed a warning + the plain table), which broke the TUI —
  `setup_ubuntu_tui.sh` forks `list --json` and validates it with `jq -e`, so it
  failed on a real run with `'setup_ubuntu list --json' did not return JSON
  (ADR-0019)`. `list --json` now prints `{"items":[{name,category,tags,
  supported_platforms,description,recommended},…]}` (jq-escaped; `description` /
  `recommended` sourced per-module, degrading to `null` per ADR-0019), honors
  `--category=` / `--tag=`, and keeps warnings off stdout. The TUI smoke test is
  hardened to fork the real `list --json` so this can't regress.

### Changed

- **TUI main menu visually separates its three sections** (issue #169):
  `tui_main_menu_entries` now emits non-selectable divider rows (sentinel tag
  `-`, a `──────────────` rule in the label column) between the three logical
  groups — build-the-pick (quick-setup + category browse), manage/info
  (manage, secrets, sysinfo), and the `run` action. The dividers render
  identically on dialog and whiptail (both accept arbitrary tag/item rows);
  `_tui_main_loop` skips the sentinel as a no-op so landing on a separator
  never dispatches an action. Real items are neither reordered nor renamed,
  `run` stays the last row, and `< Exit >` behavior is unchanged.

### Added

- **`auto-merge-on-green` skill + CI-monitor hook** (issue #154): a new skill
  (canonical under `.agents/skills/`, symlinked from `.claude/skills/`) plus
  `.claude/script/auto-merge-on-green.sh` that arms GitHub-native auto-merge
  (`gh pr merge --auto --squash --delete-branch`) on a PR and Monitor-watches
  it land. The script keys off `gh pr view`'s `mergeStateStatus`
  (repo-agnostic — no hardcoded check name): `MERGED` → done; `BEHIND` →
  `gh pr update-branch` (keeps GitHub auto-merge unblocked under `strict`
  branch protection, which does not auto-update stale branches); `DIRTY` /
  required-check `FAILURE` → report and exit (auto-merge left armed so a
  fix-push merges automatically); a non-progressing `BLOCKED` bails after a
  grace window. The merge runs server-side, so it lands even if the session
  ends. Covered by `test/unit/script/auto_merge_on_green_spec.bats` and
  `test/unit/hook/remind_ci_auto_merge_spec.bats`.

### Changed

- **`make` → `just` as the single task runner** (issue #157, ADR-0022):
  hard cut, no `Makefile` alias kept. The retired `Makefile` is replaced by
  two files mirroring `ycpss91255-docker/base` v0.41.0 (ADR-00000005):
  `justfile.ci` — the CI / test gate, a 1:1 port of the old targets
  (`just -f justfile.ci test` / `test-unit [<module>]` / `test-integration`
  / `lint` / `coverage` / `coverage-unit [<module>]` / `coverage-merge` /
  `build-test-tools` / `clean`; `help` → `default`); and a net-new
  auto-discovered `justfile` wrapping the host entry scripts
  (`just install` / `remove` / `purge` / `upgrade` / `verify` / `list` /
  `show` / `detect` / `doctor` / `config` / `version` / `tui` / `secrets` /
  `nvidia-driver` / `claude`). `MODULE=<name>` becomes a positional recipe
  param (`just -f justfile.ci test-unit core`); the `TEST_TOOLS_PREBUILT=1`
  toggle (just has no conditional deps) is reproduced via a hidden
  always-run `_ensure-image` dep with a conditional body. `just` is
  provisioned in CI (`extractions/setup-just`) and the test-tools image
  (`apk add just`); dev hosts install it manually. `ci.sh`'s CLI is
  unchanged. All references updated atomically (CI workflow, the docker
  hook whitelist, `generate_module_filters.sh` + spec, docs, ADR-0004,
  `AGENTS.md` / `CONTEXT.md`, templates, `compose.yaml`, script comments).

- **`remind_pr_wait_ci.sh` → `remind_ci_auto_merge.sh`** (issue #154): the
  PR-CI reminder hook is renamed and broadened. It now triggers on both
  `gh pr create` and `git push`, and injects the matching instruction —
  `gh pr create` → run the `auto-merge-on-green` skill; `git push` (tag) →
  monitor release CI; `git push` (branch) → auto-merge if a PR exists, else
  monitor. The hook only detects + instructs (it cannot run a Monitor or
  merge); the agent + skill do the work and GitHub performs the merge. No
  per-PR human merge step; human oversight moves to feature/project
  checkpoints. ADR-0007's exit-code-contract script list updated to the new
  name.

- **Skill layout canonicalized under `.agents/skills/`** (issue #150,
  supersedes the 2026-05-21 migration): the repo-owned skills `semver-bump`
  and `wait-pr-ci` move from real directories in `.claude/skills/` to
  `.agents/skills/<name>/`, with `.claude/skills/<name>` now a symlink into
  the canonical store — matching how third-party (`skills` CLI) skills are
  laid out. Both the canonical dir and the symlink are git-tracked;
  third-party skills + their symlinks stay machine-local. `.gitignore` moves
  to the `.agents/*` + layer-by-layer negation form (git cannot re-include a
  path once a parent dir is ignored). Path references such as
  `.claude/skills/semver-bump/SKILL.md` still resolve transparently through
  the symlink, so no hook/script/doc references changed.

### Added

- **GitHub issue/PR templates + agent template-enforcement hook**: four
  YAML issue forms under `.github/ISSUE_TEMPLATE/` (`bug` / `feature` /
  `task` / `docs`), each setting `type:` (org Issue Type — auto-applies in
  org repos, harmlessly ignored on this personal repo) and stock `labels:`,
  plus `config.yaml` disabling blank issues and a markdown
  `PULL_REQUEST_TEMPLATE.md` (`Summary` / `Changes` / `Decision` / `Tests`).
  New PreToolUse hook `enforce_gh_issue_template.sh` re-imposes the template
  on the agent path (`gh issue create --body-file` bypasses GitHub's forms):
  it picks the form from the conventional-commit title prefix
  (`fix`→bug, `feat`→feature, `docs`→docs, `refactor/test/ci/chore/perf/build/style`→task)
  and denies when a required section is missing or empty. Required sections
  are parsed from the form files themselves — single source of truth, no
  second list to drift. Templates are repo-agnostic and intended to be
  adoptable by `ycpss91255-docker/base`. Covered by
  `test/unit/hook/enforce_gh_issue_template_spec.bats` (13 tests).
- **lib/general.sh + lib mid-band unit-spec coverage boost** (issue #122,
  AC-17 gap 1/2, from the #112 honest-coverage investigation): +177
  behavior-level bats tests across nine `test/unit/*_spec.bats` files —
  `general` (13→57: exec_cmd incl. capture mode, sudo/platform helpers,
  backup_file, temp-file helpers), `dispatcher` (49→83), `module_helper`
  (25→59), `state_io` (24→37), `state` (37→46), `config` (14→24),
  `secrets` (45→58), `sync` (17→23, rebased onto the post-#105 SSH e2e
  suite), `detect` (14→28). lib/general.sh rises from 5.3% to 65%+ in
  the core shard alone; no kcov excludes or threshold changes.
  Test-only — no engine code touched.
- **Batch-A module spec backfill** (issue #123, AC-17 gap 2/2): Q29-scope
  per-module specs for the 10 pre-runner Batch-A modules that previously
  had only incidental coverage (26-60%) — apt-essentials (72 tests),
  docker (72, extended thin spec), font (80), nvidia-driver (86), fish
  (82), tmux (66), neovim (77), shell (65), ssh-config (69), git-config
  (71); 740 tests total, reusing the Batch B/C pattern (smoke / metadata /
  lifecycle dry-run / no-side-fx / sidecar ADR-0001 / idempotency AC-5 /
  standalone CLI AC-25). No kcov excludes, no threshold changes; the
  per-module matrix shards (#31) pick the specs up automatically.

- **Runner records the ADR-0010 depends_on snapshot** (issue #93, PRD
  §10.1, follow-up to #43): `runner_install` now passes the resolved
  forward-dep snapshot into `state_record_install`'s 4th parameter
  instead of always recording `[]`. The snapshot is the resolver's
  transitive dep closure for the module, filtered to deps that actually
  completed install earlier in the same session (topo order guarantees
  deps run first), so deps that failed mid-batch are excluded and
  `--no-deps` installs record `[]` — the state reflects what really
  happened, not metadata intent. The per-session success set resets on
  every runner batch. `upgrade` topo-sort (PRD §7.6) and
  `--with-orphans` consume this field later.

- **AC-10 two-layer TUI test harness** (issue #73, PRD §11.1 AC-10):
  layer 1 — `test/unit/tui_ac10_spec.bats` runs the scripted-widget e2e
  (now extracted to the reusable `test/helper/tui_harness.bash`: ADR-0019
  fixtures, sealed-PATH symlink farm, recording mock `setup_ubuntu`,
  backend-named mock widget) on BOTH backends and asserts the Q43 model —
  checked pages accumulate → `< Run >` → one exact
  `install <modules...> -y` CLI command string, byte-identical on dialog
  and whiptail — plus the argv-level backend differences (dialog
  `--cancel-label` vs whiptail `--cancel-button`; widget argv otherwise
  identical across backends) and a whiptail Exit fs-snapshot. Layer 2 —
  `test/integration/tui/tui_smoke_spec.bats` drives the REAL dialog and
  whiptail binaries on an expect pseudo-tty (new `expect` in
  Dockerfile.test-tools) through the literal AC-10 flow: open main menu →
  enter Optional → check one item → OK → Exit; asserts every screen
  renders, the checkbox toggles to `[*]`, `< Exit >` exits 0 with zero
  file writes, and the only CLI forks are `list/detect --json`. The
  expect proc library (`test/integration/tui/harness/tui_expect_lib.tcl`)
  is reusable for the upcoming #71/#72 screens. Runs under
  `make test-integration` (ADR-0004: Docker only).
- **TUI Quick Setup multi-step wizard + manual-flag semantics** (issue
  #71, PRD §8.2.1, ADR-0010): main-menu item 1 is now the real four-step
  wizard. Step 1/4 confirms the detected platform with an optional
  override that stays in wizard memory during prepare; Step 2/4 offers
  recommended modules with the §15.3 filter pipeline (SUPPORTED_PLATFORMS
  vs the effective form factor first, then the Q36 `[modules.<n>] enabled`
  tri-state — `false` force-excludes, `true` force-includes checked — then
  the engine's `is_recommended` verdict preselects); Step 3/4 offers the
  CLI-essentials suite as whole-suite / pick-individually / skip; Step 4/4
  is the AI-agent-CLI multi-select (recommended ones preselected). The
  wizard then reuses the #70 Review & Install screen (refactored into a
  shared `_tui_screen_review` decision screen: rc 0 = Proceed) and forks
  the single CLI pipeline via `_tui_exec_install`. The platform override
  is written only on the Proceed leg — via a forked
  `setup_ubuntu config set platform.override <v>` followed by
  `install --profile=<v> <picked...> -y` — so Cancel/SIGINT anywhere
  before Proceed is a pure cancel (zero config/state writes, fs-snapshot
  asserted); after Proceed the CLI pipeline owns the terminal and a
  partial install's exit 6 propagates as the TUI exit code (§8.2.1 stage
  table, ADR-0015). ADR-0010 manual-flag matrix is guaranteed
  structurally: the forked argv names only user-picked modules (e.g.
  neovim/lazygit/eza → `manual=true`), engine-pulled deps
  (fzf/ripgrep/fdfind/fnm) never appear on it and stay `manual=false` —
  bats asserts the exact command string. New `lib/tui_backend.sh` helpers:
  `tui_platform_choices` (shared §7.5 form-factor vocabulary, also reused
  by System Info), `tui_effective_form_factor`,
  `tui_qs_recommended_entries`, `tui_qs_tag_entries` (driven by the
  additive ADR-0019 item fields `recommended` / `enabled`, absent = null
  = nothing forced). Covered by `test/unit/tui_quick_setup_spec.bats`
  (helper units + scripted mock-backend e2e: happy path, deferred
  override write ordering, override narrowing Step 2, pure-cancel
  fs snapshots, nothing-selected, exit-6 propagation).
- **TUI Manage Installed / Manage Secrets + destructive confirm dialogs**
  (issue #72, PRD §8.3/§8.4): the main menu's Manage Installed entry now
  lists installed modules (version + installed_at, data source: a forked
  `setup_ubuntu list --installed --json`) with a flat ↔ group-by-`TAGS[0]`
  view toggle. Per-module actions fork the matching CLI subcommand (G4 —
  the TUI has no pipeline of its own): Update → `upgrade <m> -y`,
  Remove → `remove --no-deps <m> -y`, Purge → `purge --no-deps <m> -y`
  (`--no-deps` so tearing down a module never cascades into shared
  dependencies). Remove / Purge go through a §8.4 confirm dialog that
  enumerates the concrete actions — the exact command to be forked, the
  module plan derived from a forked `<action> --dry-run --no-deps`, and
  the state.json change — behind `< Proceed > / < Cancel >` buttons
  (Cancel forks nothing). Manage Secrets forks `setup_secrets` and
  returns to the main menu afterwards. New `lib/tui_backend.sh` helpers:
  `tui_cli_installed_json`, `tui_installed_entries`, `tui_manage_args`,
  `tui_cli_manage_plan`, `tui_manage_confirm_text`, plus
  `TUI_YES_LABEL`/`TUI_NO_LABEL` relabeling on `tui_render_yesno`
  (dialog `--yes-label/--no-label`, whiptail `--yes-button/--no-button`).
  Covered by `test/unit/tui_manage_spec.bats` (mock-backend units + e2e
  slices: list rendering, action argv, confirm content, cancel-no-fork,
  secrets round-trip).

- **TUI checkbox accumulator + Run → Review → Proceed** (issue #70, PRD
  §8.1/§8.2 Q43, AC-10/AC-11): Base / Recommended / Optional submenus are
  now pure check-lists grouped by `TAGS[0]` with dep chains collapsed to a
  "will pull N deps" hint (arch Q-A3). `< OK >` stores the page in an
  in-memory associative-array accumulator inside the TUI process,
  `< Back >` discards the page — selections never touch disk. `< Run >`
  (new last main-menu row) is the only batch execution point: it opens
  Review & Install (full selection list + resolver-computed dep summary
  via a forked `setup_ubuntu install --dry-run`, expandable details),
  and Proceed clears the screen and forks one
  `setup_ubuntu install <modules...> -y` CLI pipeline (G4 — the TUI has
  no install path of its own, which is what makes AC-11 structural).
  Back/Cancel return to the main menu keeping selections; Run with
  nothing selected reports `nothing selected`; `< Exit >` (relabeled
  Cancel button) drops the process and every selection with zero side
  effects. New `lib/tui_backend.sh` helpers (`tui_checklist_entries`,
  `tui_selection_*`, `tui_cli_install_plan`, `tui_plan_deps`,
  `tui_install_args`, `tui_render_checklist` with `--separate-output` on
  both backends) are bats-covered, including a scripted mock-backend e2e
  that asserts the exact generated CLI command string and an fs-snapshot
  proving Exit writes no files. `install --profile=<x>` is accepted as a
  stubbed WARN flag so the TUI session platform override can ride the
  fork before the engine implements it.

- **Hand-written guides + auto-generated module index + README Quick Start**
  (issue #47, PRD M14 / §3.4): `doc/guide/` now carries all four guides —
  the existing `archetype-cookbook.md` plus new `module-authoring.md`
  (template → metadata → lifecycle → bats spec → PR workflow, referencing
  module-spec, PRD Q29 and ADR-0001), `cli-usage.md` (apt-aligned daily
  flows, global flags, the PRD §7.4 exit-code contract with examples) and
  `troubleshooting.md` (verify vs doctor, reading the OTel-aligned JSONL
  log, chasing a `trace_id`, exit-code playbook). `doc/module/INDEX.md` is
  now AUTO-GENERATED by the new `script/gen-module-index.sh`, which
  extracts `NAME` / `CATEGORY` / `TAGS` / `DESCRIPTION[en]` from every
  `module/*.module.sh` in a registry-style throwaway sub-shell;
  regeneration is deterministic (no timestamps, locale-pinned ordering)
  and a bats spec guards header, per-module coverage, pipe escaping,
  determinism and freshness of the committed INDEX. README Quick Start
  rewritten to the PRD §3.4 three-line bootstrap (apt install git →
  git clone → `./setup_ubuntu_tui.sh`) with a documentation map; the
  README stays `.adoc` (full `.md` conversion is 0.2.0 / AC-28).
- **`claude-code-config.module.sh` module** (issue #75, PRD §6.3.2 Batch C,
  M7): new config-drop module applying the personal Claude Code settings
  shipped in `module/config/claude/` (`settings.json`,
  `run-statusline.sh`, `settings.statusline.json`) to `~/.claude/`.
  Built on `module_use_config_archetype` with super-call overrides: the
  two statusline companions are dropped alongside the primary
  `settings.json`, template-author `/home/<user>` prefixes are rewritten
  to the current `$HOME`, and the marker is a JSON key already present in
  the template so the archetype never injects a `#` comment into JSON.
  `CATEGORY=optional`, `TAGS=(agent ...)`, `DEPENDS_ON=(claude-code)`
  (Q39). All 10 lifecycle phases run standalone (AC-25); install is
  idempotent (AC-5); `--dry-run` performs no filesystem writes (AC-12);
  the version Sidecar is written on install/upgrade and removed on
  remove/purge per ADR-0001 while `state.json` is never touched by the
  module. `is_outdated` reports drift between the dropped files and the
  localized templates; `doctor` validates the statusline launcher.
  80-test bats spec.

- **`setup_secrets.sh`: token / gpg / list / remove subcommands**
  (issue #68, PRD §14, AC-20): the reserved #44 stubs are now real.
  `token set <name>` reads the value from a no-echo `/dev/tty` prompt
  (or from a stdin pipe in automation) — never from argv, so nothing
  sensitive can land in `ps` output or shell history; `token get <name>`
  prints the value (and nothing else) on stdout so it is pipe-safe.
  `gpg generate` delegates to `gpg --full-generate-key` (all prompts,
  including the passphrase, stay on gpg's own tty); `gpg import [<file>]`
  imports key material from a file or stdin. `list` prints stored names
  only — never values — on a log-free stdout; `remove <name>` deletes
  from the active backend and fails non-zero for unknown names. Token
  round-trip is covered through the real CLI on all three PRD §14.3
  backends: encrypted-file for real in Docker, `pass` and `gnome-keyring`
  via PATH-stub mocks that also assert the secret value never rides argv.
- **`jetson-stats.module.sh` v2 module** (issue #37, PRD Q51 / §6.3.3 Batch
  C): new module providing the `jtop` monitor TUI for NVIDIA Jetson Orin on
  the custom archetype — `sudo pip3 install -U jetson-stats`, falling back
  to `sudo pipx install` on PEP 668 (externally-managed) Python
  environments, detected via the stdlib `EXTERNALLY-MANAGED` marker.
  `SUPPORTED_PLATFORMS=("jetson-orin")` only: `detect()` keys off the
  engine form factor or `/etc/nv_tegra_release`, and `is_recommended()`
  answers yes solely on jetson-orin. `doctor()` checks the `jtop.service`
  state (warn-only — a fresh install legitimately needs a re-login or
  `sudo systemctl restart jtop.service`, also surfaced as the post-install
  message). All 10 lifecycle phases run standalone (AC-25); install is
  idempotent (AC-5); `--dry-run` performs no filesystem writes (AC-12); the
  version Sidecar (pip-reported version, `pip-managed` fallback) is written
  on install/upgrade and removed on remove/purge per ADR-0001 while
  `state.json` is never touched by the module. `remove` keeps the leftover
  `jtop.service` unit; only `purge` disables the service and deletes the
  unit file. Tagged `hardware`, `CATEGORY=optional`,
  `DEPENDS_ON=(apt-essentials)` (Q39).
- **notion module** (issue #65, PRD §6.3.3 Batch C, Q50 / #35): new
  `module/notion.module.sh` installs the Notion desktop app from the
  unofficial notion-electron `.deb` release (anechunaev/notion-electron),
  replacing the legacy small-tools snap path (the snap is broken on
  24.04). Rides the github-release archetype but consumes a `.deb`:
  install resolves the latest tag, downloads the versioned
  `Notion_Electron-<ver>-{amd64,arm64}.deb` asset, and hands it to
  `apt-get install ./<deb>` so apt resolves the package's dependencies.
  `CATEGORY=optional`, `TAGS=(notes)`, `DEPENDS_ON=(apt-essentials)`
  (Q39), `SUPPORTED_PLATFORMS=(desktop)`; `is_recommended` never
  pre-ticks on non-desktop form factors. All 10 lifecycle phases run
  standalone (AC-25); install is idempotent (AC-5); `--dry-run` performs
  no filesystem writes (AC-12); the version Sidecar is written on
  install/upgrade and removed on remove/purge per ADR-0001 while
  `state.json` is never touched by the module.

- **anydesk module** (issue #64, PRD §6.3.3 Batch C, M7): migrated
  `module/anydesk.sh` to the v2 contract as `module/anydesk.module.sh`
  on the apt archetype with AnyDesk's vendor repo — install wires the
  upstream signing key under `/etc/apt/keyrings/anydesk.gpg`
  (unprivileged `gpg --dearmor` piped into `sudo tee`) plus the
  `deb.anydesk.com all main` source, then chains to the apt default;
  remove keeps the repo wiring, purge unhooks source + keyring.
  Desktop-only `SUPPORTED_PLATFORMS` with a form-factor-gated
  `is_recommended` (Q49), `DEPENDS_ON=("apt-essentials")` (module names
  only, Q39), tagged `remote`. All 10 lifecycle phases runnable
  standalone (AC-25), idempotent install (AC-5), dry-run writes nothing
  (AC-12), Sidecar per ADR-0001. 76-test bats spec
  `test/unit/module/anydesk_spec.bats` (Q29 coverage ladder).
- **TUI skeleton: entry point, backend detection, main menu** (issue
  #69, PRD §8.1 / §8.5, G4): new `setup_ubuntu_tui.sh` +
  `lib/tui_backend.sh`. Backend detection prefers `dialog`, falls back
  to `whiptail`; both missing is fatal with the §8.5 fix guidance (no
  auto-install). Running without usable sudo exits 4 and suggests CLI
  mode. The TUI is a pure CLI frontend (G4): menu data comes exclusively
  from forked `setup_ubuntu list --json` / `detect --json` subprocesses
  (ADR-0019 schema) — it never sources engine libs and never writes
  state (pinned by a grep gate in bats). The main menu renders only
  non-empty CATEGORYs (Q44: `experimental` is hidden while empty and
  auto-appears once populated); the System Info screen shows forked
  `detect` output and offers a session-memory platform override.
  Dispatch mount points are stubbed for #70 (checkbox accumulator +
  Run/Review), #71 (Quick Setup), and #72 (Manage Installed / Secrets).
- **yazi module (v2 contract)** (issue #60, PRD §6.3.3 Batch C):
  `module/yazi.module.sh` migrates `module/submodule/yazi.sh` to the
  github-release archetype with a zip-aware fetch override (upstream
  ships `yazi-x86_64-unknown-linux-gnu.zip`, not a tarball; magic-byte
  validation, flatten-top-dir extract, `unzip` fail-fast). Metadata:
  `CATEGORY=optional`, `TAGS=(filemgr)`, `DEPENDS_ON=()`, i18n
  `DESCRIPTION`/`POST_INSTALL_MESSAGE` (en + zh-TW). All 10 lifecycle
  phases standalone-runnable (AC-25), idempotent install (AC-5),
  dry-run writes nothing (AC-12), Sidecar on install/upgrade and
  removed on remove/purge (ADR-0001, AC-23). Appends a guarded
  `alias yz='yazi'` to existing `~/.bashrc`/`~/.zshrc` — fixing the
  issue #1 copy-paste bug where the alias targeted `cat`; purge strips
  it. 68-test bats spec at `test/unit/module/yazi_spec.bats`.
- **qmk-firmware module** (issue #63, PRD §6.3.3 Batch C, M7): new
  `module/qmk-firmware.module.sh` migrates `module/setup_qmk_firmware.sh`
  to the v2 contract on the custom archetype — apt prereqs (git, python3,
  pipx, build-essential; the package is ensured in `install()` per Q39
  while `DEPENDS_ON` carries only the `apt-essentials` module), pipx-managed
  `qmk` CLI, `qmk setup -y` toolchain + `~/qmk_firmware` checkout, and a
  personal keymap overlay from `module/config/qmk_firmware/keyboards`.
  Tagged `hardware`; host-only platforms (no wsl/container, US-5); opt-in
  only (`is_recommended` always declines — enable via
  `[modules.qmk-firmware]`). All 10 lifecycle phases runnable standalone
  (AC-25), idempotent install (AC-5), dry-run writes nothing (AC-12),
  Sidecar per ADR-0001 with PyPI-backed `is_outdated`. 74-test bats spec
  `test/unit/module/qmk-firmware_spec.bats` (Q29 coverage ladder).

- **claude-code module** (issue #57, PRD §6.3.2, Batch C): new
  `module/claude-code.module.sh` installs the Anthropic Claude Code CLI
  via the official native installer (`https://claude.ai/install.sh`,
  user-home install, no sudo) on the custom archetype (D). The tool
  ships its own auto-updater, so `is_outdated` always returns 1
  (delegated) and `upgrade` runs `claude update`; `remove` keeps user
  config (`~/.claude*`), `purge` clears it. Sidecar written on
  install/upgrade and dropped on remove/purge (ADR-0001); all 10
  lifecycle phases runnable standalone (AC-25). 74-test bats spec at
  `test/unit/module/claude-code_spec.bats`.

- **ranger module** (issue #61, PRD §6.3.3 Batch C): new
  `module/ranger.module.sh` on the apt + config-drop hybrid archetype
  (super-call pattern) — apt installs the `ranger` package, then the
  config-drop defaults place the repo-managed
  `module/config/ranger/rifle.conf` (ranger's file-opener rules) at
  `~/.config/ranger/rifle.conf` with the managed marker. `is_installed`
  requires both the package and the marked config, so a deleted
  rifle.conf re-triggers the drop while a user-edited (still-marked)
  file is never clobbered; `remove` keeps the config, `purge` deletes
  `~/.config/ranger`. All 10 lifecycle phases run standalone (AC-25);
  install is idempotent (AC-5); `--dry-run` performs no filesystem
  writes (AC-12); the version Sidecar is written on install/upgrade and
  removed on remove/purge per ADR-0001 while `state.json` is never
  touched by the module. Tagged `filemgr`, `CATEGORY=optional`,
  `DEPENDS_ON=()` (Q39).
- **`lnav.module.sh` v2 module** (issue #62, PRD §6.3.3 Batch C):
  migrates the `module/config/lnav_pkg/` based install (config bundle
  loaded ad-hoc via `lnav -I <path>`) to the v2 contract on the custom
  archetype — the apt `lnav` package plus the legacy lnav_pkg config
  bundle (theme, UI settings, custom log formats) deployed to
  `~/.config/lnav` so lnav loads it without the `-I` flag. All 10
  lifecycle phases run standalone (AC-25); install is idempotent (AC-5);
  `--dry-run` performs no filesystem writes (AC-12); the version Sidecar
  (dpkg-reported package version) is written on install/upgrade and
  removed on remove/purge per ADR-0001 while `state.json` is never
  touched by the module. `remove` keeps the deployed config bundle,
  `purge` wipes it. Tagged `logs`, `CATEGORY=optional`, `DEPENDS_ON=()`.
- **vscode module migrated to the v2 contract** (issue #59, PRD §6.3.3
  Batch C): `module/setup_vscode.sh` (v1) is superseded by
  `module/vscode.module.sh` on the apt archetype with a Microsoft vendor
  repo — deb822 source at `/etc/apt/sources.list.d/vscode.sources` signed
  by a dearmored `/etc/apt/keyrings/microsoft.gpg` (same shape as
  `docker.module.sh`), then `apt install code`. Demoted from recommended
  to optional (no longer the primary editor): `CATEGORY=optional`,
  `TAGS=(editor)`, `DEPENDS_ON=(apt-essentials)` (Q39). All 10 lifecycle
  phases run standalone (AC-25); install is idempotent (AC-5);
  `--dry-run` performs no filesystem writes (AC-12); the version Sidecar
  (dpkg-reported `code` version) is written on install/upgrade and
  removed on remove/purge per ADR-0001 while `state.json` is never
  touched by the module. `remove` keeps the vendor repo files for cheap
  re-install; only `purge` drops them.
- **codex module** (issue #58, PRD §6.3.2 Batch C, M7): new
  `module/codex.module.sh` installs the OpenAI Codex CLI from GitHub
  releases (`openai/codex`, native musl binary, github-release
  archetype) into `/opt/codex` with a `/usr/local/bin/codex` symlink.
  Arch-aware asset selection (x86_64 / aarch64), best-effort latest-tag
  lookup feeds the Sidecar (the download URL itself is
  version-independent), `rust-vX.Y.Z` tags normalised for
  `is_outdated`. Tagged `agent`; all 10 lifecycle phases runnable
  standalone (AC-25), idempotent install (AC-5), dry-run writes nothing
  (AC-12), Sidecar per ADR-0001. 84-test bats spec
  `test/unit/module/codex_spec.bats` (Q29 coverage ladder).
- **Color library + global output flags** (issue #45, PRD §5.1 / §7.5,
  M8, AC-16): new `lib/color.sh` decides ANSI color once per run —
  `auto` (default) turns color off for non-tty stdout, `NO_COLOR`,
  `TERM=dumb`, and background jobs; exposes the `CLR_*` palette
  (blank-safe when off), `color_enabled`, and a `colorize` helper.
  `dispatcher_dispatch` pre-parses position-independent global flags:
  `--color=auto|always|never` (exit 2 on a bad value, `always` forces
  escapes even piped, `never` strips them on a tty via the
  `INIT_UBUNTU_COLOR_MODE` override in `lib/logger.sh`),
  `--verbose`/`-v` sets `LOG_LEVEL=DEBUG`, and `--quiet` sets
  `LOG_LEVEL=WARN`. e2e bats pin AC-16: `setup_ubuntu list | cat`
  emits no ANSI escapes.

### Fixed

- **legacy small-tools Notion install GPU-crash on 24.04** (issue #35):
  `_install_notion()` in `module/setup_small_tools.sh` no longer runs
  `snap install notion-desktop` (the snap's bundled Mesa lacks
  iris/swrast, crashing the GPU process on Ubuntu 24.04); it now
  downloads the notion-electron `.deb` (anechunaev/notion-electron)
  and installs it via `apt install ./<deb>`.

- **Module phase exit codes could be masked in the runner sub-shell**
  (issue #66 follow-on, `lib/runner.sh`): the module sub-shell runs in an
  `if`-tested context where `set -e` is suspended, so any command appended
  after the phase call would overwrite the sub-shell's exit status. The
  phase exit code is now captured explicitly and re-raised via `exit`.
- **github-release archetype download URL 404** : `lib/module_helper.sh`
  built `releases/latests/download/` (one-char typo) so every real
  (non-mocked) install of an archetype-B module would 404. Fixed to
  `releases/latest/download/` + regression spec. Found independently by
  three Batch B module agents.

### Added

- **Sync SSH end-to-end** (issue #67, PRD §16, AC-15): `lib/sync.sh` now
  implements the full §16.3 flow. Remote tool check — a remote without
  `setup_ubuntu` exits 7 and prints the 3-line §3.4 bootstrap (apt
  install git → git clone → run); **no auto-rsync** (an orphan install
  without `.git` breaks self-upgrade) and **no unattended remote sudo**.
  Tool version skew between the two ends only warns; the hard
  compatibility gate stays with the payload schema version check inside
  the import pipeline (ADR-0008), on whichever side imports. Connection
  test keeps `StrictHostKeyChecking=yes` + `BatchMode=yes` (key-only —
  a missing key fails fast pointing at `setup_secrets ssh-key copy`,
  never a password prompt, PRD §16.4), remote import/export output
  streams back over the ssh channel, and conflict handling is fully
  delegated to the shared ADR-0013 import pipeline (issue #43). Ship
  gate per Q52: a dual-container integration suite
  (`test/integration/sync_ssh_spec.bats` + compose `sync-receiver`
  service under the `sync-e2e` profile) runs the real `ssh`/`scp` flow
  against a pinned host key — default push streams the remote
  `IMPORT DIFF` back without changes; `--apply` lands the module in the
  receiver's `state.json` through its real install pipeline (AC-15).
  `make test-integration` orchestrates receiver up → suite (`SYNC_E2E=1`)
  → teardown; other workflows skip the spec. `openssh` is baked into
  the test-tools image, and `/.tmp/` (throwaway E2E ssh keys) is now
  gitignored.
- **`fnm.module.sh` v2 module** (issue #56, PRD §6.3.1 Batch B, Q3/Q4):
  Fast Node Manager split out of `module/setup_neovim.sh` so the
  dependency is reusable (neovim and gemini both need Node.js). Custom
  archetype matching the legacy logic: the upstream install script
  (`https://fnm.vercel.app/install --skip-shell --install-dir`) performs
  a pure user-home install into `~/.local/share/fnm`
  (`SUPPORTS_USER_HOME=true`, `INSTALL_TARGET_DEFAULT=user-home`, no
  sudo), with `Schniz/fnm` release queries powering `is_outdated` and
  the Sidecar version. Shell integration is idempotent and
  marker-guarded: a fish `conf.d/fnm.fish` drop (user-owned files are
  never clobbered) and a fenced block appended to an existing
  `~/.bashrc` (never created); purge strips exactly what install added.
  Install also provisions the legacy default Node.js 22 (fail-soft) so
  dependents get a working `node`/`npm` out of the box. All 10
  lifecycle phases run standalone (AC-25); install is idempotent
  (AC-5); `--dry-run` performs no filesystem writes (AC-12); the
  Sidecar is written on install/upgrade and removed on remove/purge per
  ADR-0001 while `state.json` is never touched by the module. Tagged
  `cli-essentials`, `CATEGORY=optional`, `DEPENDS_ON=()`. Ships
  `test/unit/module/fnm_spec.bats` (94 tests, Q29 scope) with mocked
  fetch + GitHub queries (Q46: zero network in gates).
- **New `ripgrep` module on the apt archetype** (issue #55, PRD §6.3.1
  Batch B, Q41): `module/ripgrep.module.sh` installs the `ripgrep`
  package (binary: `rg`, fast grep alternative) — referenced by the
  neovim dep chain (telescope live-grep) but previously missing from
  the catalog. All 10 lifecycle phases run standalone (AC-25); install
  is idempotent (AC-5); `--dry-run` performs no filesystem writes
  (AC-12); the version Sidecar (dpkg-reported package version) is
  written on install/upgrade and removed on remove/purge per ADR-0001
  while `state.json` is never touched by the module. Tagged
  `cli-essentials`, `CATEGORY=optional`, `DEPENDS_ON=()`. Ships
  `test/unit/module/ripgrep_spec.bats` (63 tests, Q29 scope).
- **Install output UX** (issue #66, PRD §7.7, AC-35): the install pipeline
  now renders human-readable output derived from JSONL events (events are
  the single source of truth).
  - Per-module `[i/N] <name>: installing...` progress headers and
    `✔ <name> installed (Ns)` success lines (`lib/runner.sh`).
  - `exec_cmd` capture mode (`lib/general.sh`): inside the engine pipeline
    child stdout/stderr is no longer streamed — it is captured into one
    `cmd_exec` JSONL event per command (attributes: `cmd` / `exit` /
    `duration_ms` / `output`). New `--verbose` flag streams child output
    live (still captured); new `--quiet` flag suppresses progress lines
    and raises `LOG_LEVEL` to WARN. Legacy standalone `module/setup_*.sh`
    callers keep the streaming behavior (capture is opt-in via
    `INIT_UBUNTU_CMD_CAPTURE`, set only by the runner sub-shell).
  - On module failure: automatic dump of the last ~20 lines of that
    module's captured child output + `trace_id` + the JSONL log path.
  - End-of-session **Action required** aggregation (PRD §7.7.2):
    `module_emit_post_install` / `module_emit_reboot_required` now emit
    structured `action_required` events (`kind=post_install|reboot`,
    i18n-resolved message) after a successful install, and the engine
    derives the human-readable block from this session's events at
    session end — stdout and `jq 'select(.body=="action_required")'`
    over the session log never diverge (AC-35).
- **fdfind module migrated to the v2 contract** (issue #54, PRD §6.3.1
  Batch B): `module/submodule/fdfind.sh` (v1 GitHub tarball install) is
  replaced by `module/fdfind.module.sh` on the apt archetype — Ubuntu
  ships fd as the `fd-find` package whose binary is `fdfind`; the
  POST_INSTALL_MESSAGE explains the `alias fd=fdfind` shortcut. All 10
  lifecycle phases run standalone (AC-25); install is idempotent (AC-5);
  `--dry-run` performs no filesystem writes (AC-12); the version Sidecar
  (dpkg-reported package version) is written on install/upgrade and
  removed on remove/purge per ADR-0001 while `state.json` is never
  touched by the module. Tagged `cli-essentials`, `CATEGORY=optional`,
  `DEPENDS_ON=()` (also a neovim dependency for telescope file finding).
- **Self-deps preflight in the entrypoint** (issue #40, PRD §3.4 /
  AC-34): new `lib/preflight.sh` checks the tool's own dependencies
  (`jq` / `curl` / `git`) before dispatching. Missing + sudo available:
  prints an apt-style plan and asks once whether to `apt install`
  (automatic with `-y` / `INIT_UBUNTU_YES=true`); missing + no sudo:
  fails fast with exit 4 and explicit install guidance. `help` /
  `version` paths are exempt, and the check runs at most once per run
  (`INIT_UBUNTU_PREFLIGHT_DONE` guard). Resolves the chicken-and-egg
  where state/config/detect need `jq` but `jq` ships inside the
  `apt-essentials` module. Test rig gains `curl` (test-tools image +
  kcov coverage deps) so e2e specs driving the real entrypoint pass the
  preflight; the real apt-install path is reserved for the AC-34
  integration check in a clean CI container (wave 6).
- **`lazygit.module.sh` v2 module** (issue #48, PRD §6.3.1 Batch B):
  migrates `module/submodule/lazygit.sh` to the v2 contract on the
  github-release archetype. Versioned upstream assets
  (`lazygit_<ver>_Linux_x86_64.tar.gz`) are resolved at run time before
  super-calling the archetype fetch. All 10 lifecycle phases are
  runnable standalone (AC-25); the version Sidecar (shared
  `module_sidecar_*` helpers) is written on install/upgrade and deleted
  on remove/purge (ADR-0001), with `doctor` flagging
  Sidecar/install-state drift. Ships
  `test/unit/module/lazygit_spec.bats` (71 tests, Q29 scope) with
  mocked GitHub queries (Q46: zero network in gates).
- **Import/export with the ADR-0013 conflict pipeline** (issue #43,
  AC-14): `export <file> [--modules=<csv>]` ships only the
  machine-portable `synced` section of each installed module (ADR-0018);
  the machine-specific `local` section never leaves the host.
  `import <file>` runs the same conflict pipeline as `sync --pull`:
  **dry-run by default** (prints an `IMPORT DIFF` plan, writes nothing),
  `--apply` commits. Merge rules: union of modules (local-only entries
  are never deleted), remote-wins on `version_provided` / `depends_on`,
  `manual` sticky-to-true, and remote-only modules missing from the
  local catalog are skipped with a warning. The receiver rebuilds
  `local` sections via its own install pipeline; payload `local` data is
  never applied. New state helpers `state_get_synced` /
  `state_set_synced`, plus `state_io_import_plan` /
  `state_io_import_apply` (payload schema 0.2.0). `sync --apply` is
  forwarded to the importing side (push: remote `import --apply`; pull:
  local apply), so sync also defaults to dry-run per ADR-0013.
- **state.json synced/local split** (issue #43, ADR-0018, PRD §10.1):
  `installed.<m>` is now split into `synced` (manual, depends_on,
  version_provided, installed_at, installed_by — travels over
  sync/export) and `local` (machine-specific facts — never leaves the
  host). `state_record_install` gains an optional 4th `depends_on` csv
  arg and preserves the `local` sub-object across re-records;
  `state_record_upgrade` updates `synced`; `state_record_verify` stamps
  `local.last_verified_at`; `state_get_field` reads synced-then-local.
- **batcat module migrated to the v2 contract** (issue #53, PRD §6.3.1
  Batch B): `module/submodule/batcat.sh` (GitHub-release tarball) is
  replaced by `module/batcat.module.sh` on the apt archetype — installs
  the Ubuntu `bat` package (binary ships as `batcat`) and appends guarded
  `alias cat='batcat'` / `alias bat='batcat'` lines to existing
  `~/.bashrc` / `~/.zshrc` (alias target asserted against the real binary
  per the issue #1 copy-paste bug class; `LEGACY_DOTFILE=true` per spec
  §6.1). All 10 lifecycle phases run standalone (AC-25); install is
  idempotent (AC-5); `--dry-run` performs no filesystem writes (AC-12);
  the version Sidecar is written on install/upgrade and removed on
  remove/purge per ADR-0001 while `state.json` is never touched by the
  module. Tagged `cli-essentials`, `CATEGORY=optional`, `DEPENDS_ON=()`.
- **`setup_secrets.sh` skeleton: storage backend abstraction + ssh-key
  subcommands** (issue #44, PRD §14, AC-20): new standalone sensitive-data
  tool (not a module; shares `lib/logger.sh` / `lib/i18n.sh` /
  `lib/config.sh` only — no engine pipeline coupling, so the TUI can fork
  it later). New `lib/secrets.sh` implements the generic backend API
  (`secrets_store/retrieve/exists/list/remove`, stdin/stdout only — secret
  material never travels through argv) over three backends with PRD §14.3
  priority: `pass` → `gnome-keyring` (secret-tool + DBus) → encrypted file
  (`openssl enc` AES-256-CBC + PBKDF2, `~/.config/init_ubuntu/secrets/
  <name>.enc`, 0600/0700 perms, passphrase via `-pass env:` — never
  plaintext on disk). Autoselect honors `[secrets] backend` in config.ini
  and the `INIT_UBUNTU_SECRETS_BACKEND` env override. Subcommands shipped:
  `ssh-key generate` (passphrase prompting delegated to ssh-keygen's own
  tty — nothing sensitive in argv or shell history, AC-20), `ssh-key
  load` (ssh-add), `ssh-key copy <user@host>` (ssh-copy-id, remote
  failure → exit 7). `gpg` / `token` / `list` / `remove` are reserved
  stubs for issue #68 and mount directly on the backend API. Test-tools
  image gains `openssl` so the encrypted-file round-trip is tested for
  real in the container.
- **eza module migrated to the v2 contract** (issue #51, PRD §6.3.1
  Batch B): `module/submodule/eza.sh` → `module/eza.module.sh`
  (github-release archetype, `CATEGORY=optional`,
  `TAGS=("cli-essentials")`). Keeps the legacy behavior — tarball to
  `/opt/eza`, `/usr/local/bin/eza` symlink, `alias ls='eza'` dropped
  into `~/.bashrc` / `~/.zshrc` (removed on purge, kept on remove) —
  and adds Sidecar bookkeeping plus `is_outdated` / `doctor`. New
  shared Sidecar helpers in `lib/module_helper.sh`
  (`module_sidecar_write/remove/get_version/path`, ADR-0001) are
  available to all modules.
- **zoxide module** (issue #52, PRD §6.3.1 Batch B): migrated
  `module/submodule/zoxide.sh` to the v2 contract as
  `module/zoxide.module.sh` (smarter `cd`; aliases `cd` to `z`).
  Archetype B (github-release) with super-call overrides — the release
  asset name embeds the version, so install/upgrade resolve the latest
  tag first, then chain to the archetype default; both wire
  `zoxide init` + the `cd`→`z` alias into existing bash/zsh rc files
  (idempotent) and write the version Sidecar; remove/purge delete it
  (ADR-0001). All 10 lifecycle phases run standalone (AC-25); dry-run
  performs no filesystem writes (AC-12). New shared `module_sidecar_*`
  helpers in `lib/module_helper.sh` (path / write / remove /
  get_version, dry-run-safe) give Standalone and Engine mode one
  Sidecar code path — closes the cookbook's
  `module_sidecar_get_version` follow-up. Spec:
  `test/unit/module/zoxide_spec.bats` (49 tests).
- **fzf module migrated to the v2 contract** (issue #50, PRD §6.3.1 Batch
  B): `module/submodule/fzf.sh` (git-clone + `~/.fzf/install`) is replaced
  by `module/fzf.module.sh` on the github-release archetype — downloads
  the prebuilt single-binary tarball for the host arch (amd64 / arm64 /
  armv7) into `/opt/fzf` and symlinks `/usr/local/bin/fzf`. All 10
  lifecycle phases run standalone (AC-25); install is idempotent (AC-5);
  `--dry-run` performs no filesystem writes (AC-12); the version Sidecar
  is written on install/upgrade and removed on remove/purge per ADR-0001
  while `state.json` is never touched by the module. Tagged
  `cli-essentials`, `CATEGORY=optional`, depends on `apt-essentials`.
- **lazydocker module migrated to the v2 contract** (issue #49, PRD
  §6.3.1 Batch B): `module/lazydocker.module.sh` (docker TUI,
  github-release archetype with a version-aware fetch override —
  upstream asset names embed the release version). Metadata per PRD
  §9.1 (`CATEGORY=optional`, `TAGS=(cli-essentials)`,
  `DEPENDS_ON=(docker)`, i18n `DESCRIPTION`). All 10 lifecycle phases
  run standalone (AC-25); install is idempotent (AC-5); `--dry-run`
  writes nothing (AC-12). New `module_sidecar_*` helpers in
  `lib/module_helper.sh` implement the ADR-0001 Sidecar (written on
  install/upgrade, dropped on remove/purge, never touching
  `state.json` in standalone mode); `is_outdated` compares the Sidecar
  version against the latest GitHub release.

- **Session-end log retention** (issue #42, PRD §10.2, AC-33): new
  `logger_prune_logs` in `lib/logger.sh` prunes the JSONL log directory
  at session end — keeps the newest 100 `.jsonl` files and none older
  than 30 days; when either limit is exceeded it deletes from the oldest
  (logrotate-like, pure bash/find, no external dependency; both limits
  env-overridable via `INIT_UBUNTU_LOG_RETENTION_{DAYS,FILES}`). Wired
  into `lib/runner.sh` right after the `session_end` event so the active
  log file (newest mtime) is never a victim; pruning emits one
  engine-level `log_pruned` OTel event (ADR-0006 schema) carrying
  `deleted_count` + retention limits. Boundaries are keep-side inclusive:
  exactly 100 files / exactly 30 days old are kept.
- **State robustness** (issue #41, PRD §10.1): reading a corrupt
  `state.json` now quarantines it (`mv` → `state.json.corrupt.<ts>`) and
  fails fast (exit 1) with recovery guidance — re-run install to rebuild
  records (modules are idempotent) or manually fix the quarantined file
  and rename it back. Never silently rebuilt, so manual / dep snapshot
  data is never lost (automated repair stays `doctor --fix`, 0.3.0).
  Contended state writes print a one-line wait notice; after
  `INIT_UBUNTU_LOCK_TIMEOUT` (default 30 s) the writer exits 1 printing
  the lock holder info (PID / lock file path).

### Changed

- **CI unit tests and coverage merged into a single bats run**
  (issue #28, AC-17): every `test-unit` matrix shard now runs bats ONCE
  under kcov (`make coverage-unit MODULE=<name>|core`, new `ci.sh
  --kcov` flag; shard output `coverage/shard-<name>`, uploaded as a
  per-shard artifact) instead of the previous separate `test-unit` +
  `coverage` double run. The standalone `coverage` job becomes an
  aggregation job: it downloads all shard artifacts, merges them with
  `kcov --merge` (`make coverage-merge`, new `ci.sh --merge-coverage` /
  `--ci-merge-coverage` modes), and asserts the coverage gate on the
  MERGED result — never per shard. The gate is a **ratchet**:
  `COVERAGE_MIN` defaults to 66 (honest merged baseline 66.70%,
  measured 2026-06-07) to prevent regression; AC-17's 80% final value
  is unchanged — #122 (lib specs) and #123 (engine specs) boost the
  weak areas, then #124 flips the default to 80. Enforcement is
  **full-matrix-only**: `discover` emits a `full` output (is the
  selection the complete modules + core cartesian?) which the coverage
  job forwards as `COVERAGE_ENFORCE` — narrow-matrix PRs (only changed
  shards ran) merge to a structurally low number because unrun shards'
  source files still count in the denominator, so they print the
  percentage report-only; full-matrix runs (push to main / shared
  fan-out) enforce. Zero shards (every selected shard was a spec-less
  green skip) green-skips the merge too; doc-only PRs skip the whole
  chain and `ci-passed` name/aggregation semantics stay unchanged.
  Local `make coverage` (full kcov run, unit + integration) is
  untouched.
- **Unit tests run as a per-module CI matrix** (issue #31, PRD M10): a
  `discover` job builds the matrix dynamically from `module/*.module.sh`
  (`fail-fast: false`, `timeout-minutes: 5` per shard) and non-module
  specs (engine/lib/hook/script/template) run in a single
  `test-unit (core)` job. `make test-unit MODULE=<name>` (and
  `MODULE=core`) narrows the bats run via the new `ci.sh --module` flag;
  a module without a spec yet is a green skip. Runtime-generated
  `dorny/paths-filter` filters (`script/ci/generate_module_filters.sh` +
  `script/ci/select_unit_matrix.sh`) make PRs run only the shards for
  changed modules — `lib/`/`script/`/`Makefile`/workflow changes (or any
  code change outside the known filters) fan out to the full matrix, and
  pushes to main / tags always run the full matrix. `ci-passed` name and
  aggregation semantics unchanged (skipped shards still count as pass);
  every shard reuses the `build-image` test-tools artifact (#26).
- **Module tools directory relocated to top-level `tool/`** (issue #46,
  PRD §6.5): holding area for one-off scripts — not in the module
  catalog, not in the TUI, not in the install pipeline; per-file
  destinations deferred to 0.2+. Engine registry scan (`lib/registry.sh`)
  only reads `module/*.module.sh`, so `tool/` is outside its scope.
  CI lint prune list, kcov excludes, and `.codecov.yaml` ignore updated.
  ADR-0021 leftovers finished in the same pass:
  `test/unit/hooks/`→`test/unit/hook/`,
  `test/unit/scripts/`→`test/unit/script/`.
- **CI path filter now actually skips heavy jobs on doc-only / meta-only
  PRs** (issue #27): the all-negated `changes` filter gets
  `predicate-quantifier: every` (without it the default `some` quantifier
  matched nearly every file, so `code` was effectively always true), and
  the exclusion list adds `.claude/**`, `.github/ISSUE_TEMPLATE/**`, and
  `**/*.adoc`. `ci-passed` name and aggregation semantics unchanged
  (skipped heavy jobs still count as pass).
- **CI builds the test-tools image once and reuses it** (issue #26):
  new `build-image` job builds `test-tools:local` via
  `docker/build-push-action@v6` with GHA layer cache and uploads it as a
  1-day tar artifact; `lint` / `test-unit` / `test-integration`
  `docker load` the artifact instead of cold-building per job. `coverage`
  runs in the upstream `kcov/kcov` image and skips the test-tools build
  entirely. `Makefile` gains a `TEST_TOOLS_PREBUILT=1` escape hatch that
  drops the `build-test-tools` prerequisite (CI-only; local dev behavior
  unchanged). `ci-passed` aggregator now also requires `build-image`
  (required-check name unchanged).
- **Folder naming reverted to all-singular** (issue #32, ADR-0021
  supersedes ADR-0005): `docs/`→`doc/`, `tests/`→`test/`
  (`helpers/`→`helper/`, `unit/modules/`→`unit/module/`),
  `scripts/`→`script/`, `modules/`→`module/`, `templates/`→`template/`,
  `.claude/hooks/`→`.claude/hook/`, `.claude/scripts/`→`.claude/script/`,
  `docs/agents/`→`doc/agent/`, `docs/processes/`→`doc/process/`,
  `docs/guides/`→`doc/guide/`. Upstream-imposed dirs and acronyms
  (`adr/`, `prd/`, `ci/`) unchanged; file names ending in `s` deferred
  to 0.2.0. User-local module dir is now
  `${XDG_CONFIG_HOME}/init_ubuntu/module/` (was `.../modules/`).

### Added

#### M1 — PRD + architecture + module contract (commit 50a41eb)

- Product spec at `doc/prd/init-ubuntu.prd.md` covering MVP scope, milestones
  (M1-M15), acceptance criteria, exit codes, CLI surface, state model.
- System architecture at `doc/architecture.md` covering engine layering
  (dispatcher / runner / registry / resolver / state).
- Module v1 contract at `doc/module-spec.md` defining metadata schema,
  lifecycle functions, archetype concepts.

#### M2 — Test harness (commit 82b5a7e)

- Borrowed + customized `ycpss91255-docker/base` v0.28.0 test rig.
- Docker-only test execution via `Makefile` + `script/ci/ci.sh` +
  `compose.yaml`.
- bats unit + integration test infrastructure at `test/unit/` and
  `test/integration/`.

#### M3 — Engine basics: logger, helpers, environment detection (commits 4502ecc, 62b173f)

- `lib/logger.sh` with JSONL `log_event` for structured CI-friendly logs.
- `lib/general.sh` with portable helpers (`have_sudo_access`, `is_wsl`, ...).
- `lib/detect.sh` + `lib/platform.sh` with `INIT_UBUNTU_FORM_FACTOR`
  classifier (desktop / server / wsl / container variants).

#### M4 — Module engine: registry, resolver, runner, state (commits 41fca5f, 6827b79, c5af7a4)

- `lib/registry.sh` — module discovery, metadata extraction, DEPENDS_ON
  graph build.
- `lib/resolver.sh` — topological sort with cycle detection +
  CONFLICTS_WITH validation.
- `lib/runner.sh` — per-phase orchestration with sub-shell isolation,
  JSONL phase events, state.json recording.
- `lib/state.sh` — `${XDG_STATE_HOME}/init_ubuntu/state.json` with flock,
  import/export, atomic writes.
- `module/apt-essentials.module.sh` — reference module (apt archetype).
- `module/docker.module.sh` — reference module (custom archetype).
- `template/module.template.sh` — v1 module skeleton.
- `test/unit/e2e_spec.bats` — end-to-end install/remove dry-run.

#### M5 — CLI + sync + apt-style subcommands (commit be6e5b1)

- `setup_ubuntu.sh` dispatcher with apt-aligned subcommands:
  `install / remove / purge / list / show / status / update / export /
  import / help / version`.
- `lib/sync.sh` — sync `state.json` ↔ filesystem reality after manual
  apt operations.
- `lib/config.sh` — `${XDG_CONFIG_HOME}/init_ubuntu/config.ini` reader
  with `[section.key]` access pattern.

#### M7-A — v2 module contract refactor (commit 6fc3d6c)

- All 10 lifecycle functions become mandatory (ADR-0002):
  `detect / is_recommended / is_installed / install / upgrade / remove /
  purge / verify / is_outdated / doctor`. (`upgrade` was `update` at this
  commit, renamed later in #68.)
- i18n migrated from scalar `DESCRIPTION_EN` / `_ZH_TW` to associative
  array `declare -gA DESCRIPTION=([en]=... [zh-TW]=...)`. Supported langs:
  en, zh-TW, zh-CN, ja.
- Standalone vs Engine dual-mode header: `bash module/foo.module.sh install`
  works as a self-contained CLI without `setup_ubuntu` (ADR-0001 defines
  the Sidecar vs state.json write split).
- Archetype macros `module_use_apt_archetype` / `_github_release_` /
  `_config_` — one-line lifecycle binding.
- Metadata fields trimmed: dropped MAINTAINER, RECOVERY_FALLBACK,
  PARALLEL_GROUP, INSTALL_TIME_ESTIMATE, DISK_SPACE_ESTIMATE.
- Folder naming convention enforced (singular):
  `doc/` → `doc/`, `test/helper/` → `test/helper/`,
  `test/unit/module/` → `test/unit/module/`, `tool/` →
  `tool/`. Hook `.claude/hook/test-must-use-docker.sh` enforces
  Docker-only test execution (ADR-0004).
- ADRs 0001-0004 introduced (`doc/adr/`):
  0001 standalone/engine state boundary,
  0002 all 10 lifecycle functions mandatory,
  0003 language choice + migration triggers,
  0004 tests-must-run-in-docker-only.
- `CONTEXT.md` domain glossary added.
- Refactored 10 v2 modules: apt-essentials, docker, fish, font,
  git-config, neovim, nvidia-driver, shell, ssh-config, tmux.

#### M7-#68 — Template split into 4 archetypes (commit 57df2e3)

- `template/module.template.sh` (unified, all archetypes commented out)
  replaced with 4 specialized templates:
  - `template/module-apt.template.sh` (archetype A)
  - `template/module-github-release.template.sh` (archetype B)
  - `template/module-config.template.sh` (archetype C)
  - `template/module-custom.template.sh` (archetype D, hand-written)
- `test/unit/template_consistency_spec.bats` — hash-compares shared
  sentinel-delimited sections (shared-bootstrap / shared-metadata /
  shared-lifecycle-stubs / shared-footer) across the 4 templates to
  detect drift.
- `test/unit/template_smoke_spec.bats` — rewritten to iterate the 18
  smoke checks (`--help` / `--version` / install/upgrade/remove/purge/
  verify --dry-run / is-installed / is-outdated / doctor / info /
  status / source-mode / no-side-effects) across all 4 archetypes.
- Test count: 255 → 267 (8 new archetype-iterating smoke + 11 consistency).

#### CI workflow — GitHub Actions (issue #2)

- `.github/workflows/ci.yaml` with 5 jobs:
  - `lint` — `make lint` (shellcheck + hadolint + fish syntax),
    always runs even on doc-only PRs.
  - `test-unit` — `make test-unit`, skipped on doc-only PRs.
  - `test-integration` — `make test-integration`, skipped on doc-only.
  - `coverage` — `make coverage` (kcov), uploaded as artefact;
    skipped on doc-only.
  - `ci-passed` — aggregator that succeeds iff lint passed and the
    heavy three either passed or skipped. Single check name for
    `required_status_checks` to anchor on (#3).
- Path filter via `dorny/paths-filter@v3`: `code` output is `false`
  for changes touching only `doc/**`, `**/*.md`, `LICENSE*`,
  `.gitignore`, `.codecov.yaml`.
- Triggers: PR to `main`, push to `main`, push to `v*` tags (so
  `release-tag.sh`'s CI-conclusion query for RC tags works).
- `concurrency` group cancels in-flight PR runs on new pushes.

#### ShellCheck baseline — base-aligned, no global config

Convention: no project-wide `.shellcheckrc`. Every disable lives at its
call site with a wiki-link rationale, matching the upstream
`ycpss91255-docker/base` pattern. Lint level stays at shellcheck's
default severity (style/info/warning/error all reported).

- `script/ci/ci.sh`:
  - Fix exclude-path typo `module/tool` → `tool` (post-
    ADR-0005 plural rename had not been propagated).
  - Extend `_find_lintable_sh` to pick up `*.bash` + `*.bats` too.
  - Exclude legacy paths slated for removal per PRD §6.5/§6.6:
    `module/submodule/`, `module/function/`, `module/setup_*.sh`,
    `module/anydesk.sh`, `install-nvidia-driver.sh` — these predate
    the v2 module pattern; their shellcheck disables stay as-is until
    relocation.
  - Add `jq` to `_install_deps_for_coverage` apt-get list (kcov/kcov
    image lacks it; `lib/state.sh` needs jq for state.json mutation).
  - Refactor `_bats_args` → `_set_bats_args_arr` populating global
    `BATS_ARGS_ARR`; callers now `bats "${BATS_ARGS_ARR[@]}"` instead of
    `bats $(_bats_args)` (SC2046 proper fix).
- Proper fixes (no disable):
  - `lib/detect.sh:268`, `lib/platform.sh:42`: escape `\}` in case
    pattern (SC1083 — literal `}` matches JSON `null}` object close).
  - `lib/module_helper.sh`: remove `"$@"` from 18 archetype inner
    wrappers — never called with args, fixes SC2119/SC2120.
  - All `lib/*.sh` + `module/*.module.sh` + `template/*.sh`:
    defensive `${BASH_SOURCE[0]:-}` / `${0:-}` (matches base).
  - `test/unit/module_helper_spec.bats:205`: use
    `declare -A DESCRIPTION=([en]="...")` for assoc array (SC2190).
  - `module/font.module.sh`: `command -v X && X || true` → explicit
    `if ... then ... fi` (SC2015).
- Disable-with-rationale (wiki-link inline at each disable):
  - 10 `module/*.module.sh` + 4 `template/module-*.template.sh`:
    file-top SC2034 — metadata vars consumed by engine post-source.
  - 1 `test/unit/module_helper_spec.bats` file-top SC2034/SC2317.
  - 6 `test/unit/*_spec.bats`: file-top SC1091 — tests source libs
    via runtime `${LIB_DIR}` shellcheck can't statically resolve.
  - `lib/module_helper.sh`: file-top SC2317 — archetype-macro inner
    wrappers dispatched indirectly via `${_phase}` (lib/runner.sh).
  - `lib/sync.sh`: file-top SC2029 — SSH cmds expand `${_remote_path}`
    client-side intentionally.
  - `module/docker.module.sh`: per-fn SC2032/SC2033 above `install()`
    — function name shadows `/usr/bin/install`; harmless because `sudo
    install` invokes the binary (sudo clears function table).
  - `test/unit/i18n_spec.bats`: file-top SC2030/SC2031 — bats `run`
    spawns subshell, test setups `export LANG=...` stage env.
  - `test/unit/module/docker_spec.bats`, `template/test.template.bats`:
    file-top SC2317 — test mocks dispatched indirectly.
  - `test/unit/template_smoke_spec.bats:34`: per-block SC2016 above
    multi-line `sed` with literal `${MODULE_DIR}` template placeholders.
  - `lib/module_helper.sh:45`: per-line SC2120 on i18n wrapper —
    optional `<lang>` arg.
  - `lib/module_helper.sh:478`: per-line SC2119 on call without args
    (uses INIT_UBUNTU_LANG default).

#### Engine subshell isolation: `bash -c` → `(...)` (coverage compat)

`lib/runner.sh:_runner_run_phase` switches the module-dispatch
subshell from `bash --noprofile --norc -c "..."` to `(...)` fork.

Why: kcov-instrumented bash (the coverage target's image) leaves
`$BASH_SOURCE` / `$FUNCNAME` unbound inside `bash -c` contexts.
Under `set -u`, kcov's ptrace-driven line-attribution hits the
unset parameter and tears down the subshell on every command. The
fork-style subshell inherits these arrays from the parent shell, so
the strict-mode contract holds and coverage instrumentation stays
happy. Isolation guarantee is unchanged — `(...)` is still a true
subshell (side-effects don't leak back to the engine), just cheaper
than `exec`-ing a new bash.

Parent shell (`setup_ubuntu.sh` or bats `_load_engine`) is now
responsible for sourcing `logger.sh` / `general.sh` /
`module_helper.sh` once; the subshell inherits them. The subshell
still `source`s the module file itself and dispatches to `${_phase}`.

- `.gitignore`: add `/coverage/` to ignore the kcov output dir.

#### ADR-0006 — OTel-aligned logger schema (decision only; issue #8)

- `doc/adr/0006-otel-aligned-logger-schema.md` — decision to migrate
  `lib/logger.sh` `log_event` JSONL output to mirror the OpenTelemetry
  Logs Data Model + W3C Trace Context, without adopting the OTel SDK
  or Collector. Sourced from the project author's observability
  playbook (Notion: "Debug 資訊架構：從 print 到 Observability",
  2026-05-12). Key choices:
  - Field rename: `ts` → `timestamp`, `level` → `severity_text`,
    `event` → `body`, top-level `module` → nested
    `attributes.service.name`.
  - All business payload nested under `attributes` (OTel SemConv).
  - Add `attributes.service.lang = "bash"`, `attributes.code.filepath`
    + `code.lineno`.
  - Add `trace_id` (per-`setup_ubuntu`-invocation, UUID v7 preferred)
    + `span_id` (per-phase-per-module). Auto-propagate via env into
    sub-shells.
  - Mirror `log_info` / `log_warn` / `log_error` to JSONL too.
  - Per-session log file rotation:
    `${XDG_STATE_HOME}/init_ubuntu/logs/<trace_id>.jsonl` + `latest`
    symlink.
  - `doc/guide/log-queries.md` will ship lnav format file with
    `opid-field: trace_id` (free timeline view) + jq snippet library.
- Implementation deferred to issue #8; gated on PRs #4 / #6 / #7
  merging first to avoid CHANGELOG and `lib/runner.sh` conflicts.

#### Archetype cookbook (issue #5, task #69)

- `doc/guide/archetype-cookbook.md` — companion to the 4 archetype
  templates. Documents:
  - Decision tree for picking archetype A / B / C / D.
  - Pure-archetype usage (apt-essentials, neovim, git-config, font).
  - **Hybrid + super-call override pattern** — using
    `module_use_apt_archetype` then overriding `install()` (docker
    is the reference: apt-repo key+source setup + `usermod -aG`).
  - Capture-and-chain pattern: `_orig_install=$(declare -f
    module_default_apt_install | sed '1d;$d')` to `eval` the
    original then add post-steps.
  - `is_outdated()` recipes per archetype (apt-list-upgradable,
    gh-release-tag-compare, sha256sum-config-hash, custom).
  - 5 common pitfalls: bad-substitution arrays, `declare -A` vs
    `declare -gA`, `cd` outside subshell, standalone vs engine
    state writes (ADR-0001), `update` vs `upgrade` naming.
- Templates' authoring docstring paths fixed:
  `doc/guide/archetype-cookbook.md` → `doc/guide/archetype-cookbook.md`
  (per ADR-0005, plural for the collection dir).

#### wait-pr-ci skill + hook (issue #15)

Port of docker_harness's `wait-pr-ci` triple so `gh pr create` is
followed by a non-context-burning CI monitor instead of a sleep
poll. Three components:

- `.claude/script/wait-pr-ci.sh` — the polling primitive. Wraps
  `gh pr view` + `gh pr checks` with terminal-state detection
  (success / failure / merged / closed). Designed to be the body
  of a Claude Code Monitor invocation. SKIPPED checks count as
  success (matches the path-filter doc-only behaviour from #4's
  CI workflow).
- `.claude/skills/wait-pr-ci/SKILL.md` — agent-facing flow doc.
  When to invoke (post `gh pr create`, post force-push, when
  checking on another agent's PR), how to read the output.
- `.claude/hook/remind_pr_wait_ci.sh` — PreToolUse Bash hook.
  Fires when the agent is about to run `gh pr create` and emits
  a non-blocking systemMessage reminding to invoke the skill
  after the PR opens. Registered as the 8th entry in
  `.claude/settings.json` PreToolUse Bash matcher.

#### User-local module discovery (issue #13, PRD §13.2 Q35)

- `lib/registry.sh`: `registry_load_all` now scans a second directory
  after the bundled `module/` — defaults to
  `${INIT_UBUNTU_USER_MODULE_DIR:-${XDG_CONFIG_HOME:-${HOME}/.config}/init_ubuntu/module}`.
  Skipped silently if absent (engine works on hosts that never opt in).
- Name collision: user-local wins by overwriting the bundled entry;
  `log_warn` (or stderr fallback if logger not loaded) reports the
  override with both paths.
- Internal: existing scan loop extracted to private
  `_registry_load_one_dir(dir, is_user_local)` helper. Public API
  `registry_load_all` keeps backwards-compatible single-arg
  signature.
- Tests: 267 → 271 (4 new in `test/unit/registry_spec.bats`):
  - user-local module appears in `registry_list_names`
  - user-local NAME collision overrides bundled metadata
  - collision emits `user-local override` warn line
  - absent user dir is a no-op

#### apt archetype: is_outdated default via apt list --upgradable (issue #11)

- `lib/module_helper.sh`: new `module_default_apt_is_outdated` —
  returns 0 (outdated) if any package in `APT_PKGS` appears in
  `apt list --upgradable` output, 1 otherwise. No sudo required;
  graceful on hosts without apt (`apt -> empty -> 1`).
- `module_use_apt_archetype` macro now binds `is_outdated()` too
  (was 6 fns → 7 fns). Module authors get the default for free; can
  still override after the macro.
- Test: `module_use_apt_archetype` function-list assertion updated
  to include `is_outdated` (now 7).
- Test: `template_smoke_spec`'s `is-outdated` case split per
  archetype — apt returns 1 (macro-provided, empty APT_PKGS = not
  outdated); github-release / config / custom still return 2 (not
  implemented).

Follow-ups (not in this PR):
- github-release archetype `is_outdated` default — needs a
  `module_sidecar_get_version` helper to read
  `${XDG_STATE_HOME}/init_ubuntu/versions/<name>`. Separate task.
- config archetype `is_outdated` default — sha256sum-based diff;
  ~15-line stub but ships cleanly in its own PR.

#### Engine: upgrade / verify subcommands + state.json fields (issue #7)

- `setup_ubuntu upgrade [<module>...] [-y] [--dry-run]` — calls each
  module's `upgrade()` (was previously misrouted to `runner_install`).
  No args = upgrade every module recorded in `state.json` as
  installed. Engine refuses root for the real-run path
  (PRD §10), dry-run + empty-modules paths stay root-safe.
- `setup_ubuntu verify [<module>...] [--dry-run]` — new subcommand,
  calls each module's `verify()`. No args = verify all installed.
  Safe to invoke as root (no apt mutation).
- `lib/runner.sh`: `runner_upgrade` / `runner_verify` / `runner_doctor`
  added on top of the generic `_runner_run_phase`. All three
  hand off to module's `upgrade()` / `verify()` / `doctor()` per
  ADR-0002.
- `lib/state.sh`:
  - `state_record_upgrade <name> <version>` — stamps
    `version_provided` + `last_upgraded_at` (ISO 8601 UTC).
    No-op if the module isn't in `.installed`.
  - `state_record_verify <name>` — stamps `last_verified_at`.
- Runner state-recording switch (`_runner_run_phase`) updated:
  on successful `upgrade` → `state_record_upgrade`; on successful
  `verify` → `state_record_verify`. Existing `install` /
  `remove` / `purge` recording unchanged.
- Tests: 267 → 278 (5 new runner phase tests + 6 state-record
  tests).

`setup_ubuntu doctor` per-module behaviour (running each module's
`doctor()` instead of the existing state-drift detection) is
deferred to a follow-up — `runner_doctor` is implemented but the
existing `_dispatcher_doctor` keeps its current state-drift
semantics until the design question (state-drift vs per-module
doctor()) is decided.

#### Release workflow — port from docker_harness#22 + #106 (commit 1b40cfb)

Alignment with `ycpss91255-docker/docker_harness` release infrastructure:

- `.claude/script/release-tag.sh` — canonical primitive for cutting
  version tags. Decision tree: RC tag short-circuits; `Z>0` patch
  short-circuits; `Y` bump requires passing `vX.Y.0-rcN` CI; `X` bump
  also requires `RELEASE_X_BUMP_ACK=<tag>`. Verifies `.version`
  literal matches the tag.
- `.claude/skills/semver-bump/SKILL.md` — agent-facing companion.
- `.claude/hook/enforce_semver_tag_via_script.sh` — DENIES ad-hoc
  `git tag v*` / `git push origin v*` / `git push --tags`; forces
  callers through `release-tag.sh`.
- `.claude/hook/check_main_fresh_before_worktree.sh` — BLOCKs
  `git worktree add ... main` when local main is behind origin/main.
- `.claude/hook/remind_main_sync.sh` — non-blocking reminder on
  `gh pr merge` to `git pull --ff-only origin main` after merge.
- `.claude/hook/check_changelog_drift.sh` — non-blocking reminder when
  `git commit` stages non-doc code without a CHANGELOG entry.
- `.claude/hook/enforce_gh_body_file.sh` — enforces `--body-file`
  convention on `gh issue/pr create/comment` (docker_harness
  gh-artifact-format skill rules 1-8).
- `.claude/hook/enforce_gh_english.sh` — **new (not in docker_harness)**:
  DENIES `gh issue/pr create/comment` whose title / body contains CJK
  characters. Project rule: GitHub interaction is English-only.
- `doc/process/release.md` — release workflow documentation.
- `doc/process/worktree.md` — already in [Unreleased] under Phase 1
  (commit 6e840d1).
- `.version` — `v0.0.0` baseline (commit 6e840d1).
- All 7 hooks registered in `.claude/settings.json`.

#### ADR-0007 + transcript-bound shellcheck-disable approval hook (issue #17)

Codifies the ShellCheck base-alignment discipline (`# shellcheck disable=...`
gated by wiki-link rationale + user approval) from PR #4 into an enforceable
hook plus rationale doc:

- `doc/adr/0007-exit-code-contract-scripts-default-to-set-uo.md` — ADR
  documenting the project convention that exit-code-contract scripts
  (`.claude/hook/*.sh`, `.claude/script/release-tag.sh`) default to
  `set -uo pipefail` (not `-euo`). Cites BashFAQ #105 + Google Shell
  Style Guide; lists exception criteria for `-euo` (always-act scripts
  like `test-must-use-docker.sh`).
- `CLAUDE.md` (`AGENTS.md`) — new `## Script conventions` section
  indexing ADR-0007 and the new hook for agent-facing discoverability.
- `.claude/hook/enforce_shellcheck_disable_approval.sh` — PreToolUse
  hook on `Edit|Write|MultiEdit`. Blocks (`permissionDecision: deny`)
  any newly added `# shellcheck disable=SC<code>` directive unless the
  user has explicitly approved that code in their most recent message
  via the phrase `approve SC<code>` (case-insensitive on the verb;
  batchable: `approve SC2034 SC1091`). Approval is read from the
  system-controlled session transcript path (`transcript_path` in the
  PreToolUse JSON) — it cannot be forged. Emergency bypass via
  `ECC_ALLOW_SHELLCHECK_DISABLE=1` env var.
- Internal modules (functions sourced for bats testing in isolation):
  `read_latest_user_message`, `new_shellcheck_disables`,
  `is_disable_approved`, `main`.
- `test/unit/hook/{transcript_reader,disable_diff,approval_check,enforce_shellcheck_disable_approval}_spec.bats`
  — bats specs for each module + integration test for the hook entry.
- `.claude/settings.json` — hook registered as the 2nd `PreToolUse`
  matcher block (`Edit|Write|MultiEdit`).

### Changed

- **Folder naming reverted to plural-for-collections + singular-for-concepts**
  (ADR-0005). M7-A's "all folders singular" hard rule is replaced after
  three observations forced a re-evaluation: industry convention is
  plural for collections (Linux kernel, Python, Rust, Git internals);
  sibling repo `ycpss91255-docker/docker_harness` is itself mixed; the
  exception list for upstream-mandated plurals kept growing. Renames:
  `doc/` → `doc/`, `doc/agent/` → `doc/agent/`,
  `doc/process/` → `doc/process/`, `module/` → `module/`,
  `module/tool/` → `tool/`, `script/` → `script/`,
  `script/hook/test-must-use-docker.sh` → `.claude/hook/test-must-use-docker.sh`
  (also relocated since all hooks are Claude PreToolUse, matching
  docker_harness `.claude/hook/`), `test/` → `test/`,
  `test/helper/` → `test/helper/`,
  `test/unit/module/` → `test/unit/module/`,
  `template/` → `template/`. Kept singular: `lib/`, `doc/adr/`,
  `doc/changelog/`, `doc/prd/`, `module/config/`,
  `module/submodule/` (deprecated path), `script/ci/`,
  `test/unit/`, `test/integration/`. AGENTS.md Hard rule #2
  rewritten to point at ADR-0005.
- **Lifecycle phase rename: `update()` → `upgrade()`** (commit 57df2e3).
  PRD §5.1 / §13.2 has long aligned the CLI with apt
  (`setup_ubuntu update` = registry rescan, `setup_ubuntu upgrade` = run
  lifecycle upgrade) but the implementation still defined module-level
  `update()`. Renamed across:
  - `lib/module_helper.sh` archetype macros, default implementations,
    standalone CLI accepted phases, dryrun_guard labels, `--help` text.
  - 6 v2 modules (apt-essentials, docker, fish, font, nvidia-driver,
    tmux).
  - `test/unit/module_helper_spec.bats` archetype function-list assertion.
  - `setup_ubuntu update` (registry rescan subcommand) **unchanged**.
- **File rename: `lib/module_helpers.sh` → `lib/module_helper.sh`**
  (commit 57df2e3). Folder-name singular convention extended to filenames;
  `git mv` preserves history; all 16 references updated.
- AGENTS.md + `doc/agent/{issue-tracker,triage-labels,domain}.md` added
  (commit 68dcf55) for `setup-matt-pocock-skills` scaffolding;
  `CLAUDE.md` is a symlink to `AGENTS.md` so Claude Code and
  AGENTS.md-aware CLIs read the same content.
- `.claude/` and `CLAUDE.md` un-gitignored (commit 1a8f44c). Project-wide
  Claude Code config (hooks, plugins) moved into tracked
  `.claude/settings.json`; only `.claude/settings.local.json`
  (machine-specific permission allow-list) remains gitignored. The
  Docker-only PreToolUse hook now follows the repo on clone.

### Fixed

- `module/submodule/yazi.sh`: alias clobbered `cat` instead of installing
  `yz` (issue #1). The script wrote `command -v yazi &>/dev/null &&
  alias cat='yazi'` to `~/.bashrc` and `~/.zshrc` — looked like a
  copy-paste leftover from `batcat.sh` where `alias cat=bat` is the
  intended override. Now matches the fish config
  (`module/config/fish/conf.d/alias.fish`) which already uses
  `alias yz=yazi`. Users with the bad alias already in their rc files
  should `unalias cat` + remove the line manually (no auto-cleanup).

- `wait-pr-ci.sh` watch-start guard hung forever when launched after CI
  completion (issue #22). New `--stale-window <seconds>` flag (default
  120s) bounds the post-force-push race window — checks that completed
  more than `stale_window` seconds before `watch_start` are now trusted
  as a legitimate prior run instead of demoted to `pending`. Setting
  `--stale-window 0` restores the pre-fix always-demote behaviour.

- `module_default_apt_is_installed`: `${#APT_PKGS[@]:-0}` bad-substitution
  under `set -u` (would crash if an apt-archetype module's smoke test
  triggered the macro path) — replaced with `declare -p` existence
  check (commit 57df2e3).
- `module_standalone_usage` `--help` text missing `upgrade` phase
  (commit 57df2e3).
- PreToolUse hook `test-must-use-docker.sh` false-positive on commit
  messages and grep output containing literal "host bats" /
  "apt-get install" (commit 97e8c0e) — added first-token whitelist of
  safe commands (git, grep, sed, awk, ...).

### Removed

- Legacy `template/{func,module,submodule,test}_tmp.sh` (commit 6fc3d6c).
- Legacy `module/setup_*.sh` scripts being replaced by v2 modules
  (incremental, per M7 batch).
- 5 metadata fields no longer carried: MAINTAINER, RECOVERY_FALLBACK,
  PARALLEL_GROUP, INSTALL_TIME_ESTIMATE, DISK_SPACE_ESTIMATE (commit
  6fc3d6c).
- ECC plugin + marketplace (`affaan-m/everything-claude-code`) from
  `.claude/settings.json` — no longer used.

---

[Unreleased]: https://github.com/ycpss91255/initialization/compare/...HEAD
