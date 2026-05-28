# ADR-0016: setup_secrets backend selection algorithm

- **Status:** Accepted
- **Date:** 2026-05-20

## Context

PRD §14.3 listed a backend priority for `setup_secrets`:
1. `pass`
2. `gnome-keyring`
3. fallback (`age` / `openssl enc`)

But left undefined:
- How "available" is decided (especially for `gnome-keyring` on
  headless / non-D-Bus environments).
- What happens when multiple backends are available.
- Whether the choice is pinned across sessions.
- How the choice survives cross-machine sync.

Real failure modes without policy:
- RPi headless has `secret-tool` installed (via apt) but no D-Bus
  session → silent stores that disappear next reboot.
- User sets a token via `pass` on workstation, later runs
  `setup_secrets token get` in a fresh shell that picks
  `gnome-keyring` → token "missing".
- Sync from desktop (gnome-keyring) to server (no GUI) → user
  expects tokens to travel; PRD §16.4 says they don't, but the
  failure isn't surfaced.

## Decision

### (a) Availability probe per backend

```bash
secrets_backend_available_pass() {
    command -v pass >/dev/null 2>&1 || return 1
    [[ -d "${PASSWORD_STORE_DIR:-$HOME/.password-store}" ]] || return 1
    return 0
}

secrets_backend_available_gnome() {
    command -v secret-tool >/dev/null 2>&1 || return 1
    [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] || return 1
    # quick probe — does not require a real entry to exist
    secret-tool search _init_ubuntu_probe noop >/dev/null 2>&1
    [[ $? -le 1 ]]  # 0 = found nothing, 1 = no D-Bus / no daemon
}

secrets_backend_available_file() {
    command -v age >/dev/null 2>&1
    # openssl enc is the last-resort fallback within "file"
    # — covered by openssl shipping by default on Ubuntu
}
```

A backend is "available" only when both the tool is installed and
the runtime context is usable. `command -v` alone is not enough.

### (b) Selection precedence (under `backend=auto`)

```
auto:
  if available_pass:       → pass
  elif available_gnome:    → gnome-keyring
  else:                    → file (age preferred, openssl fallback)
```

`pass` ranks above `gnome-keyring` because `pass` requires deliberate
setup (apt install + `pass init <gpg-key>`); its presence signals
user preference. `gnome-keyring` ships with GNOME and may not
reflect intent.

### (c) `[secrets] backend` in config.ini

```ini
[secrets]
backend = auto                  # auto | pass | gnome-keyring | file
```

- `auto` (default) — run the precedence above on first call, then
  **pin the resolved choice** to config.ini for stability across
  sessions:

  ```ini
  [secrets]
  backend = auto
  resolved_backend = pass         # written by tool on first resolution
  ```

  Subsequent `setup_secrets` calls read `resolved_backend` directly
  without re-probing. This avoids "different backend each session"
  surprises.

- `pass` / `gnome-keyring` / `file` — forced. If the named backend
  is not available, `setup_secrets <op>` exits 1 with message:

  ```
  Configured backend 'gnome-keyring' not available
  (DBUS_SESSION_BUS_ADDRESS unset). Either start a graphical
  session, or change [secrets] backend in
  ${XDG_CONFIG_HOME}/init_ubuntu/config.ini.
  ```

### (d) Backend is local; never synced

PRD §16.4 already states `setup_secrets` data never crosses the
wire. Reaffirming: the `[secrets]` section of `config.ini` is also
local-only. `sync` excludes it.

### (e) Switching backends

v0.1 has no `migrate-backend` subcommand. User flow to switch:

1. List current secrets: `setup_secrets list`
2. Manually copy each value to the new backend (out of band).
3. `setup_secrets remove <name>` for each on old backend.
4. Edit config.ini `[secrets] backend = <new>` and remove
   `resolved_backend`.
5. Next `setup_secrets` call resolves & pins to the new backend.

`migrate-backend` is v1.x scope.

### (f) File backend implementation

When `resolved_backend = file`:
- Encryption tool: `age` (preferred). If `age` unavailable on first
  resolution, emit warning: `"recommended: setup_ubuntu install age"`,
  and use `openssl enc -aes-256-cbc -pbkdf2 -salt` as fallback.
- Key location: `${XDG_CONFIG_HOME:-$HOME/.config}/init_ubuntu/secrets/key.txt`
  (`age`) or salt-derived (openssl). `chmod 600` enforced.
- Encrypted values: `${XDG_CONFIG_HOME:-$HOME/.config}/init_ubuntu/secrets/<name>.<ext>`
  where ext is `.age` or `.enc`.

## Alternatives considered

- **Strict `pass` only.** Rejected: forces every machine to install
  pass + GPG even when gnome-keyring already serves the use case.
- **Strict `gnome-keyring` only.** Rejected: breaks headless / RPi
  / server completely.
- **No pinning; re-detect every call.** Rejected: same secret op
  routing to different backends across sessions is a confusing
  failure mode.
- **One global `secrets` config across machines (synced).** Rejected:
  backend availability is hardware/environment-specific. A laptop
  preference makes no sense on an RPi.

## Consequences

- One pinned backend per machine. Switching is a deliberate
  multi-step ritual until v1.x ships `migrate-backend`.
- AC additions:
  - **AC-49:** On a fresh install, first `setup_secrets token set
    foo bar` resolves a backend, writes `resolved_backend` to
    config.ini, and stores `foo`.
  - **AC-50:** Same backend resolves identically next session
    (config.ini pin sticks).
  - **AC-51:** On RPi headless (no D-Bus), `auto` resolves to `file`
    even if `secret-tool` is installed.
  - **AC-52:** Setting `[secrets] backend = gnome-keyring` on a
    machine where `DBUS_SESSION_BUS_ADDRESS` is unset → exits 1
    with the message above.
