-- Round 7 S3: the Stations tab and the stop panel by network section. A station built at runtime with a station
-- combinator on mask 1 (provides copper), Inventory 1 on mask 3 (provides iron) and Inventory 2 on mask 4 (requests
-- coal): its Network cell lists "1 · 3 · 4" with a "+2" badge, its strip has a labelled group per section, and its
-- stop panel one block per section. Every other station's panel renders its single block without an error.
--
-- Row k = 104 on cyb-bench with a network of its own, torn down at the end.

local DEV = "cybersyn-manager-dev"
local PI = 1
local K = 104
local NETWORK = "signal-0"
local MODE_INVENTORY = "AND"
local NAME = "r7-sections"

local function dev(fn, ...)
	return remote.call(DEV, fn, ...)
end

local function read(...)
	return (remote.call("cybersyn", "read_global", ...))
end

local function find_named(elem, name)
	if elem.name == name then return elem end
	for _, child in ipairs(elem.children) do
		local hit = find_named(child, name)
		if hit then return hit end
	end
	return nil
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

local function polled(id)
	local stops = read("stations", id, "stops")
	return stops ~= nil and table_size(stops) >= 2
end

--- Flattens a LocalisedString (or a tree of element views) into one searchable string.
local function flat(v)
	return serpent.line(v, { comment = false })
end

local steps = {
	function(ctx)
		local case = cases.base("SECTIONS", { k = K }, { network = NETWORK, no_train = true })
		ctx.case = case
		local st = cases.station(case, { name = NAME, x = cases.X_R[1],
			signals = { { NETWORK, 1, "virtual" }, { "copper-plate", 500 } } })
		ctx.st = st
		inventory(case, st, -0.5, { { NETWORK, 3, "virtual" }, { "iron-plate", 400 } })
		inventory(case, st, 0.5, { { NETWORK, 4, "virtual" }, { "coal", -300 } })
		cases.finish(case)
		lab.wait_until(function() return polled(st.id) end, 1800)
	end,
	function(ctx)
		local id = ctx.st.id
		lab.check("both inventory combinators are polled", polled(id), read("stations", id, "stops"))
		dev("close", PI)
		dev("clear_filters", PI)
		dev("open", PI)
		dev("select_tab", PI, "stations")
		dev("set_filter", PI, { query = NAME })
		dev("collect")
		dev("update", PI, 6)

		local list = find_named(game.get_player(PI).gui.screen.manager_window, "manager_stations_tab_scroll_pane")
		local row
		for _, r in ipairs(list and list.children or {}) do
			if r.tags.station_id == id then row = r end
		end
		lab.check("the station has a row", row ~= nil)
		if row then
			local net = row.children[3].children
			lab.check("Network cell lists every section's mask", net[2].caption == "1 · 3 · 4", net[2].caption)
			lab.check("Network cell badge counts the inventories", net[3] and net[3].visible and net[3].caption == "+2",
				net[3] and net[3].caption)
			lab.check("Network tooltip has a line per section", flat(row.children[3].tooltip):find("stations-net-sections", 1, true) ~= nil,
				row.children[3].tooltip)
			local strip = row.children[4].children[1].children
			local groups, items = {}, {}
			for _, e in ipairs(strip) do
				if e.type == "label" and e.tags.group then groups[#groups + 1] = e.tags.group end
				if e.type == "sprite-button" then items[#items + 1] = e.tags.id end
			end
			lab.check("strip: one labelled group per advertising section",
				lab.same_list(groups, { NETWORK .. ":1", NETWORK .. ":3", NETWORK .. ":4" }), groups)
			lab.check("strip: copper, iron, coal in section order", lab.same_list(items, { "copper-plate", "iron-plate", "coal" }), items)
		end

		dev("set_filter", PI, { query = false, network = NETWORK, mask = 4 })
		dev("collect")
		dev("update", PI, 6)
		local d = dev("dump", PI, "stations")
		local found = false
		for _, sid in ipairs(d.ids or {}) do
			if sid == id then found = true end
		end
		lab.check("the network filter on bit 3 finds the station by its Inventory 2", found, d.ids)
		dev("clear_filters", PI)

		dev("relative_open", PI, "stop", id)
		dev("update", PI, 2)
		local rd = dev("relative_dump", PI)
		local slots = flat(rd.sections and rd.sections.slots)
		lab.check("panel: Advertised heading", slots:find("section-advertised", 1, true) ~= nil, slots)
		lab.check("panel: Inventory 1's block shows its bits", slots:find("bits 1+2", 1, true) ~= nil)
		lab.check("panel: sources named", slots:find("source-inventory", 1, true) ~= nil and slots:find("source-station", 1, true) ~= nil)
		local head = flat(rd.sections and rd.sections.head)
		lab.check("panel: head lists the networks", head:find("relative-networks", 1, true) ~= nil, head)
		local before = rd.rebuilt and rd.rebuilt.slots
		dev("update", PI, 3)
		rd = dev("relative_dump", PI)
		lab.check("panel: no rebuild without a change", (rd.rebuilt and rd.rebuilt.slots) == before,
			{ before = before, after = rd.rebuilt and rd.rebuilt.slots })
		dev("relative_close", PI)

		-- Every other station: one block, no error.
		local ok, errors, n = 0, {}, 0
		for sid in pairs(read("stations") or {}) do
			if sid ~= id then
				n = n + 1
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
		end
		lab.check("panel renders for every plain station (" .. ok .. "/" .. n .. ")", ok == n and n > 0, errors)
		dev("close", PI)
		ctx.case.cleanup()
	end,
}

lab.suite("sections_view", steps)
