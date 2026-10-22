-- PLAN4 D14 (phase p5-log): the analytics side of round 4.
--   * slow_delivery: never written while the golden trace ran; written for a delivery whose train was held (its fuel
--     taken, then given back) after three normal trips of the same item, with a = the trip
--     and b = the item's average, station = requester, station2 = provider; not for the three normal trips.
--   * Utilization (PLAN8 D8-5, the chart back): without factorio-charts the tab is hidden and the missing library is
--     named once; with it (a lab that loads the zip) every layout is sampled, the legend lists them, a checkbox toggles
--     a series, each range button selects its interval.
--   * Breakdown (through its dev hooks, with or without factorio-charts): the bar tooltip names the item by its
--     localised name with its icon, fluids too; every range button covers what its caption says.

local D, pi = lab.D, lab.pi

local function dev(fn, ...)
	return remote.call(D, fn, ...)
end

local function read(...)
	return remote.call("cybersyn", "read_global", ...)
end

-- The case's own item and network: nothing in the save or the trace moves them, so the item's trip average is the
-- case's alone.
local ITEM = "engine-unit"
local NETWORK = "signal-Y"
local K = 60
-- Station combinator bits as cases.lua's CONTROL case sets them: provide + allow all, request + allow all.
local P_BITS, R_BITS = 1 + 4, 2 + 4

local function slow_events(from_seq)
	local out = {}
	for _, ev in ipairs(dev("diag_events", from_seq, 100000)) do
		if ev.kind == "slow_delivery" then out[#out + 1] = ev end
	end
	return out
end

local function sorted_keys(t)
	local keys = {}
	for k in pairs(t) do keys[#keys + 1] = k end
	table.sort(keys)
	return keys
end

local function trips(c)
	local e = read("stats", "trip_ema", ITEM)
	return e and e.n or 0
end

local function arm(c)
	-- cases.operate turns a train round once per status; every trip of the case needs its own turns.
	c.turned = nil
	cases.set_signals(c.r, cases.request(c, -2000, 1000))
end

local function dispatched(c)
	local t = cases.ctrain(c.trains[1])
	return t ~= nil and t.status == 1
end

local function delivery_steps(n)
	return {
		function(ctx)
			arm(ctx.c)
			lab.wait_until(function() return dispatched(ctx.c) end, 7200)
		end,
		function(ctx)
			lab.check("trip " .. n .. ": the train was dispatched", dispatched(ctx.c) or trips(ctx.c) >= n,
				cases.ctrain(ctx.c.trains[1]))
			lab.wait_until(function() return trips(ctx.c) >= n and cases.trains_ready(ctx.c) end, 36000)
		end,
	}
end

local steps = {
	function(ctx)
		-- The trace window: no slow delivery among its deliveries. The trace's own records give every trip it saw
		-- (dispatch to the train turning for its depot) with its first item, and the rule is applied to them here;
		-- the basic ring is checked as far back as it still reaches.
		local t = lab.trace
		local open, per_item, judged, slow_oracle = {}, {}, 0, 0
		local status_of = {}
		for _, e in ipairs(t and t.events or {}) do
			local tick, id, field, value = e[1], e[2], e[3], e[4]
			if field == "status" then
				if value == 1 and tick > t.start then open[id] = { tick = tick } end
				if value == 5 and status_of[id] == 4 and open[id] and open[id].item then
					local trip, item = tick - open[id].tick, open[id].item
					local a = per_item[item]
					if a and a.n >= 3 then
						judged = judged + 1
						if trip > 2 * a.avg then slow_oracle = slow_oracle + 1 end
					end
					if a then a.avg, a.n = a.avg + 0.2 * (trip - a.avg), a.n + 1 else per_item[item] = { avg = trip, n = 1 } end
					open[id] = nil
				end
				status_of[id] = value
			elseif field == "manifest" and value and open[id] and open[id].tick == tick then
				open[id].item = string.match(value, "^([^=,]+)")
			end
		end
		local evs = dev("diag_events", nil, 100000)
		local oldest = evs[1] and evs[1].tick
		local in_window = 0
		for _, ev in ipairs(evs) do
			if ev.kind == "slow_delivery" and t and ev.tick >= t.start and ev.tick <= t.stop then in_window = in_window + 1 end
		end
		lab.check("the golden trace: the rule finds no slow trip and the ring holds none", t ~= nil and slow_oracle == 0 and
			in_window == 0, { slow_oracle = slow_oracle, in_window = in_window })
		local ema = read("stats", "trip_ema") or {}
		lab.info(string.format("trace: %d timed trips of %d items, %d judged against an average of three or more; " ..
			"ring reaches back to tick %s (trace %d-%d)", (function()
				local n = 0
				for _, a in pairs(per_item) do n = n + a.n end
				return n
			end)(), lab.count(per_item), judged, tostring(oldest), t and t.start or -1, t and t.stop or -1))
		lab.check("the case's item has no trips yet", ema[ITEM] == nil, ema[ITEM])

		local c = cases.base("SLOW", { k = K }, { network = NETWORK })
		c.item = ITEM
		c.p = cases.station(c, { name = cases.sname(c, "p"), x = cases.X_P[1], bits = P_BITS,
			signals = cases.provide(c, 5000) })
		c.r = cases.station(c, { name = cases.sname(c, "r"), x = cases.X_R[1], bits = R_BITS })
		c.r_station, c.p_station = c.r.id, c.p.id
		c.operated = true
		c.line_end = c.surface.find_entities_filtered({ name = "straight-rail",
			position = { cases.X_MAX + 1, c.y + 1 } })[1]
		c.on_unload = function(cc) cases.set_signals(cc.r, {}) end
		cases.finish(c)
		ctx.c = c
		ctx.seq0 = dev("diag_state").seq
		lab.slow_case = c
		script.on_event(defines.events.on_tick, function()
			local cc = lab.slow_case
			if not cc then return end
			-- A new leg of the trip may need the turn again (the waypoint is used once per status).
			local t = cases.ctrain(cc.trains[1])
			local status = t and t.status
			if status ~= cc.last_status then
				cc.last_status = status
				cc.turned = nil
			end
			cases.operate(cc)
		end)
		lab.wait_until(function() return cases.trains_ready(c) end, 7200)
	end,
}
for n = 1, 3 do
	for _, s in ipairs(delivery_steps(n)) do steps[#steps + 1] = s end
end
local more = {
	function(ctx)
		local c = ctx.c
		local e = read("stats", "trip_ema", ITEM)
		lab.check("three normal trips: an average of three, no slow_delivery", e and e.n == 3 and #slow_events(ctx.seq0) == 0,
			{ ema = e, slow = slow_events(ctx.seq0) })
		ctx.avg = e and e.avg or 600
		lab.info(string.format("normal trips: average %.0f ticks", ctx.avg))
		arm(c)
		lab.wait_until(function() return dispatched(c) end, 7200)
	end,
	function(ctx)
		local train = game.train_manager.get_train_by_id(ctx.c.trains[1])
		lab.check("the fourth trip is dispatched", train ~= nil and dispatched(ctx.c), cases.ctrain(ctx.c.trains[1]))
		-- Held for three average trips by taking its fuel (a train switched to manual mode as it leaves the depot is
		-- handled as leaving its delivery, so manual mode would not slow this trip), then fuelled again.
		if train then cases.unfuel(train) end
		ctx.stopped = game.tick
		lab.wait(math.ceil(3 * ctx.avg))
	end,
	function(ctx)
		local train = game.train_manager.get_train_by_id(ctx.c.trains[1])
		if train then
			for _, dir in pairs(train.locomotives) do
				for _, loco in pairs(dir) do loco.insert({ name = "coal", count = 50 }) end
			end
		end
		ctx.resumed = game.tick
		lab.wait_until(function() return trips(ctx.c) >= 4 end, 36000)
	end,
	function(ctx)
		local c = ctx.c
		local slow = slow_events(ctx.seq0)
		local ev = slow[1]
		local e = read("stats", "trip_ema", ITEM)
		lab.check("the slowed trip wrote one slow_delivery", #slow == 1 and e and e.n == 4, { slow = slow, ema = e })
		lab.check("…with the trip and the average it was judged against", ev and ev.a > 2 * ev.b and
			math.abs(ev.b - ctx.avg) <= 1 and ev.a >= ctx.resumed - ctx.stopped, { ev = ev, avg = ctx.avg })
		lab.check("…about the requester, the provider, the train and the item", ev and ev.station == c.r_station and
			ev.station2 == c.p_station and ev.train == c.trains[1] and ev.item == ITEM and ev.sev == "warning",
			ev)
		-- The Log shows it under the deliveries group, with its message.
		dev("open", pi)
		dev("clear_filters", pi)
		dev("select_tab", pi, "log")
		dev("log_set_filter", pi, { sev = false, train = false, window = false, follow = true,
			summary = false })
		dev("log_set_filter", pi, { kind = "slow_delivery" })
		local d
		for _ = 1, 20 do
			dev("update", pi, 1)
			d = dev("log_dump", pi)
			if d.complete and not d.counting then break end
		end
		local row = d.rows[1]
		lab.check("the Log's kind filter shows it with its message", row and type(row.message) == "table" and
			row.message[1] == "cybersyn-diag.msg-slow-delivery" and #d.groups == 1,
			{ message = row and row.message, groups = #(d.groups or {}), visible = d.tab_visible, filter = d.filter })
		dev("log_set_filter", pi, { kind = false, group = "deliveries" })
		dev("update", pi, 2)
		d = dev("log_dump", pi)
		local found = false
		for _, g in ipairs(d.groups) do
			if g.kind == "slow_delivery" then found = true end
		end
		lab.check("…and in the deliveries group", found)
		dev("log_set_filter", pi, { group = false })
		lab.info(string.format("slow trip %d ticks against an average of %d (stopped %d ticks)", ev and ev.a or -1,
			ev and ev.b or -1, ctx.resumed - ctx.stopped))
		script.on_event(defines.events.on_tick, nil)
		lab.slow_case = nil
		c.cleanup()
		lab.wait(120)
	end,

	-- Utilization (PLAN8 D8-5): the factorio-charts line chart, sampled while analytics is on. The suite runs without the
	-- library by default (the tab is hidden, the notice printed once) and with it through a lab that loads the zip.
	function(ctx)
		ctx.analytics = settings.global["cybersyn-enable-analytics"].value
		ctx.samples = dev("utilization_samples", pi)
		dev("set_setting", "cybersyn-enable-analytics", true)
		-- Samples are taken every analytics.SAMPLE_TICKS from the moment the setting is on, before any tab opens.
		lab.wait(300)
	end,

	function(ctx)
		local s = dev("utilization_samples", pi)
		ctx.library = s.library
		ctx.layouts = {}
		for _, t in pairs(read("trains")) do
			if t.layout_id then ctx.layouts[tostring(t.layout_id)] = t.layout_id end
		end
		if not s.library then
			lab.check("no charts library: nothing is sampled", s.intervals == nil, s)
			dev("open", pi)
			local tab = dev("select_tab", pi, "utilization")
			lab.check("no charts library, analytics on: no Utilization tab", tab ~= "utilization_tab", tab)
			tab = dev("select_tab", pi, "breakdown")
			lab.check("…and no Breakdown tab", tab ~= "delivery_breakdown_tab", tab)
			s = dev("utilization_samples", pi)
			lab.check("…the missing library is named once on open", type(s.notice) == "number", s.notice)
			ctx.notice = s.notice
			dev("close", pi)
			lab.wait(60)
			return
		end
		local samples = s.intervals and s.intervals[1] and s.intervals[1].counts or {}
		lab.check("analytics on: every layout with trains is sampled before the tab opens",
			lab.same_list(sorted_keys(samples), sorted_keys(ctx.layouts)), s)
		dev("open", pi)
		local tab = dev("select_tab", pi, "utilization")
		lab.check("analytics on: the Utilization tab is there", tab == "utilization_tab", tab)
		lab.wait(2)
	end,

	function(ctx)
		if not ctx.library then
			dev("open", pi)
			local s = dev("utilization_samples", pi)
			lab.check("…and not again on the next open", s.notice == ctx.notice, { first = ctx.notice, now = s.notice })
			dev("close", pi)
			for _, name in ipairs({ "chart renders", "legend lists the layouts", "a checkbox toggles a series",
				"each range button selects" }) do
				lab.skip("Utilization " .. name, "factorio-charts not loaded in this lab")
			end
			return
		end
		local d = dev("dump", pi, "utilization")
		ctx.d = d
		lab.check("Utilization: the chart shows, no 'no data' line", d.chart == true and d.no_data == false, d)
		local surface = game.surfaces["cybersyn_analytics"]
		lab.check("…its camera on the analytics surface, registered on the interval", surface ~= nil
			and d.camera_surface == surface.index and d.registered, d)
		local names = {}
		for _, e in ipairs(d.legend) do names[e.series] = true end
		lab.check("…the legend lists the save's layouts", #d.legend > 0 and #d.legend == lab.count(names)
			and lab.same_list(sorted_keys(names), sorted_keys(ctx.layouts)), { legend = d.legend, want = ctx.layouts })
		local layouts = read("layouts")
		local captions = true
		for _, e in ipairs(d.legend) do
			local layout = layouts[tonumber(e.series)]
			local locos, wagons = 0, 0
			for _, c in pairs(layout or {}) do
				if c == 0 then locos = locos + 1 else wagons = wagons + 1 end
			end
			if not (e.state == true and type(e.caption) == "string" and e.caption:find("^" .. locos .. "L")
				and e.average:find("%%$")) then captions = false end
		end
		lab.check("…each checked, named by its carriage counts, with its average %", captions, d.legend)
		lab.check("…every series drawn", d.drawn == #d.legend and d.series == #d.legend, d)
		lab.check("…the graph as wide as the tab beside the legend, as tall as the tab below the time range",
			d.width == math.max(400, d.content_width - d.legend_width - 8) and d.height == math.max(300, d.content_height - d.chrome)
			and d.camera_width == d.width, d)
		lab.info("utilization: " .. serpent.line(d.legend, { comment = false }) .. string.format(" graph %dx%d", d.width, d.height))
		ctx.series = d.legend[1].series
		local state = dev("utilization_toggle", pi, ctx.series)
		lab.check("a legend checkbox unticks", state == false, state)
		lab.wait(2)
	end,

	function(ctx)
		if not ctx.library then return end
		local d = dev("dump", pi, "utilization")
		local e = d.legend[1]
		lab.check("…its series leaves the chart, the legend keeps it unticked", e and e.series == ctx.series and e.state == false
			and d.drawn == #d.legend - 1, d)
		dev("utilization_toggle", pi, ctx.series)
		lab.wait(2)
	end,

	function(ctx)
		if not ctx.library then return end
		local d = dev("dump", pi, "utilization")
		lab.check("…and ticked again it is back", d.legend[1].state == true and d.drawn == #d.legend, d)
		local ok, seen = true, {}
		for i = 1, #d.captions do
			dev("click", pi, "utilization_interval_buttons", i)
			local di = dev("dump", pi, "utilization")
			local lit = 0
			for _, b in pairs(di.buttons) do if b then lit = lit + 1 end end
			local s = dev("utilization_samples", pi)
			local viewers = 0
			for _, iv in ipairs(s.intervals) do viewers = viewers + iv.viewers end
			seen[i] = { interval = di.interval, lit = lit, viewers = viewers, mine = s.intervals[i].viewers,
				name = s.intervals[i].name, caption = di.captions[i] }
			if not (di.interval == i and di.buttons[i] and lit == 1 and viewers == 1 and s.intervals[i].viewers == 1
				and s.intervals[i].name == di.captions[i]) then
				ok = false
			end
		end
		lab.check("each range button selects the interval its caption names, lit alone, the chart registered on it alone", ok
			and #d.captions == 7, seen)
		dev("click", pi, "utilization_interval_buttons", 1)
		dev("close", pi)
		local s = dev("utilization_samples", pi)
		local viewers = 0
		for _, iv in ipairs(s.intervals) do viewers = viewers + iv.viewers end
		lab.check("closing the window lets go of the interval", viewers == 0, s.intervals)
		dev("open", pi)
		local tab = dev("select_tab", pi, "breakdown")
		lab.check("analytics on with the library: the Breakdown tab is there too", tab == "delivery_breakdown_tab", tab)
		dev("close", pi)
	end,

	function(ctx)
		-- Breakdown, through its hooks (they work with or without the charts library).
		local tip = dev("breakdown_tooltip", "steam", "travel_to_p", 12)
		local head = tip and tip[2]
		lab.check("Breakdown tooltip: a fluid by its localised name and icon", type(head) == "table" and
			head[2] == "[img=fluid.steam]" and type(head[4]) == "table" and head[4][1] == "fluid-name.steam", tip)
		tip = dev("breakdown_tooltip", "iron-plate", "loading", 3)
		head = tip and tip[2]
		lab.check("Breakdown tooltip: an item by its localised name and icon", type(head) == "table" and
			head[2] == "[img=item.iron-plate]" and type(head[4]) == "table" and head[4][1] == "item-name.iron-plate", tip)
		lab.info("breakdown tooltip: " .. serpent.line(tip, { comment = false }))
		local ranges = dev("breakdown_ranges")
		local spans = true
		for _, r in ipairs(ranges) do
			if r.ticks ~= r.parsed then spans = false end
		end
		lab.check("Breakdown range buttons span what their captions say", #ranges == 5 and spans, ranges)
		-- Item 1 of the round-4 screenshot review: gridlines on whole durations, a graph that fills the tab.
		local bl = dev("breakdown_layout", pi, 108)
		local labels = {}
		for i, t in ipairs(bl.ticks) do labels[i] = t.label end
		lab.check("Breakdown axis: the checkpoint's 108 s top gets 0s / 30s / 1m / 1m 30s", lab.same_list(labels,
			{ "0s", "30s", "1m", "1m 30s" }), bl.ticks)
		lab.check("Breakdown graph: as wide as the tab beside the legend, as tall as the tab below the time range",
			bl.width == math.max(400, bl.content_width - bl.sidebar - 8) and bl.height == math.max(300, bl.content_height - bl.chrome)
			and bl.height > 700, bl)
		local sr = dev("breakdown_stats_rows", { delivery_count = 2, total_wait = 4, total_travel_p = 50, total_loading = 9,
			total_travel_r = 70, total_unloading = 7, fail_count = 1,
			fail_reasons = { { reason = nil, count = 1, max = 30 } } })
		local keys_ok = #sr == 9
		for _, r in ipairs(sr) do
			if not (type(r[1]) == "table" and type(r[2]) == "string") then keys_ok = false end
		end
		lab.check("Breakdown stats: label / value rows (7 delivery rows, Stuck, one reason)", keys_ok
			and sr[1][1][1] == "cybersyn-gui.breakdown-stat-deliveries" and sr[1][2] == "2"
			and sr[8][1][1] == "cybersyn-gui.breakdown-stuck" and sr[9].indent == true, sr)
		dev("set_setting", "cybersyn-enable-analytics", false)
		dev("open", pi)
		local tab = dev("select_tab", pi, "utilization")
		lab.check("analytics off: no Utilization tab", tab ~= "utilization_tab", tab)
		dev("set_setting", "cybersyn-enable-analytics", ctx.analytics)
		dev("select_tab", pi, "overview")
	end,
}
for _, s in ipairs(more) do steps[#steps + 1] = s end

lab.suite("39_analytics", steps)
