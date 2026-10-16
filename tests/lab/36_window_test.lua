-- PLAN3 phase 3: the window sized from the screen (whole rows on every tab for four emulated screens, never above
-- 85 % of the screen), the Overview's Unserved table and tiles against the diagnostics state, acknowledge with expiry,
-- the dispatch-paused banner, search with pattern characters and rich text, the item chip on every tab, Ctrl+F only
-- while open, Esc in the search field, the filter row and the reset command.

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
		lab.dev("set_player_setting", pi, "cybersyn-manager-unserved-minutes", 1)
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
		lab.check("Unserved > 1 min tile == entries older than a minute", d.tiles.unserved.headline == old,
			{ tile = d.tiles.unserved.headline, rows = old })
		lab.check("Unserved tile caption names the setting", key_of(d.rendered_tiles.unserved.caption) == "cybersyn-gui.overview-tile-unserved"
			and d.rendered_tiles.unserved.caption[2] == "1", d.rendered_tiles.unserved.caption)
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

	-- Misconfigured == stations whose st.lint is not 0. The lint job (phase 2b) fills most of them on this save; one
	-- clean record is set by hand on top of that and the tile must follow it up and back down.
	function()
		local function count()
			local n = 0
			for _, st in pairs(lab.read("manager").snapshot.stations) do
				if (st.lint or 0) ~= 0 then n = n + 1 end
			end
			return n
		end
		local id
		for sid, st in pairs(lab.read("manager").snapshot.stations) do
			if (st.lint or 0) == 0 and (not id or sid < id) then id = sid end
		end
		local before = count()
		lab.check("a station without a lint finding exists to mark by hand", id ~= nil, { flagged = before })
		if not id then return end
		remote.call("cybersyn", "write_global", 5, "manager", "snapshot", "stations", id, "lint")
		local d = overview()
		local n = count()
		lab.check("misconfigured == stations with st.lint ~= 0", d.tiles.failing.misconfigured == n and n == before + 1,
			{ tile = d.tiles.failing.misconfigured, lint = n, before = before })
		local tip = serpent.line(d.rendered_tiles.failing.tooltip, { comment = false })
		lab.check("failing tooltip splits misconfigured by check", string.find(tip, "overview-failing-lint-bit", 1, true) ~= nil, tip)
		remote.call("cybersyn", "write_global", 0, "manager", "snapshot", "stations", id, "lint")
		d = overview()
		lab.check("misconfigured back to the lint job's own count once the hand-written finding is cleared",
			d.tiles.failing.misconfigured == before and count() == before, { tile = d.tiles.failing, before = before })
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
		lab.check("acknowledged row leaves the open rows", not contains(d.lists.unserved.keys, key), key)
		lab.check("acknowledged count +1", d.lists.unserved.acked_total == u.acked_total + 1
			and d.lists.unserved.total == u.total - 1, { before = u.total, after = d.lists.unserved.total })
		if old_row then
			lab.check("tile reads (+1 acked)", d.tiles.unserved.acked == before.acked + 1
				and key_of(d.rendered_tiles.unserved.note) == "cybersyn-gui.overview-acked-note", d.rendered_tiles.unserved)
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
			and last.requester_id .. "|" .. last.item == key and last.chip_style == "cybersyn_chip_grey"
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
		local tbl_child = { COLUMNS + 4, 2 }
		local res = lab.dev("click", pi, TABLE, tbl_child, { right = true })
		lab.check("a click on the provider link reaches its handler", res == true, res)
		-- Hover hold: the chip of row 2 is under the cursor; a row that would move to the top waits.
		local rendered = d.lists.unserved.rendered
		local last = rendered[#rendered]
		local h = remote.call(D, "hover", pi, TABLE, COLUMNS * 2 + 3)
		lab.check("hovering an Unserved row starts the hold", h.handled and h.hold, h)
		local last_ix = lab.read("diag", "item_ix", last.item)
		local last_first = lab.read("diag", "unserved", last.requester_id, last_ix, "first_tick")
		remote.call("cybersyn", "write_global", -1, "diag", "unserved", last.requester_id, last_ix, "first_tick")
		d = overview()
		lab.check("while hovered the row order is held", d.lists.unserved.held
			and serpent.line(d.lists.unserved.shown_keys, { comment = false }) == keys, d.lists.unserved.held)
		remote.call(D, "hover", pi, TABLE, COLUMNS * 2 + 3, true)
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
		s = lab.dev("search_input", pi)
		lab.check("Ctrl+F on the Overview opens the Stations search field", s.open and s.visible and s.selected_tab == "stations_tab", s)
		remote.call(D, "set_filter", pi, { query = "stn" })
		lab.check("Esc in the search field is handled", lab.dev("cancel_search", pi) == true)
		local h = remote.call(D, "header", pi)
		lab.check("Esc clears and closes the search field", not h.stations_tab.search and remote.call(D, "state", pi).filters.terms == nil, h)
	end,

	-- The filter row: hidden until toggled, kept open while one of its filters is set, and it costs rows.
	function(ctx)
		remote.call(D, "set_layout", pi, 3840, 2160, 1.5)
		local plain = remote.call(D, "rows", pi, "overview")
		lab.check("filter row hidden by default", not remote.call(D, "header", pi).filter_row)
		lab.dev("click", pi, "manager_filter_button")
		local open = remote.call(D, "rows", pi, "overview")
		lab.check("filter toggle shows the row, which takes a row", remote.call(D, "header", pi).filter_row
			and open.computed < plain.computed and open.window_height <= open.max_height, { plain = plain, open = open })
		remote.call(D, "set_filter", pi, { network = "signal-A" })
		lab.dev("click", pi, "manager_filter_button")
		lab.check("the row stays while a network filter is set", remote.call(D, "header", pi).filter_row)
		remote.call(D, "clear_filters", pi)
		lab.check("the row hides once the filters are cleared", not remote.call(D, "header", pi).filter_row)
		lab.check("rows back", remote.call(D, "rows", pi, "overview").computed == plain.computed)
	end,

	-- /cybersyn-reset-gui forgets the position and the emulated screen.
	function(ctx)
		remote.call("cybersyn", "write_global", { x = -5000, y = 10 }, "manager", "players", pi, "location")
		local h = lab.dev("reset_gui", pi)
		lab.check("reset forgets the stored position", h.location == nil, h.location)
		lab.check("reset drops the emulated screen", lab.read("manager").players[pi].layout_override == nil)
		lab.big_screen(pi)
		lab.dev("set_setting", "cybersyn-enable-planner", ctx.planner)
		lab.dev("set_player_setting", pi, "cybersyn-manager-unserved-minutes", 5)
	end,
})
