# ADR-0009: verify is post-install acceptance, doctor is runtime health

- **Status:** Accepted
- **Date:** 2026-05-20

## Context

PRD §13.1 Q20 declared `doctor()` defaults to `verify()` and "may be
overridden for deeper checks". This left the boundary ambiguous: module
authors had no rule for *when* to override, and the two functions
risked collapsing into duplicates.

In practice the two answer different questions:

- `verify()` runs at the **cleanest possible moment** — immediately
  after `install()` / `upgrade()`. Nothing has had time to drift.
- `doctor()` runs at an **arbitrary later moment** — invoked by the
  user via `setup_ubuntu doctor`. The world has moved on: daemons may
  be stopped, user may be in the wrong groups, config files may have
  been hand-edited, external repos may be unreachable.

## Decision

Pin the two functions to distinct purposes.

### `verify()` — post-install acceptance

- **Question answered:** "Did `install()` actually complete?"
- **When called:** automatically at the end of `install` / `upgrade`
  (PRD §13.2 Q15), and on demand via `setup_ubuntu verify`.
- **Scope:**
  - Binary / installed artefact exists on disk.
  - `TEST_VERIFY_CMD` exits 0.
  - Sidecar `${XDG_STATE_HOME}/init_ubuntu/versions/<name>` written.
- **Must NOT assume:** daemons are running, user is in the right
  groups, the config file is still intact, external network is up.
- **Performance:** fast (< 1s typical).

### `doctor()` — runtime health

- **Question answered:** "Can I actually use this right now?"
- **When called:** only by user (`setup_ubuntu doctor [<name>]`); never
  automatic.
- **Scope superset of verify(), plus runtime concerns where they
  apply.** Split into two layers:
  - **Local checks (always run, offline-safe):**
    - Service / daemon state (`systemctl is-active`).
    - User membership in required groups (`docker`, `dialout`, ...).
    - Config file integrity / expected entries present.
    - GPU device node existence (`/dev/nvidia0`).
  - **Network checks (only when `--online` is passed):**
    - apt repo reachable.
    - GitHub release URL reachable.
    - Daemon outbound connectivity (e.g. docker pull dry-run).

### Offline default

`setup_ubuntu doctor` defaults to offline mode. Network checks are
skipped. The engine sets `INIT_UBUNTU_DOCTOR_ONLINE=false` before
invoking module `doctor()` functions; each module's `doctor()` is
expected to guard network calls behind this flag:

```bash
doctor() {
  # local checks (always)
  is_installed && systemctl is-active docker >/dev/null 2>&1 || return 1
  groups | grep -q docker || return 1
  # network checks (only --online)
  [[ "${INIT_UBUNTU_DOCTOR_ONLINE:-false}" == "true" ]] || return 0
  curl -sf https://hub.docker.com/ >/dev/null || return 7
}
```

Rationale:
- Personal-use tool targets multi-platform machines, including SBCs
  in field deployments and WSL on locked-down networks. Offline is
  common.
- `--online` makes the user-intent explicit and lets the same
  `doctor()` function serve both modes via env-flag guard.
- Aligns with §13.2 Q31 ("not actively apt update") — doctor avoids
  unsolicited network traffic.

Exit codes:
- Local check fails → exit 1.
- Network check fails (only possible with `--online`) → exit 7
  (PRD §7.4 — remote/network failure).

### Default and override rule

`doctor() { verify; }` remains the default — but only valid for
modules with **no runtime surface**:

| Archetype | Runtime surface | doctor override expected? |
|---|---|---|
| A (apt) | depends on the pkg | yes for daemons/groups (`docker`); no for pure CLIs (`vim`, `jq`) |
| B (github-release) | usually none — binary download | no |
| C (config-drop) | usually none — file presence is the contract | no |
| D (custom) | author decides | author judges |

`template/module-*.template.sh` carries a `# Override doctor() if this
module has a daemon, group requirement, or runtime config dependency.`
hint per archetype.

## Alternatives considered

- **Collapse the two into one function.** Rejected: caller intent
  ("did install finish" vs "does it work now") is real and surfaces
  in different commands (`setup_ubuntu install` chains verify;
  `setup_ubuntu doctor` is a manual sweep).
- **Make `doctor` mandatory to override.** Rejected: many modules
  legitimately have no runtime surface (`git-config`, `ssh-config`,
  pure dotfile drops); forcing a duplicate is noise.
- **Move runtime checks into `verify` itself.** Rejected: `verify`
  runs in the auto-install chain (Q15); a network call there means
  every install becomes flaky on offline machines.

## Consequences

- Module authors with daemons/groups (`docker`, `nvidia-driver`,
  `ssh-config`) **must** override `doctor()`. Code review checklist
  gains: "if this module has a daemon or group requirement, does
  `doctor()` check it?"
- `setup_ubuntu install` stays offline-safe by contract (verify never
  hits the network).
- `setup_ubuntu doctor` is the one place users go for "what's broken
  now?", with permission to take seconds.
- AC additions:
  - **AC-32:** For modules with daemons (`docker`), stopping the
    daemon after install makes `doctor docker` exit 1 while
    `verify docker` still exits 0.
