-- Reason-code suite (PLAN3 §6 gate 2): one constructed scenario per dispatcher failure the diagnostics core names
-- (§4.5), built by tests/lab/cases.lua on rows far south of the save's world and torn down again at the end.
--
-- Two kinds of checks per scenario:
--   observable: the scenario is the situation it is built for, read from Cybersyn's own tables (the request was
--     polled, a provider offers the item unless its stock is the point, the precondition holds, the requester's
--     combinator shows a failed request, no delivery was created while the cause was in place). They hold with or without the diagnostics core. A control case on the same kind of
--     track is dispatched, loaded, unloaded and returns, so "no delivery" elsewhere means something.
--   reason: against the dev API of the diagnostics core (`diag_unserved` etc. on cybersyn-manager-dev). Without it
--     each scenario prints `SKIP 40_reason_codes: <NAME> (no diag api)`; with it, the code must be pending (or already set, for a
--     first entry) right after the first failing evaluation and be the confirmed reason after the flap window
--     (two evaluations and 30 s), with the payload numbers a/b where PLAN3 §4.5 (B1) defines them, counted by
--     diag_counts while it is live, and lifting the cause must produce a `served` event.
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

-- The core's setting is the sign that it landed; an API missing next to it must not read as "not written yet".
local function core_present()
	return prototypes.mod_setting["cybersyn-diagnostics"] ~= nil
end

local function dev(fn, ...)
	return remote.call(DEV, fn, ...)
end

-- The lint checks that predict a reason code (PLAN3 §4.12); a case asserts exactly its expected ones among these.
local PREDICTING = { "capacity", "layout", "mask", "train_mask", "no_train", "no_provider", "limit_zero", "same_item",
	"occupancy", "phantom" }

local function has_lint_api()
	local i = remote.interfaces[DEV]
	return i ~= nil and i.lint_run ~= nil
end

--- The lint masks of the case's requester and provider from a fresh snapshot and lint pass, with assert_lint for
--- every expected check.
local function lint_sample(case)
	dev("collect")
	dev("lint_run")
	local out = {}
	for role, id in pairs({ r = case.r_station, p = case.p_station }) do
		local bits = dev("lint_bits", id)
		local asserted = {}
		for _, check in ipairs(case.lint_expect[role] or {}) do asserted[check] = dev("assert_lint", id, check) end
		out[role] = { checks = bits.checks, st_lint = bits.st_lint, mask = bits.mask, asserted = asserted }
	end
	-- Phase 6b: every finding of this pass is a correct row of the Problems tab (and counts towards the coverage
	-- check at the end of the run).
	if lab.problems_verify then
		out.problems = {}
		lab.problems_verify(case.name, out.problems)
	end
	return out
end

--- Phase 2b (§6.2): the lint bits that predict the case's reason are set, and no other predicting bit is.
local function lint_checks(n, case, res)
	for _, p in ipairs(res.lint and res.lint.problems or {}) do lab.check(p[1], p[2], p[3]) end
	for _, role in ipairs({ "r", "p" }) do
		local got = res.lint and res.lint[role]
		local want = {}
		for _, check in ipairs(case.lint_expect[role] or {}) do want[check] = true end
		local set = {}
		for _, check in ipairs(got and got.checks or {}) do set[check] = true end
		for _, check in ipairs(PREDICTING) do
			if want[check] then
				local predicts = dev("lint_predicts", check, role)
				lab.check(n .. ": lint " .. check .. " on " .. role .. " (predicts " .. tostring(predicts) .. ")",
					set[check] == true and got.asserted[check] == true, got)
				local recorded = res.settled and res.settled.reason
				if recorded then
					lab.check(n .. ": lint " .. check .. " on " .. role .. " predicts the recorded " .. recorded,
						predicts == recorded, { predicts = predicts, recorded = recorded })
				end
			end
		end
		local extra = {}
		for _, check in ipairs(PREDICTING) do
			if set[check] and not want[check] then extra[#extra + 1] = check end
		end
		lab.check(n .. ": no other predicting lint finding on " .. role, #extra == 0, { extra = extra, got = got })
		lab.check(n .. ": st.lint of " .. role .. " equals the lint mask", got ~= nil and got.st_lint == got.mask, got)
	end
end

local rc = {
	cycle = 0,
	seen = 0,
	list = {},
	deliveries = {},
	statuses = {},
	diag = has_diag(),
	errors = {},
	cycle_tick = nil,
	max_cycle_ticks = 0,
}
lab.rc = rc

-- B3 (PLAN3 §3): the dispatcher's alert for a key, as the alert events of the log record it. "Missing train" only
-- when the network has no train available; filtered trains get their own alert; trains inside interrupts get none.
local B3 = {
	TRAIN_FILTERED_MANUAL = { yes = "trains_filtered", no = "missing_train" },
	TRAIN_FILTERED_MASK = { yes = "trains_filtered", no = "missing_train" },
	NO_TRAINS_ON_NETWORK = { yes = "missing_train", no = "trains_filtered" },
	CAPACITY = { yes = "no_train_has_capacity", no = "missing_train" },
	R_LAYOUT = { yes = "no_train_matches_r_layout", no = "missing_train" },
	P_LAYOUT = { yes = "no_train_matches_p_layout", no = "missing_train" },
	ALL_IN_INTERRUPT = { no = "missing_train", none = true },
}

--- Alert code names the log holds for one requester.
local function alerts_for(station)
	local out = {}
	for _, ev in ipairs(dev("diag_events", 0, 1000000) or {}) do
		if ev.kind == "alert" and ev.station == station then out[#out + 1] = ev.code_name end
	end
	return out
end

local function kind_is(kind, name)
	if kind == name then return true end
	local st = rc.diag_state
	return type(kind) == "number" and st and st.kinds and st.kinds[kind] == name or false
end

local function diag_entry(case, station)
	local t = dev("diag_unserved", station or case.r_station)
	return t and t[case.item]
end

--- The first `served` event for `station` written after `seq`, or nil. The contract does not say whether
--- diag_events' from_seq is inclusive, so the query starts at `seq` and the filter drops it.
local function served_after(seq, station)
	for _, ev in ipairs(dev("diag_events", seq, 1000) or {}) do
		if ev.seq and ev.seq > seq and kind_is(ev.kind, "served") and ev.station == station then return ev end
	end
	return nil
end

--- Live unserved entries by confirmed reason over every station the run knows (the save's and the scenarios'),
--- read through diag_unserved: what diag_counts must report at the same tick.
local function unserved_tally()
	local tally, seen = {}, {}
	local function add(id)
		if seen[id] then return end
		seen[id] = true
		for _, e in pairs(dev("diag_unserved", id) or {}) do
			if e.reason then tally[e.reason] = (tally[e.reason] or 0) + 1 end
		end
	end
	for _, id in ipairs(rc.before.stations) do add(id) end
	for _, case in ipairs(rc.list) do
		for _, st in ipairs(case.stations) do add(st.id) end
	end
	return tally
end

--- assert_reason (PLAN3 §6.2) for the settled reason and for one it is not; errors are kept as the result.
local function assert_reason_pair(case, want)
	local other = want == "NO_PROVIDER" and "R_DISABLED" or "NO_PROVIDER"
	local function ask(code)
		local ok, v = pcall(dev, "assert_reason", case.r_station, case.item, code)
		if ok then return v end
		return tostring(v)
	end
	return { yes = ask(want), no = ask(other), other = other }
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
	if case.armed_tick then case.res.delivered_end = deliveries_to(case, case.armed_tick) end
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
				if rc.diag and case.flap then
					local e = diag_entry(case)
					res.samples = res.samples or {}
					res.samples[#res.samples + 1] = { tick = tick, cycle = rc.cycle, reason = e and e.reason,
						pending = e and e.pending }
				end
				if rc.cycle >= res.first_cycle + 2 and tick >= case.first_tick + SETTLE_TICKS then
					if rc.diag then
						res.settled = copy(diag_entry(case))
						res.counts = copy(dev("diag_counts"))
						res.tally = unserved_tally()
						res.asserted = assert_reason_pair(case, case.expect_settled or case.expect)
						if case.lift_station then res.target_settled = copy(diag_entry(case, case.lift_station)) end
						if B3[case.name] then res.alerts = alerts_for(case.r_station) end
					end
					if rc.lint then res.lint = lint_sample(case) end
					res.pre = case.pre(case)
					res.display_failed = display_failed(case)
					res.delivered = deliveries_to(case, case.armed_tick)
					if case.served then
						case.phase = "serving"
						case.serve_tick = tick
					elseif case.lift then
						res.lift_seq = rc.diag and dev("diag_state").seq or nil
						case.lift(case)
						case.lift_tick = tick
						res.lift_tick = tick
						case.phase = "lifting"
					else
						finish(case)
					end
				end
			elseif case.phase == "lifting" then
				local target = case.lift_station or case.r_station
				res.lift_delivered = deliveries_to({ r_station = target, item = case.item }, case.lift_tick)
				if rc.diag then
					res.served_ev = copy(served_after(res.lift_seq, target))
					res.served_event = res.served_ev ~= nil
					res.entry_after_lift = diag_entry(case, target) ~= nil
				end
				-- Two more cycles after the delivery, so a requester the lift must not serve has been evaluated again.
				if not res.lift_done_cycle and res.lift_delivered > 0 and (not rc.diag or res.served_event) then
					res.lift_done_cycle = rc.cycle
				end
				if (res.lift_done_cycle and rc.cycle >= res.lift_done_cycle + 2) or
					tick - case.lift_tick > LIFT_TIMEOUT then
					finish(case)
				end
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
		if rc.cycle_tick then
			local len = game.tick - rc.cycle_tick
			if len > rc.max_cycle_ticks then rc.max_cycle_ticks = len end
		end
		rc.cycle_tick = game.tick
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

--- Payload numbers of an entry against the case's expectation; nil in the expectation matches anything.
local function ab_matches(e, want)
	local a, b = e and e.a, e and e.b
	local function eq(x, y) return y == nil or x == y end
	if eq(a, want[1]) and eq(b, want[2]) then return true end
	return want.unordered == true and eq(b, want[1]) and eq(a, want[2])
end

local TRAIN_CAUSES = { "TRAIN_MASK", "TRAIN_MANUAL", "TRAIN_SURFACE" }



--- The rejection is counted under the expected TRAIN_FILTERED cause and under no other.
local function rej_matches(e, want)
	local rej = e and e.rej or {}
	for _, cause in ipairs(TRAIN_CAUSES) do
		local n = rej[cause] or 0
		if (cause == want) ~= (n > 0) then return false end
	end
	return true
end

--- The flap rule held the dispatcher's own transition back: an evaluation after the first still showed the old
--- reason with the new one pending, and the new one was confirmed only a flap window after it became pending.
--- Samples are taken on cycle boundaries, so the measured window can be short by up to one cycle at each end.
local function flap_checks(n, case, res)
	local from, to = case.flap.from, case.flap.to
	local pending_at, confirmed_at
	for _, s in ipairs(res.samples or {}) do
		if not pending_at and s.reason == from and s.pending == to then pending_at = s end
		if not confirmed_at and s.reason == to then confirmed_at = s end
	end
	lab.check(n .. ": " .. from .. " held with " .. to .. " pending", pending_at ~= nil, res.samples)
	local slack = 2 * rc.max_cycle_ticks
	lab.check(n .. ": " .. to .. " confirmed only after the flap window",
		pending_at ~= nil and confirmed_at ~= nil and confirmed_at.cycle >= pending_at.cycle + 1 and
		confirmed_at.tick - pending_at.tick >= FLAP_TICKS - slack,
		{ pending = pending_at, confirmed = confirmed_at, slack = slack })
end

--- The reason checks of one failing scenario against the diagnostics core.
local function reason_checks(n, case, res)
	local code = case.expect
	local first, settled = res.first or {}, res.settled or {}
	if case.kind == "counter" then
		lab.check(n .. ": lost_n counted after the first evaluation", (first.lost_n or 0) >= 1, first)
		lab.check(n .. ": lost_to is the winner", first.lost_to == case.winner, first.lost_to)
	else
		lab.check(n .. ": " .. code .. " pending after the first evaluation",
			first.pending == code or (first.pending == nil and first.reason == code), first)
	end
	if case.no_loss then
		lab.check(n .. ": no priority loss counted (lo is evaluated in the same call)",
			(first.lost_n or 0) == 0 and (settled.lost_n or 0) == 0 and settled.lost_to == nil,
			{ first = first.lost_n, settled = settled.lost_n, to = settled.lost_to })
	end
	local want = case.expect_settled or code
	lab.check(n .. ": reason " .. want .. " after the flap window", settled.reason == want, settled)
	local asserted = res.asserted or {}
	lab.check(n .. ": assert_reason agrees (" .. want .. " true, " .. tostring(asserted.other) .. " false)",
		asserted.yes == true and asserted.no == false, asserted)
	-- diag_counts counts live entries by confirmed reason (the Overview's and the HUD's number), so it is read
	-- while the cause is still in place, against the entries diag_unserved shows at that same tick.
	local counts, tally = res.counts or {}, res.tally or {}
	local exact = (tally[want] or 0) >= 1
	for _, t in ipairs({ counts, tally }) do
		for reason in pairs(t) do
			if (counts[reason] or 0) ~= (tally[reason] or 0) then exact = false end
		end
	end
	lab.check(n .. ": diag_counts equals the live entries by reason (" .. want .. " among them)", exact,
		{ counts = counts, entries = tally })
	local ab = case.expect_ab
	if ab then
		local e = ab.at == "first" and first or settled
		lab.check(n .. ": payload a/b", ab_matches(e, ab), { want = ab, a = e.a, b = e.b })
		if case.expect_rej then
			lab.check(n .. ": rejection counted under " .. case.expect_rej, rej_matches(e, case.expect_rej), e.rej)
		end
	end
	if case.flap then flap_checks(n, case, res) end
	local b3 = B3[n]
	if b3 then
		local seen = {}
		for _, name in ipairs(res.alerts or {}) do seen[name] = true end
		if b3.yes then lab.check(n .. ": alert " .. b3.yes .. " (B3)", seen[b3.yes] == true, res.alerts) end
		if b3.no then lab.check(n .. ": no " .. b3.no .. " alert (B3)", not seen[b3.no], res.alerts) end
		if b3.none then lab.check(n .. ": no dispatcher alert at all (B3)", #(res.alerts or {}) == 0, res.alerts) end
	end
	if case.lift then
		lab.check(n .. ": served event after the cause is lifted", res.served_event == true)
		-- PLAN3 §4.5: served carries the wait, now - first_tick, in `a`; the key failed from first_tick until the lift.
		local ev, before = res.served_ev or {}, case.lift_station and res.target_settled or res.settled
		local ft = before and before.first_tick
		lab.check(n .. ": served event carries the wait since the first failure",
			ft ~= nil and ev.a ~= nil and ev.tick ~= nil and ev.a == ev.tick - ft and ev.a >= res.lift_tick - ft,
			{ a = ev.a, tick = ev.tick, first_tick = ft, lift_tick = res.lift_tick })
		lab.check(n .. ": unserved entry gone after the cause is lifted", res.entry_after_lift == false)
	end
end

lab.suite("40_reason_codes", {
	function()
		lab.check("cases.lua loaded", cases ~= nil and cases.ORDER ~= nil)
		lab.check("planner enabled", settings.global["cybersyn-enable-planner"].value == true)
		rc.before = cases.fingerprint()
		lab.check("save has its 30 stations before the suite", #rc.before.stations == 30, #rc.before.stations)
		if core_present() then
			lab.check("diagnostics core present with its dev api", rc.diag,
				"cybersyn-diagnostics exists but cybersyn-manager-dev has no diag_unserved")
		end
		if rc.diag then
			local setting = settings.global["cybersyn-diagnostics"]
			rc.diag_setting = setting and setting.value
			local ok, err = pcall(function()
				dev("set_setting", "cybersyn-diagnostics", "basic")
				dev("diag_reset")
				rc.diag_state = dev("diag_state")
				-- DIAG_VERIFY_INTERRUPT: tick_dispatch also reads each candidate's schedule and counts disagreements.
				dev("diag_verify_interrupt", true)
			end)
			lab.check("diagnostics set to basic and reset", ok, err)
		end
		lab.info("diagnostics api " .. (rc.diag and "present" or "absent"))
		rc.lint = has_lint_api()

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
					lab.check(n .. ": no second delivery by the end of the trip", res.delivered_end == 1,
						res.delivered_end)
					if rc.lint then lint_checks(n, case, res) end
				else
					lab.check(n .. ": requester shows a failed request", res.display_failed)
					lab.check(n .. ": no delivery to the requester while the cause is in place", res.delivered == 0,
						res.delivered)
					if case.lift_station then
						lab.check(n .. ": the higher-priority requester is served once the cause is lifted",
							(res.lift_delivered or 0) == 1, res.lift_delivered)
					elseif case.lift then
						lab.check(n .. ": served once the cause is lifted", (res.lift_delivered or 0) > 0,
							res.lift_delivered)
					end
					if rc.diag then
						reason_checks(n, case, res)
					else
						lab.skip(n, "no diag api")
					end
					if rc.lint then lint_checks(n, case, res) else lab.skip(n, "no lint api") end
				end
			end
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
		-- Cybersyn drops destroyed stops at once; active_station_ids is pruned lazily during the next poll, and the
		-- diagnostics core sweeps entries older than two cycles.
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
		if rc.diag then
			local left_keys = {}
			for _, case in ipairs(rc.list) do
				for _, st in ipairs(case.stations) do
					local t = dev("diag_unserved", st.id)
					if t and next(t) ~= nil then left_keys[#left_keys + 1] = case.name .. "/" .. st.name end
				end
			end
			lab.check("cleanup: no unserved entry left for a removed stop", #left_keys == 0, left_keys)
			local st = dev("diag_state")
			lab.check("in_interrupt cache: no disagreement with the schedules tick_dispatch read (PLAN3 §4.4)",
				st.interrupt_checks ~= nil and st.interrupt_checks > 0 and st.interrupt_mismatches == 0,
				{ checks = st.interrupt_checks, mismatches = st.interrupt_mismatches })
			lab.info("in_interrupt shadow comparison: " .. tostring(st.interrupt_checks) .. " checks, " ..
				tostring(st.interrupt_mismatches) .. " mismatches")
			dev("diag_verify_interrupt", false)
			if rc.diag_setting then dev("set_setting", "cybersyn-diagnostics", rc.diag_setting) end
		end
		if lab.problems_coverage then lab.problems_coverage() end
	end,
})
