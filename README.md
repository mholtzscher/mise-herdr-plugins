# mise-herdr-plugins

Manage Herdr's GitHub plugins declaratively with **mise bootstrap**. This is a Lua
package-manager plugin, not a versioned-tool backend: Herdr owns the checkouts,
builds, registration, and plugin state.

## Setup

Initially tested with **mise 2026.10.6** and **Herdr 0.9.3** on Linux/macOS. Git must
be installed. Keep Herdr and any plugin build toolchains in your **global** mise
configuration or on PATH; package hooks cannot rely on project-only tools.

Add to `~/.config/mise/config.toml`:

```toml
[tools]
herdr = "0.9.3"

[bootstrap.plugins]
herdr-plugins = "https://github.com/mholtzscher/mise-herdr-plugins"

[bootstrap.packages]
# Replace these illustrative sources/refs with plugins you trust.
"herdr-plugins:owner/repository" = "latest"
"herdr-plugins:owner/another-repository/plugin-subdir" = "v1.2.3"
```

The repository is currently private; cloning it requires repository access and
working Git authentication. Pin the package-manager plugin's Git revision using
`URL#<commit>` for controlled rollouts. There is no published release tag yet.

Preview, then apply:

```sh
mise bootstrap --dry-run
mise bootstrap
```

Full bootstrap provisions the package plugin, installs global tools, then applies
plugin packages. For the narrower commands, install tools first:

```sh
mise bootstrap plugins apply
mise install
mise bootstrap packages status
mise bootstrap packages apply --manager herdr-plugins --dry-run
mise bootstrap packages apply --manager herdr-plugins
mise bootstrap packages upgrade --manager herdr-plugins
```

Use `--yes` on mise commands only after reviewing their plans. A missing `herdr`
or `git` can make mise skip this manager, even with exit status 0. To make missing
prerequisites actionable, target `--manager herdr-plugins` on apply; verbose mode
(`-v`) also exposes mise's availability diagnostics. A successful whole bootstrap
alone is not proof that an unavailable manager applied packages.

## Package names and versions

Names are GitHub shorthand: `owner/repo[/subdirectory]`. Owner/repository matching
is case-insensitive; subdirectories are case-sensitive. Conflicting refs for
case-variant aliases of one source are rejected before installation. Full Git URLs and local
links are not supported. Manifest IDs need not match repository names.

| Declaration | Apply | Upgrade |
|---|---|---|
| `"latest"` | Install missing plugin from default-branch HEAD; accept any installed version | Refresh only requested plugins from default-branch HEAD |
| Exact Git ref | Install missing or mismatched ref | Keep matching pins; install mismatches at their pin |

Pins can be tags, branches, or **full commit SHAs**. They are compared exactly
against Herdr's recorded Git source, not the manifest's version. Do not add a
`ref:` prefix, and don't expect `v1.2.3` to equal `1.2.3`. `latest` does **not** mean
the latest GitHub release. Tags/branches can move; a matching recorded ref remains
satisfied. Use a full SHA for immutable source identity.

Disabled plugins count as installed. **Reinstalling a disabled plugin is refused**
before any install in that action batch, because Herdr 0.9.3's native installer
would enable it. This includes ref changes, repairs, and `latest` upgrades. Decide
whether to enable it explicitly in Herdr before updating; this plugin never
silently changes enabled state.

Status and dry runs run no installer, builds, enable/disable, or configuration
commands. Installs verify the resulting native source/ref and checkout, so a
successful subprocess exit with incorrect registration is still an error.
Batch operations are not transactions: successful earlier installs remain if a
later install fails. Failed mutations are never automatically retried.

## Trust and boundaries

Declaring packages authorizes native `herdr plugin install ... --yes`. Mise owns
the confirmation step, so Herdr's second trust prompt is skipped. Plugin builds
and commands run with your user's privileges and are **not sandboxed**. Review
the repository and manifest first; configure only trusted sources.

- Plugin packages are global to the user across all Herdr sessions.
- No config/keybinding edits, build-tool installation, runtime PATH injection,
  Herdr upgrades, server restarts, or sudo.
- No uninstall/prune hook in v1. Removing declarations does not remove plugins.
- Local links are not adopted or force-unlinked. Native installation refuses
  collisions with locally linked manifest IDs.
- Different GitHub repositories with the same manifest ID can replace each
  other through Herdr's native installer; this adapter cannot prevent that.
- Herdr 0.9.3's offline list can report an empty successful list for a corrupt
  native registry. The adapter rejects malformed CLI responses but cannot detect
  errors that Herdr itself masks. It never reads or edits Herdr's internal registry.
- Mutations are delegated to Herdr; concurrent external modifications are not
  an atomic compare-and-swap workflow.

## Development and tests

Python 3 is required **only for integration tests**, not by the plugin. The
development configuration provides Lua 5.1, Herdr, and StyLua:

```sh
mise trust
mise install
mise run check
```

Individual checks:

```sh
mise run test:unit
mise run test:integration
mise run format
```

Without installing project tools, use an existing Lua 5.1/LuaJIT and mise/Herdr:

```sh
lua tests/run.lua
sh tests/integration.sh
```

`MISE_BIN`/`HERDR_BIN` select test executables. `MISE_REQUIRE_NATIVE_TESTS=1`
requires Herdr instead of skipping native tests. `mise run test` and CI set it.
Tests clear inherited Herdr/mise runtime context and use temporary HOME/XDG/mise
state, a fake CLI, and local Git URL rewrites. After tool installation the entire
suite is offline; it never operates on your existing Herdr registry/server.
CI runs formatting, unit tests, and real mise/Herdr integration on Linux/macOS.

The implementation contract and acceptance criteria are in
[`specs/mise-herdr-bootstrap-plugin.md`](specs/mise-herdr-bootstrap-plugin.md).
Manage Herdr plugins declaratively with mise bootstrap
