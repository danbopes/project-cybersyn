-- PLAN4 D14 (phase p5-log): the analytics side of round 4.
--   * slow_delivery: never written while the golden trace ran; written for a delivery whose train was held (its fuel
--     taken, then given back) after three normal trips of the same item, with a = the trip
--     and b = the item's average, station = requester, station2 = provider; not for the three normal trips.
--   * Utilization (analytics on, no charts library in the lab): one table row per distinct train layout, trains per
--     row as storage.trains says.
--   * Breakdown (needs factorio-charts, absent here, so through its dev hooks): the bar tooltip names the item by its
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
		dev("log_set_filter", pi, { sev = false, train = false, subject = false, window = false, follow = true,
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

	-- Utilization: analytics on, the table, one row per layout.
	function(ctx)
		ctx.analytics = settings.global["cybersyn-enable-analytics"].value
		dev("set_setting", "cybersyn-enable-analytics", true)
		dev("open", pi)
		local tab = dev("select_tab", pi, "utilization")
		lab.check("analytics on without the charts library: the Utilization tab is there", tab == "utilization_tab", tab)
		local d = dev("dump", pi, "utilization")
		local layouts, per = {}, {}
		for _, t in pairs(read("trains")) do
			if t.layout_id then
				layouts[t.layout_id] = true
				per[t.layout_id] = (per[t.layout_id] or 0) + 1
			end
		end
		local m = dev("utilization_model", pi)
		lab.check("Utilization rows == distinct layouts", #d.rows == lab.count(layouts) and #m.rows == #d.rows and #d.rows > 0,
			{ rows = d.rows, layouts = layouts })
		local ok = true
		for i, r in ipairs(m.rows) do
			if per[r.layout_id] ~= r.trains or d.rows[i].trains ~= tostring(r.trains) then ok = false end
		end
		lab.check("…each with its trains as storage.trains counts them", ok, { model = m.rows, per = per })
		local CLASS = { [0] = "item/locomotive", [1] = "item/cargo-wagon", [2] = "item/fluid-wagon" }
		local icons_ok = true
		for i, r in ipairs(m.rows) do
			local row = d.rows[i]
			if not (row and row.layout == r.composition and r.runs and #row.icons == #r.runs) then
				icons_ok = false
			else
				for j, run in ipairs(r.runs) do
					local icon = row.icons[j]
					if not (type(icon) == "table" and icon[1] == CLASS[run.class] and icon[2] == run.n) then icons_ok = false end
				end
			end
		end
		lab.check("…its composition as icons with a count badge per run, the L<CC> text in the tooltip", icons_ok,
			{ model = m.rows, rows = d.rows })
		lab.check("…under a header that says what busy means", type(d.header) == "table" and
			d.header[1] == "cybersyn-gui.utilization-header", d.header)
		lab.info("utilization: " .. serpent.line(d.rows, { comment = false }))
		dev("utilization_set_period", pi, 1)
		d = dev("dump", pi, "utilization")
		lab.check("the period drop-down switches the period", d.minutes == 10, d.minutes)
		dev("utilization_set_period", pi, 2)
		-- Breakdown, through its hooks (no charts library in the lab).
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
		dev("set_setting", "cybersyn-enable-analytics", ctx.analytics)
		dev("select_tab", pi, "overview")
	end,
}
for _, s in ipairs(more) do steps[#steps + 1] = s end

lab.suite("39_analytics", steps)
