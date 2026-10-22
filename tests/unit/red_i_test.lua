-- PLAN8 D8-4: an inventory combinator's red I. The planner records a failed request per stop: the station
-- combinator's stop lights the station's red S (display_state bit 2), an inventory's stop lights only that
-- combinator's red I (`station.inv_failed[unit]`, operation OR). Driven through the real `tick` (poll, then dispatch)
-- against fake combinators.

local H = require("harness")

package.loaded["scripts.analytics"].record_failed_dispatch = function() end

local function sig(name, count, type)
	return { signal = { name = name, type = type or "item" }, count = count }
end

--- A combinator whose inputs are `inputs.list` (copied on every read: the poll removes control signals in place).
local function comb(unit, op, inputs)
	local control = { parameters = { operation = op } }
	return {
		valid = true,
		unit_number = unit,
		status = defines.entity_status.working,
		get_signals = function()
			local out = {}
			for i, s in ipairs(inputs.list) do out[i] = { signal = s.signal, count = s.count } end
			return out
		end,
		get_or_create_control_behavior = function() return control end,
	}
end

local function op(c)
	return c.get_or_create_control_behavior().parameters.operation
end

--- One station on signal-A: the station combinator reads `own`, each inventory combinator `invs[unit]`.
local function station(id, own, invs, extra)
	local secs = {}
	for unit, inputs in pairs(invs or {}) do secs[unit] = comb(unit, MODE_SECONDARY_INVENTORY, inputs) end
	local st = {
		entity_stop = { valid = true, trains_limit = 5, unit_number = id },
		entity_comb1 = comb(id + 1, MODE_PRIMARY_IO, own),
		secondary_inv_combs = secs,
		is_r = true,
		is_p = true,
		network_name = "signal-A",
		network_mask = 1,
		deliveries = {},
		deliveries_total = 0,
		display_state = 0,
		last_delivery_tick = 0,
		request_start_ticks = {},
		accepted_layouts = {},
	}
	for k, v in pairs(extra or {}) do st[k] = v end
	return st
end

local function world(stations)
	local ids, by_id = {}, {}
	for _, st in ipairs(stations) do
		ids[#ids + 1] = st.entity_stop.unit_number
		by_id[st.entity_stop.unit_number] = st
	end
	return {
		tick_data = {},
		active_station_ids = ids,
		stations = by_id,
		economy = { all_r_stops = {}, all_p_stops = {}, all_names = {} },
		tick_state = STATE_POLL_STATIONS,
		total_ticks = 1,
		trains = {},
		each_refuelers = {},
		refuelers = {},
		to_comb = {},
		available_trains = {},
		layouts = {},
	}
end

local SETTINGS = {
	enable_planner = true, update_rate = 10, r_threshold = 1000, r_fluid_threshold = 0, priority = 0, locked_slots = 0,
	reserved_fluid_capacity = 0, network_mask = 1, tps = 60,
}

--- Polls every station and dispatches until the planner is back at its init state: one whole planner pass.
local function pass(map_data)
	map_data.tick_state = STATE_POLL_STATIONS
	map_data.tick_data = {}
	for _ = 1, 20 do
		tick(map_data, SETTINGS)
		if map_data.tick_state == STATE_INIT then return end
	end
	error("the planner did not finish a pass")
end

local NET = sig("signal-A", 1, "virtual")

test("is_secondary_inventory_op: AND and OR are one mode, nothing else is", function()
	assert_eq({ is_secondary_inventory_op("AND"), is_secondary_inventory_op("OR"), is_secondary_inventory_op("/"),
		is_secondary_inventory_op("^"), is_secondary_inventory_op(nil) }, { true, true, false, false, false })
	assert_eq(MODE_SECONDARY_INVENTORY_FAILED, "OR")
end)

test("no provider: only the inventory that requests goes red, the station combinator stays cyan", function()
	H.fresh()
	local inv = { list = { sig("iron-plate", -5000) } }
	local st = station(100, { list = { NET } }, { [201] = inv, [202] = { list = {} } })
	local map_data = world({ st })
	pass(map_data)
	assert_eq(st.inv_failed, { [201] = true })
	assert_eq({ op(st.secondary_inv_combs[201]), op(st.secondary_inv_combs[202]), op(st.entity_comb1), st.display_state },
		{ "OR", "AND", "/", 0 })

	-- Still unserved: unchanged. Then it stops requesting: cleared on the next poll, the I goes cyan.
	pass(map_data)
	assert_eq(op(st.secondary_inv_combs[201]), "OR")
	inv.list = {}
	pass(map_data)
	assert_nil(st.inv_failed, "an empty set is dropped")
	assert_eq(op(st.secondary_inv_combs[201]), "AND")
end)

test("the station combinator's own failure lights its S, not the inventory's I; each clears on its own requests", function()
	H.fresh()
	local own = { list = { NET, sig("copper-plate", -5000) } }
	local inv = { list = {} }
	local st = station(100, own, { [201] = inv })
	local map_data = world({ st })
	pass(map_data)
	assert_eq({ op(st.entity_comb1), st.inv_failed, op(st.secondary_inv_combs[201]) }, { "^", nil, "AND" })

	-- The station stops requesting while its inventory starts: the S goes out although the station still requests
	-- through the inventory, and the I lights.
	own.list = { NET }
	inv.list = { sig("iron-plate", -5000) }
	pass(map_data)
	assert_eq({ op(st.entity_comb1), st.display_state, st.inv_failed, op(st.secondary_inv_combs[201]) },
		{ "/", 0, { [201] = true }, "OR" })
end)

test("no requester can take a train: every listed inventory stop goes red, the station's own stop goes red", function()
	H.fresh()
	-- The requester is at its train limit (0), so the dispatcher finds no requester and marks every listed one.
	local req = station(100, { list = { NET, sig("iron-plate", -5000) } }, { [201] = { list = { sig("iron-plate", -5000) } } },
		{ is_p = false })
	req.entity_stop.trains_limit = 0
	local prov = station(300, { list = { NET, sig("iron-plate", 9000) } }, nil, { is_r = false })
	local map_data = world({ req, prov })
	pass(map_data)
	assert_eq({ req.inv_failed, op(req.secondary_inv_combs[201]), op(req.entity_comb1) }, { { [201] = true }, "OR", "^" })
	assert_eq({ prov.inv_failed, op(prov.entity_comb1) }, { nil, "/" })
end)

test("a station from an older save (no inv_failed) polls and fails like a new one", function()
	H.fresh()
	local st = station(100, { list = { NET } }, { [201] = { list = { sig("iron-plate", -5000) } } })
	st.inv_failed = nil
	local map_data = world({ st })
	pass(map_data)
	assert_eq(st.inv_failed, { [201] = true })
end)

test("update_inv_display: follows the bit, leaves a combinator in another mode and a missing one alone", function()
	H.fresh()
	local st = station(100, { list = {} }, { [201] = { list = {} }, [202] = { list = {} } })
	st.secondary_inv_combs[202].get_or_create_control_behavior().parameters.operation = MODE_SECONDARY_IO
	st.inv_failed = { [201] = true, [202] = true }
	update_inv_display({}, st, 201)
	update_inv_display({}, st, 202)
	update_inv_display({}, st, 999)
	assert_eq({ op(st.secondary_inv_combs[201]), op(st.secondary_inv_combs[202]) }, { "OR", "%" })
	st.inv_failed = nil
	update_inv_display({}, st, 201)
	assert_eq(op(st.secondary_inv_combs[201]), "AND")
end)
