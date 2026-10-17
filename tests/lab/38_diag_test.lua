-- Diagnostics core (PLAN3 phase 2, §4.4, §4.5, §4.13) on layout-dev, after the golden trace: the state and
-- schema a save from the previous build gets, the setting switches, acknowledgements, the always-on train and
-- stats fields, the snapshot fields, and the log events of this phase. The full-mode events come from one
-- delivery on a scenario row of its own (cases.lua's CONTROL builder on row 30, far from the rows
-- 40_reason_codes uses), which is torn down again before that suite fingerprints the world.

local D = "cybersyn-manager-dev"
local SPEED = 50
local ROW = 30
-- The mod's constants are not visible in level scope.
local ACK_END_EXPIRED = 1
local FAIL_TRAIN_REMOVED = 1

local function dev(fn, ...)
	return remote.call(D, fn, ...)
end

local dg = {}
lab.dg = dg

--- Every station id Cybersyn knows.
local function station_ids()
	local out = {}
	for id in pairs(lab.read("stations") or {}) do out[#out + 1] = id end
	return out
end

--- diag_counts against a walk of diag_unserved over every station.
local function counts_match()
	local tally = {}
	for _, id in ipairs(station_ids()) do
		for _, e in pairs(dev("diag_unserved", id)) do
			if e.reason then tally[e.reason] = (tally[e.reason] or 0) + 1 end
		end
	end
	local counts = dev("diag_counts")
	for _, t in ipairs({ counts, tally }) do
		for k in pairs(t) do
			if counts[k] ~= tally[k] then return false, { counts = counts, tally = tally } end
		end
	end
	return true, counts
end

local function events_since(seq, kind)
	local out = {}
	for _, ev in ipairs(dev("diag_events", seq, 100000)) do
		if ev.seq > seq and (not kind or ev.kind == kind) then out[#out + 1] = ev end
	end
	return out
end

--- Drives the row's single delivery: the request goes on once the train is parked, cases.operate loads and
--- unloads it and turns it at the line's end.
local function on_tick()
	local c = dg.case
	if not c or dg.done then return end
	local ok, err = pcall(function()
		if not dg.armed and cases.trains_ready(c) then
			dg.armed = game.tick
			cases.set_signals(c.r, { { c.item, -2000 }, { "cybersyn-request-threshold", 1000, "virtual" } })
		end
		cases.operate(c)
	end)
	if not ok then
		dg.error = err
		dg.done = true
	end
end

lab.suite("38_diag", {
	-- What a load of layout-dev (saved by the previous build) leaves behind.
	function()
		local st = dev("diag_state")
		lab.check("diagnostics default to basic", st.mode == "basic", st.mode)
		lab.check("ring sizes: basic 4,096, full from the setting (16,384)",
			st.ring_basic_size == 4096 and st.ring_full_size == 16384, st)
		lab.check("the log has events after the trace", st.seq > 0 and st.count_basic > 0, st)
		-- PLAN4 D14 appends slow_delivery as kind 26.
		lab.check("kinds table names all 26 kinds", #st.kinds == 26 and st.kinds[2] == "served" and
			st.kinds[26] == "slow_delivery", st.kinds)
		-- Step 2 (phase 2b): the sweep and ring fields, the planner-cycle counters, refuel_since.
		lab.check("schema step 2 recorded", lab.read("fork_schema") == 2, lab.read("fork_schema"))
		local acks = lab.read("acks")
		lab.check("storage.acks created", acks ~= nil and acks.request ~= nil and acks.station ~= nil and acks.lint ~= nil,
			acks)
		local trains, filled = 0, 0
		for _, t in pairs(lab.read("trains") or {}) do
			trains = trains + 1
			if type(t.in_interrupt) == "boolean" and t.last_state ~= nil and type(t.state_tick) == "number" then
				filled = filled + 1
			end
		end
		lab.check("every Cybersyn train has in_interrupt, last_state and state_tick", trains > 0 and filled == trains,
			{ trains = trains, filled = filled })
		local ci = dev("diag_check_interrupts")
		lab.check("in_interrupt cache agrees with every schedule", ci.mismatches == 0 and ci.trains == trains, ci)
		local ok, detail = counts_match()
		lab.check("diag_counts equals the live entries over every station", ok, detail)
		local s = dev("diag_stats")
		lab.check("available counters equal the planner's available_trains",
			serpent.line(s.available_count) == serpent.line(s.available_actual), s)
		local minimum_ok = true
		for net, n in pairs(s.available_actual) do
			if (s.min_available_by_network[net] or -1) > n then minimum_ok = false end
		end
		lab.check("the hour's minimum is at most the current count", minimum_ok, s)

		local evs = dev("diag_events", 0, 100000)
		local ordered, basic_only, served, served_ok = true, true, 0, true
		for i, ev in ipairs(evs) do
			if i > 1 and ev.seq <= evs[i - 1].seq then ordered = false end
			if ev.kind == "dispatched" or ev.kind == "arrive_p" or ev.kind == "train_state" then basic_only = false end
			if ev.kind == "served" then
				served = served + 1
				if not (ev.a > 0 and ev.station > 0 and ev.item) then served_ok = false end
			end
		end
		lab.check("events come back in seq order", ordered)
		lab.check("no full-only kind in basic mode", basic_only)
		lab.info("after the trace: " .. #evs .. " events, " .. served .. " served, " .. st.unserved_entries ..
			" unserved entries, counts " .. serpent.line(dev("diag_counts")))
		lab.check("served events carry a positive wait, the requester and the item", served > 0 and served_ok, served)
		local rows = dev("diag_unserved_rows", 5)
		local sorted = #rows > 0
		for i = 2, #rows do
			if rows[i].first_tick < rows[i - 1].first_tick then sorted = false end
		end
		lab.check("unserved_rows: longest wait first", sorted, rows)
		lab.check("last_for returns a station's newest events first", (function()
			local id = rows[1] and rows[1].r_station_id
			local last = id and dev("diag_last_for", "station", id, 5) or {}
			for i = 2, #last do
				if last[i].seq >= last[i - 1].seq then return false end
			end
			return #last > 0
		end)())

		dev("collect")
		local f = dev("snapshot_fields")
		-- Phase 2b: st.lint is the lint job's last mask for the stop (the manager ran it in 20_manager).
		lab.check("snapshot: read_tick and lint on every station record, equal to the lint job's mask",
			f.stations == 30 and f.read_tick == 30 and f.lint_number == 30 and f.lint_matches == 30, f)
		lab.check("snapshot: st.unserved copies the station's entries", f.unserved > 0 and f.unserved_count ==
			dev("diag_state").unserved_entries, f)
		lab.check("snapshot: train state, state_since, in_interrupt and has_path",
			f.trains > 0 and f.state == f.trains and f.state_since == f.trains and f.in_interrupt_bool == f.trains and
			f.has_path_bool == f.trains, f)
		lab.check("snapshot: declared fleet capability, mask_or and depots_by_name",
			type(f.capability) == "table" and type(f.mask_or) == "table" and type(f.depots_by_name) == "table" and
			type(f.min_available_by_network) == "table", f)
	end,

	-- A save from before this schema (no fork_schema, acks, counters or train fields) is brought up to date by the
	-- first planner tick, and the in-flight state is left alone.
	function()
		local id = next(lab.read("trains"))
		dg.train = id
		dg.entries_before = dev("diag_state").unserved_entries
		remote.call("cybersyn", "write_global", nil, "fork_schema")
		remote.call("cybersyn", "write_global", nil, "acks")
		remote.call("cybersyn", "write_global", nil, "trains", id, "in_interrupt")
		remote.call("cybersyn", "write_global", nil, "trains", id, "last_state")
		remote.call("cybersyn", "write_global", nil, "trains", id, "state_tick")
		remote.call("cybersyn", "write_global", {}, "stats", "available_count")
		lab.wait(10)
	end,
	function()
		lab.check("migration: schema step re-run", lab.read("fork_schema") == 2)
		lab.check("migration: storage.acks recreated", lab.read("acks", "request") ~= nil)
		local t = lab.read("trains", dg.train)
		lab.check("migration: train fields recreated", t ~= nil and type(t.in_interrupt) == "boolean" and
			t.last_state ~= nil and t.state_tick ~= nil, t and { t.in_interrupt, t.last_state, t.state_tick })
		local s = dev("diag_stats")
		lab.check("migration: available counters recounted", serpent.line(s.available_count) ==
			serpent.line(s.available_actual), s)
		-- Keys are served and swept during the wait, so only a wipe (not ordinary churn) may fail this.
		local after = dev("diag_state").unserved_entries
		lab.check("migration: the diagnostics state kept its entries",
			after >= math.floor(dg.entries_before / 2), { before = dg.entries_before, after = after })
	end,

	-- The setting: off drops storage.diag (acknowledgements stay), basic creates it again, the ring size applies.
	function()
		local rows = dev("diag_unserved_rows", 1)
		dg.key = rows[1]
		dev("diag_ack", "station", 424242, nil, nil, 1)
		dev("set_setting", "cybersyn-diagnostics", "off")
		lab.check("off: storage.diag is nil", lab.read("diag") == nil and dev("diag_state").mode == "off")
		lab.check("off: acknowledgements survive", lab.read("acks", "station", 424242) ~= nil)
		lab.check("off: the API answers empty", next(dev("diag_counts")) == nil and #dev("diag_events", 0, 10) == 0)
		dev("set_setting", "cybersyn-diagnostics", "basic")
		local st = dev("diag_state")
		lab.check("basic again: a fresh state", st.mode == "basic" and st.seq == 0 and st.loaded_tick == game.tick, st)
		dev("set_setting", "cybersyn-diagnostics-ring", 2048)
		lab.check("ring setting resizes the full ring", dev("diag_state").ring_full_size == 2048)
		dev("set_setting", "cybersyn-diagnostics-ring", 16384)
		lab.check("ring setting back to 16,384", dev("diag_state").ring_full_size == 16384)
		lab.check("unack of the station acknowledgement", dev("diag_unack", "station", 424242, nil, 1) == true)
		-- Two cycles so the fresh state has entries again.
		lab.wait(400)
	end,

	-- Acknowledgements: an event per acknowledge, expiry by time at a cycle start.
	function()
		local rows = dev("diag_unserved_rows", 1)
		local key = rows[1]
		if not lab.check("an unserved key to acknowledge", key ~= nil) then return end
		dg.key = key
		dg.ack_seq = dev("diag_state").seq
		local ack = dev("diag_ack", "request", key.r_station_id, key.hash, 300, 1)
		lab.check("ack records the confirmed reason and the expiry", ack.reason == key.reason and
			ack.until_tick == game.tick + 300, { ack = ack, key = key })
		lab.check("is_acked while it holds", dev("diag_is_acked", "request", key.r_station_id, key.hash) == true)
		local ev = events_since(dg.ack_seq, "acknowledged")[1]
		lab.check("acknowledged event: station, item, player, until",
			ev ~= nil and ev.station == key.r_station_id and ev.item == key.hash and ev.station2 == 1 and
			ev.a == ack.until_tick, ev)
		lab.wait(600)
	end,
	function()
		local key = dg.key
		if not key then return end
		lab.check("expired after its until_tick (swept at a cycle start)",
			dev("diag_is_acked", "request", key.r_station_id, key.hash) == false and
			lab.read("acks", "request", key.r_station_id) == nil)
		local ev = events_since(dg.ack_seq, "unacknowledged")[1]
		lab.check("unacknowledged event with the expiry cause", ev ~= nil and ev.station == key.r_station_id and
			ev.b == ACK_END_EXPIRED, ev)
	end,

	-- Full mode: one delivery's events share its delivery id; station changes; a delivery that fails.
	function()
		dev("set_setting", "cybersyn-diagnostics", "full")
		lab.check("full mode", dev("diag_state").mode == "full")
		dg.full_seq = dev("diag_state").seq
		dg.case = cases.CONTROL({ k = ROW })
		script.on_event(defines.events.on_tick, on_tick)
		lab.wait_until(function()
			local c = dg.case
			local t = cases.ctrain(c.trains[1])
			return dg.done or (dg.armed and t and t.status == 0 and t.is_available and
				#events_since(dg.full_seq, "returned") > 1)
		end, 12000, SPEED)
	end,
	function()
		lab.check("the delivery ran without a runner error", dg.error == nil, dg.error)
		local c = dg.case
		local train = c.trains[1]
		local by_kind = {}
		for _, ev in ipairs(events_since(dg.full_seq)) do
			if ev.train == train then
				by_kind[ev.kind] = by_kind[ev.kind] or {}
				table.insert(by_kind[ev.kind], ev)
			end
		end
		local dispatched = by_kind.dispatched and by_kind.dispatched[1]
		if not lab.check("dispatched event with a delivery id", dispatched ~= nil and dispatched.delivery > 0, by_kind) then
			return
		end
		lab.check("dispatched: requester, provider, item, manifest count",
			dispatched.station == c.r_station and dispatched.station2 == c.p_station and dispatched.item == c.item and
			dispatched.a == 1 and dispatched.b == 2000, dispatched)
		for _, kind in ipairs({ "arrive_p", "leave_p", "arrive_r", "leave_r", "returned" }) do
			local found = false
			for _, ev in ipairs(by_kind[kind] or {}) do
				if ev.delivery == dispatched.delivery then found = true end
			end
			lab.check(kind .. " event carries the delivery id", found, by_kind[kind])
		end
		local ap = by_kind.arrive_p and by_kind.arrive_p[1]
		lab.check("arrive_p names the provider", ap ~= nil and ap.station == c.p_station, ap)
		local np = false
		for _, ev in ipairs(by_kind.train_state or {}) do
			if ev.code == defines.train_state.no_path then np = true end
		end
		lab.check("train_state no_path logged on the dead-end line", np, by_kind.train_state)
		dg.station_seq = dev("diag_state").seq
		c.r.stop.trains_limit = 0
		lab.wait(300, SPEED)
	end,
	function()
		local c = dg.case
		local ev = events_since(dg.station_seq, "station_disabled")[1]
		lab.check("station_disabled when the train limit goes to 0", ev ~= nil and ev.station == c.r_station and
			ev.b == 0, ev)
		dg.station_seq = dev("diag_state").seq
		c.r.stop.trains_limit = 3
		-- Any status but working/low_power stops the station the way a power cut does. Combinators ignore
		-- disabled_by_script, and a cut row keeps them at low_power for thousands of ticks, so the combinator is
		-- marked for deconstruction instead (Cybersyn does not react to the mark).
		c.r.comb.order_deconstruction(game.forces.player)
		lab.check("the requester's combinator stopped working",
			c.r.comb.status == defines.entity_status.marked_for_deconstruction)
		lab.wait(300, SPEED)
	end,
	function()
		local c = dg.case
		local lim = events_since(dg.station_seq, "station_limit")[1]
		lab.check("station_limit from 0 to 3", lim ~= nil and lim.station == c.r_station and lim.a == 0 and lim.b == 3, lim)
		local pw = events_since(dg.station_seq, "station_power")[1]
		lab.check("station_power: the combinator stopped working", pw ~= nil and pw.station == c.r_station and pw.a == 0,
			pw)
		dg.station_seq = dev("diag_state").seq
		c.r.comb.cancel_deconstruction(game.forces.player)
		lab.wait(300, SPEED)
	end,
	function()
		local c = dg.case
		local pw = events_since(dg.station_seq, "station_power")[1]
		lab.check("station_power: working again", pw ~= nil and pw.station == c.r_station and pw.a == 1, pw)
		-- A held delivery, then its train is removed: delivery_failed.
		cases.unfuel(c.t1)
		dg.fail_seq = dev("diag_state").seq
		cases.set_signals(c.r, { { c.item, -2000 }, { "cybersyn-request-threshold", 1000, "virtual" } })
		lab.wait_until(function()
			local t = cases.ctrain(c.trains[1])
			return t ~= nil and t.status == 1
		end, 3000, SPEED)
	end,
	function()
		local c = dg.case
		local t = cases.ctrain(c.trains[1])
		if not lab.check("held delivery dispatched", t ~= nil and t.status == 1, t and t.status) then return end
		dg.delivery = t.delivery_id
		for _, car in pairs(c.t1.carriages) do car.destroy({ raise_destroy = true }) end
		local ev = events_since(dg.fail_seq, "delivery_failed")[1]
		lab.check("delivery_failed when the train is removed mid-delivery",
			ev ~= nil and ev.code == FAIL_TRAIN_REMOVED and ev.train == c.trains[1] and ev.delivery == dg.delivery and
			ev.station == c.r_station and ev.station2 == c.p_station and ev.a == 1 and ev.b == 1, ev)
	end,

	-- Export: synchronous for the lab, chunked on the fixed export tick for the GUI.
	function()
		local path = dev("diag_export", lab.pi)
		lab.check("export returns its script-output path", type(path) == "string" and
			string.match(path, "^cybersyn/diag%-%d+%.csv$") ~= nil, path)
		lab.info("export written to " .. tostring(path))
		local async = dev("diag_export_async", lab.pi)
		lab.check("an export queued for the export tick", dev("diag_state").export_jobs == 1, async)
		dev("tick", 6)
		lab.check("the manager tick leaves it to the export tick", dev("diag_state").export_jobs == 1)
		dev("export_tick", 6)
		lab.check("the export tick drained it", dev("diag_state").export_jobs == 0)

		script.on_event(defines.events.on_tick, nil)
		pcall(dg.case.cleanup)
		dg.done = true
		dev("set_setting", "cybersyn-diagnostics", "basic")
		lab.check("back to basic", dev("diag_state").mode == "basic")
		lab.wait(600, SPEED)
	end,
	function()
		lab.check("row torn down: the save's 30 stations again", #station_ids() == 30, #station_ids())
		local left = game.surfaces[cases.SURFACE].count_entities_filtered({
			area = { { cases.X_MIN - 64, cases.Y0 + cases.ROW * ROW - 64 }, { cases.X_MAX + 64, cases.Y0 + cases.ROW * ROW + 64 } },
		})
		lab.check("row torn down: no entity left", left == 0, left)
	end,
})
