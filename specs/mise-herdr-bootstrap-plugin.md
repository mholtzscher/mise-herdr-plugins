# Herdr plugin packages for mise bootstrap

Status: Approved for implementation by the user's implementation request.
Effort: L (approximately 1 day including isolated integration tests).

## Implementation clarifications

- The user authorized creating `mholtzscher/mise-herdr-plugins`, moving this
  specification/session there, and publishing one implementation PR.
- Repository visibility is private until the user requests otherwise.
- The user approved refusing updates of disabled plugins before invoking the
  installer, because Herdr 0.9.3 native reinstall enables them. Matching disabled
  installations still satisfy status/apply; latest upgrades and ref changes of
  disabled installations fail safely with an actionable error. Do not restore
  disabled state after temporarily enabling a plugin.
- Initially tested compatibility is mise 2026.10.6 and Herdr 0.9.3 on Linux/macOS.
- Herdr 0.9.3's offline listing can mask a corrupt native registry as an empty
  successful list. Validate the CLI response strictly, but document this inherited
  limitation rather than reading/editing an internal registry or claiming to fix it.

## Problem and recommendation

Automate Herdr plugin setup from a global mise configuration, so a fresh machine
can install the desired plugins through `mise bootstrap`, and repeated runs do
not reinstall matching packages.

Build a standalone **Lua package-manager plugin**, provisionally named
`mise-herdr-plugins`, registered under the manager name `herdr-plugins`.
Use `[bootstrap.plugins]` and `[bootstrap.packages]`, not a `[tools]` backend.
Delegate cloning, manifest validation, builds, registration, and storage to Herdr.

The user confirmed: bootstrap is the goal, Herdr owns plugin storage, and v1
manages plugin packages only. Config files and keybindings belong in a separate
mise dotfile setup; enabled/disabled state is not a declarative resource here.

This supersedes the earlier mise-owned tool-backend draft. There are no separate
mise checkouts, Python helper, environment activation hooks, or Herdr modifications.
No implementation repository is created or published by this design.

## Verified current system

- Mise 2026.10.6 is installed and exposes `mise bootstrap plugins`.
- Package plugins have required `PackageInstalled` and `PackageInstall` hooks;
  `PackageUpgrade` and `PackageUninstall` are optional.
- A package manager is described by `[package-manager]` in `mise.plugin.toml`.
  Hooks receive requested package names and optional opaque version pins.
- Full bootstrap installs plugins, then built-in packages, then tools, then
  packages managed by plugins. Plugin hooks see global tools, not project-only tools.
- Herdr's installed CLI exposes `plugin install SOURCE --ref REF --yes` and
  `plugin list --json`. Source is GitHub `owner/repo[/subdir]` shorthand.
- Herdr records source kind, owner, repository, subdirectory, requested Git ref,
  resolved commit, plugin root, manifest version, and enabled state.
- Manifest IDs need not match repository names. Match packages by source metadata.
- Plugin installations and enabled state are global to the current user.
- Native installation runs manifest build commands and checks compatibility.
  Locally linked plugins are not GitHub-managed packages and must not be adopted.
- Current Herdr master includes `plugin update` and installation leases, but the
  installed help and published stable docs do not promise those features. V1 uses
  native reinstall for upgrades, not unreleased commands.

References:
- https://mise.jdx.dev/package-plugin-development.html
- https://mise.jdx.dev/bootstrap/packages/plugins.html
- https://mise.jdx.dev/bootstrap.html
- https://herdr.dev/docs/plugins/
- https://herdr.dev/docs/cli-reference/
- https://github.com/herdrdev/herdr/blob/master/src/api/schema/plugins.rs
- https://github.com/herdrdev/herdr/blob/master/src/cli/plugin.rs

## User contract

Example global `~/.config/mise/config.toml`; publisher/repositories/refs below are
illustrative, not claims about existing releases:

```toml
[tools]
herdr = "latest"

[bootstrap.plugins]
herdr-plugins = "https://github.com/<publisher>/mise-herdr-plugins"

[bootstrap.packages]
"herdr-plugins:owner/repo" = "latest"
"herdr-plugins:owner/another-repo/plugin-subdir" = "v1.2.3"
```

Full setup: `mise bootstrap --dry-run`, then `mise bootstrap`.
Narrow workflow after prerequisites are installed:

```sh
mise bootstrap plugins apply
mise bootstrap packages status
mise bootstrap packages apply --manager herdr-plugins --dry-run
mise bootstrap packages apply --manager herdr-plugins
mise bootstrap packages upgrade --manager herdr-plugins
```

Consumers should pin Herdr and the mise plugin's Git revision for controlled
rollouts. Herdr and any manifest build toolchains must be global mise tools or
available on PATH. Git is also required. The plugin never installs build tools,
uses sudo, upgrades Herdr, or restarts a Herdr server.

### Version behavior

| Declaration | Apply | Explicit upgrade |
|---|---|---|
| `"latest"` | Install missing source using native default-branch HEAD; accept any valid existing GitHub-managed version | Reinstall only this requested source without `--ref`, refreshing default-branch HEAD |
| Exact Git ref | Install missing source or ref mismatch with `--ref REF` | Preserve matching pins; install mismatches at that exact ref |

Pins are opaque Git ref strings: tag, branch, or full commit SHA. There is no
SemVer sorting, tag-prefix normalization, `ref:` wrapper, or GitHub release lookup.
For immutable source identity use a full commit SHA. Tags and branches can move;
a matching recorded requested ref is satisfied until explicitly changed or
reinstalled outside the idempotent apply workflow. Upgrade does not unpin a ref.

Status compares against native source metadata, never `plugin.version`, which is
only manifest metadata. A disabled installed plugin still satisfies the package.
Preserve native enabled state on reinstall; do not force-enable it.

## Scope and alternatives

V1: public GitHub shorthand with subdirectories, exact refs, installation status,
idempotent apply, explicit targeted upgrade, dry-run previews, Linux/macOS.

Non-goals: mise-owned storage, local development links, release bundles, private
auth management, enable/disable configuration, keybindings, config edits, plugin
marketplace discovery, runtime dependency injection, or automatic project changes.
No uninstall hook in v1: pruning/removal is deferred rather than risking removal
of local links or native installations. Deleting a declaration removes nothing.

| Option | Trade-off | Decision |
|---|---|---|
| Bootstrap task calling Herdr | Simplest, but manual status/dry-run/idempotence | Reasonable one-off alternative; not the reusable plugin requested |
| Package-manager plugin | Native bootstrap status/apply/upgrade, host-owned state | Recommended |
| Versioned tool backend | Extra source/build/activation machinery; wrong ownership for bootstrap | Rejected after clarification |

Linux/macOS is a proposed initial support boundary because fixed POSIX shell
commands can pass values safely through quoted environment variables. Windows
requires a separately tested command adapter and is deferred, not implicitly supported.

## Types

New LuaCATS types, owned by `lib/source.lua` and `lib/herdr.lua` respectively:

```lua
---@class Source
---@field owner string
---@field repo string
---@field subdir string|nil
---@field canonical string -- owner/repo[/subdir]; case-fold owner/repo only

---@class PackageRequest
---@field name string
---@field version string|nil -- nil means latest

---@class NativePlugin
---@field plugin_id string
---@field plugin_root string
---@field manifest_path string
---@field version string -- manifest metadata, not the requested Git ref
---@field enabled boolean
---@field warnings string[]|nil
---@field source NativeSource

---@class NativeSource
---@field kind 'github'|'local'
---@field owner string|nil
---@field repo string|nil
---@field subdir string|nil
---@field requested_ref string|nil
---@field resolved_commit string|nil

---@class PackageResult
---@field name string -- original request spelling required by mise
---@field state 'installed'|'missing'
---@field version string|nil
```

No new persistence schema: Herdr owns package metadata; mise owns its package
tracking. Do not maintain a second plugin registry, and never edit `plugins.json`.

## Interfaces and responsibilities

`metadata.lua` contains descriptive plugin metadata only. Proposed manifest:

```toml
[package-manager]
requires = ["herdr", "git"]
supports_version_pins = true
os = ["linux", "macos"]
```

Hooks, each defined in its corresponding `hooks/package_*.lua`:

```lua
function PLUGIN:PackageInstalled(ctx) -- ctx.packages: PackageRequest[]
    -- return { packages = PackageResult[] }, one entry for every request
end

function PLUGIN:PackageInstall(ctx) -- packages, dry_run, update
    -- invoke native installer only for ctx.packages; return nil or {}
end

function PLUGIN:PackageUpgrade(ctx) -- installed requests, dry_run, update
    -- refresh latest requests; honor pins; never upgrade unrelated plugins
end
```

Shared boundaries:

```lua
-- lib/source.lua
parse_source(name) --> Source or error
validate_ref(ref) --> unchanged string or error
matches_source(source, native_source) --> boolean

-- lib/herdr.lua
list_plugins() --> NativePlugin[] or error
reported_version(plugin, request) --> string
install(source, ref_or_nil) --> nil or error

-- lib/packages.lua
installed(requests, plugins) --> PackageResult[] or error
apply(requests, dry_run) --> nil or error
upgrade(requests, dry_run) --> nil or error
```

### Status algorithm

1. Validate all request names/refs before launching action commands.
2. Read `herdr plugin list --json` once per status batch and require a valid
   successful JSON envelope containing `result.plugins`. Error envelopes,
   malformed JSON, or missing required source metadata fail; never infer an empty
   installation set from command/parser errors.
3. Match only `source.kind == "github"` and exact canonical source. Owner/repo
   are case-insensitive; subdirectory is case-sensitive. Multiple matches are an
   ambiguity error. Local links remain unmatched even if their manifest ID resembles
   a package name.
4. Confirm recorded manifest/root paths still exist and reject native warnings
   indicating an unavailable manifest. Report these broken packages as missing so
   native apply can repair them. Unknown warning/schema changes require contract tests.
5. Return a result for every request in original spelling. Installed version is
   `source.requested_ref`, else `source.resolved_commit`, else manifest version.
   For a full commit pin equal to `source.resolved_commit`, return that recorded
   commit even if the native installer originally selected it through a tag.
6. Mise compares requested pin and reported installed version by exact equality.
   The hook must not echo a requested pin unless native metadata actually proves it.

Status invokes no install/build/enable/config commands and has no prompts or
network resolution. Native CLI locking may touch lockfiles; plugin installations,
user configuration, and state must remain unchanged.

### Action algorithm

Use fixed POSIX command strings and pass values through `cmd.exec`'s environment
option. Source/ref text must never be concatenated into shell code:

```lua
-- Pinned installation:
cmd.exec('herdr plugin install "$SOURCE" --ref "$REF" --yes', {
    env = { SOURCE = source.canonical, REF = ref },
})
-- Latest installation:
cmd.exec('herdr plugin install "$SOURCE" --yes', {
    env = { SOURCE = source.canonical },
})
```

Validate nonempty owner/repo segments, and reject empty/dot/parent/backslash/NUL
subdirectory segments, control characters, and refs beginning with `-`.
Refs are otherwise opaque; do not parse SemVer or rewrite them.

Dry runs log the exact intended source/ref and call no installer. `ctx.update`
requires no extra action because native install fetches Git directly. Upgrade
filters to the supplied batch; latest uses reinstall, matching pins are skipped,
and pinned mismatches use the exact ref. No bulk `herdr plugin update` invocation.

Native errors abort the batch with package context and stderr; previously
completed installs remain installed. Never blindly retry a failed mutation.
The adapter explicitly verifies native status after every successful installer
exit: installed source, available checkout, and exact pin where requested. Real
integration tests demonstrated that mise's own post-action status can print success
without enforcing the pin, so it is not sufficient to detect failed convergence.
Incorrect ref/source output must never appear satisfied.

`--yes` bypasses Herdr's trust prompt because mise owns action confirmation.
Documentation must explain that builds and plugin commands run as the user,
are not sandboxed, and only trusted sources should be declared. No secrets are
written or handled by this plugin.

Native manifest-ID collisions between different GitHub repositories remain a
Herdr limitation: install can replace another GitHub-managed plugin with that ID.
Do not promise collision protection without fetching/parsing remote manifests.
Call this out in documentation and avoid adding that machinery to v1.

## Standalone project layout

```text
mise-herdr-plugins/                     # new — standalone repository
├── metadata.lua                       # new — plugin metadata
├── mise.plugin.toml                   # new — package-manager capability declaration
├── hooks/
│   ├── package_installed.lua          # new — read-only status entrypoint
│   ├── package_install.lua            # new — bootstrap apply entrypoint
│   └── package_upgrade.lua            # new — targeted upgrade entrypoint
├── lib/
│   ├── source.lua                     # new — source/ref validation and identity
│   ├── herdr.lua                      # new — native CLI/JSON adapter
│   └── packages.lua                   # new — matching and batch lifecycle policy
├── tests/
│   ├── source_spec.lua                # new — validation/identity cases
│   ├── packages_spec.lua              # new — status/version/dry-run/batch cases
│   ├── fake-herdr                     # new — CLI argument and failure fixtures
│   └── integration.sh                 # new — isolated real mise/Herdr checks
├── mise.toml                          # new — development/test tools and tasks
├── README.md                          # new — global bootstrap recipe and limits
└── .github/workflows/ci.yml            # new — Linux/macOS test matrix
```

All application interfaces/types are new and owned above. Existing Herdr and mise
source is unchanged; this Nix repository only gains this specification document.

## Deliverables and testable acceptance

| ID | Outcome | Effort | Owning paths | Depends on | Acceptance |
|---|---|---|---|---|---|
| D1 | Minimal package plugin and real CLI/bootstrap schema contract tests | M | metadata.lua, mise.plugin.toml, tests/fake-herdr, tests/integration.sh | — | A1, A2 |
| D2 | Correct source/ref parsing and installed-state reporting | M | lib/source.lua, lib/herdr.lua, lib/packages.lua, hooks/package_installed.lua, source_spec.lua, packages_spec.lua | D1 | A3–A6 |
| D3 | Native apply/upgrade and non-mutating dry runs | M | hooks/package_install.lua, hooks/package_upgrade.lua, lib/herdr.lua, lib/packages.lua, packages_spec.lua, integration.sh | D2 | A7–A10 |
| D4 | User documentation, repeatable test command, platform CI | M | README.md, mise.toml, .github/workflows/ci.yml | D3 | A11 |

| ID | Check | Expected result | Procedure |
|---|---|---|---|
| A1 | Real installed mise loads package hooks | Correct package-manager classification and dispatch | In throwaway HOME/MISE_DATA_DIR/XDG config, `mise plugins link herdr-plugins ./mise-herdr-plugins`, then bootstrap packages status with fake CLI |
| A2 | Full bootstrap on empty isolated setup | Global Herdr tool is available before plugin package apply | Isolated global config plus `mise bootstrap --only plugins,packages,tools`; fake/local tool fixture first; network smoke test separately |
| A3 | Root/subdirectory, case handling, manifest ID differs from repo | Match by source, preserve subdir case and original request name | Lua fixture unit tests |
| A4 | Manifest version differs from ref; requested tag and resolved commit cases | Exact Git-ref drift detected; no prefix normalization; SHA equality based on recorded commit | Fixture status tests and real native response fixture |
| A5 | Empty config, subset, disabled plugin, local link, duplicate sources | Empty batch safe; all requested results returned; disabled accepted; local not adopted; duplicates fail | Fixture tests |
| A6 | Invalid JSON/error envelope, missing files, invalid paths/refs | Errors are not mistaken for missing packages; broken native checkout repairable; invalid input rejected before install | Failure fixture tests |
| A7 | Apply missing and mismatched packages; repeat with matching state | Correct source/--ref/--yes argv; second apply does no install | Fake CLI call log plus real isolated idempotence test |
| A8 | Status and dry-run apply/upgrade | No installer/build/config/enable commands executed, native state unchanged | Compare fake call log and isolated registry/config/state sentinels |
| A9 | Upgrade latest plus pinned entries; subset selection | Only requested latest sources refresh; matching pins remain; mismatch repaired without unpinning | Fake CLI batch tests |
| A10 | CLI/build failure and locally linked ID conflict | Nonzero result with source context; no false success, no retries, no force unlink, earlier successes retained | Failure injection and named isolated native fixture |
| A11 | Linux/macOS, spaces/metacharacters in valid ref/path; missing Git/Herdr/toolchain | Tests pass; quoted values literal; prerequisites/failures actionable; README states latest/default-branch and global-tool behavior | Proposed `mise run test` plus CI matrix |

`mise run test` is a proposed task to add in D4, not an existing command here.
D1 chooses and wires a minimal Lua 5.1-compatible fixture test runner and records
exact isolated integration invocations. Tests must clear inherited Herdr socket,
session, and runtime environment and use throwaway configuration/data paths; never
touch or stop the user's Herdr server. Real public GitHub smoke tests require
network access, but fake CLI and local fixture tests must not.

## Risks, mitigations, and review

| Risk | Mitigation |
|---|---|
| Incorrect ref reporting repeatedly reinstalls or hides drift | Exact source metadata tests, distinguish manifest version from Git ref |
| Native CLI/schema drift or different runtime/server version | Installed CLI fixtures plus pinned native integration matrix; fail on malformed responses |
| Bootstrap sees no project-only toolchain | Global config recipe, explicit prerequisites, full-bootstrap ordering test |
| Native ID collisions or mutable tags | Document inherited limits, recommend full commit pins and trusted repositories |
| Executable third-party builds and nontransactional batches | Clear trust warning, previews, bounded action scope, no automatic retry |
| User expects pruning or enabled-state reconciliation | Explicit v1 exclusions; no silent deletion or enablement |

Review the proposed Linux/macOS scope and deferred prune support. Once the design
is approved, ask for the standalone implementation directory before creating files
outside this repository. A publisher URL and release workflow can be chosen later;
no publication is authorized by this specification.
