# Archetype Cookbook

Companion to `doc/module-spec.md` and the 4 archetype templates.
This file is referenced from every `template/module-*.template.sh`
authoring docstring.

The 4 archetypes (A apt / B github-release / C config-drop / D
custom) cover ~95% of how Ubuntu modules ship. This cookbook shows
which to pick, how to use the macro, and how to override one function
when the macro is *mostly* right.

---

## Pick an archetype

```
Does the upstream provide an apt package (in main / universe /
multiverse / a 3rd-party repo)?
├── Yes → archetype A (apt)
│         e.g. apt-essentials, fish, tmux, shell
│         If the install also needs custom steps (add repo+key, add
│         user to a group, write a config snippet), use the
│         super-call override pattern below.
│
└── No → Does upstream publish GitHub Releases with a tarball asset
        whose URL is stable?
        ├── Yes → archetype B (github-release)
        │         e.g. neovim
        │
        └── No → Is the entire module just dropping a config file
                into ~/.config/<tool>/?
                ├── Yes → archetype C (config-drop)
                │         e.g. git-config, ssh-config
                │
                └── No → archetype D (custom, hand-written 6 fns)
                          e.g. docker (apt + repo+key + usermod),
                          nvidia-driver (ubuntu-drivers integration),
                          font (manual extract + fc-cache)
```

If you find yourself fighting archetype A/B/C, that's a signal to use
D instead. The macros are convenience, not a contract.

---

## Archetype A — apt

`module_use_apt_archetype` binds the 6 lifecycle functions to
`module_default_apt_*` (see `lib/module_helper.sh §4`).

### Pure apt

`module/apt-essentials.module.sh` — installs a list of packages,
no extra work:

```bash
# Archetype A: APT packages
APT_PKGS=(curl ssh keychain ...)
APT_PPA=""             # (optional) e.g. "ppa:fish-shell/release-4"
CONFIG_PATHS=()        # dirs to rm on purge
module_use_apt_archetype
```

That's it. `install` runs `apt-get install -y ${APT_PKGS[@]}`,
`upgrade` runs `apt-get install --only-upgrade -y ${APT_PKGS[@]}`,
`remove` / `purge` / `verify` / `is_installed` all derive from the
package list.

### Hybrid: apt + override one function

This is the **super-call override pattern**. `docker.module.sh` uses
the apt macro for the lifecycle skeleton but overrides `install`
because the install also needs to:
- Add Docker's apt key under `/etc/apt/keyrings/docker.gpg`
- Add the apt source line for the current Ubuntu codename
- Add the invoking user to the `docker` group via `usermod -aG`

```bash
# Archetype A binding (skeleton)
APT_PKGS=(docker-ce docker-ce-cli containerd.io docker-compose-plugin)
CONFIG_PATHS=("${HOME}/.docker")
module_use_apt_archetype

# Override install() — runs INSTEAD OF module_default_apt_install
install() {
    module_dryrun_guard install "apt-repo setup + apt-install ... + usermod -aG docker" && return 0
    module_skip_if_installed && return 0

    have_sudo_access 2>/dev/null \
        || { log_error "[${NAME}] sudo required for docker install"; return 1; }

    # 1. apt key + source
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

    local _codename
    _codename="$(lsb_release -cs)"
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu ${_codename} stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

    # 2. fall back to apt default install for the package list
    sudo apt-get update -qq
    sudo apt-get install -y "${APT_PKGS[@]}"

    # 3. usermod
    sudo usermod -aG docker "${USER}"
}
```

The macro still defines `upgrade` / `remove` / `purge` / `verify` /
`is_installed` for us. We only paid the cost of one function override.

### Hybrid: chain to the macro's default

If you want to **add** behaviour to the default install rather than
replace it, capture the original first:

```bash
module_use_apt_archetype

# Capture the body of module_default_apt_install via declare -f
_orig_install=$(declare -f module_default_apt_install | sed '1d;$d')

install() {
    eval "${_orig_install}"   # do everything the default would do
    # … then add post-install steps
    log_info "[${NAME}] running post-install hook"
    sudo systemctl enable --now <some-service>
}
```

This pattern is rare in this repo (most overrides replace, not extend)
but it's the right tool when the macro's behaviour is correct AND you
need to bolt something on after.

### `is_outdated` for apt — `apt list --upgradable`

The default APT archetype doesn't implement `is_outdated` (it's
optional). The canonical recipe (tracked in task #72) is:

```bash
is_outdated() {
    local _pkg _line
    for _pkg in "${APT_PKGS[@]}"; do
        _line=$(apt list --upgradable 2>/dev/null | grep "^${_pkg}/")
        [[ -n "${_line}" ]] && return 0   # at least one pkg has updates
    done
    return 1
}
```

---

## Archetype B — github-release

`module_use_github_release_archetype` binds lifecycle to
`module_default_github_release_*` (see `lib/module_helper.sh §5`).

`module/neovim.module.sh` is the reference:

```bash
GITHUB_REPO="neovim/neovim"
GITHUB_ASSET_PATTERN="nvim-linux-x86_64.tar.gz"
INSTALL_DIR="/opt/nvim"
BIN_NAME="nvim"
# BIN_PATH_IN_TAR defaults to "bin/${BIN_NAME}"
# BIN_LINK defaults to "/usr/local/bin/${BIN_NAME}"
# STRIP_COMPONENTS defaults to 1
# USE_SUDO defaults to "true"
CONFIG_PATHS=("${HOME}/.config/nvim")
module_use_github_release_archetype
```

The default `install` fetches the latest release tarball, extracts it
to `INSTALL_DIR`, and symlinks `BIN_LINK` → `INSTALL_DIR/bin/<BIN_NAME>`.

### `is_outdated` for github-release

Compare the local Sidecar version against the latest release tag:

```bash
is_outdated() {
    local _local _remote
    _local=$(module_sidecar_get_version "${NAME}" 2>/dev/null || echo "")
    _remote=$(gh release view --repo "${GITHUB_REPO}" \
              --json tagName -q .tagName 2>/dev/null)
    [[ -n "${_remote}" && "${_local}" != "${_remote}" ]]
}
```

The Sidecar at `${XDG_STATE_HOME}/init_ubuntu/versions/<name>` is
written by both standalone (`install`) and engine (`runner.sh`) per
ADR-0001.

### Hybrid: github-release + override is_installed

If a binary lives somewhere non-default and `command -v ${BIN_NAME}`
isn't a reliable check, override:

```bash
module_use_github_release_archetype

is_installed() {
    [[ -x /opt/nvim/bin/nvim ]] && /opt/nvim/bin/nvim --version >/dev/null 2>&1
}
```

---

## Archetype C — config-drop

`module_use_config_archetype` binds lifecycle to
`module_default_config_*` (see `lib/module_helper.sh §6`).

`module/git-config.module.sh` and `module/ssh-config.module.sh`
are the references. Drops one file from
`${MODULE_DIR}/config/<tool>/<file>` to `${HOME}/.config/<tool>/<file>`:

```bash
CONFIG_TEMPLATE_SRC="${MODULE_DIR}/config/git/gitconfig"
CONFIG_DEST="${HOME}/.config/git/config"
# CONFIG_MARKER (optional, default "# init_ubuntu managed")
# CONFIG_MODE   (optional, default "600")
# CONFIG_DIR_MODE (optional, default "700")
module_use_config_archetype
```

Default `install` backs up any existing file, writes the template
content with the marker comment, sets mode + ownership.

### `is_outdated` for config-drop

Compare hashes:

```bash
is_outdated() {
    [[ -f "${CONFIG_DEST}" ]] || return 1
    local _src_hash _dst_hash
    _src_hash=$(sha256sum "${CONFIG_TEMPLATE_SRC}" 2>/dev/null | awk '{print $1}')
    _dst_hash=$(sha256sum "${CONFIG_DEST}"          2>/dev/null | awk '{print $1}')
    [[ "${_src_hash}" != "${_dst_hash}" ]]
}
```

---

## Archetype D — custom (hand-written)

Used when none of A/B/C fits. You implement all 6 lifecycle functions
yourself (`is_installed`, `install`, `upgrade`, `remove`, `purge`,
`verify`) and any optional functions (`is_outdated`, `doctor`).

`module/font.module.sh` and `module/nvidia-driver.module.sh` are the
references. They use `template/module-custom.template.sh` as the
starting point.

### When to choose D over hybrid-A

If the override would replace **all 6 lifecycle functions** anyway,
the macro adds no value and just clutters the file. Pick D.

If the override would replace **1–3 functions** and the rest of the
macro is still correct, pick A/B/C with override. Docker is the
canonical example.

### `is_outdated` for custom

Tool-specific. Common patterns:
- Driver / kernel module: `dkms status` shows version vs latest
- Binary in `/usr/local/bin/`: `<bin> --version` parsed vs known latest
- Font: compare a marker file's mtime to upstream release date

If your tool has no meaningful version concept, leave `is_outdated`
commented out in the template. Engine's `status` subcommand will show
`outdated: (no is_outdated)` and skip it during `upgrade --all`.

---

## When to use which override technique

| Situation | Technique | Example |
|---|---|---|
| Macro's behaviour is wrong; replace it entirely | Plain override after the macro | docker.install |
| Macro is right but you need extra steps after | Capture `_orig_<fn>` + `eval` + extra | (none yet — pattern from above) |
| Only need to override `is_installed` because the default check is unreliable | Plain override | (potential nvidia case) |
| Need to replace 4+ of the 6 functions | Switch to archetype D | font, nvidia-driver |

---

## Common pitfalls

1. **`${#APT_PKGS[@]:-0}` is a bad-substitution under `set -u`.**
   The shipped `module_default_apt_is_installed` already handles this
   via a `declare -p` existence check — use it, or copy the same
   pattern if you override `is_installed`.

2. **`declare -A` inside a function creates a LOCAL array.**
   Modules must use `declare -gA DESCRIPTION=(...)` (`g` = global)
   so the array survives being source'd from inside `_load_module`
   in test fixtures. All 10 v2 modules do this; new modules must too.

3. **Don't `cd` outside a subshell.**
   The runner (`lib/runner.sh`) sources your module in a sub-shell
   so any `cd` you do leaks scope-locally. If you must change
   directory, wrap in `(cd /path && ...)` so the subshell exits
   and restores. Tracked in task #74.

4. **Standalone vs Engine state.**
   Both write the Sidecar at `${XDG_STATE_HOME}/init_ubuntu/versions/<name>`.
   Only the engine writes `state.json`. Don't write `state.json`
   from your module — let the engine handle it (ADR-0001).

5. **`upgrade` is for the lifecycle phase, `update` is for registry rescan.**
   `setup_ubuntu update` rescans `module/`. `setup_ubuntu upgrade
   <module>` runs your module's `upgrade()` function. Don't define
   an `update()` function in your module — the macros and standalone
   CLI expect `upgrade`.

## See also

- `doc/module-spec.md` §2 (the v2 contract).
- `doc/adr/0001-standalone-engine-state-boundary.md`.
- `doc/adr/0002-all-lifecycle-functions-mandatory.md`.
- `lib/module_helper.sh` — the macros and `module_default_*` functions.
- `template/module-{apt,github-release,config,custom}.template.sh`.
