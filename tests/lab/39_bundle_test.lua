-- Phase 2b dispatcher-adjacent bundle (PLAN3 §4.4, §4.5, §4.14): cargo anomalies at the provider and requester
-- departures (items and the fluid tolerance boundary), refuel_tick at a refueler, schedule_edited, the planner-cycle
-- counters, the per-(item, network) no-train alert (B6) and the permission gate on the three console commands (B7).
--
-- Rows k = 30.. on cyb-bench (cases.lua's builders), torn down at the end. An operator in on_tick stands in for
-- inserters and pumps: it loads at the provider and unloads at the requester as each scenario says, and makes a
-- train leave when the scenario wants it to leave short or with cargo aboard (Cybersyn's wait conditions would hold
-- it), and sends trains round the east end of the dead-end line as dispatch_trace.lua does.

local DEV = "cybersyn-manager-dev"
local SPEED = 50
local K0 = 30
local TIMEOUT = 9000

local function dev(fn, ...)
	return remote.call(DEV, fn, ...)
end

local function read(...)
	return remote.call("cybersyn", "read_global", ...)
end

local bx = {
	list = {},
	errors = {},
	inits = {},
	dispatches = 0,
	cycle_samples = {},
}
lab.bx = bx

local STATUS_D, STATUS_TO_P, STATUS_P, STATUS_R, STATUS_TO_F, STATUS_F = 0, 1, 2, 4, 7, 8

-- ---- scenarios ------------------------------------------------------------------------------------------------

--- A provider, a requester and one train on its own row; `load`/`unload` are what the operator does.
local function delivery_row(name, k, network, opt)
	local case = cases.base(name, { k = k }, { network = network, wagon = opt.wagon })
	case.item = opt.item or cases.ITEM
	case.p = cases.station(case, { name = cases.sname(case, "p"), x = cases.X_P[1], bits = 1 + 4,
		signals = { { case.item, opt.provide or 5000 } } })
	case.r = cases.station(case, { name = cases.sname(case, "r"), x = cases.X_R[1], bits = 2 + 4 })
	case.r_station, case.p_station = case.r.id, case.p.id
	case.request = opt.request
	case.load, case.unload = opt.load, opt.unload
	case.expect, case.absent = opt.expect, opt.absent
	case.line_end = case.surface.find_entities_filtered({ name = "straight-rail",
		position = { cases.X_MAX + 1, case.y + 1 } })[1]
	cases.finish(case)
	return case
end

--- Inserts `n` of each manifest entry (items or fluid).
local function put(t, manifest, scale, extra)
	for _, m in ipairs(manifest) do
		local n = math.floor(m.count * scale + 0.5)
		if m.type == "fluid" then
			-- LuaTrain.insert_fluid inserts nothing into these trains; the wagon's own box takes it.
			t.fluid_wagons[1].set_fluid(1, { name = m.name, amount = n })
		else
			t.insert({ name = m.name, count = n, quality = m.quality })
		end
	end
	if extra then t.insert(extra) end
end

--- Leaves `keep` of the manifest's first entry aboard.
local function empty_but(t, manifest, keep)
	local m = manifest[1]
	if m.type == "fluid" then
		t.fluid_wagons[1].set_fluid(1, keep > 0 and { name = m.name, amount = keep } or nil)
	else
		t.clear_items_inside()
		if keep > 0 then t.insert({ name = m.name, count = keep }) end
	end
end

local function leave(t)
	local schedule = t.get_schedule()
	local n = schedule.get_record_count()
	if n > 0 then schedule.go_to_station(schedule.current % n + 1) end
end

local function build()
	local list = bx.list
	local k = K0
	local function add(case) list[#list + 1] = case; k = k + 1 end
	-- Items: 100 short at the provider.
	add(delivery_row("CARGO_SHORT", k, "signal-0", {
		request = cases.request({ item = cases.ITEM }, -2000, 1000),
		load = function(c, t, m) put(t, m, 1, nil); t.remove_item({ name = m[1].name, count = 100 }); leave(t) end,
		unload = function(c, t, m) t.clear_items_inside() end,
		expect = { { kind = "short_load", at = "p", a = 2000, b = 1900, item = "iron-plate" } },
		absent = { "unexpected_cargo", "residual_cargo" },
	}))
	-- Items: a second item nobody ordered.
	add(delivery_row("CARGO_EXTRA", k, "signal-1", {
		request = cases.request({ item = cases.ITEM }, -2000, 1000),
		load = function(c, t, m) put(t, m, 1, { name = "copper-plate", count = 50 }) end,
		unload = function(c, t, m) t.clear_items_inside() end,
		expect = { { kind = "unexpected_cargo", at = "p", a = 0, b = 50, item = "copper-plate" } },
		absent = { "short_load", "residual_cargo" },
	}))
	-- Items: 30 left aboard at the requester.
	add(delivery_row("CARGO_RESIDUE", k, "signal-2", {
		request = cases.request({ item = cases.ITEM }, -2000, 1000),
		load = function(c, t, m) put(t, m, 1, nil) end,
		unload = function(c, t, m) empty_but(t, m, 30); leave(t) end,
		expect = { { kind = "residual_cargo", at = "r", a = 2000, b = 30, item = "iron-plate" } },
		absent = { "short_load", "unexpected_cargo" },
	}))
	-- Fluid inside the 2 % tolerance at both ends: 1.5 % short, 1 % left.
	add(delivery_row("FLUID_OK", k, "signal-3", {
		wagon = "fluid-wagon", item = "water", provide = 20000,
		request = { { "water", -10000 }, { "cybersyn-fluid-request-threshold", 1000, "virtual" } },
		load = function(c, t, m) put(t, m, 0.985, nil); leave(t) end,
		unload = function(c, t, m) empty_but(t, m, 100); leave(t) end,
		expect = {},
		absent = { "short_load", "unexpected_cargo", "residual_cargo" },
	}))
	-- Fluid beyond it: 3 % short, 3 % left.
	add(delivery_row("FLUID_BAD", k, "signal-4", {
		wagon = "fluid-wagon", item = "water", provide = 20000,
		request = { { "water", -10000 }, { "cybersyn-fluid-request-threshold", 1000, "virtual" } },
		load = function(c, t, m) put(t, m, 0.97, nil); leave(t) end,
		unload = function(c, t, m) empty_but(t, m, 300); leave(t) end,
		expect = {
			{ kind = "short_load", at = "p", a = 10000, b = 9700, item = "water" },
			{ kind = "residual_cargo", at = "r", a = 10000, b = 300, item = "water" },
		},
		absent = { "unexpected_cargo" },
	}))
	for _, case in ipairs(list) do case.kind = "cargo" end
	-- A refueler on the row: the test trains carry a third of a fuel inventory, under the 0.5 fuel threshold.
	local rf = delivery_row("REFUEL", k, "signal-5", {
		request = cases.request({ item = cases.ITEM }, -2000, 1000),
		load = function(c, t, m) put(t, m, 1, nil) end,
		unload = function(c, t, m) t.clear_items_inside() end,
		expect = {},
		absent = { "short_load", "unexpected_cargo", "residual_cargo" },
	})
	rf.kind = "refuel"
	rf.f = cases.station(rf, { name = cases.sname(rf, "f"), x = cases.X_P[3], mode = ">>", bits = 4 })
	cases.promote({ rf.f.id })
	add(rf)
	-- B6: two requesters of one item, no train on the network.
	local ab = cases.base("ALERT_DEDUPE", { k = k }, { network = "signal-6", no_train = true })
	ab.p = cases.station(ab, { name = cases.sname(ab, "p"), x = cases.X_P[1], bits = 1 + 4,
		signals = { { cases.ITEM, 5000 } } })
	ab.a = cases.station(ab, { name = cases.sname(ab, "a"), x = cases.X_R[1], bits = 2 + 4 })
	ab.b = cases.station(ab, { name = cases.sname(ab, "b"), x = cases.X_R[2], bits = 2 + 4 })
	cases.finish(ab)
	ab.kind = "dedupe"
	ab.key = "signal-6:" .. cases.ITEM
	add(ab)
	for _, case in ipairs(list) do
		case.phase = "staging"
		case.res = {}
		case.start_tick = game.tick
	end
end

-- ---- the operator and the stages, inside the game tick -----------------------------------------------------------

local function custom_alerts(stop)
	if not (stop and stop.valid) then return -1 end
	local n = 0
	for _, by_type in pairs(game.get_player(1).get_alerts({ entity = stop, type = defines.alert_type.custom })) do
		for _, list in pairs(by_type) do n = n + #list end
	end
	return n
end

local function operate(case)
	local t = case.t1
	if not (t and t.valid) then return end
	local ct = read("trains", t.id)
	if not ct then return end
	local res = case.res
	if case.kind == "refuel" and not res.refuel_tick and ct.refuel_tick then
		res.refuel_tick = ct.refuel_tick
		res.refuel_status = ct.status
		res.refuel_at = game.tick
	end
	if t.state == defines.train_state.no_path and case.line_end then
		local schedule = t.get_schedule()
		local current = schedule.current
		local record = schedule.get_record({ schedule_index = current })
		local rail = case.line_end
		if record and rail.valid and record.rail ~= rail and case.turned ~= ct.status then
			case.turned = ct.status
			schedule.add_record({ rail = rail, rail_direction = defines.rail_direction.front, temporary = true,
				wait_conditions = { { type = "time", ticks = 1 } }, index = { schedule_index = current } })
			schedule.go_to_station(current)
		end
		return
	end
	if not (t.state == defines.train_state.wait_station and t.station) then return end
	if ct.status == STATUS_P and ct.manifest and not case.loaded then
		case.loaded = true
		res.manifest = ct.manifest
		res.p_seq = res.p_seq or dev("diag_state").seq
		case.load(case, t, ct.manifest)
	elseif ct.status == STATUS_R and case.loaded and not case.unloaded then
		case.unloaded = true
		res.r_seq = dev("diag_state").seq
		case.unload(case, t, ct.manifest)
		cases.set_signals(case.r, {})
	end
end

local function cargo_tick(case)
	local res = case.res
	if case.phase == "staging" then
		if cases.trains_ready(case) then
			res.seq0 = dev("diag_state").seq
			cases.set_signals(case.r, case.request)
			case.phase = "running"
		end
	elseif case.phase == "running" then
		operate(case)
		local ct = case.t1.valid and read("trains", case.t1.id)
		local done
		if case.kind == "refuel" then
			done = res.refuel_tick ~= nil
		else
			done = case.unloaded and (not ct or ct.status == STATUS_D or ct.status == 5 or ct.status == 6)
		end
		if done then
			case.phase = "done"
			res.done_tick = game.tick
		end
	end
end

local function dedupe_tick(case, cycle_started)
	local res = case.res
	if not cycle_started then return end
	bx.dedupe_cycle = (bx.dedupe_cycle or 0) + 1
	local c = bx.dedupe_cycle
	local function sample()
		local ad = dev("alert_dedupe")
		local key = ad.keys[case.key]
		return { sent = key and key.sent, shown = key and key.shown, code = key and key.code, a = custom_alerts(case.a.stop),
			b = custom_alerts(case.b.stop), cycle = c, tick = game.tick }
	end
	if case.phase == "staging" then
		case.phase = "arm_a"
	elseif case.phase == "arm_a" then
		cases.set_signals(case.a, cases.request(case, -2000, 1000))
		case.phase = "arm_b"
		case.wait_until = c + 2
	elseif case.phase == "arm_b" and c >= case.wait_until then
		cases.set_signals(case.b, cases.request(case, -2000, 1000))
		case.phase = "both"
		case.wait_until = c + 4
	elseif case.phase == "both" and c >= case.wait_until then
		res.both = sample()
		res.both_next = nil
		case.phase = "both2"
	elseif case.phase == "both2" then
		res.both_next = sample()
		cases.set_signals(case.a, {})
		case.phase = "only_b"
		case.wait_until = c + 4
	elseif case.phase == "only_b" and c >= case.wait_until then
		res.only_b = sample()
		cases.set_signals(case.b, {})
		case.phase = "none"
		case.wait_until = c + 4
	elseif case.phase == "none" and c >= case.wait_until then
		res.none = sample()
		case.phase = "done"
	end
end

local function on_tick()
	local cycle_started = bx.init_seen ~= #bx.inits
	bx.init_seen = #bx.inits
	for _, case in ipairs(bx.list) do
		if case.phase ~= "done" then
			local ok, err = xpcall(function()
				if case.kind == "dedupe" then
					dedupe_tick(case, cycle_started)
				else
					cargo_tick(case)
				end
				if game.tick - case.start_tick > TIMEOUT then
					case.res.timeout = case.phase
					case.phase = "done"
				end
			end, debug.traceback)
			if not ok then
				bx.errors[#bx.errors + 1] = case.name .. ": " .. tostring(err)
				case.phase = "done"
			end
		end
	end
end

local function all_done()
	for _, case in ipairs(bx.list) do
		if case.phase ~= "done" then return false end
	end
	return true
end

-- ---- checks ------------------------------------------------------------------------------------------------------

--- Cargo events after `seq` for one train.
local function cargo_events(seq, train_id)
	local out = {}
	for _, ev in ipairs(dev("diag_events", seq, 100000)) do
		if ev.seq > seq and ev.train == train_id and (ev.kind == "short_load" or ev.kind == "unexpected_cargo" or
			ev.kind == "residual_cargo") then
			out[#out + 1] = ev
		end
	end
	return out
end

local function cargo_checks(case)
	local n, res = case.name, case.res
	lab.check(n .. ": the delivery ran to the end", res.done_tick ~= nil and not res.timeout,
		{ timeout = res.timeout, manifest = res.manifest })
	local evs = cargo_events(res.seq0 or 0, case.trains[1])
	local by_kind = {}
	for _, ev in ipairs(evs) do
		by_kind[ev.kind] = by_kind[ev.kind] or {}
		table.insert(by_kind[ev.kind], ev)
	end
	for _, want in ipairs(case.expect or {}) do
		local got = by_kind[want.kind] or {}
		local ev = got[1]
		local station = want.at == "p" and case.p_station or case.r_station
		local other = want.at == "p" and case.r_station or case.p_station
		lab.check(n .. ": one " .. want.kind .. " event (planned " .. want.a .. ", actual " .. want.b .. ", " ..
			want.item .. ")", #got == 1 and ev.a == want.a and ev.b == want.b and ev.item == want.item and
			ev.station == station and ev.station2 == other and ev.sev == "warning", got)
	end
	for _, kind in ipairs(case.absent or {}) do
		lab.check(n .. ": no " .. kind .. " event", by_kind[kind] == nil, by_kind[kind])
	end
end

lab.suite("39_bundle", {
	function()
		lab.check("cases.lua loaded", cases ~= nil and cases.base ~= nil)
		bx.setting = settings.global["cybersyn-diagnostics"].value
		dev("set_setting", "cybersyn-diagnostics", "basic")
		lab.check("cargo tolerance is a fixed 2 %, not a setting", prototypes.mod_setting["cybersyn-cargo-tolerance"] == nil)
		script.on_event(remote.call("cybersyn", "get_on_tick_init"), function()
			local ok, err = pcall(function()
				bx.inits[#bx.inits + 1] = { tick = game.tick, dispatches = bx.dispatches, cycle = dev("cycle") }
				bx.dispatches = 0
			end)
			if not ok then bx.errors[#bx.errors + 1] = "tick_init: " .. tostring(err) end
		end)
		script.on_event(remote.call("cybersyn", "get_on_train_status_changed"), function(e)
			if e.new_status == STATUS_TO_P then bx.dispatches = bx.dispatches + 1 end
		end)
		local ok, err = xpcall(build, debug.traceback)
		lab.check("scenarios build", ok, err)
		script.on_event(defines.events.on_tick, function()
			local ok2, err2 = xpcall(on_tick, debug.traceback)
			if not ok2 then
				bx.errors[#bx.errors + 1] = "on_tick: " .. tostring(err2)
				for _, case in ipairs(bx.list) do case.phase = "done" end
				script.on_event(defines.events.on_tick, nil)
			end
		end)
		lab.wait_until(all_done, TIMEOUT + 600, SPEED)
	end,

	function()
		lab.check("every scenario finished", all_done())
		for _, err in ipairs(bx.errors) do lab.check("runner error", false, err) end
		for _, case in ipairs(bx.list) do
			if case.kind == "cargo" then cargo_checks(case) end
		end

		-- refuel_tick (PLAN3 §4.4): written when the train reaches the refueler; the snapshot copies it.
		local rf
		for _, case in ipairs(bx.list) do if case.kind == "refuel" then rf = case end end
		local res = rf.res
		lab.check("REFUEL: refuel_tick written at the refueler arrival",
			res.refuel_tick ~= nil and res.refuel_tick <= res.refuel_at and res.refuel_at - res.refuel_tick <= 1 and
			res.refuel_status == STATUS_F, { tick = res.refuel_tick, at = res.refuel_at, status = res.refuel_status })
		dev("collect")
		local snap_train = dev("snapshot_train", rf.trains[1])
		lab.check("REFUEL: the snapshot train carries refuel_tick and in_group",
			snap_train ~= nil and snap_train.refuel_tick == res.refuel_tick and snap_train.in_group == false, snap_train)
		local fleet = dev("fleet_capability")
		lab.check("REFUEL: the fleet facts count the row's trains on their network",
			fleet.capability["signal-5"] ~= nil and fleet.mask_or["signal-5"] ~= nil, fleet.capability["signal-5"])

		-- schedule_edited (A2): a player's edit of a Cybersyn train's schedule, one row per train per 10 s.
		local seq = dev("diag_state").seq
		dev("train_schedule_changed", rf.trains[1], 1)
		dev("train_schedule_changed", rf.trains[1], 1)
		local edits = {}
		for _, ev in ipairs(dev("diag_events", seq, 100)) do
			if ev.seq > seq and ev.kind == "schedule_edited" then edits[#edits + 1] = ev end
		end
		lab.check("schedule_edited: one event for two edits in a row, carrying the train and the player",
			#edits == 1 and edits[1].train == rf.trains[1] and edits[1].station2 == 1 and edits[1].a == 1, edits)

		-- B5: the cycle figures equal what the test counted between two tick_init events.
		local inits = bx.inits
		local checked, bad = 0, {}
		-- inits[1] closes the cycle the handler was registered in, so counting starts with the cycle it opened.
		for i = 2, #inits do
			local prev, cur = inits[i - 1], inits[i]
			local c = cur.cycle
			checked = checked + 1
			if c.ticks_last ~= cur.tick - prev.tick or c.dispatches_last ~= cur.dispatches or c.calls_last < 1 or
				c.calls_last < c.dispatches_last then
				bad[#bad + 1] = { i = i, ticks = cur.tick - prev.tick, dispatches = cur.dispatches, cycle = c }
			end
		end
		local dispatched = 0
		for i = 2, #inits do dispatched = dispatched + inits[i].dispatches end
		lab.check("cycle: ticks_last, dispatches_last and calls_last match " .. checked .. " counted cycles",
			checked > 10 and #bad == 0 and dispatched > 0, { bad = bad, dispatched = dispatched })
		lab.info("cycle figures: " .. checked .. " cycles, " .. dispatched .. " dispatches, last " ..
			serpent.line(inits[#inits].cycle))

		-- B6: one alert per (item, network) per cycle, on the longer-waiting requester, moved and then removed.
		local ab
		for _, case in ipairs(bx.list) do if case.kind == "dedupe" then ab = case end end
		local r = ab.res
		local both, nxt, only_b, none = r.both or {}, r.both_next or {}, r.only_b or {}, r.none or {}
		lab.check("B6: both failing: one missing_train alert, on the requester that waited longer",
			both.code == "missing_train" and both.shown == ab.a.id and both.a == 1 and both.b == 0, both)
		lab.check("B6: one alert sent per cycle for the two requesters", nxt.sent ~= nil and nxt.sent == (both.sent or -1) + 1,
			{ before = both, after = nxt })
		lab.check("B6: the alert moves to the other requester when the first stops failing",
			only_b.shown == ab.b.id and only_b.a == 0 and only_b.b == 1, only_b)
		lab.check("B6: the alert is removed when no requester fails", none.shown == nil and none.a == 0 and none.b == 0,
			none)
		local logged = {}
		for _, ev in ipairs(dev("diag_events", 0, 100000)) do
			if ev.kind == "alert" and (ev.station == ab.a.id or ev.station == ab.b.id) then
				logged[#logged + 1] = { station = ev.station, code = ev.code_name }
			end
		end
		lab.check("B6: the log has the alert of each requester it was shown on, once", #logged == 2, logged)
	end,

	-- B7 (PLAN3 §4.14): the three console commands through their real handlers with a synthetic event (the engine's
	-- command path cannot be driven as a player from RCON; a joining client that is not admin would type them
	-- instead, so this emulation is the test).
	function()
		local p = game.get_player(1)
		local was_admin = p.admin
		local setting = settings.global["cybersyn-manager-actions"].value
		lab.check("actions setting defaults to admins", setting == "admins", setting)
		local function actions_since(seq)
			local n = 0
			for _, ev in ipairs(dev("diag_events", seq, 100000)) do
				if ev.seq > seq and ev.kind == "manual_action" then n = n + 1 end
			end
			return n
		end
		local function run(name, admin)
			p.admin = admin
			local seq = dev("diag_state").seq
			dev("run_command", name, 1)
			return actions_since(seq) == 1
		end
		-- A train with a wrong cached capacity shows whether the recalculation really ran.
		local probe = bx.list[1].trains[1]
		local function recalculated(admin)
			local right = read("trains", probe, "item_slot_capacity")
			remote.call("cybersyn", "write_global", 7, "trains", probe, "item_slot_capacity")
			local ran = run("cybersyn-recalculate-train-size", admin)
			local now = read("trains", probe, "item_slot_capacity")
			remote.call("cybersyn", "write_global", right, "trains", probe, "item_slot_capacity")
			return ran and now == right, ran or now ~= 7
		end
		for _, case in ipairs({
			{ "admins", true, true }, { "admins", false, false },
			{ "everyone", true, true }, { "everyone", false, true },
			{ "nobody", true, false }, { "nobody", false, false },
		}) do
			dev("set_setting", "cybersyn-manager-actions", case[1])
			local ran, touched = recalculated(case[2])
			local who = case[2] and "an admin" or "a non-admin"
			if case[3] then
				lab.check("gate " .. case[1] .. ": " .. who .. " may recalculate train sizes (audited)", ran, touched)
			else
				lab.check("gate " .. case[1] .. ": " .. who .. " is refused (nothing ran, nothing audited)",
					not ran and not touched, touched)
			end
		end
		dev("set_setting", "cybersyn-manager-actions", "admins")
		lab.check("gate admins: a non-admin is refused /cybersyn-fix-priorities",
			not run("cybersyn-fix-priorities", false))
		lab.check("gate admins: an admin may run /cybersyn-fix-priorities", run("cybersyn-fix-priorities", true))
		lab.check("gate admins: a non-admin is refused /cybersyn-abolish-same-depot",
			not run("cybersyn-abolish-same-depot", false))
		-- An admin's abolish rewrites every depot and train; their settings are restored afterwards.
		local depots, trains = {}, {}
		for id, depot in pairs(read("depots")) do
			local comb = depot.entity_comb
			if comb and comb.valid then
				depots[id] = { comb = comb, params = comb.get_control_behavior().parameters,
					limit = depot.entity_stop.trains_limit }
			end
		end
		for id, train in pairs(read("trains")) do trains[id] = train.use_any_depot end
		lab.check("gate admins: an admin may run /cybersyn-abolish-same-depot", run("cybersyn-abolish-same-depot", true))
		for id, d in pairs(depots) do
			if d.comb.valid then
				d.comb.get_control_behavior().parameters = d.params
				local stop = read("depots", id, "entity_stop")
				if stop and stop.valid and d.limit > 2100000000 then stop.trains_limit = nil end
			end
		end
		for id, v in pairs(trains) do
			if read("trains", id) then remote.call("cybersyn", "write_global", v or nil, "trains", id, "use_any_depot") end
		end
		local ev = dev("diag_events", nil, 1)[1]
		lab.check("manual_action event: action, player and target", ev and ev.kind == "manual_action" and
			ev.code_name == "abolish_same_depot" and ev.station2 == 1 and ev.b == 0, ev)
		p.admin = was_admin
	end,

	function()
		script.on_event(defines.events.on_tick, nil)
		script.on_event(remote.call("cybersyn", "get_on_tick_init"), nil)
		script.on_event(remote.call("cybersyn", "get_on_train_status_changed"), nil)
		for _, case in ipairs(bx.list) do
			local ok, err = pcall(case.cleanup)
			if not ok then lab.check(case.name .. ": cleanup", false, err) end
		end
		if bx.setting then dev("set_setting", "cybersyn-diagnostics", bx.setting) end
		lab.wait(600, SPEED)
	end,

	function()
		local left = game.surfaces[cases.SURFACE].count_entities_filtered({
			area = { { cases.X_MIN - 64, cases.Y0 + cases.ROW * K0 - 64 },
				{ cases.X_MAX + 64, cases.Y0 + cases.ROW * (K0 + #bx.list) + 64 } },
		})
		lab.check("cleanup: no entity left on the bundle rows", left == 0, left)
		local n = table_size((read("stations")))
		lab.check("cleanup: 30 stations again", n == 30, n)
	end,
})
