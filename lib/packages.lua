local source = require("lib.source")
local herdr = require("lib.herdr")
local M = {}

---@class PackageResult
---@field name string
---@field state 'installed'|'missing'
---@field version string|nil

local function validate(requests)
	if type(requests) ~= "table" then
		error("packages must be an array", 0)
	end
	local count = 0
	for k in pairs(requests) do
		if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
			error("packages must be an array", 0)
		end
		count = count + 1
	end
	local batch, declared = {}, {}
	for i = 1, count do
		local request = requests[i]
		if type(request) ~= "table" then
			error("packages must contain request objects without gaps", 0)
		end
		local parsed = source.parse_source(request.name)
		local ref = request.version
		if ref == "latest" then
			ref = nil
		end
		if ref ~= nil then
			local ok, err = pcall(source.validate_ref, ref)
			if not ok then
				error("source " .. request.name .. ": " .. tostring(err), 0)
			end
		end
		local previous = declared[parsed.canonical]
		if previous and previous.version ~= ref then
			error(
				"conflicting refs for source " .. parsed.canonical .. ": " .. previous.name .. " and " .. request.name,
				0
			)
		end
		batch[i] = { name = request.name, version = ref, source = parsed }
		declared[parsed.canonical] = batch[i]
	end
	return batch
end

local function match(request, plugins)
	local found
	for _, plugin in ipairs(plugins) do
		if source.matches_source(request.source, plugin.source) then
			if found then
				error("ambiguous native source " .. request.name .. ": multiple installed plugins", 0)
			end
			found = plugin
		end
	end
	return found
end

local function status(batch, plugins)
	local results, matches = {}, {}
	for i, request in ipairs(batch) do
		local plugin = match(request, plugins)
		matches[i] = plugin
		local available = plugin and herdr.available(plugin)
		-- A manifest version is useful display metadata for latest, but cannot
		-- prove an exact Git ref when the native record lacks Git metadata.
		if
			available
			and request.version ~= nil
			and plugin.source.requested_ref == nil
			and plugin.source.resolved_commit == nil
		then
			available = false
		end
		results[i] = {
			name = request.name,
			state = available and "installed" or "missing",
			version = available and herdr.reported_version(plugin, request) or nil,
		}
	end
	return results, matches
end

function M.installed(requests, plugins)
	local batch = validate(requests)
	if #batch == 0 then
		return {}
	end
	local results = status(batch, plugins or herdr.list_plugins())
	return results
end

local function verify_install(request)
	local ok, err = pcall(function()
		local plugin = match(request, herdr.list_plugins())
		if plugin == nil or not herdr.available(plugin) then
			error("matching GitHub source is missing or unavailable", 0)
		end
		-- A successful process exit is not proof of installation. Pins must be
		-- proved by native Git metadata, never a coincidentally equal manifest
		-- version. reported_version also handles a full SHA installed via a tag.
		local actual_version = herdr.reported_version(plugin, request)
		if
			request.version ~= nil
			and (
				actual_version ~= request.version
				or (plugin.source.requested_ref == nil and plugin.source.resolved_commit == nil)
			)
		then
			error(
				"requested ref "
					.. string.format("%q", request.version)
					.. " was not recorded (reported version "
					.. string.format("%q", actual_version)
					.. ")",
				0
			)
		end
	end)
	if not ok then
		error("source " .. request.name .. ": installation did not converge: " .. tostring(err), 0)
	end
end

local function action(requests, dry_run, upgrade)
	local batch = validate(requests)
	if #batch == 0 then
		return
	end
	local results, matches = status(batch, herdr.list_plugins())
	local plan, planned = {}, {}
	-- Compute and validate the whole plan before mutations. Even a broken
	-- checkout can have disabled state that a reinstall would silently enable.
	for i, request in ipairs(batch) do
		local result, plugin = results[i], matches[i]
		local needed = result.state == "missing"
			or (request.version ~= nil and request.version ~= result.version)
			or (upgrade and request.version == nil)
		if needed then
			if plugin and not plugin.enabled then
				error(
					"source "
						.. request.name
						.. ": refusing to reinstall disabled plugin "
						.. plugin.plugin_id
						.. "; native reinstall enables it. Enable it explicitly in Herdr before updating",
					0
				)
			end
			if not planned[request.source.canonical] then
				plan[#plan + 1] = request
				planned[request.source.canonical] = true
			end
		end
	end
	for _, request in ipairs(plan) do
		if dry_run then
			print(
				"would install "
					.. request.source.canonical
					.. (request.version and " --ref " .. string.format("%q", request.version) or " (default-branch HEAD)")
					.. " --yes"
			)
		else
			herdr.install(request.source, request.version)
			verify_install(request)
		end
	end
end

function M.apply(requests, dry_run)
	return action(requests, dry_run, false)
end

function M.upgrade(requests, dry_run)
	return action(requests, dry_run, true)
end

return M
