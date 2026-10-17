-- Analytics tabs (PLAN4 D14): the Breakdown range buttons and the Utilization table model.

local H = require("harness")
local analytics = loadfile("cybersyn/scripts/analytics.lua")()
local utilization = require("scripts.gui.utilization")
local stats = require("scripts.stats")

local MIN = 3600

test("breakdown ranges: every button covers exactly the span its caption names", function()
	local keys = {}
	for i, r in ipairs(analytics.BREAKDOWN_RANGES) do
		keys[i] = r.key
		assert_eq(r.ticks, analytics.range_ticks(r.key), r.key)
	end
	assert_eq(keys, { "1m", "10m", "1h", "10h", "50h" })
	assert_eq({ analytics.range_ticks("1m"), analytics.range_ticks("10h"), analytics.range_ticks("5s") }, { 3600, 2160000, nil })
end)

test("breakdown ranges: each range has its caption and tooltip in every manager.cfg", function()
	for _, r in ipairs(analytics.BREAKDOWN_RANGES) do
		for _, key in ipairs({ "breakdown-range-" .. r.key, "breakdown-range-tooltip-" .. r.key }) do
			for _, lang in ipairs({ "en", "de", "es", "fr", "ko", "ru", "sv-SE" }) do
				local text = io.open("cybersyn/locale/" .. lang .. "/manager.cfg"):read("*a")
				assert_true(text:find("\n" .. key .. "=", 1, true) ~= nil, lang .. " " .. key)
			end
		end
	end
end)

local function trains()
	return {
		[1] = { layout_id = 1, status = STATUS_TO_P, dispatch_tick = 9 * MIN },
		[2] = { layout_id = 1, status = STATUS_D },
		[3] = { layout_id = 2, status = STATUS_R, dispatch_tick = 5 * MIN },
		[4] = { layout_id = 1, status = STATUS_F },
		[5] = { status = STATUS_D },
	}
end

test("utilization model: one row per layout with trains, most trains first, busy over the period", function()
	game.tick = 0
	storage.stats = nil
	stats.get()
	-- Layout 1 finished a 2-minute delivery in minutes 2-4.
	game.tick = 4 * MIN
	stats.record_delivery_complete({ layout_id = 1, manifest = {}, dispatch_tick = 2 * MIN })
	game.tick = 10 * MIN
	local rows, span = utilization.model(trains(), { [1] = { 0, 1, 1 }, [2] = { 0, 2 } }, 10)
	-- Ten minute buckets: the current one has just begun, so the period reaches back to 1:00.
	assert_eq(span, 9 * MIN + 1)
	assert_eq(#rows, 2, "rows == distinct layouts among the trains")
	assert_eq({ rows[1].layout_id, rows[1].composition, rows[1].trains, rows[1].busy_now, rows[1].deliveries },
		{ 1, "L<CC>", 3, 1, 1 })
	assert_near(rows[1].busy, (2 * MIN + 1 * MIN) / (3 * span))
	assert_eq(rows[1].trip, 2 * MIN)
	assert_eq({ rows[2].layout_id, rows[2].composition, rows[2].trains, rows[2].busy_now, rows[2].trip },
		{ 2, "L<F>", 1, 1, nil })
	assert_near(rows[2].busy, 5 * MIN / span)
end)

test("utilization model: a layout record that is gone shows its id; busy is capped at 100 %", function()
	game.tick = 0
	storage.stats = nil
	stats.get()
	game.tick = MIN
	local rows = utilization.model({ [1] = { layout_id = 9, status = STATUS_P, dispatch_tick = 0 } }, {}, 10)
	assert_eq(rows[1].composition, "#9")
	assert_true(rows[1].busy <= 1)
	assert_eq(utilization.model({}, {}, 10), {})
end)
