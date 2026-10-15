-- Characterization tests for the Stations query pipeline (scripts/gui/stations.lua at 3b5fe31): the status ladder,
-- sort order with its name/id tiebreak, the status filter and the incremental update from the collector log.
-- PLAN3: §4.2 moves the status ladder into collector.station_status; these expectations must survive the move.

local H = require("harness")

local function st(id, name, over)
	local r = {
		id = id,
		name = name,
		name_lower = string.lower(name),
		tiebreak = string.format("%s\0%010d", string.lower(name), id),
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
	-- A record from before the tiebreak field existed.
	snap.stations[9].tiebreak = nil
	snap.starved = { ["signal-A:coal"] = true }
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
	assert_eq(counts, { all = 9, no_power = 1, disabled = 1, warming_up = 1, starved = 1, saturated = 1, idle = 1, ok = 3 })
end)

test("query: idle needs an old last delivery, tps > 0 and no active request", function()
	local stations_tab, _, snap = setup()
	mod_settings.tps = 0
	local _, _, ctx = stations_tab.query({})
	assert_eq(ctx.status[7], "ok")
	stations_tab, _, snap = setup()
	-- 30 minutes at tps 60 is exactly IDLE_TICKS, which is not idle yet.
	snap.stations[7].last_delivery_tick = 200000 - 108000
	_, _, ctx = stations_tab.query({})
	assert_eq(ctx.status[7], "ok")
	stations_tab, _, snap = setup()
	snap.stations[7].last_delivery_tick = 200000 - 108001
	_, _, ctx = stations_tab.query({})
	assert_eq(ctx.status[7], "idle")
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
	assert_eq(counts, { all = 2, no_power = 0, disabled = 0, warming_up = 0, starved = 0, saturated = 0, idle = 0, ok = 2 })
	pd = { search_item = "coal" }
	stations_tab = setup()
	rows = stations_tab.query(pd)
	assert_eq(ids(rows), { 3, 4 })
end)

test("query: a replaced record is merged into the kept order once its pass has completed", function()
	local stations_tab, collector, snap = setup()
	local pd = {}
	stations_tab.query(pd)
	assert_eq(pd.stations_query.sort_kind, "full")
	snap.stations[8] = st(8, "Aardvark")
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

test("query: a starved-set change reclassifies only the affected stations", function()
	local stations_tab, _, snap = setup()
	local pd = {}
	stations_tab.query(pd)
	snap.starved = { ["signal-A:stone"] = true }
	snap.starved_version = 2
	local rows, counts, ctx = stations_tab.query(pd)
	assert_eq(ctx.status[4], "ok")
	assert_eq(ctx.status[9], "starved")
	assert_eq(counts.starved, 1)
	assert_eq(counts.ok, 3)
	assert_eq(pd.stations_query.starved_version, 2)
	assert_eq(#rows, 9)
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
