-- scripts/gui/dev.lua: the test interface exists only with the startup setting cybersyn-manager-dev-interface on.

local H = require("harness")

local SETTING = "cybersyn-manager-dev-interface"

local function register_with(value)
	remote.interfaces["cybersyn-manager-dev"] = nil
	settings.startup[SETTING] = value ~= nil and { value = value } or nil
	local dev = H.load("scripts.gui.dev")
	dev.register({}, {})
	local registered = remote.interfaces["cybersyn-manager-dev"] ~= nil
	settings.startup[SETTING] = nil
	remote.interfaces["cybersyn-manager-dev"] = nil
	return registered, dev
end

test("register: the interface follows the startup setting; a missing setting means off", function()
	assert_true((register_with(true)))
	assert_false((register_with(false)))
	assert_false((register_with(nil)))
end)

test("enabled: reads the startup setting", function()
	settings.startup[SETTING] = { value = true }
	local dev = H.load("scripts.gui.dev")
	assert_true(dev.enabled())
	settings.startup[SETTING] = { value = false }
	assert_false(dev.enabled())
	settings.startup[SETTING] = nil
end)
