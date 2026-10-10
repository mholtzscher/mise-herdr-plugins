local T = require("tests.test")
local source = require("lib.source")

T.case("source canonicalizes owner/repo but preserves nested subdirectory case", function()
	local parsed = source.parse_source("Owner/REPO/Plugins/My Plugin;$'\"/nested")
	T.eq(parsed.canonical, "owner/repo/Plugins/My Plugin;$'\"/nested")
	T.eq(parsed.subdir, "Plugins/My Plugin;$'\"/nested")
	T.eq(source.parse_source("Owner/REPO").subdir, nil)
end)

T.case("source rejects malformed shorthand and unsafe path components", function()
	local names = {
		"",
		"owner",
		"/repo",
		"owner/",
		"owner//repo",
		"./repo",
		"owner/..",
		"owner/repo/",
		"owner/repo//sub",
		"owner/repo/.",
		"owner/repo/../sub",
		"owner/repo/a\\b",
		"owner/repo/a\0b",
		"owner/repo/a\nb",
		"https://github.com/a/b",
		"git@github.com:a/b",
		"-o$/r",
		"o/r:x",
		"o/é",
	}
	for _, name in ipairs(names) do
		T.raises(function()
			source.parse_source(name)
		end, "invalid source")
	end
	T.raises(function()
		source.parse_source(false)
	end, "invalid source")
end)

T.case("opaque refs are neither normalized nor interpreted", function()
	for _, ref in ipairs({ "v1.2.3", "1.2.3", "refs/heads/main", "ref:foo", "tag with spaces;$(touch nope)'\"\\" }) do
		T.eq(source.validate_ref(ref), ref)
	end
	for _, ref in ipairs({ "", "-main", "x\0y", "x\ny", "x\127y", false, 42 }) do
		T.raises(function()
			source.validate_ref(ref)
		end, "invalid Git ref")
	end
end)

T.case("matching accepts GitHub case folding only, never local links", function()
	local parsed = source.parse_source("OWNER/repo/Sub")
	T.eq(source.matches_source(parsed, { kind = "github", owner = "Owner", repo = "REPO", subdir = "Sub" }), true)
	T.eq(source.matches_source(parsed, { kind = "github", owner = "Owner", repo = "Repo", subdir = "sub" }), false)
	T.eq(source.matches_source(parsed, { kind = "local", owner = "Owner", repo = "Repo", subdir = "Sub" }), false)
end)
