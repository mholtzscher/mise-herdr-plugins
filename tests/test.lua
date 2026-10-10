local T = { cases = {}, calls = {}, logs = {}, files = {}, output = nil }
local null = newproxy and newproxy() or function() end
local array_mt = { __metatable = false }

function T.array(values)
	return setmetatable(values or {}, array_mt)
end

T.null = null
package.preload.json = function()
	return {
		decode = function(input)
			if input == "null" then
				return null
			end
			if input == "[]" then
				return T.array()
			end
			if input == "fixture" then
				return T.output
			end
			error("malformed JSON fixture")
		end,
	}
end
package.preload.cmd = function()
	return {
		exec = function(command, opts)
			T.calls[#T.calls + 1] = { command = command, env = opts and opts.env }
			if command == "herdr plugin list --json" then
				if T.list_error then
					error(T.list_error)
				end
				return T.raw_output or "fixture"
			end
			if command == 'test -d "$ROOT" && test -f "$MANIFEST"' then
				local root, manifest = T.files[opts.env.ROOT], T.files[opts.env.MANIFEST]
				if
					not (
						root
						and (root.is_dir or root.target_is_dir)
						and manifest
						and (manifest.is_file or manifest.target_is_file)
					)
				then
					error("wrong symlink target type")
				end
				return ""
			end
			if T.install_error and opts.env.SOURCE == T.install_error.source then
				error(T.install_error.message)
			end
			T.completed[#T.completed + 1] = opts.env.SOURCE
			-- Model native persistence independently of the plugin's status logic.
			-- Tests can corrupt the resulting registry/paths after a successful exit.
			local parsed = require("lib.source").parse_source(opts.env.SOURCE)
			local plugins = T.output.result.plugins
			for i = #plugins, 1, -1 do
				local s = plugins[i].source
				if
					s.kind == "github"
					and s.owner:lower() == parsed.owner
					and s.repo:lower() == parsed.repo
					and s.subdir == parsed.subdir
				then
					table.remove(plugins, i)
				end
			end
			local plugin = T.plugin(parsed.owner, parsed.repo, parsed.subdir)
			plugin.plugin_root = "/native/" .. opts.env.SOURCE
			plugin.manifest_path = plugin.plugin_root .. "/herdr-plugin.toml"
			T.files[plugin.plugin_root] = { is_dir = true }
			T.files[plugin.manifest_path] = { is_file = true }
			plugin.source.requested_ref = opts.env.REF
			plugin.source.resolved_commit = string.rep("a", 40)
			plugins[#plugins + 1] = plugin
			if T.after_install then
				T.after_install(opts.env, plugin)
			end
		end,
	}
end
package.preload.file = function()
	return {
		exists = function(path)
			return T.files[path] ~= nil and not T.files[path].dangling
		end,
		stat = function(path)
			return T.files[path]
		end,
	}
end

function T.plugin(owner, repo, subdir)
	local plugin = {
		plugin_id = "manifest.id.not.repo",
		plugin_root = "/native/root",
		manifest_path = "/native/root/herdr-plugin.toml",
		version = "9.9.9",
		enabled = true,
		source = { kind = "github", owner = owner or "Owner", repo = repo or "Repo", subdir = subdir },
	}
	T.files[plugin.plugin_root] = { is_dir = true }
	T.files[plugin.manifest_path] = { is_file = true }
	return plugin
end

function T.envelope(plugins)
	return { id = "cli:plugin", result = { type = "plugin_list", plugins = T.array(plugins) } }
end

function T.reset()
	T.calls, T.logs, T.files, T.completed = {}, {}, {}, {}
	T.list_error, T.install_error, T.raw_output = nil, nil, nil
	T.after_install = nil
	T.output = T.envelope({})
end

function T.eq(actual, expected)
	if actual ~= expected then
		error("expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
	end
end

function T.raises(fn, fragment)
	local ok, err = pcall(fn)
	if ok then
		error("expected failure containing " .. fragment, 2)
	end
	if not tostring(err):find(fragment, 1, true) then
		error("expected error containing " .. fragment .. ", got " .. tostring(err), 2)
	end
end

function T.case(name, fn)
	T.cases[#T.cases + 1] = { name = name, fn = fn }
end

function T.run()
	local failures = 0
	local original_print = print
	for _, case in ipairs(T.cases) do
		T.reset()
		_G.print = function(message)
			T.logs[#T.logs + 1] = message
		end
		local ok, err = xpcall(case.fn, debug.traceback)
		_G.print = original_print
		if ok then
			original_print("ok - " .. case.name)
		else
			failures = failures + 1
			original_print("not ok - " .. case.name .. "\n" .. err)
		end
	end
	original_print(#T.cases .. " tests, " .. failures .. " failures")
	if failures > 0 then
		os.exit(1)
	end
end

return T
