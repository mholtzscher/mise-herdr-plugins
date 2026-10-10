local packages = require("lib.packages")

function PLUGIN:PackageInstalled(ctx)
	return { packages = packages.installed(ctx.packages) }
end
