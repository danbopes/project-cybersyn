-- The pure builders of the relative panels (scripts/gui/relative-text.lua) and the bounded backward scan they read
-- the log with (diag.last_for_step).

local H = require("harness")

local function rt()
	return H.load("scripts.gui.relative-text")
end


test("role: provider, requester, both, none; stack mode appended", function()
	local t = rt()
	assert_eq(t.role(true, true, false), { "cybersyn-gui.relative-role-both" })
	assert_eq(t.role(true, false, false), { "cybersyn-gui.relative-role-provider" })
	assert_eq(t.role(false, true, false), { "cybersyn-gui.relative-role-requester" })
	assert_eq(t.role(false, false, false), { "cybersyn-gui.relative-role-none" })
	assert_eq(t.role(false, true, true),
		{ "", { "cybersyn-gui.relative-role-requester" }, " · ", { "cybersyn-gui.relative-stack-mode" } })
end)

test("stacks: whole stacks a threshold fills, rounded up; no stack size reads 0", function()
	local t = rt()
	assert_eq(t.stacks(2000, 100), 20)
	assert_eq(t.stacks(2001, 100), 21)
	assert_eq(t.stacks(2000, 5), 400)
	assert_eq(t.stacks(1, 200), 1)
	assert_eq(t.stacks(0, 50), 0)
	assert_eq(t.stacks(100, nil), 0)
end)

test("effective_threshold: a lower provider threshold replaces the requester's, a higher one does not", function()
	local t = rt()
	local v, o = t.effective_threshold(5000, 2000)
	assert_eq(v, 2000)
	assert_true(o)
	v, o = t.effective_threshold(5000, 8000)
	assert_eq(v, 5000)
	assert_false(o)
	v, o = t.effective_threshold(5000, nil)
	assert_eq(v, 5000)
	assert_false(o)
end)

test("train_mask: one network, NETWORK_EACH by name, other networks nil", function()
	local t = rt()
	assert_eq(t.train_mask({ network_name = "signal-A", network_mask = 3 }, "signal-A"), 3)
	assert_nil(t.train_mask({ network_name = "signal-A", network_mask = 3 }, "signal-B"))
	assert_eq(t.train_mask({ network_name = NETWORK_EACH, network_mask = { ["signal-B"] = 4 } }, "signal-B"), 4)
	assert_nil(t.train_mask({ network_name = NETWORK_EACH, network_mask = { ["signal-B"] = 4 } }, "signal-A"))
	assert_nil(t.train_mask({ network_name = nil }, "signal-A"))
end)

test("count_train: mask matches and distinct depots; capability per layout over every train on the network", function()
	local t = rt()
	local counts = { ["signal-A"] = t.new_fleet_count(1), ["signal-B"] = t.new_fleet_count(2) }
	local trains = {
		{ network_name = "signal-A", network_mask = 1, depot_id = 10, layout_id = 1, item_slot_capacity = 40, fluid_capacity = 0 },
		{ network_name = "signal-A", network_mask = 3, depot_id = 10, layout_id = 2, item_slot_capacity = 80, fluid_capacity = 0 },
		{ network_name = "signal-A", network_mask = 2, depot_id = 11, layout_id = 1, item_slot_capacity = 40, fluid_capacity = 0 },
		{ network_name = NETWORK_EACH, network_mask = { ["signal-B"] = 6 }, depot_id = 12, layout_id = 3, item_slot_capacity = 0, fluid_capacity = 50000 },
		{ network_name = "signal-C", network_mask = 1, depot_id = 13, layout_id = 1, item_slot_capacity = 40 },
	}
	for _, tr in ipairs(trains) do t.count_train(counts, tr) end
	local a, b = counts["signal-A"], counts["signal-B"]
	assert_eq(a.trains, 2, "trains sharing bit 1")
	assert_eq(a.depots, 1, "both in depot 10")
	assert_eq(a.capability[1], { count = 2, item_capacity = 40, fluid_capacity = 0, mask_or = 3 })
	assert_eq(a.capability[2], { count = 1, item_capacity = 80, fluid_capacity = 0, mask_or = 3 })
	assert_eq(b.trains, 1)
	assert_eq(b.depots, 1)
	assert_eq(b.capability[3].fluid_capacity, 50000)
	assert_eq(a.matched[1], { count = 1, item_capacity = 40, fluid_capacity = 0 }, "layout 1: only the mask-1 train")
	assert_eq(a.matched[2], { count = 1, item_capacity = 80, fluid_capacity = 0 })
end)

--- A fleet count of one network from {mask, layout_id, items, fluid} trains against the stop's mask.
local function fleet(t, stop_mask, trains)
	local counts = { ["signal-A"] = t.new_fleet_count(stop_mask) }
	for _, x in ipairs(trains) do
		t.count_train(counts, { network_name = "signal-A", network_mask = x[1], depot_id = 1, layout_id = x[2],
			item_slot_capacity = x[3], fluid_capacity = x[4] or 0 })
	end
	return counts["signal-A"]
end

test("eligible: trains counted one by one, never a layout's whole count by its OR-ed mask", function()
	local t = rt()
	-- One layout, four trains with masks 1, 2, 4, 8; the stop's mask is 1.
	local c = fleet(t, 1, { { 1, 7, 40 }, { 2, 7, 40 }, { 4, 7, 40 }, { 8, 7, 40 } })
	assert_eq(c.trains, 1)
	assert_eq(c.capability[7].count, 4)
	local n, items = t.eligible(c, true, {})
	assert_eq(n, 1, "matches the per-train count")
	assert_eq(items, 40)
	-- The largest capacity comes from a matching train only.
	c = fleet(t, 1, { { 1, 3, 20 }, { 2, 3, 80 } })
	n, items = t.eligible(c, true, {})
	assert_eq({ n, items }, { 1, 20 }, "the 80-stack train shares no bit")
	-- Accepted layouts filter the matched trains.
	c = fleet(t, 3, { { 1, 1, 40 }, { 2, 2, 80 }, { 1, 2, 60 } })
	n, items = t.eligible(c, false, { [1] = true })
	assert_eq({ n, items }, { 1, 40 })
	n, items = t.eligible(c, false, { [2] = true })
	assert_eq({ n, items }, { 2, 80 })
	assert_eq({ t.eligible(nil, true, {}) }, { 0, 0, 0 })
end)

test("allow_list: accepted layouts, eligible trains and the layouts no train has", function()
	local t = rt()
	local c = fleet(t, 1, { { 1, 1, 40 }, { 1, 1, 40 }, { 2, 2, 40 }, { 2, 2, 40 }, { 3, 2, 40 } })
	local n, trains, missing = t.allow_list({ [1] = true, [5] = true, [4] = true }, false, c)
	assert_eq(n, 3)
	assert_eq(trains, 2)
	assert_eq(missing, { 4, 5 })
	n, trains, missing = t.allow_list({ [2] = true }, false, c)
	assert_eq(trains, 1, "only layout 2's mask-3 train shares bit 1")
	assert_eq(missing, {})
	n, trains = t.allow_list({}, true, c)
	assert_false(n)
	assert_eq(trains, 3)
	n, trains, missing = t.allow_list({ [1] = true }, false, nil)
	assert_eq(n, 1)
	assert_eq(trains, 0)
	assert_eq(missing, { 1 })
end)

test("schedule_row: the active record marked, stations, rail waypoints, temporary and interrupt records", function()
	local t = rt()
	assert_eq(t.schedule_row(1, { station = "Depot" }, 2), { caption = { "", "    ", "1", ". ", "Depot" }, active = false })
	assert_eq(t.schedule_row(2, { station = "P", temporary = true }, 2), {
		caption = { "", "▶ ", "2", ". ", "P", " ", { "cybersyn-gui.relative-schedule-temporary" } }, active = true })
	assert_eq(t.schedule_row(3, { rail = true, temporary = true }, 2).caption[5], { "cybersyn-gui.relative-schedule-rail" })
	assert_eq(t.schedule_row(4, { station = "X", temporary = true, created_by_interrupt = true }, 1).caption[7],
		{ "cybersyn-gui.relative-schedule-interrupt" })
end)

test("event_row: rounded age, kind, and the detail each kind needs", function()
	local t = rt()
	assert_eq(t.event_row({ tick = 0, kind = DIAG_KIND_UNSERVED_REASON, code = REASON_R_LAYOUT, a = 0, b = 0 }, 1250),
		{ "", "20s", "  ", { "cybersyn-diag.kind-unserved-reason" }, " · ", { "cybersyn-diag.chip-r-layout" } })
	assert_eq(t.event_row({ tick = 100, kind = DIAG_KIND_SERVED, code = REASON_R_LAYOUT, a = 60, b = 0 }, 100),
		{ "", "0s", "  ", { "cybersyn-diag.kind-served" } })
	assert_eq(t.event_detail({ kind = DIAG_KIND_SHORT_LOAD, code = 0, a = 2000, b = 1900 }),
		{ "cybersyn-gui.relative-event-cargo", "2,000", "1,900" })
	assert_eq(t.event_detail({ kind = DIAG_KIND_LINT, code = DIAG_LINT_APPEARED, a = LINT_LAYOUT, b = 5 }),
		{ "", { "cybersyn-diag.lint-layout" }, " (", { "cybersyn-diag.lint-appeared" }, ")" })
	assert_eq(t.event_detail({ kind = DIAG_KIND_STATION_LIMIT, code = 0, a = 2, b = 0 }),
		{ "cybersyn-gui.relative-event-limit", "2", "0" })
	assert_nil(t.event_detail({ kind = DIAG_KIND_ALERT, code = 1, a = 0, b = 0 }))
end)

test("s_colour, trains_pair, mask_text", function()
	local t = rt()
	assert_eq(t.s_colour(0), "cyan")
	assert_eq(t.s_colour(1), "green")
	assert_eq(t.s_colour(3), "green")
	assert_eq(t.s_colour(2), "red")
	assert_eq(t.s_colour(nil), "cyan")
	assert_eq(t.trains_pair(1, 2), "1 / 2")
	assert_eq(t.trains_pair(0, 4294967295), "0 / ∞")
	assert_eq(t.mask_text(5), "5 (101)")
	assert_eq(t.mask_text(0), "0 (0)")
	assert_eq(t.mask_text(-1), "-1")
	assert_eq(t.mask_text(65536), "65536")
end)

-- ---------------------------------------------------------------- diag.last_for_step

local diag = H.load("scripts.diag")

local function setup(mode)
	settings.global["cybersyn-diagnostics"] = { value = mode or "full" }
	settings.global["cybersyn-diagnostics-ring"] = { value = 16384 }
	storage.trains = storage.trains or {}
	storage.stations = storage.stations or {}
	return diag.apply()
end

local function seqs(rows)
	local out = {}
	for i, ev in ipairs(rows) do out[i] = ev.seq end
	return out
end

--- `n` events about `station` (basic and full rings alternating) among `filler` others each.
local function fill(d, station, n, filler)
	for _ = 1, n do
		for _ = 1, filler do diag.event(d, DIAG_KIND_ARRIVE_P, DIAG_SEV_INFO, 0, 0, 1, 999, 0, 0, 0, 0) end
		diag.event(d, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, 0, 0, 0, station, 0, 0, 1, 2)
		diag.event(d, DIAG_KIND_ARRIVE_R, DIAG_SEV_INFO, 0, 0, 2, station, 0, 0, 0, 0)
	end
end

test("last_for_step: equals last_for once done, with at most the budget examined per call", function()
	game.tick = 10
	local d = setup("full")
	fill(d, 7, 6, 500)
	local want = seqs(diag.last_for("station", 7, 10))
	assert_eq(#want, 10)
	local c = diag.scan_cursor("station", 7, 10)
	local calls = 0
	repeat
		diag.last_for_step(c, 300)
		calls = calls + 1
		assert_true(c.examined <= 300, "examined " .. c.examined)
	until c.done or calls > 100
	assert_true(c.done)
	assert_eq(seqs(c.rows), want)
	assert_true(calls > 5, "the scan was spread over calls: " .. calls)
end)

test("last_for_step: rows written since the last call come first, without a rescan", function()
	game.tick = 10
	local d = setup("full")
	fill(d, 7, 12, 3)
	local c = diag.scan_cursor("station", 7, 10)
	diag.last_for_step(c)
	assert_true(c.done)
	fill(d, 7, 1, 20)
	diag.last_for_step(c)
	assert_eq(c.examined, 22, "only the new rows")
	assert_eq(seqs(c.rows), seqs(diag.last_for("station", 7, 10)))
end)

test("last_for_step: fewer matches than n is done at the end of the log; a new state starts over", function()
	game.tick = 10
	local d = setup("basic")
	fill(d, 7, 2, 5)
	local c = diag.scan_cursor("station", 7, 10)
	diag.last_for_step(c)
	assert_true(c.done)
	assert_eq(#c.rows, 2, "basic keeps only the limit rows")
	setup("off")
	assert_eq(diag.last_for_step(c), {})
	game.tick = 20
	d = setup("basic")
	fill(d, 7, 1, 0)
	assert_eq(#diag.last_for_step(c), 1)
end)

test("last_for_step: more new rows than the budget start over from the newest", function()
	game.tick = 10
	local d = setup("full")
	fill(d, 7, 3, 0)
	local c = diag.scan_cursor("station", 7, 10)
	diag.last_for_step(c)
	fill(d, 9, 2, 400)
	fill(d, 7, 1, 0)
	diag.last_for_step(c, 100)
	assert_eq(c.rows[1].seq, d.seq)
	repeat diag.last_for_step(c, 100) until c.done
	assert_eq(seqs(c.rows), seqs(diag.last_for("station", 7, 10)))
end)
