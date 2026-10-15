-- Reason-code suite (PLAN3 §6 gate 2): one constructed scenario per dispatcher failure the diagnostics core names
-- (§4.5), built by tests/lab/cases.lua on rows far south of the save's world and torn down again at the end.
--
-- Two kinds of checks per scenario:
--   observable: the scenario is what it claims, read from Cybersyn's own tables (the request was polled, the
--     precondition holds, the requester's combinator shows a failed request, no delivery was created while the
--     cause was in place). They hold with or without the diagnostics core. A control case on the same kind of
--     track is dispatched, loaded, unloaded and returns, so "no delivery" elsewhere means something.
--   reason: against the dev API of the diagnostics core (`diag_unserved` etc. on cybersyn-manager-dev). Without it
--     each scenario prints `SKIP <code> (no diag api)`; with it, the code must be pending (or already set, for a
--     first entry) right after the first failing evaluation and be the confirmed reason after the flap window
--     (two evaluations and 30 s), and lifting the cause must produce a `served` event.
--
-- Everything time-critical runs inside the game tick: a handler on Cybersyn's tick_init event marks the planner
-- cycle boundaries, and an on_tick handler advances each scenario one stage per cycle and samples it right after
-- a boundary, so a sample always describes complete dispatcher cycles. RCON only waits for the outcome; the
-- printed lines do not depend on when RCON commands arrive.

local DEV = "cybersyn-manager-dev"
local FLAP_TICKS = 1800
local SETTLE_TICKS = FLAP_TICKS + 600
local STAGE_TIMEOUT = 3600
local LIFT_TIMEOUT = 1200
local CONTROL_TIMEOUT = 7200
local SPEED = 50

local function has_diag()
	local i = remote.interfaces[DEV]
	return i ~= nil and i.diag_unserved ~= nil
end

local function dev(fn, ...)
	return remote.call(DEV, fn, ...)
end

local rc = {
	cycle = 0,
	seen = 0,
	list = {},
	deliveries = {},
	statuses = {},
	diag = has_diag(),
	errors = {},
}
lab.rc = rc

local function kind_is(kind, name)
	if kind == name then return true end
	local st = rc.diag_state
	return type(kind) == "number" and st and st.kinds and st.kinds[kind] == name or false
end

--- The highest event sequence number the core has written so far.
local function last_seq()
	local events = dev("diag_events", 0, 1000000) or {}
	local seq = 0
	for _, e in ipairs(events) do
		if e.seq and e.seq > seq then seq = e.seq end
	end
	return seq
end

local function diag_entry(case)
	local t = dev("diag_unserved", case.r_station)
	return t and t[case.item]
end

local function copy(t)
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in pairs(t) do out[k] = copy(v) end
	return out
end

local function deliveries_to(case, since_tick)
	local n = 0
	for _, d in ipairs(rc.deliveries) do
		if d.r == case.r_station and d.tick >= since_tick and d.items[case.item] then n = n + 1 end
	end
	return n
end

local function display_failed(case)
	local ds = lab.read("stations", case.r_station, "display_state")
	return ds ~= nil and bit32.band(ds, 2) ~= 0
end

local function finish(case)
	case.phase = "done"
end

--- One planner cycle has completed since the last call: advance or sample every scenario.
local function boundary()
	local tick = game.tick
	for _, case in ipairs(rc.list) do
		local res = case.res
		local ok, err = xpcall(function()
			if case.phase == "staging" then
				local stage = case.stages[case.stage]
				if stage.when(case) then
					stage.run(case)
					case.stage = case.stage + 1
					if case.stage > #case.stages then
						case.phase = "armed"
						res.armed = true
						case.armed_tick = tick
						case.armed_cycle = rc.cycle
					end
				elseif tick - case.stage_tick > STAGE_TIMEOUT then
					res.stage_timeout = case.stage
					finish(case)
				end
				if case.phase == "staging" and case.stage_seen ~= case.stage then
					case.stage_seen = case.stage
					case.stage_tick = tick
				end
			elseif case.phase == "armed" then
				-- Armed on the first tick of a cycle: the request is evaluated at the end of this cycle or, if the
				-- requester was already polled, of the next one.
				local e = rc.diag and diag_entry(case)
				if e or rc.cycle >= case.armed_cycle + 2 then
					res.first = copy(e)
					res.first_cycle = rc.cycle
					case.first_tick = tick
					case.phase = "settling"
				end
			elseif case.phase == "settling" then
				if rc.cycle >= res.first_cycle + 2 and tick >= case.first_tick + SETTLE_TICKS then
					res.settled = rc.diag and copy(diag_entry(case)) or nil
					res.pre = case.pre(case)
					res.display_failed = display_failed(case)
					res.delivered = deliveries_to(case, case.armed_tick)
					if case.winner then
						res.winner_delivered = deliveries_to({ r_station = case.winner, item = case.item },
							case.armed_tick)
					end
					if case.served then
						case.phase = "serving"
						case.serve_tick = tick
					elseif case.lift then
						res.lift_seq = rc.diag and last_seq() or nil
						case.lift(case)
						case.lift_tick = tick
						case.phase = "lifting"
					else
						finish(case)
					end
				end
			elseif case.phase == "lifting" then
				res.lift_delivered = deliveries_to(case, case.lift_tick)
				if rc.diag then
					res.served_event = false
					for _, ev in ipairs(dev("diag_events", res.lift_seq + 1, 1000) or {}) do
						if kind_is(ev.kind, "served") and ev.station == case.r_station then res.served_event = true end
					end
					local e = diag_entry(case)
					res.entry_after_lift = e ~= nil
				end
				local done = res.lift_delivered > 0 and (not rc.diag or res.served_event)
				if done or tick - case.lift_tick > LIFT_TIMEOUT then finish(case) end
			elseif case.phase == "serving" then
				local t = cases.ctrain(case.trains[1])
				local seen = rc.statuses[case.trains[1]] or {}
				res.trip = seen
				local completed = seen[5] or seen[6]
				if (completed and t and t.status == 0) or tick - case.serve_tick > CONTROL_TIMEOUT then
					res.back = t ~= nil and t.status == 0 and t.is_available == true
					finish(case)
				end
			end
		end, debug.traceback)
		if not ok then
			rc.errors[#rc.errors + 1] = case.name .. ": " .. tostring(err)
			finish(case)
		end
	end
end

local function tick()
	if rc.cycle ~= rc.seen then
		rc.seen = rc.cycle
		boundary()
	end
	for _, case in ipairs(rc.list) do
		if case.operated and case.phase ~= "done" then cases.operate(case) end
	end
end

-- An error inside a level-script event handler stops the server, so it is recorded and the runner winds down.
local function on_tick()
	local ok, err = xpcall(tick, debug.traceback)
	if not ok then
		rc.errors[#rc.errors + 1] = "on_tick: " .. tostring(err)
		for _, case in ipairs(rc.list) do case.phase = "done" end
		script.on_event(defines.events.on_tick, nil)
	end
end

local function all_done()
	for _, case in ipairs(rc.list) do
		if case.phase ~= "done" then return false end
	end
	return true
end

lab.suite("40_reason_codes", {
	function()
		lab.check("cases.lua loaded", cases ~= nil and cases.ORDER ~= nil)
		lab.check("planner enabled", settings.global["cybersyn-enable-planner"].value == true)
		rc.before = cases.fingerprint()
		lab.check("save has its 30 stations before the suite", #rc.before.stations == 30, #rc.before.stations)
		if rc.diag then
			local setting = settings.global["cybersyn-diagnostics"]
			rc.diag_setting = setting and setting.value
			local ok, err = pcall(function()
				dev("set_setting", "cybersyn-diagnostics", "basic")
				dev("diag_reset")
				rc.diag_state = dev("diag_state")
			end)
			lab.check("diagnostics set to basic and reset", ok, err)
		end
		lab.info("diagnostics api " .. (rc.diag and "present" or "absent"))

		script.on_event(remote.call("cybersyn", "get_on_tick_init"), function() rc.cycle = rc.cycle + 1 end)
		script.on_event(remote.call("cybersyn", "get_on_train_status_changed"), function(e)
			local ok, err = pcall(rc.on_status, e)
			if not ok then rc.errors[#rc.errors + 1] = "on_train_status_changed: " .. tostring(err) end
		end)
		rc.on_status = function(e)
			local seen = rc.statuses[e.train_id] or {}
			rc.statuses[e.train_id] = seen
			seen[e.new_status] = true
			if e.new_status == 1 then
				local t = remote.call("cybersyn", "read_global", "trains", e.train_id)
				if t then
					local items = {}
					for _, m in ipairs(t.manifest or {}) do items[m.name] = m.count end
					rc.deliveries[#rc.deliveries + 1] = { tick = game.tick, train = e.train_id, p = t.p_station_id,
						r = t.r_station_id, items = items }
				end
			end
		end

		for k, name in ipairs(cases.ORDER) do
			local ok, case = xpcall(cases[name], debug.traceback, { k = k - 1 })
			if ok then
				case.res = {}
				case.phase = "staging"
				case.stage = 1
				case.stage_tick = game.tick
				rc.list[#rc.list + 1] = case
			else
				lab.check(name .. ": scenario builds", false, case)
			end
		end
		script.on_event(defines.events.on_tick, on_tick)
		lab.wait_until(all_done, 20000, SPEED)
	end,

	function()
		lab.check("every scenario finished in time", all_done())
		for _, err in ipairs(rc.errors) do lab.check("runner error", false, err) end
		for _, case in ipairs(rc.list) do
			local n, res = case.name, case.res
			lab.check(n .. ": scenario builds", true)
			local registered = true
			for _, st in ipairs(case.stations) do
				if not (lab.read("stations", st.id) or lab.read("depots", st.id)) then registered = false end
			end
			lab.check(n .. ": every stop registered with Cybersyn", registered)
			if lab.check(n .. ": armed", res.armed == true, { stage = res.stage_timeout }) and res.pre then
				for _, p in ipairs(res.pre) do lab.check(n .. ": " .. p[1], p[2], p[3]) end
				if case.served then
					local trip = res.trip or {}
					lab.check(n .. ": dispatched once", res.delivered == 1, res.delivered)
					lab.check(n .. ": train reached the provider", trip[2] == true)
					lab.check(n .. ": train reached the requester", trip[4] == true)
					lab.check(n .. ": delivery completed", trip[5] == true or trip[6] == true)
					lab.check(n .. ": train back at its depot and available", res.back == true)
				else
					lab.check(n .. ": requester shows a failed request", res.display_failed)
					lab.check(n .. ": no delivery to the requester while the cause is in place", res.delivered == 0,
						res.delivered)
					if case.winner then
						lab.check(n .. ": the higher-priority requester got the delivery", res.winner_delivered == 1,
							res.winner_delivered)
					end
					if case.lift then
						lab.check(n .. ": served once the cause is lifted", (res.lift_delivered or 0) > 0,
							res.lift_delivered)
					end
					local code = case.expect
					if rc.diag then
						local first, settled = res.first or {}, res.settled or {}
						if case.kind == "counter" then
							lab.check(n .. ": lost_n counted after the first evaluation", (first.lost_n or 0) >= 1,
								first)
							lab.check(n .. ": lost_to is the winner", first.lost_to == case.winner, first.lost_to)
						else
							lab.check(n .. ": " .. code .. " pending after the first evaluation",
								first.pending == code or (first.pending == nil and first.reason == code), first)
						end
						local want = case.expect_settled or code
						lab.check(n .. ": reason " .. want .. " after the flap window", settled.reason == want, settled)
						if case.lift then
							lab.check(n .. ": served event after the cause is lifted", res.served_event == true)
							lab.check(n .. ": unserved entry gone after the cause is lifted",
								res.entry_after_lift == false)
						end
					else
						lab.skip(n, "no diag api")
					end
				end
			end
		end
		if rc.diag then
			local counts = dev("diag_counts") or {}
			local missing = {}
			for _, case in ipairs(rc.list) do
				if case.expect and case.kind ~= "counter" and not ((counts[case.expect] or 0) > 0) then
					missing[#missing + 1] = case.expect
				end
			end
			lab.check("diag_counts counts every reason the scenarios produced", #missing == 0, missing)
		end
	end,

	function()
		script.on_event(defines.events.on_tick, nil)
		script.on_event(remote.call("cybersyn", "get_on_tick_init"), nil)
		script.on_event(remote.call("cybersyn", "get_on_train_status_changed"), nil)
		for _, case in ipairs(rc.list) do
			local ok, err = pcall(case.cleanup)
			if not ok then lab.check(case.name .. ": cleanup", false, err) end
		end
		if rc.diag and rc.diag_setting then dev("set_setting", "cybersyn-diagnostics", rc.diag_setting) end
		-- Cybersyn drops destroyed stops at once; active_station_ids is pruned lazily during the next poll.
		lab.wait(600, SPEED)
	end,

	function()
		local after = cases.fingerprint()
		for _, key in ipairs({ "stations", "trains", "depots", "available_trains", "layouts", "refuelers", "warmup",
			"active_station_ids", "connected_surfaces", "surfaces" }) do
			local same, at = lab.same_list(rc.before[key], after[key])
			lab.check("cleanup restored " .. key, same, { at = at, before = rc.before[key], after = after[key] })
		end
		lab.check("cleanup: 30 stations again", #after.stations == 30, #after.stations)
		local left = game.surfaces[cases.SURFACE].count_entities_filtered({
			area = { { cases.X_MIN - 64, cases.Y0 - 64 }, { cases.X_MAX + 64, cases.Y0 + cases.ROW * #cases.ORDER + 64 } },
		})
		lab.check("cleanup: no entity left on the scenario rows", left == 0, left)
	end,
})
