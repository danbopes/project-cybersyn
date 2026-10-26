-- The collector re-implements the planner's split of combinator signals into provided, requested and ignored, so the
-- same combinators go through the real poll and the collector here and the network:item pairs each registers must
-- agree.

local H = require("harness")
local F = require("planner_fixtures")
local collector = require("scripts.gui.collector")
local sig, station, world = F.sig, F.station, F.world

local function poll(map_data)
	map_data.tick_state = STATE_POLL_STATIONS
	map_data.tick_data = {}
	for _ = 1, 20 do
		tick(map_data, F.SETTINGS)
		if map_data.tick_state ~= STATE_POLL_STATIONS then return end
	end
	error("the planner did not finish polling")
end

local function keys(t)
	local out = {}
	for k in pairs(t) do out[k] = true end
	return out
end

test("parity: a secondary's settings signals, locked slots included, are not networks", function()
	H.fresh()
	local each = station(100, { list = { sig("signal-A", 1, "virtual"), sig("coal", -5000), sig("stone", 3000) } }, {
		[201] = { list = {
			sig("signal-B", 1, "virtual"), sig(LOCKED_SLOTS, 2, "virtual"), sig(SIGNAL_PRIORITY, 3, "virtual"),
			sig(REQUEST_THRESHOLD, 50, "virtual"), sig("iron-plate", -400), sig("copper-plate", 4000), sig("sulfur", -10),
		} },
	}, { network_name = NETWORK_EACH, network_mask = {} })
	-- Not a requester: its negative signal is ignored, not requested.
	local prov = station(300, { list = { F.NET, sig("iron-plate", 9000), sig("coal", -5000) } }, nil, { is_r = false })
	each.entity_stop.backer_name, prov.entity_stop.backer_name = "Each", "Provider"
	local map_data = world({ each, prov })
	poll(map_data)

	mod_settings = F.SETTINGS
	storage.manager = { players = {} }
	collector.init()
	storage.stations, storage.trains, storage.depots = map_data.stations, {}, {}
	storage.tick_state = STATE_POLL_STATIONS
	collector.run_to_completion()
	local snap = collector.get()

	local requested = keys(map_data.economy.all_r_stops)
	assert_eq(requested, { ["signal-A:coal"] = true, ["signal-B:iron-plate"] = true })
	assert_eq(keys(snap.request_keys), requested)
	assert_eq(keys(snap.provider_masks), keys(map_data.economy.all_p_stops))
	assert_eq(snap.stations[300].ignored, { coal = -5000 })
end)
