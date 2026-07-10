# ADR-0016: setup_secrets backend selection algorithm

- **Status:** Accepted (implemented) — with two design points **Deferred /
  not built** (see marker below)
- **Date:** 2026-05-20

> **Reconciliation note (2026-07):** the shipped `lib/secrets.sh` names the
> fallback backend **`encrypted-file`** (not `file`); this ADR has been
> updated to match. Two design points below are **Deferred / not built**:
> (1) session-pinning the resolved backend via `resolved_backend` in
> config.ini, and (2) the `age`-preferred on-disk layout. The shipped
> `encrypted-file` backend uses **openssl enc (AES-256-CBC + PBKDF2)**, not
> `age`. Newly recorded shipped behavior: the `INIT_UBUNTU_SECRETS_BACKEND`
> env override (highest-priority selection) and the backend exit-code
> contract (3 = requested backend unavailable on this machine, 2 = unknown
> backend name).

## Context

PRD §14.3 listed a backend priority for `setup_secrets`:
1. `pass`
2. `gnome-keyring`
3. fallback (`encrypted-file` — `age` / `openssl enc`)

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

secrets_backend_available_encrypted_file() {
    # As shipped: openssl is the encryptor (see the Deferred marker on the
    # age-preferred layout below), covered by openssl shipping by default
    # on Ubuntu.
    command -v openssl >/dev/null 2>&1
}
```

A backend is "available" only when both the tool is installed and
the runtime context is usable. `command -v` alone is not enough.

### (a′) Selection order and env override (as shipped)

`_secrets_select_backend()` resolves in this order:

1. **`INIT_UBUNTU_SECRETS_BACKEND` (env)** — highest priority; the
   automation/test override. Checked **before** `config.ini`. A valid
   value (`pass` | `gnome-keyring` | `encrypted-file`) that is available is
   used directly; if the requested backend is **not available** on this
   machine the call **returns 3**; an unknown name **returns 2**.
2. **`[secrets] backend` in config.ini** — same valid-name / availability
   contract and the same exit codes.
3. **`auto`** — the precedence probe in (b).

Exit-code contract (used by all forced/requested paths):
- **2** — unknown backend name.
- **3** — requested backend is unavailable on this machine (or, under
  `auto`, no backend is available at all).

### (b) Selection precedence (under `backend=auto`)

```
auto:
  if available_pass:              → pass
  elif available_gnome:           → gnome-keyring
  else:                           → encrypted-file (openssl enc)
```

`pass` ranks above `gnome-keyring` because `pass` requires deliberate
setup (apt install + `pass init <gpg-key>`); its presence signals
user preference. `gnome-keyring` ships with GNOME and may not
reflect intent.

### (c) `[secrets] backend` in config.ini

```ini
[secrets]
backend = auto                  # auto | pass | gnome-keyring | encrypted-file
```

- `auto` (default) — run the precedence above.

  > **Deferred / not built — session-pinning (`resolved_backend`).**
  > The design below (writing the resolved choice back to config.ini and
  > reading it on later calls to avoid re-probing) was **not implemented**.
  > As shipped, `auto` re-runs the availability probe each call; on a stable
  > machine this resolves identically anyway. AC-49/AC-50 (below) describe
  > the pinning behavior and are likewise deferred.
  >
  > ```ini
  > [secrets]
  > backend = auto
  > resolved_backend = pass         # NOT written by the shipped tool
  > ```

- `pass` / `gnome-keyring` / `encrypted-file` — forced/requested. If the
  named backend is not available, the resolver **returns 3** (requested
  backend unavailable); an unknown name **returns 2**. Intended user-facing
  message:

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
4. Edit config.ini `[secrets] backend = <new>`.
5. Next `setup_secrets` call resolves to the new backend.

`migrate-backend` is v1.x scope.

### (f) encrypted-file backend implementation

When the resolved backend is `encrypted-file`:

> **Deferred / not built — age-preferred layout.** The design preferred
> `age` as the encryptor with an `age`-native key file and `.age` on-disk
> extension, falling back to openssl only when `age` was missing. **As
> shipped, the backend uses openssl unconditionally** — there is no `age`
> path and no `.age` layout. openssl was kept because it ships by default
> on Ubuntu (no extra install) and, per `lib/secrets.sh`, the passphrase is
> handled via `-pass env:` so plaintext never touches argv or disk.

As shipped:
- Encryption tool: `openssl enc -aes-256-cbc -md sha512 -pbkdf2 -iter
  <SECRETS_PBKDF2_ITER>` (PBKDF2 work factor 300000, OWASP-2023 baseline).
  There is no `age` code path.
- Ciphertext-only on disk: plaintext is NEVER written to disk.
- Encrypted values live under
  `${XDG_CONFIG_HOME:-$HOME/.config}/init_ubuntu/secrets/`; `chmod 600`
  enforced.

## Alternatives considered

- **Strict `pass` only.** Rejected: forces every machine to install
  pass + GPG even when gnome-keyring already serves the use case.
- **Strict `gnome-keyring` only.** Rejected: breaks headless / RPi
  / server completely.
- **No pinning; re-detect every call.** Originally rejected on the theory
  that re-detection routes the same op to different backends across
  sessions. **As shipped, this is what happens** (session-pinning was
  deferred): on a stable machine the probe resolves identically each call,
  so the feared failure mode does not arise in practice. `resolved_backend`
  pinning can still be added later if a machine's backend availability
  proves genuinely unstable.
- **One global `secrets` config across machines (synced).** Rejected:
  backend availability is hardware/environment-specific. A laptop
  preference makes no sense on an RPi.

## Consequences

- One backend resolved per machine (by re-probe each call, pinning
  deferred). Switching is a deliberate multi-step ritual until v1.x ships
  `migrate-backend`.
- AC additions:
  - **AC-49 (Deferred / not built):** first `setup_secrets token set foo
    bar` writes `resolved_backend` to config.ini. Pinning was not
    implemented; the shipped tool resolves and stores without writing
    `resolved_backend`.
  - **AC-50 (Deferred / not built):** "config.ini pin sticks next
    session." Superseded by re-probing, which resolves identically on a
    stable machine.
  - **AC-51:** On RPi headless (no D-Bus), `auto` resolves to
    `encrypted-file` even if `secret-tool` is installed.
  - **AC-52:** Requesting `[secrets] backend = gnome-keyring` (or via
    `INIT_UBUNTU_SECRETS_BACKEND`) on a machine where
    `DBUS_SESSION_BUS_ADDRESS` is unset → resolver **returns 3**
    (requested backend unavailable). An unknown backend name → **returns
    2**.
