local packages = require("lib.packages")

function PLUGIN:PackageUpgrade(ctx)
	packages.upgrade(ctx.packages, ctx.dry_run)
end
