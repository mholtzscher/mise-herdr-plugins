local M = {}

---@class Source
---@field owner string
---@field repo string
---@field subdir string|nil
---@field canonical string

---@class PackageRequest
---@field name string
---@field version string|nil

local function invalid(name, detail)
	error("invalid source " .. tostring(name) .. ": " .. detail, 0)
end

function M.parse_source(name)
	if type(name) ~= "string" or name == "" or name:find("[%c\\]") then
		invalid(name, "expected owner/repo[/subdir] without controls or backslashes")
	end
	local parts = {}
	for part in (name .. "/"):gmatch("(.-)/") do
		if part == "" or part == "." or part == ".." then
			invalid(name, "empty, dot and parent segments are forbidden")
		end
		parts[#parts + 1] = part
	end
	if #parts < 2 then
		invalid(name, "expected owner/repo[/subdir]")
	end
	for i = 1, 2 do
		if parts[i]:find("[^A-Za-z0-9_.-]") then
			invalid(name, "owner/repo must contain only ASCII letters, digits, dot, underscore or hyphen")
		end
	end
	local subdir = #parts > 2 and table.concat(parts, "/", 3) or nil
	local owner, repo = parts[1]:lower(), parts[2]:lower()
	return {
		owner = owner,
		repo = repo,
		subdir = subdir,
		canonical = owner .. "/" .. repo .. (subdir and "/" .. subdir or ""),
	}
end

function M.validate_ref(ref)
	if type(ref) ~= "string" or ref == "" or ref:find("%c") or ref:sub(1, 1) == "-" then
		error(
			"invalid Git ref " .. tostring(ref) .. ": expected nonempty opaque ref without controls or leading '-'",
			0
		)
	end
	return ref
end

function M.matches_source(source, native_source)
	return native_source.kind == "github"
		and type(native_source.owner) == "string"
		and type(native_source.repo) == "string"
		and source.owner == native_source.owner:lower()
		and source.repo == native_source.repo:lower()
		and source.subdir == native_source.subdir
end

return M
