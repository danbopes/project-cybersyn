-- Phase 7 hardening (PLAN3 §5 row 7): the one Escape rule for every overlay (Explain, the item drill-down, the Trains
-- pane, a focused search) on pinned and unpinned windows, the modal action dialog and its hand-back, lint transitions
-- not logged twice after a dropped half pass, the per-item station index behind the drill-down, the Trains table on
-- a narrow window, Test path's rate limit, relative.tick's open-panel flag and the growth sampler.
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
		lab.check("Escape closes Explain first; the drill-down and the window stay",
			dev("explain_dump", PI).open == false and dev("item_dump", PI).open and dev("state", PI).is_open)
		settle()
		lab.check("with an overlay left, the pinned window takes player.opened back", player().opened == window()
			and pd_field("overlay_took") == true)
		escape()
		lab.check("the next Escape closes the drill-down", not dev("item_dump", PI).open and dev("state", PI).is_open)
		settle()
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
		-- A search field with the keyboard is the top overlay.
		dev("select_tab", PI, "stations")
		dev("search_input", PI)
		lab.check("Ctrl+F on a pinned window: the search takes player.opened", player().opened == window())
		dev("set_filter", PI, { query = "stn-1" })
		escape()
		lab.check("Escape clears and closes the search, the window stays",
			read("manager", "players", PI, "search_query") == nil and dev("state", PI).is_open)
		settle()
		lab.check("and the pinned window gives player.opened up again", player().opened == nil)
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

	-- Test path: one pathfinder request per player per second; a click in between gets the last answer again.
	function()
		local stop = next(read("stations"))
		local tid = next(read("trains"))
		local a = dev("test_path", PI, stop, tid)
		local b = dev("test_path", PI, stop, tid, true)
		lab.check("a second Test path in the same tick is not asked again", a and b and a.seq == b.seq, { a, b })
		local c = dev("test_path", PI, stop, tid)
		lab.check("after the limit the next one is", c and c.seq == a.seq + 1, c)
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
