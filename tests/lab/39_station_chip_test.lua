-- PLAN8 D8-7: the station chip. Set by the stop panel's Open in manager and its item slots; honoured by Stations,
-- Trains and Log (row sets equal an oracle over the snapshot and the diag rings), ignored by the Overview (same model
-- with and without it, and its chip tooltip says so); cleared by its ×, the clear-all button and the filter-row
-- toggle; kept across close and reopen; a stop named "R" is focused by id, not by a text search that also matches
-- "R2".

local D, PI = lab.D, lab.pi
local DT = "cybersyn-manager-dev-trains"

local function dev(fn, ...)
	return remote.call(D, fn, ...)
end

local function snapshot()
	return lab.read("manager").snapshot
end

local function sorted(list)
	local out = {}
	for i, v in ipairs(list) do out[i] = v end
	table.sort(out)
	return out
end

local function stations_ids()
	dev("select_tab", PI, "stations")
	return sorted(dev("dump", PI, "stations").ids)
end

local function trains_ids()
	dev("select_tab", PI, "trains")
	return sorted(dev("dump", PI, "trains").ids)
end

--- Trains of the snapshot on a delivery to or from `id` (and carrying `hash` when given), by train id.
local function trains_oracle(id, hash)
	local out = {}
	for tid, tr in pairs(snapshot().trains) do
		if (tr.p_station_id == id or tr.r_station_id == id) and (not hash or tr.manifest_hashes[hash]) then
			out[#out + 1] = tid
		end
	end
	table.sort(out)
	return out
end

local function filters()
	return dev("state", PI).filters
end

-- Log kinds whose station2 column names a station (diag.STATION2_IS_STATION).
local STATION2 = { unserved_reason = true, served = true, flapping = true, dispatch_failed = true,
	delivery_failed = true, alert = true, short_load = true, unexpected_cargo = true, residual_cargo = true,
	dispatched = true, arrive_p = true, leave_p = true, arrive_r = true, leave_r = true, slow_delivery = true }

local function names_station(g, id)
	return g.station == id or (STATION2[g.kind] and g.station2 == id)
end

local function log_render()
	local d
	for _ = 1, 60 do
		dev("update", PI, 1)
		d = dev("log_dump", PI)
		local filling = d.display and d.shown < #d.display
		if not (d.counting or filling or d.complete == false) then break end
	end
	return d
end

local function overview_model()
	dev("select_tab", PI, "overview")
	local d = dev("dump", PI, "overview")
	return serpent.line({ d.lists, d.tiles })
end

lab.suite("39_station_chip", {
	-- A requester with a delivery inbound (the save's stuck signal-A dispatches), so Stations, Trains, the in-flight
	-- slot and the advertised slots all have something to show.
	function(ctx)
		ctx.planner = settings.global["cybersyn-enable-planner"].value
		-- Frozen: no dispatch may move a train between the oracle and the dump.
		dev("set_setting", "cybersyn-enable-planner", false)
		lab.big_screen(PI)
		dev("close", PI)
		dev("clear_filters", PI)
		dev("open", PI)
		dev("collect")
		local snap = snapshot()
		for _, tr in pairs(snap.trains) do
			local st = tr.r_station_id and snap.stations[tr.r_station_id]
			if st and next(st.deliveries) and next(st.requested) and (not ctx.s or tr.r_station_id < ctx.s) then
				ctx.s = tr.r_station_id
			end
		end
		lab.check("the save has a requester with a delivery inbound", ctx.s ~= nil)
		if not ctx.s then return end
		for id in pairs(snap.stations) do
			if id ~= ctx.s and not ctx.other then ctx.other = id end
		end
		ctx.name = lab.read("stations", ctx.s).entity_stop.backer_name
	end,

	-- Honoured by Stations, Trains, Log; ignored by the Overview; the chip on every tab with the right tooltip.
	function(ctx)
		if not ctx.s then return end
		local s = ctx.s
		-- The chip opens the filter row, which takes rows from the layout: the baseline is taken with the row open.
		dev("click", PI, "manager_filter_button")
		local overview_before = overview_model()
		local all_trains = trains_ids()
		local f = dev("set_filter", PI, { station = s })
		lab.check("set_filter station: f.station is the id, the row opens", f.station == s and
			dev("header", PI).filter_row == true, f)
		lab.check("Stations: exactly the chip's station", serpent.line(stations_ids()) == serpent.line({ s }),
			stations_ids())
		local want = trains_oracle(s)
		local got = trains_ids()
		lab.check("Trains: exactly the trains delivering to or from it (" .. #want .. " of " .. #all_trains .. ")",
			#want > 0 and serpent.line(got) == serpent.line(want), { got = got, want = want })
		lab.check("Overview: the same model with the chip as without it", overview_model() == overview_before)

		-- Inventory: the grids hold exactly the chip station's provided and active requested amounts. A station with
		-- secondaries or sections is placed by a filter of its own, which must carry the chip too.
		local st = snapshot().stations[s]
		local oracle = { provided = {}, requested = {} }
		for hash, count in pairs(st.provided) do oracle.provided[hash] = math.abs(count) end
		for hash, req in pairs(st.requested) do
			if req.active then oracle.requested[hash] = math.abs(req.count) end
		end
		dev("select_tab", PI, "inventory")
		local sort = dev("dump", PI, "inventory").provided.column
		dev("set_sort", PI, "inventory", "amount", true)
		local d = dev("dump", PI, "inventory")
		for _, grid in ipairs({ "provided", "requested" }) do
			local got, ok, n_want = {}, true, lab.count(oracle[grid])
			for i, hash in ipairs(d[grid].hashes) do
				got[hash] = d[grid].keys[i]
				if oracle[grid][hash] ~= d[grid].keys[i] then ok = false end
			end
			lab.check("Inventory " .. grid .. ": exactly the chip station's amounts (" .. n_want .. " items)",
				ok and #d[grid].hashes == n_want, { got = got, want = oracle[grid] })
		end
		dev("set_sort", PI, "inventory", sort, true)

		local chips = dev("chips", PI)
		local caption_ok, tooltip_ok = true, true
		for tab, c in pairs(chips) do
			-- A tab that is not built (Breakdown without analytics) has no chip to show.
			if c.exists and not (c.station and c.caption and c.caption[1] == "cybersyn-gui.station-chip" and c.caption[2] == ctx.name
					and c.caption[3] == tostring(s)) then
				caption_ok = false
			end
			local ignored = tab == "overview_tab" or tab == "utilization_tab" or tab == "delivery_breakdown_tab"
			local key = ignored and "cybersyn-gui.station-chip-ignored-tooltip" or "cybersyn-gui.station-chip-tooltip"
			if c.exists and not (c.tooltip and c.tooltip[1] == key) then tooltip_ok = false end
		end
		lab.check("the chip shows on every tab: [stop] Name #ID ×", caption_ok, chips)
		lab.check("its tooltip says where it does not apply (Overview, Utilization, Breakdown)", tooltip_ok, chips)

		-- Log: three events written now; the chip's two (station column, and station2 of a served event) show, the
		-- other station's does not, and every rendered row names the station.
		if dev("diag_state") then
			dev("diag_event", "station_limit", "info", { station = s })
			local seq_a = dev("diag_state").seq
			dev("diag_event", "station_limit", "info", { station = ctx.other })
			local seq_b = dev("diag_state").seq
			dev("diag_event", "served", "info", { station = ctx.other, station2 = s, a = 60 })
			local seq_c = dev("diag_state").seq
			dev("select_tab", PI, "log")
			local d = log_render()
			local seqs, all_name = {}, #d.groups > 0
			for _, g in ipairs(d.groups) do
				seqs[g.seq] = true
				if not names_station(g, s) then all_name = false end
			end
			lab.check("Log: every row names the chip's station", all_name, d.groups)
			lab.check("Log: its station and station2 events show, the other station's does not",
				seqs[seq_a] and seqs[seq_c] and not seqs[seq_b], { a = seq_a, b = seq_b, c = seq_c })
			-- The oracle over both rings: every event naming the station inside the Log's window, newest first.
			local fs = dev("log_filter_state", PI)
			local n = 0
			for _, ev in ipairs(dev("diag_events", nil, 200000)) do
				if (not fs.export.min_tick or ev.tick >= fs.export.min_tick) and names_station(ev, s) then n = n + 1 end
			end
			local shown = 0
			for _, g in ipairs(d.groups) do shown = shown + g.n end
			lab.check("Log: the rows hold exactly the events naming it (" .. n .. ")", shown == n and fs.export.station == s,
				{ shown = shown, n = n, export = fs.export.station })
		else
			lab.skip("Log honours the chip", "diagnostics off")
		end
		dev("select_tab", PI, "stations")
	end,

	-- Cleared by its × (either half, either button), clear-all and the filter-row toggle; the item filter stays
	-- with the ×.
	function(ctx)
		if not ctx.s then return end
		local s = ctx.s
		dev("set_filter", PI, { station = s, item = "iron-plate" })
		dev("click", PI, "stations_tab_station_chip")
		local f = filters()
		lab.check("×: the station chip goes, the item filter stays", f.station == nil and f.item == "iron-plate", f)
		dev("set_filter", PI, { station = s, item = false })
		dev("click", PI, "stations_tab_station_chip_icon", nil, { right = true })
		lab.check("right-click on the chip's icon clears it too", filters().station == nil)
		dev("set_filter", PI, { station = s })
		dev("click", PI, "manager_clear_filters_button")
		lab.check("the clear-all button clears it", filters().station == nil)
		dev("set_filter", PI, { station = s })
		dev("click", PI, "manager_filter_button")
		lab.check("closing the filter row clears it", filters().station == nil and dev("header", PI).filter_row ~= true)
		lab.check("with it gone the Stations tab lists every station again", #stations_ids() == lab.count(snapshot().stations))

		dev("set_filter", PI, { station = s })
		dev("close", PI)
		dev("open", PI)
		local chips = dev("chips", PI)
		lab.check("close + reopen keeps the chip, shown", filters().station == s and chips.stations_tab.station == true
			and serpent.line(stations_ids()) == serpent.line({ s }))
		dev("clear_filters", PI)
		lab.check("no chip after clear_filters", dev("chips", PI).stations_tab.station == false)
	end,

	-- Open in manager focuses by id: a stop renamed "R" next to a stop renamed "R2" shows only itself.
	function(ctx)
		if not ctx.s then return end
		local s, other = ctx.s, ctx.other
		local stop, stop2 = lab.read("stations", s).entity_stop, lab.read("stations", other).entity_stop
		ctx.renamed = { [s] = stop.backer_name, [other] = stop2.backer_name }
		stop.backer_name = "R"
		stop2.backer_name = "R2"
		dev("close", PI)
		dev("set_filter", PI, { query = "nothing matches this" })
		dev("relative_open", PI, "stop", s)
		dev("relative_click", PI, "open_manager")
		local st = dev("state", PI)
		lab.check("Open in manager: Stations tab, chip on the stop, search cleared", st.is_open and
			st.selected_tab == "stations_tab" and st.filters.station == s and st.filters.terms == nil, st)
		dev("collect")
		lab.check("a stop named \"R\" shows alone (\"R2\" is not listed)", serpent.line(stations_ids()) == serpent.line({ s }),
			stations_ids())
		local chips = dev("chips", PI)
		lab.check("the chip names it: R #" .. s, chips.stations_tab.caption and chips.stations_tab.caption[2] == "R",
			chips.stations_tab)
		dev("relative_close", PI)
		stop.backer_name = ctx.renamed[s]
		stop2.backer_name = ctx.renamed[other]
		dev("close", PI)
		dev("clear_filters", PI)
	end,

	-- The stop panel's item slots: an advertised (requested) slot lands on the Inventory's drill-down with the chip; an
	-- in-flight slot lands on Trains with item + chip, from a closed window.
	function(ctx)
		if not ctx.s then return end
		local s = ctx.s
		dev("collect")
		local st = snapshot().stations[s]
		local req = next(st.requested)
		local flight = next(st.deliveries)
		dev("close", PI)
		dev("relative_open", PI, "stop", s)
		local r = dev("relative_click", PI, { kind = "item", id = req, station = s })
		local st1, item = dev("state", PI), dev("item_dump", PI)
		lab.check("Requested slot: the window opens on the Inventory's drill-down of the item with the chip on the stop",
			st1.is_open and st1.selected_tab == "inventory_tab" and st1.filters.station == s and item.open and item.hash == req,
			{ r = r, state = st1.filters, item = item })
		local only_s = #(item.row_keys and item.row_keys.requesters or {}) > 0
		for _, t in ipairs({ "providers", "requesters" }) do
			for _, key in ipairs(item.row_keys and item.row_keys[t] or {}) do
				if key:sub(1, #tostring(s) + 1) ~= s .. "@" then only_s = false end
			end
		end
		lab.check("Requested slot: the drill-down's rows are the chip station's only", only_s, item.row_keys)
		dev("close_item", PI)
		dev("clear_filters", PI)
		-- Leftovers that would hide the slot's trains: a Trains chip they do not match, a search, and grouped mode with
		-- every depot group collapsed. The landing must clear the first two and expand the groups holding them.
		remote.call(DT, "set_chip", PI, "parked")
		dev("set_filter", PI, { query = "zzz-no-such-train" })
		remote.call(DT, "set_grouped", PI, true, {})
		dev("close", PI)
		r = dev("relative_click", PI, { kind = "item", id = flight, station = s, flight = true })
		local st2 = dev("state", PI)
		lab.check("in-flight slot: the window opens on Trains with item + chip", st2.is_open and
			st2.selected_tab == "trains_tab" and st2.filters.station == s and st2.filters.item == flight,
			{ r = r, state = st2 })
		local want = trains_oracle(s, flight)
		local got = trains_ids()
		lab.check("in-flight slot: Trains lists the trains carrying it to or from the stop (" .. #want .. "), past an "
			.. "old chip, search and collapsed groups", #want > 0 and serpent.line(got) == serpent.line(want),
			{ got = got, want = want })
		-- Shift: the same landings without the chip; the chip the clicks above set must go.
		r = dev("relative_click", PI, { kind = "item", id = req, station = s }, { shift = true })
		local st3, item3 = dev("state", PI), dev("item_dump", PI)
		lab.check("shift on the Requested slot: the item's drill-down opens without the station chip",
			st3.is_open and st3.selected_tab == "inventory_tab" and st3.filters.station == nil
			and st3.filters.item == req and item3.open and item3.hash == req,
			{ r = r, state = st3.filters, item = item3 })
		dev("close_item", PI)
		r = dev("relative_click", PI, { kind = "item", id = flight, station = s, flight = true }, { shift = true })
		local st4 = dev("state", PI)
		lab.check("shift on the in-flight slot: Trains on the item without the chip", st4.is_open
			and st4.selected_tab == "trains_tab" and st4.filters.station == nil and st4.filters.item == flight,
			{ r = r, state = st4.filters })
		remote.call(DT, "set_grouped", PI, false)
		dev("relative_close", PI)
		dev("close", PI)
		dev("clear_filters", PI)
	end,

	function(ctx)
		dev("set_setting", "cybersyn-enable-planner", ctx.planner)
		dev("clear_filters", PI)
		dev("close", PI)
	end,
})
