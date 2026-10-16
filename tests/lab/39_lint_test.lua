-- Phase 2b setup lint (PLAN3 §4.12): every check without a reason code of its own, each built on a row of its own
-- and asserted through the dev API (lint_run, lint_bits, lint_findings), with the `lint` log event of each
-- transition; the job running only while a window is open; and the world scan, synchronously and through the
-- /cybersyn-find-problems command's chunked job, finding the derelicts built for it.
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
		-- Row 2: the world-scan derelicts.
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
		-- A plain stop that shares the depot's name, and one with a station's name at a non-default priority.
		local overlap_stop = bare_stop(w, 40, w.d1.name)
		local priority_stop = bare_stop(w, 20, w.r2.name)
		priority_stop.train_stop_priority = 49
		lx.world = { derelict = derelict, ghost_stop = ghost_stop, ghost = ghost, wrong_stop = wrong_stop, wrong = wrong,
			nocomb_stop = nocomb_stop, control = control, double_stop = double_stop, first = first, second = second,
			overlap_stop = overlap_stop, priority_stop = priority_stop }
		lab.check("world rows: the wrong-side combinator is not adopted by its stop",
			read("to_stop", wrong.unit_number) == nil)
		lab.check("world rows: the control-only stop and the double stop own their combinators",
			read("to_stop", control.unit_number) == nocomb_stop and read("to_stop", first.unit_number) == double_stop and
			read("to_stop", second.unit_number) == double_stop)
		lab.check("world rows: none of the four stops is registered with Cybersyn",
			read("stations", ghost_stop.unit_number) == nil and read("stations", wrong_stop.unit_number) == nil and
			read("stations", nocomb_stop.unit_number) == nil)
		lab.wait_until(function() return cases.trains_ready(a) end, 3600, SPEED)
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
		lab.wait(300, SPEED)
	end,

	function()
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
		local r2 = lx.w.r2
		local oc = dev("lint_findings", r2.id, "occupancy")[1]
		lab.check("occupancy gap after two passes (Cybersyn 0, the stop 1)", oc ~= nil and oc.a == 0 and oc.b == 1,
			{ bits = dev("lint_bits", r2.id), count = r2.stop.trains_count })
		lab.check("no phantom on the occupancy stop and no gap on the phantom stop",
			not has(r2.id, "phantom") and not has(a.r.id, "occupancy"))
		lab.check("st.lint of the phantom stop is its lint mask", dev("lint_bits", a.r.id).st_lint ==
			dev("lint_bits", a.r.id).mask)
		local appeared = transition(events, d1, "depot_limit", true)
		lab.check("lint event when a finding appears (a = check, b = subject)", appeared ~= nil and appeared.station == d1,
			appeared)

		-- Fix them: each finding clears with its own event.
		a.d1.stop.trains_limit = 1
		a.train_entities[2].group = ""
		a.t3.group = ""
		local sched = a.t1.get_schedule()
		sched.remove_record({ schedule_index = sched.get_record_count() })
		a.t1.manual_mode = false
		a.train_entities[2].manual_mode = false
		write(0, "stations", a.r.id, "deliveries_total")
		write(lx.refuel_since, "stats", "refuel_since")
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
		lab.check("capacity restored by the recalculation", read("trains", t1, "item_slot_capacity") == lx.capacity)
		local ev = transition(lx.cleared, d1, "depot_limit", false)
		lab.check("lint event when a finding clears", ev ~= nil and ev.sev == "info", ev)
		local drift = transition(lx.cleared, t1, "capacity_drift", false)
		lab.check("lint event of a train carries the train", drift ~= nil and drift.train == t1, drift)

		-- The job runs on the manager tick only while a window is open.
		local before = dev("lint_state").pass
		dev("close", 1)
		lx.closed_pass = before
		lab.wait(600, 1)
	end,

	function()
		lab.check("lint job: no pass while every window is closed", dev("lint_state").pass == lx.closed_pass,
			dev("lint_state"))
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

		-- World scan (B8), synchronously.
		local w = lx.world
		local found = {}
		for _, f in ipairs(dev("lint_scan_world", nil, false)) do
			found[f.id] = found[f.id] or {}
			found[f.id][#found[f.id] + 1] = f.message
		end
		lx.sync = found
		local function says(entity, message)
			for _, m in ipairs(found[entity.unit_number] or {}) do
				if m == message then return true end
			end
			return false
		end
		lab.check("world scan: derelict combinator", says(w.derelict, "derelict-combinator"), found[w.derelict.unit_number])
		lab.check("world scan: ghost combinator at an unregistered stop", says(w.ghost_stop, "ghost-combinator"))
		lab.check("world scan: combinator facing away from its stop", says(w.wrong_stop, "wrong-side-combinator") and
			not says(w.wrong, "derelict-combinator"))
		lab.check("world scan: stop with only a control combinator", says(w.nocomb_stop, "stop-no-combinator"))
		lab.check("world scan: two station combinators at one stop", says(w.double_stop, "double-station"))
		lab.check("world scan: a plain stop sharing a depot's name", says(w.overlap_stop, "name-overlap-with-depot"))
		lab.check("world scan: a non-default priority on a stop named like a station",
			says(w.priority_stop, "non-default-priority"))
		local n = 0
		for _ in pairs(found) do n = n + 1 end
		lab.info("world scan: " .. n .. " subjects with findings on layout-dev plus the rows")

		-- The command starts the same scan as a chunked job on the manager tick (no window needed).
		dev("run_command", "cybersyn-find-problems", 1)
		lab.check("/cybersyn-find-problems starts the chunked scan", dev("lint_state").world_running == true)
		lab.wait_until(function() return dev("lint_state").world_running == false end, 36000, 50)
	end,

	function()
		local st = dev("lint_state")
		lab.check("/cybersyn-find-problems: the chunked scan completes with the windows closed",
			st.world_running == false and st.world_tick ~= nil, st)
		local n = 0
		for _ in pairs(lx.sync) do n = n + 1 end
		local async = {}
		for _, f in ipairs(dev("lint_scan_world", nil, false)) do async[f.id] = true end
		local same = st.world_findings ~= nil
		for id in pairs(lx.sync) do if not async[id] then same = false end end
		lab.check("/cybersyn-find-problems: the same findings as the synchronous scan", same, st)

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
			if f.subject ~= "train" and not (read("stations", f.id) or read("depots", f.id) or read("refuelers", f.id)) then
				stale = stale + 1
			end
		end
		lab.check("cleanup: no lint finding left for a removed stop", stale == 0, stale)
	end,
})
