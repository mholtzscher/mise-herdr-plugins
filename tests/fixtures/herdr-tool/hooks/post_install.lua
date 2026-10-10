local cmd = require("cmd")
function PLUGIN:PostInstall(ctx)
	cmd.exec('mkdir -p "$DEST/bin" && cp "$FAKE_HERDR_EXECUTABLE" "$DEST/bin/herdr" && chmod +x "$DEST/bin/herdr"', {
		env = { DEST = ctx.rootPath },
	})
end
