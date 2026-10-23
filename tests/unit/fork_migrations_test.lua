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

local function fake_comb(unit, op)
	local params = { operation = op }
	return {
		valid = true,
		unit_number = unit,
		get_or_create_control_behavior = function() return { parameters = params } end,
	}
end

local function fake_stop(nearby)
	local stop = { valid = true, position = { x = 10, y = 20 } }
	stop.surface = {
		find_entities_filtered = function(filter)
			stop.searched = filter
			return nearby
		end,
	}
	return stop
end

test("migrate_schema: inventory combinators end up keyed by unit number, mis-moded and invalid ones dropped", function()
	local fm = H.load("scripts.fork-migrations")
	local inv_a, inv_b = fake_comb(101, MODE_SECONDARY_INVENTORY), fake_comb(102, MODE_SECONDARY_INVENTORY)
	-- the Mini-Mall case: a combinator once registered as inventory, since switched to station control
	local control = fake_comb(103, MODE_SECONDARY_IO)
	local gone = fake_comb(104, MODE_SECONDARY_INVENTORY)
	gone.valid = false
	local stop = fake_stop({ inv_a, inv_b, control })
	storage.trains = {}
	storage.to_stop = { [101] = stop, [102] = stop, [103] = stop }
	storage.stations = { [1] = { entity_stop = stop, secondary_inv_combs = { inv_a, inv_b, control, gone } } }
	local counts = fm.rekey_secondary_inv_combs()
	local combs = storage.stations[1].secondary_inv_combs
	assert_eq(H.keys(combs), { 101, 102 })
	assert_true(combs[101] == inv_a and combs[102] == inv_b)
	assert_eq(counts, { rekeyed = 2, invalid = 1, wrong_mode = 1, added = 0 })
	assert_eq(stop.searched.name, COMBINATOR_NAME)
	assert_eq(stop.searched.area, { { 8, 18 }, { 12, 22 } }, "the build paths' search area")
end)

test("migrate_schema: an inventory combinator next to the stop but missing from the table joins it", function()
	local fm = H.load("scripts.fork-migrations")
	local listed, missing = fake_comb(201, MODE_SECONDARY_INVENTORY), fake_comb(202, MODE_SECONDARY_INVENTORY)
	-- inventory-mode, in reach, but owned by another stop
	local neighbours = fake_comb(203, MODE_SECONDARY_INVENTORY)
	local stop = fake_stop({ listed, missing, neighbours })
	storage.trains = {}
	storage.to_stop = { [201] = stop, [202] = stop, [203] = fake_stop({}) }
	storage.stations = { [1] = { entity_stop = stop, secondary_inv_combs = { [201] = listed } } }
	fm.migrate_schema()
	assert_eq(H.keys(storage.stations[1].secondary_inv_combs), { 201, 202 })
	assert_eq(storage.fork_schema, 7)
end)

test("migrate_schema: re-keying a second time changes nothing and logs nothing", function()
	local fm = H.load("scripts.fork-migrations")
	local inv = fake_comb(301, MODE_SECONDARY_INVENTORY)
	local stop = fake_stop({ inv })
	storage.trains = {}
	storage.to_stop = { [301] = stop }
	storage.stations = {
		[1] = { entity_stop = stop, secondary_inv_combs = { inv } },
		-- a station whose stop is gone keeps its valid entries and is not searched
		[2] = { entity_stop = { valid = false }, secondary_inv_combs = nil },
	}
	fm.rekey_secondary_inv_combs()
	local before = #H.logged
	local counts = fm.rekey_secondary_inv_combs()
	assert_eq(counts, { rekeyed = 0, invalid = 0, wrong_mode = 0, added = 0 })
	assert_eq(#H.logged, before)
	assert_eq(H.keys(storage.stations[1].secondary_inv_combs), { 301 })
	assert_eq(H.keys(storage.stations[2].secondary_inv_combs), {})
end)

test("adopt_replaced_storage: the replaced mod's storage becomes ours, deliveries in flight included", function()
	local fm = H.load("scripts.fork-migrations")
	local train = { status = 2, p_station_id = 7, manifest = { { name = "iron-plate", count = 4000 } } }
	storage._migrated = { cybersyn = { trains = { [11] = train }, fork_migrated = true } }
	assert_true(fm.adopt_replaced_storage())
	assert_nil(storage._migrated)
	assert_true(storage.trains[11] == train, "the same table, not a copy")
	assert_true(storage.fork_migrated)
end)

test("adopt_replaced_storage: a save that never had the replaced mod is left alone", function()
	local fm = H.load("scripts.fork-migrations")
	storage._migrated = nil
	assert_eq(fm.adopt_replaced_storage(), false)
	storage._migrated = { ["some-other-mod"] = {} }
	assert_eq(fm.adopt_replaced_storage(), false)
	assert_not_nil(storage._migrated["some-other-mod"])
	storage._migrated = nil
end)

test("previous_version: the replaced mod's version on the adopting load, ours afterwards", function()
	local fm = H.load("scripts.fork-migrations")
	local me = script.mod_name
	assert_eq(fm.previous_version({ mod_changes = {
		[me] = { new_version = "3.2.0" },
		cybersyn = { old_version = "2.1.2" },
	} }), "2.1.2")
	assert_eq(fm.previous_version({ mod_changes = { [me] = { old_version = "3.2.0", new_version = "3.2.1" } } }), "3.2.0")
	assert_nil(fm.previous_version({ mod_changes = { [me] = { new_version = "3.2.0" } } }), "a fresh install runs nothing")
	assert_nil(fm.previous_version({ mod_changes = { flib = { old_version = "0.17.1", new_version = "0.17.2" } } }),
		"another mod's change runs nothing")
end)
