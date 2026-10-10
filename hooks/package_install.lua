local packages = require("lib.packages")

function PLUGIN:PackageInstall(ctx)
	packages.apply(ctx.packages, ctx.dry_run)
end
