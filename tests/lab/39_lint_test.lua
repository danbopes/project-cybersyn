-- Phase 2b setup lint (PLAN3 §4.12): every check without a reason code of its own, each built on a row of its own
-- and asserted through the dev API (lint_run, lint_bits, lint_findings), with the `lint` log event of each
-- transition; the job running only while a window is open; the setup registry (PLAN4 D8) recording each combinator
-- and stop problem when it is built and dropping it when it is fixed by a rotation, a removal, a revived ghost or a
-- rename, the same as a fresh seed, and /cybersyn-find-problems printing it; and the phantom/occupancy race of an
-- incremental pass (PLAN4 D10) closed: a train leaving its provider or requester between the pass's index and the
-- station's turn is no gap.
--
-- Rows k = 40.. on cyb-bench, torn down at the end. The checks whose reason codes the dispatcher records are asserted
-- with those codes in 40_reason_codes.

local DEV = "cybersyn-manager-dev"
local SPEED = 50
local K0 = 40

local function dev(fn, ...)
	return remote.call(DEV, fn, ...)
end

local function read(...)
	return (remote.call("cybersyn", "read_global", ...))
end

local function write(value, ...)
	return remote.call("cybersyn", "write_global", value, ...)
end

local lx = { rows = {} }
lab.lint = lx

local function has(id, check, is_train)
	return dev("assert_lint", id, check, is_train) == true
end

--- Runs a fresh collector pass and lint pass and returns the lint events written by it.
local function pass()
	local seq = dev("diag_state").seq
	dev("collect")
	dev("lint_run")
	local out = {}
	for _, ev in ipairs(dev("diag_events", seq, 100000)) do
		if ev.seq > seq and ev.kind == "lint" then out[#out + 1] = ev end
	end
	return out
end

--- The lint event of one transition among `events`.
local function transition(events, id, check_name, appeared)
	for _, ev in ipairs(events) do
		if ev.b == id and ev.code_name == (appeared and "appeared" or "cleared") and ev.a == lx.check_index[check_name] then
			return ev
		end
	end
	return nil
end

--- A train that is not Cybersyn's: built east of `x` on the case's row, scheduled to `station` with a long wait.
local function vanilla_train(case, x, station)
	local s = case.surface
	local y = case.y + 1
	local force = game.forces.player
	local function add(e) case.entities[#case.entities + 1] = e; return e end
	local l1 = add(s.create_entity({ name = "locomotive", position = { x + 4, y }, direction = defines.direction.east,
		force = force }))
	add(s.create_entity({ name = "cargo-wagon", position = { x + 11, y }, direction = defines.direction.east, force = force }))
	local l2 = add(s.create_entity({ name = "locomotive", position = { x + 18, y }, direction = defines.direction.west,
		force = force }))
	l1.insert({ name = "coal", count = 50 })
	l2.insert({ name = "coal", count = 50 })
	local train = l1.train
	train.schedule = { current = 1, records = { { station = station,
		wait_conditions = { { type = "time", ticks = 3600 * 60, compare_type = "or" } } } } }
	train.manual_mode = false
	case.train_entities[#case.train_entities + 1] = train
	return train
end

local function comb_at(case, stop_entity, dx, dy, dir, mode, ghost)
	local s = case.surface
	local pos = { stop_entity.position.x + dx, stop_entity.position.y + dy }
	local e
	if ghost then
		e = s.create_entity({ name = "entity-ghost", inner_name = "cybersyn-combinator", position = pos,
			direction = defines.direction[dir], force = game.forces.player, raise_built = true })
	else
		e = s.create_entity({ name = "cybersyn-combinator", position = pos, direction = defines.direction[dir],
			force = game.forces.player })
		local ctl = e.get_or_create_control_behavior()
		local params = ctl.parameters
		params.operation = mode
		params.first_signal = { type = "virtual", name = case.network }
		ctl.parameters = params
		script.raise_script_built({ entity = e })
	end
	case.entities[#case.entities + 1] = e
	return e
end

local function registry(entity)
	return dev("lint_registry", entity.unit_number)
end

--- The one registry finding on `entity` has `message` (nil: it has none).
local function only(entity, message)
	local list = registry(entity)
	if message == nil then return #list == 0 end
	return #list == 1 and list[1].message == message
end

local function bare_stop(case, x, name)
	local s = case.surface
	local stop = s.create_entity({ name = "train-stop", position = { x, case.y - 1 }, direction = defines.direction.west,
		force = game.forces.player, raise_built = true })
	stop.backer_name = name
	case.entities[#case.entities + 1] = stop
	return stop
end

lab.suite("39_lint", {
	function()
		lx.setting = settings.global["cybersyn-diagnostics"].value
		dev("set_setting", "cybersyn-diagnostics", "basic")
		-- An earlier file may leave a manager window open, and the lint job then runs between steps and writes the
		-- transition events before pass() can capture them.
		dev("close", 1)
		lx.reg_start = dev("lint_state").registry
		lab.info("registry findings on layout-dev before the rows: " .. tostring(lx.reg_start))
		-- Row 1: depots, refueler, trains, a requester for the phantom and one for the occupancy gap.
		-- Trains on mask 1 (the default network mask is every bit, which any refueler would match).
		local a = cases.base("LINT_A", { k = K0 }, { network = "signal-7", depot_mask = 1 })
		a.d2 = cases.station(a, { name = a.d1.name, x = cases.X_D2, mode = "+", bits = 0, signals = { { "signal-7", 1 } } })
		a.depots[#a.depots + 1] = a.d2
		a.t2 = cases.train(a, cases.X_D2 + 6, a.d2)
		-- A depot of another name: a train group holding its train and t2 spans two depot names.
		a.d3 = cases.station(a, { name = cases.sname(a, "depot3"), x = cases.X_D3, mode = "+", bits = 0,
			signals = { { "signal-7", 1 } } })
		a.depots[#a.depots + 1] = a.d3
		a.t3 = cases.train(a, cases.X_D3 + 6, a.d3)
		a.f = cases.station(a, { name = cases.sname(a, "f"), x = cases.X_P[3], mode = ">>", bits = 4,
			signals = { { a.network, 4 } } })
		a.p = cases.station(a, { name = cases.sname(a, "p"), x = cases.X_P[1], bits = 1 + 4 })
		a.r = cases.station(a, { name = cases.sname(a, "r"), x = cases.X_R[1], bits = 2 + 4 })
		cases.finish(a)
		lx.rows[#lx.rows + 1] = a
		lx.a = a
		-- Row 2: the registry's combinator and stop problems.
		local w = cases.base("LINT_W", { k = K0 + 1 }, { network = "signal-8", no_train = true })
		-- The stop a train that is not Cybersyn's heads for (the occupancy gap).
		w.r2 = cases.station(w, { name = cases.sname(w, "r2"), x = 220, bits = 2 + 4 })
		cases.finish(w)
		lx.rows[#lx.rows + 1] = w
		lx.w = w
		local derelict = comb_at(w, w.d1.stop, -200, -2.5, "north", "/")
		local ghost_stop = bare_stop(w, 160, "rc-LINT_W-ghost")
		local ghost = comb_at(w, ghost_stop, 1.5, -2.5, "north", "/", true)
		local wrong_stop = bare_stop(w, 130, "rc-LINT_W-wrong")
		local wrong = comb_at(w, wrong_stop, 1.5, -2.5, "east", "/")
		local nocomb_stop = bare_stop(w, 100, "rc-LINT_W-nocomb")
		local control = comb_at(w, nocomb_stop, 1.5, -2.5, "north", "%")
		local double_stop = bare_stop(w, 70, "rc-LINT_W-double")
		local first = comb_at(w, double_stop, 1.5, -2.5, "north", "/")
		local second = comb_at(w, double_stop, -0.5, -2.5, "north", "/")
		-- A plain stop that shares the depot's name.
		local overlap_stop = bare_stop(w, 40, w.d1.name)
		lx.world = { derelict = derelict, ghost_stop = ghost_stop, ghost = ghost, wrong_stop = wrong_stop, wrong = wrong,
			nocomb_stop = nocomb_stop, control = control, double_stop = double_stop, first = first, second = second,
			overlap_stop = overlap_stop }
		lab.check("world rows: the wrong-side combinator is not adopted by its stop",
			read("to_stop", wrong.unit_number) == nil)
		lab.check("world rows: the control-only stop and the double stop own their combinators",
			read("to_stop", control.unit_number) == nocomb_stop and read("to_stop", first.unit_number) == double_stop and
			read("to_stop", second.unit_number) == double_stop)
		lab.check("world rows: none of the four stops is registered with Cybersyn",
			read("stations", ghost_stop.unit_number) == nil and read("stations", wrong_stop.unit_number) == nil and
			read("stations", nocomb_stop.unit_number) == nil)
		-- Row 3: a 40-slot train the requester accepts and an 80-slot one it rejects, for a 50-stack request. The
		-- dispatcher tests capacity before layout, so it records R_LAYOUT and the lint must say layout, not capacity.
		local l = cases.base("LINT_L", { k = K0 + 2 }, { network = "signal-6" })
		l.d2 = cases.depot(l, cases.X_D2, cases.sname(l, "depot2"))
		l.t2 = cases.train(l, cases.X_D2 + 6, l.d2, nil, 2)
		l.p = cases.station(l, { name = cases.sname(l, "p"), x = cases.X_P[1], bits = 1 + 4,
			signals = cases.provide(l, 20000) })
		l.r = cases.station(l, { name = cases.sname(l, "r"), x = cases.X_R[1], bits = 2 })
		cases.finish(l)
		lx.rows[#lx.rows + 1] = l
		lx.l = l
		-- Row 4: a requester threshold of 50 stacks that only the provider's own item threshold (2,000) brings within
		-- the 40-slot train; the train is dispatched without fuel, so it stays on its way to the provider.
		local o = cases.base("LINT_O", { k = K0 + 3 }, { network = "signal-5" })
		o.p = cases.station(o, { name = cases.sname(o, "p"), x = cases.X_P[1], bits = 1 + 4,
			signals = cases.provide(o, 20000) })
		local pos = o.p.stop.position
		local force = game.forces.player
		o.comb2 = o.surface.create_entity({ name = "cybersyn-combinator", position = { pos.x - 0.5, pos.y - 2.5 },
			direction = defines.direction.north, force = force })
		local ctl = o.comb2.get_or_create_control_behavior()
		local params = ctl.parameters
		params.operation = "%"
		ctl.parameters = params
		o.entities[#o.entities + 1] = o.comb2
		script.raise_script_built({ entity = o.comb2 })
		o.cc2 = o.surface.create_entity({ name = "constant-combinator", position = { pos.x - 0.5, pos.y - 4.5 },
			force = force })
		o.entities[#o.entities + 1] = o.cc2
		o.cc2.get_wire_connector(defines.wire_connector_id.circuit_red, true).connect_to(
			o.comb2.get_wire_connector(defines.wire_connector_id.combinator_input_red, true), false)
		cases.set_signals({ cc = o.cc2 }, { { cases.ITEM, 2000 } })
		o.r = cases.station(o, { name = cases.sname(o, "r"), x = cases.X_R[1], bits = 2 + 4 })
		cases.finish(o)
		lx.rows[#lx.rows + 1] = o
		lx.o = o
		-- Row 5: one delivery the race steps drive by hand (the operator's loading and unloading).
		local q = cases.base("LINT_RACE", { k = K0 + 4 }, { network = "signal-9" })
		q.p = cases.station(q, { name = cases.sname(q, "p"), x = cases.X_P[1], bits = 1 + 4,
			signals = cases.provide(q, 5000) })
		q.r = cases.station(q, { name = cases.sname(q, "r"), x = cases.X_R[1], bits = 2 + 4 })
		cases.finish(q)
		lx.rows[#lx.rows + 1] = q
		lx.q = q
		lab.wait_until(function() return cases.trains_ready(a) and cases.trains_ready(l) and cases.trains_ready(o) and
			cases.trains_ready(q) end, 3600, SPEED)
	end,

	function()
		local a = lx.a
		lab.check("row trains parked at their depots", cases.trains_ready(a))
		lx.check_index = {}
		for i, name in ipairs({ "capacity", "layout", "mask", "no_provider", "limit_zero", "same_item", "occupancy",
			"phantom", "depot_limit", "depot_shared_name", "refueler_mask", "never_refuelled", "in_group", "missing_stop",
			"capacity_drift" }) do
			lx.check_index[name] = i
		end
		-- Faults: unlimited depots that share a name (same depot required, bypass on), a refueler whose mask no train has,
		-- refuelling tracked for over an hour, a group, a schedule record naming no stop, a wrong cached capacity,
		-- a phantom delivery and a vanilla train bound for a Cybersyn stop.
		lx.refuel_since = read("stats", "refuel_since")
		write(game.tick - 216001, "stats", "refuel_since")
		-- Each train has its own grace from when Cybersyn first saw it (phase 6b): these were built a moment ago.
		lx.seen = {}
		for _, t in ipairs({ a.t1, a.train_entities[2] }) do
			lx.seen[t.id] = read("trains", t.id, "seen_tick")
			write(game.tick - 216001, "trains", t.id, "seen_tick")
		end
		lab.check("a new train has its own refuelling grace: seen_tick is set when Cybersyn registers it",
			lx.seen[a.t1.id] ~= nil and lx.seen[a.t1.id] > lx.refuel_since, { seen = lx.seen, since = lx.refuel_since })
		-- Manual mode keeps both trains parked and Cybersyn's (a manual switch is not a departure) while their schedules
		-- change.
		a.t1.manual_mode = true
		a.train_entities[2].manual_mode = true
		a.t3.manual_mode = true
		a.train_entities[2].group = "rc-lint-group"
		a.t3.group = "rc-lint-group"
		a.t1.get_schedule().add_record({ station = "rc-no-such-stop", wait_conditions = { { type = "time", ticks = 60 } } })
		lx.capacity = read("trains", a.t1.id, "item_slot_capacity")
		write(7, "trains", a.t1.id, "item_slot_capacity")
		write(1, "stations", a.r.id, "deliveries_total")
		lx.vanilla = vanilla_train(lx.w, cases.X_D1 + 6, lx.w.r2.name)
		local l = lx.l
		lx.small_layout = read("trains", l.t1.id, "layout_id")
		lx.big_layout = read("trains", l.t2.id, "layout_id")
		write({ [lx.small_layout] = true }, "stations", l.r.id, "accepted_layouts")
		cases.set_signals(l.r, cases.request(l, -10000, 5000))
		local o = lx.o
		cases.unfuel(o.t1)
		cases.set_signals(o.r, cases.request(o, -10000, 5000))
		-- Stop priorities: the pass reads them on every registered stop (PLAN4 D8; no event reports a change).
		lx.w.r2.stop.train_stop_priority = 49
		a.d3.stop.train_stop_priority = 60
		lab.wait(300, SPEED)
	end,

	function()
		-- A train out on a delivery is not read (its schedule is Cybersyn's own); what it had between trips is carried.
		local ot = lx.o.t1
		lx.trip_status = read("trains", ot.id, "status")
		ot.get_schedule().add_record({ station = "rc-no-such-stop-2", wait_conditions = { { type = "time", ticks = 60 } } })
		lx.first = pass()
		lab.wait(1200, SPEED)
	end,

	function()
		local a = lx.a
		local events = pass()
		for _, ev in ipairs(lx.first) do events[#events + 1] = ev end
		lx.events = events
		local d1, d2 = a.d1.id, a.d2.id
		local t1, t2 = a.t1.id, a.train_entities[2].id
		lab.check("depot limit not 1: both depots", has(d1, "depot_limit") and has(d2, "depot_limit"),
			dev("lint_bits", d1))
		lab.check("depots share a name with same-depot and bypass on: both depots",
			has(d1, "depot_shared_name") and has(d2, "depot_shared_name"), dev("lint_findings", d1))
		local f = dev("lint_findings", d1, "depot_shared_name")[1]
		lab.check("depot_shared_name detail: 2 depots, 2 trains requiring their depot", f and f.a == 2 and f.b == 2, f)
		lab.check("refueler mask matches no train", has(a.f.id, "refueler_mask"), dev("lint_findings", a.f.id))
		lab.check("never refuelled: both trains of the refueler's network", has(t1, "never_refuelled", true) and
			has(t2, "never_refuelled", true), dev("lint_bits", t1, true))
		local t3 = a.t3.id
		local g = dev("lint_findings", t3, "in_group")[1]
		lab.check("a train group spanning two depot names: both its trains, not the third",
			has(t2, "in_group", true) and has(t3, "in_group", true) and not has(t1, "in_group", true) and g ~= nil and
			g.a == 2, g)
		local m = dev("lint_findings", t1, "missing_stop")[1]
		lab.check("schedule names a missing stop (record index in the detail)", has(t1, "missing_stop", true) and
			m ~= nil and m.a == 2 and not has(t2, "missing_stop", true), m)
		local c = dev("lint_findings", t1, "capacity_drift")[1]
		lab.check("cached capacity differs from the wagons (cached 7, live 40)", c ~= nil and c.a == 7 and c.b == 40, c)
		local ph = dev("lint_findings", a.r.id, "phantom")[1]
		lab.check("phantom delivery after two passes (1 counted, 0 trains bound)", ph ~= nil and ph.a == 1 and ph.b == 0,
			dev("lint_bits", a.r.id))
		lab.check("phantom delivery with no train bound is a counter leak: the recount fix, no train named",
			ph ~= nil and ph.fix == "phantom-leak" and ph.train == nil, ph)
		local r2 = lx.w.r2
		local oc = dev("lint_findings", r2.id, "occupancy")[1]
		lab.check("occupancy gap after two passes (Cybersyn 0, the stop 1)", oc ~= nil and oc.a == 0 and oc.b == 1,
			{ bits = dev("lint_bits", r2.id), count = r2.stop.trains_count })
		lab.check("occupancy names the train Cybersyn did not send", oc ~= nil and oc.train == lx.vanilla.id,
			{ finding = oc, vanilla = lx.vanilla.id })
		local pr = dev("lint_findings", r2.id, "priority")[1]
		local pd = dev("lint_findings", a.d3.id, "priority")[1]
		lab.check("priority not 50: a station and a depot, with the priority in the detail",
			pr ~= nil and pr.a == 49 and pr.subject == "station" and pd ~= nil and pd.a == 60 and pd.subject == "depot",
			{ station = pr, depot = pd })
		lab.check("no phantom on the occupancy stop and no gap on the phantom stop",
			not has(r2.id, "phantom") and not has(a.r.id, "occupancy"))
		lab.check("st.lint of the phantom stop is its lint mask", dev("lint_bits", a.r.id).st_lint ==
			dev("lint_bits", a.r.id).mask)

		local l = lx.l
		local e = dev("diag_unserved", l.r.id)[cases.ITEM] or {}
		lab.check("capacity vs layout: two layouts with 40 and 80 slots", lx.small_layout ~= lx.big_layout and
			read("trains", l.t2.id, "item_slot_capacity") == 80, { lx.small_layout, lx.big_layout })
		lab.check("capacity vs layout: the dispatcher records R_LAYOUT", e.reason == "R_LAYOUT" or e.pending == "R_LAYOUT", e)
		local lf = dev("lint_findings", l.r.id, "layout")[1]
		-- b counts the layouts the allow list keeps out that would carry the request (phase 6b: no longer the trains).
		lab.check("capacity vs layout: the lint says layout (1 layout accepted, 1 rejected layout carries it), not capacity",
			lf ~= nil and lf.a == 1 and lf.b == 1 and lf.predicts == "R_LAYOUT" and not has(l.r.id, "capacity"),
			dev("lint_bits", l.r.id))

		local o = lx.o
		local ot = read("trains", o.t1.id) or {}
		lab.check("provider item threshold: the 50-stack request is dispatched to the 40-slot train",
			ot.status == 1 and ot.r_station_id == o.r.id and ot.p_station_id == o.p.id,
			{ status = ot.status, r = ot.r_station_id, p = ot.p_station_id })
		lab.check("provider item threshold: the snapshot keeps the provider's 2,000",
			(dev("provider_overrides")["signal-5:" .. cases.ITEM]) == 2000, dev("provider_overrides"))
		lab.check("provider item threshold: no capacity finding on the requester", not has(o.r.id, "capacity"),
			dev("lint_bits", o.r.id))
		lab.check("a train on a delivery: a record added on the way is not read until it is back",
			lx.trip_status == 1 and not has(o.t1.id, "missing_stop", true), { status = lx.trip_status,
			bits = dev("lint_bits", o.t1.id, true) })
		local count = o.p.stop.trains_count
		lab.info("a dispatched train routed through its rail record: provider trains_count " .. tostring(count))
		lab.check("delivery in flight across two passes: no occupancy or phantom finding on either end",
			not has(o.p.id, "occupancy") and not has(o.r.id, "occupancy") and not has(o.p.id, "phantom") and
			not has(o.r.id, "phantom"), { p = dev("lint_bits", o.p.id), r = dev("lint_bits", o.r.id), count = count })
		local appeared = transition(events, d1, "depot_limit", true)
		lab.check("lint event when a finding appears (a = check, b = subject)", appeared ~= nil and appeared.station == d1,
			appeared)

		if lab.problems_verify then lab.problems_verify("39_lint rows") end

		-- No network bit (PLAN4 D6): mask 0 on a network that has trains, a warning; nothing for a mask no provider of
		-- the item shares (the MASK_MISMATCH row of 40_reason_codes asserts that side).
		local lp = l.p.id
		lx.l_mask = read("stations", lp, "network_mask")
		write(0, "stations", lp, "network_mask")
		dev("collect")
		dev("lint_run")
		local mf = dev("lint_findings", lp, "mask")[1]
		if lab.problems_verify then lab.problems_verify("39_lint mask 0") end
		write(lx.l_mask, "stations", lp, "network_mask")
		lab.check("mask 0 on a network with trains: one mask finding, a = 0, on the network", mf ~= nil and mf.a == 0 and
			mf.network == "signal-6", { finding = mf, mask = lx.l_mask })

		-- Fix them: each finding clears with its own event.
		a.d1.stop.trains_limit = 1
		a.train_entities[2].group = ""
		a.t3.group = ""
		local sched = a.t1.get_schedule()
		sched.remove_record({ schedule_index = sched.get_record_count() })
		a.t1.manual_mode = false
		a.train_entities[2].manual_mode = false
		write(0, "stations", a.r.id, "deliveries_total")
		lx.w.r2.stop.train_stop_priority = 50
		a.d3.stop.train_stop_priority = 50
		write(lx.refuel_since, "stats", "refuel_since")
		for id, seen in pairs(lx.seen) do write(seen, "trains", id, "seen_tick") end
		game.get_player(1).admin = true
		dev("run_command", "cybersyn-recalculate-train-size", 1)
		game.get_player(1).admin = false
		lx.cleared = pass()
	end,

	function()
		local a = lx.a
		local d1, t1, t2 = a.d1.id, a.t1.id, a.train_entities[2].id
		lab.check("cleared: depot limit 1", not has(d1, "depot_limit") and has(a.d2.id, "depot_limit"))
		lab.check("cleared: group, missing stop, drift, never refuelled", not has(t2, "in_group", true) and
			not has(t1, "missing_stop", true) and not has(t1, "capacity_drift", true) and
			not has(t1, "never_refuelled", true), { t1 = dev("lint_bits", t1, true), t2 = dev("lint_bits", t2, true) })
		lab.check("cleared: phantom", not has(a.r.id, "phantom"))
		lab.check("cleared: priority back at 50, and the mask restored", not has(lx.w.r2.id, "priority") and
			not has(a.d3.id, "priority") and not has(lx.l.p.id, "mask"))
		lab.check("capacity restored by the recalculation", read("trains", t1, "item_slot_capacity") == lx.capacity)
		local ev = transition(lx.cleared, d1, "depot_limit", false)
		lab.check("lint event when a finding clears", ev ~= nil and ev.sev == "info", ev)
		local drift = transition(lx.cleared, t1, "capacity_drift", false)
		lab.check("lint event of a train carries the train", drift ~= nil and drift.train == t1, drift)

		-- The job runs on the manager tick only while a window is open.
		dev("open", 1)
		lab.wait_until(function() return dev("lint_state").running ~= nil end, 1200, 1)
	end,

	function()
		lx.closing = dev("lint_state")
		dev("close", 1)
		lx.closed_pass = dev("lint_state").pass
		lab.wait(600, 1)
	end,

	function()
		lab.check("lint job: no pass while every window is closed", dev("lint_state").pass == lx.closed_pass,
			dev("lint_state"))
		lab.check("lint job: a pass in progress is dropped when the last window closes", lx.closing.running ~= nil and
			dev("lint_state").running == nil, { closing = lx.closing, now = dev("lint_state") })
		dev("open", 1)
		lx.open_pass = dev("lint_state").pass
		lab.wait_until(function() return dev("lint_state").pass > lx.open_pass end, 3600, 20)
	end,

	function()
		local st = dev("lint_state")
		lab.check("lint job: passes on the manager tick while a window is open", st.pass > lx.open_pass, st)
		lab.info("lint pass on layout-dev: " .. tostring(st.updates) .. " updates, " .. tostring(st.findings) ..
			" findings")
		dev("close", 1)

		-- The setup registry (PLAN4 D8): every row-W problem was recorded when it was built, one finding each.
		local w = lx.world
		lx.reg_before = dev("lint_state").registry
		lab.check("registry: derelict combinator, one finding on the combinator", only(w.derelict, "derelict-combinator") and
			registry(w.derelict)[1].subject == "combinator", registry(w.derelict))
		lab.check("registry: ghost combinator at an unregistered stop, one finding on the stop",
			only(w.ghost_stop, "ghost-combinator"), registry(w.ghost_stop))
		lab.check("registry: combinator facing away from its stop, one finding on the combinator, none on the stop",
			only(w.wrong, "wrong-side-combinator") and only(w.wrong_stop, nil), { comb = registry(w.wrong),
			stop = registry(w.wrong_stop) })
		lab.check("registry: stop with only a control combinator", only(w.nocomb_stop, "stop-no-combinator"),
			registry(w.nocomb_stop))
		lab.check("registry: two station combinators at one stop", only(w.double_stop, "double-station") and
			only(w.first, nil) and only(w.second, nil), registry(w.double_stop))
		lab.check("registry: a plain stop sharing a depot's name, not the depot", only(w.overlap_stop,
			"name-overlap-with-depot") and only(lx.w.d1.stop, nil), registry(w.overlap_stop))
		local by_unit = {}
		for _, f in ipairs(dev("lint_findings")) do
			if f.message then by_unit[f.id .. f.message] = true end
		end
		lab.check("registry: lint.findings() carries the registry findings after the pass's",
			by_unit[w.derelict.unit_number .. "derelict-combinator"] and by_unit[w.double_stop.unit_number .. "double-station"],
			by_unit)
		-- The seed (fork schema 3) builds the same registry from Cybersyn's tables as the handlers did.
		local function keys()
			local out = {}
			for _, f in ipairs(dev("lint_registry")) do out[#out + 1] = f.id .. ":" .. f.check .. ":" .. f.message end
			table.sort(out)
			return out
		end
		local live = keys()
		local seed = dev("lint_registry_seed")
		rcon.print({ "", "INFO 39_lint: registry seed on layout-dev plus the rows: ", seed.ms, " (", seed.entries,
			" entries, ", seed.orphans, " orphan combinators, ", seed.ghosts, " ghosts, ", seed.names, " depot names)" })
		lab.check("registry: a fresh seed holds exactly what the build handlers recorded", lab.same_list(live, keys()),
			{ handlers = live, seed = keys() })
		-- /cybersyn-find-problems prints the registry and the registered stops at a non-default priority.
		lab.check("/cybersyn-find-problems: one line per registry finding", dev("lint_report", 1) == #live,
			{ lines = dev("lint_report", 1), registry = #live })
		dev("run_command", "cybersyn-find-problems", 1)
		lx.w.r2.stop.train_stop_priority = 30
		lab.check("/cybersyn-find-problems: and one per registered stop at a non-default priority",
			dev("lint_report", 1) == #live + 1, dev("lint_report", 1))
		lx.w.r2.stop.train_stop_priority = 50
		if lab.problems_verify then lab.problems_verify("39_lint registry") end

		-- The Stations Problems view lists them once each, after every station row, linked to the entity: shift shows
		-- the derelict combinator, the stop the ghost waits at and the combinator facing away on the map.
		dev("open", 1)
		dev("clear_filters", 1)
		lab.big_screen(1)
		dev("collect")
		remote.call("cybersyn-manager-dev-stations", "set_chip", 1, "problems")
		dev("select_tab", 1, "stations")
		local d = dev("dump", 1, "stations")
		for _, c in ipairs({ { "derelict combinator", w.derelict, "derelict-combinator" },
			{ "ghost combinator", w.ghost_stop, "ghost-combinator" },
			{ "wrong-side combinator", w.wrong, "wrong-side-combinator" } }) do
			local label, entity, message = c[1], c[2], c[3]
			local suffix = ":" .. entity.unit_number .. ":" .. message
			local rows = {}
			for _, r in ipairs(d.registry) do
				if r.key:sub(-#suffix) == suffix then rows[#rows + 1] = r end
			end
			local r = rows[1]
			lab.check("Stations Problems view: the " .. label .. " is one registry row after the stations, linked to it",
				#rows == 1 and d.registry_last and r.link[1] == "entity" and r.link[2] == entity.unit_number,
				{ rows = rows, last = d.registry_last })
			local res = r and dev("link_click", 1, r.link[1], r.link[2], { shift = true })
			lab.check("Stations Problems view: the " .. label .. "'s link shows it on the map", res ~= nil
				and res.controller == defines.controllers.remote and res.markers ~= nil and #res.markers == 2, res)
			local player = game.get_player(1)
			if player.controller_type == defines.controllers.remote then player.exit_remote_view() end
		end
		remote.call("cybersyn-manager-dev-stations", "set_chip", 1, "all")
		dev("close", 1)

		-- Fixed in the world: each finding goes with the event that fixed it. A turn by 90° changes which stop a
		-- combinator reaches (the engine allows it in place only to scripts; see dev raise_rotated).
		local player = game.get_player(1)
		w.wrong.direction = defines.direction.north
		dev("raise_rotated", w.wrong, 1, defines.direction.east)
		lab.check("registry: turning the combinator to face its stop registers the station and drops the finding",
			read("to_stop", w.wrong.unit_number) == w.wrong_stop and read("stations", w.wrong_stop.unit_number) ~= nil and
			only(w.wrong, nil) and only(w.wrong_stop, nil), { comb = registry(w.wrong), stop = registry(w.wrong_stop) })
		-- A player's R on a placed combinator flips it 180°: the same reach, so the station is not rebuilt.
		write(true, "stations", w.wrong_stop.unit_number, "lab_marker")
		lx.flipped = w.wrong.rotate({ by_player = player })
		lab.check("registry: a player's flip keeps the reach and the very same station record", lx.flipped and
			w.wrong.direction == defines.direction.south and read("stations", w.wrong_stop.unit_number, "lab_marker") and
			only(w.wrong, nil), { flipped = lx.flipped, dir = w.wrong.direction })
		w.wrong.direction = defines.direction.east
		dev("raise_rotated", w.wrong, 1, defines.direction.south)
		lab.check("registry: turning it away again unregisters the station and records one wrong-side finding",
			read("to_stop", w.wrong.unit_number) == nil and read("stations", w.wrong_stop.unit_number) == nil and
			only(w.wrong, "wrong-side-combinator") and only(w.wrong_stop, nil), registry(w.wrong))
		-- Removing the stop it faces away from leaves it no stop's at all: derelict, as a fresh seed says.
		w.wrong_stop.destroy({ raise_destroy = true })
		lab.check("registry: removing the stop a wrong-side combinator faces away from makes it derelict",
			only(w.wrong, "derelict-combinator"), registry(w.wrong))
		lab.check("registry: the seed agrees after the stop's removal", (function()
			local now = keys()
			dev("lint_registry_seed")
			return lab.same_list(now, keys())
		end)())
		local derelict_unit = w.derelict.unit_number
		w.derelict.destroy({ raise_destroy = true })
		lab.check("registry: removing the derelict combinator drops its finding",
			#dev("lint_registry", derelict_unit) == 0)
		w.control.destroy({ raise_destroy = true })
		lab.check("registry: removing the control combinator drops the stop's finding", only(w.nocomb_stop, nil),
			registry(w.nocomb_stop))
		w.second.destroy({ raise_destroy = true })
		lab.check("registry: removing the second station combinator drops the doubled finding, the station stays",
			only(w.double_stop, nil) and read("stations", w.double_stop.unit_number) ~= nil, registry(w.double_stop))
		local _, revived = w.ghost.revive({ raise_revive = true })
		if revived then lx.w.entities[#lx.w.entities + 1] = revived end
		lab.check("registry: building the ghost registers the stop and drops its finding", revived ~= nil and
			read("stations", w.ghost_stop.unit_number) ~= nil and only(w.ghost_stop, nil) and
			(revived == nil or only(revived, nil)), registry(w.ghost_stop))
		w.overlap_stop.backer_name = "rc-LINT_W-renamed"
		lab.check("registry: renaming the stop away from the depot's name drops the overlap", only(w.overlap_stop, nil),
			registry(w.overlap_stop))
		w.overlap_stop.backer_name = lx.w.d1.name
		lab.check("registry: renaming it back records the overlap again", only(w.overlap_stop, "name-overlap-with-depot"),
			registry(w.overlap_stop))
		w.overlap_stop.destroy({ raise_destroy = true })
		lab.check("registry: removing the stop drops it", dev("lint_state").registry == lx.reg_before - 5,
			{ before = lx.reg_before, now = dev("lint_state").registry })
		lab.check("registry: the seed agrees after the fixes", (function()
			local now = keys()
			dev("lint_registry_seed")
			return lab.same_list(now, keys())
		end)())

		-- The race of an incremental pass (PLAN4 D10): the provider's delivery leaves between the pass's index and
		-- the provider's turn. Before the fix the counter was read live at the turn and the index at the start.
		local q = lx.q
		cases.set_signals(q.r, cases.request(q, -2000, 1000))
		lab.wait_until(function()
			local t = read("trains", q.t1.id)
			return t and t.status == 2 and q.t1.state == defines.train_state.wait_station
		end, 7200, SPEED)
	end,

	function()
		local q = lx.q
		local t = read("trains", q.t1.id) or {}
		lab.check("race: the train is loading at the provider, its delivery counted",
			t.status == 2 and read("stations", q.p.id, "deliveries_total") == 1, { status = t.status })
		dev("collect")
		dev("lint_reset_job")
		dev("lint_step", 1, 0, 0)
		local st = dev("lint_state")
		lx.race_pass = st.pass
		lab.check("race: a pass is set up (index taken) and has checked no station yet", st.running ~= nil and
			st.running.i == 0, st)
		for _, m in ipairs(t.manifest or {}) do q.t1.insert({ name = m.name, count = m.count, quality = m.quality }) end
		lab.wait_until(function() return (read("trains", q.t1.id) or {}).status == 3 end, 3600, 10)
	end,

	function()
		local q = lx.q
		lab.check("race: the train left the provider during the pass, its counter is 0 now",
			(read("trains", q.t1.id) or {}).status == 3 and read("stations", q.p.id, "deliveries_total") == 0)
		dev("lint_finish")
		local gaps = dev("lint_gaps")
		lab.check("race: the pass completed", dev("lint_state").pass == lx.race_pass + 1, dev("lint_state"))
		-- The provider's live counter against the pass's older index is only a sighting; the next pass decides it on
		-- the counter read with its own index.
		lx.race_sighted = lab.set_of(gaps.phantom)[q.p.id] == true
		lab.info("race: provider gap sighted on the first pass: " .. tostring(lx.race_sighted))
		lab.check("race: no phantom finding at the provider or the requester after the provider's race",
			not has(q.p.id, "phantom") and not has(q.r.id, "phantom"), gaps)
		lab.wait_until(function()
			local t = read("trains", q.t1.id)
			return t and t.status == 4 and q.t1.state == defines.train_state.wait_station
		end, 7200, SPEED)
	end,

	function()
		-- The same race at the requester, on the next pass: the train unloads and leaves between index and turn.
		local q = lx.q
		lab.check("race: the train is unloading at the requester, its delivery counted",
			(read("trains", q.t1.id) or {}).status == 4 and read("stations", q.r.id, "deliveries_total") == 1)
		dev("collect")
		dev("lint_reset_job")
		dev("lint_step", 1, 0, 0)
		cases.set_signals(q.r, {})
		q.t1.clear_items_inside()
		-- The line is a dead end east of the requester: the control case's operator sends the train round its end.
		q.line_end = q.surface.find_entities_filtered({ name = "straight-rail", position = { cases.X_MAX + 1, q.y + 1 } })[1]
		lab.wait_until(function()
			cases.operate(q)
			return (read("trains", q.t1.id) or {}).status ~= 4
		end, 3600, 10)
	end,

	function()
		local q = lx.q
		local t = read("trains", q.t1.id) or {}
		lab.check("race: the train left the requester during the pass", t.status ~= 4 and
			read("stations", q.r.id, "deliveries_total") == 0, { status = t.status, state = q.t1.state,
			deliveries = read("stations", q.r.id, "deliveries_total") })
		-- A sighted station is decided on the counter read with the index: a counter that differs by the station's
		-- turn (written here for the length of this one synchronous finish) changes nothing. Read live at the turn,
		-- it would confirm the provider's sighting from the last pass as a finding.
		local p_total = read("stations", q.p.id, "deliveries_total")
		write(7, "stations", q.p.id, "deliveries_total")
		dev("lint_finish")
		write(p_total, "stations", q.p.id, "deliveries_total")
		local gaps = dev("lint_gaps")
		lab.check("race: the provider's sighting is decided on the counter read with the index: cleared, no finding",
			not lab.set_of(gaps.phantom)[q.p.id] and not has(q.p.id, "phantom"), { gaps = gaps, sighted = lx.race_sighted })
		-- One more pass decides the requester's sighting the same way.
		dev("lint_run")
		gaps = dev("lint_gaps")
		lab.check("race: no phantom gap at either end after the pass that decides the sightings",
			not lab.set_of(gaps.phantom)[q.p.id] and not lab.set_of(gaps.phantom)[q.r.id], gaps)
		lab.check("race: no phantom or occupancy finding on the row", not has(q.p.id, "phantom") and
			not has(q.r.id, "phantom") and not has(q.p.id, "occupancy") and not has(q.r.id, "occupancy"),
			{ p = dev("lint_bits", q.p.id), r = dev("lint_bits", q.r.id) })

		for _, case in ipairs(lx.rows) do
			local ok, err = pcall(case.cleanup)
			if not ok then lab.check(case.name .. ": cleanup", false, err) end
		end
		if lx.setting then dev("set_setting", "cybersyn-diagnostics", lx.setting) end
		lab.wait(600, SPEED)
	end,

	function()
		local left = game.surfaces[cases.SURFACE].count_entities_filtered({
			area = { { cases.X_MIN - 260, cases.Y0 + cases.ROW * K0 - 64 },
				{ cases.X_MAX + 64, cases.Y0 + cases.ROW * (K0 + #lx.rows) + 64 } },
		})
		lab.check("cleanup: no entity left on the lint rows", left == 0, left)
		local n = table_size((read("stations")))
		lab.check("cleanup: 30 stations again", n == 30, n)
		dev("lint_run")
		local stale = 0
		for _, f in ipairs(dev("lint_findings")) do
			if not f.message and f.subject ~= "train" and not (read("stations", f.id) or read("depots", f.id) or
				read("refuelers", f.id)) then
				stale = stale + 1
			end
		end
		lab.check("cleanup: no lint finding left for a removed stop", stale == 0, stale)
		lab.check("cleanup: the registry is back to the save's own findings", dev("lint_state").registry == lx.reg_start,
			{ start = lx.reg_start, now = dev("lint_registry") })
	end,
})
