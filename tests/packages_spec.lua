local T = require("tests.test")
local packages = require("lib.packages")

local function request(name, version)
	return { name = name or "Owner/Repo", version = version }
end

T.case("empty batches launch no commands", function()
	T.eq(#packages.installed({}), 0)
	packages.apply({})
	packages.upgrade({})
	T.eq(#T.calls, 0)
end)

T.case("status matches source metadata, preserves spelling and reports every subset request", function()
	local plugin = T.plugin("Owner", "Repo", "Plugins/My Plugin")
	plugin.source.requested_ref = "v1.2.3"
	T.output = T.envelope({ plugin, T.plugin("unrelated", "repo") })
	local results = packages.installed({
		request("OWNER/REPO/Plugins/My Plugin", "v1.2.3"),
		request("owner/repo/plugins/My Plugin"),
		request("missing/repo"),
	})
	T.eq(#results, 3)
	T.eq(results[1].name, "OWNER/REPO/Plugins/My Plugin")
	T.eq(results[1].state, "installed")
	T.eq(results[1].version, "v1.2.3")
	T.eq(results[2].state, "missing")
	T.eq(results[3].state, "missing")
	T.eq(#T.calls, 1)
end)

T.case("versions come from ref then commit then manifest, never echoed request", function()
	local plugin = T.plugin()
	local sha = string.rep("a", 40)
	plugin.source.requested_ref, plugin.source.resolved_commit = "v1", sha
	T.output = T.envelope({ plugin })
	T.eq(packages.installed({ request(nil, "v2") })[1].version, "v1")
	T.eq(packages.installed({ request(nil, "1") })[1].version, "v1")
	T.eq(packages.installed({ request(nil, sha) })[1].version, sha)
	T.eq(packages.installed({ request(nil, string.rep("b", 40)) })[1].version, "v1")
	plugin.source.requested_ref = nil
	T.eq(packages.installed({ request() })[1].version, sha)
	plugin.source.resolved_commit = nil
	T.eq(packages.installed({ request() })[1].version, "9.9.9")
end)

T.case("disabled matching package satisfies status and apply without enable commands", function()
	local plugin = T.plugin()
	plugin.enabled, plugin.source.requested_ref = false, "v1"
	T.output = T.envelope({ plugin })
	T.eq(packages.installed({ request(nil, "v1") })[1].state, "installed")
	packages.apply({ request(nil, "v1") })
	packages.apply({ request() })
	packages.upgrade({ request(nil, "v1") })
	T.eq(#T.completed, 0)
	T.eq(#T.calls, 4)
end)

T.case("manifest-only version never satisfies an exact Git pin", function()
	local plugin = T.plugin()
	T.output = T.envelope({ plugin })
	T.eq(packages.installed({ request(nil, plugin.version) })[1].state, "missing")
	T.eq(packages.installed({ request() })[1].version, plugin.version)
	packages.apply({ request(nil, plugin.version) })
	T.eq(#T.completed, 1)
end)

T.case("local links are not adopted and local conflicts never trigger unlink or retry", function()
	local plugin = T.plugin()
	plugin.source = { kind = "local" }
	T.output = T.envelope({ plugin })
	T.eq(packages.installed({ request() })[1].state, "missing")
	T.install_error = { source = "owner/repo", message = "already linked from a local path" }
	T.raises(function()
		packages.apply({ request() })
	end, "herdr install owner/repo: ")
	T.eq(#T.calls, 3)
	T.eq(T.calls[3].command, 'herdr plugin install "$SOURCE" --yes')
	T.eq(#T.completed, 0)
end)

T.case("duplicate native sources abort status and preflight action before first mutation", function()
	T.output = T.envelope({ T.plugin(), T.plugin("OWNER", "REPO") })
	T.raises(function()
		packages.installed({ request() })
	end, "ambiguous native source Owner/Repo")
	T.raises(function()
		packages.apply({ request("missing/repo"), request() })
	end, "ambiguous")
	T.eq(#T.completed, 0)
	T.eq(#T.calls, 2)
end)

T.case("whole request batch is validated before even listing native state", function()
	for _, run in ipairs({ packages.installed, packages.apply, packages.upgrade }) do
		T.raises(function()
			run({ request("valid/repo"), request("bad/repo/..") })
		end, "invalid source")
		T.raises(function()
			run({ request("valid/repo"), request("another/repo", "-bad") })
		end, "source another/repo")
		T.raises(function()
			run({ [2] = request() })
		end, "without gaps")
	end
	T.eq(#T.calls, 0)
end)

T.case("canonical source declarations reject conflicting refs before any native command", function()
	for _, run in ipairs({ packages.installed, packages.apply, packages.upgrade }) do
		T.raises(function()
			run({ request("Owner/Repo", "v1"), request("owner/repo", "v2") })
		end, "conflicting refs")
		T.raises(function()
			run({ request("Owner/Repo"), request("owner/repo", "v1") })
		end, "conflicting refs")
	end
	T.eq(#T.calls, 0)
end)

T.case("matching canonical aliases retain status names but install only once", function()
	local requests = { request("Owner/Repo", "v1"), request("owner/repo", "v1") }
	packages.apply(requests)
	T.eq(#T.completed, 1)
	local results = packages.installed(requests)
	T.eq(results[1].name, "Owner/Repo")
	T.eq(results[2].name, "owner/repo")
	T.eq(results[1].version, "v1")
	T.eq(results[2].version, "v1")
end)

T.case("malformed unrelated native metadata prevents action rather than becoming missing", function()
	local plugin = T.plugin("unrelated", "repo")
	plugin.source.owner = T.null
	T.output = T.envelope({ plugin })
	T.raises(function()
		packages.apply({ request() })
	end, ".source.owner")
	T.eq(#T.calls, 1)
	T.eq(#T.completed, 0)
end)

T.case("broken checkout is reported missing and repaired natively", function()
	local plugin = T.plugin()
	plugin.warnings = T.array({ "manifest unavailable: parse error" })
	T.output = T.envelope({ plugin })
	T.eq(packages.installed({ request() })[1].state, "missing")
	packages.apply({ request() })
	T.eq(T.completed[1], "owner/repo")
end)

T.case("apply installs missing and exact mismatches but skips matching and unrelated sources", function()
	local plugin = T.plugin()
	plugin.source.requested_ref = "v1"
	T.output = T.envelope({ plugin, T.plugin("unrelated", "repo") })
	packages.apply({ request("missing/repo"), request(nil, "v2") })
	T.eq(#T.calls, 5)
	T.eq(T.calls[2].env.SOURCE, "missing/repo")
	T.eq(T.calls[2].env.REF, nil)
	T.eq(T.calls[3].command, "herdr plugin list --json")
	T.eq(T.calls[4].env.SOURCE, "owner/repo")
	T.eq(T.calls[4].env.REF, "v2")
	T.eq(T.calls[5].command, "herdr plugin list --json")
	packages.apply({ request(nil, "v2") })
	T.eq(#T.calls, 6)
	packages.apply({ request(nil, "latest") })
	T.eq(#T.calls, 7)
end)

T.case("dry-run apply and upgrade only list once and log intended sources and exact refs", function()
	local plugin = T.plugin()
	plugin.source.requested_ref = "v1"
	T.output = T.envelope({ plugin })
	local ref = "tag with spaces;$(no)"
	packages.apply({ request("missing/repo", ref), request(nil, "v1") }, true)
	T.eq(#T.calls, 1)
	T.eq(#T.logs, 1)
	T.eq(T.logs[1], 'would install missing/repo --ref "tag with spaces;$(no)" --yes')
	packages.upgrade({ request(), request("missing/repo", "v2") }, true)
	T.eq(#T.calls, 2)
	T.eq(#T.logs, 3)
	T.eq(#T.completed, 0)
end)

T.case("upgrade refreshes only supplied latest sources and never unpins matching refs", function()
	local latest, pinned, drift = T.plugin(), T.plugin("pin", "repo"), T.plugin("drift", "repo")
	pinned.source.requested_ref, drift.source.requested_ref = "release", "old"
	T.output = T.envelope({ latest, pinned, drift, T.plugin("unrelated", "repo") })
	packages.upgrade({ request(), request("pin/repo", "release"), request("drift/repo", "new") })
	T.eq(#T.calls, 5)
	T.eq(T.calls[2].env.SOURCE, "owner/repo")
	T.eq(T.calls[2].env.REF, nil)
	T.eq(T.calls[3].command, "herdr plugin list --json")
	T.eq(T.calls[4].env.SOURCE, "drift/repo")
	T.eq(T.calls[4].env.REF, "new")
	T.eq(T.calls[5].command, "herdr plugin list --json")
end)

T.case("disabled ref changes, latest upgrades and repairs refuse entire batch before mutation", function()
	local plugin = T.plugin()
	plugin.enabled, plugin.source.requested_ref = false, "v1"
	T.output = T.envelope({ plugin })
	T.raises(function()
		packages.apply({ request("missing/repo"), request(nil, "v2") })
	end, "source Owner/Repo: refusing")
	T.raises(function()
		packages.upgrade({ request("missing/repo"), request() })
	end, "disabled plugin")
	T.raises(function()
		packages.upgrade({ request() }, true)
	end, "disabled plugin")
	T.files[plugin.manifest_path] = nil
	T.raises(function()
		packages.apply({ request() })
	end, "disabled plugin")
	T.eq(#T.calls, 4)
	T.eq(#T.completed, 0)
end)

T.case("failure keeps earlier successes, aborts later entries, retains stderr and never retries", function()
	T.install_error = { source = "second/repo", message = "exit 1: build tool missing" }
	local ok, err = pcall(function()
		packages.apply({ request("first/repo"), request("second/repo"), request("third/repo") })
	end)
	T.eq(ok, false)
	T.eq(tostring(err):find("herdr install second/repo: ", 1, true) ~= nil, true)
	T.eq(tostring(err):find("build tool missing", 1, true) ~= nil, true)
	T.eq(#T.calls, 4)
	T.eq(#T.completed, 1)
	T.eq(T.completed[1], "first/repo")
	T.eq(T.calls[4].env.SOURCE, "second/repo")
	T.eq(T.output.result.plugins[1].source.owner, "first")
end)

T.case("successful installer with wrong ref fails immediately and aborts later packages", function()
	T.after_install = function(env, plugin)
		if env.SOURCE == "second/repo" then
			plugin.source.requested_ref = "wrong-ref"
		end
	end
	T.raises(function()
		packages.apply({ request("first/repo", "v1"), request("second/repo", "v2"), request("third/repo") })
	end, "source second/repo: installation did not converge: requested ref")
	T.eq(#T.calls, 5)
	T.eq(#T.completed, 2)
	T.eq(T.completed[1], "first/repo")
	T.eq(T.completed[2], "second/repo")
	T.eq(T.output.result.plugins[1].source.requested_ref, "v1")
	T.eq(packages.installed({ request("second/repo", "v2") })[1].version, "wrong-ref")
end)

T.case("successful installer with wrong source fails for latest and pins", function()
	for _, run in ipairs({ packages.apply, packages.upgrade }) do
		for _, version in ipairs({ "latest", "wanted" }) do
			T.reset()
			T.after_install = function(_, plugin)
				plugin.source.repo = "wrong-repo"
			end
			T.raises(function()
				run({ request(nil, version), request("later/repo") })
			end, "source Owner/Repo: installation did not converge: matching GitHub source is missing")
			T.eq(#T.calls, 3)
			T.eq(#T.completed, 1)
		end
	end
end)

T.case("post-install missing paths and native unavailable warnings fail convergence", function()
	for _, corrupt in ipairs({
		function(plugin)
			T.files[plugin.plugin_root] = nil
		end,
		function(plugin)
			T.files[plugin.manifest_path] = nil
		end,
		function(plugin)
			plugin.warnings = T.array({ "manifest unavailable: invalid TOML" })
		end,
	}) do
		T.reset()
		T.after_install = function(_, plugin)
			corrupt(plugin)
		end
		T.raises(function()
			packages.apply({ request(), request("later/repo") })
		end, "source Owner/Repo: installation did not converge: matching GitHub source is missing or unavailable")
		T.eq(#T.calls, 3)
		T.eq(#T.completed, 1)
	end
end)

T.case("post-install ambiguous source fails before another installer and never retries", function()
	T.after_install = function(_, plugin)
		T.output.result.plugins[#T.output.result.plugins + 1] = T.plugin(plugin.source.owner, plugin.source.repo)
	end
	T.raises(function()
		packages.apply({ request(), request("later/repo") })
	end, "source Owner/Repo: installation did not converge: ambiguous native source Owner/Repo")
	T.eq(#T.calls, 3)
	T.eq(#T.completed, 1)
end)

T.case("post-install malformed metadata and list failures retain source context", function()
	for _, corrupt in ipairs({
		function(plugin)
			plugin.source.owner = T.null
		end,
		function()
			T.output = T.envelope({})
		end,
		function()
			T.list_error = "exit 1: verification stderr"
		end,
		function()
			T.raw_output = "not JSON"
		end,
	}) do
		T.reset()
		T.after_install = function(_, plugin)
			corrupt(plugin)
		end
		T.raises(function()
			packages.apply({ request(), request("later/repo") })
		end, "source Owner/Repo: installation did not converge:")
		T.eq(#T.calls, 3)
		T.eq(#T.completed, 1)
	end
end)

T.case("post-install pin requires native metadata even when manifest version matches", function()
	T.after_install = function(_, plugin)
		plugin.source.requested_ref, plugin.source.resolved_commit = nil, nil
		plugin.version = "wanted"
	end
	T.raises(function()
		packages.apply({ request(nil, "wanted") })
	end, "source Owner/Repo: installation did not converge: requested ref")
	T.eq(#T.calls, 3)
end)

T.case("post-install full commit pin via tag converges from resolved native SHA", function()
	local sha = string.rep("a", 40)
	T.after_install = function(_, plugin)
		plugin.source.requested_ref = "release-tag"
	end
	packages.apply({ request(nil, sha) })
	T.eq(#T.calls, 3)
	T.eq(packages.installed({ request(nil, sha) })[1].version, sha)
end)

T.case("post-install latest accepts actual version without echoing a requested ref", function()
	T.after_install = function(_, plugin)
		plugin.source.requested_ref = "native-current-ref"
		plugin.version = "different-manifest-version"
	end
	packages.apply({ request() })
	T.eq(#T.calls, 3)
	T.eq(packages.installed({ request() })[1].version, "native-current-ref")
end)

T.case("metadata and hooks provide package-only batch dispatch without uninstall", function()
	dofile("metadata.lua")
	dofile("hooks/package_installed.lua")
	dofile("hooks/package_install.lua")
	dofile("hooks/package_upgrade.lua")
	T.eq(PLUGIN.name, "herdr-plugins")
	T.eq(PLUGIN.PackageUninstall, nil)
	T.eq(PLUGIN.BackendInstall, nil)
	T.eq(PLUGIN:PackageInstalled({ packages = { request() } }).packages[1].state, "missing")
	PLUGIN:PackageInstall({ packages = { request() }, dry_run = true, update = true })
	PLUGIN:PackageUpgrade({ packages = { request() }, dry_run = true, update = true })
	T.eq(#T.calls, 3)
	T.eq(#T.completed, 0)
end)
