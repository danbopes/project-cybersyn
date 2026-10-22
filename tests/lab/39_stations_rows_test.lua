-- PLAN8 D8-1 / D8-2 / D8-3 / D8-4 in the Stations tab and the stop panel. A station built at runtime: the station
-- combinator on mask 1 provides copper; Inventory 1 (1 tile west) on mask 2 at priority 5 provides iron; Inventory 2
-- (2 tiles west, also on mask 2) requests coal nobody on its network provides, so its combinator shows the red I.
-- Stations: rows == Σ inventories over every station (and under each filter, the rows util.row_passes keeps), the
-- chips and the summary still count stations, a name sort keeps the station's three rows together in index order,
-- each row shows its own network, priority and slots, the inventory rows carry the combinator marker (an "entity"
-- link that opens the combinator), deliveries only on the station row. Stop panel: one Advertised block per
-- combinator with its letter (the red I on Inventory 2), "Networks" lists the distinct masks.
--
-- Row k = 114 on cyb-bench with a network of its own (one train), torn down at the end.

local DEV = "cybersyn-manager-dev"
local PI = 1
local K = 114
local NETWORK = "signal-cyan"
local MODE_INVENTORY = "AND"
local NAME = "r8-stations-rows"
local THRESHOLD = "cybersyn-request-threshold"

local function dev(fn, ...)
	return remote.call(DEV, fn, ...)
end

local function read(...)
	return (remote.call("cybersyn", "read_global", ...))
end

local function flat(v)
	return serpent.line(v, { comment = false })
end

--- An inventory combinator `dx` tiles west of the station combinator (in the stop's reach), wired to a constant
--- combinator sending `signals`. Not on the station combinator's tile (39_red_i places them the same way).
local function inventory(case, st, dx, signals)
	local s, force = case.surface, game.forces.player
	local x, y = st.comb.position.x - dx, st.comb.position.y
	local comb = s.create_entity({ name = "cybersyn-combinator", position = { x, y },
		direction = defines.direction.north, force = force })
	case.entities[#case.entities + 1] = comb
	local ctl = comb.get_or_create_control_behavior()
	local params = ctl.parameters
	params.operation = MODE_INVENTORY
	params.first_signal = { type = "virtual", name = NETWORK }
	params.second_constant = 0
	ctl.parameters = params
	script.raise_script_built({ entity = comb })
	local cc = s.create_entity({ name = "constant-combinator", position = { x, y - 2 }, force = force })
	case.entities[#case.entities + 1] = cc
	cc.get_wire_connector(defines.wire_connector_id.circuit_red, true)
		.connect_to(comb.get_wire_connector(defines.wire_connector_id.combinator_input_red, true), false)
	local rec = { comb = comb, cc = cc, unit = comb.unit_number }
	cases.set_signals(rec, signals)
	return rec
end

local function failed(ctx)
	local f = read("stations", ctx.st.id, "inv_failed")
	return f ~= nil and f[ctx.inv2.unit] == true
end

--- Rows of every snapshot station that `f` lets through, by util.row_passes' rules (network, mask, item, station),
--- from the dev row dump.
local function oracle_rows(f)
	local n = 0
	local band = bit32.band
	for sid in pairs(read("stations") or {}) do
		for _, r in ipairs(dev("station_rows", sid) or {}) do
			local pass = true
			if f.station and sid ~= f.station then pass = false end
			if pass and f.network then
				if r.networks then
					pass = r.networks[f.network] ~= nil and (f.mask == nil or band(r.networks[f.network], f.mask) ~= 0)
				else
					pass = r.network_name == f.network and r.mask ~= nil and (f.mask == nil or band(r.mask, f.mask) ~= 0)
				end
			end
			if pass and f.item then
				pass = r.provided[f.item] ~= nil or r.requested[f.item] ~= nil
				if not pass and r.index == 0 then
					local d = read("stations", sid, "deliveries")
					pass = d ~= nil and d[f.item] ~= nil
				end
			end
			if pass then n = n + 1 end
		end
	end
	return n
end

local function positions(d, keys)
	local out = {}
	for i, k in ipairs(d.row_keys or {}) do
		for j, want in ipairs(keys) do
			if k == want then out[j] = i end
		end
	end
	return out
end

local steps = {
	function(ctx)
		local case = cases.base("STATIONS_ROWS", { k = K }, { network = NETWORK })
		ctx.case = case
		-- Provides and requests (the default switch), so nothing is held back as "not advertised".
		ctx.st = cases.station(case, { name = NAME, x = cases.X_R[1],
			signals = { { NETWORK, 1, "virtual" }, { THRESHOLD, 100, "virtual" }, { "copper-plate", 500 } } })
		ctx.inv1 = inventory(case, ctx.st, 1, { { NETWORK, 2, "virtual" }, { "cybersyn-priority", 5, "virtual" },
			{ "iron-plate", 400 } })
		ctx.inv2 = inventory(case, ctx.st, 2, { { NETWORK, 2, "virtual" }, { "coal", -300 } })
		cases.finish(case)
		lab.wait_until(function() return cases.trains_ready(case) and failed(ctx) end, 3600)
	end,
	function(ctx)
		local id = ctx.st.id
		local combs = read("stations", id, "secondary_inv_combs") or {}
		lab.check("both inventory combinators are registered", combs[ctx.inv1.unit] ~= nil and combs[ctx.inv2.unit] ~= nil,
			combs)
		lab.check("Inventory 2's unserved coal request lights its red I", failed(ctx)
			and ctx.inv2.comb.get_or_create_control_behavior().parameters.operation == "OR",
			read("stations", id, "inv_failed"))
		dev("close", PI)
		dev("clear_filters", PI)
		dev("open", PI)
		lab.big_screen(PI)
		dev("collect")
		dev("select_tab", PI, "stations")
		dev("set_sort", PI, "stations", "name", true)
		dev("update", PI, 6)

		local rows = dev("station_rows", id) or {}
		ctx.keys = { id .. "@" .. ctx.st.comb.unit_number, id .. "@" .. ctx.inv1.unit, id .. "@" .. ctx.inv2.unit }
		lab.check("dev station_rows: Inventory 2's row is failed, the others are not",
			#rows == 3 and rows[1].failed == false and rows[2].failed == false and rows[3].failed == true, rows)

		local d = dev("dump", PI, "stations")
		local stations, expect = 0, 0
		for sid in pairs(read("stations") or {}) do
			local n = #(dev("station_rows", sid) or {})
			if n > 0 then
				stations = stations + 1
				expect = expect + n
			end
		end
		lab.check("Stations rows == Σ inventories over every station (" .. expect .. ")",
			d.total == expect and #d.row_keys == expect, { total = d.total, shown = #d.row_keys, expect = expect })
		lab.check("D8-3: the All chip and the summary count stations (" .. stations .. ")",
			d.counts.all == stations and d.stations_listed == stations, { all = d.counts.all, listed = d.stations_listed })
		lab.check("the summary adds the rows", flat(d.summary):find("stations-summary-rows", 1, true) ~= nil, d.summary)

		local at = positions(d, ctx.keys)
		lab.check("a name sort keeps the station's rows together in index order",
			at[1] ~= nil and at[2] == at[1] + 1 and at[3] == at[1] + 2, { at = at })
		local i1, i2, i3 = at[1] or 0, at[2] or 0, at[3] or 0
		lab.check("rows carry station_id and unit", d.ids[i1] == id and d.ids[i2] == id and d.ids[i3] == id
			and d.row_keys[i2] == ctx.keys[2], { d.ids[i1], d.row_keys[i2] })
		lab.check("each row shows its own network mask", d.networks[i1] and d.networks[i1][1] == "1"
			and d.networks[i2][1] == "2" and d.networks[i3][1] == "2"
			and d.networks[i1][2] == "virtual-signal/" .. NETWORK, { d.networks[i1], d.networks[i2], d.networks[i3] })
		lab.check("each row shows its own priority", d.priorities[i1] == "0" and d.priorities[i2] == "5"
			and d.priorities[i3] == "0", { d.priorities[i1], d.priorities[i2], d.priorities[i3] })
		lab.check("each row shows its own slots", flat(d.pr_items[i1]) == flat({ "copper-plate" })
			and flat(d.pr_items[i2]) == flat({ "iron-plate" }) and flat(d.pr_items[i3]) == flat({ "coal" }),
			{ d.pr_items[i1], d.pr_items[i2], d.pr_items[i3] })
		lab.check("deliveries sit on the station combinator's row only", #(d.dl_items[i2] or {}) == 0
			and #(d.dl_items[i3] or {}) == 0, { d.dl_items[i2], d.dl_items[i3] })
		local m1, m2, m3 = d.markers[i1], d.markers[i2], d.markers[i3]
		lab.check("D8-2: no marker on the station combinator's row", m1 == false, m1)
		lab.check("D8-2: an inventory row's marker is an entity link to its combinator", type(m2) == "table"
			and m2.kind == "entity" and m2.unit == ctx.inv1.unit and m2.sprite == "item/cybersyn-combinator"
			and type(m3) == "table" and m3.unit == ctx.inv2.unit, { m2, m3 })
		lab.check("D8-2: the marker's tooltip names the inventory, its priority and network",
			flat(m2 and m2.tooltip):find('"cybersyn-gui.stations-inventory-marker", "1", "5", {"cybersyn-gui.stations-inventory-network", "[virtual-signal=signal-cyan]", "2"}', 1, true) ~= nil,
			m2 and m2.tooltip)
		lab.check("the failed inventory's marker says so", flat(m3 and m3.tooltip):find("relative-i-red", 1, true) ~= nil
			and flat(m2 and m2.tooltip):find("relative-i-red", 1, true) == nil, m3 and m3.tooltip)
		lab.check("the marker's unit resolves to the combinator", read("to_comb", ctx.inv1.unit) == ctx.inv1.comb)

		-- The marker's click goes through util.handle_link_click's "entity" kind to util.open_entity.
		local click
		if type(m2) == "table" then
			local ok, res = pcall(dev, "click", PI, "manager_stations_tab_scroll_pane", { i2, 1, m2.index })
			click = { ok = ok, res = res, opened = game.get_player(PI).opened }
		end
		lab.check("clicking the marker raises no error", click ~= nil and click.ok, click)
		lab.info("marker click: player.opened = " .. tostring(click and click.opened and click.opened.object_name)
			.. " " .. tostring(click and click.opened and click.opened.valid and click.opened.name))

		-- Filters: rows are the ones util.row_passes keeps; the counts stay stations.
		for _, case in ipairs({
			{ "network mask 2", { network = NETWORK, mask = 2 }, { 2, 3 } },
			{ "network any mask", { network = NETWORK }, { 1, 2, 3 } },
			{ "item iron", { item = "iron-plate" }, { 2 } },
			{ "item coal", { item = "coal" }, { 3 } },
			{ "station chip", { station = id }, { 1, 2, 3 } },
		}) do
			dev("clear_filters", PI)
			local filter = case[2]
			dev("set_filter", PI, filter)
			dev("update", PI, 6)
			local fd = dev("dump", PI, "stations")
			local mine = {}
			for _, k in ipairs(fd.row_keys) do
				for j, want in ipairs(ctx.keys) do
					if k == want then mine[#mine + 1] = j end
				end
			end
			local expect_rows = oracle_rows({ network = filter.network, mask = filter.mask, item = filter.item,
				station = filter.station })
			lab.check(case[1] .. ": this station's rows " .. flat(case[3]), flat(mine) == flat(case[3]), mine)
			lab.check(case[1] .. ": rows == the rows the filter keeps (" .. expect_rows .. ")",
				fd.total == expect_rows, { total = fd.total, expect = expect_rows })
		end
		dev("clear_filters", PI)

		-- Sorts on the row's own values.
		dev("set_sort", PI, "stations", "priority", false)
		dev("update", PI, 6)
		local pd = dev("dump", PI, "stations")
		local pa = positions(pd, ctx.keys)
		lab.check("a priority sort puts Inventory 1 (priority 5) before its station's other rows",
			pa[2] ~= nil and pa[2] < pa[1] and pa[2] < pa[3], pa)
		dev("set_sort", PI, "stations", "network", true)
		dev("update", PI, 6)
		local nd = dev("dump", PI, "stations")
		local na = positions(nd, ctx.keys)
		lab.check("a network sort orders the rows by their own masks", na[1] ~= nil and na[1] < na[2] and na[2] < na[3], na)
		dev("set_sort", PI, "stations", "name", true)

		-- Stop panel: one block per combinator, the red I on Inventory 2.
		dev("relative_open", PI, "stop", id)
		dev("update", PI, 1)
		local v = dev("relative_dump", PI)
		local slots = flat(v.sections and v.sections.slots)
		local s0 = slots:find("S[/color] ", 1, true)
		-- A caption read back holds its parameters as strings.
		local b1 = slots:find('{"cybersyn-gui.source-inventory", "1"}', 1, true)
		local b2 = slots:find('{"cybersyn-gui.source-inventory", "2"}', 1, true)
		lab.check("stop panel: one Advertised block per combinator, in index order", s0 and b1 and b2 and s0 < b1 and b1 < b2,
			slots)
		lab.check("stop panel: Inventory 2's head shows the red I, Inventory 1's the cyan one",
			slots:find('[color=1,0.35,0.35]I[/color] ", {"", {"cybersyn-gui.source-inventory", "2"}', 1, true) ~= nil
			and slots:find('[color=0.4,0.9,1]I[/color] ", {"", {"cybersyn-gui.source-inventory", "1"}', 1, true) ~= nil)
		lab.check("stop panel: the network and mask follow each head", slots:find("[virtual-signal=signal-cyan]2", 1, true) ~= nil
			and slots:find("[virtual-signal=signal-cyan]1", 1, true) ~= nil)
		local head = flat(v.sections and v.sections.head)
		lab.check("stop panel: the Networks line lists the distinct masks",
			head:find("relative-networks", 1, true) ~= nil
			and head:find("[virtual-signal=signal-cyan]1 · [virtual-signal=signal-cyan]2", 1, true) ~= nil, head)
		dev("relative_close", PI)
		dev("close", PI)
		ctx.case.cleanup()
	end,
}

lab.suite("stations_rows", steps)
