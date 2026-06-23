# init_ubuntu Security Review

- Date: 2026-06-23
- Tag: v0.1.0-rc3 (commit b6c88bc, main)
- Reviewer lens: software-vulnerability / security audit, post-release-candidate.
  OWASP-style severity. READ-ONLY pass; no code was modified. This document
  RAISES issues for the maintainer to decide on. Nothing here is "fixed".

## Threat model note (read this first)

init_ubuntu is a single-maintainer, personal-use Ubuntu environment-init tool.
The realistic adversaries are:

1. A network attacker (MITM / DNS / BGP / upstream-infra compromise) against the
   download-and-install paths.
2. A local unprivileged co-user racing predictable temp paths while a privileged
   install runs.
3. Tampered/hostile input crossing a trust boundary: a sync payload from another
   host, a hand-edited state.json/config.ini, environment variables.

Crucially, the module files under `module/*.module.sh`, the libraries under
`lib/`, and `LIB_DIR`/`REPO_ROOT` are TRUSTED authoring inputs (they are the
program). Several mechanical "unquoted variable reaches bash -c" patterns exist,
but the interpolated values are repo-authored constants or registry data derived
from trusted on-disk module files — not attacker-controlled runtime data. Those
are reported at LOW (hygiene/robustness), not inflated to RCE, because under this
threat model they are not exploitable. Where a value genuinely does cross a trust
boundary, it is rated higher.

## Executive summary

Overall the codebase is careful and security-aware, especially the secrets
subsystem (`lib/secrets.sh`, `setup_secrets.sh`, `lib/tui_secrets.sh`) and the
state import/sync deserialization path (`lib/state_io.sh`, `lib/state.sh`), which
are clean. Most findings concern the software-supply-chain trust of third-party
downloads (no checksum/signature verification) and one production-reachable test
seam. No CRITICAL issue with a credible exploit path was found under the stated
threat model.

Counts by severity:

- CRITICAL: 0
- HIGH:     1
- MEDIUM:   4
- LOW:      6

Top issues for the orchestrator:

1. HIGH  — Test-only GitHub-fetch seam (`INIT_UBUNTU_TEST_GH_FIXTURE_DIR` /
   `INIT_UBUNTU_TEST_GH_VERSION`) is reachable in production via env vars with no
   test-mode gate; an attacker who can set env can swap the install payload.
2. MEDIUM — Root-privileged `tar`/`unzip` extraction of downloaded archives has no
   `--no-same-owner` and no path-traversal guard, so a malicious/MITM tarball can
   write as root outside `INSTALL_DIR`.
3. MEDIUM — No checksum/signature verification anywhere in the github-release
   archetype or the `curl | bash` installers (only a magic-byte sniff).

---

## Findings

### SR-01 (HIGH) — Production-reachable "test-only" GitHub-fetch seam

- File: `lib/module_helper.sh:306-311`, `lib/module_helper.sh:349-356`
- Description: The github-release archetype install honors two environment
  variables intended for offline tests:
  - `INIT_UBUNTU_TEST_GH_VERSION` (lines 306-311) redefines
    `get_github_pkg_latest_version()` to return the env value verbatim, shadowing
    the real network resolver.
  - `INIT_UBUNTU_TEST_GH_FIXTURE_DIR` (lines 349-356) makes the fetch
    `cp "${INIT_UBUNTU_TEST_GH_FIXTURE_DIR%/}/${GITHUB_ASSET_PATTERN}" "${_tmp}"`
    instead of downloading from GitHub.
  Both are gated ONLY on the variable being non-empty. There is no
  "are we in a test harness" guard (no Docker-only check, no separate
  `INIT_UBUNTU_TEST_MODE`), and the code comment itself says it is "Never set in
  production" — i.e. relies on convention, not enforcement.
- Exploit path: Any context that can influence the environment of a `setup_ubuntu
  install <ghr-module>` run (a poisoned shell rc, a wrapper script, a CI runner,
  a sudo policy that preserves env, or a compromised parent process) sets
  `INIT_UBUNTU_TEST_GH_FIXTURE_DIR=/tmp/evil` containing a file named exactly like
  the module's `GITHUB_ASSET_PATTERN`. The engine then copies that attacker file
  in, passes the gzip/zip sniff (attacker controls the bytes), and extracts it as
  root into `INSTALL_DIR` + symlinks it onto `PATH`. This converts "can set one
  env var" into "root-path binary planting" with no network needed. The receiver
  side of `sync` deliberately bakes these vars into a `/usr/bin/setup_ubuntu`
  wrapper (see `test/integration/sync/receiver-entry.sh:169-174`), demonstrating
  the seam reaches the real (non-dry-run) install lifecycle.
- Remediation OPTIONS (not applied):
  - Option A: Gate both seams behind a single dedicated test flag that production
    never sets, and additionally require an in-container marker (e.g. only honor
    them when `/.dockerenv` exists or `INIT_UBUNTU_IN_TEST=1`).
  - Option B: Move the fixture injection out of `module_helper.sh` into a
    test-only override file that is sourced only by the bats harness, so the
    production code path has no env branch at all.
  - Option C: At minimum, refuse the fixture path unless it resides under a
    known scratch root and is owned by the current user, and never honor the
    seam when `EUID==0`.
- Confidence: High that the seam is unconditionally env-gated and reaches the real
  install. Medium on real-world exploitability (depends on whether an attacker can
  set env for the install process — plausible but not trivial). Rated HIGH because
  it is a deliberate trust bypass that ships in the release artifact.

### SR-02 (MEDIUM) — Root archive extraction without `--no-same-owner` / path-traversal guard

- File: `lib/module_helper.sh:374` (`tar -C "${INSTALL_DIR}" --strip-components=… -xzf`),
  `module/fzf.module.sh:207` (`tar … -xzf` — also no `--strip-components`),
  `module/lazydocker.module.sh:199` (`sudo tar … -xzf`),
  `module/yazi.module.sh:210` (`sudo unzip -q -o "${_tmp}" -d "${INSTALL_DIR}"`).
- Description: Downloaded tarballs/zips are extracted with `sudo` (root) and no
  `--no-same-owner`, no `--no-same-permissions`, and no member-path validation.
  GNU `tar` with `-p` defaults under root will restore archived owner/uid/setuid
  bits; `tar` does strip a leading `/` by default but a member like
  `../../etc/profile.d/x.sh` or a symlink member can still write outside the
  intended directory tree. `unzip` does not protect against `../` members.
- Exploit path: Combined with SR-03 (no signature check) and SR-01, a
  MITM/compromised-mirror tarball can (a) carry setuid-root files, or (b) carry
  `../`-prefixed members or symlink members that escape `INSTALL_DIR` and land in
  a root-writable system path. The gzip/zip magic sniff
  (`file … | grep gzip` / `head -c2 == PK`) does not constrain member paths.
- Remediation OPTIONS:
  - Option A: Add `--no-same-owner --no-same-permissions` to every root `tar`,
    and prefer extracting as the invoking user where the target allows it.
  - Option B: Extract into a private staging dir first, validate that no member
    resolves outside it (reject absolute / `..` / symlink-escaping members), then
    move into place.
  - Option C: For `unzip`, validate entries or use a tool/flag that rejects
    traversal; pin `STRIP_COMPONENTS` semantics explicitly.
- Confidence: High on the missing flags (verifiable in the lines above). Medium on
  end-to-end exploitability since it requires an already-malicious archive (SR-03).

### SR-03 (MEDIUM) — No integrity verification on downloaded software

- Files (github-release archetype + per-module fetchers):
  `lib/module_helper.sh:357-366` (curl then `file … grep gzip` only),
  `module/fzf.module.sh:192-202`, `module/yazi.module.sh:192-202`,
  `module/notion.module.sh:213`, `module/font.module.sh:69-79`,
  `module/setup_font.sh:83-86`.
- Files (`curl | bash` / `curl | source` installers):
  `module/claude-code.module.sh:200` (`curl … "https://claude.ai/install.sh" | bash`),
  `module/fnm.module.sh:225-226` (`curl … "https://fnm.vercel.app/install" | bash -s --`),
  `module/fish.module.sh:95` (`fish -c "curl … fisher.fish | source && fisher install …"`),
  `module/qmk-firmware.module.sh` pipx + `module/setup_qmk_firmware.sh:60`
  (`curl -fsSL https://install.qmk.fm | sh`, legacy file — see SR-08).
- Description: All transport is HTTPS (good), but there is no SHA-256 / GPG /
  cosign verification of any downloaded artifact or installer script, and the
  github-release archetype targets `releases/latest/download/…` (no version
  pinning). The only post-download check is a content-type magic sniff
  (`file`/`head -c2`), which authenticates nothing.
- Exploit path: Upstream-infra compromise, a malicious mirror, or a TLS-MITM with
  a mis-issued cert delivers a trojaned binary/installer that is then executed or
  installed (often as root). `latest` also means a maintainer can never pin a
  known-good version and a yanked/republished release silently changes.
- Remediation OPTIONS:
  - Option A: For github-release modules, fetch the release's published checksums
    file, verify the asset SHA-256, and pin a version (`GITHUB_RELEASE_TAG`)
    instead of `latest`.
  - Option B: For `curl | bash` installers, download to a temp file, verify a
    pinned SHA-256 (or vendor GPG signature) before executing, rather than piping
    straight to the interpreter.
  - Option C: Accept the risk explicitly and document it per-module (these are
    upstream "official installer" archetypes); record the decision in an ADR.
- Confidence: High (verifiable absence of any checksum/signature step). This is
  partly a documented design choice for the "official installer" archetype, hence
  MEDIUM rather than HIGH.

### SR-04 (MEDIUM) — Predictable fixed remote temp path in sync

- File: `lib/sync.sh:262`, `lib/sync.sh:319` (`_remote_path="/tmp/init_ubuntu_sync.json"`),
  with `scp … "${_target}:${_remote_path}"` (l.263) and the remote
  `setup_ubuntu import ${_remote_path}` (l.272-274) / `export` (l.320).
- Description: The remote-side staging file is a FIXED, world-predictable name in
  a shared `/tmp`. The local sides correctly use `mktemp` (l.253, l.326), but the
  remote path is constant. Push writes it via `scp`; pull has the remote write it
  via `setup_ubuntu export`.
- Exploit path: On the remote host, a local unprivileged co-user pre-creates
  `/tmp/init_ubuntu_sync.json` as a symlink (e.g. to a file the sync user can
  write) or as a file they can read. `scp`/`export` then follows/overwrites the
  symlink (clobbering an arbitrary sync-user-writable file) or the attacker reads
  the imported payload (module-name metadata only — payload carries no secrets by
  design, ADR-0018, so confidentiality impact is low). Primarily an
  integrity/overwrite + race concern on multi-user remotes.
- Remediation OPTIONS:
  - Option A: Use `ssh … mktemp` to obtain a per-run remote temp path and pass it
    through, mirroring the local `mktemp` discipline.
  - Option B: Stage under the remote user's private dir (e.g.
    `${XDG_RUNTIME_DIR}` or `~/.cache/init_ubuntu/`) with `0600`, not shared
    `/tmp`.
- Confidence: High that the path is fixed. Medium on impact (payload is
  non-secret; requires a hostile local co-user on the remote).

### SR-05 (MEDIUM) — Unverified APT signing keys fetched at install time

- File: `module/docker.module.sh:99` (`curl … download.docker.com/…/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg`),
  `module/anydesk.module.sh:134` (`curl … "${ANYDESK_KEY_URL}" | gpg --dearmor | sudo tee "${ANYDESK_KEYRING}"`),
  `module/vscode.module.sh` (Microsoft `.asc` dearmor to keyring).
- Description: APT repo signing keys are fetched over HTTPS and trusted with no
  fingerprint pinning. The repos are then added with `signed-by=<keyring>` (good —
  this scopes the key to that repo), but the key itself is trust-on-first-fetch.
- Exploit path: TLS-MITM or vendor-infra compromise at the key endpoint installs
  an attacker key into the trusted keyring; subsequent `apt-get install` from that
  repo accepts attacker-signed packages installed as root.
- Remediation OPTIONS:
  - Option A: Ship the expected key fingerprint per module and verify
    (`gpg --show-keys` / compare fpr) before writing the keyring.
  - Option B: Vendor the known-good key files in the repo and install from disk
    instead of fetching at runtime.
- Confidence: High on the absence of fingerprint pinning. Standard distro-tooling
  risk; MEDIUM.

### SR-06 (LOW) — `bash -c` / `sh -c` with interpolated (trusted) values

- File: `lib/dispatcher.sh:1096-1101` (doctor drift check: `bash --noprofile --norc
  -c "source '${LIB_DIR}/logger.sh'; … source '${_file}'; is_installed"`),
  `module/yazi.module.sh:220` (`${_sudo} sh -c "mv '${_top}'/* '${INSTALL_DIR}/' && rmdir '${_top}'"`),
  `lib/module_helper.sh:165` (`bash -c "${TEST_VERIFY_CMD}"`),
  `install-nvidia-driver.sh:461` (`trap "exec_cmd 'sudo service ${dm} start'" EXIT`).
- Description: These build a shell string from variables. Under this repo's threat
  model the interpolated values are NOT attacker-controlled: `_file` is a registry
  entry whose path is a glob match in trusted module dirs and whose stem is
  validated to equal `NAME` (`lib/registry.sh:120-127`); `LIB_DIR`/`INSTALL_DIR`/
  `GITHUB_ASSET_PATTERN`/`TEST_VERIFY_CMD`/`dm` are repo-authored constants or
  derived from trusted system queries. So there is no concrete injection here
  today. They remain LOW because the pattern is fragile: a future change that lets
  any of these carry a runtime/untrusted value (e.g. a user-supplied install dir,
  or a module name flowing into a path with metacharacters) would turn into
  injection, and `trap "…${dm}…"` expands at trap-set time which is a latent foot-gun.
- Remediation OPTIONS:
  - Option A: Replace `bash -c "…source '${_file}'…"` with a `(...)` subshell that
    `source "${_file}"` directly (the engine already prefers this in
    `lib/runner.sh:204-254`); keeps `set -u`/coverage happy without string-building.
  - Option B: For `sh -c "mv '${_top}'/*"`, pass paths as positional args
    (`sh -c 'mv "$1"/* "$2"/ && rmdir "$1"' _ "${_top}" "${INSTALL_DIR}"`) or use
    plain bash `mv` with globbing.
  - Option C: Single-quote the trap body so `${dm}` expands at trigger time.
- Confidence: High that no injection is reachable today; flagged as hardening.

### SR-07 (LOW) — Docker-enforcement hook whitelist is bypassable

- File: `.agents/hook/test-must-use-docker.sh:51-61` (and the `.claude/` symlink).
- Description: The PreToolUse hook blocks host bats / host apt by matching the
  command's FIRST token against a block list, but it first short-circuits to
  `exit 0` if the first token is in a large allow list that includes `env`, `tee`,
  `xargs`, `bash`-adjacent helpers, etc. A command like `env apt-get install …` or
  `xargs -I{} apt-get install {}` has first token `env`/`xargs` and is allowed,
  bypassing the host-install guard.
- Exploit path: Not a runtime user-facing vulnerability — this hook governs the
  AGENT's own tool use as a discipline guardrail, not the shipped product. Impact
  is "agent could run a host install despite the policy", not end-user compromise.
- Remediation OPTIONS:
  - Option A: After the allow-list short-circuit, still scan the FULL command for
    the block patterns (e.g. detect `apt-get install` anywhere, accounting for
    `env`/`xargs`/`sudo` prefixes).
  - Option B: Parse out env-prefix wrappers (`env`, `xargs`, `nice`, `timeout`,
    `sudo`) and re-evaluate the effective first token.
- Confidence: High on the bypass mechanics; LOW severity because it is a dev/agent
  guardrail, not a product security boundary.

### SR-08 (LOW) — Dead legacy installer still on disk with `curl | sh`

- File: `module/setup_qmk_firmware.sh:60` (`curl -fsSL https://install.qmk.fm | sh`).
- Description: This v1 legacy script was superseded by
  `module/qmk-firmware.module.sh` (which says so at line 4). The registry only
  loads `*.module.sh` files, so `setup_qmk_firmware.sh` is NOT loaded by the
  engine — but it is still executable on disk and runnable directly, and it
  pipes a remote script straight to `sh` with no verification.
- Exploit path: A user who runs the stale file directly gets the unverified
  `curl | sh`. Low because it is not on the engine path.
- Remediation OPTIONS:
  - Option A: Delete the superseded `module/setup_*.sh` legacy sketches.
  - Option B: If kept for reference, move them out of `module/` (e.g. to a
    `doc/legacy/` or strip the executable bit).
- Confidence: High.

### SR-09 (LOW) — Broken release URL ("latests") in legacy font fetcher

- File: `module/setup_font.sh:83`
  (`…/releases/latests/download/${_download_file}`).
- Description: `latests` (typo) yields a 404. Not a vulnerability per se, but a
  broken-download path can mask real failures and the file (a legacy `setup_*.sh`,
  same class as SR-08) has no checksum verification either. The live module
  `module/font.module.sh:69` uses the correct pinned-version URL.
- Remediation OPTIONS: fix or remove the legacy file (see SR-08 Option A/B).
- Confidence: High (typo verified). Cosmetic/robustness.

### SR-10 (LOW) — `eval "$*"` capture executor (trusted command strings)

- File: `lib/general.sh:86,88,215` (`exec_cmd` / `_exec_cmd_captured` run
  `eval "$*"` / `eval "${_cmd}"`).
- Description: The capture-mode executor evals the command it is handed. All
  current callers pass repo-authored command strings (module install steps), not
  untrusted runtime data, so there is no injection today. Flagged because `eval`
  of a joined `$*` is inherently fragile: any future caller that interpolates a
  user/state value into the string inherits an injection. The engine's per-module
  child output is also logged verbatim into the JSONL `output=` field
  (`lib/general.sh:104`), which is fine but means anything the command prints lands
  in the log.
- Remediation OPTIONS:
  - Option A: Where the call site already has an argv array, prefer running the
    array directly (`"${cmd[@]}"`) instead of `eval` on a flattened string.
  - Option B: Keep `eval` only for the genuinely string-shaped legacy callers and
    document the invariant that inputs are always repo-authored.
- Confidence: High that it is not exploitable today; hardening note.

### SR-11 (LOW) — Stray sensitive-looking working file in the tree

- File: `tmp.md` (mode `-rw-------`, repo root), plus untracked `Cleanup).` and a
  `.worktree_tap.log` owned by root.
- Description: Not part of the shipped product and `tmp.md` is correctly `0600`,
  but a `0600`-mode scratch file at repo root is the kind of thing that gets
  committed by accident. `.worktree_tap.log` being root-owned in a user repo is
  odd. No secret content was read (out of scope to dump), but the maintainer
  should confirm these are intentional and gitignored.
- Remediation OPTIONS: remove/ignore scratch files; confirm none carry secrets.
- Confidence: Low-impact housekeeping.

---

## Surface covered / no issue found

These areas were examined and found clean (or clean under the threat model):

- Secrets storage backend — `lib/secrets.sh`: secret values travel via
  stdin/stdout pipes only, never argv (`secrets_store` reads stdin, l.151-164);
  the encryption passphrase reaches openssl via `-pass env:` in a child env, never
  argv (l.314-316, l.335-337); encrypted-file output is written via a `umask 077`
  subshell to a temp then `mv` + `chmod 600`, directory `chmod 700` (l.306-322);
  secret NAMES are validated against `^[A-Za-z0-9][A-Za-z0-9._@-]*$` before
  becoming file basenames, blocking path traversal (l.140-147); only names are
  logged, never values (l.162, l.193). Backend selection from config/env is
  validated against a fixed allow-list before the dynamic
  `_secrets_backend_<b>_*` dispatch (l.107-122) — no command injection via
  backend name. PBKDF2 iter 300000, AES-256-CBC, SHA-512.
- Secrets CLI — `setup_secrets.sh`: `ssh-keygen`/`ssh-add`/`gpg`/`ssh-copy-id`
  own their own passphrase prompts on their tty (l.157-159, l.183-184, l.433-436);
  `token set` reads the value from a no-echo tty prompt or stdin pipe, never argv
  (l.371-388); `token get` is deliberately CLI-only and NOT wired into the TUI
  (verified against `lib/tui_secrets.sh` — the TUI token sub-screen exposes only
  list/set/remove, l.232-252), preserving the anti-shoulder-surf intent; `ssh-key
  remove` canonicalizes the target and refuses anything outside `~/.ssh`
  (l.280-310) and requires `--yes` in non-interactive contexts (l.324-336).
- TUI secrets layer — `lib/tui_secrets.sh`: every flow forks `setup_secrets` and
  only ever passes NON-secret args (token name, user@host, file path, the
  type-to-confirm name); values/passphrases are always collected by the forked
  tool on its own tty (l.75-124). SSH delete uses a type-to-confirm gate
  (l.170-185). No engine lib is sourced; no State write.
- State import / sync deserialization — `lib/state_io.sh`, `lib/state.sh`: payloads
  are jq-validated (object type, supported major version 0.x) before use
  (`_state_io_payload_validate`, state_io.sh l.82-106); only the payload's
  `synced` section is ever read, a smuggled `local` section is ignored by
  construction (l.258-302); module names from a payload are matched against the
  local registry catalog (`registry_has`) and the install lifecycle that runs is
  the RECEIVER's own local module code, never code from the payload — so a hostile
  payload cannot introduce executable content; all state mutations use jq
  `--arg`/`--argjson` binding (state.sh throughout) so values never reach a shell
  parser. flock-guarded writes.
- Module registry — `lib/registry.sh`: modules are discovered by glob only in
  trusted dirs (bundled `module/` + user-local `~/.config/init_ubuntu/module/`),
  parsed in an isolated `bash --noprofile --norc` subshell (l.57-69), and a file
  whose `NAME` does not equal its filename stem is skipped (l.120-127). Module
  names therefore cannot be arbitrary strings that key into shell-building code.
- Config — `lib/config.sh`: pure bash + awk INI parsing, jq only for `--json`
  output; values are never eval'd; the one security-relevant consumer
  (`secrets.backend`) is re-validated against an allow-list downstream.
- TUI CLI broker — `lib/tui_backend.sh:440-553`: forked `list/detect/show --json`
  payloads are validated with `jq -e .` before use (l.446); a non-JSON / failing
  fork routes to a single error path. `TUI_CLI`/`TUI_BACKEND`/`TUI_FZF_BIN` are
  operator-set seams; backend is validated against `gum|whiptail`. No payload
  value is eval'd; jq queries bind dynamic values with `--arg`/`--argjson`.
- Logger — `lib/logger.sh`: `log_event` JSON-escapes keys and values
  (`_json_escape`/`_json_value`) before composing each JSONL line, so embedded
  newlines/quotes cannot break the one-object-per-line format or inject log
  records. It does not eval its inputs.
- i18n — `lib/i18n.sh`: `i18n_t` substitution uses bash parameter expansion
  (`${_s//\{$i\}/$arg}`), not `printf` with a dynamic format, so a value containing
  `%` or `\` is inert (no format-string risk). The table name is a repo-authored
  bareword, never attacker-influenced.
- Engine module runner — `lib/runner.sh:204-254`: modules run in a `(...)` subshell
  (not `bash -c`), side effects scoped; phase function presence is checked before
  call. The sourced file is the registry path (trusted).
- Other libs reviewed with no finding: `lib/environment.sh`, `lib/preflight.sh`
  (apt invoked with `--` separator and package names derived from `command -v`,
  not free text), `lib/resolver.sh`, `lib/color.sh`, `lib/module_bootstrap.sh`,
  `lib/state_migrate.sh`, `setup_ubuntu.sh` entrypoint path resolution.
- Most modules are pure-apt archetype and clean: build-essential, curl, git, htop,
  jq, ripgrep, fdfind, tmux, unzip, vim, wget, batcat, codex, gemini, and the
  config-only modules (git-config, ssh-config, shell, ranger, claude-code-config).

---

## Open questions for the maintainer

1. SR-01: Is the `INIT_UBUNTU_TEST_GH_*` seam acceptable to ship env-gated only, or
   should it be gated behind an in-container/test-only marker so production has no
   payload-swap branch? (This is the one I'd most want a decision on.)
2. SR-03/SR-05: Is "trust the upstream official installer / HTTPS only, no checksum
   or key pinning" a conscious, documented design stance for the
   github-release + `curl | bash` + apt-key archetypes? If so it likely deserves
   an ADR so it is an explicit accepted risk rather than an omission.
3. SR-02: For root extraction, are you comfortable adding
   `--no-same-owner --no-same-permissions` and a traversal guard, or is the
   "trusted upstream tarball" assumption sufficient given SR-03's stance?
4. SR-04: Should sync's remote staging move off the fixed `/tmp/init_ubuntu_sync.json`
   to a per-run `mktemp`/private-dir path, given remotes may be multi-user?
5. SR-06/SR-10: Worth converting the remaining `bash -c "…source…"` and
   `eval "$*"` string-builders to subshell `source` / argv-array execution as
   defense-in-depth, even though no injection is reachable today?
6. SR-08/SR-09/SR-11: Can the legacy `module/setup_*.sh` sketches and the
   `tmp.md` / `Cleanup).` / root-owned `.worktree_tap.log` scratch files be
   removed/ignored before 0.1.0 GA?
