# ADR-0012: --force overrides soft filters, never capability flags

- **Status:** Accepted
- **Date:** 2026-05-20

## Context

PRD §7.2 lists `--force` on `install`, and §15.3 says it "skips all
filters". This left ambiguous whether `--force` also bypasses
module-level capability declarations like `SUPPORTS_USER_HOME=false`
or `SUPPORTED_UBUNTU` allowlists.

The distinction matters: filters are about policy (when should the
engine refuse to install?). Capability flags are about whether the
module's code path *exists* (`SUPPORTS_USER_HOME=false` means the
author never wrote a user-home install branch — forcing it would
execute non-existent code).

## Decision

Split into two layers; `--force` only overrides the soft layer.

### Soft filters (skippable by `--force`)

These reflect engine policy about whether install is appropriate:

- `is_recommended()` returning non-zero
- `SUPPORTED_PLATFORMS` not including the current `INIT_UBUNTU_FORM_FACTOR`
- `RISK_LEVEL=high` WARN_MESSAGE confirmation prompt
- `[modules.<name>] enabled = false` in config.ini
- `is_installed()` returning zero (already installed) — `--force`
  forces a reinstall via `purge → install`

### Hard capability flags (NOT skippable by `--force`)

These declare what the module's code can do. Forcing past them
executes undefined behaviour:

- `SUPPORTS_USER_HOME=false` + `--install-target=user-home` → exit
  code 4. Error message: "Module 'docker' does not support user-home
  install (SUPPORTS_USER_HOME=false). --force does not bypass
  capability flags."
- `SUPPORTED_UBUNTU` not containing the current Ubuntu version →
  exit code 3. Error message: "Module 'docker' does not support
  Ubuntu 30.04 (SUPPORTED_UBUNTU=22.04 24.04 26.04). To attempt
  anyway, edit the metadata in module/docker.module.sh."
- `CONFLICTS_WITH` matching an installed module → exit code 5. Same
  rationale: the module declared it cannot coexist.
- `detect()` returning non-zero → exit code 3, **unless** the
  module sets `DETECT_OVERRIDE=true` in its metadata (see escape
  hatch below).

### `detect()` escape hatch (`DETECT_OVERRIDE`)

`detect()` is a function (not a static metadata field), so it can
produce false negatives — e.g. nvidia-driver's `detect()` checks
`lspci` for an NVIDIA GPU, but a freshly-installed GPU may not show
until reboot. For these heuristic detects, the module author can
opt in to `--force` bypass:

```bash
# In module/nvidia-driver.module.sh metadata:
DETECT_OVERRIDE=true
```

With `DETECT_OVERRIDE=true`, `--force` skips `detect()`. Without
it (default), `detect()` failure is fatal even with `--force`.

This keeps the default safe (ubuntu-version-style hard checks stay
hard) while giving heuristic-detect modules a deliberate escape.

### `--force` mental model

`--force` says "I know the engine would normally refuse for *policy*
reasons; do it anyway." It does not say "I know the module isn't
written to handle this; do it anyway." The latter is a metadata edit.

## Alternatives considered

- **`--force` overrides everything.** Rejected: `SUPPORTS_USER_HOME=false`
  modules don't have a user-home install branch — forcing it runs
  code that doesn't exist, producing silent partial installs or
  installs to unexpected paths.
- **Two flags: `--force` and `--force-capability`.** Rejected: the
  second flag has no real use case. Editing the module's metadata
  is the honest workaround when a capability needs to change.
- **`--force` always errors with "use --force-capability".** Rejected:
  pointless ceremony. The current `--force` use cases are all soft
  (reinstall, recommended override, platform override).

## Consequences

- Module authors can rely on `SUPPORTS_USER_HOME=false` actually
  meaning "the engine will not call my install() with
  INIT_UBUNTU_INSTALL_TARGET=user-home". They don't need defensive
  guards in `install()`.
- Users who genuinely need to test an unsupported configuration
  edit the metadata (a real change, not a flag), which is
  appropriately friction-ful.
- AC additions:
  - **AC-38:** `setup_ubuntu install docker --install-target=user-home
    --force` exits 4 without invoking docker's `install()`.
  - **AC-39:** `setup_ubuntu install nvidia-driver --force` on
    `container` form factor succeeds (or fails for module reasons)
    — the platform filter is bypassed.
  - **AC-39b:** A module without `DETECT_OVERRIDE=true` whose
    `detect()` returns non-zero exits code 3 even with `--force`.
  - **AC-39c:** A module with `DETECT_OVERRIDE=true` whose
    `detect()` returns non-zero proceeds to install when `--force`
    is given.
