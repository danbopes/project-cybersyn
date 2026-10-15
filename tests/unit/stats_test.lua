-- Characterization tests for scripts/stats.lua at 3b5fe31.

local H = require("harness")
local stats = require("scripts.stats")

local MIN, HOUR = 3600, 216000

local function at(tick)
	game.tick = tick
end

local function deliver(tick, manifest, dispatch_tick)
	at(tick)
	local train = { manifest = manifest, dispatch_tick = dispatch_tick }
	stats.record_delivery_complete(train)
	return train
end

test("constants", function()
	assert_eq(stats.MINUTE, 3600)
	assert_eq(stats.HOUR, 216000)
end)

test("get: creates the table with since_tick = game.tick", function()
	at(500)
	local s = stats.get()
	assert_eq(s, { minute = {}, hour = {}, totals = { deliveries = 0, dispatches = 0, items = 0, since_tick = 500 }, cycle = {} })
	assert_same(storage.stats, s)
	assert_same(stats.get(), s)
end)

test("get: repairs a partial table and drops the old sample ring", function()
	at(900)
	storage.stats = { cycle = { samples = { 1, 2 }, next = 3, ema_seconds = 4 } }
	local s = stats.get()
	assert_eq(s.minute, {})
	assert_eq(s.hour, {})
	assert_eq(s.totals, { deliveries = 0, dispatches = 0, items = 0, since_tick = 900 })
	assert_eq(s.cycle, { ema_seconds = 4 })
	storage.stats = { minute = { x = 1 }, totals = { deliveries = 7 } }
	s = stats.get()
	assert_eq(s.minute, { x = 1 })
	assert_eq(s.totals, { deliveries = 7 })
	assert_eq(s.cycle, {})
end)

test("record_dispatch: bucket index and start from the tick", function()
	local train = {}
	at(61 * MIN + 5)
	stats.record_dispatch(train)
	assert_eq(train.dispatch_tick, 61 * MIN + 5)
	local s = stats.get()
	assert_eq(H.keys(s.minute), { 2 })
	assert_eq(s.minute[2], { start_tick = 61 * MIN, deliveries = 0, dispatches = 1, items = {} })
	assert_eq(H.keys(s.hour), { 2 })
	assert_eq(s.hour[2], { start_tick = HOUR, deliveries = 0, dispatches = 1, items = {} })
	stats.record_dispatch({})
	assert_eq(s.minute[2].dispatches, 2)
	assert_eq(s.totals.dispatches, 2)
end)

test("bucket ring: a slot from a previous lap is replaced, not added to", function()
	at(10)
	stats.record_dispatch({})
	at(60 * MIN + 10)
	stats.record_dispatch({})
	local s = stats.get()
	assert_eq(s.minute[1], { start_tick = 60 * MIN, deliveries = 0, dispatches = 1, items = {} })
	assert_eq(s.hour[1].dispatches, 1)
	assert_eq(s.hour[2].dispatches, 1)
	at(24 * HOUR)
	stats.record_dispatch({})
	assert_eq(s.hour[1], { start_tick = 24 * HOUR, deliveries = 0, dispatches = 1, items = {} })
	assert_eq(s.totals.dispatches, 3)
end)

test("record_fulfilment: sums, count, first maximum wins ties", function()
	at(2 * MIN + 100)
	stats.record_fulfilment(300, 4, "iron-plate")
	stats.record_fulfilment(500, 5, "copper-plate")
	at(2 * MIN + 200)
	stats.record_fulfilment(500, 6, "coal")
	local s = stats.get()
	local expected = {
		start_tick = 2 * MIN, deliveries = 0, dispatches = 0, items = {},
		wait_sum = 1300, wait_n = 3, wait_max = 500, wait_max_station = 5, wait_max_hash = "copper-plate",
		wait_max_tick = 2 * MIN + 100,
	}
	assert_eq(s.minute[3], expected)
	expected.start_tick = 0
	assert_eq(s.hour[1], expected)
	assert_eq(s.totals.dispatches, 0)
end)

test("record_delivery_complete: items by hash, cycle sum and EMA", function()
	at(0)
	stats.get()
	local t = deliver(1800, {
		{ name = "iron-plate", count = 100 },
		{ name = "iron-plate", quality = "rare", count = 10 },
		{ name = "iron-plate", quality = "normal", count = 1 },
		{ name = "water" },
	}, 600)
	assert_nil(t.dispatch_tick)
	local s = stats.get()
	assert_eq(s.minute[1], {
		start_tick = 0, deliveries = 1, dispatches = 0,
		items = { ["iron-plate"] = 101, ["iron-plate|rare"] = 10, water = 0 },
		cycle_sum = 20, cycle_n = 1,
	})
	assert_eq(s.hour[1].items, { ["iron-plate"] = 101, ["iron-plate|rare"] = 10, water = 0 })
	assert_eq(s.totals, { deliveries = 1, dispatches = 0, items = 111, since_tick = 0 })
	assert_eq(s.cycle.ema_seconds, 20)
	deliver(2400, { { name = "coal", count = 5 } }, 0)
	assert_eq(s.minute[1].cycle_sum, 60)
	assert_eq(s.minute[1].cycle_n, 2)
	assert_near(s.cycle.ema_seconds, 22)
end)

test("record_delivery_complete: untimed deliveries count but leave the cycle alone", function()
	at(0)
	stats.get()
	local t = deliver(1000, nil, nil)
	deliver(1000, {}, 1001)
	local s = stats.get()
	assert_eq(s.minute[1], { start_tick = 0, deliveries = 2, dispatches = 0, items = {} })
	assert_eq(s.totals.deliveries, 2)
	assert_nil(s.cycle.ema_seconds)
	assert_nil(t.dispatch_tick)
	-- A delivery completed on its dispatch tick is timed at 0 s.
	deliver(1000, nil, 1000)
	assert_eq(s.minute[1].cycle_n, 1)
	assert_eq(s.minute[1].cycle_sum, 0)
end)

local function window_scenario()
	at(0)
	stats.get()
	deliver(100, { { name = "coal", count = 1 } })
	deliver(5 * MIN + 100, { { name = "coal", count = 2 } }, 5 * MIN)
	deliver(9 * MIN + 100, { { name = "stone", count = 4 } }, 9 * MIN - 1100)
	at(10 * MIN + 100)
	stats.record_dispatch({})
	deliver(10 * MIN + 100, { { name = "coal", count = 8 } })
	at(10 * MIN + 200)
end

test("window: counts the current partial minute and the minutes before it", function()
	window_scenario()
	assert_eq({ stats.window(1) }, { 1, 1 })
	assert_eq({ stats.window(2) }, { 2, 1 })
	assert_eq({ stats.window(10) }, { 3, 1 })
	assert_eq({ stats.window(11) }, { 4, 1 })
	local d, p, items = stats.window(10, true)
	assert_eq({ d, p }, { 3, 1 })
	assert_eq(items, { coal = 10, stone = 4 })
	assert_eq(select(3, stats.window(60, true)), { coal = 11, stone = 4 })
end)

test("cycle_average: mean over timed deliveries in the window", function()
	window_scenario()
	assert_eq({ stats.cycle_average(1) }, { nil, 0 })
	-- Minute 9: (9*MIN+100 - (9*MIN-1100)) / 60 = 20 s; minute 5: 100/60 s.
	assert_eq({ stats.cycle_average(2) }, { 20, 1 })
	local avg, n = stats.cycle_average(10)
	assert_eq(n, 2)
	assert_near(avg, (20 + 100 / 60) / 2)
	at(0)
	storage.stats = nil
	assert_eq({ stats.cycle_average(60) }, { nil, 0 })
end)

test("day_deliveries: 24 hourly buckets incl. the current one", function()
	at(0)
	stats.get()
	deliver(10, nil)
	deliver(HOUR + 10, nil)
	deliver(23 * HOUR + 10, nil)
	at(23 * HOUR + 20)
	assert_eq(stats.day_deliveries(), 3)
	deliver(24 * HOUR + 10, nil)
	at(24 * HOUR + 20)
	-- Hour 0 fell out of the window (and its slot was reused by hour 24).
	assert_eq(stats.day_deliveries(), 3)
	at(25 * HOUR)
	assert_eq(stats.day_deliveries(), 2)
end)

local function wait_scenario()
	at(0)
	stats.get()
	at(2 * MIN + 100)
	stats.record_fulfilment(600, 1, "iron-plate")
	at(3 * MIN + 100)
	stats.record_fulfilment(1200, 2, "copper-plate")
	stats.record_fulfilment(300, 3, "water")
	deliver(3 * MIN + 200, { { name = "coal", count = 7 }, { name = "stone", count = 3 } }, 3 * MIN - 400)
	at(3 * MIN + 300)
	stats.record_dispatch({})
end

local function slowest_starts(out)
	local starts = {}
	for i, b in ipairs(out.slowest) do starts[i] = b.start_tick end
	table.sort(starts)
	return starts
end

test("aggregate(10): minute ring sums, waits, cycle, partial span", function()
	wait_scenario()
	at(3 * MIN + 400)
	local out = stats.aggregate(10)
	assert_eq(out.minutes, 10)
	-- Recording started at tick 0, inside the 10-minute period.
	assert_true(out.partial)
	assert_eq(out.span_ticks, 3 * MIN + 401)
	assert_eq(out.deliveries, 1)
	assert_eq(out.dispatches, 1)
	assert_eq(out.items, { coal = 7, stone = 3 })
	assert_eq(out.amount, 10)
	assert_eq(out.cycle_n, 1)
	assert_eq(out.cycle_avg, 10)
	assert_eq(out.wait_n, 3)
	assert_eq(out.wait_avg, 700)
	assert_eq(out.wait_max, 1200)
	assert_eq(slowest_starts(out), { 2 * MIN, 3 * MIN })
	assert_eq(out.slowest_minutes, {})
	local max_bucket
	for _, b in ipairs(out.slowest) do
		if b.wait_max == out.wait_max then max_bucket = b end
	end
	assert_eq(max_bucket.wait_max_station, 2)
	assert_eq(max_bucket.wait_max_hash, "copper-plate")
	assert_eq(max_bucket.wait_max_tick, 3 * MIN + 100)
	-- The list holds the live buckets, not copies.
	assert_same(max_bucket, stats.get().minute[4])
end)

test("aggregate(10): full span once recording predates the period", function()
	wait_scenario()
	at(15 * MIN + 10)
	local out = stats.aggregate(10)
	assert_false(out.partial)
	assert_eq(out.span_ticks, 15 * MIN + 10 - 6 * MIN + 1)
	assert_eq(out.deliveries, 0)
	assert_eq(out.items, {})
	assert_eq(out.wait_n, 0)
	assert_nil(out.wait_avg)
	assert_nil(out.wait_max)
	assert_nil(out.cycle_avg)
	assert_eq(out.slowest, {})
end)

test("aggregate(1440): hour sums; the current hour lists its minute buckets instead", function()
	wait_scenario()
	at(3 * MIN + 400)
	local out = stats.aggregate(1440)
	assert_eq(out.minutes, 1440)
	assert_true(out.partial)
	assert_eq(out.span_ticks, 3 * MIN + 401)
	assert_eq(out.deliveries, 1)
	assert_eq(out.wait_n, 3)
	assert_eq(out.wait_avg, 700)
	assert_eq(out.wait_max, 1200)
	assert_eq(slowest_starts(out), { 2 * MIN, 3 * MIN })
	local s = stats.get()
	assert_eq(table_size(out.slowest_minutes), 2)
	assert_true(out.slowest_minutes[s.minute[3]])
	assert_true(out.slowest_minutes[s.minute[4]])
end)

test("aggregate(1440): closed hours stay as hour buckets", function()
	at(0)
	stats.get()
	at(100)
	stats.record_fulfilment(50, 1, "coal")
	at(HOUR + 100)
	stats.record_fulfilment(70, 2, "stone")
	at(HOUR + 200)
	local out = stats.aggregate(1440)
	local s = stats.get()
	assert_eq(out.wait_n, 2)
	assert_eq(out.wait_max, 70)
	assert_eq(#out.slowest, 2)
	local hour_bucket, minute_bucket
	for _, b in ipairs(out.slowest) do
		if out.slowest_minutes[b] then minute_bucket = b else hour_bucket = b end
	end
	assert_same(hour_bucket, s.hour[1])
	assert_same(minute_bucket, s.minute[1])
	assert_eq(minute_bucket.start_tick, HOUR)
end)

test("aggregate: periods over an hour round up to whole hours, capped at 24", function()
	at(0)
	stats.get()
	deliver(10, nil)
	deliver(HOUR + 10, nil)
	deliver(2 * HOUR + 10, nil)
	at(2 * HOUR + 20)
	assert_eq(stats.aggregate(90).deliveries, 2)
	assert_eq(stats.aggregate(61).deliveries, 2)
	assert_eq(stats.aggregate(60).deliveries, 1)
	assert_eq(stats.aggregate(5000).deliveries, 3)
	assert_eq(stats.aggregate(90).span_ticks, 2 * HOUR + 20 - HOUR + 1)
end)

test("aggregate: since_tick missing counts as 0", function()
	at(100)
	storage.stats = { minute = {}, hour = {}, totals = { deliveries = 0, dispatches = 0, items = 0 }, cycle = {} }
	local out = stats.aggregate(10)
	assert_true(out.partial)
	assert_eq(out.span_ticks, 101)
	at(20 * MIN)
	out = stats.aggregate(10)
	assert_false(out.partial)
	assert_eq(out.span_ticks, 9 * MIN + 1)
end)

test("init: purges hashes whose item, fluid or quality is gone", function()
	storage.stats = {
		minute = {
			[1] = {
				start_tick = 0, deliveries = 1, dispatches = 0,
				items = { ["iron-plate"] = 5, ["gone-item"] = 3, ["iron-plate|gone-q"] = 2, water = 1, ["signal-A"] = 4, ["coal|rare"] = 6 },
				wait_max_hash = "gone-item",
			},
		},
		hour = { [1] = { start_tick = 0, deliveries = 1, dispatches = 0, items = {}, wait_max_hash = "iron-plate|rare" } },
		totals = { deliveries = 1, dispatches = 0, items = 0, since_tick = 0 },
		cycle = {},
	}
	stats.init()
	local s = stats.get()
	-- Virtual signals are not item or fluid hashes, so they are purged too.
	assert_eq(s.minute[1].items, { ["iron-plate"] = 5, water = 1, ["coal|rare"] = 6 })
	assert_nil(s.minute[1].wait_max_hash)
	assert_eq(s.hour[1].wait_max_hash, "iron-plate|rare")
end)

test("init: creates the table on a new game", function()
	at(42)
	stats.init()
	assert_eq(storage.stats.totals.since_tick, 42)
end)

test("summary: plain data for the dev interface", function()
	wait_scenario()
	at(3 * MIN + 400)
	local sum = stats.summary()
	assert_eq(sum.tick, 3 * MIN + 400)
	assert_same(sum.totals, stats.get().totals)
	assert_eq(sum.deliveries_10m, 1)
	assert_eq(sum.dispatches_10m, 1)
	assert_eq(sum.deliveries_60m, 1)
	assert_eq(sum.dispatches_60m, 1)
	assert_eq(sum.deliveries_24h, 1)
	assert_eq(sum.cycle_avg_60m, 10)
	assert_eq(sum.cycle_samples_60m, 1)
	assert_eq(sum.cycle_ema, 10)
	-- coal and stone in one minute bucket and one hour bucket.
	assert_eq(sum.item_entries, 4)
	assert_eq(sum.waits_60m, { n = 3, avg = 700, max = 1200, buckets = 2 })
	assert_eq(sum.waits_24h, { n = 3, avg = 700, max = 1200, buckets = 2 })
end)

test("aggregate: no min_available_by_network or no_train_failures yet", function()
	at(0)
	local out = stats.aggregate(60)
	-- PLAN3: §4.4 adds min_available_by_network and no_train_failures to the aggregate.
	assert_nil(out.min_available_by_network)
	assert_nil(out.no_train_failures)
end)

test("aggregate: longer periods cover only the last 24 hours, stale ring slots excluded", function()
	at(0)
	stats.get()
	deliver(10, nil)
	deliver(2 * HOUR + 10, nil)
	deliver(3 * HOUR + 10, nil)
	-- Hour 25 reuses hour 1's slot; hour 0's slot is still in the ring but outside the last 24 hours.
	deliver(25 * HOUR + 10, nil)
	at(25 * HOUR + 20)
	local out = stats.aggregate(5000)
	assert_eq(out.deliveries, 3)
	assert_false(out.partial)
	assert_eq(out.span_ticks, 25 * HOUR + 20 - 2 * HOUR + 1)
	assert_eq(stats.get().hour[1].start_tick, 0)
end)

test("aggregate: recording that started exactly at the oldest bucket is not partial", function()
	at(0)
	stats.get()
	at(9 * MIN + 5)
	local out = stats.aggregate(10)
	assert_false(out.partial)
	assert_eq(out.span_ticks, 9 * MIN + 6)
	storage.stats.totals.since_tick = 1
	assert_true(stats.aggregate(10).partial)
end)

test("cycle_average: ignores a minute slot that starts after the current tick", function()
	at(0)
	stats.get()
	at(3 * MIN + 10)
	stats.get().minute[6] = { start_tick = 5 * MIN, deliveries = 1, dispatches = 0, items = {}, cycle_sum = 100, cycle_n = 1 }
	assert_eq({ stats.cycle_average(10) }, { nil, 0 })
end)
