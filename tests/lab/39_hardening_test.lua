-- Phase 7 hardening (PLAN3 §5 row 7): the one Escape rule for every overlay (Explain, the item drill-down, the Trains
-- pane, a focused search) on pinned and unpinned windows, the modal action dialog and its hand-back, lint transitions
-- not logged twice after a dropped half pass, the per-item station index behind the drill-down, the Trains table on
-- a narrow window, relative.tick's open-panel flag and the growth sampler.
-- Escape is emulated as the engine does it: player.opened set to nil raises on_gui_closed for the window.

local DEV = "cybersyn-manager-dev"
local PI = 1

local function dev(fn, ...)
	return remote.call(DEV, fn, ...)
end

local function read(...)
	return (remote.call("cybersyn", "read_global", ...))
end

local function player()
	return game.get_player(PI)
end

local function window()
	return player().gui.screen.manager_window
end

local function pd_field(name)
	return read("manager", "players", PI, name)
end

--- Escape: the engine clears player.opened first, which raises on_gui_closed of the window.
local function escape()
	player().opened = nil
end

--- The deferred hand-back of player.opened after an Escape, as the next planner or export tick runs it.
local function settle()
	local pending = read("manager", "pane_escapes")
	if pending and pending[PI] then
		remote.call("cybersyn", "write_global", game.tick - 1, "manager", "pane_escapes", PI, "tick")
	end
	dev("pane_escapes", PI, true)
end

--- The Overview's ack button of an Unserved row, and the row's wait caption (the cell before it).
local function ack_button(row)
	local w = window()
	if not w then return nil end
	local function find(e)
		if e.type == "table" and e.name == "overview_unserved_table" then return e end
		for _, c in pairs(e.children) do
			local t = find(c)
			if t then return t end
		end
	end
	local tbl = find(w)
	if not tbl then return nil end
	local cells = tbl.children
	for i, c in ipairs(cells) do
		local t = c.tags
		if c.type == "sprite-button" and c.style.name == "cybersyn_unserved_ack" and t.r_id == row.requester
			and t.hash == row.item then
			local wait = cells[i - 1]
			return c, wait and wait.caption
		end
	end
end

local function an_unserved_row()
	local rows = remote.call("cybersyn-query", "query_unserved", { limit = 1 })
	return rows[1]
end

local function lint_events_for(station, after_seq)
	local n = 0
	for _, ev in ipairs(dev("diag_events", after_seq, 4096)) do
		if ev.kind == "lint" and ev.station == station then n = n + 1 end
	end
	return n
end

lab.suite("39_hardening", {
	-- One rule for every overlay, pinned window (dev open pins it): an overlay takes player.opened, Escape peels the top
	-- one and the window takes player.opened back while another overlay remains, then gives it up.
	function(ctx)
		-- A window an earlier suite left open unpinned still holds player.opened; this case starts from a fresh one.
		dev("close", PI)
		dev("open", PI)
		lab.big_screen(PI)
		dev("select_tab", PI, "inventory")
		lab.check("pinned window without overlays does not hold player.opened", player().opened == nil, player().opened)
		local row = an_unserved_row()
		if not lab.check("an unserved row exists", row ~= nil) then return end
		ctx.row = row
		dev("open_item", PI, row.item)
		lab.check("the drill-down on a pinned window takes player.opened", player().opened == window()
			and pd_field("overlay_took") == true, pd_field("overlay_took"))
		dev("explain_open", PI, row.requester, row.item)
		lab.check("Explain opens over it", dev("explain_dump", PI).open == true)
		escape()
		lab.check("a pinned window's Escape closes nothing in its own tick (another GUI may be replacing the window)",
			dev("explain_dump", PI).open == true and dev("item_dump", PI).open)
		settle()
		lab.check("Escape closes Explain first; the drill-down and the window stay",
			dev("explain_dump", PI).open == false and dev("item_dump", PI).open and dev("state", PI).is_open)
		lab.check("with an overlay left, the pinned window takes player.opened back", player().opened == window()
			and pd_field("overlay_took") == true)
		escape()
		settle()
		lab.check("the next Escape closes the drill-down", not dev("item_dump", PI).open and dev("state", PI).is_open)
		lab.check("with none left, the pinned window gives player.opened up", player().opened == nil
			and pd_field("overlay_took") == nil, { player().opened, pd_field("overlay_took") })
		escape()
		lab.check("Escape on a pinned window without overlays does nothing", dev("state", PI).is_open)

		-- The pane counts too, and the × gives player.opened up with the last overlay.
		dev("select_tab", PI, "trains")
		local tid = next(read("trains"))
		dev("select_train", PI, tid)
		lab.check("the Trains pane on a pinned window takes player.opened", player().opened == window())
		dev("deselect_train", PI)
		lab.check("closing it by its own control gives player.opened up", player().opened == nil
			and pd_field("overlay_took") == nil)
		-- A search field with the keyboard is the top overlay. With no GUI open at all the client makes Ctrl+F the
		-- map search, so the window leaves it; with an overlay holding player.opened, Ctrl+F is the window's.
		dev("select_tab", PI, "stations")
		dev("search_input", PI)
		lab.check("Ctrl+F on a pinned window with no GUI open is left to the game", player().opened == nil
			and pd_field("search_focused") == nil)
		dev("explain_open", PI, row.requester, row.item)
		dev("search_input", PI)
		lab.check("Ctrl+F on a pinned window with an overlay: the search has the keyboard", player().opened == window()
			and pd_field("search_focused") == true)
		dev("set_filter", PI, { query = "stn-1" })
		escape()
		settle()
		lab.check("Escape clears and closes the search, Explain and the window stay",
			read("manager", "players", PI, "search_query") == nil and dev("state", PI).is_open
			and dev("explain_dump", PI).open == true)
		escape()
		settle()
		lab.check("and with Explain closed the pinned window gives player.opened up again", player().opened == nil
			and dev("explain_dump", PI).open == false)
	end,

	-- A pinned window stays on screen through other GUIs and remote view (PLAN3 §1), its overlays with it: on_gui_closed
	-- cannot tell Escape from a GUI replacing the window, so the overlay waits for a later tick.
	function(ctx)
		dev("select_tab", PI, "trains")
		local tid = next(read("trains"))
		ctx.tid = tid
		dev("select_train", PI, tid)
		lab.check("pinned + pane: the window holds player.opened", player().opened == window())
		-- An entity clicked in the world: the engine closes the window, then opens the entity's GUI.
		escape()
		local station = next(read("stations"))
		dev("stop_gui_opened", PI, station)
		lab.check("a GUI replacing a pinned window keeps the pane and its train", read("manager", "players", PI, "selected_train")
			== tid and dev("pane_dump", PI).visible and dev("state", PI).is_open, read("manager", "players", PI, "selected_train"))
		lab.check("nothing waits any more", read("manager", "pane_escapes") == nil)
		dev("relative_close", PI)
		lab.check("the window waits to take player.opened back", pd_field("overlay_took") == nil
			and read("manager", "players", PI, "restore_opened") ~= nil)
		dev("tick", 1)
		lab.check("with that GUI closed, the window holds player.opened for the pane again", player().opened == window()
			and pd_field("overlay_took") == true, { player().opened and player().opened.name, pd_field("overlay_took") })
		-- Remote view (M, or the pane's Locate) after the close.
		escape()
		dev("controller_changed", PI)
		lab.check("remote view keeps a pinned window's pane", read("manager", "players", PI, "selected_train") == tid
			and dev("pane_dump", PI).visible, read("manager", "players", PI, "selected_train"))
		dev("tick", 1)
		-- A search with the keyboard and a query: remote view takes the keyboard, the query stays.
		dev("select_tab", PI, "stations")
		dev("explain_open", PI, ctx.row.requester, ctx.row.item)
		dev("search_input", PI)
		dev("set_filter", PI, { query = "stn-2" })
		lab.check("search focused with a query", pd_field("search_focused") == true)
		escape()
		dev("controller_changed", PI)
		lab.check("remote view after a pinned window's close keeps the query, the field loses the keyboard",
			read("manager", "players", PI, "search_query") ~= nil and pd_field("search_focused") == nil
			and dev("explain_dump", PI).open == true, { read("manager", "players", PI, "search_query"), pd_field("search_focused") })
		dev("explain_close", PI)
		dev("clear_filters", PI)
		dev("tick", 1)
		dev("select_tab", PI, "trains")
		dev("deselect_train", PI)
		dev("select_tab", PI, "inventory")
		dev("tick", 1)
		lab.check("no overlay left: the pinned window gives player.opened up", player().opened == nil, player().opened and
			player().opened.name)
	end,

	-- Unpinned: Escape peels the overlays, then closes the window.
	function(ctx)
		local row = ctx.row
		if not row then return end
		dev("click", PI, "manager_pin_button")
		lab.check("unpinned: the window holds player.opened", player().opened == window())
		dev("explain_open", PI, row.requester, row.item)
		escape()
		lab.check("unpinned: Escape closes Explain, the window stays", dev("explain_dump", PI).open == false
			and dev("state", PI).is_open)
		settle()
		lab.check("unpinned: the window has player.opened back", player().opened == window())
		escape()
		lab.check("unpinned: the next Escape closes the window", not dev("state", PI).is_open)
		dev("open", PI)
		lab.big_screen(PI)
	end,

	-- The action dialog is modal: it takes player.opened, Back and Escape give it back to the window.
	function(ctx)
		ctx.actions = settings.global["cybersyn-manager-actions"].value
		dev("set_setting", "cybersyn-manager-actions", "everyone")
		dev("click", PI, "manager_pin_button")
		lab.check("unpinned again", player().opened == window())
		local d = dev("action_dialog", PI, "recalc")
		lab.check("the dialog takes player.opened", d.open and player().opened ~= nil and player().opened.name ==
			"cybersyn_action_dialog", player().opened and player().opened.name)
		lab.check("opening the dialog does not close the window", dev("state", PI).is_open)
		dev("action_dialog_back", PI)
		-- Escape on the dialog: it closes, and the window gets player.opened on a later tick.
		dev("action_dialog", PI, "recalc")
		escape()
		lab.check("Escape closes the dialog", not dev("action_dialog", PI).open)
		lab.check("the window stays open", dev("state", PI).is_open)
		local pending = read("manager", "dialog_escapes")
		if pending and pending[PI] then
			remote.call("cybersyn", "write_global", game.tick - 1, "manager", "dialog_escapes", PI, "tick")
		end
		dev("pane_escapes", PI, true)
		dev("tick", 1)
		lab.check("the window holds player.opened again after the hand-back", player().opened == window(),
			player().opened and player().opened.name)
		-- Back hands it back at once.
		dev("action_dialog", PI, "recalc")
		dev("action_dialog_back", PI)
		lab.check("Back closes the dialog and the window holds player.opened at once", not dev("action_dialog", PI).open
			and player().opened == window(), player().opened and player().opened.name)
		dev("click", PI, "manager_pin_button")
		dev("set_setting", "cybersyn-manager-actions", ctx.actions)
	end,

	-- A lint pass dropped half-way (the last window closed) must not log its transitions again on the next pass.
	function()
		dev("lint_run")
		local findings = dev("lint_findings")
		local id
		for _, f in ipairs(findings) do
			if f.subject == "station" then id = f.id break end
		end
		if not lab.check("a station with a setup finding", id ~= nil) then return end
		local mask = read("manager", "lint", "bits", id)
		local seq = dev("diag_state").seq
		-- The committed mask says clean: this pass logs the finding as new.
		remote.call("cybersyn", "write_global", 0, "manager", "lint", "bits", id)
		dev("lint_step", 1, 100000, 0)
		local first = lint_events_for(id, seq)
		lab.check("the half pass logs the finding's transition", first > 0, first)
		-- Dropped as release_if_unused drops it; the next pass checks the station again.
		remote.call("cybersyn", "write_global", nil, "manager", "lint", "job")
		dev("lint_run")
		lab.check("the next full pass does not log it again", lint_events_for(id, seq) == first,
			{ first = first, now = lint_events_for(id, seq) })
		lab.check("and commits the mask", read("manager", "lint", "bits", id) == mask)
		lab.check("the logged masks are gone after the commit", read("manager", "lint", "logged") == nil)
	end,

	-- The drill-down reads the collector's per-item station index: the same stations as a walk over all of them.
	function()
		dev("collect")
		local idx = read("manager", "snapshot", "item_stations")
		lab.check("a complete pass leaves a per-item station index", type(idx) == "table" and next(idx) ~= nil)
		local stations = read("manager", "snapshot", "stations")
		local ok, checked = true, 0
		for hash, ids in pairs(idx or {}) do
			local want = {}
			for id, st in pairs(stations) do
				local d = st.deliveries and st.deliveries[hash] or 0
				if (st.provided and st.provided[hash]) or (st.requested and st.requested[hash]) or d ~= 0 then
					want[id] = true
				end
			end
			local got = {}
			for _, id in ipairs(ids) do
				if got[id] then ok = false end
				got[id] = true
			end
			if lab.count(want) ~= lab.count(got) then ok = false end
			for id in pairs(want) do if not got[id] then ok = false end end
			checked = checked + 1
		end
		lab.check("index == the stations that provide, request or have a delivery of each item (" .. checked .. " items)",
			ok and checked > 0)
	end,

	-- Narrow windows: the closed Trains table drops columns instead of squeezing the status.
	function()
		dev("set_layout", PI, 1920, 1080, 2.0)
		dev("select_tab", PI, "trains")
		dev("update", PI, 2)
		local p = dev("pane_dump", PI)
		local status
		for _, c in ipairs(p.columns or {}) do
			if c[1] == "train_status" then status = c[2] end
		end
		lab.check("1080p at 2.0: the status keeps 260 px or more with the pane closed", status and status >= 260,
			{ status = status, dropped = p.dropped })
		local r = dev("rows", PI, "overview")
		lab.check("1080p at 2.0: the window is no wider and no taller than the screen", r.width <= r.screen[1]
			and r.window_height <= r.screen[2], r)
		lab.big_screen(PI)
		dev("select_tab", PI, "overview")
	end,

	-- relative.tick walks no players while no panel is open.
	function()
		local station = next(read("stations"))
		dev("relative_open", PI, "stop", station)
		lab.check("an open panel sets the flag", read("manager", "relative_any") == true)
		dev("relative_close", PI)
		dev("tick", 1)
		lab.check("the tick after the last panel closed clears it", read("manager", "relative_any") == nil)
	end,

	-- Phase-10 lab gaps: the dialog's own handler checks the right again; an action with diagnostics off is still
	-- audited (log and force line); Send home leaves the train's schedule on its depot.
	function(ctx)
		local setting = settings.global["cybersyn-manager-actions"].value
		dev("set_setting", "cybersyn-manager-actions", "everyone")
		dev("action_dialog", PI, "recalc")
		dev("set_setting", "cybersyn-manager-actions", "nobody")
		local seq = dev("diag_state").seq
		local d = dev("action_dialog", PI, nil, true)
		local recalcs = 0
		for _, ev in ipairs(dev("diag_events", seq, 4096)) do
			if ev.kind == "manual_action" and ev.a == 3 then recalcs = recalcs + 1 end
		end
		lab.check("Confirm in a dialog opened with the right, after it was taken away: refused, not audited",
			d.ran == false and recalcs == 0, { d = d, recalcs = recalcs })
		dev("set_setting", "cybersyn-manager-actions", "everyone")
		-- Send home with diagnostics off: the schedule's current record is the depot, and the action still logs and
		-- prints its audit line.
		local tid, depot
		for id, t in pairs(read("trains")) do
			if t.manifest and t.status >= 1 and t.status <= 4 and t.depot_id then
				tid, depot = id, t.depot_id
				break
			end
		end
		if tid then
			dev("set_setting", "cybersyn-diagnostics", "off")
			dev("relative_open", PI, "train", tid)
			dev("last_audit", true)
			dev("action_click", PI, "fail_delivery")
			dev("action_click", PI, "fail_delivery")
			local audit = dev("last_audit")
			lab.check("with diagnostics off, Send home is still audited (force line)", type(audit) == "table"
				and audit[1] == "cybersyn-messages.audit-fail-delivery", audit)
			local t = read("trains", tid)
			local schedule = t.entity.get_schedule()
			local current = schedule.get_records()[schedule.current]
			local name = read("depots", depot).entity_stop.backer_name
			lab.check("Send home: the schedule's current record is the train's depot", current and current.station == name,
				{ current = current and current.station, depot = name })
			dev("relative_close", PI)
			dev("set_setting", "cybersyn-diagnostics", "basic")
		else
			lab.skip("Send home schedule and audit", "no train on a delivery at this point of the run")
		end
		dev("set_setting", "cybersyn-manager-actions", setting)
		lab.check("diagnostics back on", dev("diag_state").mode == "basic")
	end,

	-- The drill-down's Requesters order against the dispatcher's real choice on a same-priority tie: two requesters of
	-- priority 0, the one whose last delivery is older must get the train, and the drill-down must list it first.
	function(ctx)
		local ok, case = pcall(function()
			local c = cases.base("TIEBREAK", { k = 74 }, { network = "signal-4" })
			c.p = cases.station(c, { name = cases.sname(c, "p"), x = cases.X_P[1], bits = 1 + 4 })
			c.a = cases.station(c, { name = cases.sname(c, "a"), x = cases.X_R[1], bits = 2 + 4 })
			c.b = cases.station(c, { name = cases.sname(c, "b"), x = cases.X_R[2], bits = 2 + 4 })
			return cases.finish(c)
		end)
		lab.check("same-priority tie scenario builds", ok, case)
		if not ok then return end
		ctx.tie = case
		lab.wait_until(function() return cases.trains_ready(case) end, 3600, 50)
	end,
	function(ctx)
		local case = ctx.tie
		if not case then return end
		lab.check("tie: train parked", cases.trains_ready(case))
		-- b served recently, a long ago: the dispatcher takes a (central-planning: equal priority, older last delivery).
		remote.call("cybersyn", "write_global", 10, "stations", case.a.id, "last_delivery_tick")
		remote.call("cybersyn", "write_global", game.tick, "stations", case.b.id, "last_delivery_tick")
		cases.set_signals(case.p, cases.provide(case, 2000))
		cases.set_signals(case.a, cases.request(case, -2000, 1000))
		cases.set_signals(case.b, cases.request(case, -2000, 1000))
		lab.wait_until(function()
			local t = read("trains", case.trains[1])
			return t ~= nil and t.r_station_id ~= nil
		end, 4800, 50)
	end,
	function(ctx)
		local case = ctx.tie
		if not case then return end
		local t = read("trains", case.trains[1])
		lab.check("tie: the dispatcher sent the train to the requester with the older last delivery",
			t and t.r_station_id == case.a.id, { r = t and t.r_station_id, a = case.a.id, b = case.b.id })
		dev("open", PI)
		dev("collect")
		dev("select_tab", PI, "inventory")
		local d = dev("open_item", PI, case.item)
		d = dev("item_dump", PI)
		local pos = {}
		for i, r in ipairs(d.model and d.model.requesters or {}) do pos[r.id] = i end
		lab.check("tie: the drill-down lists that requester before the other (dispatcher order)",
			pos[case.a.id] ~= nil and pos[case.b.id] ~= nil and pos[case.a.id] < pos[case.b.id],
			{ a = pos[case.a.id], b = pos[case.b.id] })
		dev("close_item", PI)
		dev("select_tab", PI, "overview")
		case.cleanup()
	end,

	-- The Overview's Stations failing counts follow the collector's change log: a station switched off (train limit 0)
	-- and back is counted and uncounted as a walk of every record counts it.
	function(ctx)
		dev("open", PI)
		dev("collect")
		dev("select_tab", PI, "overview")
		dev("update", PI)
		local o = dev("overview_failing_oracle", PI)
		lab.check("failing counts: cache equals a walk after the first render", o.same, o)
		local id
		for sid in pairs(read("stations")) do
			local status = read("manager", "snapshot", "stations", sid, "status")
			if status ~= "no_power" and status ~= "disabled" then
				id = sid
				break
			end
		end
		if not id then
			lab.check("failing counts: a station to switch off", false)
			return
		end
		-- The station's own limit (its train-limit signal, read on the station's poll), which the collector copies.
		local limit = read("stations", id, "trains_limit")
		local before = o.cached.disabled
		remote.call("cybersyn", "write_global", 0, "stations", id, "trains_limit")
		dev("collect")
		dev("update", PI)
		o = dev("overview_failing_oracle", PI)
		lab.check("failing counts: the switched-off station counts as disabled, as a walk counts it",
			o.same and o.cached.disabled == before + 1, o)
		remote.call("cybersyn", "write_global", limit, "stations", id, "trains_limit")
		dev("collect")
		dev("update", PI)
		o = dev("overview_failing_oracle", PI)
		lab.check("failing counts: switched back on, uncounted again", o.same and o.cached.disabled == before, o)
	end,

	-- An acknowledged Unserved row's "for another …" is a clock: it moves with the wait, not only when the row's
	-- numbers or identity change. The wait itself is on the 10 s step, as the stop panel shows it.
	function(ctx)
		dev("open", PI)
		lab.big_screen(PI)
		dev("select_tab", PI, "overview")
		local row = an_unserved_row()
		if not row then
			lab.skip("ack countdown", "no unserved row")
			return
		end
		ctx.ack_row = row
		remote.call("cybersyn", "write_global", true, "manager", "players", PI, "overview_show_acked")
		dev("set_filter", PI, { item = row.item })
		ctx.ack_until = dev("diag_ack", "request", row.requester, row.item, 3600 * 60, PI).until_tick
		dev("update", PI, 2)
		local b = ack_button(row)
		ctx.ack_tip = b and serpent.line(b.tooltip)
		lab.check("an acknowledged row shows its countdown", b ~= nil and b.toggled and ctx.ack_tip:find("unserved-ack-for", 1, true)
			~= nil, ctx.ack_tip)
		lab.wait(700)
	end,
	function(ctx)
		local row = ctx.ack_row
		if not row then return end
		dev("update", PI, 1)
		local b, wait = ack_button(row)
		local tip = b and serpent.line(b.tooltip)
		lab.check("700 ticks later the countdown has moved", tip ~= nil and tip ~= ctx.ack_tip, { ctx.ack_tip, tip })
		local left = ctx.ack_until and (ctx.ack_until - game.tick)
		lab.check("it reads the ack's remaining minutes", tip ~= nil and left ~= nil
			and tip:find('"' .. math.floor(left / 3600) .. "m", 1, true) ~= nil, { tip, left })
		lab.check("the wait caption is on the 10 s step", wait ~= nil and (wait:find("0s$") ~= nil or wait:find("m$") ~= nil
			or wait:find("h$") ~= nil), wait)
		dev("diag_unack", "request", row.requester, row.item, PI)
		remote.call("cybersyn", "write_global", nil, "manager", "players", PI, "overview_show_acked")
		dev("clear_filters", PI)
		dev("close", PI)
		lab.check("closing the window drops the Overview's per-player caches",
			read("manager", "players", PI, "overview_failing") == nil
			and read("manager", "players", PI, "gui_state", "overview_unserved_table", "content_sigs") == nil)
		dev("open", PI)
		lab.big_screen(PI)
	end,

	-- A removed station's findings leave the Problems side, its snapshot record's mask and the running lint pass at
	-- once, so Problems and the Overview's misconfigured line count the same stations in between.
	function(ctx)
		local ok, case = pcall(function()
			local c = cases.base("LINTGONE", { k = 75 }, { network = "signal-5" })
			c.r = cases.station(c, { name = cases.sname(c, "r"), x = cases.X_R[1], bits = 2 })
			return cases.finish(c)
		end)
		lab.check("lint removal scenario builds", ok, case)
		if not ok then return end
		ctx.lintgone = case
		-- A request nobody on its network provides; the planner reads it on its next poll of the stop.
		cases.set_signals(case.r, cases.request(case, -2000, 1000))
		lab.wait(1200, 50)
	end,
	function(ctx)
		local case = ctx.lintgone
		if not case then return end
		local id = case.r.id
		dev("collect")
		dev("lint_run")
		local bits = dev("lint_bits", id)
		if bits.mask == 0 then
			lab.skip("lint removal", "the scenario station has no finding")
			case.cleanup()
			return
		end
		lab.check("the scenario station has findings and its record carries them", #dev("lint_findings", id) > 0
			and bits.st_lint == bits.mask, bits)
		-- A pass in flight that has examined the station, its trains still to come.
		dev("lint_step", 1, 100000, 0)
		local running = dev("lint_state").running
		lab.check("a pass is in flight with the station examined", running ~= nil
			and read("manager", "lint", "job", "bits", id) ~= nil, running)
		case.cleanup()
		lab.check("removed: its findings left the Problems side at once", #dev("lint_findings", id) == 0)
		lab.check("removed: the snapshot record's mask is cleared", (read("manager", "snapshot", "stations", id, "lint") or 0) == 0)
		lab.check("removed: the running pass forgot it", read("manager", "lint", "job", "bits", id) == nil)
		local o = dev("overview_failing_oracle", PI)
		lab.check("removed: the Overview's failing counts still equal a walk", o.same, o)
		dev("lint_step", 1, 100000, 100000)
		lab.check("the pass's commit does not bring it back", #dev("lint_findings", id) == 0
			and dev("lint_state").running == nil)
	end,

	-- The growth sampler answers with every field the phase-7 growth gate reads.
	function()
		local s = dev("growth_sample", PI)
		lab.check("growth_sample: heap, diag, rings, acks, lint, stats, census", s.heap_kb > 0 and s.diag_json
			and s.basic and s.basic.head and s.full and s.acks_n and s.lint and s.stats_json and s.census
			and s.player_entries, s)
		local st = dev("diag_state")
		lab.check("diag_state reports both rings' heads", st.head_basic ~= nil and st.head_full ~= nil)
	end,
})
