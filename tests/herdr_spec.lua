local T = require("tests.test")
local herdr = require("lib.herdr")
local source = require("lib.source")

T.case("native list uses one fixed read-only command and accepts a real empty array", function()
	T.eq(#herdr.list_plugins(), 0)
	T.eq(#T.calls, 1)
	T.eq(T.calls[1].command, "herdr plugin list --json")
	T.eq(T.calls[1].env, nil)
end)

T.case("native list rejects command failure and malformed JSON", function()
	T.list_error = "exit 1: native stderr"
	T.raises(herdr.list_plugins, "native stderr")
	T.list_error, T.raw_output = nil, "not JSON"
	T.raises(herdr.list_plugins, "invalid JSON")
end)

T.case("native list strictly requires successful typed envelope and plugins array", function()
	local invalid = {
		T.null,
		T.array(),
		{},
		{ result = T.null },
		{ result = {} },
		{ error = T.null, result = T.envelope({}).result },
		{ error = { message = "nope" } },
		{ result = { type = "other", plugins = T.array() } },
		{ result = { type = "plugin_list" } },
		{ result = { type = "plugin_list", plugins = T.null } },
		{ result = { type = "plugin_list", plugins = {} } },
		{ result = { type = "plugin_list", plugins = { ["1"] = T.plugin() } } },
		{ result = { type = "plugin_list", plugins = T.array({ [2] = T.plugin() }) } },
	}
	for _, envelope in ipairs(invalid) do
		T.output = envelope
		T.raises(herdr.list_plugins, "herdr plugin list --json")
	end
end)

T.case("native source metadata and required plugin fields fail closed", function()
	local invalid = {
		{ "source", nil },
		{ "source", T.null },
		{ "source", T.array() },
		{ "enabled", "false" },
		{ "plugin_id", false },
		{ "plugin_root", "" },
		{ "manifest_path", T.null },
		{ "version", nil },
	}
	for _, replacement in ipairs(invalid) do
		local plugin = T.plugin()
		plugin[replacement[1]] = replacement[2]
		T.output = T.envelope({ plugin })
		T.raises(herdr.list_plugins, "plugins[1]")
	end
	for _, field in ipairs({ "kind", "owner", "repo", "subdir", "requested_ref", "resolved_commit" }) do
		for _, value in ipairs({ T.null, false, 42, "" }) do
			local plugin = T.plugin()
			plugin.source[field] = value
			T.output = T.envelope({ plugin })
			T.raises(herdr.list_plugins, ".source.")
		end
	end
	for _, field in ipairs({ "kind", "owner", "repo" }) do
		local plugin = T.plugin()
		plugin.source[field] = nil
		T.output = T.envelope({ plugin })
		T.raises(herdr.list_plugins, ".source.")
	end
end)

T.case("native sources reject malformed GitHub path components and refs", function()
	for _, pair in ipairs({
		{ "kind", "remote" },
		{ "owner", "a/b" },
		{ "repo", "../r" },
		{ "subdir", "../x" },
		{ "requested_ref", "-evil" },
	}) do
		local plugin = T.plugin()
		plugin.source[pair[1]] = pair[2]
		T.output = T.envelope({ plugin })
		T.raises(herdr.list_plugins, ".source")
	end
end)

T.case("native warnings must be a dense string array, not null or an object", function()
	for _, warnings in ipairs({ T.null, {}, T.array({ false }), T.array({ T.null }), T.array({ [2] = "warning" }) }) do
		local plugin = T.plugin()
		plugin.warnings = warnings
		T.output = T.envelope({ plugin })
		T.raises(herdr.list_plugins, ".warnings")
	end
	local plugin = T.plugin()
	plugin.warnings = T.array({ "unknown event: future-event" })
	T.output = T.envelope({ plugin })
	T.eq(herdr.list_plugins()[1], plugin)
end)

T.case("missing, wrong-type and dangling native paths are unavailable", function()
	local plugin = T.plugin()
	T.eq(herdr.available(plugin), true)
	T.files[plugin.plugin_root] = { is_file = true }
	T.eq(herdr.available(plugin), false)
	T.files[plugin.plugin_root] = { is_dir = true }
	T.files[plugin.manifest_path] = { is_dir = true }
	T.eq(herdr.available(plugin), false)
	T.files[plugin.manifest_path] = { is_symlink = true, dangling = true }
	T.eq(herdr.available(plugin), false)
	T.files[plugin.manifest_path] = { is_symlink = true, target_is_file = true }
	T.eq(herdr.available(plugin), true)
	T.files[plugin.plugin_root] = nil
	T.eq(herdr.available(plugin), false)
end)

T.case("symlink target types are checked without interpreting recorded paths", function()
	local plugin = T.plugin()
	plugin.plugin_root = "/native/root 'quoted';$(no)"
	plugin.manifest_path = "/native/manifest 'quoted';$(no)"
	T.files[plugin.plugin_root] = { is_symlink = true, target_is_dir = true }
	T.files[plugin.manifest_path] = { is_symlink = true, target_is_file = true }
	T.eq(herdr.available(plugin), true)
	T.eq(T.calls[1].env.ROOT, plugin.plugin_root)
	T.eq(T.calls[1].env.MANIFEST, plugin.manifest_path)
	T.files[plugin.manifest_path].target_is_file = false
	T.eq(herdr.available(plugin), false)
	T.files[plugin.manifest_path].target_is_file = true
	T.files[plugin.plugin_root].target_is_dir = false
	T.eq(herdr.available(plugin), false)
end)

T.case("native unavailable-manifest warnings override present paths", function()
	local plugin = T.plugin()
	plugin.warnings = T.array({ "manifest unavailable: invalid TOML\n at line 1" })
	T.output = T.envelope({ plugin })
	T.eq(herdr.list_plugins()[1], plugin)
	T.eq(herdr.available(plugin), false)
	plugin.warnings = T.array({ "unknown event: future-event" })
	T.eq(herdr.available(plugin), true)
end)

T.case("install adapter keeps metacharacters literal in env and fixed shell code", function()
	local parsed = source.parse_source("Owner/Repo/a 'quoted';$(echo no)")
	local ref = "tag '\";$(echo no)\\ with spaces"
	herdr.install(parsed, ref)
	T.eq(T.calls[1].command, 'herdr plugin install "$SOURCE" --ref "$REF" --yes')
	T.eq(T.calls[1].env.SOURCE, "owner/repo/a 'quoted';$(echo no)")
	T.eq(T.calls[1].env.REF, ref)
	herdr.install(parsed, nil)
	T.eq(T.calls[2].command, 'herdr plugin install "$SOURCE" --yes')
	T.eq(T.calls[2].env.REF, nil)
end)
