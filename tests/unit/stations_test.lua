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
	assert_eq(counts, { all = 9, no_power = 1, disabled = 1, warming_up = 1, starved = 1, saturated = 1, idle = 1, ok = 3,
		unserved = 0, setup = 0, failing = 2, stuck = 0 })
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

test("query: status filter applies after counting; unknown filters are cleared", function()
	local stations_tab = setup()
	local pd = { stations_status_filter = "ok" }
	local rows, counts = stations_tab.query(pd)
	assert_eq(ids(rows), { 6, 8, 9 })
	assert_eq(counts.all, 9)
	pd.stations_status_filter = "gone"
	rows = stations_tab.query(pd)
	assert_nil(pd.stations_status_filter)
	assert_eq(#rows, 9)
end)

test("query: global filters narrow the set and the counts", function()
	local stations_tab = setup()
	local pd = { search_query = "hotel" }
	local rows, counts = stations_tab.query(pd)
	assert_eq(ids(rows), { 8, 9 })
	assert_eq(counts, { all = 2, no_power = 0, disabled = 0, warming_up = 0, starved = 0, saturated = 0, idle = 0, ok = 2,
		unserved = 0, setup = 0, failing = 0, stuck = 0 })
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

test("query: the first build after a boosted pass is spread over the two updates after the one that completed it", function()
	local stations_tab, _, snap = setup()
	local pd = { player_index = 1 }
	snap.boosted = true
	snap.tick = 20
	local rows, counts, ctx = stations_tab.query(pd)
	assert_eq(#rows, 0)
	assert_eq(counts, {})
	assert_true(ctx.pending)
	assert_nil(pd.stations_query)
	-- Next update: classified and sorted into the cache, rows still pending.
	game.tick = 21
	rows, counts, ctx = stations_tab.query(pd)
	assert_eq(#rows, 0)
	assert_true(ctx.pending)
	assert_eq(#pd.stations_query.order, 9)
	game.tick = 22
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
test("chips: unserved, setup, stuck and failing count what they show", function()
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
	assert_eq({ counts.unserved, counts.setup, counts.stuck, counts.failing }, { 2, 2, 2, 5 })
	local want = { unserved = { 5, 8 }, setup = { 6, 8 }, stuck = { 4, 9 }, failing = { 1, 2, 6, 7, 8 } }
	for chip, list in pairs(want) do
		pd.stations_status_filter, pd.stations_chip = nil, nil
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
	stations_tab.set_chip(pd, "setup")
	stations_tab.set_chip(pd, "ok")
	assert_eq({ pd.stations_status_filter, pd.stations_chip }, { "ok", nil })
	-- The surface filter narrows every chip count.
	snap.stations[8].surface_index = 2
	local _, narrowed = stations_tab.query({ search_surface_idx = 1 })
	assert_eq({ narrowed.unserved, narrowed.setup }, { 1, 1 })
end)

test("chips: a refilled record moves between chip counts with the change log", function()
	local stations_tab, collector, snap = setup()
	local pd = {}
	local _, counts = stations_tab.query(pd)
	assert_eq(counts.setup, 0)
	snap.stations[3].lint = 4
	local manager = storage.manager
	manager.collect_log = manager.collect_log or { epoch = 1, base = 0, ids = {} }
	local log = manager.collect_log
	log.ids[#log.ids + 1] = 3
	local _, after = stations_tab.query(pd)
	assert_eq(after.setup, 1)
	assert_eq(after.failing, 3)
end)
