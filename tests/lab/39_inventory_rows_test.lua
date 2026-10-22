-- PLAN8 D8-1 / D8-3: the collector's inventory-row contract. A station built at runtime with a station combinator on
-- mask 1 (provides copper), Inventory 1 on mask 3 at priority 5 (provides iron), Inventory 2 on mask 4 (requests
-- coal) and Inventory 3 also on mask 4 (provides copper): four rows keyed `id@unit` in unit order, each with its own
-- lists, priority, network and mask; two inventories on one mask stay two rows; the station's totals are plain sums
-- and it counts once per item. The row-aware network filter finds the station by any row's bits. The round-7 views
-- still read the compat sections (wave 2 replaces them): every stop panel renders without an error.
--
-- Row k = 104 on cyb-bench with a network of its own, torn down at the end.

local DEV = "cybersyn-manager-dev"
local PI = 1
local K = 104
local NETWORK = "signal-0"
local MODE_INVENTORY = "AND"
local NAME = "r8-rows"

local function dev(fn, ...)
	return remote.call(DEV, fn, ...)
end

local function read(...)
	return (remote.call("cybersyn", "read_global", ...))
end

--- An inventory combinator beside the stop, wired to a constant combinator sending `signals`.
local function inventory(case, st, dx, signals)
	local s, force = case.surface, game.forces.player
	local x, y = st.stop.position.x, st.stop.position.y
	local comb = s.create_entity({ name = "cybersyn-combinator", position = { x + dx, y - 2.5 },
		direction = defines.direction.north, force = force })
	case.entities[#case.entities + 1] = comb
	local ctl = comb.get_or_create_control_behavior()
	local params = ctl.parameters
	params.operation = MODE_INVENTORY
	params.first_signal = { type = "virtual", name = NETWORK }
	params.second_constant = 0
	ctl.parameters = params
	script.raise_script_built({ entity = comb })
	local cc = s.create_entity({ name = "constant-combinator", position = { x + dx, y - 4.5 }, force = force })
	case.entities[#case.entities + 1] = cc
	cc.get_wire_connector(defines.wire_connector_id.circuit_red, true)
		.connect_to(comb.get_wire_connector(defines.wire_connector_id.combinator_input_red, true), false)
	cases.set_signals({ cc = cc }, signals)
	return comb
end

local function polled(id, n)
	local stops = read("stations", id, "stops")
	return stops ~= nil and table_size(stops) >= n
end

local function contains(list, v)
	for _, x in ipairs(list or {}) do
		if x == v then return true end
	end
	return false
end

--- Flattens a LocalisedString (or a tree of element views) into one searchable string.
local function flat(v)
	return serpent.line(v, { comment = false })
end

local steps = {
	function(ctx)
		local case = cases.base("ROWS", { k = K }, { network = NETWORK, no_train = true })
		ctx.case = case
		local st = cases.station(case, { name = NAME, x = cases.X_R[1],
			signals = { { NETWORK, 1, "virtual" }, { "copper-plate", 500 } } })
		ctx.st = st
		-- Built in this order, so unit numbers ascend with the inventory index.
		ctx.units = {
			inventory(case, st, -0.5, { { NETWORK, 3, "virtual" }, { "cybersyn-priority", 5, "virtual" }, { "iron-plate", 400 } })
				.unit_number,
			inventory(case, st, 0.5, { { NETWORK, 4, "virtual" }, { "coal", -300 } }).unit_number,
			inventory(case, st, -1.5, { { NETWORK, 4, "virtual" }, { "copper-plate", 200 } }).unit_number,
		}
		ctx.comb1 = st.comb.unit_number
		cases.finish(case)
		lab.wait_until(function() return polled(st.id, 3) end, 1800)
	end,
	function(ctx)
		local id = ctx.st.id
		lab.check("every inventory combinator is polled", polled(id, 3), read("stations", id, "stops"))
		dev("close", PI)
		dev("clear_filters", PI)
		dev("open", PI)
		dev("collect")

		local rows = dev("station_rows", id) or {}
		local keys = {}
		for i, r in ipairs(rows) do keys[i] = r.key end
		local u = ctx.units
		lab.check("one row per combinator, keys id@unit in unit order",
			lab.same_list(keys, { id .. "@" .. ctx.comb1, id .. "@" .. u[1], id .. "@" .. u[2], id .. "@" .. u[3] }), keys)
		local shape = {}
		for i, r in ipairs(rows) do
			shape[i] = { r.index, r.kind, r.priority, r.network_name, r.mask, r.read, r.ok }
		end
		lab.check("rows carry index, kind, own priority, network and mask", flat(shape) == flat({
			{ 0, "station", 0, NETWORK, 1, true, true },
			{ 1, "inventory", 5, NETWORK, 3, true, true },
			{ 2, "inventory", 0, NETWORK, 4, true, true },
			{ 3, "inventory", 0, NETWORK, 4, true, true },
		}), shape)
		local r = rows
		lab.check("rows carry their own lists",
			r[1] and r[1].provided["copper-plate"] == 500 and r[1].provided["iron-plate"] == nil
			and r[2] and r[2].provided["iron-plate"] == 400 and next(r[2].requested) == nil
			and r[3] and r[3].requested.coal and r[3].requested.coal.count == -300 and next(r[3].provided) == nil
			and r[4] and r[4].provided["copper-plate"] == 200, rows)
		lab.check("labels name the combinator", r[1] and flat(r[1].label):find("source-station", 1, true) ~= nil
			and r[4] and flat(r[4].label):find("source-inventory", 1, true) ~= nil, r[4] and r[4].label)

		-- D8-3: totals are plain sums; the station counts once per item.
		local copper = dev("item_oracle", "copper-plate")
		lab.check("copper: the station combinator and Inventory 3 are provider rows",
			contains(copper.provider_row_keys, id .. "@" .. ctx.comb1) and contains(copper.provider_row_keys, id .. "@" .. u[3]),
			copper.provider_row_keys)
		lab.check("copper: the station is one provider", contains(copper.providers, id), copper.providers)
		local mine = 0
		for _, k in ipairs(copper.provider_row_keys) do
			if k:find("^" .. id .. "@") then mine = mine + 1 end
		end
		lab.check("copper: exactly two of the rows are this station's", mine == 2, copper.provider_row_keys)
		local coal = dev("item_oracle", "coal")
		lab.check("coal: requested by Inventory 2's row only", contains(coal.requester_row_keys, id .. "@" .. u[2])
			and not contains(coal.requester_row_keys, id .. "@" .. ctx.comb1), coal.requester_row_keys)

		-- Every row of every station the snapshot holds, against the planner's own table.
		local summary = dev("summary")
		local expect, n = 0, 0
		for sid, station in pairs(read("stations") or {}) do
			local stop, comb1 = station.entity_stop, station.entity_comb1
			if stop and stop.valid and comb1 and comb1.valid then
				local seen = {}
				for _, sec in pairs(station.secondary_inv_combs or {}) do
					if sec and sec.valid then seen[sec.unit_number] = true end
				end
				expect = expect + 1 + table_size(seen)
				n = n + #(dev("station_rows", sid) or {})
			end
		end
		lab.check("summary.inventory_rows == Σ (1 + inventories) over the planner's stations (" .. expect .. ")",
			summary.inventory_rows == expect and n == expect, { summary = summary.inventory_rows, rows = n, expect = expect })

		-- The row-aware network filter: bit 3 comes from Inventories 2 and 3, bit 2 from Inventory 1's mask 3.
		dev("select_tab", PI, "stations")
		for _, case in ipairs({ { 4, true }, { 2, true }, { 1, true }, { 8, false } }) do
			dev("set_filter", PI, { network = NETWORK, mask = case[1] })
			dev("update", PI, 6)
			local d = dev("dump", PI, "stations")
			lab.check("network filter mask " .. case[1] .. (case[2] and " finds" or " skips") .. " the station",
				contains(d.ids, id) == case[2], d.ids)
		end
		-- Network and item must match on one row: coal is Inventory 2's (mask 4), bit 2 only Inventory 1's. A station-wide
		-- rule (the round-7 mask union) would find the station under mask 2 + coal too.
		for _, case in ipairs({ { 4, true }, { 2, false } }) do
			dev("set_filter", PI, { network = NETWORK, mask = case[1], item = "coal" })
			dev("update", PI, 6)
			local d = dev("dump", PI, "stations")
			lab.check("network mask " .. case[1] .. " + coal " .. (case[2] and "finds" or "skips") .. " the station",
				contains(d.ids, id) == case[2], d.ids)
		end
		dev("clear_filters", PI)

		-- The stop panel renders for every station.
		local ok, errors, total = 0, {}, 0
		for sid in pairs(read("stations") or {}) do
			total = total + 1
			local good, err = pcall(function()
				dev("relative_open", PI, "stop", sid)
				dev("update", PI, 1)
				local v = dev("relative_dump", PI)
				local s = flat(v.sections and v.sections.slots)
				if not (s:find("section-advertised", 1, true) or s:find("relative-no-items", 1, true)) then
					error("no blocks: " .. s:sub(1, 200))
				end
				dev("relative_close", PI)
			end)
			if good then ok = ok + 1 else errors[#errors + 1] = tostring(err) end
		end
		lab.check("panel renders for every station (" .. ok .. "/" .. total .. ")", ok == total and total > 0, errors)
		dev("close", PI)
		ctx.case.cleanup()
	end,
}

lab.suite("inventory_rows", steps)
