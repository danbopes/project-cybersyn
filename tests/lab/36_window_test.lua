-- PLAN3 phase 3: the window sized from the screen (whole rows on every tab for four emulated screens, never above
-- 85 % of the screen), the Overview's Unserved table and tiles against the diagnostics state, acknowledge with expiry,
-- the dispatch-paused banner, search with pattern characters and rich text, the item chip on every tab, Ctrl+F only
-- while open, Esc in the search field, the filter row and the reset command. Round 4 (PLAN4 D2-D4, D7, D16, round 5
-- items 1, 2, 5, 7, 14): the Overview under network / network ID / surface filters with each tile agreeing with its
-- jump, the filter button as the row's switch and reset, the surface default at open, the Misconfigured line, the
-- Setup marker, empty columns hidden, and the hand-back after remote view.

local D, pi = lab.D, lab.pi
local HOUR = 216000

local SCREENS = {
	{ "4K at 1.5", 3840, 2160, 1.5 },
	{ "1080p at 1.0", 1920, 1080, 1.0 },
	{ "1080p at 1.25", 1920, 1080, 1.25 },
	{ "4K at 2.0", 3840, 2160, 2.0 },
}

local function key_of(c)
	return type(c) == "table" and c[1] or c
end

local TABLE = "overview_unserved_table"
local COLUMNS = 8

--- The since line of a chip tooltip, with or without its "read n s ago" suffix.
local function since_key(tip)
	local since = tip and tip[8]
	if type(since) ~= "table" then return nil end
	if since[1] == "" then return key_of(since[2]) end
	return since[1]
end

local function overview()
	remote.call(D, "select_tab", pi, "overview")
	return remote.call(D, "dump", pi, "overview")
end

--- The element named `name` in the player's screen GUI (depth-first), or nil.
local function find(name, root)
	root = root or game.get_player(pi).gui.screen
	if root.name == name then return root end
	for _, c in ipairs(root.children) do
		local hit = find(name, c)
		if hit then return hit end
	end
	return nil
end

local function contains(list, value)
	for _, v in ipairs(list) do
		if v == value then return true end
	end
	return false
end

lab.suite("36_window", {
	-- Whole rows: rows computed for the screen == rows rendered (or every row there is), window within 85 %.
	function(ctx)
		ctx.planner = settings.global["cybersyn-enable-planner"].value
		lab.dev("set_setting", "cybersyn-enable-planner", true)
		remote.call(D, "open", pi)
		remote.call(D, "clear_filters", pi)
		lab.dev("collect")
		for _, screen in ipairs(SCREENS) do
			remote.call(D, "set_layout", pi, screen[2], screen[3], screen[4])
			local summary = {}
			for _, tab in ipairs(lab.TABS) do
				remote.call(D, "select_tab", pi, tab)
				local r = remote.call(D, "rows", pi, tab)
				local d = remote.call(D, "dump", pi, tab)
				local available
				if tab == "overview" then
					available = d.lists.unserved.total
				elseif tab == "stations" or tab == "trains" then
					available = d.total
				end
				local want = available and math.min(r.computed, available) or r.computed
				summary[tab] = r.computed .. "/" .. tostring(r.rendered)
				lab.check(string.format("%s %s: rows rendered == rows computed (or all there are)", screen[1], tab),
					r.rendered == want and r.computed >= 3, { r = r, available = available })
				lab.check(string.format("%s %s: page size is the row count", screen[1], tab),
					tab == "overview" or tab == "inventory" or r.page_size == r.computed, r)
			end
			-- The Log: its rows, or every row there is when the log holds fewer.
			remote.call(D, "select_tab", pi, "log")
			local lr = remote.call(D, "rows", pi, "log")
			local ld = remote.call(D, "dump", pi, "log")
			summary.log = lr.computed .. "/" .. tostring(lr.rendered)
			lab.check(screen[1] .. " log: rows rendered == rows computed (or all there are)",
				-- PLAN4 D12 (p5-log): the Log scrolls a page of up to 200 rows; its viewport is the layout's rows.
				lr.rendered >= math.min(#ld.groups, lr.computed) and (#ld.groups >= lr.computed or ld.complete) and
				lr.computed >= 3,
				{ r = lr, groups = #ld.groups, complete = ld.complete })
			local r = remote.call(D, "rows", pi, "overview")
			lab.check(screen[1] .. ": window height within 85 % of the screen", r.window_height <= r.max_height, r)
			lab.check(screen[1] .. ": window width = min(1440, 75 % of the screen)",
				r.width == math.max(960, math.min(1440, math.floor(0.75 * r.screen[1]))), r)
			lab.info(screen[1] .. " rows computed/rendered " .. serpent.line(summary, { comment = false })
				.. " window " .. r.width .. "x" .. r.window_height .. " of " .. r.screen[1] .. "x" .. r.screen[2])
		end
		lab.big_screen(pi)
	end,

	-- The table counts every unserved entry that is not acknowledged; tile 1 those older than N minutes.
	function(ctx)
		remote.call("cybersyn", "write_global", 1, "manager", "players", pi, "unserved_minutes")
		local d = overview()
		local counts = lab.dev("diag_counts")
		local total = 0
		for _, n in pairs(counts) do total = total + n end
		local u = d.lists.unserved
		lab.check("unserved table total == diag_counts total minus acknowledged", u.total + u.acked_total == total
			and total > 0, { table = u.total, acked = u.acked_total, diag = total })
		local old = 0
		for _, row in ipairs(lab.dev("diag_unserved_rows", 5000)) do
			if game.tick - row.first_tick >= 3600 and not lab.dev("diag_is_acked", "request", row.r_station_id, row.hash) then
				old = old + 1
			end
		end
		lab.check("Unserved tile's Waiting > 1 min line == entries older than a minute", d.tiles.unserved.old == old,
			{ tile = d.tiles.unserved.old, rows = old })
		local rt = d.rendered_tiles.unserved
		lab.check("Unserved tile: the headline is its station count, the first line names the threshold",
			key_of(rt.caption) == "cybersyn-gui.overview-tile-unserved" and d.tiles.unserved.headline == d.tiles.unserved.stations
			and rt.headline == tostring(d.tiles.unserved.stations)
			and key_of(rt.lines[1][1]) == "cybersyn-gui.overview-unserved-old" and rt.lines[1][1][2] == "1", rt)
		lab.check("table caption counts shown of total", key_of(u.caption) == "cybersyn-gui.unserved-count", u.caption)
		local r1 = u.rendered[1]
		local tip = r1 and r1.chip_tooltip
		local asked = tip and key_of(tip[2])
		lab.check("rows carry the four-line chip tooltip", tip and (asked == "cybersyn-gui.unserved-asked"
			or asked == "cybersyn-gui.unserved-asked-no-amount") and key_of(tip[4]) == "cybersyn-gui.unserved-why"
			and key_of(tip[6]) == "cybersyn-gui.unserved-fix" and since_key(tip) ~= nil, tip)
		local sorted = true
		for i = 2, #u.order do
			if u.order[i] < u.order[i - 1] then sorted = false end
		end
		lab.check("rows sorted by wait, longest first", sorted)
		-- Dump twice and render in between: rows and tooltips are rebuilt only when their sig changes.
		local a = serpent.line(overview().lists.unserved, { comment = false })
		remote.call(D, "update", pi, 1)
		local b = serpent.line(overview().lists.unserved, { comment = false })
		lab.check("unserved table dump identical across a render in the same tick (sig-guarded)", a == b)
	end,

	-- Misconfigured (PLAN4 D7) == stations with an unacknowledged error-severity lint finding; stations whose errors are
	-- all acknowledged read "(+n acked)". Checked against an oracle over the findings list after a real pass, then a
	-- clean record is marked by hand, acknowledged, unacknowledged and cleared.
	function()
		lab.dev("lint_run")
		local d = overview()
		local em = d.lint_error_mask
		local function count()
			local n = 0
			for _, st in pairs(lab.read("manager").snapshot.stations) do
				if bit32.band(st.lint or 0, em) ~= 0 then n = n + 1 end
			end
			return n
		end
		local oracle = lab.dev("overview_setup_oracle", pi)
		local t = d.tiles.failing
		lab.check("misconfigured == stations with an open error finding (oracle over the findings list)",
			t.misconfigured == oracle.stations and t.misconfigured_acked == oracle.acked and t.findings == oracle.findings,
			{ tile = t, oracle = oracle })
		lab.check("after the first lint pass the tile shows numbers, not '–'", t.lint_pending == nil
			and d.rendered_tiles.failing.headline ~= "–", { pending = t.lint_pending, headline = d.rendered_tiles.failing.headline })
		local id
		for sid, st in pairs(lab.read("manager").snapshot.stations) do
			if (st.lint or 0) == 0 and (not id or sid < id) then id = sid end
		end
		local before, before_acked = t.misconfigured, t.misconfigured_acked
		lab.check("a station without a lint finding exists to mark by hand", id ~= nil and em ~= 0, { em = em })
		if not id then return end
		local check = 1
		while bit32.band(em, bit32.lshift(1, check - 1)) == 0 do check = check + 1 end
		-- As lint writes a mask (set_station_lint): the record, then the collector's change log the per-player counts
		-- follow.
		local function mark(mask)
			remote.call("cybersyn", "write_global", mask, "manager", "snapshot", "stations", id, "lint")
			local ids = lab.read("manager").collect_log.ids
			remote.call("cybersyn", "write_global", id, "manager", "collect_log", "ids", #ids + 1)
		end
		mark(bit32.lshift(1, check - 1))
		d = overview()
		lab.check("an error bit on one more station: misconfigured + 1", d.tiles.failing.misconfigured == before + 1
			and count() == before + before_acked + 1, { tile = d.tiles.failing, before = before })
		local tip = serpent.line(d.rendered_tiles.failing.tooltip, { comment = false })
		lab.check("failing tooltip counts stations and findings and splits them by check",
			string.find(tip, "overview-misconfigured-count", 1, true) ~= nil and string.find(tip, "overview-failing-lint-check", 1, true) ~= nil
			and string.find(tip, "cybersyn-diag.lint-", 1, true) ~= nil, tip)
		lab.dev("diag_ack", "lint", id, check, nil, pi)
		d = overview()
		local line = d.rendered_tiles.failing.lines[4]
		lab.check("acknowledged: not counted, read as (+n acked)", d.tiles.failing.misconfigured == before
			and d.tiles.failing.misconfigured_acked == before_acked + 1
			and string.find(serpent.line(line[2], { comment = false }), "overview-acked-note", 1, true) ~= nil,
			{ tile = d.tiles.failing, line = line })
		lab.dev("diag_unack", "lint", id, check, pi)
		mark(0)
		d = overview()
		lab.check("misconfigured back once the hand-written finding is cleared",
			d.tiles.failing.misconfigured == before and d.tiles.failing.misconfigured_acked == before_acked,
			{ tile = d.tiles.failing, before = before })
		-- D5-4: the split tile looks like the other three. Its button keeps the full tile height and chrome, the wrapper
		-- draws nothing, and the link line lies over the button's last line slot in the plain lines' weight.
		-- The buttons take their 108 px from the style (no runtime height reads back nil); their bodies get it at layout.
		local heights, styles, own = {}, {}, {}
		for _, name in ipairs({ "unserved", "fleet", "failing", "throughput" }) do
			local b = find("overview_tile_" .. name)
			heights[name] = b and b.children[1].style.minimal_height
			own[name] = b and b.style.minimal_height or false
			styles[name] = b and b.style.name
		end
		lab.check("all four tile buttons share one style and the full tile height", styles.failing == "cybersyn_overview_tile"
			and styles.unserved == styles.failing and styles.fleet == styles.failing and styles.throughput == styles.failing
			and own.failing == own.unserved and heights.failing == 108 and heights.unserved == 108 and heights.fleet == 108
			and heights.throughput == 108, { heights = heights, styles = styles, own = own })
		local wrap, link_line, link = find("overview_tile_failing_frame"), find("overview_failing_line4"),
			find("overview_failing_line4_label")
		lab.check("the failing tile's wrapper is an invisible frame", wrap and wrap.style.name == "invisible_frame",
			wrap and wrap.style.name)
		lab.check("the Misconfigured line overlays the button's last line slot", link_line and link_line.style.top_margin == -22
			and link_line.parent == wrap and wrap.children[1].name == "overview_tile_failing", link_line and link_line.style.top_margin)
		lab.check("the Misconfigured line reads like the plain lines", link and link.style.name == "cybersyn_overview_line_link",
			link and link.style.name)
		-- The line is a link of its own: Stations with the Problems chip (stations.lua reads it once phase p3 lands).
		local res = lab.dev("click", pi, "overview_failing_line4_label")
		lab.check("the Misconfigured line jumps to the Stations tab", res == true
			and remote.call(D, "state", pi).selected_tab == "stations_tab", res)
		local chip = lab.read("manager", "players", pi, "stations_chip")
		lab.check("the Misconfigured jump narrows the Problems chip to open errors",
			lab.read("manager", "players", pi, "stations_problems_scope") == "errors", chip)
		-- Line == rows needs the Problems chip (phase p3) to honour the scope; until it lands stations.lua drops the chip.
		if chip == "problems" then
			local rows = remote.call(D, "dump", pi, "stations").ids
			lab.check("Misconfigured line == rows of its jump", #rows == before, { line = before, rows = #rows })
		else
			lab.skip("Misconfigured line == rows of its jump", "stations.lua has no Problems chip on this branch")
		end
		remote.call(D, "clear_filters", pi)
		remote.call(D, "select_tab", pi, "overview")
	end,

	-- Acknowledge: the row leaves the open rows, shows greyed at the bottom with the toggle on, the tile reads
	-- (+1 acked); expiry brings it back.
	function(ctx)
		lab.dev("set_setting", "cybersyn-enable-planner", false)
		remote.call("cybersyn", "write_global", nil, "manager", "players", pi, "overview_show_acked")
		local d = overview()
		local u = d.lists.unserved
		local row = u.rendered[1]
		local key = row.requester_id .. "|" .. row.item
		local old_row = game.tick - u.order[1] >= 3600
		local before = d.tiles.unserved
		local res = lab.dev("click", pi, "overview_unserved_table", 16)
		lab.check("ack button dispatches", res == true, res)
		lab.check("acknowledged in storage", lab.dev("diag_is_acked", "request", row.requester_id, row.item))
		local ack = lab.read("acks").request[row.requester_id][row.item]
		lab.check("a plain click acknowledges for 24 h", ack.until_tick == game.tick + 24 * HOUR and ack.player_index == pi, ack)
		d = overview()
		lab.check("acknowledged row leaves the open rows", not contains(d.lists.unserved.keys, key)
			and not contains(d.lists.unserved.shown_keys, key), key)
		lab.check("acknowledged count +1", d.lists.unserved.acked_total == u.acked_total + 1
			and d.lists.unserved.total == u.total - 1, { before = u.total, after = d.lists.unserved.total })
		if old_row then
			lab.check("tile reads (+1 acked)", d.tiles.unserved.acked == before.acked + 1
				and string.find(serpent.line(d.rendered_tiles.unserved.lines[1][2], { comment = false }),
					"overview-acked-note", 1, true) ~= nil, d.rendered_tiles.unserved)
		else
			lab.skip("tile reads (+1 acked)", "the first row is younger than a minute")
		end
		-- Filtered to the item, the open rows of that item fit, so the acknowledged one shows below them.
		remote.call("cybersyn", "write_global", true, "manager", "players", pi, "overview_show_acked")
		remote.call(D, "set_filter", pi, { item = row.item })
		d = overview()
		local rendered = d.lists.unserved.rendered
		local last = rendered[#rendered]
		lab.check("with the toggle on the acknowledged row is greyed at the bottom", #rendered < d.rows and last.acked == true
			and last.requester_id .. "|" .. last.item == key and last.chip_style == "cybersyn_chip_acked"
			and #rendered == d.lists.unserved.total + 1, { rows = #rendered, last = last })
		remote.call(D, "set_filter", pi, { item = false })
		-- Expiry: the acknowledgement's time is up.
		remote.call("cybersyn", "write_global", game.tick, "acks", "request", row.requester_id, row.item, "until_tick")
		d = overview()
		lab.check("an expired acknowledgement puts the row back", contains(d.lists.unserved.keys, key)
			and d.lists.unserved.acked_total == u.acked_total, d.lists.unserved.acked_total)
		lab.dev("diag_unack", "request", row.requester_id, row.item, pi)
		-- Shift = 1 h, control = until the reason changes.
		d = overview()
		lab.dev("click", pi, "overview_unserved_table", 16, { shift = true })
		ack = lab.read("acks").request[row.requester_id][row.item]
		lab.check("shift-click acknowledges for 1 h", ack and ack.until_tick == game.tick + HOUR, ack)
		lab.dev("diag_unack", "request", row.requester_id, row.item, pi)
		overview()
		lab.dev("click", pi, "overview_unserved_table", 16, { control = true })
		ack = lab.read("acks").request[row.requester_id][row.item]
		lab.check("control-click acknowledges until the reason changes", ack and ack.until_tick == nil and ack.reason ~= nil, ack)
		-- With the toggle on and the item filter set, the acknowledged row is the last one.
		remote.call(D, "set_filter", pi, { item = row.item })
		d = overview()
		local n = #d.lists.unserved.rendered
		local again = lab.dev("click", pi, "overview_unserved_table", n * 8 + 8)
		remote.call(D, "set_filter", pi, { item = false })
		lab.check("clicking an acknowledged row ends it", again and not lab.dev("diag_is_acked", "request", row.requester_id, row.item))
		remote.call("cybersyn", "write_global", nil, "manager", "players", pi, "overview_show_acked")
		lab.dev("set_setting", "cybersyn-enable-planner", true)
	end,

	-- D5-5: with more open rows than the page holds, an acknowledgement clicked the way a player clicks (the pointer
	-- on the table, so the hover hold is on) removes the row in the click's own event; the hold is back from the next
	-- tick on.
	function(ctx)
		lab.dev("set_setting", "cybersyn-enable-planner", false)
		remote.call("cybersyn", "write_global", nil, "manager", "players", pi, "overview_show_acked")
		remote.call(D, "clear_filters", pi)
		remote.call(D, "set_layout", pi, 1920, 1080, 1.0)
		local d = overview()
		local u = d.lists.unserved
		lab.check("more open requests than page rows", u.total > d.rows and #u.rendered == d.rows,
			{ total = u.total, rows = d.rows })
		local row = u.rendered[1]
		local key = row.requester_id .. "|" .. row.item
		ctx.ack_key, ctx.ack_row = key, { row.requester_id, row.item }
		local res = lab.dev("click", pi, TABLE, COLUMNS * 2, { control = true, cursor = true })
		d = remote.call(D, "dump", pi, "overview")
		local after = d.lists.unserved
		lab.check("the ack click held the table like a player's click",
			res == true and lab.read("manager", "players", pi, "hover", "scope") == TABLE, res)
		lab.check("acknowledged: the row is gone in the same tick", not contains(after.shown_keys, key)
			and not after.held and #after.rendered == d.rows and after.rendered[1].acked == false
			and after.rendered[1].requester_id .. "|" .. after.rendered[1].item ~= key,
			{ held = after.held, first = after.rendered[1], n = #after.rendered })
		ctx.click_tick = game.tick
		lab.wait(1)
	end,
	function(ctx)
		lab.check("the next tick the hover hold is back", game.tick > ctx.click_tick
			and lab.read("manager", "players", pi, "hover") ~= nil
			and lab.read("manager", "players", pi, "hold_released_tick") ~= game.tick
			and game.tick - lab.read("manager", "players", pi, "hover", "tick") < 600, lab.read("manager", "players", pi, "hover"))
		-- Two more acknowledgements, then Show acknowledged with a stale hold on the table: acknowledged rows get the
		-- bottom of a full page at once, greyed.
		local acked = { ctx.ack_row }
		for _ = 1, 2 do
			local r = remote.call(D, "dump", pi, "overview").lists.unserved.rendered[1]
			acked[#acked + 1] = { r.requester_id, r.item }
			lab.dev("click", pi, TABLE, COLUMNS * 2, { cursor = true })
		end
		remote.call(D, "hover", pi, TABLE, COLUMNS * 3)
		lab.check("show acknowledged hook runs", lab.dev("overview_show_acked", pi, true) == true)
		local d = remote.call(D, "dump", pi, "overview")
		local rendered = d.lists.unserved.rendered
		local tail_ok = #rendered == d.rows
		for i = #rendered - 2, #rendered do
			local r = rendered[i]
			if not (r and r.acked == true and r.chip_style == "cybersyn_chip_acked") then tail_ok = false end
		end
		lab.check("show acknowledged on a full page: the 3 acknowledged rows take the bottom at once", tail_ok
			and rendered[#rendered - 3].acked == false and not d.lists.unserved.held,
			{ n = #rendered, rows = d.rows, held = d.lists.unserved.held })
		lab.check("show acknowledged: the caption counts them", string.find(serpent.line(d.lists.unserved.caption),
			tostring(d.lists.unserved.total + d.lists.unserved.acked_total), 1, true) ~= nil, d.lists.unserved.caption)
		-- Unacknowledge with the toggle on and the hold on: the row is open again in the same tick.
		local last = rendered[#rendered]
		local back = last.requester_id .. "|" .. last.item
		lab.dev("click", pi, TABLE, COLUMNS * #rendered + COLUMNS, { cursor = true })
		d = remote.call(D, "dump", pi, "overview")
		local again
		for _, r in ipairs(d.lists.unserved.rendered) do
			if r.requester_id .. "|" .. r.item == back then again = r end
		end
		lab.check("unacknowledged with the hold on: open again in the same tick",
			not lab.dev("diag_is_acked", "request", last.requester_id, last.item) and contains(d.lists.unserved.keys, back)
			and again ~= nil and again.acked == false and not d.lists.unserved.held, again)
		remote.call(D, "hover", pi, TABLE, COLUMNS * 3)
		lab.dev("overview_show_acked", pi, false)
		d = remote.call(D, "dump", pi, "overview")
		local any = false
		for _, r in ipairs(d.lists.unserved.rendered) do if r.acked then any = true end end
		lab.check("show acknowledged off: no acknowledged rows at once", not any and #d.lists.unserved.rendered == d.rows
			and not d.lists.unserved.held, #d.lists.unserved.rendered)
		remote.call(D, "hover", pi, TABLE, COLUMNS * 3, true)
		for _, a in ipairs(acked) do
			if lab.dev("diag_is_acked", "request", a[1], a[2]) then lab.dev("diag_unack", "request", a[1], a[2], pi) end
		end
		remote.call("cybersyn", "write_global", nil, "manager", "players", pi, "overview_show_acked")
		lab.big_screen(pi)
		lab.dev("set_setting", "cybersyn-enable-planner", true)
	end,

	-- Rows update in place: a row built while it had no provider gets a working provider link once its reason names
	-- one. Hovering a row holds the order; leaving releases it.
	function(ctx)
		lab.dev("set_setting", "cybersyn-enable-planner", false)
		remote.call(D, "clear_filters", pi)
		local d = overview()
		local pick
		for i, r in ipairs(d.lists.unserved.rendered) do
			if i > 1 and r.provider_id and not pick then pick = r end
		end
		lab.check("a rendered row with a provider", pick ~= nil and #d.lists.unserved.rendered >= 3, #d.lists.unserved.rendered)
		if not pick then
			lab.dev("set_setting", "cybersyn-enable-planner", true)
			return
		end
		local all_handlers = true
		for _, r in ipairs(d.lists.unserved.rendered) do
			if not r.provider_handler or r.hover_scope ~= TABLE then all_handlers = false end
		end
		lab.check("every provider link has a click handler and every row joins the hover hold", all_handlers)
		local ix = lab.read("diag", "item_ix", pick.item)
		local function entry() return lab.read("diag", "unserved", pick.requester_id, ix) end
		local function write(field, value)
			remote.call("cybersyn", "write_global", value, "diag", "unserved", pick.requester_id, ix, field)
		end
		local e = entry()
		local saved = { reason = e.reason, first_tick = e.first_tick }
		local key = pick.requester_id .. "|" .. pick.item
		-- No provider and the oldest of all: the row moves to the top, so it is built without a provider, and stays
		-- first so the next render updates it in place.
		write("reason", 1)
		write("first_tick", 0)
		d = overview()
		local keys = serpent.line(d.lists.unserved.shown_keys, { comment = false })
		local r1 = d.lists.unserved.rendered[1]
		lab.check("no provider: the row is rebuilt first without a provider", d.lists.unserved.shown_keys[1] == key
			and r1.provider_id == nil, r1)
		write("reason", saved.reason)
		d = overview()
		r1 = d.lists.unserved.rendered[1]
		lab.check("provider back in place: the link has its target and its click handler", r1.provider_id == e.p_station_id
			and r1.provider_handler and serpent.line(d.lists.unserved.shown_keys, { comment = false }) == keys, r1)
		local tbl_child = { COLUMNS + 4, r1.provider_button_index }
		local res = lab.dev("click", pi, TABLE, tbl_child, { right = true })
		lab.check("a click on the provider link reaches its handler", res == true, res)
		-- Hover hold: the item of row 2 is under the cursor; a row that would move to the top waits.
		local rendered = d.lists.unserved.rendered
		local last = rendered[#rendered]
		local h = remote.call(D, "hover", pi, TABLE, COLUMNS * 2 + 1)
		lab.check("hovering an Unserved row starts the hold", h.handled and h.hold, h)
		local last_ix = lab.read("diag", "item_ix", last.item)
		local last_first = lab.read("diag", "unserved", last.requester_id, last_ix, "first_tick")
		remote.call("cybersyn", "write_global", -1, "diag", "unserved", last.requester_id, last_ix, "first_tick")
		d = overview()
		lab.check("while hovered the row order is held", d.lists.unserved.held
			and serpent.line(d.lists.unserved.shown_keys, { comment = false }) == keys, d.lists.unserved.held)
		remote.call(D, "hover", pi, TABLE, COLUMNS * 2 + 1, true)
		d = overview()
		lab.check("after the leave the moved row is first", not d.lists.unserved.held
			and d.lists.unserved.shown_keys[1] == last.requester_id .. "|" .. last.item, d.lists.unserved.shown_keys[1])
		remote.call("cybersyn", "write_global", last_first, "diag", "unserved", last.requester_id, last_ix, "first_tick")
		write("first_tick", saved.first_tick)
		-- The caption jumps to Stations sorted longest wait first.
		local sort_before = lab.read("manager", "players", pi, "sort", "stations_tab")
		lab.dev("click", pi, "overview_unserved_count")
		remote.call(D, "select_tab", pi, "stations")
		local ids = remote.call(D, "dump", pi, "stations").ids
		local stations = lab.read("manager", "snapshot", "stations")
		local oldest
		for _, st in pairs(stations) do
			local start = st.longest_wait_start
			if start and (not oldest or start < oldest) then oldest = start end
		end
		local first = ids[1] and stations[ids[1]]
		lab.check("the Unserved caption opens Stations with the longest wait first", oldest ~= nil and first
			and first.longest_wait_start == oldest, { first = first and first.longest_wait_start, oldest = oldest })
		remote.call("cybersyn", "write_global", sort_before, "manager", "players", pi, "sort", "stations_tab")
		lab.dev("set_setting", "cybersyn-enable-planner", true)
	end,

	-- Requests already failing when the diagnostics state is created show their wait as a lower bound ("≥", "since
	-- load") until the second planner cycle after creation; later entries are measured. The window is reopened on the
	-- live state rather than by diag_reset, which would empty the rings 38_diag reads.
	function(ctx)
		remote.call("cybersyn", "write_global", 0, "diag", "inherit_cycles")
		remote.call("cybersyn", "write_global", nil, "diag", "inherit_until")
		local st = lab.dev("diag_state")
		lab.check("the inherited window is open", st.inherit_open == true and st.inherit_until == nil, st)
		lab.wait_until(function() return lab.dev("diag_state").inherit_until ~= nil end, 7200)
	end,
	function(ctx)
		local st = lab.dev("diag_state")
		lab.check("the inherited window closes at the second cycle start", st.inherit_until ~= nil and not st.inherit_open, st)
		if not st.inherit_until then return end
		lab.dev("set_setting", "cybersyn-enable-planner", false)
		local d = overview()
		local rendered = d.lists.unserved.rendered
		local inherited, right = 0, true
		for _, r in ipairs(rendered) do
			local e = lab.dev("diag_unserved", r.requester_id)[r.item]
			local is = e.first_tick < st.inherit_until
			if is then inherited = inherited + 1 end
			local shows = string.sub(r.wait, 1, #"≥") == "≥"
			local since = since_key(r.chip_tooltip)
			if shows ~= is or since ~= (is and "cybersyn-gui.unserved-since-load" or "cybersyn-gui.unserved-since") then
				right = false
			end
		end
		lab.check("rows first seen inside the window show ≥ and 'since load', the others do not", right and inherited > 0,
			{ rows = #rendered, inherited = inherited })
		local r1 = rendered[1]
		local ix = lab.read("diag", "item_ix", r1.item)
		local first = lab.read("diag", "unserved", r1.requester_id, ix, "first_tick")
		remote.call("cybersyn", "write_global", st.inherit_until, "diag", "unserved", r1.requester_id, ix, "first_tick")
		remote.call(D, "set_filter", pi, { item = r1.item })
		d = overview()
		local again
		for _, r in ipairs(d.lists.unserved.rendered) do
			if r.requester_id == r1.requester_id and r.item == r1.item then again = r end
		end
		lab.check("an entry first seen at the window's end is measured", again and string.sub(again.wait, 1, #"≥") ~= "≥"
			and since_key(again.chip_tooltip) == "cybersyn-gui.unserved-since", again or #d.lists.unserved.rendered)
		remote.call(D, "set_filter", pi, { item = false })
		remote.call("cybersyn", "write_global", first, "diag", "unserved", r1.requester_id, ix, "first_tick")
		lab.dev("set_setting", "cybersyn-enable-planner", true)
	end,

	-- The dispatch-paused banner: on every tab, naming the player who changed the setting; it costs rows.
	function(ctx)
		local before = remote.call(D, "rows", pi, "overview")
		remote.call(D, "set_layout", pi, 3840, 2160, 1.5)
		local plain = remote.call(D, "rows", pi, "overview")
		lab.dev("set_setting_as", pi, "cybersyn-enable-planner", false)
		local h = remote.call(D, "header", pi)
		local name = game.get_player(pi).name
		local all = true
		for _, tab in ipairs({ "overview_tab", "inventory_tab", "stations_tab", "trains_tab" }) do
			local t = h[tab]
			if not (t.banner and key_of(t.banner_caption) == "cybersyn-gui.dispatch-paused-by" and t.banner_caption[2] == name) then
				all = false
			end
		end
		lab.check("banner 'Dispatch paused by " .. name .. "' on every tab", all, h)
		local paused = remote.call(D, "rows", pi, "overview")
		lab.check("the banner takes a row and stays within 85 %", paused.computed < plain.computed
			and paused.window_height <= paused.max_height, { plain = plain, paused = paused })
		lab.dev("set_setting", "cybersyn-enable-planner", true)
		lab.check("banner gone with the dispatcher on", not remote.call(D, "header", pi).overview_tab.banner)
		lab.dev("set_setting", "cybersyn-enable-planner", false)
		h = remote.call(D, "header", pi)
		lab.check("a change without a player reads 'Dispatch paused'", key_of(h.stations_tab.banner_caption) == "cybersyn-gui.dispatch-paused",
			h.stations_tab.banner_caption)
		lab.dev("set_setting", "cybersyn-enable-planner", true)
		lab.big_screen(pi)
		lab.check("rows back after the banner", remote.call(D, "rows", pi, "overview").computed == before.computed)
	end,

	-- Search: plain substrings, so "[", "%" and "-" match themselves; rich text in a name matches its tag text.
	function(ctx)
		local stations = lab.read("stations")
		local id
		for sid in pairs(stations) do
			if not id or sid < id then id = sid end
		end
		local stop = stations[id].entity_stop
		ctx.rename = { stop = stop, name = stop.backer_name }
		stop.backer_name = "[item=iron-plate] Iron 50% (east)"
		lab.dev("collect")
		remote.call(D, "select_tab", pi, "stations")
		-- The tile jumps above leave a Stations chip toggled (phase 4 honours it); the search is checked on all rows.
		lab.set_status_filter(pi, nil)
		local function rows(query)
			local ok, res = pcall(remote.call, D, "set_filter", pi, { query = query })
			if not ok then return nil, res end
			return remote.call(D, "dump", pi, "stations").ids
		end
		for _, q in ipairs({ "[", "%", "(", "50%", "[item=iron", "iron 50% (east)", "-" }) do
			local ids, err = rows(q)
			lab.check("search '" .. q .. "' runs", ids ~= nil, err)
			if ids then
				if q == "-" then
					lab.check("search '-' matches the stn- names", #ids >= 10, #ids)
				else
					lab.check("search '" .. q .. "' finds exactly the renamed station", #ids == 1 and ids[1] == id, ids)
				end
			end
		end
		local ids = rows("a.b")
		lab.check("search '.' is not a wildcard", ids and #ids == 0, ids)
		remote.call(D, "set_filter", pi, { query = false })
		stop.backer_name = ctx.rename.name
		lab.dev("collect")
	end,

	-- The item chip on every tab while an item filter is set; a click on it clears the filter.
	function(ctx)
		local inv = remote.call(D, "dump", pi, "inventory")
		local item = inv.provided.hashes[1]
		remote.call(D, "set_filter", pi, { item = item })
		remote.call(D, "update", pi, 1)
		local h = remote.call(D, "header", pi)
		local all = true
		for _, tab in ipairs({ "overview_tab", "inventory_tab", "stations_tab", "trains_tab" }) do
			if not (h[tab].chip and key_of(h[tab].chip_caption) == "cybersyn-gui.filter-chip") then all = false end
		end
		lab.check("item chip on every tab", all, h)
		lab.check("the Overview chip says what the Overview ignores",
			key_of(h.overview_tab.chip_tooltip) == "cybersyn-gui.filter-chip-overview-tooltip", h.overview_tab.chip_tooltip)
		lab.check("filter button toggled while a filter is active", h.filter_button == "flib_selected_frame_action_button", h.filter_button)
		local d = overview()
		local only = true
		for _, k in ipairs(d.lists.unserved.keys) do
			if not string.find(k, "|" .. item, 1, true) then only = false end
		end
		lab.check("the Overview's Unserved table follows the item filter", only and d.item == item, d.item)
		lab.dev("click", pi, "stations_tab_chip")
		h = remote.call(D, "header", pi)
		lab.check("clicking the chip clears the item filter", not h.stations_tab.chip and remote.call(D, "state", pi).filters.item == nil, h)
	end,

	-- Ctrl+F only while open; on the Overview it opens the Stations search; Esc in the field cancels the search.
	function(ctx)
		remote.call(D, "close", pi)
		local s = lab.dev("search_input", pi)
		lab.check("Ctrl+F does nothing while the manager is closed", not s.open and not remote.call(D, "state", pi).is_open, s)
		remote.call(D, "open", pi)
		remote.call(D, "select_tab", pi, "overview")
		-- Pinned with no GUI open, the client turns Ctrl+F into the map search: the window leaves it alone.
		s = lab.dev("search_input", pi)
		lab.check("Ctrl+F on a pinned window with no GUI open is the game's", not s.open and s.selected_tab == "overview_tab", s)
		lab.dev("click", pi, "manager_pin_button")
		s = lab.dev("search_input", pi)
		lab.check("Ctrl+F on the Overview opens the Stations search field", s.open and s.visible and s.selected_tab == "stations_tab", s)
		remote.call(D, "set_filter", pi, { query = "stn" })
		lab.check("Esc in the search field is handled", lab.dev("cancel_search", pi) == true)
		local h = remote.call(D, "header", pi)
		lab.check("Esc clears and closes the search field", not h.stations_tab.search and remote.call(D, "state", pi).filters.terms == nil, h)
		lab.dev("click", pi, "manager_pin_button")
	end,

	-- E and Escape (on_gui_closed of an unpinned window): with the search field open, focused or not, they cancel the
	-- search and the window stays holding player.opened, as the game's own search boxes do; with the drill-down open
	-- they close the drill-down first; otherwise one press closes the window. on_gui_closed is the engine's own, raised
	-- by setting player.opened to nil.
	function(ctx)
		local player = game.get_player(pi)
		local function window() return player.gui.screen.manager_window end
		local function unpinned()
			remote.call(D, "close", pi)
			remote.call(D, "open", pi)
			lab.dev("click", pi, "manager_pin_button")
			remote.call(D, "select_tab", pi, "stations")
		end
		local function search_shown() return remote.call(D, "header", pi).stations_tab.search end
		local function closes(name)
			player.opened = nil
			lab.check(name, not remote.call(D, "state", pi).is_open and player.opened == nil,
				{ open = remote.call(D, "state", pi).is_open, opened = player.opened })
		end
		local function cancels(name)
			player.opened = nil
			lab.check(name, remote.call(D, "state", pi).is_open and player.opened == window()
				and remote.call(D, "state", pi).filters.terms == nil and not search_shown())
		end
		local function typing(query)
			lab.dev("search_input", pi)
			remote.call(D, "set_filter", pi, { query = query })
			return search_shown() and player.opened == window()
		end

		unpinned()
		lab.check("unpinned window holds player.opened", player.opened == window())
		lab.check("Ctrl+F opens the search field", typing("stn"))
		cancels("on_gui_closed with the search open: the search is cancelled, the window stays and holds player.opened")
		closes("the next on_gui_closed closes the window")

		unpinned()
		typing("stn")
		lab.dev("click", pi, "manager_trains_tab")
		remote.call(D, "select_tab", pi, "stations")
		cancels("the search open after a click elsewhere: on_gui_closed still cancels it first")
		closes("then one on_gui_closed closes the window")

		unpinned()
		typing("stn")
		remote.call(D, "close", pi)
		unpinned()
		lab.check("reopened, the query still shows", search_shown())
		cancels("reopened: the first on_gui_closed cancels the search")
		closes("reopened: the next one closes the window")

		unpinned()
		closes("no search open: one on_gui_closed closes the window")

		unpinned()
		local row = remote.call("cybersyn-query", "query_unserved", { limit = 1 })[1]
		if not lab.check("an unserved row exists for the drill-down", row ~= nil) then return end
		remote.call(D, "open_item", pi, row.item)
		lab.check("drill-down open", remote.call(D, "item_dump", pi).open == true)
		player.opened = nil
		lab.check("on_gui_closed with the drill-down open closes the drill-down; the window stays and holds player.opened",
			not remote.call(D, "item_dump", pi).open and remote.call(D, "state", pi).is_open and player.opened == window())
		closes("then one on_gui_closed closes the window (drill-down)")
		remote.call(D, "close", pi)
		remote.call(D, "clear_filters", pi)
		remote.call(D, "open", pi)
	end,

	-- The filter button is the row's switch and its reset (PLAN4 D4): lit = open, closing clears item, network,
	-- network ID, surface and the Stations/Trains chips but not the station search; every path that sets a filter
	-- opens the row, so no filter is ever hidden; the row costs a row while open.
	function(ctx)
		remote.call(D, "set_layout", pi, 3840, 2160, 1.5)
		remote.call(D, "clear_filters", pi)
		local LIT, UNLIT = "flib_selected_frame_action_button", "frame_action_button"
		local function hdr() return remote.call(D, "header", pi) end
		local function filters() return remote.call(D, "state", pi).filters end
		local plain = remote.call(D, "rows", pi, "overview")
		local h = hdr()
		lab.check("filter row hidden by default, button unlit", not h.filter_row and h.filter_button == UNLIT, h)
		lab.dev("click", pi, "manager_filter_button")
		local open = remote.call(D, "rows", pi, "overview")
		h = hdr()
		local f = filters()
		lab.check("the button opens the row and is lit with no filter set", h.filter_row and h.filter_button == LIT
			and f.item == nil and f.network == nil and f.mask == -1 and f.surface == nil, { h = h, f = f })
		lab.check("the open row takes a row", open.computed < plain.computed and open.window_height <= open.max_height,
			{ plain = plain, open = open })
		local bench = game.surfaces["cyb-bench"].index
		local item = remote.call(D, "dump", pi, "inventory").provided.hashes[1]
		remote.call(D, "set_filter", pi, { network = "signal-A", mask = 3, surface = bench, item = item, query = "stn" })
		remote.call("cybersyn", "write_global", "unserved", "manager", "players", pi, "stations_chip")
		remote.call("cybersyn", "write_global", "parked", "manager", "players", pi, "trains_chip")
		lab.dev("click", pi, "manager_filter_button")
		h, f = hdr(), filters()
		lab.check("closing the row clears item, network, network ID and surface, the button unlit",
			not h.filter_row and h.filter_button == UNLIT and f.item == nil and f.network == nil and f.mask == -1
			and f.surface == nil, { h = h, f = f })
		lab.check("closing the row clears the Stations and Trains chips", lab.read("manager", "players", pi, "stations_chip") == nil
			and lab.read("manager", "players", pi, "trains_chip") == nil)
		lab.check("the item chip is gone from every tab", not h.overview_tab.chip and not h.stations_tab.chip, h)
		lab.check("the station search is not part of the reset", f.terms ~= nil and f.terms[1] == "stn", f.terms)
		lab.check("rows back", remote.call(D, "rows", pi, "overview").computed == plain.computed)
		remote.call(D, "set_filter", pi, { query = false })

		-- Every path that sets a filter opens the row.
		remote.call(D, "set_filter", pi, { surface = bench })
		h = hdr()
		lab.check("dev set_filter opens the row, lit", h.filter_row and h.filter_button == LIT, h)
		lab.dev("click", pi, "manager_filter_button")
		lab.check("and closing it again leaves no filter", not hdr().filter_row and filters().surface == nil)
		remote.call(D, "select_tab", pi, "overview")
		local d = overview()
		if #d.lists.unserved.rendered > 0 then
			lab.dev("click", pi, TABLE, COLUMNS + 1, { shift = true })
			-- A click holds the table's row order like a hover; the pointer leaves it again.
			remote.call(D, "hover", pi, TABLE, COLUMNS + 1, true)
			h, f = hdr(), filters()
			lab.check("a shift-click on an item filters Stations by it and opens the row", h.filter_row and h.filter_button == LIT
				and f.item == d.lists.unserved.rendered[1].item and remote.call(D, "state", pi).selected_tab == "stations_tab",
				{ h = h, f = f })
			lab.dev("click", pi, "manager_filter_button")
		else
			lab.skip("a shift-click on an item filters Stations by it and opens the row", "no Unserved row")
		end
		remote.call(D, "select_tab", pi, "overview")
		lab.dev("click", pi, "overview_tile_fleet")
		h, f = hdr(), filters()
		if f.network then
			lab.check("the Fleet headroom jump sets its network and opens the row", h.filter_row and h.filter_button == LIT, h)
		else
			lab.skip("the Fleet headroom jump sets its network and opens the row", "no network in the fleet counters")
		end
		lab.dev("click", pi, "manager_filter_button")
		remote.call(D, "set_filter", pi, { network = "signal-B" })
		lab.dev("click", pi, "manager_clear_filters_button")
		h, f = hdr(), filters()
		lab.check("the row's own reset clears it and closes it", not h.filter_row and h.filter_button == UNLIT
			and f.network == nil, { h = h, f = f })
		remote.call(D, "set_filter", pi, { network = "signal-A" })
		ctx.reset_with_filter = true
	end,

	-- PLAN4 D2: the table and tiles 1 and 3 follow network, network ID and surface on the requester; each tile's
	-- number equals the rows its jump lists (Unserved: the stations behind it, the Stations tab's Unserved chip; Stations
	-- failing: the Failing chip), with a surface filter, a network filter and both. Fleet headroom follows the network.
	function(ctx)
		lab.big_screen(pi)
		remote.call(D, "clear_filters", pi)
		lab.dev("lint_run")
		local stations = lab.read("stations")
		local bench = game.surfaces["cyb-bench"].index
		local function mask_ok(f, mask)
			return type(mask) == "number" and bit32.btest(f.mask or -1, mask)
		end
		-- The requester's place (surface, network name, network ID), from the live station.
		local function passes(id, f)
			local st = stations[id]
			if not st then return false end
			local stop = st.entity_stop
			if f.surface and not (stop and stop.valid and stop.surface_index == f.surface) then return false end
			if f.network then
				local mask = st.network_name == "signal-each" and type(st.network_mask) == "table" and st.network_mask[f.network]
					or (st.network_name == f.network and st.network_mask) or nil
				if not mask_ok(f, mask) then return false end
			elseif f.mask then
				if type(st.network_mask) == "table" then
					local any = false
					for _, m in pairs(st.network_mask) do any = any or mask_ok(f, m) end
					if not any then return false end
				elseif not mask_ok(f, st.network_mask) then
					return false
				end
			end
			return true
		end
		local function entries(f)
			local n = 0
			for _, row in ipairs(lab.dev("diag_unserved_rows", 5000)) do
				if passes(row.r_station_id, f) and (not f.item or row.hash == f.item) then n = n + 1 end
			end
			return n
		end
		-- The Stations tab's Unserved chip rule, independently: a snapshot record with an unserved entry (any item) that
		-- passes the place filters and provides, requests or delivers the filtered item.
		local function unserved_stations(f)
			local n = 0
			for id, st in pairs(lab.read("manager").snapshot.stations) do
				if st.unserved and st.unserved.count > 0 and passes(id, f) and (not f.item or st.provided[f.item]
					or st.requested[f.item] or st.deliveries[f.item]) then
					n = n + 1
				end
			end
			return n
		end
		local function jump(tile)
			remote.call(D, "select_tab", pi, "overview")
			lab.dev("click", pi, "overview_tile_" .. tile)
			return remote.call(D, "dump", pi, "stations").ids
		end
		remote.call(D, "select_tab", pi, "overview")
		lab.dev("collect")
		local all = overview()
		-- An item filter where the two rules differ when one can be found: a station that handles the item with an
		-- unserved entry for another item only (the case a per-entry count got wrong).
		local item, differs
		local by_item = {}
		for _, row in ipairs(lab.dev("diag_unserved_rows", 5000)) do
			by_item[row.hash] = by_item[row.hash] or {}
			by_item[row.hash][row.r_station_id] = true
		end
		for hash, ids in pairs(by_item) do
			local d = unserved_stations({ item = hash }) ~= table_size(ids)
			if not item or (d and not differs) or (d == differs and hash < item) then item, differs = hash, d end
		end
		lab.info("item case " .. tostring(item) .. (differs and " (a station handles it with another item unserved)" or ""))
		local cases = {
			{ "surface cyb-bench", { surface = bench } },
			{ "network signal-A", { network = "signal-A" } },
			{ "surface cyb-bench + network signal-B", { surface = bench, network = "signal-B" } },
			{ "item " .. tostring(item), { item = item } },
			{ "network ID 1", { mask = 1 } },
			{ "network signal-A + network ID 2", { network = "signal-A", mask = 2 } },
			{ "surface cyb-bench + a station search typed elsewhere", { surface = bench, query = "stn-1" } },
			{ "surface nauvis (no stops)", { surface = 1 } },
		}
		for _, case in ipairs(cases) do
			local name, f = case[1], case[2]
			remote.call(D, "clear_filters", pi)
			remote.call(D, "set_filter", pi, f)
			remote.call(D, "select_tab", pi, "overview")
			lab.dev("collect")
			local d = overview()
			local u = d.tiles.unserved
			local n, n_stations = entries(f), unserved_stations(f)
			lab.check(name .. ": Unserved table counts the requests whose requester passes, the tile the chip's stations",
				u.total + u.acked_total == n and u.stations == n_stations and u.headline == u.stations,
				{ tile = u, entries = n, stations = n_stations })
			local ok = true
			for _, r in ipairs(d.lists.unserved.rendered) do
				if not passes(r.requester_id, f) then ok = false end
			end
			lab.check(name .. ": every listed row's requester passes", ok)
			local failing = d.tiles.failing.headline
			local unserved_ids = jump("unserved")
			lab.check(name .. ": Unserved tile stations == rows of its jump", u.stations == #unserved_ids,
				{ tile = u.stations, rows = #unserved_ids })
			if f.query then remote.call(D, "set_filter", pi, { query = f.query }) end
			local failing_ids = jump("failing")
			lab.check(name .. ": Stations failing tile == rows of its jump", failing == #failing_ids,
				{ tile = failing, rows = #failing_ids })
			local st = remote.call(D, "state", pi).filters
			lab.check(name .. ": the jumps keep the filter and the row open and drop the station search",
				remote.call(D, "header", pi).filter_row and st.surface == f.surface and st.item == f.item
				and st.mask == (f.mask or -1) and st.terms == nil, st)
			lab.info(name .. ": unserved " .. u.total .. " + " .. u.acked_total .. " acked at " .. u.stations
				.. " stations, failing " .. tostring(failing) .. " (unfiltered " .. all.tiles.unserved.total .. ", "
				.. tostring(all.tiles.failing.headline) .. ")")
			if f.network and not f.surface then
				local fl = d.tiles.fleet
				lab.check(name .. ": Fleet headroom shows the filtered network", fl.network == f.network
					and (fl.worst == nil or fl.worst == f.network), fl)
				local tip = serpent.line(d.rendered_tiles.fleet.tooltip, { comment = false })
				lab.check(name .. ": its tooltip says network ID and surface do not apply",
					string.find(tip, "overview-fleet-scope", 1, true) ~= nil, tip)
			end
		end
		local d = overview()
		lab.check("surface nauvis: nothing listed, an empty state that names the filters", d.tiles.unserved.total == 0
			and #d.lists.unserved.rendered == 0 and key_of(d.lists.unserved.empty) == "cybersyn-gui.unserved-empty-filtered",
			d.lists.unserved.empty)
		remote.call(D, "clear_filters", pi)
		remote.call(D, "select_tab", pi, "overview")
		d = overview()
		lab.check("unfiltered again: the counts are back", d.tiles.unserved.total == all.tiles.unserved.total)
		local hud = lab.dev("hud", pi)
		lab.check("Fleet headroom's Now line is the HUD's free trains", d.tiles.fleet.now == (hud.values and hud.values.headroom),
			{ tile = d.tiles.fleet.now, hud = hud.values })
		local rt = d.rendered_tiles
		lab.check("Fleet headroom labelled 'min · <period>' with a Now line", key_of(rt.fleet.note) == "cybersyn-gui.overview-fleet-min"
			and key_of(rt.fleet.lines[1][1]) == "cybersyn-gui.hud-headroom-now", rt.fleet)
		lab.check("Throughput says it covers all networks, the wait lines say dispatch wait",
			string.find(serpent.line(rt.throughput.caption, { comment = false }), "overview-all-networks", 1, true) ~= nil
			and key_of(rt.throughput.lines[2][1]) == "cybersyn-gui.overview-throughput-wait-avg", rt.throughput)

		-- PLAN5 D5-8: Fleet headroom counts by network name alone, so its jump drops every other filter and the query;
		-- with an item filter left, the Parked list (no manifest) was always empty.
		local worst = d.tiles.fleet.worst
		local hashes = {}
		for _, row in ipairs(lab.dev("diag_unserved_rows", 5000)) do hashes[#hashes + 1] = row.hash end
		table.sort(hashes)
		remote.call(D, "set_filter", pi, { item = hashes[1] or false, surface = game.surfaces["cyb-bench"].index, mask = 3,
			query = "stn" })
		remote.call(D, "select_tab", pi, "overview")
		lab.dev("click", pi, "overview_tile_fleet")
		local f = remote.call(D, "state", pi).filters
		local jumped = remote.call(D, "dump", pi, "trains")
		remote.call(D, "clear_filters", pi)
		if worst then remote.call(D, "set_filter", pi, { network = worst }) end
		remote.call("cybersyn-manager-dev-trains", "set_chip", pi, "parked")
		local oracle = remote.call(D, "dump", pi, "trains")
		lab.check("the Fleet jump keeps only the worst network (no item, surface, network ID or search)",
			serpent.line(f) == serpent.line({ mask = -1, network = worst }), { f = f, worst = worst, item = hashes[1] })
		lab.check("the Fleet jump toggles Parked and lists the parked trains of that network", jumped.chip == "parked"
			and serpent.line(jumped.ids) == serpent.line(oracle.ids), { jumped = jumped.ids, oracle = oracle.ids })
		lab.info("Fleet jump: worst " .. tostring(worst) .. ", " .. #jumped.ids .. " parked trains listed")
		remote.call("cybersyn-manager-dev-trains", "set_chip", pi, "all")
		remote.call(D, "clear_filters", pi)
	end,

	-- PLAN4 D3: every open starts on the player's surface; a surface without Cybersyn stops falls back to All.
	function(ctx)
		remote.call(D, "clear_filters", pi)
		local p = game.get_player(pi)
		local bench = game.surfaces["cyb-bench"]
		local function dropdown()
			local function find(elem)
				if elem.name == "manager_surface_dropdown" then return elem end
				for _, c in pairs(elem.children) do
					local e = find(c)
					if e then return e end
				end
			end
			local dd = find(p.gui.screen)
			return dd and dd.items[dd.selected_index]
		end
		local home = { surface = p.surface, position = p.position }
		remote.call(D, "close", pi)
		p.teleport({ 0, 0 }, bench)
		remote.call(D, "open", pi)
		local f = remote.call(D, "state", pi).filters
		local h = remote.call(D, "header", pi)
		lab.check("open on a surface with stops: the surface filter is the player's surface, the row open and lit",
			f.surface == bench.index and h.filter_row and h.filter_button == "flib_selected_frame_action_button", { f = f, h = h })
		lab.check("the drop-down shows the resolved surface", dropdown() == bench.name, dropdown())
		remote.call(D, "set_filter", pi, { surface = false })
		remote.call(D, "close", pi)
		remote.call(D, "open", pi)
		lab.check("a surface changed afterwards lasts only until the window closes",
			remote.call(D, "state", pi).filters.surface == bench.index)
		local empty = game.create_surface("p1-no-stops")
		remote.call(D, "close", pi)
		p.teleport({ 0, 0 }, empty)
		remote.call(D, "open", pi)
		f, h = remote.call(D, "state", pi).filters, remote.call(D, "header", pi)
		lab.check("open on a surface without stops: All, the row closed", f.surface == nil and not h.filter_row, { f = f, h = h })
		remote.call(D, "close", pi)
		p.teleport(home.position, home.surface)
		game.delete_surface(empty)
		remote.call(D, "open", pi)
		lab.check("back on this save's player surface (no stops there): All", remote.call(D, "state", pi).filters.surface == nil)
	end,

	-- Round 5 items 5 and 14: a Setup marker in the Why cell when the requester has an open error finding for the item
	-- (or the whole station); a column the visible rows leave empty is hidden and Requester takes its width.
	function(ctx)
		remote.call(D, "clear_filters", pi)
		remote.call(D, "select_tab", pi, "overview")
		lab.dev("lint_run")
		local d = overview()
		local rendered = d.lists.unserved.rendered
		local any_stock, any_lost, rows_ok = false, false, true
		for _, r in ipairs(rendered) do
			if r.stock ~= "–" and r.stock ~= "" then any_stock = true end
			if r.lost ~= "" then any_lost = true end
			if r.stock_visible ~= not d.hidden.stock or r.lost_visible ~= not d.hidden.lost then rows_ok = false end
		end
		lab.check("Stock / needed and Lost to are hidden exactly when no visible row fills them", #rendered > 0 and rows_ok
			and d.hidden.stock == not any_stock and d.hidden.lost == not any_lost, { hidden = d.hidden, stock = any_stock, lost = any_lost })
		local widths = lab.read("manager", "players", pi, "overview_widths")
		local extra = (d.hidden.stock and 110 or 0) + (d.hidden.lost and 96 or 0)
		lab.check("Requester takes the hidden columns' width", rendered[1] and rendered[1].requester_width == widths.requester + extra,
			{ cell = rendered[1] and rendered[1].requester_width, base = widths.requester, extra = extra })
		local r = rendered[1]
		if not r then return end
		lab.check("no Setup marker without a finding", not r.setup or lab.dev("overview_setup_oracle", pi).stations > 0, r.setup)
		local findings = lab.read("manager", "lint", "findings")
		local n = #findings
		local check = 1
		while bit32.band(d.lint_error_mask, bit32.lshift(1, check - 1)) == 0 do check = check + 1 end
		remote.call("cybersyn", "write_global", { subject = 1, id = r.requester_id, check = check, a = 0, b = 0, item = r.item },
			"manager", "lint", "findings", n + 1)
		d = overview()
		local r1
		for _, row in ipairs(d.lists.unserved.rendered) do
			if row.requester_id == r.requester_id and row.item == r.item then r1 = row end
		end
		lab.check("an open error finding for the requester and item: a Setup marker beside the chip", r1 and r1.setup
			and string.find(serpent.line(r1.setup_tooltip, { comment = false }), "cybersyn-diag.lint-", 1, true) ~= nil, r1)
		lab.dev("diag_ack", "lint", r.requester_id, check, nil, pi)
		d = overview()
		r1 = nil
		for _, row in ipairs(d.lists.unserved.rendered) do
			if row.requester_id == r.requester_id and row.item == r.item then r1 = row end
		end
		lab.check("acknowledged: no marker", r1 and not r1.setup, r1)
		lab.dev("diag_unack", "lint", r.requester_id, check, pi)
		remote.call("cybersyn", "write_global", nil, "manager", "lint", "findings", n + 1)
		d = overview()
	end,

	-- PLAN5 D5-2: show on map lands where a click on the target's map pin lands (remote view following the target at
	-- the screen centre, zoom 1.5), from the character view and from remote view; a train follows its front stock;
	-- an unpinned window stays open holding player.opened (so E closes it in remote view) and Back returns to the
	-- view it came from with the window still open; a pinned window gets no Back.
	function(ctx)
		local player = game.get_player(pi)
		local d = overview()
		local rows = d.lists.unserved.rendered
		if not (rows[1] and rows[2]) then return lab.skip("show on map", "fewer than two Unserved rows") end
		local function stop_of(row) return lab.read("stations", row.requester_id).entity_stop end
		local function lands(name, stop)
			local pos, c = player.position, player.centered_on
			lab.check(name, player.controller_type == defines.controllers.remote and c ~= nil and c.valid
				and c.unit_number == stop.unit_number and player.surface == stop.surface
				and math.abs(pos.x - stop.position.x) <= 0.01 and math.abs(pos.y - stop.position.y) <= 0.01
				and player.zoom == 1.5,
				{ controller = player.controller_type, centered_on = c and c.valid and c.unit_number, want = stop.unit_number,
					position = pos, stop = stop.position, zoom = player.zoom })
		end
		if player.controller_type == defines.controllers.remote then player.exit_remote_view() end
		local was_pinning = lab.read("manager", "players", pi, "pinning")
		remote.call("cybersyn", "write_global", false, "manager", "players", pi, "pinning")
		local stop1 = stop_of(rows[1])
		local res = lab.dev("click", pi, TABLE, { COLUMNS + 2, 1 }, { shift = true })
		lands("shift-click from the character view: the pin's view (centred on the stop, zoom 1.5)", stop1)
		local pd = lab.read("manager", "players", pi)
		local window = player.gui.screen.manager_window
		lab.check("show on map keeps the unpinned window open, holding player.opened, with Back", pd.is_manager_open
			and not pd.pinning and player.opened == window and pd.map_from ~= nil
			and remote.call(D, "header", pi).back_button == true, { pinning = pd.pinning, map_from = pd.map_from, res = res })
		lab.check("the marker pair is drawn", pd.markers ~= nil and #pd.markers == 2, pd.markers)
		player.zoom = 0.3
		player.centered_on = nil
		local stop2 = stop_of(rows[2])
		lab.dev("click", pi, TABLE, { 2 * COLUMNS + 2, 1 }, { shift = true })
		lands("shift-click from remote view at zoom 0.3: the pin's view of the second row", stop2)
		lab.check("in remote view the window still holds player.opened, and Back still goes to the character view",
			player.opened == window
			and lab.read("manager", "players", pi, "map_from").controller == defines.controllers.character)
		local tid, train = next(lab.read("trains"))
		local front = train and train.entity and train.entity.valid and train.entity.front_stock
		if front then
			local t = lab.dev("link_click", pi, "train", tid, { shift = true })
			lab.check("a train link follows the front stock at zoom 1.5", t.centered_on == front.unit_number and t.zoom == 1.5
				and t.controller == defines.controllers.remote, t)
		end
		local ok, err = pcall(remote.call, D, "click", pi, "manager_back_button")
		lab.check("Back leaves remote view", player.controller_type ~= defines.controllers.remote, { ok = ok, err = err })
		lab.check("after Back the window is open, holds player.opened and hides Back", remote.call(D, "state", pi).is_open
			and player.opened == window and lab.read("manager", "players", pi, "map_from") == nil
			and remote.call(D, "header", pi).back_button == false)
		lab.dev("click", pi, "manager_pin_button")
		lab.dev("click", pi, TABLE, { COLUMNS + 2, 1 }, { shift = true })
		lands("shift-click on a pinned window: the same view", stop1)
		lab.check("a pinned window gets no Back and does not take player.opened",
			lab.read("manager", "players", pi, "map_from") == nil and player.opened ~= window
			and remote.call(D, "header", pi).back_button == false)
		if player.controller_type == defines.controllers.remote then player.exit_remote_view() end
		remote.call("cybersyn", "write_global", was_pinning, "manager", "players", pi, "pinning")
		lab.dev("controller_changed", pi)
		remote.call(D, "select_tab", pi, "overview")
	end,

	-- A pinned window never holds player.opened: its overlays leave it alone, from remote view and back.
	function(ctx)
		local player = game.get_player(pi)
		remote.call(D, "select_tab", pi, "trains")
		local tid = next(lab.read("trains"))
		remote.call(D, "select_train", pi, tid)
		lab.dev("controller_changed", pi)
		lab.check("pinned + pane: player.opened is not the window", player.opened ~= player.gui.screen.manager_window)
		remote.call(D, "deselect_train", pi)
		remote.call(D, "select_tab", pi, "overview")
	end,

	-- /cybersyn-reset-gui forgets the position and the emulated screen, and closes the filter row with its filters.
	function(ctx)
		remote.call("cybersyn", "write_global", { x = -5000, y = 10 }, "manager", "players", pi, "location")
		remote.call(D, "set_filter", pi, { network = "signal-A" })
		local h = lab.dev("reset_gui", pi)
		lab.check("reset forgets the stored position", h.location == nil, h.location)
		lab.check("reset closes the filter row and clears its filters", not h.filter_row
			and remote.call(D, "state", pi).filters.network == nil, h.filter_row)
		lab.check("reset drops the emulated screen", lab.read("manager").players[pi].layout_override == nil)
		lab.big_screen(pi)
		lab.dev("set_setting", "cybersyn-enable-planner", ctx.planner)
		remote.call("cybersyn", "write_global", nil, "manager", "players", pi, "unserved_minutes")
	end,
})
