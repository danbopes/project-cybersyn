-- Phase 8 per-item drill-down (PLAN3 §4.10): opened by a left-click on an item cell of the Inventory grid and of a
-- Stations slot (shift keeps the Stations jump, right clears the filter), back returns to the tab it came from, the
-- totals are the snapshot's inventory_all, the three tables list exactly the stations and trains that provide, request
-- or carry the item, sorted (providers by stock, requesters in the dispatcher's order, trains by amount), whole rows
-- on four emulated screens, Escape on a pinned window closes only the drill-down, dump twice identical.
-- The dispatcher-order case reuses cases.lua's LOST_PRIORITY scenario on row k = 70 with a network of its own: the
-- requester the dispatcher serves first (the entry's lost_to) is listed before the one that loses.

local DEV = "cybersyn-manager-dev"
local PI = 1
local K = 70
local SPEED = 50
local NETWORK = "signal-3"

local function dev(fn, ...)
	return remote.call(DEV, fn, ...)
end

local function read(...)
	return (remote.call("cybersyn", "read_global", ...))
end

local ix = {}
lab.item = ix

--- Index path from the element named `name` (anywhere under the window) to its first descendant `pred` accepts.
local function find_named(elem, name)
	if elem.name == name then return elem end
	for _, child in ipairs(elem.children) do
		local hit = find_named(child, name)
		if hit then return hit end
	end
	return nil
end

local function path_to(elem, pred, path)
	path = path or {}
	for i, child in ipairs(elem.children) do
		path[#path + 1] = i
		if pred(child) then return path end
		local hit = path_to(child, pred, path)
		if hit then return hit end
		path[#path] = nil
	end
	return nil
end

--- The child of the tab content that holds `elem` (what the drill-down hides and shows again).
local function top_child(elem, content_name)
	while elem and elem.parent and elem.parent.name ~= content_name do elem = elem.parent end
	return elem
end

local function window()
	return game.get_player(PI).gui.screen.manager_window
end

local function ids_of(rows)
	local out = {}
	for i, r in ipairs(rows) do out[i] = type(r) == "table" and r.id or r end
	return out
end

local function sorted(list)
	local out = {}
	for i, v in ipairs(list) do out[i] = v end
	table.sort(out)
	return out
end

--- The checks that hold for any open drill-down: totals, row sets, sort orders, rendered rows, whole rows.
local function model_checks(label, hash)
	dev("collect")
	-- A pass that re-sorts the lists spreads its row rewrites over a few updates (REWRITE_ROWS per update).
	dev("update", PI, 4)
	local d = dev("item_dump", PI)
	lab.check(label .. ": no row rewrite left for a later update", d.deferred == 0, d.deferred)
	local o = dev("item_oracle", hash)
	lab.check(label .. ": open on " .. hash, d.open and d.hash == hash, { d.open, d.hash })
	if not d.open then return d end
	local t = d.totals
	lab.check(label .. ": totals == inventory_all", t.provided == (o.provided and o.provided.count or 0) and
		t.provided_stations == (o.provided and o.provided.stations or 0) and
		t.requested == (o.requested and -o.requested.count or 0) and
		t.in_transit == (o.in_transit and o.in_transit.count or 0), { t, o.provided, o.requested, o.in_transit })
	lab.check(label .. ": provider rows == stations providing it", lab.same_list(sorted(ids_of(d.model.providers)), o.providers),
		{ ids_of(d.model.providers), o.providers })
	lab.check(label .. ": requester rows == stations requesting it",
		lab.same_list(sorted(ids_of(d.model.requesters)), o.requesters), { ids_of(d.model.requesters), o.requesters })
	lab.check(label .. ": train rows == trains carrying it", lab.same_list(sorted(ids_of(d.model.trains)), o.trains),
		{ ids_of(d.model.trains), o.trains })

	-- Providers by stock (descending), from Cybersyn's own numbers through the rendered captions' order.
	local stations = read("stations")
	local ok_order = true
	local prev
	for _, r in ipairs(d.model.requesters) do
		local st = stations[r.id]
		if st and r.group == 0 then
			local prior = st.priority or 0
			if st.item_thresholds and st.item_thresholds[hash] and st.item_priority then prior = st.item_priority end
			if prior ~= r.priority or (st.last_delivery_tick or 0) ~= r.last_served then ok_order = false end
			if prev and (prev.priority < r.priority or (prev.priority == r.priority and prev.last_served > r.last_served)) then
				ok_order = false
			end
			prev = r
		end
	end
	lab.check(label .. ": queued requesters in the dispatcher's order (priority desc, last delivery asc), from Cybersyn's own priority and last_delivery_tick",
		ok_order, d.model.requesters)
	local groups_ok = true
	for i = 2, #d.model.requesters do
		if d.model.requesters[i].group < d.model.requesters[i - 1].group then groups_ok = false end
	end
	lab.check(label .. ": skipped requests after the queue", groups_ok, d.model.requesters)

	-- Rendered rows: the first rows of each list, at most its share; the shares add up to the layout's rows.
	local a = d.alloc
	lab.check(label .. ": the three shares add up to the layout's rows", a and a.providers + a.requesters + a.trains == d.total_rows,
		{ a, d.total_rows })
	for _, tname in ipairs({ "providers", "requesters", "trains" }) do
		local want = math.min(#d.model[tname], a[tname])
		local rendered = d.rendered[tname]
		local same = #rendered == want
		for i = 1, want do
			local id = ids_of(d.model[tname])[i]
			if not rendered[i] or rendered[i].id ~= id then same = false end
		end
		lab.check(label .. ": " .. tname .. " shows its first " .. want .. " rows in model order", same,
			{ want = want, rendered = #rendered })
		local cap = d.captions[tname]
		lab.check(label .. ": " .. tname .. " caption counts n of m", cap.count and cap.count[2] == tostring(want) and
			cap.count[3] == tostring(#d.model[tname]), cap.count)
		lab.check(label .. ": " .. tname .. " empty state exactly when the list is empty", cap.empty == (#d.model[tname] == 0), cap)
	end
	local rows = dev("rows", PI, "item")
	lab.check(label .. ": rows computed == the layout's item rows, rendered <= computed",
		rows.computed == d.total_rows and rows.rendered <= rows.computed, rows)
	return d
end

lab.suite("39_item", {
	function()
		dev("close", PI)
		dev("clear_filters", PI)
		dev("open", PI)
		lab.big_screen(PI)
		dev("select_tab", PI, "inventory")
		local inv = dev("dump", PI, "inventory")
		ix.hash = inv.provided.hashes[1]
		lab.check("an item to drill into", ix.hash ~= nil, inv.provided)

		-- Left-click on an Inventory slot: the drill-down, from the Inventory, no filter set.
		local res = dev("click", PI, "inventory_provided_table", 1)
		local d = dev("item_dump", PI)
		lab.check("Inventory slot click is handled by the shared link handler", res == true, res)
		lab.check("left-click on an Inventory slot opens the drill-down from the Inventory",
			d.open and d.hash == ix.hash and d.from_tab == "inventory_tab" and d.selected_tab == "inventory_tab", d)
		lab.check("the item filter is not set by the drill-down", dev("state", PI).filters.item == nil)
		lab.check("the drill-down replaces the Inventory's content", (function()
			local w = window()
			local grids = find_named(w, "inventory_provided_table")
			local view = find_named(w, "item_view")
			return view and view.visible and grids and not top_child(grids, "manager_inventory_content_frame").visible
		end)())
		lab.check("the subheader has the back button, icon and name", d.header.back == true and d.header.icon ~= nil and
			d.header.name ~= nil, d.header)
		lab.check("the Requesters caption says dispatcher order, approximate, with a tooltip",
			d.captions.requesters.caption[1] == "cybersyn-gui.item-requesters" and
			d.captions.requesters.tooltip[1] == "cybersyn-gui.item-requesters-tooltip")
		model_checks("inventory", ix.hash)
		ix.first = dev("item_dump", PI)

		-- 'Delivered' in the drill-down is the figure of the Inventory slot's tooltip (one per-minute cache).
		local function find_key(ls, key)
			if type(ls) ~= "table" then return nil end
			if ls[1] == key then return ls end
			for i = 2, #ls do
				local hit = find_key(ls[i], key)
				if hit then return hit end
			end
			return nil
		end
		local grid = find_named(window(), "inventory_provided_table")
		local slot = grid and grid.children[1]
		local line = slot and find_key(slot.tooltip, "cybersyn-gui.inventory-delivered-hour")
		local shown = line and string.gsub(tostring(line[2]), "%D", "")
		if ix.first.period == 60 then
			lab.check("drill-down Delivered == the Inventory slot tooltip's Delivered · last hour",
				shown ~= nil and shown == tostring(ix.first.delivered), { shown, ix.first.delivered })
		else
			lab.skip("drill-down Delivered == Inventory tooltip", "Overview period is not one hour")
		end

		-- Number cells right-aligned (the value style), chips the cybersyn_chip styles.
		local styles_ok = true
		for _, tname in ipairs({ "providers", "requesters", "trains" }) do
			for _, row in ipairs(ix.first.rendered[tname]) do
				for _, s in pairs(row.styles or {}) do
					if s ~= "cybersyn_unserved_value" and s ~= "cybersyn_unserved_cell" then styles_ok = false end
				end
				if row.chip_style and not row.chip_style:find("^cybersyn_chip_") then styles_ok = false end
			end
		end
		lab.check("numbers in the right-aligned value style, chips in the chip styles", styles_ok)

		-- Back returns to the Inventory and shows its content again.
		dev("close_item", PI)
		d = dev("item_dump", PI)
		lab.check("back closes the drill-down and returns to the Inventory", not d.open and dev("state", PI).selected_tab == "inventory_tab")
		lab.check("the Inventory's grids are shown again", (function()
			local grids = find_named(window(), "inventory_provided_table")
			return grids and top_child(grids, "manager_inventory_content_frame").visible and find_named(window(), "item_view") == nil
		end)())

		-- Shift keeps the Stations jump; right clears the filter.
		dev("click", PI, "inventory_provided_table", 1, { shift = true })
		local st = dev("state", PI)
		lab.check("shift-click on an Inventory slot jumps to Stations filtered to the item",
			st.selected_tab == "stations_tab" and st.filters.item == ix.hash and not dev("item_dump", PI).open, st)
		dev("select_tab", PI, "inventory")
		dev("click", PI, "inventory_provided_table", 1, { right = true })
		lab.check("right-click on an Inventory slot clears the item filter", dev("state", PI).filters.item == nil)
	end,

	function()
		-- A Stations slot: the same handler and semantics.
		dev("select_tab", PI, "stations")
		local scroll = find_named(window(), "manager_stations_tab_scroll_pane")
		local path = scroll and path_to(scroll, function(e)
			return e.type == "sprite-button" and e.tags and (e.tags.item_hash or (e.tags.kind == "item" and e.tags.id)) ~= nil
		end)
		lab.check("a Stations row has an item slot", path ~= nil)
		if not path then return end
		local slot = scroll
		for _, i in ipairs(path) do slot = slot.children[i] end
		local hash = slot.tags.item_hash or slot.tags.id
		dev("click", PI, "manager_stations_tab_scroll_pane", path)
		local d = dev("item_dump", PI)
		lab.check("left-click on a Stations slot opens the drill-down from Stations",
			d.open and d.hash == hash and d.from_tab == "stations_tab" and d.selected_tab == "stations_tab", d)
		model_checks("stations slot", hash)
		-- An item cell inside the open drill-down's subheader: shift jumps to Stations filtered.
		dev("close_item", PI)
		lab.check("back returns to Stations", dev("state", PI).selected_tab == "stations_tab" and not dev("item_dump", PI).open)
		lab.check("the Stations rows are shown again", scroll.valid and scroll.visible and
			top_child(scroll, "manager_stations_content_frame").visible)

		-- Selecting another tab leaves the drill-down.
		local od0 = dev("open_item", PI, hash)
		lab.check("on the pinned window the drill-down holds player.opened (Escape reaches it)", od0.took_opened == true, od0)
		dev("select_tab", PI, "trains")
		lab.check("selecting another tab closes the drill-down", not dev("item_dump", PI).open and
			find_named(window(), "item_view") == nil)
		lab.check("and the tab selected stays selected (releasing player.opened does not re-select the old tab)",
			dev("state", PI).selected_tab == "trains_tab", dev("state", PI).selected_tab)
		dev("select_tab", PI, "stations")
		lab.check("and the host tab's content is back", scroll.valid and scroll.visible and
			top_child(scroll, "manager_stations_content_frame").visible)

		-- A Trains shipment slot: the same handler.
		dev("select_tab", PI, "trains")
		local trains = find_named(window(), "manager_trains_tab_scroll_pane")
		local tpath = trains and path_to(trains, function(e)
			return e.type == "sprite-button" and e.tags and e.tags.kind == "item" and e.tags.id ~= nil
		end)
		if tpath then
			local tslot = trains
			for _, i in ipairs(tpath) do tslot = tslot.children[i] end
			dev("click", PI, "manager_trains_tab_scroll_pane", tpath)
			local td = dev("item_dump", PI)
			lab.check("left-click on a Trains shipment slot opens the drill-down from Trains", td.open and
				td.hash == tslot.tags.id and td.from_tab == "trains_tab", td.from_tab)
			dev("close_item", PI)
			lab.check("back returns to Trains", dev("state", PI).selected_tab == "trains_tab" and trains.visible)
		else
			lab.skip("Trains shipment slot click", "no train carries cargo on this page")
		end
		dev("select_tab", PI, "stations")

		-- Ctrl+F and a search set from outside (the stop panel's Open in manager) show the lists again.
		dev("open_item", PI, hash)
		local sf = dev("search_input", PI)
		lab.check("Ctrl+F closes the drill-down and opens the visible search field", not dev("item_dump", PI).open and
			sf.open and sf.visible, sf)
		dev("cancel_search", PI)
		dev("open_item", PI, hash)
		dev("set_filter", PI, { query = "stn-1" })
		lab.check("a station search set from outside closes the drill-down", not dev("item_dump", PI).open)
		dev("clear_filters", PI)

		-- An item cell outside the window (the stop and train panels): the window opens on the drill-down.
		dev("close", PI)
		local outside = dev("link_click", PI, "item", hash)
		local od = dev("item_dump", PI)
		lab.check("an item link with the window closed opens the window on the drill-down",
			dev("state", PI).is_open and od.open and od.hash == hash, { outside, od.open })
		dev("close_item", PI)
		dev("select_tab", PI, "stations")

		-- Escape: on a pinned window it closes only the drill-down.
		dev("open_item", PI, hash)
		local e = dev("item_escape", PI)
		lab.check("Escape on the pinned window waits for a later tick (another GUI may have replaced the window)",
			e.before and e.open and e.manager_open, e)
		dev("pane_escapes", PI, true)
		lab.check("then closes the drill-down, the window stays", not dev("item_dump", PI).open and dev("state", PI).is_open)
		-- Unpinned: one rule for every overlay since phase 7 (manager.top_overlay): Escape closes the drill-down and
		-- the window stays, as it does for the Trains pane; the next Escape closes the window. (Phase 8 closed the
		-- window with the drill-down here.)
		dev("click", PI, "manager_pin_button")
		dev("open_item", PI, hash)
		e = dev("item_escape", PI)
		lab.check("Escape on an unpinned window closes the drill-down, the window stays", e.before and not e.open and
			e.manager_open, e)
		dev("pane_escapes", PI, true)
		e = dev("item_escape", PI)
		lab.check("the next Escape on the unpinned window closes the window", not e.before and not e.manager_open, e)
		dev("open", PI)
		lab.big_screen(PI)
	end,

	function()
		-- Dispatcher order against the dispatcher's own choice: the LOST_PRIORITY scenario on a network of its own.
		local saved = cases.NETWORKS.LOST_PRIORITY
		cases.NETWORKS.LOST_PRIORITY = NETWORK
		local ok, case = pcall(cases.LOST_PRIORITY, { k = K })
		cases.NETWORKS.LOST_PRIORITY = saved
		lab.check("LOST_PRIORITY scenario builds", ok, case)
		if not ok then return end
		ix.case = case
		lab.wait_until(function() return cases.trains_ready(case) end, 3600, SPEED)
	end,

	function()
		local case = ix.case
		if not case then return end
		lab.check("LOST_PRIORITY train parked", cases.trains_ready(case))
		case.stages[1].run(case)
		lab.wait_until(function()
			local e = dev("diag_unserved", case.r_station)[case.item]
			return e ~= nil and e.lost_n > 0
		end, 4800, SPEED)
	end,

	function()
		local case = ix.case
		if not case then return end
		local e = dev("diag_unserved", case.r_station)[case.item]
		lab.check("the dispatcher served hi first: lo lost to hi", e and e.lost_n > 0 and e.lost_to == case.hi.id, e)
		dev("clear_filters", PI)
		dev("select_tab", PI, "inventory")
		local d = dev("open_item", PI, case.item)
		d = model_checks("LOST_PRIORITY", case.item)
		local pos = {}
		for i, r in ipairs(d.model.requesters) do pos[r.id] = i end
		lab.check("the winner (lost_to) is listed before the requester that lost to it",
			pos[case.hi.id] ~= nil and pos[case.r_station] ~= nil and pos[case.hi.id] < pos[case.r_station],
			{ hi = pos[case.hi.id], lo = pos[case.r_station] })
		-- hi is first overall unless another requester of the item has a priority of 10 or more.
		local top = true
		for _, r in ipairs(d.model.requesters) do
			if r.id ~= case.hi.id and r.group == 0 and r.priority >= 10 then top = false end
		end
		if top then
			lab.check("the winner heads the Requesters table", d.model.requesters[1].id == case.hi.id and
				d.rendered.requesters[1] and d.rendered.requesters[1].id == case.hi.id, d.model.requesters[1])
		end
		local lo_row
		for _, r in ipairs(d.rendered.requesters) do if r.id == case.r_station then lo_row = r end end
		lab.check("the loser's row carries its reason chip with the four-line tooltip", lo_row and lo_row.chip_tooltip and
			lo_row.chip_tooltip[1] == "" and #lo_row.chip_tooltip >= 8, lo_row)
		local lost_line = lo_row and lo_row.chip_tooltip and lo_row.chip_tooltip[10]
		lab.check("the loser's chip names the winner it lost to, with the count",
			type(lost_line) == "table" and lost_line[1] == "cybersyn-diag.lost-priority" and type(lost_line[2]) == "string" and
			(tonumber(lost_line[3]) or 0) > 0,
			lost_line)

		-- Dump twice, two seconds apart: the same rows in the same order.
		ix.dump1 = d
		lab.wait(120, 1)
	end,

	function()
		local d1 = ix.dump1
		if not d1 then return end
		dev("update", PI, 1)
		local d2 = dev("item_dump", PI)
		local function keys(d)
			local out = {}
			for _, tname in ipairs({ "providers", "requesters", "trains" }) do out[tname] = ids_of(d.rendered[tname]) end
			return out
		end
		lab.check("dump twice 2 s apart: same rows in the same order", serpent.line(keys(d1)) == serpent.line(keys(d2)),
			{ keys(d1), keys(d2) })

		-- Whole rows on four screens: the shares add up to the rows the layout computed for the drill-down.
		for _, screen in ipairs({ { 1920, 1080, 1 }, { 2560, 1440, 1.25 }, { 3840, 2160, 1.5 }, { 3840, 2160, 2 },
			{ 1366, 768, 1.5 }, { 1920, 1080, 2 } }) do
			local rows = dev("set_layout", PI, screen[1], screen[2], screen[3])
			dev("update", PI, 1)
			local d = dev("item_dump", PI)
			local r = dev("rows", PI, "item")
			local a = d.alloc
			local label = screen[1] .. "x" .. screen[2] .. "@" .. screen[3]
			lab.check(label .. ": shares add up to the computed rows, rendered within them",
				a and a.providers + a.requesters + a.trains == r.computed and r.rendered <= r.computed and
				r.computed >= 3 and 256 + r.computed * 32 <= r.content_height and 256 + (r.computed + 1) * 32 > r.content_height,
				{ a, r.computed, r.rendered, r.content_height, rows.computed })
		end
		lab.big_screen(PI)

		dev("close_item", PI)
		if ix.case then cases.destroy(ix.case) end
		ix.case = nil
		dev("clear_filters", PI)
	end,
})
