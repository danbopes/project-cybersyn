-- PLAN8 D8-1 / D8-3 / D8-7 / D8-8 in the item drill-down and the Inventory grids, on a station built at runtime: the
-- station combinator on mask 1 provides copper, Inventory 1 on mask 2 at priority 5 provides copper too, Inventory 2
-- on mask 4 requests coal. The drill-down lists one row per inventory (id@unit) with the inventory named in a tag,
-- the station counted once in its totals; the station chip scopes the rows, the totals and the grids to the station,
-- with the network ID on top of it to one inventory; the empty texts say when filters hide rows.
--
-- Row k = 107 on cyb-bench with a network of its own, torn down at the end.

local DEV = "cybersyn-manager-dev"
local PI = 1
local K = 107
local NETWORK = "signal-cyan"
local NAME = "r8-item-rows"

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
	params.operation = "AND"
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

local function flat(v)
	return serpent.line(v, { comment = false })
end

local function sorted(list)
	local out = {}
	for i, v in ipairs(list or {}) do out[i] = v end
	table.sort(out)
	return out
end

local function mine(keys, id)
	local out = {}
	for _, k in ipairs(keys or {}) do
		if k:find("^" .. id .. "@") then out[#out + 1] = k end
	end
	table.sort(out)
	return out
end

--- The drill-down after enough updates to write every row.
local function drill()
	dev("collect")
	dev("update", PI, 12)
	return dev("item_dump", PI)
end

local steps = {
	function(ctx)
		local case = cases.base("ITEM_ROWS", { k = K }, { network = NETWORK, no_train = true })
		ctx.case = case
		local st = cases.station(case, { name = NAME, x = cases.X_R[1],
			signals = { { NETWORK, 1, "virtual" }, { "copper-plate", 500 } } })
		ctx.st = st
		-- Built in this order, so unit numbers ascend with the inventory index.
		ctx.units = {
			inventory(case, st, -0.5, { { NETWORK, 2, "virtual" }, { "cybersyn-priority", 5, "virtual" },
				{ "copper-plate", 200 } }).unit_number,
			inventory(case, st, -1.5, { { NETWORK, 4, "virtual" }, { "coal", -5000 } }).unit_number,
		}
		ctx.comb1 = st.comb.unit_number
		cases.finish(case)
		lab.wait_until(function() return polled(st.id, 2) end, 1800)
	end,
	function(ctx)
		local id, u = ctx.st.id, ctx.units
		local station_key, inv1, inv2 = id .. "@" .. ctx.comb1, id .. "@" .. u[1], id .. "@" .. u[2]
		lab.check("every inventory combinator is polled", polled(id, 2), read("stations", id, "stops"))
		dev("close", PI)
		dev("clear_filters", PI)
		dev("open", PI)
		lab.big_screen(PI)
		dev("collect")

		-- No filter: one row per inventory providing copper, the inventory named in the row's tag.
		dev("open_item", PI, "copper-plate")
		local d = drill()
		local o = dev("item_oracle", "copper-plate")
		local want = { station_key, inv1 }
		table.sort(want)
		lab.check("drill-down: the station's copper rows are its two providing inventories",
			flat(mine(d.row_keys.providers, id)) == flat(want), d.row_keys.providers)
		lab.check("drill-down: the provider rows are the oracle's inventory rows",
			flat(sorted(d.row_keys.providers)) == flat(o.provider_row_keys), { d.row_keys.providers, o.provider_row_keys })
		local tags = {}
		for i, r in ipairs(d.rendered.providers) do
			if d.row_keys.providers[i] == station_key or d.row_keys.providers[i] == inv1 then
				tags[d.row_keys.providers[i]] = r.tag
			end
		end
		lab.check("drill-down: Inventory 1's row is tagged with its inventory and network ID, the station row with its "
			.. "network ID only", flat(tags[inv1]):find("source-inventory", 1, true) ~= nil and flat(tags[inv1]):find("2", 1, true)
			~= nil and tags[station_key] ~= nil and flat(tags[station_key]):find("source", 1, true) == nil, tags)
		lab.check("drill-down totals without filters are inventory_all's (the station once)",
			d.totals.provided == (o.provided and o.provided.count or 0)
			and d.totals.provided_stations == (o.provided and o.provided.stations or 0), { d.totals, o.provided })

		-- The station chip: that station's rows, its sums, counted once (D8-3).
		dev("set_filter", PI, { station = id })
		d = drill()
		lab.check("chip: copper rows are the station's two inventories", flat(sorted(d.row_keys.providers)) == flat(want),
			d.row_keys.providers)
		lab.check("chip: provided 700 at one station, marked filtered", d.totals.provided == 700
			and d.totals.provided_stations == 1 and d.filtered == true, d.totals)
		lab.check("chip: no train to or from the station carries copper", #d.model.trains == 0, d.model.trains)
		lab.check("chip: the empty Trains table says filters hide rows (D8-8)", d.captions.trains.empty
			and d.captions.trains.empty_caption[1] == "cybersyn-gui.item-empty-trains-filtered", d.captions.trains)
		lab.check("chip: the drill-down's subheader shows the station chip", type(d.station_chip) == "table"
			and d.station_chip[3] == tostring(id), d.station_chip)

		-- The chip and a network ID: one inventory.
		dev("set_filter", PI, { mask = 2 })
		d = drill()
		lab.check("chip + mask 2: Inventory 1's row only, its 200", flat(d.row_keys.providers) == flat({ inv1 })
			and d.totals.provided == 200 and d.totals.provided_stations == 1, { d.row_keys.providers, d.totals })
		dev("set_filter", PI, { mask = 1 })
		d = drill()
		lab.check("chip + mask 1: the station combinator's row only, its 500", flat(d.row_keys.providers) == flat({ station_key })
			and d.totals.provided == 500, { d.row_keys.providers, d.totals })

		-- Coal: requested by Inventory 2 at its own priority; nobody on the chip provides it.
		dev("set_filter", PI, { mask = false })
		dev("open_item", PI, "coal")
		d = drill()
		lab.check("chip, coal: Inventory 2's request row only", flat(d.row_keys.requesters) == flat({ inv2 }),
			d.row_keys.requesters)
		lab.check("chip, coal: the empty Providers table says filters hide rows (D8-8)", d.captions.providers.empty
			and d.captions.providers.empty_caption[1] == "cybersyn-gui.item-empty-providers-filtered", d.captions.providers)

		-- Without any filter an empty table's text is the plain one.
		dev("clear_filters", PI)
		dev("open_item", PI, "coal")
		d = drill()
		local plain_ok, seen = true, 0
		for _, t in ipairs({ "providers", "requesters", "trains" }) do
			local c = d.captions[t]
			if c.empty then
				seen = seen + 1
				if c.empty_caption[1] ~= "cybersyn-gui.item-empty-" .. t then plain_ok = false end
			end
		end
		lab.check("no filter: every empty table's text is the plain one (" .. seen .. " empty)", plain_ok, d.captions)
		dev("close_item", PI)

		-- The Inventory grids under the chip: the station's sums, counted once; with mask 2 Inventory 1's alone.
		dev("set_filter", PI, { station = id })
		dev("select_tab", PI, "inventory")
		dev("set_sort", PI, "inventory", "amount", false)
		local function grid_amount(grid, hash)
			dev("update", PI, 3)
			local inv = dev("dump", PI, "inventory")
			for i, h in ipairs(inv[grid].hashes) do
				if h == hash then return inv[grid].keys[i], inv[grid].hashes end
			end
			return nil, inv[grid].hashes
		end
		local amount, hashes = grid_amount("provided", "copper-plate")
		lab.check("grids, chip: copper 700, the station's items only", amount == 700 and #hashes == 1, { amount, hashes })
		amount = grid_amount("requested", "coal")
		lab.check("grids, chip: coal requested 5000", amount == 5000, amount)
		dev("set_filter", PI, { mask = 2 })
		amount, hashes = grid_amount("provided", "copper-plate")
		lab.check("grids, chip + mask 2: Inventory 1's 200 alone", amount == 200, { amount, hashes })
		amount = grid_amount("requested", "coal")
		lab.check("grids, chip + mask 2: no coal request (it is on mask 4)", amount == nil, amount)
		dev("set_sort", PI, "inventory", "item_order", true)
		dev("clear_filters", PI)
		dev("close", PI)
		ctx.case.cleanup()
	end,
}

lab.suite("39_item_rows", steps)
