-- The storage conversions of scripts/fork-migrations.lua that only reshape fields.

local H = require("harness")

test("migrate_schema: the Stations chip ends up in stations_chip alone", function()
	local fm = H.load("scripts.fork-migrations")
	storage.trains = {}
	storage.manager = { fleet_networks = { minute = 1, set = {} }, players = {
		[1] = { stations_chip = "setup" },
		[2] = { stations_status_filter = "setup" },
		[3] = { stations_status_filter = "ok" },
		[4] = {},
	} }
	fm.migrate_schema()
	local p = storage.manager.players
	assert_eq(p[1].stations_chip, "problems", "an older build's Setup chip is the Problems chip")
	assert_eq(p[2].stations_chip, "setup", "the Setup status stays the status")
	assert_eq(p[3].stations_chip, "ok")
	assert_nil(p[4].stations_chip)
	for i = 1, 4 do assert_nil(p[i].stations_status_filter) end
	assert_nil(storage.manager.fleet_networks)
end)

test("migrate_schema: a later run (every configuration change) leaves a toggled Setup status alone", function()
	local fm = H.load("scripts.fork-migrations")
	storage.trains = {}
	storage.manager = { players = { [1] = { stations_status_filter = "setup" } } }
	fm.migrate_schema()
	assert_eq(storage.manager.players[1].stations_chip, "setup")
	fm.migrate_schema()
	assert_eq(storage.manager.players[1].stations_chip, "setup", "the one-time Problems mapping must not run again")
end)
