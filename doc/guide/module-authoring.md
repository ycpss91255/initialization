# Module Authoring Guide

How to take a tool from "I want this installed on my machines" to a
merged `module/<name>.module.sh`. This is the author *workflow*; the
normative contract lives in `doc/module-spec.md` and the per-archetype
recipes in `doc/guide/archetype-cookbook.md`.

The whole flow:

```
pick archetype → copy template → fill metadata → lifecycle functions
              → bats spec → make test-unit / lint → PR
```

---

## 1. Pick an archetype and copy its template

Decide how the upstream ships (decision tree:
`doc/guide/archetype-cookbook.md` "Pick an archetype"):

| Upstream ships as... | Archetype | Template |
|---|---|---|
| apt package (main / universe / PPA / 3rd-party repo) | A — apt | `template/module-apt.template.sh` |
| GitHub Release tarball | B — github-release | `template/module-github-release.template.sh` |
| just a config file under `~/.config/<tool>/` | C — config-drop | `template/module-config.template.sh` |
| anything else (multi-step, hardware, installers) | D — custom | `template/module-custom.template.sh` |

```bash
cp template/module-apt.template.sh module/mytool.module.sh
```

Don't fight the macro: if your A/B/C module needs more than one or two
overridden functions, switch to D (hand-written 6 functions). The
macros are convenience, not a contract.

Keep the template's dual-mode header and standalone footer **unchanged**
(`doc/module-spec.md` §4.9): they are what make
`bash module/mytool.module.sh install` (Standalone) and
`setup_ubuntu install mytool` (Engine) both work from one file.

## 2. Fill the metadata block

Work through `doc/module-spec.md` §3. The required fields:

- `NAME` — must equal the file name minus `.module.sh`.
- `DESCRIPTION` — `declare -gA` associative array; at least an `[en]`
  entry (`[zh-TW]` strongly encouraged). The `-g` flag is mandatory so
  the array survives being source'd inside test fixtures.
- `CATEGORY` — `base` / `recommended` / `optional` / `experimental`
  (PRD §6 catalog).
- `SUPPORTED_UBUNTU` — e.g. `("22.04" "24.04" "26.04")`.

Then the optional fields that matter most in practice:

- `DEPENDS_ON` — other module names. Nearly everything depends on
  `apt-essentials`. The engine resolves these; Standalone mode does not
  (ADR-0001).
- `TAGS` — `TAGS[0]` is the TUI grouping key (`cli-essentials`,
  `agent`, `hardware`, ...).
- `SUPPORTED_PLATFORMS` / `SUPPORTS_USER_HOME` / `RISK_LEVEL` /
  `REBOOT_REQUIRED` / `INSTALL_TARGET_DEFAULT` — see spec §3.3.
- `TEST_VERIFY_CMD` — one-liner the default `verify()` runs, e.g.
  `"command -v mytool && mytool --version"`.

Metadata is consumed *post-source* by the engine, so the template keeps
a file-level `shellcheck disable=SC2034` — don't add new disables
elsewhere (gated by `.claude/hook/enforce_shellcheck_disable_approval.sh`).

## 3. Lifecycle functions

The archetype macro (`module_use_apt_archetype`, ...) binds the six
lifecycle functions (`install` / `upgrade` / `remove` / `purge` /
`verify` / `is_outdated`) to library defaults. You always hand-write:

- `detect()` — is this environment one where the module *can* run?
  Exit 0 = yes, non-zero = no (Query-class exit codes, PRD §7.4).
- `is_recommended()` — should the TUI pre-tick it here? (e.g. NVIDIA
  GPU present → recommend `nvidia-driver`).

Rules that bite if ignored:

- **All lifecycle functions are mandatory** (ADR-0002) — the archetype
  macro satisfies this for you; for archetype D you write all of them.
- **Idempotency** (spec §4.2): `install` twice = ok, `remove` twice =
  ok. Guard with `is_installed` early-returns.
- **Dry-run** (spec §4.5): wrap every side-effecting command with
  `module_dryrun_guard` / `exec_cmd` so `--dry-run` prints instead of
  executes.
- **verify() vs doctor()** (ADR-0009): `verify` = "did install
  complete?" (fast, offline, no daemons assumed); `doctor` = "can I use
  it right now?" (groups, services, device nodes).
- **State boundary** (ADR-0001): the module writes only the Sidecar
  (`${XDG_STATE_HOME}/init_ubuntu/versions/<name>`, via the helpers);
  never touch `state.json` — that is engine-owned.
- **verify failure = install failure** (ADR-0015): engine runs your
  `purge()` to clean up, so make `purge()` safe on a half-installed
  tree.

When the macro is *mostly* right, override one function with the
super-call pattern (rename the default, call it, add your extra step) —
worked examples per archetype in `doc/guide/archetype-cookbook.md`.

## 4. Write the bats spec

```bash
cp template/test.template.bats test/unit/module/mytool_spec.bats
```

Replace `<MODULE-NAME>` / `<TODO>` markers. The minimum case table is
normative in `doc/module-spec.md` §7 and the overall scope is sized by
PRD Q29: **~50 tests per module** — smoke, metadata sanity, the 10
lifecycle functions under dry-run, no-side-effects, idempotency,
standalone CLI behavior (`--help` / `--version` / unknown phase = exit
2 / `info --lang=zh-TW`), plus whatever is special about your module.

Mock everything that would touch the system (`apt-get`, `curl`,
`sudo`, ...) with bats-mock or PATH stubs — a unit test must never
perform a real install (hard rule: ADR-0004, plus "no host package
installs").

## 5. Test and lint (Docker only)

```bash
make test-unit MODULE=mytool   # your spec only
make test-unit                 # full unit suite
make lint                      # ShellCheck + fish + hadolint
```

Tests run inside Docker **only** (ADR-0004); the Make targets handle
the container for you. Regenerate the module index after adding the
module:

```bash
./script/gen-module-index.sh > doc/module/INDEX.md
```

(CI fails if the committed INDEX.md is stale.)

## 6. Open the PR

One module per PR. Checklist:

- [ ] `module/mytool.module.sh` (metadata complete, `NAME` = file name)
- [ ] `test/unit/module/mytool_spec.bats` (spec §7 table covered)
- [ ] `doc/module/INDEX.md` regenerated
- [ ] CHANGELOG entry under `[Unreleased]` (`doc/changelog/CHANGELOG.md`)
- [ ] `make test-unit MODULE=mytool` + `make lint` green
- [ ] Conventional commit, e.g. `feat(module): mytool — <summary>`

`setup_ubuntu doctor --validate-modules` runs the same metadata lint CI
applies (required fields, `NAME` vs file name, `DEPENDS_ON` targets
exist, no dependency cycles).

## See also

- `doc/module-spec.md` — the v2 contract (normative).
- `doc/guide/archetype-cookbook.md` — per-archetype recipes + gotchas.
- `doc/adr/0001-standalone-engine-state-boundary.md` — Sidecar vs state.json.
- `doc/adr/0002-all-lifecycle-functions-mandatory.md`.
- `doc/adr/0009-verify-vs-doctor-semantic-boundary.md`.
- `doc/adr/0015-verify-failure-equals-install-failure.md`.
- PRD §13 Q29 — per-module test sizing.
