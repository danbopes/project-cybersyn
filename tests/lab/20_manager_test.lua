-- Manager characterization: every tab renders, dumps are stable, every sort column orders its rows, filters only
-- narrow and the network/mask filters match an oracle computed from Cybersyn's own station table, status chips,
-- paging clamps, the Overview period switch and rendered rows, hover hold, pause, memory and the snapshot summary's
-- invariants. Expected orders come from the dumped key values, never from the mod's own sort. Exact rows, tie
-- orders, statuses and amounts at a fixed tick are pinned by lab.golden() in summary.json, not here: this suite runs
-- on a world that is still moving.

local D, pi = lab.D, lab.pi
local SORTS, DEFAULT_SORT = lab.SORTS, lab.DEFAULT_SORT
local btest = bit32.btest

--- Which stations a network/mask filter must keep, from Cybersyn's storage rather than the manager's snapshot.
--- @param f {network: string?, mask: int?}
--- @return {[uint]: true}
local function network_oracle(f)
	local want, mask = f.network, f.mask or -1
	local out = {}
	for id, st in pairs(lab.read("stations")) do
		local name, m = st.network_name, st.network_mask
		local pass
		if want then
			if name == "signal-each" then
				pass = type(m) == "table" and m[want] ~= nil and btest(mask, m[want])
			else
				pass = name == want and type(m) == "number" and btest(mask, m)
			end
		elseif type(m) == "table" then
			pass = false
			for _, v in pairs(m) do
				if btest(mask, v) then pass = true end
			end
		else
			pass = type(m) == "number" and btest(mask, m)
		end
		if pass then out[id] = true end
	end
	return out
end

--- Whether a rendered Overview row shows the model row with key `key`: item rows carry the hash, station rows the
--- station id (waiting keys are "station|hash", slowest keys "tick|station|hash"), a removed station nothing.
local function shows(cell, key)
	if cell == key or cell == "" then return true end
	if type(key) ~= "string" or type(cell) ~= "number" then return false end
	return string.find("|" .. key, "|" .. cell .. "|", 1, true) ~= nil
end

local function render(tab)
	remote.call(D, "select_tab", pi, tab)
	return remote.call(D, "update", pi, 1)
end

--- Compares two lab.tab_keys results tab by tab; returns the first difference.
local function same_keys(a, b)
	for _, tab in ipairs({ "stations", "trains" }) do
		local ok, i = lab.same_list(a[tab], b[tab])
		if not ok then return false, tab .. " row " .. i end
	end
	for _, g in ipairs(lab.GRIDS) do
		local ok, i = lab.same_list(a.inventory[g], b.inventory[g])
		if not ok then return false, "inventory " .. g .. " row " .. i end
	end
	for name, list in pairs(a.overview) do
		local ok, i = lab.same_list(list, b.overview[name])
		if not ok then return false, "overview " .. name .. " row " .. i end
	end
	return true
end

local function size(keys)
	local n = { stations = #keys.stations, trains = #keys.trains }
	for _, g in ipairs(lab.GRIDS) do n["inventory_" .. g] = #keys.inventory[g] end
	return n
end

lab.suite("20_manager", {
	-- Every tab renders five times without error; the timings are the per-tab update cost on this save.
	function(ctx)
		-- Trains keep finishing their legs, but no new dispatch reshuffles the rows between two dumps of this suite.
		ctx.planner = settings.global["cybersyn-enable-planner"].value
		lab.check("planner frozen for the suite", lab.dev("set_setting", "cybersyn-enable-planner", false) == false)
		remote.call(D, "collect")
		local st = remote.call(D, "open", pi)
		lab.check("manager opens", st.is_open, st)
		remote.call(D, "clear_filters", pi)
		for _, tab in ipairs(lab.TABS) do
			local ok, sel = pcall(remote.call, D, "select_tab", pi, tab)
			lab.check("select " .. tab, ok and sel == tab .. "_tab", sel)
			local ok2, res = pcall(remote.call, D, "update", pi, 5)
			if lab.check("update(pi, 5) on " .. tab, ok2, res) then
				lab.info({ "", "update " .. tab .. " ", res })
			end
		end
	end,

	function(ctx)
		ctx.first = lab.tab_keys(pi)
		lab.wait(120)
	end,
	function(ctx)
		local second = lab.tab_keys(pi)
		local ok, where = same_keys(ctx.first, second)
		lab.check("dump order identical 2 s apart on every tab", ok, where)
		ctx.all = second
		lab.info("rows " .. serpent.line(size(second), { comment = false }))
	end,

	function(ctx)
		lab.check("ordered() rejects a misordered list", not lab.ordered({ 1, 3, 2 }, 3, true)
			and not lab.ordered({ "b", "a" }, 2, true) and not lab.ordered({ 1, nil, 2 }, 3, false)
			and lab.ordered({ 3, 3, 1, nil }, 4, false))
		for _, tab in ipairs({ "stations", "trains" }) do
			local coverage = {}
			for _, column in ipairs(SORTS[tab]) do
				for _, asc in ipairs({ true, false }) do
					local label = string.format("sort %s.%s %s", tab, column, asc and "asc" or "desc")
					remote.call(D, "set_sort", pi, tab, column, asc)
					render(tab)
					local d = remote.call(D, "dump", pi, tab)
					-- The stations dumper reports the column its query used; trains and inventory echo the stored sort.
					if tab == "stations" then
						lab.check(label .. " applied", d.column == column and d.ascending == asc,
							{ column = d.column, ascending = d.ascending })
					end
					lab.check(label .. " keeps the row set", #d.ids == #ctx.all[tab] and lab.subset(d.ids, ctx.all[tab]),
						{ rows = #d.ids, expected = #ctx.all[tab] })
					local ok, detail = lab.ordered(d.keys, #d.ids, asc)
					lab.check(label .. " ordered", ok, detail)
					if asc then
						local present, distinct = 0, {}
						for i = 1, #d.ids do
							if d.keys[i] ~= nil and d.keys[i] ~= false then
								present = present + 1
								distinct[d.keys[i]] = true
							end
						end
						coverage[#coverage + 1] = string.format("%s %d/%d keyed, %d distinct", column, present, #d.ids,
							lab.count(distinct))
					end
				end
			end
			lab.info("sort keys " .. tab .. ": " .. table.concat(coverage, "; "))
			local def = DEFAULT_SORT[tab]
			remote.call(D, "set_sort", pi, tab, def[1], def[2])
		end
		for _, column in ipairs(SORTS.inventory) do
			for _, asc in ipairs({ true, false }) do
				local label = string.format("sort inventory.%s %s", column, asc and "asc" or "desc")
				remote.call(D, "set_sort", pi, "inventory", column, asc)
				render("inventory")
				local d = remote.call(D, "dump", pi, "inventory")
				for _, g in ipairs(lab.GRIDS) do
					local grid = d[g]
					-- A column a grid cannot sort by (wait outside requests, or without wait data) falls back to item order.
					local used_ok = grid.column == column or (column == "wait" and grid.column == "item_order")
					lab.check(label .. " " .. g .. " column", used_ok, grid.column)
					lab.check(label .. " " .. g .. " keeps the item set",
						#grid.hashes == #ctx.all.inventory[g] and lab.subset(grid.hashes, ctx.all.inventory[g]),
						{ rows = #grid.hashes, expected = #ctx.all.inventory[g] })
					local ok, detail = lab.ordered(grid.keys, #grid.hashes, grid.ascending)
					lab.check(label .. " " .. g .. " ordered", ok, detail)
					lab.check(label .. " " .. g .. " captions match the aggregate", grid.stale == 0, grid.stale)
					lab.check(label .. " " .. g .. " shows every aggregated item", #grid.hashes == grid.expected,
						{ shown = #grid.hashes, expected = grid.expected })
				end
			end
		end
		remote.call(D, "set_sort", pi, "inventory", "item_order", true)
	end,

	-- Each filter narrows or keeps every tab's row set and never adds a row.
	function(ctx)
		local all = ctx.all
		local item = all.inventory.provided[1]
		local cases = lab.filter_cases(item)
		for _, case in ipairs(cases) do
			remote.call(D, "clear_filters", pi)
			remote.call(D, "set_filter", pi, case[2])
			local keys = lab.tab_keys(pi)
			for _, tab in ipairs({ "stations", "trains" }) do
				local ok, extra = lab.subset(keys[tab], all[tab])
				lab.check("filter " .. case[1] .. " " .. tab .. " adds nothing", ok, extra)
			end
			for _, g in ipairs(lab.GRIDS) do
				local ok, extra = lab.subset(keys.inventory[g], all.inventory[g])
				lab.check("filter " .. case[1] .. " inventory " .. g .. " adds nothing", ok, extra)
			end
			for name, list in pairs(keys.overview) do
				-- A list cut to its top rows can show rows under a filter that ranked below the cut without it.
				if all.overview_total[name] == #all.overview[name] then
					local ok, extra = lab.subset(list, all.overview[name])
					lab.check("filter " .. case[1] .. " overview " .. name .. " adds nothing", ok, extra)
				else
					lab.check("filter " .. case[1] .. " overview " .. name .. " total does not grow",
						keys.overview_total[name] <= all.overview_total[name],
						{ keys.overview_total[name], all.overview_total[name] })
				end
			end
			lab.info("filter " .. case[1] .. " rows " .. serpent.line(size(keys), { comment = false }))
			ctx[case[1]] = keys
		end
		lab.check("query stn-1 narrows stations", #ctx["query stn-1"].stations < #all.stations
			and #ctx["query stn-1"].stations > 0, #ctx["query stn-1"].stations)
		lab.check("surface nauvis leaves no stations", #ctx["surface nauvis"].stations == 0,
			#ctx["surface nauvis"].stations)
		lab.check("surface cyb-bench keeps every station", #ctx["surface cyb-bench"].stations == #all.stations,
			#ctx["surface cyb-bench"].stations)
		for _, case in ipairs(cases) do
			local f = case[2]
			if f.network or f.mask then
				local expected = network_oracle(f)
				local rows = ctx[case[1]].stations
				local got = lab.set_of(rows)
				local missing, extra
				for id in pairs(expected) do
					if not got[id] then missing = id end
				end
				for id in pairs(got) do
					if not expected[id] then extra = id end
				end
				lab.check("filter " .. case[1] .. " stations match the storage oracle", not missing and not extra,
					{ missing = missing, extra = extra, rows = #rows, expected = lab.count(expected) })
				lab.check("filter " .. case[1] .. " narrows stations", #rows > 0 and #rows < #all.stations,
					{ rows = #rows, all = #all.stations })
			end
		end
		remote.call(D, "clear_filters", pi)
		local f = remote.call(D, "clear_filters", pi)
		lab.check("clear_filters resets", f.terms == nil and f.item == nil and f.network == nil and f.mask == -1
			and f.surface == nil, f)
	end,

	-- Status chips: each chip shows exactly the stations of that status, in the unfiltered order, and its count.
	function(ctx)
		remote.call(D, "clear_filters", pi)
		lab.set_status_filter(pi, nil)
		render("stations")
		local d = remote.call(D, "dump", pi, "stations")
		lab.check("stations rows striped", d.stripes_ok == true)
		lab.check("every station has a status", #d.statuses == #d.ids and #d.ids == d.total,
			{ statuses = #d.statuses, ids = #d.ids, total = d.total })
		local seen = 0
		for _, s in ipairs(lab.STATUSES) do
			local expected = {}
			for i, id in ipairs(d.ids) do
				if d.statuses[i] == s then expected[#expected + 1] = id end
			end
			local active = lab.set_status_filter(pi, s)
			local f = remote.call(D, "dump", pi, "stations")
			local ok, i = lab.same_list(f.ids, expected)
			lab.check("status chip " .. s .. " shows its stations in order", ok and active == s,
				{ active = active, row = i, got = #f.ids, expected = #expected })
			lab.check("status chip " .. s .. " count", (d.counts[s] or 0) == #expected, { d.counts[s], #expected })
			if #expected > 0 then seen = seen + 1 end
		end
		lab.check("statuses cover at least two chips", seen >= 2, seen)
		lab.check("status chip all restores every row", lab.set_status_filter(pi, nil) == "all"
			and #remote.call(D, "dump", pi, "stations").ids == d.total)
	end,

	-- Paging: a 10-row page splits the 30 stations into three pages, out-of-range pages clamp.
	function(ctx)
		remote.call("cybersyn", "write_global", 10, "manager", "players", pi, "page_size")
		local pages = {}
		for p = 1, 3 do
			remote.call(D, "set_page", pi, "stations", p)
			render("stations")
			local d = remote.call(D, "dump", pi, "stations")
			lab.check("stations page " .. p .. " has 10 rows", #d.ids == 10 and d.page == p, { rows = #d.ids, page = d.page })
			for _, id in ipairs(d.ids) do pages[#pages + 1] = id end
		end
		local ok, i = lab.same_list(pages, ctx.all.stations)
		lab.check("three pages concatenate to the full order", ok, i)
		for _, case in ipairs({ { 4, 3 }, { 99, 3 }, { 0, 1 }, { -5, 1 } }) do
			remote.call(D, "set_page", pi, "stations", case[1])
			render("stations")
			local d = remote.call(D, "dump", pi, "stations")
			lab.check("stations page " .. case[1] .. " clamps to " .. case[2], d.page == case[2] and #d.ids == 10,
				{ page = d.page, rows = #d.ids })
		end
		remote.call(D, "set_page", pi, "trains", 2)
		render("trains")
		local d = remote.call(D, "dump", pi, "trains")
		lab.check("trains page 2 of 1 clamps to 1", d.page == 1 and #d.ids == #ctx.all.trains, { page = d.page, rows = #d.ids })
		remote.call("cybersyn", "write_global", nil, "manager", "players", pi, "page_size")
		remote.call(D, "set_page", pi, "stations", 1)
		render("stations")
		d = remote.call(D, "dump", pi, "stations")
		lab.check("page size restored", #d.ids == #ctx.all.stations, #d.ids)
	end,

	function(ctx)
		remote.call(D, "select_tab", pi, "overview")
		local totals = {}
		for _, minutes in ipairs(lab.PERIODS) do
			local ok, res = pcall(remote.call, D, "set_period", pi, minutes)
			lab.check("set_period " .. minutes, ok and res == minutes, res)
			local ok2, err = pcall(remote.call, D, "update", pi, 1)
			lab.check("overview renders at period " .. minutes, ok2, err)
			local d = remote.call(D, "dump", pi, "overview")
			lab.check("overview model period " .. minutes, d.period == minutes, d.period)
			totals[minutes] = d.lists.delivered.total
			-- The rendered table shows the model's rows from the list's scroll offset on, one per row.
			for name, list in pairs(d.lists) do
				local offset = d.offsets and d.offsets[name] or 0
				local bad
				for r, cells in ipairs(list.rendered) do
					if not shows(cells[1], list.keys[offset + r]) then
						bad = { row = r, cell = cells[1], key = list.keys[offset + r] }
						break
					end
				end
				local want = math.max(0, math.min(#list.keys - offset, d.capacity))
				lab.check(string.format("overview %s rendered rows match the model at period %d", name, minutes),
					not bad and (#list.rendered == want or (want == 0 and #list.rendered == 0)),
					bad or { rendered = #list.rendered, want = want })
			end
		end
		lab.check("delivered over 10 min never exceeds delivered over 24 h", totals[10] <= totals[1440], totals)
		lab.info("delivered list totals by period " .. serpent.line(totals, { comment = false }))
		remote.call(D, "set_period", pi, 60)
	end,

	-- Hover hold: hovering a station row holds the hover scope, a render keeps the rows, leaving releases it.
	function(ctx)
		remote.call(D, "select_tab", pi, "stations")
		render("stations")
		local before = remote.call(D, "dump", pi, "stations").ids
		local h = remote.call(D, "hover", pi, "manager_stations_tab_scroll_pane", 1)
		lab.check("hover on a station row is handled and holds", type(h) == "table" and h.handled and h.hold == true, h)
		remote.call(D, "update", pi, 1)
		local ok, i = lab.same_list(remote.call(D, "dump", pi, "stations").ids, before)
		lab.check("rows unchanged across a render while held", ok, i)
		local l = remote.call(D, "hover", pi, "manager_stations_tab_scroll_pane", 1, true)
		lab.check("leaving releases the hold", type(l) == "table" and l.hold == false, l)
	end,

	-- Pause: no render while paused, renders resume once unpaused.
	function(ctx)
		remote.call(D, "select_tab", pi, "stations")
		local st = remote.call(D, "set_paused", pi, true)
		lab.check("pause sets paused", st.paused, st)
		ctx.paused_tick = st.last_update_tick
		lab.wait(180)
	end,
	function(ctx)
		local st = remote.call(D, "state", pi)
		lab.check("last_update_tick frozen while paused", st.last_update_tick == ctx.paused_tick,
			{ before = ctx.paused_tick, after = st.last_update_tick, tick = game.tick })
		st = remote.call(D, "set_paused", pi, false)
		lab.check("unpause renders at once", not st.paused and st.last_update_tick == game.tick, st)
		ctx.unpaused_tick = st.last_update_tick
		lab.wait(180)
	end,
	function(ctx)
		local st = remote.call(D, "state", pi)
		lab.check("manager tick renders again after unpause", st.last_update_tick > ctx.unpaused_tick,
			{ before = ctx.unpaused_tick, after = st.last_update_tick })
	end,

	-- Heap growth over one full collector pass with renders after every step.
	function(ctx)
		local before = remote.call(D, "mem", true)
		local steps = remote.call(D, "bench_pass", pi)
		local after = remote.call(D, "mem", true)
		local growth = after - before
		lab.check("heap growth over a full pass under 10,000 KB", growth < 10000, growth)
		lab.info(string.format("heap %.0f KB -> %.0f KB (%+.0f KB) over a %d-step pass", before, after, growth, #steps))
	end,

	function(ctx)
		local s = remote.call(D, "collect")
		lab.check("summary station_count 30", s.station_count == 30, s.station_count)
		lab.check("summary train_count 6", s.train_count == 6, s.train_count)
		lab.check("fleet_total equals train_count", s.fleet_total == s.train_count, { s.fleet_total, s.train_count })
		local by_status = 0
		for _, n in pairs(s.fleet_by_status) do by_status = by_status + n end
		lab.check("fleet by_status sums to fleet_total", by_status == s.fleet_total, { by_status, s.fleet_total })

		local available = lab.read("available_trains") or {}
		local expected = {}
		for network, trains in pairs(available) do expected[network] = lab.count(trains) end
		local ok = lab.count(expected) == lab.count(s.available_by_network)
		for network, n in pairs(expected) do
			if s.available_by_network[network] ~= n then ok = false end
		end
		lab.check("available_by_network matches the available train table", ok,
			{ summary = s.available_by_network, storage = expected })
		local networks = {}
		for _, st in pairs(lab.read("stations")) do
			if type(st.network_name) == "string" then networks[st.network_name] = true end
			if type(st.network_mask) == "table" then
				for name in pairs(st.network_mask) do networks[name] = true end
			end
		end
		local unknown
		for network in pairs(s.available_by_network) do
			if not networks[network] then unknown = network end
		end
		lab.check("available_by_network keys are station networks", unknown == nil, unknown)

		render("stations")
		local stations = remote.call(D, "dump", pi, "stations")
		lab.check("stations dump total equals station_count", stations.total == s.station_count,
			{ stations.total, s.station_count })
		lab.check("stations status counts sum to the total", (function()
			local sum = 0
			for k, n in pairs(stations.counts) do
				if k ~= "all" then sum = sum + n end
			end
			return sum == stations.counts.all and stations.counts.all == stations.total
		end)(), stations.counts)

		remote.call(D, "set_sort", pi, "stations", "provided_requested", true)
		render("stations")
		local pr = remote.call(D, "dump", pi, "stations")
		local per_station = 0
		for i = 1, #pr.ids do per_station = per_station + (pr.keys[i] or 0) end
		remote.call(D, "set_sort", pi, "stations", "name", true)

		remote.call(D, "set_sort", pi, "inventory", "stations", true)
		render("inventory")
		local inv = remote.call(D, "dump", pi, "inventory")
		remote.call(D, "set_sort", pi, "inventory", "item_order", true)
		local per_item = 0
		for _, g in ipairs({ "provided", "requested" }) do
			for i = 1, #inv[g].hashes do per_item = per_item + (inv[g].keys[i] or 0) end
		end
		-- Inventory counts only active requests (above threshold); Stations counts every request slot.
		lab.check("Inventory provider+requester entries within the Stations total", per_item <= per_station and per_item > 0,
			{ stations = per_station, inventory = per_item })
		lab.info("provider+requester entries: Stations " .. per_station .. ", Inventory (active requests) " .. per_item)
		lab.check("inventory provided grid has provided_items entries", #inv.provided.hashes == s.provided_items,
			{ #inv.provided.hashes, s.provided_items })
		lab.check("inventory requested grid has requested_items entries", #inv.requested.hashes == s.requested_items,
			{ #inv.requested.hashes, s.requested_items })
		lab.check("inventory in-transit grid has in_transit_items entries", #inv.in_transit.hashes == s.in_transit_items,
			{ #inv.in_transit.hashes, s.in_transit_items })
		remote.call(D, "close", pi)
	end,

	function(ctx)
		lab.check("planner restored", lab.dev("set_setting", "cybersyn-enable-planner", ctx.planner) == ctx.planner)
	end,
})
