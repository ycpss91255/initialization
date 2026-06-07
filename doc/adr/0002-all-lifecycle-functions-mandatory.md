# All 10 Lifecycle functions are mandatory

A Module's Lifecycle contract is 10 functions: `detect`, `is_recommended`,
`is_installed`, `install`, `upgrade`, `remove`, `purge`, `verify`,
`is_outdated`, `doctor`. **All 10 are mandatory** — earlier drafts had 5
mandatory + 5 optional, but every "optional" slot creates per-Module variation
in CLI behavior ("`setup_ubuntu doctor neovim` returns exit 2 because that
Module didn't bother implementing it"). With Archetypes A/B/C providing
helper-backed defaults via the `module_use_*_archetype` macro, the cost of
"mandatory" is zero for archetype users; only Archetype D (custom hand-written)
authors must implement all 10 themselves.

## Considered Options

- **5 mandatory + 5 optional**: rejected because it makes the Engine's behavior
  depend on which Module you point it at — `setup_ubuntu upgrade <m>` working
  on some Modules and failing on others is hostile UX.

## Consequences

- The macro must define all 10 functions (not just 6 as in the v0.1 draft).
- Archetype helpers must provide sensible defaults for `verify` / `is_outdated`
  / `doctor` — e.g. `module_default_verify` runs `is_installed` then optional
  `TEST_VERIFY_CMD`; `module_default_doctor` delegates to `verify` as the
  baseline implementation. Per ADR-0009 (verify is post-install acceptance,
  doctor is runtime health), module authors **must override `doctor`** when
  the module has a runtime surface (daemon, group requirement, runtime
  config dependency) — the baseline default is only valid for modules
  with no runtime surface (e.g. config-drop modules).
- Templates `module-apt/github-release/config.template.sh` need no Lifecycle
  function stubs (macro covers all); only `module-custom.template.sh` shows 10
  stubs for hand-written authors.
