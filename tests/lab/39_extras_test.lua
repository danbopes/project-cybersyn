-- Phase 10 extras and actions (PLAN3 §11, §4.14): path trace objects and cleanup, pins through the shared link click
-- and the panel tool, the trains-window button, Test path (a reachable and an unreachable stop, against the
-- pathfinder called here), Explain on an Unserved row, the Breakdown failure labels, the HUD values against the
-- counters, the remote interface, and every action under admins / everyone / nobody x admin / non-admin with the
-- confirm step, its expiry and the audit (manual_action event + the force line), and the chunked allow-list job.

local DEV = "cybersyn-manager-dev"
local PI = 1
local ACTION_RECALC, ACTION_FAIL, ACTION_RESCAN, ACTION_ALLOW, ACTION_TEST_PATH = 3, 4, 5, 6, 7
local STATUS_TO_D = 5

local function dev(fn, ...)
	return remote.call(DEV, fn, ...)
end

local function read(...)
	return (remote.call("cybersyn", "read_global", ...))
end

local function key_of(ls)
	return type(ls) == "table" and ls[1] or ls
end

--- Whether a LocalisedString mentions a key anywhere.
local function mentions(ls, key)
	return string.find(serpent.line(ls, { comment = false }), key, 1, true) ~= nil
end

--- manual_action events after seq, with the given action code.
local function actions_after(seq, code)
	local out = {}
	for _, ev in ipairs(dev("diag_events", seq, 4096)) do
		if ev.kind == "manual_action" and ev.a == code then out[#out + 1] = ev end
	end
	return out
end

--- Whether the layout counts add up to one per Cybersyn train, every layout counted at least once.
local function layout_counts_ok()
	local want = {}
	for _, t in pairs(read("trains")) do want[t.layout_id] = (want[t.layout_id] or 0) + 1 end
	local have = read("layout_train_count")
	for id, n in pairs(want) do if have[id] ~= n then return false end end
	for id, n in pairs(have) do if want[id] ~= n then return false end end
	return true
end

local function seq_now()
	return dev("diag_state").seq
end

--- The easternmost straight rail of the train's line (the dispatch trace turns trains around the same way).
local function give_path(t)
	local stock = t.front_stock
	local y = stock.position.y
	local rail
	for _, r in ipairs(stock.surface.find_entities_filtered({ area = { { -1e4, y - 1 }, { 1e4, y + 1 } }, type = "straight-rail" })) do
		if not rail or r.position.x > rail.position.x then rail = r end
	end
	local schedule = t.get_schedule()
	schedule.add_record({ rail = rail, rail_direction = defines.rail_direction.front, temporary = true,
		wait_conditions = { { type = "time", ticks = 1 } }, index = { schedule_index = 1 } })
	schedule.go_to_station(1)
	return t.path ~= nil
end

--- A temporary schedule record to `stop`, made current.
local function send_to(t, stop)
	local schedule = t.get_schedule()
	schedule.add_record({ station = stop.backer_name, temporary = true, wait_conditions = { { type = "time", ticks = 1 } },
		index = { schedule_index = 1 } })
	schedule.go_to_station(1)
	return t.path ~= nil
end

local MATRIX = {
	{ "admins", true, true }, { "admins", false, false },
	{ "everyone", true, true }, { "everyone", false, true },
	{ "nobody", true, false }, { "nobody", false, false },
}

lab.suite("39_extras", {
	function(ctx)
		ctx.actions = settings.global["cybersyn-manager-actions"].value
		ctx.admin = game.get_player(PI).admin
		ctx.was_open = dev("state", PI).is_open
		dev("open", PI)
		ctx.stations = {}
		for id, st in pairs(read("stations")) do
			if st.entity_stop and st.entity_stop.valid then ctx.stations[#ctx.stations + 1] = id end
		end
		table.sort(ctx.stations)
		ctx.station = ctx.stations[1]
		ctx.train_ids = {}
		for id in pairs(read("trains")) do ctx.train_ids[#ctx.train_ids + 1] = id end
		table.sort(ctx.train_ids)

		-- Path trace: a train given a path to its line's end; objects = 2 x segments (game + chart), at most 256.
		-- The longest route the pathfinder finds from any train to any station; that train is sent there.
		local tid, best, target = nil, 0, nil
		for _, id in ipairs(ctx.train_ids) do
			local t = game.train_manager.get_train_by_id(id)
			for _, sid in ipairs(ctx.stations) do
				local stop = read("stations", sid).entity_stop
				local res = t and game.train_manager.request_train_path({ train = t, goals = { { train_stop = stop } },
					return_path = true })
				if res and res.found_path and #res.path > best then tid, best, target = id, #res.path, stop end
			end
		end
		if tid then send_to(game.train_manager.get_train_by_id(tid), target) end
		ctx.trace_target = target
		ctx.trace_train = tid
		if not lab.check("a train has a path to trace", tid ~= nil) then return end
		local base = dev("path_trace_state", PI)
		ctx.base_objects = base.objects
		local r = dev("path_trace", PI, tid)
		lab.info({ "", "path trace: ", tostring(r.rails), " rails, ", tostring(r.runs), " runs, ", tostring(r.segments),
			" segments, ", tostring(r.objects), " objects, draw ", r.ms })
		lab.check("trace drawn", r.drawn == true, r)
		lab.check("trace: two objects per segment (game and chart view)", r.objects == 2 * r.segments, r)
		lab.check("trace: at most 256 objects", r.objects > 0 and r.objects <= 256, r)
		lab.check("trace: the player's object count grew by exactly the trace", r.after - r.before == r.objects, r)
		lab.check("trace: rails read = path from the current rail", r.rails >= 1 and r.rails <= r.size, r)
		dev("path_trace_select", PI, "train", tid)
		lab.check("same train selected again keeps the trace", dev("path_trace_state", PI).shown == true)
		local other = ctx.train_ids[1] ~= tid and ctx.train_ids[1] or ctx.train_ids[2]
		dev("path_trace_select", PI, "train", other)
		local s = dev("path_trace_state", PI)
		lab.check("selection change removes the trace", s.shown == false and s.objects == ctx.base_objects, s)
		dev("path_trace", PI, tid)
		-- extras.tick drops the trace on the manager tick (every 60 ticks at 1 update/s), so the wait covers two of them.
		lab.wait(720)
	end,

	function(ctx)
		if not ctx.trace_train then return end
		local s = dev("path_trace_state", PI)
		lab.check("trace gone after 600 ticks (objects back to the baseline, state dropped)",
			s.shown == false and s.objects == ctx.base_objects, s)

		-- The panel's Path trace button toggles it (the train may have reached the end of its path meanwhile).
		local t = game.train_manager.get_train_by_id(ctx.trace_train)
		if t and not t.path then
			if not (ctx.trace_target and ctx.trace_target.valid and send_to(t, ctx.trace_target)) then give_path(t) end
		end
		dev("relative_open", PI, "train", ctx.trace_train)
		local b = dev("action_button", PI, "path_trace")
		lab.check("train panel has the Path trace tool", b ~= nil and b.enabled == true, b)
		dev("action_click", PI, "path_trace")
		local on = dev("path_trace_state", PI)
		lab.check("Path trace button draws", on.shown == true and on.objects > ctx.base_objects, on)
		dev("action_click", PI, "path_trace")
		local off = dev("path_trace_state", PI)
		lab.check("Path trace button again removes it", off.shown == false and off.objects == ctx.base_objects, off)

		-- Pins: control+shift on a link (station and train) and the panel's tool button.
		local stop = read("stations", ctx.station).entity_stop
		local before = dev("link_click", PI, "station", ctx.station, { control = true, shift = true })
		local pin = dev("last_pin", PI)
		lab.check("ctrl+shift on a station link pins it with its name",
			pin and pin.kind == "station" and pin.id == ctx.station and pin.label == stop.backer_name, pin)
		lab.check("ctrl+shift does not show on map", before.markers == nil or #before.markers == 0
			or before.controller == defines.controllers.character or before.controller == defines.controllers.god, before)
		dev("link_click", PI, "train", ctx.trace_train, { control = true, shift = true })
		pin = dev("last_pin", PI)
		lab.check("ctrl+shift on a train link pins '#<id>' (no English word in a plain-string label)",
			pin and pin.kind == "train" and pin.label == "#" .. ctx.trace_train, pin)
		dev("action_click", PI, "pin")
		pin = dev("last_pin", PI)
		lab.check("train panel pin tool", pin and pin.kind == "train" and pin.id == ctx.trace_train, pin)
		dev("relative_open", PI, "stop", ctx.station)
		dev("action_click", PI, "pin")
		pin = dev("last_pin", PI)
		lab.check("stop panel pin tool", pin and pin.kind == "stop" and pin.id == ctx.station and pin.label == stop.backer_name, pin)

		-- The trains-window button (the click emulated: an offline player cannot open the vanilla trains window).
		dev("close", PI)
		local tg = dev("trains_gui_button", PI)
		lab.check("trains_gui anchor exists with its caption", tg.exists and tg.anchor_gui == "trains-gui"
			and key_of(tg.caption) == "cybersyn-gui.trains-gui-open-manager", tg)
		lab.check("trains_gui button opens the manager on Trains", tg.opened == true and tg.tab == "trains_tab", tg)
	end,

	function(ctx)
		-- Test path against the pathfinder asked here: one stop this train reaches, one it does not.
		local tid = ctx.trace_train or ctx.train_ids[1]
		local t = game.train_manager.get_train_by_id(tid)
		local reach, miss, reach_length
		for _, id in ipairs(ctx.stations) do
			local st = read("stations", id)
			local res = game.train_manager.request_train_path({ train = t, goals = { { train_stop = st.entity_stop } } })
			if res.found_path and not reach then
				reach, reach_length = id, res.total_length
			elseif not res.found_path and not miss then
				miss = id
			end
		end
		if not lab.check("a reachable and an unreachable stop exist for the test train", reach and miss, { reach, miss }) then
			return
		end
		local seq = seq_now()
		local r = dev("test_path", PI, reach, tid)
		lab.check("Test path: reachable stop found with the pathfinder's length",
			r.found == true and r.length == reach_length and key_of(r.caption) == "cybersyn-gui.test-path-found", r)
		r = dev("test_path", PI, miss, tid)
		lab.check("Test path: unreachable stop says no path from the depot",
			r.found == false and (key_of(r.caption) == "cybersyn-gui.test-path-none" or key_of(r.caption) == "cybersyn-gui.test-path-none-train"), r)
		local evs = actions_after(seq, ACTION_TEST_PATH)
		lab.check("Test path is audited: two manual_action events with the stop and the train",
			#evs == 2 and evs[1].station == reach and evs[1].train == tid and evs[2].station == miss, evs)
		lab.check("Test path audit line", key_of(dev("last_audit")) == "cybersyn-messages.audit-test-path", dev("last_audit"))

		-- A registered stop whose rail is gone: the pathfinder needs a goal on a rail, so Test path must not ask it.
		local cut = read("stations", reach).entity_stop
		local rail = cut.connected_rail
		if lab.check("the reachable stop sits on a rail", rail ~= nil and rail.valid) then
			local saved = { name = rail.name, position = rail.position, direction = rail.direction, force = rail.force,
				surface = rail.surface }
			rail.destroy()
			local seq_cut = seq_now()
			local ok, cr = pcall(dev, "test_path", PI, reach, tid)
			lab.check("Test path on a stop without a rail: no error, says so, no path",
				ok and cr and cr.found == false and cr.no_rail == true
				and key_of(cr.caption) == "cybersyn-gui.test-path-no-rail", ok and cr or tostring(cr))
			lab.check("Test path on a stop without a rail is still audited", #actions_after(seq_cut, ACTION_TEST_PATH) == 1)
			saved.surface.create_entity({ name = saved.name, position = saved.position, direction = saved.direction,
				force = saved.force })
			lab.check("the rail is back under the stop", cut.connected_rail ~= nil and cut.connected_rail.valid)
		end
		-- The stop panel's button, result in the footer.
		dev("relative_open", PI, "stop", reach)
		dev("action_click", PI, "test_path")
		local dump = dev("relative_dump", PI)
		lab.check("stop panel shows the Test path result", mentions(dump.sections.buttons, "cybersyn-gui.test-path-"),
			dump.sections.buttons)
		dev("relative_close", PI)

		-- Explain on an Unserved row: recorded reason, history, setup findings, Test path.
		local rows = remote.call("cybersyn-query", "query_unserved", { limit = 1 })
		if not lab.check("an unserved row exists for Explain", #rows == 1, rows) then return end
		local row = rows[1]
		ctx.explain_row = row
		dev("open", PI)
		dev("explain_open", PI, row.requester, row.item)
		local ex = dev("explain_dump", PI)
		local text = serpent.line(ex.lines, { comment = false })
		lab.check("Explain opens beside the manager", ex.open == true and ex.key.r_id == row.requester, ex.key)
		local reason_key = "cybersyn-diag.chip-" .. string.lower(string.gsub(row.reason, "_", "-"))
		lab.check("Explain shows the recorded reason chip and why line", string.find(text, reason_key, 1, true) ~= nil
			and string.find(text, "cybersyn-gui.unserved-why", 1, true) ~= nil, text)
		-- The why line names the network as the Overview row does (its icon), never the raw signal name.
		lab.check("Explain's why line names the network like the row (no raw signal name)",
			not string.find(text, '"signal%-[AB]"'), text)
		lab.check("Explain shows the change history", string.find(text, "cybersyn-gui.explain-history", 1, true) ~= nil)
		local lb = dev("lint_bits", row.requester)
		local findings = 0
		for _ in string.gmatch(text, "cybersyn%-diag%.lint%-fix%-") do findings = findings + 1 end
		lab.check("Explain lists the station's setup findings (one fix line per lint check)", findings == #lb.checks,
			{ checks = lb.checks, fix_lines = findings })
		local tp = dev("explain_test_path", PI)
		ex = dev("explain_dump", PI)
		lab.check("Explain's Test path writes its result into the frame", tp ~= nil
			and mentions(ex.lines, "cybersyn-gui.test-path-"), ex.lines)
		dev("explain_open", PI, row.requester, row.item)
		lab.check("Explain toggles closed on the same row", dev("explain_dump", PI).open == false)
	end,

	function(ctx)
		-- Breakdown: stuck-request labels read the reason the dispatcher recorded.
		local st = ctx.stations[2] or ctx.stations[1]
		local res = dev("breakdown_failure_labels", "iron-plate", {
			{ item_hash = "iron-plate", r_station_id = st, failure_reason = 1, reason = 9 },
			{ item_hash = "iron-plate", r_station_id = st + 1, failure_reason = 0 },
		})
		local labels = {}
		for _, bar in ipairs(res.bars or {}) do labels[#labels + 1] = key_of(bar.label) end
		table.sort(labels)
		lab.check("Breakdown bars are labelled with the diag reason (unknown without one)",
			lab.same_list(labels, { "cybersyn-diag.chip-p-below-threshold", "cybersyn-gui.unserved-unknown-reason" }), res)
		local tips_ok = true
		for _, bar in ipairs(res.bars or {}) do
			if not mentions(bar.tooltip, key_of(bar.label)) then tips_ok = false end
		end
		lab.check("Breakdown bar tooltips carry the reason label", tips_ok and #(res.bars or {}) == 2, res.bars)
		local full_ok = false
		for _, bar in ipairs(res.bars or {}) do
			if mentions(bar.tooltip, "cybersyn-diag.reason-p-below-threshold") then full_ok = true end
		end
		lab.check("Breakdown bar tooltip adds the reason's full name", full_ok, res.bars)
		lab.check("Breakdown stats list one line per reason", #(res.reasons or {}) == 2, res.reasons)

		-- HUD line: values against the counters, location persisted, off again.
		local hud = dev("hud", PI, true)
		local total = 0
		for _, n in pairs(dev("diag_counts")) do total = total + n end
		-- Headroom oracle = the Overview's "Now": fewest available trains over every network that has a train.
		local avail = read("stats", "available_count") or {}
		local min
		for _, n in pairs(avail) do if not min or n < min then min = n end end
		for _, t in pairs(read("trains")) do
			local nets = {}
			if t.network_name == "signal-each" then
				for n in pairs(type(t.network_mask) == "table" and t.network_mask or {}) do nets[#nets + 1] = n end
			elseif t.network_name then
				nets[1] = t.network_name
			end
			for _, n in ipairs(nets) do
				local a = avail[n] or 0
				if not min or a < min then min = a end
			end
		end
		lab.check("HUD shown when the setting is on", hud.shown == true, hud)
		lab.check("HUD unserved = diag counts", hud.values.unserved == total, { hud = hud.values, counts = total })
		lab.check("HUD free trains = fewest available now", hud.values.headroom == min, { hud = hud.values, avail = avail })
		lab.check("HUD caption", key_of(hud.line1) == "cybersyn-gui.hud-line" and hud.line1[2] ~= nil, hud.line1)
		local loc = dev("hud_move", PI, 100, 200)
		lab.check("HUD position persisted", loc and loc.x == 100 and loc.y == 200, loc)
		hud = dev("hud", PI)
		lab.check("HUD keeps its position on refresh", hud.location and hud.location.x == 100, hud.location)
		hud = dev("hud", PI, false)
		lab.check("HUD removed when the setting is off", hud.shown == false, hud)

		-- Remote interface.
		local open = remote.call("cybersyn", "is_gui_open", PI)
		lab.check("is_gui_open matches the manager state", open == dev("state", PI).is_open, open)
		local toggled = remote.call("cybersyn", "toggle_gui", PI)
		lab.check("toggle_gui flips it", toggled == not open and dev("state", PI).is_open == toggled)
		remote.call("cybersyn", "toggle_gui", PI)
		remote.call("cybersyn", "write_global", nil, "manager", "hud_networks")
		local counts = remote.call("cybersyn-query", "query_counts")
		lab.check("query_counts: unserved = diag counts, free trains = the HUD's", counts.unserved == total
			and counts.free_trains == min, counts)
		lab.check("query_counts writes nothing to storage", read("manager", "hud_networks") == nil)
		local q = remote.call("cybersyn-query", "query_unserved", { limit = 3 })
		local sorted = #q <= 3
		for i = 2, #q do if q[i].first_tick < q[i - 1].first_tick then sorted = false end end
		lab.check("query_unserved: at most the limit, oldest first", sorted, q)
		local qr = remote.call("cybersyn-query", "query_unserved", { reason = "P_BELOW_THRESHOLD", limit = 100 })
		local same = true
		for _, r in ipairs(qr) do if r.reason ~= "P_BELOW_THRESHOLD" then same = false end end
		lab.check("query_unserved filters by reason name", same, qr)
		local qs = remote.call("cybersyn-query", "query_station", ctx.station)
		lab.check("query_station", qs and qs.kind == "station" and qs.id == ctx.station
			and qs.name == read("stations", ctx.station).entity_stop.backer_name, qs)
		local qt = remote.call("cybersyn-query", "query_train", ctx.train_ids[1])
		lab.check("query_train", qt and qt.id == ctx.train_ids[1] and type(qt.status) == "string", qt)
		lab.check("query of an unknown id is nil", remote.call("cybersyn-query", "query_station", 4000000000) == nil
			and remote.call("cybersyn-query", "query_train", 4000000000) == nil)
	end,

	function(ctx)
		-- Every action under the permission matrix: may_act, the button state, the handler's own check (a disabled
		-- button clicked anyway), the confirm step and the audit.
		local st = ctx.station
		for _, m in ipairs(MATRIX) do
			local setting, admin, allowed = m[1], m[2], m[3]
			local tag = setting .. "/" .. (admin and "admin" or "player")
			dev("set_setting", "cybersyn-manager-actions", setting)
			dev("set_admin", PI, admin)
			dev("relative_open", PI, "stop", st)
			lab.check(tag .. ": may_act", dev("may_act", PI) == allowed)
			local b = dev("action_button", PI, "rescan")
			lab.check(tag .. ": Rescan enabled only with the right", b and b.enabled == allowed
				and (allowed or key_of(b.tooltip) == "cybersyn-gui.action-admin-only"), b)
			local seq = seq_now()
			dev("action_click", PI, "rescan", true)
			local armed = dev("action_button", PI, "rescan")
			lab.check(tag .. ": first click arms 'Confirm?' only with the right",
				(key_of(armed.caption) == "cybersyn-gui.action-confirm") == allowed
				and (armed.style == "red_button") == allowed, armed)
			dev("action_click", PI, "rescan", true)
			local evs = actions_after(seq, ACTION_RESCAN)
			lab.check(tag .. ": second click runs and audits only with the right", #evs == (allowed and 1 or 0)
				and (not allowed or (evs[1].station == st and evs[1].station2 == PI)), evs)
			if allowed then
				lab.check(tag .. ": audit line to the force", key_of(dev("last_audit")) == "cybersyn-messages.audit-rescan",
					dev("last_audit"))
			end
			seq = seq_now()
			local d = dev("action_dialog", PI, "recalc", true)
			lab.check(tag .. ": Recalculate train sizes dialog only with the right",
				(d.refused == true) == not allowed and (not allowed or (d.ran == true and d.buttons[1] == "back"
					and d.buttons[2] == "confirm")), d)
			lab.check(tag .. ": Recalculate audited only with the right", #actions_after(seq, ACTION_RECALC) == (allowed and 1 or 0))
		end

		-- Each allowed run re-derived every train's layout; the counts must still add up to the trains.
		lab.check("Recalculate keeps layout_train_count = one per train", layout_counts_ok(), read("layout_train_count"))

		-- Expiry: an armed button falls back after 180 ticks, driven by the manager tick.
		dev("set_setting", "cybersyn-manager-actions", "everyone")
		dev("relative_open", PI, "stop", st)
		dev("action_click", PI, "rescan")
		lab.check("armed before the expiry", key_of(dev("action_button", PI, "rescan").caption) == "cybersyn-gui.action-confirm")
		lab.wait(300)
	end,

	function(ctx)
		local b = dev("action_button", PI, "rescan")
		lab.check("the armed button expired after 180 ticks (manager tick)", b and key_of(b.caption) == "cybersyn-gui.action-rescan"
			and b.style == "button", b)
		lab.check("no confirm left: the expiry walk is off again", read("manager", "confirm_any") == nil)
		local seq = seq_now()
		dev("action_click", PI, "rescan")
		lab.check("a click after the expiry and its grace arms again instead of running", #actions_after(seq, ACTION_RESCAN) == 0)
		lab.check("an armed button turns the expiry walk on", read("manager", "confirm_any") == true)
		dev("relative_close", PI)

		-- Fail delivery and send home: refused under nobody, then run as an admin under admins.
		local trains = read("trains")
		local tid
		for _, id in ipairs(ctx.train_ids) do
			local t = trains[id]
			if t and t.manifest and t.status >= 1 and t.status <= 4 then
				tid = id
				break
			end
		end
		if not tid then
			lab.skip("fail delivery", "no train on a delivery at this point of the run")
		else
			dev("set_setting", "cybersyn-manager-actions", "nobody")
			dev("set_admin", PI, true)
			dev("relative_open", PI, "train", tid)
			local fb = dev("action_button", PI, "fail_delivery")
			lab.check("Send home disabled under nobody", fb and fb.enabled == false, fb)
			dev("action_click", PI, "fail_delivery", true)
			dev("action_click", PI, "fail_delivery", true)
			lab.check("Send home refused under nobody (handler check)", read("trains", tid).manifest ~= nil)
			dev("set_setting", "cybersyn-manager-actions", "admins")
			dev("relative_open", PI, "train", tid)
			local seq2 = seq_now()
			dev("action_click", PI, "fail_delivery")
			lab.check("Send home arms 'Confirm?'", key_of(dev("action_button", PI, "fail_delivery").caption) == "cybersyn-gui.action-confirm")
			dev("action_click", PI, "fail_delivery")
			local t = read("trains", tid)
			lab.check("Send home: delivery failed, train heading to its depot", t.manifest == nil and t.status == STATUS_TO_D
				and t.p_station_id == nil and t.r_station_id == nil, { status = t.status, manifest = t.manifest })
			local evs = actions_after(seq2, ACTION_FAIL)
			lab.check("Send home audited with the train", #evs == 1 and evs[1].train == tid and evs[1].station2 == PI, evs)
			lab.check("Send home force line", key_of(dev("last_audit")) == "cybersyn-messages.audit-fail-delivery", dev("last_audit"))
			local after = dev("action_button", PI, "fail_delivery")
			lab.check("Send home disabled once the train has no delivery", after and after.enabled == false, after)
			dev("relative_close", PI)
		end

		-- Refresh allow-lists: a job of n trains per update (2 here, 50 by default), never one loop.
		dev("set_setting", "cybersyn-manager-actions", "everyone")
		dev("set_admin", PI, false)
		dev("repair_job_chunk", 2)
		local seq3 = seq_now()
		local d = dev("action_dialog", PI, "allow", true)
		local job = dev("repair_job")
		lab.check("Refresh allow-lists starts a job over every train", d.ran == true and job.running and job.i == 0
			and job.total == #ctx.train_ids, { d = d, job = job })
		local chunks, last_i = 0, 0
		local steps_ok = true
		while dev("repair_job").running and chunks < 100 do
			dev("repair_job", true)
			chunks = chunks + 1
			local j = dev("repair_job")
			local i = j.running and j.i or #ctx.train_ids
			if i - last_i > 2 then steps_ok = false end
			last_i = i
		end
		lab.check("allow-list job advanced at most 2 trains per step", steps_ok)
		lab.check("allow-list job took ceil(n / 2) steps", chunks == math.ceil(#ctx.train_ids / 2),
			{ chunks = chunks, trains = #ctx.train_ids })
		local last = dev("repair_job").last
		lab.check("allow-list job refreshed every train", last and last.refreshed == #ctx.train_ids, last)
		lab.check("allow-list job audited", #actions_after(seq3, ACTION_ALLOW) == 1)
		lab.check("allow-list job keeps layout_train_count = one per train", layout_counts_ok(), read("layout_train_count"))

		-- The stop-visit budget: a train whose layout no other train shares walks every stop twice, so with a budget
		-- of one stop visit each such train gets a chunk of its own, while trains sharing a layout still batch.
		local singles = 0
		for _, n in pairs(read("layout_train_count")) do if n == 1 then singles = singles + 1 end end
		dev("repair_job_chunk", 50, 1)
		d = dev("action_dialog", PI, "allow", true)
		local spent_ok, steps = true, 0
		last_i = 0
		while dev("repair_job").running and steps < 100 do
			local j = dev("repair_job", true)
			steps = steps + 1
			if j.running and j.spent and j.spent > 1 and j.i - (last_i or 0) > 1 then spent_ok = false end
			last_i = j.i
		end
		local lastb = dev("repair_job").last
		lab.check("budgeted job refreshed every train", d.ran == true and lastb and lastb.refreshed == #ctx.train_ids, lastb)
		-- layout-dev's trains share their layouts (cost 0), so they batch; the split itself is in the unit test and pY.
		lab.check("budgeted job: one chunk per singleton-layout train at least, shared layouts batch",
			lastb and lastb.chunks >= singles and spent_ok
			and (singles > 0 or lastb.chunks == math.ceil(#ctx.train_ids / 50)), { chunks = lastb and lastb.chunks, singles = singles })
		lab.check("budgeted job keeps layout_train_count = one per train", layout_counts_ok(), read("layout_train_count"))
		dev("repair_job_chunk", nil)

		dev("set_setting", "cybersyn-manager-actions", ctx.actions)
		dev("set_admin", PI, ctx.admin)
		if not ctx.was_open then dev("close", PI) end
	end,
})
