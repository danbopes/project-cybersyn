-- Characterization tests for the Stations query pipeline (scripts/gui/stations.lua at 3b5fe31): the status ladder,
-- sort order with its name/id tiebreak, the status filter and the incremental update from the collector log.
-- PLAN3 §4.2 moved the status ladder into collector.station_status: records carry `status` as the collector sets it
-- once per pass, and the query reads it. §4.1 dropped the `tiebreak` string: ties compare name_lower, then id.

local H = require("harness")

local function st(id, name, over)
	local r = {
		id = id,
		name = name,
		name_lower = string.lower(name),
		surface_index = 1,
		network_name = "signal-A",
		network_mask = 1,
		comb_ok = true,
		warming_up = false,
		trains_limit = 2,
		deliveries_total = 0,
		provided = {},
		requested = {},
		deliveries = {},
		wait = {},
	}
	for k, v in pairs(over or {}) do r[k] = v end
	return r
end

local function setup()
	local stations_tab = H.load("scripts.gui.stations")
	local collector = require("scripts.gui.collector")
	mod_settings = { tps = 60 }
	storage.total_ticks = 200000
	storage.manager = { players = {} }
	collector.init()
	local snap = collector.get()
	snap.stations = {
		[1] = st(1, "Alpha", { comb_ok = false }),
		[2] = st(2, "Bravo", { trains_limit = 0 }),
		[3] = st(3, "Charlie", { warming_up = true, requested = { coal = { count = -5, threshold = 1, active = true } } }),
		[4] = st(4, "Delta", { requested = { coal = { count = -5, threshold = 1, active = true } }, longest_wait_start = 100 }),
		[5] = st(5, "Echo", { deliveries_total = 2 }),
		[6] = st(6, "Foxtrot", { trains_limit = 2100000000, deliveries_total = 5 }),
		[7] = st(7, "Golf", { last_delivery_tick = 50000 }),
		[8] = st(8, "Hotel"),
		[9] = st(9, "Hotel", { last_delivery_tick = 50000, requested = { stone = { count = -5, threshold = 1, active = true } }, longest_wait_start = 20 }),
	}
	snap.starved = { ["signal-A:coal"] = true }
	for _, record in pairs(snap.stations) do
		record.status = collector.station_status(record, snap.starved)
	end
	snap.starved_version = 1
	snap.tick = 10
	game.tick = 20
	return stations_tab, collector, snap
end

local function ids(rows)
	local out = {}
	for i, r in ipairs(rows) do out[i] = r.id end
	return out
end

test("query: status ladder and counts", function()
	local stations_tab = setup()
	local pd = {}
	local rows, counts, ctx, column, ascending = stations_tab.query(pd)
	assert_eq(column, "name")
	assert_true(ascending)
	assert_eq(ids(rows), { 1, 2, 3, 4, 5, 6, 7, 8, 9 })
	assert_eq(ctx.status, {
		[1] = "no_power", [2] = "disabled", [3] = "warming_up", [4] = "starved", [5] = "saturated",
		[6] = "ok", [7] = "idle", [8] = "ok", [9] = "ok",
	})
	-- Phase 4: the chip counts besides the statuses; failing = no power + disabled (+ throttling + setup).
	assert_eq(counts, { all = 9, no_power = 1, disabled = 1, warming_up = 1, starved = 1, setup = 0, saturated = 1, idle = 1,
		ok = 3, unserved = 0, problems = 0, failing = 2, stuck = 0 })
end)

-- PLAN4 D15-5: an OK station with an open setup error reads Setup, counted in its own chip and not in OK; an
-- acknowledgement, which writes no change-log entry, turns it back on the next query.
test("query: Setup replaces OK while an error finding is open", function()
	local stations_tab, _, snap = setup()
	snap.stations[8].lint = LINT_BIT[LINT_CAPACITY]
	snap.stations[4].lint = LINT_BIT[LINT_CAPACITY]
	snap.stations[9].lint = LINT_BIT[LINT_LIMIT_ZERO]
	local pd = {}
	local _, counts, ctx = stations_tab.query(pd)
	assert_eq(ctx.status[8], "setup")
	assert_eq(ctx.status[4], "starved", "a status that says why stays")
	assert_eq(ctx.status[9], "ok", "a warning does not block")
	assert_eq(counts.setup, 1)
	assert_eq(counts.ok, 2)
	pd.stations_chip = "setup"
	assert_eq(ids((stations_tab.query(pd))), { 8 })
	pd.stations_chip = nil
	storage.acks = { request = {}, station = {}, lint = { [8] = { [LINT_CAPACITY] = { player_index = 1 } } }, lint_version = 1 }
	_, counts, ctx = stations_tab.query(pd)
	assert_eq(ctx.status[8], "ok")
	assert_eq(counts.setup, 0)
	assert_eq(counts.ok, 3)
	storage.acks = nil
end)

test("station_status: idle needs an old last delivery, tps > 0 and no active request", function()
	local _, collector, snap = setup()
	local golf = snap.stations[7]
	mod_settings.tps = 0
	assert_eq(collector.station_status(golf, snap.starved), "ok")
	mod_settings.tps = 60
	-- 30 minutes at tps 60 is exactly IDLE_TICKS, which is not idle yet.
	golf.last_delivery_tick = 200000 - 108000
	assert_eq(collector.station_status(golf, snap.starved), "ok")
	golf.last_delivery_tick = 200000 - 108001
	assert_eq(collector.station_status(golf, snap.starved), "idle")
	golf.requested = { stone = { count = -5, threshold = 1, active = true } }
	assert_eq(collector.station_status(golf, snap.starved), "ok")
	golf.requested = { stone = { count = -5, threshold = 10, active = false } }
	assert_eq(collector.station_status(golf, snap.starved), "idle")
	golf.deliveries_total = 1
	assert_eq(collector.station_status(golf, snap.starved), "ok")
end)

test("query: descending name keeps the id tiebreak ascending", function()
	local stations_tab = setup()
	local pd = { sort = { stations_tab = { column = "name", ascending = false } } }
	local rows = stations_tab.query(pd)
	assert_eq(ids(rows), { 8, 9, 7, 6, 5, 4, 3, 2, 1 })
end)

test("query: status and wait sort keys", function()
	local stations_tab = setup()
	local pd = { sort = { stations_tab = { column = "station_status", ascending = true } } }
	assert_eq(ids((stations_tab.query(pd))), { 1, 2, 3, 4, 5, 7, 6, 8, 9 })
	stations_tab = setup()
	pd = { sort = { stations_tab = { column = "wait", ascending = true } } }
	-- Ascending wait = latest request start first; stations without a wait last, by name.
	assert_eq(ids((stations_tab.query(pd))), { 4, 9, 1, 2, 3, 5, 6, 7, 8 })
	stations_tab = setup()
	pd = { sort = { stations_tab = { column = "bogus", ascending = true } } }
	local _, _, _, column = stations_tab.query(pd)
	assert_eq(column, "name")
end)

test("query: status filter applies after counting; an unknown chip reads as All without a write", function()
	local stations_tab = setup()
	local pd = { stations_chip = "ok" }
	local rows, counts = stations_tab.query(pd)
	assert_eq(ids(rows), { 6, 8, 9 })
	assert_eq(counts.all, 9)
	pd.stations_chip = "gone"
	rows = stations_tab.query(pd)
	assert_eq(pd.stations_chip, "gone")
	assert_eq(#rows, 9)
end)

test("query: global filters narrow the set and the counts", function()
	local stations_tab = setup()
	local pd = { search_query = "hotel" }
	local rows, counts = stations_tab.query(pd)
	assert_eq(ids(rows), { 8, 9 })
	assert_eq(counts, { all = 2, no_power = 0, disabled = 0, warming_up = 0, starved = 0, setup = 0, saturated = 0, idle = 0,
		ok = 2, unserved = 0, problems = 0, failing = 0, stuck = 0 })
	pd = { search_item = "coal" }
	stations_tab = setup()
	rows = stations_tab.query(pd)
	assert_eq(ids(rows), { 3, 4 })
end)

-- The collector refills records in place (PLAN3 §4.1), so a renamed station keeps its record table.
test("query: a refilled record is merged into the kept order once its pass has completed", function()
	local stations_tab, collector, snap = setup()
	local pd = {}
	stations_tab.query(pd)
	assert_eq(pd.stations_query.sort_kind, "full")
	snap.stations[8].name, snap.stations[8].name_lower = "Aardvark", "aardvark"
	local log = storage.manager.collect_log
	log.ids[#log.ids + 1] = 8
	-- The pass that replaced the record completed on this very tick: the re-sort waits one update.
	snap.tick = 20
	local rows, _, ctx = stations_tab.query(pd)
	assert_eq(ids(rows), { 1, 2, 3, 4, 5, 6, 7, 8, 9 })
	assert_eq(rows[8].name, "Aardvark")
	assert_eq(ctx.status[8], "ok")
	game.tick = 21
	rows = stations_tab.query(pd)
	assert_eq(ids(rows), { 8, 1, 2, 3, 4, 5, 6, 7, 9 })
	assert_eq(pd.stations_query.sort_kind, "merged")
	assert_eq({ collector.log_position() }, { pd.stations_query.epoch, pd.stations_query.pos })
end)

test("query: statuses the collector changed and logged update the cached counts", function()
	local stations_tab, _, snap = setup()
	local pd = {}
	stations_tab.query(pd)
	snap.stations[4].status = "ok"
	snap.stations[9].status = "starved"
	local log = storage.manager.collect_log
	log.ids[#log.ids + 1] = 4
	log.ids[#log.ids + 1] = 9
	local rows, counts, ctx = stations_tab.query(pd)
	assert_eq(ctx.status[4], "ok")
	assert_eq(ctx.status[9], "starved")
	assert_eq(counts.starved, 1)
	assert_eq(counts.ok, 3)
	assert_eq(#rows, 9)
end)

test("query: the status is read from the record, never recomputed", function()
	local stations_tab, _, snap = setup()
	snap.stations[8].status = "saturated"
	local _, counts, ctx = stations_tab.query({})
	assert_eq(ctx.status[8], "saturated")
	assert_eq(counts.saturated, 2)
end)

test("query: removed station leaves rows and counts", function()
	local stations_tab, _, snap = setup()
	local pd = {}
	stations_tab.query(pd)
	snap.stations[5] = nil
	local log = storage.manager.collect_log
	log.ids[#log.ids + 1] = 5
	local rows, counts = stations_tab.query(pd)
	assert_eq(counts.all, 8)
	assert_eq(counts.saturated, 0)
	assert_eq(ids(rows), { 1, 2, 3, 4, 6, 7, 8, 9 })
end)

-- Phase 4 adds the chip flags to the classification, so the first build takes three updates (classify, sort, rows)
-- instead of two (classify and sort, rows).
test("query: the first build after a boosted pass is spread over the three updates after the one that completed it", function()
	local stations_tab, _, snap = setup()
	local pd = { player_index = 1 }
	snap.boosted = true
	snap.tick = 20
	local rows, counts, ctx = stations_tab.query(pd)
	assert_eq(#rows, 0)
	assert_eq(counts, {})
	assert_true(ctx.pending)
	assert_nil(pd.stations_query)
	-- Next update: classified into the cache, not sorted yet, rows still pending.
	game.tick = 21
	rows, counts, ctx = stations_tab.query(pd)
	assert_eq(#rows, 0)
	assert_true(ctx.pending)
	assert_nil(pd.stations_query.order)
	assert_eq(pd.stations_query.counts.all, 9)
	-- The one after: sorted, rows still pending.
	game.tick = 22
	rows, counts, ctx = stations_tab.query(pd)
	assert_eq(#rows, 0)
	assert_true(ctx.pending)
	assert_eq(#pd.stations_query.order, 9)
	game.tick = 23
	rows, counts, ctx = stations_tab.query(pd)
	assert_eq(#rows, 9)
	assert_eq(counts.all, 9)
	assert_nil(ctx.pending)
	-- Only the first build waits: a cache in hand keeps showing rows on the completing update.
	snap.tick = 21
	rows = stations_tab.query(pd)
	assert_eq(#rows, 9)
end)

test("query: a pass completed by dev collect or the regular step shows rows at once", function()
	local stations_tab, _, snap = setup()
	snap.tick = 20
	local rows = stations_tab.query({ player_index = 1 })
	assert_eq(#rows, 9)
end)

-- Phase 4 (PLAN3 §4.7): the chips besides the statuses. Each chip's count is what it shows when toggled.
test("chips: unserved, problems, stuck and failing count what they show", function()
	local stations_tab, collector, snap = setup()
	snap.stations[5].unserved = { count = 2, worst_reason = 1, oldest_first_tick = 1 }
	snap.stations[6].lint = 8
	snap.stations[7].throttling = true
	snap.stations[8].lint = 1
	snap.stations[8].unserved = { count = 1, worst_reason = 1, oldest_first_tick = 1 }
	snap.trains = { [70] = { id = 70, p_station_id = 4, r_station_id = 9 }, [71] = { id = 71, p_station_id = 3 } }
	snap.alerts = { { train_id = 70, kind = 1 }, { train_id = 71, kind = 2 } }
	local pd = {}
	local _, counts = stations_tab.query(pd)
	assert_eq({ counts.unserved, counts.problems, counts.stuck, counts.failing }, { 2, 2, 2, 5 })
	-- The Problems view sorts worst first (PLAN4 D7): capacity (8) before the check behind bit 8 (6).
	local want = { unserved = { 5, 8 }, problems = { 8, 6 }, stuck = { 4, 9 }, failing = { 1, 2, 6, 7, 8 } }
	for chip, list in pairs(want) do
		pd.stations_chip = nil
		stations_tab.set_chip(pd, chip)
		local rows, c = stations_tab.query(pd)
		assert_eq(ids(rows), list, chip)
		assert_eq(#rows, c[chip], chip .. " count == rows")
	end
	-- Toggling the active chip again shows all; a status chip replaces a flag chip.
	pd = {}
	stations_tab.set_chip(pd, "failing")
	assert_eq(pd.stations_chip, "failing")
	stations_tab.set_chip(pd, "failing")
	assert_nil(pd.stations_chip)
	stations_tab.set_chip(pd, "problems")
	stations_tab.set_chip(pd, "ok")
	assert_eq(pd.stations_chip, "ok")
	-- The surface filter narrows every chip count.
	snap.stations[8].surface_index = 2
	local _, narrowed = stations_tab.query({ search_surface_idx = 1 })
	assert_eq({ narrowed.unserved, narrowed.problems }, { 1, 1 })
end)

-- PLAN4 D2/D7: the Overview's Misconfigured line counts stations with an error nobody acknowledged; the Problems view
-- it jumps to lists those first, so a station whose findings are all acknowledged moves behind the open ones as soon
-- as the acknowledgement changes (storage.acks.lint_version), without waiting for a collector pass.
test("problems view: acknowledged stations sort after the open ones, at once", function()
	local stations_tab, _, snap = setup()
	snap.stations[6].lint = 8
	snap.stations[8].lint = 1
	local pd = {}
	stations_tab.set_chip(pd, "problems")
	assert_eq(ids((stations_tab.query(pd))), { 8, 6 })
	storage.acks = { request = {}, station = {}, lint = { [8] = { [1] = { player_index = 1 } } }, lint_version = 1 }
	local rows, counts = stations_tab.query(pd)
	assert_eq(ids(rows), { 6, 8 }, "the fully acknowledged station goes last")
	assert_eq(counts.problems, 2, "the chip still counts every station with a finding")
	storage.acks.lint[8] = nil
	storage.acks.lint_version = 2
	assert_eq(ids((stations_tab.query(pd))), { 8, 6 }, "ending the acknowledgement puts it back")
	storage.acks = nil
end)

test("chips: a refilled record moves between chip counts with the change log", function()
	local stations_tab, collector, snap = setup()
	local pd = {}
	local _, counts = stations_tab.query(pd)
	assert_eq(counts.problems, 0)
	snap.stations[3].lint = 4
	local manager = storage.manager
	manager.collect_log = manager.collect_log or { epoch = 1, base = 0, ids = {} }
	local log = manager.collect_log
	log.ids[#log.ids + 1] = 3
	local _, after = stations_tab.query(pd)
	assert_eq(after.problems, 1)
	assert_eq(after.failing, 3)
end)

-- PLAN4 D15 item 15: names sort by the value of their digit runs, ties keep the id order.
test("query: natural name order (stn-1 < stn-2 < stn-10), both directions", function()
	local stations_tab, _, snap = setup()
	snap.stations = {
		[1] = st(1, "stn-10"),
		[2] = st(2, "stn-2"),
		[3] = st(3, "stn-1"),
		[4] = st(4, "stn-02"),
		[5] = st(5, "Alpha"),
	}
	for _, record in pairs(snap.stations) do record.status = "ok" end
	assert_eq(ids((stations_tab.query({}))), { 5, 3, 2, 4, 1 })
	local pd = { sort = { stations_tab = { column = "name", ascending = false } } }
	assert_eq(ids((stations_tab.query(pd))), { 1, 2, 4, 3, 5 })
	-- Another column's ties fall back to the natural order too.
	pd = { sort = { stations_tab = { column = "station_status", ascending = true } } }
	assert_eq(ids((stations_tab.query(pd))), { 5, 3, 2, 4, 1 })
end)

-- PLAN4 D7: the Problems chip (round 3's Setup) opens its view sorted worst first; leaving it drops that sort.
test("problems chip: worst severity then check order; the sort comes and goes with the chip", function()
	local stations_tab, _, snap = setup()
	snap.stations[2].lint = LINT_BIT[LINT_NEVER_REFUELLED]
	snap.stations[4].lint = LINT_BIT[LINT_LIMIT_ZERO]
	snap.stations[6].lint = LINT_BIT[LINT_LIMIT_ZERO] + LINT_BIT[LINT_LAYOUT]
	snap.stations[8].lint = LINT_BIT[LINT_CAPACITY]
	local pd = {}
	stations_tab.set_chip(pd, "problems")
	local rows, counts, _, column, ascending = stations_tab.query(pd)
	assert_eq({ column, ascending }, { "problems", true })
	assert_eq(counts.problems, 4)
	-- Errors (capacity 1, layout 2) before the warning (limit_zero) before the info (never_refuelled).
	assert_eq(ids(rows), { 8, 6, 4, 2 })
	stations_tab.set_chip(pd, "problems")
	local _, _, _, column2 = stations_tab.query(pd)
	assert_eq(column2, "name")
	-- Provided / requested stands in for Problems outside the view, and the other way round.
	pd = { sort = { stations_tab = { column = "provided_requested", ascending = true } }, stations_chip = "problems",
		stations_problems_view = true }
	local _, _, _, column3 = stations_tab.query(pd)
	assert_eq(column3, "problems")
end)

-- PLAN4 D15 item 8: "Last dispatch" reads never until the first dispatch, and sorts with the stations without one.
test("last dispatch: never while last_delivery_tick is still the build tick; sorts last", function()
	local stations_tab, _, snap = setup()
	storage.stations = {
		[5] = { last_delivery_tick = 1000, created_tick = 1000 },
		[7] = { last_delivery_tick = 50000, created_tick = 1000 },
		[9] = { last_delivery_tick = 50000 },
	}
	for _, id in ipairs({ 1, 2, 3, 4, 5, 6, 8 }) do snap.stations[id].last_delivery_tick = nil end
	snap.stations[5].last_delivery_tick = 1000
	assert_true(stations_tab.never_dispatched(snap.stations[5]))
	assert_false(stations_tab.never_dispatched(snap.stations[7]))
	assert_false(stations_tab.never_dispatched(snap.stations[9]))
	local pd = { sort = { stations_tab = { column = "last_delivery", ascending = true } } }
	local order = ids((stations_tab.query(pd)))
	assert_eq({ order[1], order[2] }, { 7, 9 })
	assert_eq(order[#order], 8)
	storage.stations = {}
end)

-- PLAN4 D15 item 13: zero-count chips hide (All and the toggled one stay), the rest wrap in order, never abbreviated.
test("chip_lines: hide zero counts, wrap onto the second line in order, keep the toggled chip", function()
	local stations_tab = setup()
	local counts = { all = 30, no_power = 0, disabled = 2, warming_up = 0, starved = 3, saturated = 0, idle = 0, ok = 25,
		unserved = 4, problems = 6, stuck = 0, failing = 8 }
	local l1, l2 = stations_tab.chip_lines(counts, "all", 2000, 2000)
	assert_eq(l1, { "all", "disabled", "starved", "ok", "unserved", "problems", "failing" })
	assert_eq(l2, {})
	-- The toggled chip shows at zero; `always` keeps a chip whose count is not known yet.
	l1 = stations_tab.chip_lines(counts, "idle", 2000, 2000, { stuck = true })
	assert_eq(l1, { "all", "disabled", "starved", "idle", "ok", "unserved", "problems", "stuck", "failing" })
	-- Narrow: what does not fit goes to the second line, keeping the order; nothing is dropped while it fits there.
	l1, l2 = stations_tab.chip_lines(counts, "all", 200, 1000)
	assert_eq(l1, { "all", "disabled" })
	assert_eq(l2, { "starved", "ok", "unserved", "problems", "failing" })
	-- Once a chip went to the second line, the later ones follow it even if they would fit the first.
	l1, l2 = stations_tab.chip_lines({ all = 1, no_power = 1, ok = 1 }, "all", 160, 1000)
	assert_eq(l1, { "all" })
	assert_eq(l2, { "no_power", "ok" })
end)

-- ---------------------------------------------------------------- network sections (round 7)

local function fluid(name, order)
	prototypes.fluid[name] = prototypes.fluid[name]
		or { name = name, order = order, localised_name = { "fluid-name." .. name }, valid = true }
end

local function source(kind, index, priority)
	return { kind = kind, index = index, unit = 100 + index, ok = true, priority = priority or 0 }
end

--- [naphthalene-oil] Provider (pY 126) in the collector's section contract: Provide only, the station combinator on
--- A1, Inventory 1 on A3, Inventory 2 on A4 holding -866 liquid fuel it does not advertise.
local function naphthalene()
	fluid("naphthalene-oil", "z[a]")
	fluid("liquid-fuel", "z[b]")
	local s0, s1, s2 = source("station", 0), source("inventory", 1), source("inventory", 2)
	return st(20, "Naphthalene Provider", {
		is_p = true, is_r = false, network_mask = 1,
		provided = { ["naphthalene-oil"] = 199134, ["liquid-fuel"] = 99134 },
		sources = { s0, s1, s2 },
		mask_union = { ["signal-A"] = 7 },
		sections = {
			{ key = "signal-A:1", network_name = "signal-A", mask = 1, sources = { s0 },
				provided = { ["naphthalene-oil"] = 199134 }, requested = {}, ignored = {} },
			{ key = "signal-A:3", network_name = "signal-A", mask = 3, sources = { s1 },
				provided = { ["liquid-fuel"] = 99134 }, requested = {}, ignored = {} },
			{ key = "signal-A:4", network_name = "signal-A", mask = 4, sources = { s2 },
				provided = {}, requested = {}, ignored = { ["liquid-fuel"] = -866 } },
		},
	})
end

--- A plain Request only station on A3 with requests below threshold.
local function plain()
	local s0 = source("station", 0, 1)
	local requested = {
		["iron-plate"] = { count = -1900, threshold = 2000, active = false },
		["copper-plate"] = { count = -1600, threshold = 2000, active = false },
		coal = { count = -2500, threshold = 2000, active = true },
	}
	local provided = {}
	return st(21, "Circuit Requestor", {
		is_p = false, is_r = true, network_mask = 3, provided = provided, requested = requested,
		sources = { s0 }, mask_union = { ["signal-A"] = 3 },
		sections = { { key = "signal-A:3", network_name = "signal-A", mask = 3, sources = { s0 },
			provided = provided, requested = requested, ignored = { stone = 52 } } },
	})
end

local function slot_ids(defs)
	local out = {}
	for i, d in ipairs(defs) do
		out[i] = d.tags.group and ("[" .. d.caption .. "]") or d.tags.overflow and d.caption or d.tags.id
	end
	return out
end

test("network cell: the naphthalene provider lists its masks with a +2 badge and one tooltip line per section", function()
	local stations_tab = setup()
	local cell = stations_tab.network_cell(naphthalene())
	assert_eq(cell.sprite, "virtual-signal/signal-A")
	assert_eq(cell.caption, "1 · 3 · 4")
	assert_eq(cell.badge, "+2")
	assert_true(cell.small)
	local tip = serpent.line(cell.tooltip)
	assert_true(tip:find('"cybersyn-gui.stations-net-sections", "3"', 1, true) ~= nil, tip)
	assert_true(tip:find('" (", "bits 1+2", ")"', 1, true) ~= nil or tip:find('" (bits 1+2)"', 1, true) ~= nil, tip)
	assert_eq(#cell.tooltip, 2 + 3, "title and three section lines")
	assert_eq(cell.tooltip[5][#cell.tooltip[5]], { "cybersyn-gui.section-nothing" }, "Inventory 2 advertises nothing")
end)

test("network cell: a plain station looks as it does today", function()
	local stations_tab = setup()
	local cell = stations_tab.network_cell(plain())
	assert_eq(cell.caption, "3")
	assert_eq(cell.sig, "signal-A=3")
	assert_nil(cell.badge)
	assert_nil(cell.small)
end)

test("strip: grouped by section with a network label each; A4 advertises nothing and gets no group", function()
	local stations_tab = setup()
	local defs = stations_tab.pr_slots(naphthalene(), nil, 12)
	assert_eq(slot_ids(defs), { "[[virtual-signal=signal-A]1]", "naphthalene-oil", "[[virtual-signal=signal-A]3]", "liquid-fuel" })
	-- Keys stay unique when one item sits in two sections.
	local keys = {}
	for _, d in ipairs(defs) do keys[#keys + 1] = stations_tab.slot_key(d) end
	assert_eq(keys, { "gsignal-A:1", "signal-A:1|pnaphthalene-oil", "gsignal-A:3", "signal-A:3|pliquid-fuel" })
	local tip = serpent.line(defs[4].tooltip)
	assert_true(tip:find('"cybersyn-gui.stations-slot-section", {"", "[virtual-signal=signal-A]3", " (bits 1+2)", " · "', 1, true) ~= nil, tip)
	assert_true(tip:find('"cybersyn-gui.stations-slot-ignored", "[virtual-signal=signal-A]4", "-866", {"cybersyn-gui.section-provide-only"}', 1, true) ~= nil, tip)
end)

test("strip: a group label never ends a line that overflows", function()
	local stations_tab = setup()
	local defs = stations_tab.pr_slots(naphthalene(), nil, 3)
	assert_eq(slot_ids(defs), { "[[virtual-signal=signal-A]1]", "naphthalene-oil", "+1" })
	assert_true(defs[3].tooltip:find("[virtual-signal=signal-A]3", 1, true) ~= nil)
end)

test("strip: a plain station keeps today's ungrouped strip and keys", function()
	local stations_tab = setup()
	local defs = stations_tab.pr_slots(plain(), nil, 12)
	assert_eq(slot_ids(defs), { "coal", "copper-plate", "iron-plate" })
	assert_eq(stations_tab.slot_key(defs[1]), "coal")
end)

test("sort keys: Provided / requested counts items per section; Network sorts by the mask union", function()
	local stations_tab = setup()
	local k = stations_tab.sort_keys
	assert_eq(k.provided_requested(naphthalene()), 2)
	assert_eq(k.provided_requested(plain()), 3)
	assert_eq(k.network(naphthalene()), string.format("%s\0%010.0f", "signal-A", 7 + 2147483648))
end)

test("network filter: a station shows under every bit any of its sections advertises on", function()
	local u = H.load("scripts.gui.util")
	local n = naphthalene()
	local f = { mask = 4, network = "signal-A" }
	assert_true(u.station_passes(n, f), "bit 3 comes from Inventory 2")
	f.mask = 2
	assert_true(u.station_passes(n, f), "bit 2 from Inventory 1's mask 3")
	f.mask = 8
	assert_false(u.station_passes(n, f))
	f.network = "signal-B"
	f.mask = -1
	assert_false(u.station_passes(n, f))
	assert_true(u.station_passes(n, { mask = 4 }), "mask only")
	local p = plain()
	p.mask_union = nil
	assert_false(u.station_passes(p, { mask = 4, network = "signal-A" }), "a record without a union reads its own mask")
end)

test("priority cell: one value for a plain station, highest first when inventories differ, * for item priorities", function()
	local stations_tab = setup()
	local plain_cell = stations_tab.priority_cell(plain())
	assert_eq(plain_cell.caption, "1")
	assert_eq(plain_cell.small, false)
	assert_eq(#plain_cell.tooltip, 2, "no per-source lines when every source agrees")

	local mixed = naphthalene()
	mixed.sources[2].priority = 5
	mixed.sources[3].priority = -2
	local cell = stations_tab.priority_cell(mixed)
	assert_eq(cell.caption, "5 · 0 · -2")
	assert_true(cell.small)
	assert_eq(#cell.tooltip, 2 + 3, "one line per source")
	assert_eq(stations_tab.sort_keys.priority(mixed), 5)

	local overridden = plain()
	overridden.control2 = { [SIGNAL_PRIORITY] = 7 }
	overridden.thresholds = { coal = 100 }
	local o = stations_tab.priority_cell(overridden)
	assert_eq(o.caption, "1*")
	assert_true(serpent.line(o.tooltip):find('"cybersyn-gui.stations-priority-item", "7", "1"', 1, true) ~= nil)
	assert_true(o.sig ~= plain_cell.sig)

	local legacy = st(30, "No sources", { priority = 3 })
	assert_eq(stations_tab.priority_cell(legacy).caption, "3")
end)
