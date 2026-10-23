-- PLAN3 phase 6 / PLAN4 D12: the Log tab. Diagnostics full on the dev save with the trace's events plus events
-- written through the dev hook: a scroll pane of the newest 200 matching rows whose viewport shows the layout's rows,
-- every filter against an oracle over diag_events (both rings), adjacent identical rows collapsed and one row per lint
-- pass (expandable), the window, Follow with Pause / Newest, the hover hold over the pane,
-- the severity counts, Summary, the unread-error badge (capped at 99+), the export (filter, rows, chunked over ticks,
-- with manager updates off, finished when diagnostics go off), chat print tags, no right-click on train and stop links
-- (PLAN5 D5-3), and the tab hiding while diagnostics are off.

local D, pi = lab.D, lab.pi

local KIND, KIND_NAME, SEV = {}, {}, { error = 1, warning = 2, info = 3 }

local function dev(fn, ...)
	return remote.call(D, fn, ...)
end

--- Updates until the rows and the counts are complete (each update scans a bounded number of ring rows).
local function render()
	local d
	for _ = 1, 60 do
		dev("update", pi, 1)
		d = dev("log_dump", pi)
		local summary = d.filter and d.filter.summary
		-- The page's rows below the first viewport are built over a few updates (PLAN4 D12).
		local filling = not summary and d.display and d.shown < #d.display
		if not (d.counting or filling or (not summary and d.complete == false)) then break end
	end
	return d
end

--- Every event the rings hold, newest first.
local function all_events()
	local evs = dev("diag_events", nil, 200000)
	local out = {}
	for i = #evs, 1, -1 do out[#out + 1] = evs[i] end
	return out
end

local WINDOWS = { 36000, 216000, false }

--- The Log's filter re-implemented from the player's raw filter (severities, kind, train field, window) over
--- plain event rows. Only which kinds and alert codes make up a group comes from the mod (that is the groups' data).
local function oracle_filter(fs, with_sev)
	local f, ex = fs.filter, fs.export
	local window = WINDOWS[f.window or 3]
	local min_tick = window and math.max(0, fs.now - window) or nil
	local kind_name = f.kind and KIND_NAME[f.kind]
	return function(ev)
		if min_tick and ev.tick < min_tick then return false end
		if f.group then
			if not (ex.kinds[KIND[ev.kind]] or (ev.kind == "alert" and ex.alerts and ex.alerts[ev.code])) then return false end
		elseif kind_name and ev.kind ~= kind_name then
			return false
		end
		if with_sev and not f.sev[SEV[ev.sev]] then return false end
		if f.train and ev.train ~= f.train then return false end
		if fs.item and ev.item ~= fs.item then return false end
		return true
	end
end

-- Adjacent events make one row when they say the same thing about the same subjects: every column but the seq, the
-- tick, the delivery and the numbers, except where the numbers name what the event is about (a lint finding's check
-- and subject, a manual action and its target, the player who edited a schedule).
local NAMED_A = { lint = true, manual_action = true, schedule_edited = true }
local NAMED_B = { lint = true, manual_action = true }
local function same_row(a, b)
	for _, c in ipairs({ "kind", "sev", "code", "train", "station", "station2", "item" }) do
		if a[c] ~= b[c] then return false end
	end
	if NAMED_A[a.kind] and a.a ~= b.a then return false end
	if NAMED_B[a.kind] and a.b ~= b.b then return false end
	return true
end

--- Rows the Log must show: matching events newest first, adjacent identical ones collapsed, every lint row of one pass
--- (its delivery column, else its tick) in that pass's row wherever it lies, `limit` rows.
local function oracle_rows(fs, limit)
	local pass = oracle_filter(fs, true)
	local out, passes = {}, {}
	for _, ev in ipairs(all_events()) do
		if pass(ev) then
			local last = out[#out]
			local key = ev.kind == "lint" and (ev.delivery ~= 0 and ev.delivery or -ev.tick) or nil
			if key and passes[key] then
				passes[key].n = passes[key].n + 1
				passes[key].first = ev.seq
			elseif not key and last and not last.pass and same_row(last.ev, ev) then
				last.n = last.n + 1
				last.first = ev.seq
			else
				if #out >= limit then break end
				out[#out + 1] = { ev = ev, seq = ev.seq, first = ev.seq, n = 1, pass = key }
				if key then passes[key] = out[#out] end
			end
		end
	end
	return out
end

local function shape(rows, from_dump)
	local s = {}
	for i, r in ipairs(rows) do s[i] = r.first .. "x" .. r.n .. (from_dump and "" or "") end
	return table.concat(s, ",")
end

--- The rendered rows equal the oracle under the current filter.
local function check_rows(label)
	local d = render()
	local fs = dev("log_filter_state", pi)
	local want = oracle_rows(fs, d.page)
	local got = shape(d.groups)
	local ok = got == shape(want) and #d.rows == #want
	lab.check(label .. ": rows == oracle (" .. #want .. " rows)", ok, { got = got, want = shape(want), rendered = #d.rows })
	return d, want
end

local function oracle_counts(fs)
	local pass = oracle_filter(fs, false)
	local c = { 0, 0, 0 }
	for _, ev in ipairs(all_events()) do
		if pass(ev) then c[SEV[ev.sev]] = c[SEV[ev.sev]] + 1 end
	end
	return c
end

local function reset_filter()
	dev("log_set_filter", pi, { sev = false, kind = false, group = false, train = false, window = false, follow = true,
		summary = false })
end

lab.suite("39_log", {
	function(ctx)
		for k, name in ipairs(dev("diag_state").kinds) do
			KIND[name] = k
			KIND_NAME[k] = name
		end
		ctx.planner = settings.global["cybersyn-enable-planner"].value
		ctx.ups = settings.global["cybersyn-manager-updates-per-second"].value
		dev("set_setting", "cybersyn-enable-planner", true)
		dev("set_setting", "cybersyn-diagnostics", "full")
		dev("open", pi)
		dev("clear_filters", pi)
		dev("set_layout", pi, 3840, 2160, 1.5)
		lab.check("the Log tab selects", dev("select_tab", pi, "log") == "log_tab")
		reset_filter()
		lab.wait(3600)
	end,

	-- Rows, filters and counts against the oracle.
	function(ctx)
		local trains = lab.read("trains")
		ctx.train_ids = {}
		for id in pairs(trains) do ctx.train_ids[#ctx.train_ids + 1] = id end
		table.sort(ctx.train_ids)
		local stations = lab.read("stations")
		ctx.station_ids = {}
		for id in pairs(stations) do ctx.station_ids[#ctx.station_ids + 1] = id end
		table.sort(ctx.station_ids)
		-- Events with known subjects: trains and stations of the save, items, every severity.
		for i, tid in ipairs(ctx.train_ids) do
			dev("diag_event", "alert", "error", { code = 1, train = tid, station = ctx.station_ids[i] })
			dev("diag_event", "short_load", "warning", { train = tid, station = ctx.station_ids[i + 1], item = "iron-plate",
				a = 24000, b = 18000 })
		end
		for _, sid in ipairs(ctx.station_ids) do
			dev("diag_event", "station_limit", "info", { station = sid, a = 2, b = 3 })
		end
		local d = render()
		local r = dev("rows", pi, "log")
		local total = #oracle_rows(dev("log_filter_state", pi), 100000)
		lab.check("the viewport shows the layout's rows (4K at 1.5); the pane holds the newest 200",
			r.rendered == #d.groups and r.computed == d.limit and #d.groups == math.min(d.page, total) and
			d.shown == #d.groups and d.page == 200, { r = r, groups = #d.groups, shown = d.shown, total = total })
		lab.check("the rows sit in a vertical scroll pane", d.scroll and d.scroll.type == "scroll-pane" and
			d.scroll.vertical == "always" and d.scroll.height == r.computed * 28, d.scroll)
		lab.check("every row is a 28 px row frame in the striped rows table", d.rows[1] and
			d.rows[1].style == "cybersyn_log_row" and d.rows[2].style == "cybersyn_log_row" and
			d.rows_style == "cybersyn_log_rows_table", { d.rows[1] and d.rows[1].style, d.rows_style })
		-- cybersyn_log_age is the right-aligned grey label style (the alignment cannot be read back from a style).
		lab.check("age column right-aligned with the absolute tick in the tooltip", d.rows[1].age_style == "cybersyn_log_age" and
			type(d.rows[1].age_tooltip) == "table" and d.rows[1].age_tooltip[1] == "cybersyn-gui.log-age-tooltip",
			d.rows[1].age_tooltip)
		check_rows("unfiltered")
		local short
		for _, row in ipairs(d.rows) do
			if type(row.message) == "table" and row.message[1] == "cybersyn-diag.msg-short-load" then short = row end
		end
		lab.check("cargo anomaly reads loaded 18k of 24k", short and short.message[2] == "18k" and short.message[3] == "24k"
			and short.item == "iron-plate" and short.elem_tooltip ~= nil, short)
		local fs = dev("log_filter_state", pi)
		lab.check("severity counts == oracle", serpent.line(d.counts) == serpent.line(oracle_counts(fs)),
			{ got = d.counts, want = oracle_counts(fs) })

		local cases = {
			{ "errors only", { sev = { true, false, false } } },
			{ "warnings and infos", { sev = { false, true, true } } },
			{ "kind station_limit", { kind = "station_limit" } },
			{ "group trains (alerts by code)", { group = "trains" } },
			{ "group unserved", { group = "unserved" } },
			{ "train field", { train = ctx.train_ids[1] } },
			{ "window 10 min", { window = 1 } },
			{ "window 1 h + errors", { window = 2, sev = { true, false, false } } },
		}
		local unfiltered = #oracle_rows(dev("log_filter_state", pi), 100000)
		for _, c in ipairs(cases) do
			reset_filter()
			dev("log_set_filter", pi, c[2])
			local dd, want = check_rows(c[1])
			local all = #oracle_rows(dev("log_filter_state", pi), 100000)
			lab.check(c[1] .. ": narrows", all <= unfiltered and all > 0, { all = all, unfiltered = unfiltered })
			local fs2 = dev("log_filter_state", pi)
			lab.check(c[1] .. ": counts == oracle", serpent.line(dd.counts) == serpent.line(oracle_counts(fs2)),
				{ got = dd.counts, want = oracle_counts(fs2) })
		end
		reset_filter()
		dev("log_set_filter", pi, { window = 1 })
		local dw = render()
		local now = game.tick
		local old = 0
		for _, g in ipairs(dw.groups) do
			if g.tick < now - 36000 then old = old + 1 end
		end
		lab.check("window 10 min: no row older than 10 min", old == 0)
		reset_filter()
	end,

	-- Adjacent identical rows collapse; Follow; the hover hold.
	function(ctx)
		dev("set_setting", "cybersyn-enable-planner", false)
		render()
		local sid = ctx.station_ids[3]
		for _ = 1, 3 do dev("diag_event", "station_disabled", "warning", { station = sid, a = 1, b = 0 }) end
		dev("diag_event", "station_limit", "info", { station = sid, a = 0, b = 1 })
		dev("diag_event", "station_disabled", "warning", { station = sid, a = 1, b = 0 })
		local d = render()
		local g1, g2, g3 = d.groups[1], d.groups[2], d.groups[3]
		lab.check("xn: an identical event after a different one is a row of its own", g1.n == 1 and g1.kind ==
			"station_disabled" and g2.kind == "station_limit", { g1, g2 })
		lab.check("xn: three adjacent identical events are one row counted once", g3.n == 3 and d.rows[3].count == "×3",
			{ g3, d.rows[3].count })
		-- Follow: a new event comes in at the top.
		local top = d.keys[1]
		dev("diag_event", "station_limit", "info", { station = ctx.station_ids[4], a = 5, b = 6 })
		d = render()
		lab.check("Follow: a new event is the top row", d.keys[2] == top and d.groups[1].a == 5, d.keys)
		-- The hover hold keeps the rows in place under the cursor; leaving lets them move.
		local h = dev("hover", pi, "log_rows", 2)
		lab.check("hover on a row starts the hold", h.hold == true, h)
		local keys = table.concat(d.keys, ",")
		dev("diag_event", "station_limit", "info", { station = ctx.station_ids[5], a = 7, b = 8 })
		d = render()
		lab.check("Follow holds while hovered (rows unchanged, layout held)", table.concat(d.keys, ",") == keys and d.held,
			{ d.keys[1], d.held })
		dev("hover", pi, "log_rows", 2, true)
		d = render()
		lab.check("leaving the row releases it: the new event is on top", d.groups[1].a == 7 and not d.held, d.groups[1])
		-- Follow off: rows frozen, the status says how many are newer.
		dev("log_set_filter", pi, { follow = false })
		d = render()
		local frozen = table.concat(d.keys, ",")
		dev("diag_event", "station_limit", "info", { station = ctx.station_ids[6], a = 9, b = 9 })
		d = render()
		lab.check("Follow off: rows stay, the status counts newer events", table.concat(d.keys, ",") == frozen and
			type(d.status) == "table" and d.status[1] == "cybersyn-gui.log-paused" and d.status[2] == "1", d.status)
		dev("log_set_filter", pi, { follow = true })
		d = render()
		lab.check("Follow back on: the newest event is on top", d.groups[1].a == 9, d.groups[1])
		-- The pointer over the pane itself (its gaps, its scroll bar) holds as a row does.
		h = dev("hover", pi, "log_body", 1)
		keys = table.concat(d.keys, ",")
		dev("diag_event", "station_limit", "info", { station = ctx.station_ids[5], a = 11, b = 11 })
		d = render()
		lab.check("the pointer over the scroll pane holds Follow and says so", table.concat(d.keys, ",") == keys and d.held and
			type(d.status) == "table" and d.status[1] == "cybersyn-gui.log-held", { h = h, held = d.held, status = d.status })
		dev("hover", pi, "log_body", 1, true)
		d = render()
		lab.check("leaving the pane lets the event in", d.groups[1].a == 11 and not d.held, d.groups[1])
		-- Pause / Newest (the wheel cannot pause Follow: a custom input on it does not fire over a scroll pane; the phase
		-- report has the client probe).
		lab.check("following: the subheader control reads Pause", type(d.follow_button) == "table" and
			d.follow_button[1] == "cybersyn-gui.log-pause", d.follow_button)
		dev("click", pi, "log_follow")
		d = render()
		lab.check("Pause: the control reads Newest and the status counts newer events", d.filter.follow == false and
			d.follow_button[1] == "cybersyn-gui.log-newest" and d.status[1] == "cybersyn-gui.log-paused", d.follow_button)
		dev("click", pi, "log_follow")
		d = render()
		lab.check("Newest: following again", d.filter.follow ~= false and d.follow_button[1] == "cybersyn-gui.log-pause",
			d.follow_button)
		dev("log_set_filter", pi, { follow = true })
		d = render()
		-- PLAN4 (round-5 item 10): the findings of one lint pass are one row, "Lint: 2 errors, 1 warning ▸", whatever
		-- lies between them; clicking it shows them below it.
		local lsid = ctx.station_ids[7]
		dev("diag_event", "lint", "warning", { code = 1, station = lsid, a = 5, b = lsid })
		dev("diag_event", "station_limit", "info", { station = ctx.station_ids[8], a = 1, b = 1 })
		dev("diag_event", "lint", "error", { code = 1, station = lsid, a = 3, b = lsid })
		dev("diag_event", "lint", "error", { code = 1, station = lsid, a = 9, b = lsid })
		d = check_rows("lint findings")
		local p = d.groups[1]
		local msg = d.rows[1].message
		lab.check("one row per lint pass with its counts by severity", p.kind == "lint" and p.n == 3 and
			d.groups[2].kind == "station_limit" and type(msg) == "table" and msg[1] == "cybersyn-gui.log-lint-pass" and
			msg[2][2][2] == "2" and msg[2][4][2] == "1" and msg[3] == "▸" and d.rows[1].count == "",
			{ p, msg, d.rows[1].count })
		dev("log_toggle_pass", pi, 1)
		d = render()
		local disp = d.display
		lab.check("the pass row expands to its rows, newest first, below it", d.rows[1].message[3] == "▾" and
			disp[2].child and disp[3].child and disp[4].child and not disp[5].child and
			#d.rows == math.min(d.page, #d.groups + 3) and
			d.rows[2].message[1] == "cybersyn-diag.msg-lint-appeared" and
			disp[2].seq > disp[3].seq and d.rows[1].message[1] ~= "",
			{ disp[1], disp[2], disp[3], disp[4], disp[5], rows = #d.rows })
		local top, kid, after = d.rows[1], d.rows[2], d.rows[5]
		lab.check("…indented by the row's left padding, the message cell giving the room back, at the same height",
			kid.left_padding == top.left_padding + 20 and kid.message_width == top.message_width - 20 and
			after.left_padding == top.left_padding and after.message_width == top.message_width and
			d.rows[3].left_padding == kid.left_padding and kid.height == top.height,
			{ top = { top.left_padding, top.message_width, top.height }, kid = { kid.left_padding, kid.message_width,
				kid.height }, after = { after.left_padding, after.message_width } })
		dev("log_toggle_pass", pi, 1)
		d = render()
		lab.check("…and collapses again", #d.rows == #d.groups and d.rows[1].message[3] == "▸" and
			d.rows[2].left_padding == d.rows[1].left_padding, #d.rows)
		-- The header's cycle figures are storage.stats.cycle, as on the Overview.
		local cycle = dev("cycle") or {}
		lab.check("header: planner cycle ticks and dispatches per cycle == stats.cycle, the plain count for the plural",
			type(d.header) == "table" and d.header[4] == tostring(cycle.ticks_last or 0) and
			d.header[5] == (cycle.dispatches_last and tostring(cycle.dispatches_last) or "–") and
			d.header[6] == tostring(cycle.dispatches_last or 0), { d.header, cycle })
		dev("set_setting", "cybersyn-enable-planner", true)
	end,

	-- PLAN4 D12 while Follow is held: the rows a rewrite left hidden below the viewport still come in (they are at their
	-- final places), and the ages below the viewport keep moving, so a scrolled-to row never shows its age out of order.
	function(ctx)
		dev("set_setting", "cybersyn-enable-planner", false)
		ctx.ups = settings.global["cybersyn-manager-updates-per-second"].value
		dev("set_setting", "cybersyn-manager-updates-per-second", 0)
		reset_filter()
		for i = 1, 260 do
			local even = i % 2 == 0
			dev("diag_event", even and "station_limit" or "station_disabled", even and "info" or "warning",
				{ station = ctx.station_ids[1 + i % 20], a = 2000 + i, b = 1 })
		end
		render()
		dev("log_set_filter", pi, { kind = "station_disabled" }, true)
		dev("hover", pi, "log_body", 1)
		dev("update", pi, 1)
		local d = dev("log_dump", pi)
		local before = d.shown
		for _ = 1, 20 do dev("update", pi, 1) end
		d = dev("log_dump", pi)
		lab.check("held: the rows a filter change left hidden still come in", before < #d.display and
			d.shown == #d.display and d.held, { before = before, shown = d.shown, display = #d.display, held = d.held })
		ctx.viewport = d.limit
		lab.wait(240)
	end,
	function(ctx)
		local function seconds(caption)
			local t = 0
			local scale = { d = 86400, h = 3600, m = 60, s = 1 }
			for n, unit in string.gmatch(caption or "", "(%d+)([dhms])") do t = t + tonumber(n) * scale[unit] end
			return t
		end
		dev("update", pi, 1)
		local d = dev("log_dump", pi)
		local prev, bad = -1, nil
		for i, row in ipairs(d.rows) do
			local s = seconds(row.age)
			if s < prev then
				bad = { i = i, age = row.age, above = d.rows[i - 1].age }
				break
			end
			prev = s
		end
		lab.check("held: 4 s later one update brings every row's age in order down the page (the whole page moves together " ..
			"every 2 s while held)", d.held and not bad and #d.rows > ctx.viewport and prev >= 4,
			{ bad = bad, rows = #d.rows, viewport = ctx.viewport, last = prev, held = d.held })
		dev("hover", pi, "log_body", 1, true)
		reset_filter()
		dev("set_setting", "cybersyn-manager-updates-per-second", ctx.ups)
		dev("set_setting", "cybersyn-enable-planner", true)
		render()
	end,

	-- Summary == the oracle's top stations and items in the window.
	function(ctx)
		local function check_summary(label, f)
			reset_filter()
			dev("log_set_filter", pi, f)
			dev("log_set_filter", pi, { summary = true })
			local d
			for _ = 1, 30 do
				d = render()
				if d.summary and d.summary.done then break end
			end
			local fs = dev("log_filter_state", pi)
			local pass = oracle_filter(fs, true)
			local st, it = {}, {}
			for _, ev in ipairs(all_events()) do
				if pass(ev) then
					local s = SEV[ev.sev]
					if ev.station ~= 0 then
						local c = st[ev.station] or { n = 0, sev = 4 }
						c.n, c.sev = c.n + 1, math.min(c.sev, s)
						st[ev.station] = c
					end
					if ev.item then
						local c = it[ev.item] or { n = 0, sev = 4 }
						c.n, c.sev = c.n + 1, math.min(c.sev, s)
						it[ev.item] = c
					end
				end
			end
			local list = {}
			for id, c in pairs(st) do list[#list + 1] = { id = id, n = c.n, sev = c.sev } end
			table.sort(list, function(a, b)
				if a.n ~= b.n then return a.n > b.n end
				if a.sev ~= b.sev then return a.sev < b.sev end
				return a.id < b.id
			end)
			local want = {}
			for i = 1, math.min(10, #list) do want[i] = list[i].id .. ":" .. list[i].n .. ":" .. list[i].sev end
			local got = {}
			for i, e in ipairs(d.summary.stations or {}) do got[i] = e.id .. ":" .. e.n .. ":" .. e.sev end
			lab.check(label .. ": top stations == oracle", table.concat(got, ",") == table.concat(want, ","),
				{ got = got, want = want })
			local items_ok, bad = #(d.summary.items or {}) == math.min(10, lab.count(it)), nil
			for _, e in ipairs(d.summary.items or {}) do
				local c = it[e.item]
				if not (c and c.n == e.n and c.sev == e.sev) then items_ok, bad = false, e end
			end
			lab.check(label .. ": top items == oracle counts and worst severity", items_ok, { bad = bad, n = lab.count(it) })
			lab.check(label .. ": the summary replaces the rows", d.summary_shown == true and #d.rows == 0 or
				(#d.summary.stations == 0 and #d.summary.items == 0), d.summary_shown)
		end
		check_summary("Summary, everything", {})
		check_summary("Summary, 1 h, warnings and errors", { window = 2, sev = { true, true, false } })
		reset_filter()
	end,

	-- The unread-error badge; the chat print; train and stop links without right-click.
	function(ctx)
		render()
		dev("select_tab", pi, "overview")
		for _ = 1, 4 do dev("diag_event", "dispatch_failed", "error", { code = 1 }) end
		dev("diag_event", "station_limit", "warning", {})
		dev("tick", 1)
		local h = dev("header", pi)
		local d = dev("log_dump", pi)
		local unread = 0
		for _, ev in ipairs(all_events()) do
			if ev.seq > d.seen and ev.sev == "error" then unread = unread + 1 end
		end
		lab.check("badge == unread errors since the Log was last viewed", d.badge == tostring(unread) and unread == 4,
			{ badge = d.badge, unread = unread })
		for _ = 1, 96 do dev("diag_event", "dispatch_failed", "error", { code = 1 }) end
		for _ = 1, 30 do dev("diag_event", "station_limit", "warning", {}) end
		dev("tick", 1)
		d = dev("log_dump", pi)
		lab.check("badge: 100 unread errors read 99+, warnings never count", d.badge == "99+", d.badge)
		dev("select_tab", pi, "log")
		d = dev("log_dump", pi)
		lab.check("viewing the Log clears the badge", d.badge == "", d.badge)

		-- A failed dispatch's kind icon follows its severity: the self-healing info rows wear no danger triangle.
		dev("diag_event", "dispatch_failed", "info", { code = 7 })
		dev("diag_event", "dispatch_failed", "info", { code = 6 })
		dev("diag_event", "dispatch_failed", "warning", { code = 8 })
		dev("update", pi, 2)
		local sprites = {}
		for _, row in ipairs(dev("log_dump", pi).rows or {}) do
			local line = serpent.line(row.message)
			for _, key in ipairs({ "train-invalid", "no-path", "path-blocked", "no-path-after-write" }) do
				if line:find('"cybersyn-diag.dispatch-' .. key .. '"', 1, true) and not sprites[key] then
					sprites[key] = row.kind_sprite
				end
			end
		end
		lab.check("dispatch rows: path_blocked and no_path (info) carry the locomotive, no danger icon",
			sprites["path-blocked"] == "item/locomotive" and sprites["no-path"] == "item/locomotive", sprites)
		lab.check("dispatch rows: no_path_after_write (warning) the warning icon, train_invalid (error) the danger icon",
			sprites["no-path-after-write"] == "utility/warning_icon" and sprites["train-invalid"] == "utility/danger_icon",
			sprites)

		-- Chat print: a row about a train and a stop of the save.
		local tid, sid = ctx.train_ids[1], ctx.station_ids[1]
		local seq = dev("diag_event", "alert", "error", { code = 1, train = tid, station = sid })
		local printed = dev("log_print", pi, seq)
		local tags = printed and printed[4] or ""
		local train = game.train_manager.get_train_by_id(tid)
		local front = train and train.front_stock
		lab.check("chat print: [train=<front stock unit number>] [train-stop=<unit number>] [gps=...]",
			front and string.find(tags, "[train=" .. front.unit_number .. "]", 1, true) and
			string.find(tags, "[train-stop=" .. sid .. "]", 1, true) and string.find(tags, "[gps=", 1, true) ~= nil,
			{ tags = tags })

		-- PLAN5 D5-3: train and stop links take no right-click anywhere (the engine filters by button before any
		-- handler sees the click); item buttons keep it (right = clear the item filter).
		local player = game.get_player(pi)
		local function find_named(elem, name)
			if elem.name == name then return elem end
			for _, c in pairs(elem.children) do
				local f = find_named(c, name)
				if f then return f end
			end
		end
		local function handler_of(elem)
			local h = elem.tags and elem.tags["__cybersyn-plus_handler"]
			return h and h[tostring(defines.events.on_gui_click)] or nil
		end
		local function is_item(tags)
			return tags.kind == "item" or tags.item_hash ~= nil or tags.cell == "item"
		end
		local function scan(root, out)
			if (root.type == "button" or root.type == "sprite-button") then
				local h = handler_of(root)
				if h and string.find(h, "link_click", 1, true) then
					local f = root.mouse_button_filter
					if is_item(root.tags) then
						out.items = out.items + 1
						if not f.right then out.item_bad[#out.item_bad + 1] = root.name ~= "" and root.name or h end
					else
						out.links = out.links + 1
						if f.right or f["left-and-right"] then
							out.bad[#out.bad + 1] = serpent.line({ name = root.name, tags = root.tags.kind or root.tags.cell })
						end
					end
				end
			end
			for _, c in pairs(root.children) do scan(c, out) end
			return out
		end
		local function census(label)
			local out = scan(player.gui.screen, { links = 0, items = 0, bad = {}, item_bad = {} })
			scan(player.gui.relative, out)
			lab.check(label .. ": no train or stop link accepts right (" .. out.links .. " links)", out.links > 0 and
				#out.bad == 0, out.bad)
			lab.info(label .. ": " .. out.items .. " item buttons, " .. #out.item_bad .. " without right")
			return out
		end
		local items_ok = true
		for _, tab in ipairs({ "overview", "stations", "trains", "inventory" }) do
			dev("select_tab", pi, tab)
			dev("update", pi, 3)
			local out = census(tab)
			if #out.item_bad > 0 then items_ok = false end
		end
		dev("select_tab", pi, "log")
		render()
		local out = census("log rows")
		lab.check("log rows: the item cells keep right (clear the item filter)", out.items > 0 and #out.item_bad == 0,
			out.item_bad)
		dev("log_set_filter", pi, { summary = true })
		render()
		out = census("log summary")
		lab.check("log summary: the item links keep right", #out.item_bad == 0, out.item_bad)
		reset_filter()
		render()
		lab.check("Overview/Stations/Trains/Inventory item buttons keep right", items_ok)
		local hash
		for _, row in ipairs(dev("diag_unserved_rows", 50)) do hash = hash or row.hash end
		hash = hash or "iron-plate"
		dev("select_tab", pi, "trains")
		dev("open_item", pi, hash)
		dev("update", pi, 2)
		census("item drill-down")
		dev("close_item", pi)
		dev("relative_open", pi, "stop", sid)
		census("stop panel")
		dev("relative_close", pi)
		dev("relative_open", pi, "train", tid)
		census("train panel")
		dev("relative_close", pi)

		-- A right-click that reaches the handler anyway (dev clicks bypass the filter) changes nothing.
		dev("select_tab", pi, "overview")
		local function snap()
			local st = dev("state", pi)
			return serpent.line({ tab = st.selected_tab, filters = st.filters, log = dev("log_filter_state", pi).filter })
		end
		local before = snap()
		local res = dev("link_click", pi, "station", sid, { right = true })
		lab.check("dev right-click on a station link: tab, filters and the Log filter unchanged", snap() == before and
			res.tab == "overview_tab", { before = before, after = snap() })
		before = snap()
		dev("link_click", pi, "train", tid, { right = true })
		lab.check("dev right-click on a train link: nothing changes", snap() == before, { before = before, after = snap() })
		dev("select_tab", pi, "log")
		d = render()
		local idx, button
		for i, row in ipairs(d.rows) do
			if row.station_tags.kind == "station" then idx, button = i, row.station_index break end
		end
		before = snap()
		if idx then dev("click", pi, "log_rows", { idx, 5, button }, { right = true }) end
		lab.check("dev right-click on a Log row's station cell: nothing changes", idx ~= nil and snap() == before,
			{ idx = idx, before = before, after = snap() })
		-- Item right-click keeps its meaning.
		dev("set_filter", pi, { item = hash })
		dev("link_click", pi, "item", hash, { right = true })
		lab.check("right-click on an item still clears the item filter", dev("state", pi).filters.item == nil,
			dev("state", pi).filters)
		dev("clear_filters", pi)

		for _ = 1, 8 do d = render() dev("update", pi, 1) end
		d = render()
		local pool = find_named(player.gui.screen, "log_rows")
		lab.check("one row element per page row; those without a group are hidden, none destroyed", pool and
			#pool.children == d.page and d.shown == #d.groups,
			{ children = pool and #pool.children, page = d.page, groups = #d.groups, shown = d.shown })
		render()
	end,

	-- Export: the filter, the row count, the CSV path, and a job spanning several ticks.
	function(ctx)
		dev("log_set_filter", pi, { sev = { true, true, false } })
		local fs = dev("log_filter_state", pi)
		local pass = oracle_filter(fs, true)
		local want = 0
		for _, ev in ipairs(all_events()) do
			if pass(ev) then want = want + 1 end
		end
		local res = dev("log_export", pi)
		lab.check("export: rows written == filtered events", res and res.rows == want, { res = res, want = want })
		lab.check("export: a CSV under script-output/cybersyn", res and string.match(res.path, "^cybersyn/diag%-%d+[%-%d]*%.csv$") ~= nil,
			res)
		lab.info("export (warnings and errors) " .. tostring(res and res.path) .. ": " .. tostring(res and res.rows) .. " rows")
		reset_filter()
		-- Enough rows for several 1,000-row chunks.
		for i = 1, 2600 do dev("diag_event", "station_limit", "info", { station = ctx.station_ids[1 + i % 10], a = i, b = 0 }) end
		dev("click", pi, "log_export_button")
		ctx.job_tick = game.tick
		dev("tick", 1)
		local d = dev("log_dump", pi)
		lab.check("export from the button: 'Exporting… n %' while it runs", type(d.export_note) == "table" and
			d.export_note[1] == "cybersyn-gui.log-exporting" and dev("diag_state").export_jobs == 1, d.export_note)
		lab.wait_until(function() return dev("diag_state").export_jobs == 0 end, 1200, 1)
	end,

	function(ctx)
		local d = dev("log_dump", pi)
		lab.check("export: the job ended and the note names the file", dev("diag_state").export_jobs == 0 and
			type(d.export_note) == "table" and d.export_note[1] == "cybersyn-gui.log-exported", d.export_note)
		local ex = d.export or {}
		lab.check("export: a job of more than 2,000 rows written in 1,000-row chunks on different ticks",
			(ex.rows or 0) > 2000 and (ex.chunks or 0) >= 3 and ex.last_tick > ex.first_tick, ex)
		lab.info("export of " .. tostring(ex.rows) .. " rows: " .. tostring(ex.chunks) .. " chunks, ticks " ..
			tostring(ex.first_tick) .. ".." .. tostring(ex.last_tick))
		-- With manager updates off only the fixed nth tick drains it.
		dev("set_setting", "cybersyn-manager-updates-per-second", 0)
		dev("click", pi, "log_export_button")
		ctx.off_tick = game.tick
		lab.wait_until(function() return dev("diag_state").export_jobs == 0 end, 1200, 1)
	end,

	function(ctx)
		local d = dev("log_dump", pi)
		lab.check("export with manager updates off finishes on the fixed nth tick", dev("diag_state").export_jobs == 0 and
			type(d.export_note) == "table" and d.export_note[1] == "cybersyn-gui.log-exported", d.export_note)
		local ex = d.export or {}
		lab.info("export with updates off: " .. tostring(ex.rows) .. " rows, " .. tostring(ex.chunks) .. " chunks, ticks " ..
			tostring(ex.first_tick) .. ".." .. tostring(ex.last_tick))
		dev("set_setting", "cybersyn-manager-updates-per-second", ctx.ups)
		-- Full, then basic: the full session's rows leave the Log and the export alike.
		dev("set_setting", "cybersyn-diagnostics", "basic")
		dev("select_tab", pi, "log")
		for _ = 1, 40 do
			d = render()
			if not d.counting then break end
		end
		local basic_only = true
		for _, ev in ipairs(all_events()) do
			if ev.kind == "dispatched" or ev.kind == "arrive_p" or ev.kind == "leave_p" or ev.kind == "arrive_r" or
				ev.kind == "leave_r" or ev.kind == "returned" or ev.kind == "train_state" then
				basic_only = false
			end
		end
		local res = dev("log_export", pi)
		local fs = dev("log_filter_state", pi)
		local pass, want = oracle_filter(fs, true), 0
		for _, ev in ipairs(all_events()) do
			if pass(ev) then want = want + 1 end
		end
		local shown = d.counts[1] + d.counts[2] + d.counts[3]
		lab.check("full -> basic: no full row is left, export rows == the Log's counted rows", basic_only and res and
			res.rows == want and res.rows == shown and want > 0, { rows = res and res.rows, want = want, shown = shown })
		dev("set_setting", "cybersyn-diagnostics", "full")
		-- Diagnostics off with a job queued: the tab hides; the job keeps its rings and goes on one chunk per export tick.
		for i = 1, 2600 do dev("diag_event", "station_limit", "info", { station = ctx.station_ids[1 + i % 10], a = i, b = 0 }) end
		dev("click", pi, "log_export_button")
		dev("set_setting", "cybersyn-diagnostics", "off")
		ctx.off_at = game.tick
		d = dev("log_dump", pi)
		local st = dev("state", pi)
		lab.check("diagnostics off: the tab hides and the window leaves it", d.tab_visible == false and
			st.selected_tab ~= "log_tab", { d.tab_visible, st.selected_tab })
		lab.check("diagnostics off mid-export: nothing written in the setting's tick, the job still queued",
			dev("diag_state").export_jobs == 1 and (d.export or {}).state == "running", d.export)
		lab.wait_until(function() return dev("diag_state").export_jobs == 0 end, 1200, 1)
	end,

	function(ctx)
		local d = dev("log_dump", pi)
		local ex = d.export or {}
		lab.check("diagnostics off mid-export: the job finished over later ticks, the note says so",
			type(d.export_note) == "table" and d.export_note[1] == "cybersyn-gui.log-exported-off" and
			(ex.chunks or 0) >= 3 and ex.last_tick > ctx.off_at, { note = d.export_note, ex = ex, off = ctx.off_at })
		dev("update", pi, 2)
		dev("set_setting", "cybersyn-diagnostics", "basic")
		dev("update", pi, 1)
		d = dev("log_dump", pi)
		lab.check("basic again: the tab is back", d.tab_visible == true)
		lab.check("the Log selects and renders in basic", dev("select_tab", pi, "log") == "log_tab" and
			render().diag == true)
		dev("set_setting", "cybersyn-enable-planner", ctx.planner)
		dev("select_tab", pi, "overview")
		lab.big_screen(pi)
	end,
})
