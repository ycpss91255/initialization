# All 10 Lifecycle functions are mandatory

> **Refined by ADR-0027** (archetype macros now emit all 10 functions, closing
> the earlier `is_outdated` / `doctor` gap). The 10-mandatory framing below
> stands; ADR-0027 makes it real by having `module_use_*_archetype` emit
> working defaults for the 8 archetype-defaultable functions, so archetype
> A/B/C users get all 10 for free and only `detect` / `is_recommended` stay
> module-defined. The `doctor` default is refined further by ADR-0009
> (`is_installed` + `TEST_VERIFY_CMD`; override for a real runtime surface).

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
  / `doctor` — `module_default_verify` runs `is_installed` then optional
  `TEST_VERIFY_CMD`; `module_default_doctor` runs the same baseline
  (`is_installed` AND, if set, `TEST_VERIFY_CMD`), reusing the acceptance probe
  as the read-only/offline runtime-health check. Per ADR-0009 (verify is
  post-install acceptance, doctor is on-demand runtime health), module authors
  **must override `doctor`** when the module has a real runtime surface (daemon,
  group requirement, runtime config dependency) with genuine checks — the
  baseline default is the right answer only for modules with no runtime surface
  beyond "the binary runs" (e.g. pure CLIs, config-drop modules).
- Templates `module-apt/github-release/config.template.sh` need no Lifecycle
  function stubs (macro covers all); only `module-custom.template.sh` shows 10
  stubs for hand-written authors.
