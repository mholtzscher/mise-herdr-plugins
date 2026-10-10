local cmd = require("cmd")
local json = require("json")
local file = require("file")
local source = require("lib.source")
local M = {}

---@class NativeSource
---@field kind 'github'|'local'
---@field owner string|nil
---@field repo string|nil
---@field subdir string|nil
---@field requested_ref string|nil
---@field resolved_commit string|nil

---@class NativePlugin
---@field plugin_id string
---@field plugin_root string
---@field manifest_path string
---@field version string
---@field enabled boolean
---@field warnings string[]|nil
---@field source NativeSource

-- mise's embedded JSON decoder preserves null and array identity. Do not
-- confuse null or {} with [] (notably a corrupt response must never mean empty).
local null = json.decode("null")
local array_marker = getmetatable(json.decode("[]"))

local function fail(detail)
	error("herdr plugin list --json: " .. detail, 0)
end

local function object(value, label)
	if type(value) ~= "table" or value == null or getmetatable(value) ~= nil then
		fail(label .. " must be an object")
	end
end

local function array(value, label)
	if type(value) ~= "table" or value == null or getmetatable(value) ~= array_marker then
		fail(label .. " must be an array")
	end
	local count = 0
	for k in pairs(value) do
		if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
			fail(label .. " must be an array")
		end
		count = count + 1
	end
	for i = 1, count do
		if value[i] == nil then
			fail(label .. " must be a dense array")
		end
	end
end

local function text(value, label)
	if type(value) ~= "string" or value == "" or value:find("%c") then
		fail(label .. " must be a nonempty string without controls")
	end
end

local function optional_text(value, label)
	if value ~= nil then
		text(value, label)
	end
end

local function validate_plugin(plugin, index)
	local label = "plugins[" .. index .. "]"
	object(plugin, label)
	for _, field in ipairs({ "plugin_id", "plugin_root", "manifest_path", "version" }) do
		text(plugin[field], label .. "." .. field)
	end
	label = label .. " (" .. plugin.plugin_id .. ")"
	if type(plugin.enabled) ~= "boolean" then
		fail(label .. ".enabled must be boolean")
	end
	object(plugin.source, label .. ".source")
	local s = plugin.source
	if s.kind ~= "github" and s.kind ~= "local" then
		fail(label .. ".source.kind must be github or local")
	end
	for _, field in ipairs({ "owner", "repo", "subdir", "requested_ref", "resolved_commit" }) do
		optional_text(s[field], label .. ".source." .. field)
	end
	if s.kind == "github" then
		text(s.owner, label .. ".source.owner")
		text(s.repo, label .. ".source.repo")
		if s.owner:find("/") or s.repo:find("/") then
			fail(label .. ".source has invalid owner/repo")
		end
		local ok, err = pcall(source.parse_source, s.owner .. "/" .. s.repo .. (s.subdir and "/" .. s.subdir or ""))
		if not ok then
			fail(label .. ".source: " .. tostring(err))
		end
	end
	if s.requested_ref then
		local ok, err = pcall(source.validate_ref, s.requested_ref)
		if not ok then
			fail(label .. ".source: " .. tostring(err))
		end
	end
	if plugin.warnings ~= nil then
		array(plugin.warnings, label .. ".warnings")
		for i, warning in ipairs(plugin.warnings) do
			-- Native TOML parser diagnostics may contain newlines.
			if type(warning) ~= "string" then
				fail(label .. ".warnings[" .. i .. "] must be a string")
			end
		end
	end
end

function M.list_plugins()
	-- Herdr 0.9.3 can itself turn a corrupt offline registry into a successful
	-- empty list. That inherited limitation is not detectable here: deliberately
	-- do not read or maintain a second copy of Herdr's registry.
	local ok, output = pcall(cmd.exec, "herdr plugin list --json")
	if not ok then
		fail(tostring(output))
	end
	local decoded, envelope = pcall(json.decode, output)
	if not decoded then
		fail("invalid JSON: " .. tostring(envelope))
	end
	object(envelope, "response")
	if envelope.error ~= nil then
		fail("native error response: " .. tostring(output))
	end
	object(envelope.result, "result")
	if envelope.result.type ~= "plugin_list" then
		fail("expected result.type plugin_list")
	end
	array(envelope.result.plugins, "result.plugins")
	for i, plugin in ipairs(envelope.result.plugins) do
		validate_plugin(plugin, i)
	end
	return envelope.result.plugins
end

function M.available(plugin)
	for _, warning in ipairs(plugin.warnings or {}) do
		if warning:sub(1, 22) == "manifest unavailable: " then
			return false
		end
	end
	-- exists follows symlinks; stat distinguishes incorrect path types. A
	-- symlink to a present target is valid, a dangling symlink is not.
	if not file.exists(plugin.plugin_root) or not file.exists(plugin.manifest_path) then
		return false
	end
	local root, manifest = file.stat(plugin.plugin_root), file.stat(plugin.manifest_path)
	if root ~= nil and manifest ~= nil and (root.is_symlink or manifest.is_symlink) then
		-- stat uses symlink_metadata. Follow links with POSIX shell builtins so
		-- a link to the wrong path type cannot satisfy status or convergence.
		local ok = pcall(cmd.exec, 'test -d "$ROOT" && test -f "$MANIFEST"', {
			env = { ROOT = plugin.plugin_root, MANIFEST = plugin.manifest_path },
		})
		return ok
	end
	return not not (
		root ~= nil
		and manifest ~= nil
		and (root.is_dir or root.is_symlink)
		and (manifest.is_file or manifest.is_symlink)
	)
end

function M.reported_version(plugin, request)
	local s = plugin.source
	local pin = request.version
	if type(pin) == "string" and #pin == 40 and not pin:find("[^0-9a-fA-F]") and pin == s.resolved_commit then
		return s.resolved_commit
	end
	return s.requested_ref or s.resolved_commit or plugin.version
end

function M.install(parsed_source, ref)
	local command, env
	if ref then
		command = 'herdr plugin install "$SOURCE" --ref "$REF" --yes'
		env = { SOURCE = parsed_source.canonical, REF = ref }
	else
		command = 'herdr plugin install "$SOURCE" --yes'
		env = { SOURCE = parsed_source.canonical }
	end
	local ok, err = pcall(cmd.exec, command, { env = env })
	if not ok then
		error("herdr install " .. parsed_source.canonical .. ": " .. tostring(err), 0)
	end
end

return M
