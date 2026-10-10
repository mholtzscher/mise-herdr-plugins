-- Run from the repository root with Lua 5.1 or LuaJIT; no native commands run.
package.path = "./?.lua;./?/init.lua;" .. package.path
local test = require("tests.test")
require("tests.source_spec")
require("tests.herdr_spec")
require("tests.packages_spec")
test.run()
