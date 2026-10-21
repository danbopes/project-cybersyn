-- Phase 10 extras and actions (PLAN3 §11, §4.14) as PLAN4 D13 trimmed them: path trace objects and cleanup, pins
-- through the shared link click and the panel tool, the trains-window button, Explain on an Unserved row, the
-- Breakdown failure labels, the HUD values against the counters, the remote interface, Send home under admins /
-- everyone / nobody x admin / non-admin with the confirm step, its expiry and the audit (manual_action event + the
-- force line) on a train its own case keeps on a delivery, Recount deliveries on a deliberately leaked counter
-- (PLAN4 D10), the stop panel hidden on narrow screens (D16), named alerts in Last events and the alert chip
-- (D15 item 9), and the chunked allow-list job behind its console command.

local DEV = "cybersyn-manager-dev"
local PI = 1
local ACTION_FAIL, ACTION_ALLOW, ACTION_RECOUNT = 4, 6, 8
local STATUS_TO_P, STATUS_TO_D = 1, 5
-- The delivery case's row and network (free in cases.lua's table and the other lab files).
local CASE_K, CASE_NET = 86, "signal-Z"
local SPEED = 20

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


local STEPS = {
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
		lab.check("stop panel: no Test path tool, no Rescan station", dev("action_button", PI, "test_path") == nil
			and dev("action_button", PI, "rescan") == nil)

		-- The trains-window button (the click emulated: an offline player cannot open the vanilla trains window).
		dev("close", PI)
		local tg = dev("trains_gui_button", PI)
		lab.check("trains_gui anchor exists with its caption", tg.exists and tg.anchor_gui == "trains-gui"
			and key_of(tg.caption) == "cybersyn-gui.trains-gui-open-manager", tg)
		lab.check("trains_gui button opens the manager on Trains", tg.opened == true and tg.tab == "trains_tab", tg)
	end,

	function(ctx)
		-- Explain on an Unserved row: recorded reason, history, setup findings; no Test path (PLAN4 D13).
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
		lab.check("Explain has no Test path section or button", not mentions(ex.lines, "test-path"), ex.lines)
		dev("explain_open", PI, row.requester, row.item)
		lab.check("Explain toggles closed on the same row", dev("explain_dump", PI).open == false)
	end,

	function(ctx)
		-- D5-1: a requester named with many icons squashes the title instead of pushing the X off the frame; the title's
		-- tooltip carries the whole caption and the whole bar drags. Opened through the real Why chip, closed by the X.
		local rows = remote.call("cybersyn-query", "query_unserved", { limit = 2 })
		if not lab.check("two unserved rows exist for the long-name Explain", #rows == 2, rows) then return end
		ctx.long_rows = rows
		local stop = read("stations", rows[1].requester).entity_stop
		ctx.long_stop, ctx.long_saved = stop, stop.backer_name
		stop.backer_name = "[item=iron-gear-wheel][item=wooden-chest]/[item=copper-cable]/[item=fast-inserter]/[item=pipe]"
			.. "/[item=steel-chest] Requestor for [item=automation-science-pack]"
		dev("open", PI)
		dev("select_tab", PI, "overview")
		lab.big_screen(PI)
		-- A cold open shows placeholder rows until the first collector pass completes.
		lab.wait_until(function()
			dev("update", PI, 1)
			local d = dev("dump", PI, "overview")
			return type(d) == "table" and #d.lists.unserved.rendered > 0
		end, 1800)
	end,

	function(ctx)
		local rows = ctx.long_rows
		if not rows then return end
		local row, other = rows[1], rows[2]
		local stop, saved = ctx.long_stop, ctx.long_saved
		local function chip_index(r)
			local tbl
			local function walk(node)
				if node.name == "overview_unserved_table" then tbl = node return end
				for _, c in ipairs(node.children) do if not tbl then walk(c) end end
			end
			walk(game.get_player(PI).gui.screen)
			if not tbl then return nil end
			for k, cell in ipairs(tbl.children) do
				local chip = cell.children[1]
				local tags = chip and chip.tags
				if tags and tags.r_id == r.requester and tags.hash == r.item and cell.type ~= "label" then return k end
			end
		end
		local k = chip_index(row)
		local res = k and dev("click", PI, "overview_unserved_table", { k, 1 })
		local ex = dev("explain_dump", PI)
		lab.check("the Why chip opens Explain", res == true and ex.open == true and ex.key.r_id == row.requester, { k = k, res = res })
		if ex.open then
			lab.check("Explain keeps its X: a close frame_action_button", ex.close.exists == true
				and ex.close.style == "frame_action_button" and ex.close.sprite == "utility/close", ex.close)
			lab.check("Explain's title squashes and carries the whole caption as its tooltip", ex.title_squashable == true
				and serpent.line(ex.title_tooltip) == serpent.line(ex.title)
				and string.find(serpent.line(ex.title), "Requestor for", 1, true) ~= nil, { ex.title, ex.title_tooltip })
			lab.check("the whole Explain title bar drags the frame", ex.drag == "cybersyn_explain"
				and ex.title_drag == "cybersyn_explain", { ex.drag, ex.title_drag })
			lab.check("the X closes Explain", dev("explain_click_close", PI) == true and dev("explain_dump", PI).open == false
				and read("manager", "players", PI, "explain") == nil, dev("explain_dump", PI))
		end
		-- One frame at a time: opening another row replaces the first.
		dev("explain_open", PI, row.requester, row.item)
		dev("explain_open", PI, other.requester, other.item)
		local frames = 0
		for _, c in ipairs(game.get_player(PI).gui.screen.children) do
			if c.name == "cybersyn_explain" then frames = frames + 1 end
		end
		local key = dev("explain_dump", PI).key
		lab.check("Explain is single-instance", frames == 1 and key and key.r_id == other.requester, { frames = frames, key = key })
		dev("explain_close", PI)
		stop.backer_name = saved
		dev("update", PI, 2)
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
		-- PLAN4 D16: two labelled numbers, the keys the Overview's Fleet headroom "Now" line reads too.
		lab.check("HUD caption: 'Unserved now n · Free trains now n'", type(hud.line1) == "table" and hud.line1[1] == ""
			and key_of(hud.line1[2]) == "cybersyn-gui.hud-unserved" and hud.line1[4] == tostring(total)
			and key_of(hud.line1[6]) == "cybersyn-gui.hud-headroom-now" and hud.line1[8] == tostring(min), hud.line1)
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
		-- Trains kept on a delivery for the actions: provider, requester and three depots with a train each on a row of
		-- their own; the trains are unfuelled at their depots so the dispatch holds them there (cases.lua's rule for a
		-- delivery in progress). Three, because each Send home that runs ends one delivery for good.
		local ok, case = pcall(function()
			local c = cases.base("EXTRAS", { k = CASE_K }, { network = CASE_NET })
			c.d2 = cases.depot(c, cases.X_D2, "rc-EXTRAS-depot-2")
			c.t2 = cases.train(c, cases.X_D2 + 6, c.d2)
			c.d3 = cases.depot(c, cases.X_D3, "rc-EXTRAS-depot-3")
			c.t3 = cases.train(c, cases.X_D3 + 6, c.d3)
			c.p = cases.station(c, { name = cases.sname(c, "p"), x = cases.X_P[1], bits = 1 + 4,
				signals = cases.provide(c, 30000) })
			c.r = cases.station(c, { name = cases.sname(c, "r"), x = cases.X_R[1], bits = 2 + 4 })
			return cases.finish(c)
		end)
		if not lab.check("delivery case builds", ok, not ok and case or nil) then return end
		ctx.case = case
		lab.wait_until(function() return cases.trains_ready(case) end, 3600, SPEED)
	end,

	function(ctx)
		local case = ctx.case
		if not case then return end
		lab.check("delivery case: trains parked", cases.trains_ready(case))
		for _, t in ipairs(case.train_entities) do cases.unfuel(t) end
		-- Three trains' worth (40 stacks of 100 each) above the threshold, so the planner sends all three in turn.
		cases.set_signals(case.r, cases.request(case, -12000, 1000))
		lab.wait_until(function() return cases.dispatched(case, { 1, 2, 3 }, "r_station_id", case.r.id) end, 7200, SPEED)
	end,

	function(ctx)
		local case = ctx.case
		if not case then return end
		cases.set_signals(case.r, {})
		ctx.tids = { case.trains[1], case.trains[2], case.trains[3] }
		if not lab.check("delivery case: the three trains are dispatched and held",
			cases.dispatched(case, { 1, 2, 3 }, "r_station_id", case.r.id)) then
			return
		end
		ctx.held = true
		ctx.counts = { p = read("stations", case.p.id, "deliveries_total"), r = read("stations", case.r.id, "deliveries_total") }
		lab.check("delivery case: each end counts the three deliveries", ctx.counts.p == 3 and ctx.counts.r == 3, ctx.counts)
		local tid = ctx.tids[1]

		local footer = dev("relative_open", PI, "train", tid).sections.buttons
		local names = {}
		local function walk(node)
			if type(node) ~= "table" then return end
			if node.name then names[node.name] = true end
			for _, c in ipairs(node.children or {}) do walk(c) end
			for _, c in ipairs(node.content or {}) do walk(c) end
		end
		walk(footer)
		lab.check("train panel footer: Open in manager, Send home, Path trace, Pin; no Locate (PLAN5 D5-7), no Recalculate, no Refresh",
			names.open_manager and not names.locate and names.fail_delivery and names.path_trace and names.pin
			and not names.recalc and not names.allow_lists, names)
		dev("relative_close", PI)

		-- Expiry: an armed button falls back after 180 ticks, driven by the manager tick.
		dev("set_setting", "cybersyn-manager-actions", "everyone")
		dev("set_admin", PI, false)
		dev("relative_open", PI, "train", tid)
		dev("action_click", PI, "fail_delivery")
		lab.check("armed before the expiry",
			key_of(dev("action_button", PI, "fail_delivery").caption) == "cybersyn-gui.action-confirm")
		lab.wait(300)
	end,

	function(ctx)
		if not ctx.held then return end
		local tid = ctx.tids[1]
		local b = dev("action_button", PI, "fail_delivery")
		lab.check("the armed button expired after 180 ticks (manager tick)", b
			and key_of(b.caption) == "cybersyn-gui.action-fail-delivery" and b.style == "button", b)
		lab.check("no confirm left: the expiry walk is off again", read("manager", "confirm_any") == nil)
		local seq = seq_now()
		dev("action_click", PI, "fail_delivery")
		lab.check("a click after the expiry and its grace arms again instead of running",
			#actions_after(seq, ACTION_FAIL) == 0 and read("trains", tid, "manifest") ~= nil, read("trains", tid))
		lab.check("an armed button turns the expiry walk on", read("manager", "confirm_any") == true)
		dev("relative_close", PI)

		-- Named alerts (PLAN4 D15 item 9): an alert row in Last events reads the alert's name, not "Alert"; the
		-- train's warning triangle gets a chip with the same name.
		local case = ctx.case
		local tid = ctx.tids[1]
		dev("diag_event", "alert", "warning", { code = 1, train = tid })
		dev("diag_event", "alert", "warning", { code = 11, station = case.r.id })
		-- active_alerts exists once Cybersyn raised its first alert; this run may not have one yet.
		if not read("active_alerts") then remote.call("cybersyn", "write_global", {}, "active_alerts") end
		remote.call("cybersyn", "write_global", { case.train_entities[1], 1, read("total_ticks") }, "active_alerts", tid)
		local td = dev("relative_open", PI, "train", tid)
		local ev = serpent.line(td.sections.events, { comment = false })
		lab.check("train Last events names the alert (Train stuck), not 'Alert'", mentions(ev, "cybersyn-diag.alert-stuck")
			and not mentions(ev, "cybersyn-diag.kind-alert"), td.sections.events)
		local alert = td.sections.alert
		lab.check("train panel: the warning triangle has a chip naming the alert", alert and alert.visible
			and mentions(alert.content, "cybersyn-diag.alert-stuck"), alert)
		local alert_label
		local function find_alert(v)
			for _, c in ipairs(v or {}) do
				if c.name == "alert_chip" then alert_label = c end
				find_alert(c.children)
			end
		end
		find_alert(alert and alert.content)
		lab.check("…as the panels' plain marker label: nothing to click, nothing that looks clickable", alert_label ~= nil
			and alert_label.type == "label" and alert_label.style == "cybersyn_marker_orange" and not alert_label.handler,
			alert_label)
		remote.call("cybersyn", "write_global", nil, "active_alerts", tid)
		dev("tick", 1)
		td = dev("relative_dump", PI)
		lab.check("the chip goes with the alert", td.sections.alert and td.sections.alert.visible == false, td.sections.alert)
		dev("relative_close", PI)
		local sd = dev("relative_open", PI, "stop", case.r.id)
		ev = serpent.line(sd.sections.events, { comment = false })
		lab.check("stop Last events names the alert (No train available), not 'Alert'",
			mentions(ev, "cybersyn-diag.alert-missing-train") and not mentions(ev, "cybersyn-diag.kind-alert"),
			sd.sections.events)
		dev("relative_close", PI)

		-- The stop panel on narrow screens (PLAN4 D16): hidden where vanilla 1,067 + 300 logical px do not fit.
		for _, sc in ipairs({ { 1920, 1080, 1.5, false }, { 1920, 1080, 2.0, false }, { 3840, 2160, 1.5, true },
			{ 1920, 1080, 1.0, true } }) do
			dev("set_layout", PI, sc[1], sc[2], sc[3])
			local d = dev("relative_open", PI, "stop", case.p.id)
			local shown = d.mounts.stop and d.mounts.stop.visible == true
			lab.check(sc[1] .. "x" .. sc[2] .. " at " .. sc[3] .. ": stop panel " .. (sc[4] and "shown" or "hidden"),
				shown == sc[4] and (d.open ~= nil) and (d.open.narrow == true) == not sc[4], { mounts = d.mounts, open = d.open })
			dev("relative_close", PI)
		end
		-- A display change while the stop's window is open: hidden on the narrow screen, shown (and filled) again.
		dev("set_layout", PI, 3840, 2160, 1.5)
		dev("relative_open", PI, "stop", case.p.id)
		dev("set_layout", PI, 1920, 1080, 1.5)
		local d = dev("relative_display_changed", PI)
		lab.check("display change to 1080p at 1.5 hides the open stop panel", d.mounts.stop.visible == false
			and d.open.narrow == true, d.mounts)
		local refreshes = d.refreshes
		dev("tick", 3)
		lab.check("a hidden stop panel is not refreshed", dev("relative_dump", PI).refreshes == refreshes)
		dev("set_layout", PI, 3840, 2160, 1.5)
		d = dev("relative_display_changed", PI)
		lab.check("display change back to 4K at 1.5 shows it again, rendered", d.mounts.stop.visible == true
			and d.open.narrow == nil and d.sections.head and d.sections.head.visible == true, d.mounts)
		dev("relative_close", PI)
		lab.big_screen(PI)

		-- Recount deliveries (PLAN4 D10): a leaked counter at the provider, one delivery too many in total and the
		-- per-item amount pushed 150 further, both written behind the dispatcher's back.
		local p = case.p.id
		ctx.good = { total = read("stations", p, "deliveries_total"), item = read("stations", p, "deliveries", case.item) }
		local w = function(v, ...) remote.call("cybersyn", "write_global", v, ...) end
		w(ctx.good.total + 1, "stations", p, "deliveries_total")
		w((ctx.good.item or 0) - 150, "stations", p, "deliveries", case.item)
		dev("collect")
		dev("lint_run")
		lab.wait(1200, SPEED)
	end,

	function(ctx)
		if not ctx.held then return end
		local case, p = ctx.case, ctx.case.p.id
		dev("collect")
		dev("lint_run")
		local f = dev("lint_findings", p, "phantom")[1]
		lab.check("the leak is a phantom finding after two passes: one delivery more counted than trains bound", f ~= nil and f.a == ctx.good.total + 1
			and f.b == ctx.good.total, f)
		dev("set_setting", "cybersyn-manager-actions", "admins")
		dev("set_admin", PI, false)
		local d = dev("relative_open", PI, "stop", p)
		local b = dev("action_button", PI, "recount_deliveries")
		lab.check("Recount deliveries sits on the finding's line, disabled for a non-admin under admins",
			b ~= nil and b.enabled == false and key_of(b.tooltip) == "cybersyn-gui.action-admin-only"
			and mentions(d.sections.setup, "recount_deliveries"), { b = b, setup = d.sections.setup })
		local seq = seq_now()
		dev("action_click", PI, "recount_deliveries", true)
		dev("action_click", PI, "recount_deliveries", true)
		lab.check("Recount refused by the handler without the right", #actions_after(seq, ACTION_RECOUNT) == 0
			and read("stations", p, "deliveries_total") == ctx.good.total + 1)
		dev("set_admin", PI, true)
		dev("relative_open", PI, "stop", p)
		dev("last_audit", true)
		seq = seq_now()
		dev("action_click", PI, "recount_deliveries")
		lab.check("Recount arms 'Confirm?'",
			key_of(dev("action_button", PI, "recount_deliveries").caption) == "cybersyn-gui.action-confirm")
		dev("action_click", PI, "recount_deliveries")
		local after = { total = read("stations", p, "deliveries_total"), item = read("stations", p, "deliveries", case.item) }
		lab.check("Recount corrects deliveries_total and deliveries[item] from the bound train",
			after.total == ctx.good.total and after.item == ctx.good.item, { after = after, want = ctx.good })
		local evs = actions_after(seq, ACTION_RECOUNT)
		lab.check("Recount writes one manual_action row for the station", #evs == 1 and evs[1].station == p
			and evs[1].station2 == PI, evs)
		local audit = dev("last_audit")
		lab.check("Recount force line names the counts before and after", key_of(audit) == "cybersyn-gui.action-recount-done"
			and audit[4] == tostring(ctx.good.total + 1) and audit[5] == tostring(ctx.good.total), audit)
		lab.check("Recount leaves the requester alone", read("stations", case.r.id, "deliveries_total") == ctx.counts.r)
		dev("collect")
		dev("lint_run")
		lab.check("the finding clears on the next pass", dev("lint_findings", p, "phantom")[1] == nil,
			dev("lint_findings", p, "phantom"))
		-- The panel has not refreshed since that pass, so its button outlives the finding: the click checks again.
		local w = function(v, ...) remote.call("cybersyn", "write_global", v, ...) end
		w(ctx.good.total + 1, "stations", p, "deliveries_total")
		seq = seq_now()
		local stale = dev("action_click", PI, "recount_deliveries")
		lab.check("a Recount button left over from a cleared finding is refused", stale.before ~= nil
			and stale.confirm == nil and #actions_after(seq, ACTION_RECOUNT) == 0
			and read("stations", p, "deliveries_total") == ctx.good.total + 1, stale)
		w(ctx.good.total, "stations", p, "deliveries_total")
		dev("relative_close", PI)

		dev("set_admin", PI, ctx.admin)

		-- Send home under the permission matrix: may_act, the button state, the handler's own check (a disabled
		-- button clicked anyway), the confirm step and the audit. A run ends that train's delivery, so each setting
		-- takes the next train still on one; the refused settings go first, the three allowed ones take a train each.
		local order = {}
		for _, m in ipairs(MATRIX) do if not m[3] then order[#order + 1] = m end end
		for _, m in ipairs(MATRIX) do if m[3] then order[#order + 1] = m end end
		for _, m in ipairs(order) do
			local setting, admin, allowed = m[1], m[2], m[3]
			local tag = setting .. "/" .. (admin and "admin" or "player")
			local tid
			for _, id in ipairs(ctx.tids) do
				if not tid and read("trains", id, "manifest") then tid = id end
			end
			if not lab.check(tag .. ": a train of the case is still on its delivery", tid ~= nil) then break end
			dev("set_setting", "cybersyn-manager-actions", setting)
			dev("set_admin", PI, admin)
			local before = { p = read("stations", case.p.id, "deliveries_total"), r = read("stations", case.r.id, "deliveries_total") }
			dev("relative_open", PI, "train", tid)
			lab.check(tag .. ": may_act", dev("may_act", PI) == allowed)
			local b = dev("action_button", PI, "fail_delivery")
			lab.check(tag .. ": Send home enabled only with the right", b and b.enabled == allowed
				and (allowed or key_of(b.tooltip) == "cybersyn-gui.action-admin-only"), b)
			local seq = seq_now()
			dev("action_click", PI, "fail_delivery", true)
			local armed = dev("action_button", PI, "fail_delivery")
			lab.check(tag .. ": first click arms 'Confirm?' only with the right",
				(key_of(armed.caption) == "cybersyn-gui.action-confirm") == allowed
				and (armed.style == "red_button") == allowed, armed)
			dev("action_click", PI, "fail_delivery", true)
			local evs = actions_after(seq, ACTION_FAIL)
			lab.check(tag .. ": second click runs and audits only with the right", #evs == (allowed and 1 or 0)
				and (not allowed or (evs[1].train == tid and evs[1].station2 == PI)), evs)
			local t = read("trains", tid)
			lab.check(tag .. ": the delivery ends only with the right", (t.manifest == nil) == allowed,
				{ status = t.status, manifest = t.manifest })
			if allowed then
				lab.check(tag .. ": audit line to the force",
					key_of(dev("last_audit")) == "cybersyn-messages.audit-fail-delivery", dev("last_audit"))
				lab.check(tag .. ": both ends stop counting the delivery, the train heads home", t.p_station_id == nil
					and t.r_station_id == nil and read("stations", case.p.id, "deliveries_total") == before.p - 1
					and read("stations", case.r.id, "deliveries_total") == before.r - 1, before)
				local after = dev("action_button", PI, "fail_delivery")
				lab.check(tag .. ": Send home disabled once the train has no delivery", after and after.enabled == false, after)
			end
			dev("relative_close", PI)
		end
		case.cleanup()
		ctx.case = nil
	end,

	function(ctx)
		-- Refresh allow-lists: off the panel (PLAN4 D13), a console command; a job of n trains per update (2 here, 50 by
		-- default), never one loop.
		local n_trains = 0
		for _ in pairs(read("trains")) do n_trains = n_trains + 1 end
		dev("set_setting", "cybersyn-manager-actions", "nobody")
		dev("set_admin", PI, false)
		local seq0 = seq_now()
		dev("run_command", "cybersyn-refresh-allow-lists", PI)
		lab.check("/cybersyn-refresh-allow-lists refused without the right", not dev("repair_job").running
			and #actions_after(seq0, ACTION_ALLOW) == 0)
		dev("set_setting", "cybersyn-manager-actions", "everyone")
		dev("repair_job_chunk", 2)
		local seq3 = seq_now()
		dev("run_command", "cybersyn-refresh-allow-lists", PI)
		local job = dev("repair_job")
		lab.check("Refresh allow-lists starts a job over every train", job.running and job.i == 0
			and job.total == n_trains, job)
		local chunks, last_i = 0, 0
		local steps_ok = true
		while dev("repair_job").running and chunks < 100 do
			dev("repair_job", true)
			chunks = chunks + 1
			local j = dev("repair_job")
			local i = j.running and j.i or n_trains
			if i - last_i > 2 then steps_ok = false end
			last_i = i
		end
		lab.check("allow-list job advanced at most 2 trains per step", steps_ok)
		lab.check("allow-list job took ceil(n / 2) steps", chunks == math.ceil(n_trains / 2),
			{ chunks = chunks, trains = n_trains })
		local last = dev("repair_job").last
		lab.check("allow-list job refreshed every train", last and last.refreshed == n_trains, last)
		lab.check("allow-list job audited", #actions_after(seq3, ACTION_ALLOW) == 1)
		lab.check("allow-list job keeps layout_train_count = one per train", layout_counts_ok(), read("layout_train_count"))

		-- The stop-visit budget: a train whose layout no other train shares walks every stop twice, so with a budget
		-- of one stop visit each such train gets a chunk of its own, while trains sharing a layout still batch.
		local singles = 0
		for _, n in pairs(read("layout_train_count")) do if n == 1 then singles = singles + 1 end end
		dev("repair_job_chunk", 50, 1)
		dev("run_command", "cybersyn-refresh-allow-lists", PI)
		local spent_ok, steps = true, 0
		last_i = 0
		while dev("repair_job").running and steps < 100 do
			local j = dev("repair_job", true)
			steps = steps + 1
			if j.running and j.spent and j.spent > 1 and j.i - (last_i or 0) > 1 then spent_ok = false end
			last_i = j.i
		end
		local lastb = dev("repair_job").last
		lab.check("budgeted job refreshed every train", lastb and lastb.refreshed == n_trains, lastb)
		-- layout-dev's trains share their layouts (cost 0), so they batch; the split itself is in the unit test and pY.
		lab.check("budgeted job: one chunk per singleton-layout train at least, shared layouts batch",
			lastb and lastb.chunks >= singles and spent_ok
			and (singles > 0 or lastb.chunks == math.ceil(n_trains / 50)), { chunks = lastb and lastb.chunks, singles = singles })
		lab.check("budgeted job keeps layout_train_count = one per train", layout_counts_ok(), read("layout_train_count"))
		dev("repair_job_chunk", nil)

		dev("set_setting", "cybersyn-manager-actions", ctx.actions)
		dev("set_admin", PI, ctx.admin)
		if ctx.case then ctx.case.cleanup() end
		if not ctx.was_open then dev("close", PI) end
	end,
}

lab.suite("39_extras", STEPS)
