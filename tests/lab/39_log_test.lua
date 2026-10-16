-- PLAN3 phase 6: the Log tab. Diagnostics full on the dev save with the trace's events plus events written through
-- the dev hook: rows == the layout's rows, every filter against an oracle over diag_events (both rings), adjacent
-- identical rows collapsed, the window, Follow and the hover hold, the severity counts, Summary, the unread-error
-- badge, the export (filter, rows, chunked over ticks, with manager updates off, finished when diagnostics go off),
-- chat print tags, the right-click subject chip, and the tab hiding while diagnostics are off.

local D, pi = lab.D, lab.pi

local KIND, SEV = {}, { error = 1, warning = 2, info = 3 }

local function dev(fn, ...)
	return remote.call(D, fn, ...)
end

local function render()
	dev("update", pi, 1)
	return dev("log_dump", pi)
end

--- Every event the rings hold, newest first.
local function all_events()
	local evs = dev("diag_events", nil, 200000)
	local out = {}
	for i = #evs, 1, -1 do out[#out + 1] = evs[i] end
	return out
end

--- The Log's filter as the export applies it, re-implemented over plain event rows.
local function oracle_filter(fs, with_sev)
	local ex, st2 = fs.export, fs.station2_kinds
	return function(ev)
		if ex.min_tick and ev.tick < ex.min_tick then return false end
		if ex.kinds and not ex.kinds[KIND[ev.kind]] then
			if not (ev.kind == "alert" and ex.alerts and ex.alerts[ev.code]) then return false end
		end
		if with_sev and ex.sevs and not ex.sevs[SEV[ev.sev]] then return false end
		if ex.train and ev.train ~= ex.train then return false end
		if ex.station and ev.station ~= ex.station and not (st2[ev.kind] and ev.station2 == ex.station) then return false end
		if fs.item and ev.item ~= fs.item then return false end
		return true
	end
end

local function same_row(a, b)
	return a.kind == b.kind and a.code == b.code and a.train == b.train and a.station == b.station and
		a.station2 == b.station2 and a.item == b.item
end

--- Rows the Log must show: matching events newest first, adjacent identical ones collapsed, `limit` rows.
local function oracle_rows(fs, limit)
	local pass = oracle_filter(fs, true)
	local out = {}
	for _, ev in ipairs(all_events()) do
		if pass(ev) then
			local last = out[#out]
			if last and same_row(last.ev, ev) then
				last.n = last.n + 1
				last.first = ev.seq
			else
				if #out >= limit then break end
				out[#out + 1] = { ev = ev, seq = ev.seq, first = ev.seq, n = 1 }
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
	local want = oracle_rows(fs, fs.limit)
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
	dev("log_set_filter", pi, { sev = false, kind = false, group = false, train = false, subject = false,
		window = false, follow = true, summary = false })
end

lab.suite("39_log", {
	function(ctx)
		for k, name in ipairs(dev("diag_state").kinds) do KIND[name] = k end
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
		lab.check("rows rendered == the layout's rows (4K at 1.5)", r.rendered == r.computed and r.computed == d.limit and
			#d.groups == r.computed, r)
		lab.check("every row is 28 px in the row styles", d.rows[1] and (d.rows[1].style == "cybersyn_log_row") and
			(d.rows[2].style == "cybersyn_log_row_odd"), d.rows[1] and d.rows[1].style)
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
			{ "subject station", { subject = { kind = "station", id = ctx.station_ids[2] } } },
			{ "subject train", { subject = { kind = "train", id = ctx.train_ids[2] } } },
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
		dev("set_setting", "cybersyn-enable-planner", true)
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

	-- The unread-error badge; the chat print; the right-click subject chip.
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
		dev("select_tab", pi, "log")
		d = dev("log_dump", pi)
		lab.check("viewing the Log clears the badge", d.badge == "", d.badge)

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

		-- The link cells take right-clicks (the engine filters by button before any handler sees the click).
		local function find(elem, name)
			if elem.name == name then return elem end
			for _, c in pairs(elem.children) do
				local f = find(c, name)
				if f then return f end
			end
		end
		dev("select_tab", pi, "overview")
		local screen = game.get_player(pi).gui.screen
		local ov = find(screen, "overview_unserved_table")
		local cell = ov and ov.children[8 + 2]
		local link = cell and cell.children[2]
		lab.check("Overview requester links take right-clicks", link and link.mouse_button_filter.right == true,
			link and link.mouse_button_filter)
		dev("select_tab", pi, "log")
		local rows = find(screen, "log_rows")
		local first = rows and rows.children[1]
		lab.check("Log train and station links take right-clicks", first and first.children[4].mouse_button_filter.right and
			first.children[5].children[2].mouse_button_filter.right, first and first.children[4].mouse_button_filter)

		-- Right-click on a station link anywhere sets the chip; the chip's click clears it.
		dev("select_tab", pi, "overview")
		dev("link_click", pi, "station", sid, { right = true })
		dev("select_tab", pi, "log")
		d = render()
		lab.check("right-click on a station link: the Log shows only that stop", d.filter.subject and
			d.filter.subject.id == sid and d.subject_chip ~= nil, d.filter.subject)
		local only = true
		for _, g in ipairs(d.groups) do
			if g.station ~= sid and g.station2 ~= sid then only = false end
		end
		lab.check("…and every row is about that stop", only and #d.groups > 0, #d.groups)
		dev("click", pi, "log_subject_chip")
		d = render()
		lab.check("the chip's click clears it", d.filter.subject == nil and d.subject_chip == nil, d.filter.subject)
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
		-- Diagnostics off with a job queued: the file is finished, the note says so, the tab hides.
		dev("click", pi, "log_export_button")
		dev("set_setting", "cybersyn-diagnostics", "off")
		d = dev("log_dump", pi)
		local st = dev("state", pi)
		lab.check("diagnostics off: the tab hides and the window leaves it", d.tab_visible == false and
			st.selected_tab ~= "log_tab", { d.tab_visible, st.selected_tab })
		lab.check("diagnostics off mid-export: the job was finished, the note says so", type(d.export_note) == "table" and
			d.export_note[1] == "cybersyn-gui.log-exported-off", d.export_note)
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
