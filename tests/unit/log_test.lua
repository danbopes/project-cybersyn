-- The Log tab's model (scripts/gui/log-model.lua): the two rings merged by seq, adjacent-row collapse, the rows that
-- follow the head, the severity counts under eviction and the window, the unread-error badge, the Summary
-- aggregation, age and message text, chat tags; plus every locale key the Log builds, in every locale.

local H = require("harness")

local diag, model

local function at(tick)
	game.tick = tick
end

local function setup(mode, ring)
	settings.global["cybersyn-diagnostics"] = { value = mode or "basic" }
	settings.global["cybersyn-diagnostics-ring"] = { value = ring or 16384 }
	storage.trains = storage.trains or {}
	storage.stations = storage.stations or {}
	diag = H.load("scripts.diag")
	model = H.load("scripts.gui.log-model")
	return diag.apply()
end

--- Writes one event; the kind decides the ring (full-only kinds need full mode).
local function ev(d, kind, sev, fields)
	fields = fields or {}
	return diag.event(d, kind, sev, fields.code or 0, fields.delivery or 0, fields.train or 0, fields.station or 0,
		fields.station2 or 0, fields.item or 0, fields.a or 0, fields.b or 0)
end

local function filter(over)
	local f = model.default_filter()
	for k, v in pairs(over or {}) do f[k] = v end
	return f
end

--- Brute force over diag.events: severities per filter, the reference the incremental counts must equal.
local function oracle_counts(d, cf)
	local c = { 0, 0, 0 }
	local rb, rf = model.rings(d)
	for _, r in ipairs({ rb, rf }) do
		for k = 0, r.count - 1 do
			local i = diag.ring_at(r, k)
			if (not cf.min_tick or r.tick[i] >= cf.min_tick) and model.match(r, i, cf) then
				c[r.sev[i]] = c[r.sev[i]] + 1
			end
		end
	end
	return c
end

test("scan_back merges both rings newest first, stops at the window, continues within a budget", function()
	at(100)
	local d = setup("full", 1024)
	ev(d, DIAG_KIND_SERVED, DIAG_SEV_INFO, { a = 1 })      -- seq 1 basic
	ev(d, DIAG_KIND_ARRIVE_P, DIAG_SEV_INFO, { a = 2 })    -- seq 2 full
	at(200)
	ev(d, DIAG_KIND_ARRIVE_R, DIAG_SEV_INFO, { a = 3 })    -- seq 3 full
	ev(d, DIAG_KIND_ALERT, DIAG_SEV_ERROR, { a = 4 })      -- seq 4 basic
	ev(d, DIAG_KIND_LEAVE_P, DIAG_SEV_INFO, { a = 5 })     -- seq 5 full
	local cf = model.compile(filter(), 300)
	local seen = {}
	local ended = model.scan_back(d.ring_basic, d.ring_full, d.seq + 1, cf, 100, function(r, i)
		seen[#seen + 1] = r.seq[i]
	end)
	assert_true(ended)
	assert_eq(seen, { 5, 4, 3, 2, 1 })
	-- Budget 2: two rows, then the scan says where to go on.
	seen = {}
	local ended2, below = model.scan_back(d.ring_basic, d.ring_full, d.seq + 1, cf, 2, function(r, i)
		seen[#seen + 1] = r.seq[i]
	end)
	assert_false(ended2)
	assert_eq(seen, { 5, 4 })
	assert_eq(below, 4)
	model.scan_back(d.ring_basic, d.ring_full, below, cf, 100, function(r, i) seen[#seen + 1] = r.seq[i] end)
	assert_eq(seen, { 5, 4, 3, 2, 1 })
	-- The window ends the scan at the first older row.
	cf = model.compile(filter({ window = 1 }), 200 + 36000 - 50)
	seen = {}
	model.scan_back(d.ring_basic, d.ring_full, d.seq + 1, cf, 100, function(r, i) seen[#seen + 1] = r.seq[i] end)
	assert_eq(seen, { 5, 4, 3 })
	-- The forward scan: oldest first, merged, bounded.
	local fwd = {}
	local reached, done = model.scan_fwd(d.ring_basic, d.ring_full, 1, 3, function(r, i) fwd[#fwd + 1] = r.seq[i] end)
	assert_eq({ fwd, reached, done }, { { 2, 3, 4 }, 4, false })
	-- Full off: the full ring is not read.
	local rb, rf = model.rings({ ring_basic = d.ring_basic, ring_full = d.ring_full, full = false })
	assert_same(rb, d.ring_basic)
	assert_nil(rf)
end)

test("collapse: adjacent identical rows become one with a count; the oldest seq is the key", function()
	setup()
	local function e(seq, kind, station, item, code)
		return { seq = seq, tick = seq * 10, kind = kind, sev = 2, code = code or 0, delivery = 0, train = 0,
			station = station, station2 = 0, item = item or 0, a = seq, b = 0 }
	end
	local rows = model.collapse({
		e(9, DIAG_KIND_ALERT, 5, 0, DIAG_ALERT_STUCK),
		e(8, DIAG_KIND_ALERT, 5, 0, DIAG_ALERT_STUCK),
		e(7, DIAG_KIND_ALERT, 5, 0, DIAG_ALERT_STUCK),
		e(6, DIAG_KIND_ALERT, 5, 0, DIAG_ALERT_MISSING_TRAIN),   -- another alert code: not identical
		e(5, DIAG_KIND_ALERT, 5, 0, DIAG_ALERT_STUCK),           -- identical to the first, but not adjacent
		e(4, DIAG_KIND_SHORT_LOAD, 5, 2),
		e(3, DIAG_KIND_SHORT_LOAD, 5, 3),                        -- another item
	})
	local shape = {}
	for i, g in ipairs(rows) do shape[i] = { g.seq, g.first, g.n, g.a } end
	assert_eq(shape, { { 9, 7, 3, 9 }, { 6, 6, 1, 6 }, { 5, 5, 1, 5 }, { 4, 4, 1, 4 }, { 3, 3, 1, 3 } })
	assert_eq(#model.collapse({ e(3, 1, 1), e(2, 1, 2), e(1, 1, 3) }, 2), 2)
	assert_eq(model.repeat_caption(1), "")
	assert_eq(model.repeat_caption(3), "×3")
	assert_eq(model.repeat_caption(1200), "×1,200")
end)

test("rows: a backward fill to the limit, then the head followed; identical new events join the top row", function()
	at(1000)
	local d = setup()
	for s = 1, 6 do ev(d, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, { station = s, a = s }) end
	local cf = model.compile(filter(), 1000)
	local rs = {}
	assert_true(model.update_rows(rs, d, cf, 4, true, 100))
	local function shape()
		local out = {}
		for i, g in ipairs(rs.groups) do out[i] = { g.first, g.n } end
		return out
	end
	assert_eq(shape(), { { 6, 1 }, { 5, 1 }, { 4, 1 }, { 3, 1 } })
	assert_nil(rs.below, "four rows found and a fifth that did not fit: complete")
	-- Nothing new: nothing changes.
	assert_false(model.update_rows(rs, d, cf, 4, true, 100))
	-- Two events identical to the newest row: one row, three events, same key.
	ev(d, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, { station = 6, a = 60 })
	ev(d, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, { station = 6, a = 61 })
	assert_true(model.update_rows(rs, d, cf, 4, true, 100))
	assert_eq(shape(), { { 6, 3 }, { 5, 1 }, { 4, 1 }, { 3, 1 } })
	assert_eq({ rs.groups[1].seq, rs.groups[1].a }, { 8, 61 })
	-- A different event pushes the bottom row out.
	ev(d, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, { station = 9 })
	model.update_rows(rs, d, cf, 4, true, 100)
	assert_eq(shape(), { { 9, 1 }, { 6, 3 }, { 5, 1 }, { 4, 1 } })
	-- Follow off: new events do not move the rows; back on: the rows are read from the head again.
	model.update_rows(rs, d, cf, 4, false, 100)
	local frozen = shape()
	ev(d, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, { station = 10 })
	model.update_rows(rs, d, cf, 4, false, 100)
	assert_eq(shape(), frozen)
	assert_eq(rs.anchor, 9)
	-- A filter change while frozen rescans up to the anchor only.
	local errors_too = model.compile(filter({ sev = { true, true, true }, group = 3 }), 1000)
	model.update_rows(rs, d, errors_too, 4, false, 100)
	assert_eq(shape()[1], { 9, 1 })
	model.update_rows(rs, d, cf, 4, true, 100)
	assert_eq(shape(), { { 10, 1 }, { 9, 1 }, { 6, 3 }, { 5, 1 } })
end)

test("rows: severity toggles, a sparse filter scanned over several updates, the window trims the bottom", function()
	at(0)
	local d = setup()
	ev(d, DIAG_KIND_ALERT, DIAG_SEV_ERROR, { train = 7, code = DIAG_ALERT_STUCK })
	for s = 1, 300 do ev(d, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, { station = s }) end
	local rs = {}
	local cf = model.compile(filter({ train = 7 }), 0)
	model.update_rows(rs, d, cf, 5, true, 100)
	assert_eq(#rs.groups, 0)
	assert_not_nil(rs.below, "budget spent before the match")
	model.update_rows(rs, d, cf, 5, true, 100)
	model.update_rows(rs, d, cf, 5, true, 100)
	model.update_rows(rs, d, cf, 5, true, 100)
	assert_eq(#rs.groups, 1)
	assert_eq(rs.groups[1].train, 7)
	assert_nil(rs.below)
	-- Errors hidden: nothing.
	local rs2 = {}
	model.update_rows(rs2, d, model.compile(filter({ sev = { false, true, true }, train = 7 }), 0), 5, true, 1000)
	assert_eq(#rs2.groups, 0)
	-- Window: rows older than 10 min leave the bottom.
	at(36000 + 10)
	ev(d, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, { station = 999 })
	local rs3 = {}
	local w = model.compile(filter({ window = 1 }), 36000 + 10)
	model.update_rows(rs3, d, w, 5, true, 1000)
	assert_eq(#rs3.groups, 1)
	assert_eq(rs3.groups[1].station, 999)
end)

test("counts: equal a brute-force count through eviction, a moving window and a chunked first count", function()
	at(0)
	local d = setup("full", 1024)
	local sevs = { DIAG_SEV_ERROR, DIAG_SEV_WARNING, DIAG_SEV_INFO }
	local n = 0
	local function burst(k, tick_step)
		for _ = 1, k do
			n = n + 1
			at(game.tick + tick_step)
			local kind = (n % 3 == 0) and DIAG_KIND_ARRIVE_P or DIAG_KIND_STATION_LIMIT
			ev(d, kind, sevs[n % 3 + 1], { station = n % 7, train = n % 5 })
		end
	end
	burst(3000, 3)
	local f = filter({ window = 1 })
	local cs = {}
	local cf = model.compile(f, game.tick)
	-- 300-row budget: the first count takes several updates and says so.
	assert_true(model.update_counts(cs, d, cf, 300))
	local guard = 0
	while model.update_counts(cs, d, cf, 300) do guard = guard + 1 end
	assert_true(guard > 1)
	assert_eq(cs.total, oracle_counts(d, cf))
	for round = 1, 6 do
		burst(700, 7)
		cf = model.compile(f, game.tick)
		model.update_counts(cs, d, cf, 300)
		assert_eq(cs.total, oracle_counts(d, cf), "round " .. round)
	end
	-- Everything kept, with a station subject: still the brute force.
	local all = model.compile(filter({ subject = { kind = "station", id = 3 } }), game.tick)
	local cs2 = {}
	while model.update_counts(cs2, d, all, 500) do end
	assert_eq(cs2.total, oracle_counts(d, all))
	burst(1500, 1)
	all = model.compile(filter({ subject = { kind = "station", id = 3 } }), game.tick)
	model.update_counts(cs2, d, all, 500)
	assert_eq(cs2.total, oracle_counts(d, all))
end)

test("badge: errors after the last seen seq, counted forward within a budget; seen clears it", function()
	at(0)
	local d = setup()
	for k = 1, 10 do ev(d, DIAG_KIND_ALERT, k % 2 == 0 and DIAG_SEV_ERROR or DIAG_SEV_WARNING) end
	local bs = {}
	assert_eq(model.update_badge(bs, d, nil, 4), 2)
	assert_eq(model.update_badge(bs, d, nil, 100), 5)
	assert_eq(model.update_badge(bs, d, 10, 100), 0)
	ev(d, DIAG_KIND_DISPATCH_FAILED, DIAG_SEV_ERROR)
	assert_eq(model.update_badge(bs, d, 10, 100), 1)
	-- A new diagnostics state starts the count again.
	setup("off")
	at(50)
	d = setup("basic")
	ev(d, DIAG_KIND_DISPATCH_FAILED, DIAG_SEV_ERROR)
	assert_eq(model.update_badge(bs, d, 10, 100), 1)
end)

test("summary: top stations and items by events in the window with the worst severity", function()
	at(0)
	local d = setup()
	local iron = diag.intern(d, "iron-plate")
	local coal = diag.intern(d, "coal")
	for _ = 1, 3 do ev(d, DIAG_KIND_SHORT_LOAD, DIAG_SEV_WARNING, { station = 11, item = iron }) end
	ev(d, DIAG_KIND_UNSERVED_REASON, DIAG_SEV_ERROR, { station = 12, item = coal })
	ev(d, DIAG_KIND_UNSERVED_REASON, DIAG_SEV_INFO, { station = 12, item = coal })
	ev(d, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, { station = 13 })
	for s = 20, 35 do ev(d, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, { station = s }) end
	local ss = {}
	local cf = model.compile(filter(), 0)
	local guard = 0
	while not model.update_summary(ss, d, cf, 5) do guard = guard + 1 end
	assert_true(guard >= 3)
	assert_eq(#ss.top_stations, model.SUMMARY_TOP)
	assert_eq({ ss.top_stations[1].id, ss.top_stations[1].n, ss.top_stations[1].sev }, { 11, 3, DIAG_SEV_WARNING })
	assert_eq({ ss.top_stations[2].id, ss.top_stations[2].n, ss.top_stations[2].sev }, { 12, 2, DIAG_SEV_ERROR })
	-- Ties: worse severity first, then the lower id.
	assert_eq({ ss.top_stations[3].id, ss.top_stations[4].id }, { 13, 20 })
	assert_eq(ss.top_items, { { item = iron, n = 3, sev = DIAG_SEV_WARNING }, { item = coal, n = 2, sev = DIAG_SEV_ERROR } })
	assert_eq(ss.scanned, 22)
	-- The severities apply: errors only.
	local ss2 = {}
	while not model.update_summary(ss2, d, model.compile(filter({ sev = { true, false, false } }), 0), 100) do end
	assert_eq(ss2.top_stations, { { id = 12, n = 1, sev = DIAG_SEV_ERROR } })
end)

test("compile and export_filter: groups take their alerts by code; train field and chip combine", function()
	setup()
	local cf = model.compile(filter({ group = 1 }), 100)
	assert_true(cf.kinds[DIAG_KIND_SERVED])
	assert_true(cf.alerts[DIAG_ALERT_MISSING_TRAIN])
	assert_nil(cf.alerts[DIAG_ALERT_STUCK])
	local ex = model.export_filter(model.compile(filter({ sev = { true, false, true }, train = 4,
		subject = { kind = "train", id = 4 } }), 100))
	assert_eq({ ex.sevs, ex.train, ex.min_tick }, { { [1] = true, [3] = true }, 4, nil })
	ex = model.export_filter(model.compile(filter({ train = 4, subject = { kind = "train", id = 5 } }), 100))
	assert_eq(ex.train, -1)
	ex = model.export_filter(model.compile(filter({ window = 2, subject = { kind = "station", id = 9 } }), 300000, 3))
	assert_eq({ ex.station, ex.min_tick, ex.item, ex.sevs }, { 9, 300000 - 216000, 3, nil })
	-- Every kind is in exactly one group, except alerts, which every group with alert codes may take.
	local seen = {}
	for _, g in ipairs(model.GROUPS) do
		for _, k in ipairs(g.kinds) do
			assert_nil(seen[k], "kind " .. k .. " in two groups")
			seen[k] = true
		end
	end
	for k = 1, #DIAG_KIND_NAMES do assert_true(seen[k] == true, "kind " .. DIAG_KIND_NAMES[k] .. " in no group") end
	local codes = {}
	for _, g in ipairs(model.GROUPS) do
		for _, c in ipairs(g.alerts or {}) do codes[c] = (codes[c] or 0) + 1 end
	end
	for c = 1, #DIAG_ALERT_NAMES do assert_eq(codes[c], 1, "alert " .. DIAG_ALERT_NAMES[c]) end
end)

test("age: two units in the column, the absolute tick in the tooltip, the range for a collapsed row", function()
	setup()
	local util = H.load("scripts.gui.util")
	local one, four = { tick = 60, first_tick = 60, n = 1 }, { tick = 120, first_tick = 60, n = 4 }
	assert_eq(model.age_caption(7260, one, util.short_duration), "2m 00s")
	assert_eq(model.age_caption(60, one, util.short_duration), "0s")
	assert_eq(model.age_caption(60 + 59 * 60, one, util.short_duration), "59s")
	assert_eq(model.age_caption(60 + 3 * 86400 * 60, one, util.short_duration), "3d 00h")
	assert_eq(model.age_tooltip(one, util.format_duration), { "cybersyn-gui.log-age-tooltip", "60", "1s" })
	assert_eq(model.age_caption(216000 + 120, four, util.short_duration), "1h 00m")
	assert_eq(model.age_tooltip(four, util.format_duration),
		{ "cybersyn-gui.log-age-range-tooltip", "60", "120", "1s", "2s", "4" })
end)

test("message: cargo reads loaded 18k of 24k, edits name the player, acknowledgements their expiry", function()
	setup()
	local ctx = {
		player = function(i) return ({ "Daniel", "Ozzy" })[i] end,
		duration = function(t) return tostring(t / 60) .. "s" end,
		stock = function(reason, a, b) return a .. "/" .. b end,
		chip = function(reason) return { "chip", reason } end,
	}
	local function g(kind, fields)
		local out = { kind = kind, code = 0, a = 0, b = 0, station2 = 0, tick = 600, seq = 1, n = 1 }
		for k, v in pairs(fields or {}) do out[k] = v end
		return out
	end
	assert_eq(model.message(g(DIAG_KIND_SHORT_LOAD, { a = 24000, b = 18000 }), ctx),
		{ "cybersyn-diag.msg-short-load", "18k", "24k" })
	assert_eq(model.message(g(DIAG_KIND_RESIDUAL_CARGO, { a = 400, b = 30 }), ctx),
		{ "cybersyn-diag.msg-residual-cargo", "30", "400" })
	assert_eq(model.message(g(DIAG_KIND_SCHEDULE_EDITED, { a = 2, b = 1 }), ctx),
		{ "cybersyn-diag.msg-schedule-edited", "Ozzy" })
	assert_eq(model.message(g(DIAG_KIND_SCHEDULE_EDITED, { a = 1, b = 5 }), ctx),
		{ "cybersyn-diag.msg-schedule-edited-group", "Daniel", "5" })
	assert_eq(model.message(g(DIAG_KIND_ACKNOWLEDGED, { code = DIAG_ACK_REQUEST, station2 = 1, a = 600 + 3600 }), ctx),
		{ "cybersyn-diag.msg-acknowledged", { "cybersyn-diag.ack-kind-request" }, "Daniel", "60s" })
	assert_eq(model.message(g(DIAG_KIND_ACKNOWLEDGED, { code = DIAG_ACK_LINT, station2 = 2, a = 0 }), ctx),
		{ "cybersyn-diag.msg-acknowledged-reason", { "cybersyn-diag.ack-kind-lint" }, "Ozzy" })
	assert_eq(model.message(g(DIAG_KIND_UNSERVED_REASON, { code = REASON_P_BELOW_THRESHOLD, a = 5, b = 9 }), ctx),
		{ "cybersyn-diag.msg-unserved-reason", { "chip", REASON_P_BELOW_THRESHOLD }, "5/9" })
	assert_eq(model.message(g(DIAG_KIND_ALERT, { code = DIAG_ALERT_STUCK }), ctx),
		{ "cybersyn-diag.msg-alert", { "cybersyn-diag.alert-stuck" } })
	assert_eq(model.message(g(DIAG_KIND_TRAIN_STATE, { code = defines.train_state.wait_signal, a = 1200 }), ctx),
		{ "cybersyn-diag.msg-train-state-wait-signal", "20s" })
	assert_eq(model.message(g(DIAG_KIND_MANUAL_ACTION, { a = ACTION_FIX_PRIORITIES, station2 = 0 }), ctx),
		{ "cybersyn-diag.msg-manual-action", { "cybersyn-diag.action-fix-priorities" }, { "cybersyn-diag.log-server" } })
	assert_eq(model.message(g(DIAG_KIND_LINT, { code = DIAG_LINT_CLEARED, a = LINT_CAPACITY }), ctx),
		{ "cybersyn-diag.msg-lint-cleared", { "cybersyn-diag.lint-capacity" } })
end)

test("chat tags: train by front stock unit number, stop by unit number, item, gps", function()
	setup()
	assert_eq(model.chat_tags(812, 4410, { x = 10.5, y = -3.5, surface = "nauvis" }, "iron-plate|rare"),
		"[train=812] [train-stop=4410] [item=iron-plate,quality=rare] [gps=10,-4,nauvis]")
	assert_eq(model.chat_tags(nil, nil, nil, "water"), "[fluid=water]")
	assert_eq(model.chat_tags(nil, 7, nil, nil), "[train-stop=7]")
end)

--- Keys of one section of a locale file.
local function locale_keys(path, section)
	local f = io.open(path, "r")
	if not f then return nil end
	local keys, current = {}, nil
	for line in f:lines() do
		local s = string.match(line, "^%[(.-)%]%s*$")
		if s then
			current = s
		elseif current == section then
			local k = string.match(line, "^([^=]+)=")
			if k then keys[k] = true end
		end
	end
	f:close()
	return keys
end

--- Every [section] key inside a LocalisedString.
local function collect_keys(ls, out)
	if type(ls) ~= "table" then return end
	local k = ls[1]
	if type(k) == "string" and k ~= "" then out[k] = true end
	for i = 2, #ls do collect_keys(ls[i], out) end
end

test("locale: every key the Log builds exists in en and in the six fallback locales", function()
	setup()
	local used = {}
	local ctx = {
		player = function() return "p" end,
		duration = function() return "1s" end,
		stock = function(reason) return reason == REASON_NO_PROVIDER and "–" or "1/2" end,
		chip = function() return "chip" end,
	}
	for kind = 1, #DIAG_KIND_NAMES do
		used["cybersyn-diag.kind-" .. DIAG_KIND_KEYS[kind]] = true
		local variants = {
			{}, { a = 1 }, { b = 1 }, { b = 3 }, { code = 1 }, { code = REASON_NO_PROVIDER },
			{ code = DIAG_LINT_CLEARED, a = 1 }, { code = DIAG_LINT_APPEARED, a = 1 },
			{ b = DIAG_ACK_END_MANUAL }, { b = DIAG_ACK_END_EXPIRED }, { a = 1, code = DIAG_ACK_STATION },
		}
		for _, v in ipairs(variants) do
			local g = { kind = kind, code = v.code or 0, a = v.a or 0, b = v.b or 0, station2 = 1, tick = 0, n = 1 }
			collect_keys(model.message(g, ctx), used)
		end
	end
	for code = 1, #DIAG_ALERT_NAMES do
		collect_keys(model.message({ kind = DIAG_KIND_ALERT, code = code, a = 0, b = 0, station2 = 0, tick = 0 }, ctx), used)
	end
	for code = 1, #DIAG_DISPATCH_NAMES do
		collect_keys(model.message({ kind = DIAG_KIND_DISPATCH_FAILED, code = code, a = 0, b = 0, tick = 0 }, ctx), used)
	end
	for code = 1, #DIAG_FAIL_NAMES do
		collect_keys(model.message({ kind = DIAG_KIND_DELIVERY_FAILED, code = code, a = 0, b = 0, tick = 0 }, ctx), used)
	end
	for _, state in pairs(defines.train_state) do
		collect_keys(model.message({ kind = DIAG_KIND_TRAIN_STATE, code = state, a = 0, b = 0, tick = 0 }, ctx), used)
	end
	for _, b in ipairs({ 1, 2, 3, 4 }) do
		collect_keys(model.message({ kind = DIAG_KIND_UNACKNOWLEDGED, code = 1, a = 0, b = b, station2 = 1, tick = 0 }, ctx),
			used)
	end
	for _, g in ipairs(model.GROUPS) do used["cybersyn-gui.log-group-" .. g.name] = true end
	for _, k in ipairs({ "error", "warning", "info" }) do used["cybersyn-diag.sev-" .. k] = true end
	-- The GUI's own keys: every "cybersyn-gui.log-..." and "cybersyn-diag...." literal in log.lua.
	local src = io.open(H.mod_root .. "/scripts/gui/log.lua"):read("*a")
	for key in string.gmatch(src, '"(cybersyn%-gui%.[%w%-]+)"') do
		if not string.match(key, "%-$") then used[key] = true end
	end
	for _, mode in ipairs({ "basic", "full" }) do used["cybersyn-gui.log-mode-" .. mode] = true end
	for key in string.gmatch(src, '"(cybersyn%-diag%.[%w%-]+)"') do
		if not string.match(key, "%-$") then used[key] = true end
	end
	for _, loc in ipairs({ "en", "de", "es", "fr", "ko", "ru", "sv-SE" }) do
		local path = H.mod_root .. "/locale/" .. loc .. "/manager.cfg"
		local sections = { ["cybersyn-gui"] = locale_keys(path, "cybersyn-gui"), ["cybersyn-diag"] = locale_keys(path, "cybersyn-diag") }
		local missing = {}
		for key in pairs(used) do
			local section, name = string.match(key, "^([^.]+)%.(.+)$")
			if sections[section] and not sections[section][name] then missing[#missing + 1] = loc .. ": " .. key end
		end
		table.sort(missing)
		assert_eq(missing, {}, loc)
	end
end)
