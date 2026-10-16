-- PLAN3 §11 / §4.14 (phase 10): the pure rules of the extras (scripts/gui/extras-logic.lua).

local H = require("harness")

local function logic()
	return H.load("scripts.gui.extras-logic")
end

local function points(list)
	local xs, ys = {}, {}
	for i, p in ipairs(list) do xs[i], ys[i] = p[1], p[2] end
	return xs, ys, #list
end

test("sample_runs: a straight run becomes one segment", function()
	local l = logic()
	local list = {}
	for i = 0, 50 do list[#list + 1] = { i * 2, 10 } end
	local vx, vy, runs = l.sample_runs(points(list))
	assert_eq(vx, { 0, 100 })
	assert_eq(vy, { 10, 10 })
	assert_eq(runs, 1)
end)

test("sample_runs: an L turn keeps its corner, duplicates are dropped", function()
	local l = logic()
	local vx, vy, runs = l.sample_runs(points({ { 0, 0 }, { 2, 0 }, { 2, 0 }, { 4, 0 }, { 4, 2 }, { 4, 4 } }))
	assert_eq(vx, { 0, 4, 4 })
	assert_eq(vy, { 0, 0, 4 })
	assert_eq(runs, 2)
end)

test("sample_runs: a reversal is not collinear", function()
	local l = logic()
	local vx = l.sample_runs(points({ { 0, 0 }, { 4, 0 }, { 2, 0 } }))
	assert_eq(vx, { 0, 4, 2 })
end)

test("sample_runs: a zig-zag longer than the cap is thinned to at most the cap, ends kept", function()
	local l = logic()
	local list = {}
	for i = 0, 999 do list[#list + 1] = { i, i % 2 } end
	local xs, ys, n = points(list)
	local vx, vy, runs = l.sample_runs(xs, ys, n)
	assert_eq(runs, 999)
	assert_true(#vx - 1 <= l.TRACE_SEGMENTS, "segments " .. (#vx - 1))
	assert_eq({ vx[1], vy[1] }, { 0, 0 })
	assert_eq({ vx[#vx], vy[#vy] }, { 999, 1 })
	local vx2 = l.sample_runs(xs, ys, n, 10)
	assert_true(#vx2 - 1 <= 10, "segments " .. (#vx2 - 1))
end)

test("sample_runs: fewer than two distinct points draw nothing", function()
	local l = logic()
	local vx, _, runs = l.sample_runs(points({ { 1, 1 }, { 1, 1 } }))
	assert_eq(#vx, 1)
	assert_eq(runs, 0)
	vx = l.sample_runs({}, {}, 0)
	assert_eq(#vx, 0)
end)

test("sample_runs: the 2x cap per player stays within 256 objects", function()
	local l = logic()
	assert_true(l.TRACE_SEGMENTS * 2 <= 256, "two render modes")
end)

test("confirm: first click arms, second fires, another key re-arms", function()
	local l = logic()
	local s, fire = l.confirm_click(nil, "fail:1", 100)
	assert_false(fire)
	assert_eq(s, { key = "fail:1", tick = 100 })
	assert_true(l.confirm_armed(s, "fail:1", 150))
	assert_false(l.confirm_armed(s, "rescan:2", 150))
	local s2, fire2 = l.confirm_click(s, "rescan:2", 150)
	assert_false(fire2)
	assert_eq(s2.key, "rescan:2")
	local s3, fire3 = l.confirm_click(s2, "rescan:2", 200)
	assert_true(fire3)
	assert_eq(s3, nil)
end)

test("confirm: an armed button expires after 180 ticks and the next click arms again", function()
	local l = logic()
	local s = l.confirm_click(nil, "fail:1", 100)
	assert_false(l.confirm_expired(s, 279))
	assert_true(l.confirm_expired(s, 280))
	assert_false(l.confirm_armed(s, "fail:1", 280))
	local s2, fire = l.confirm_click(s, "fail:1", 280)
	assert_false(fire)
	assert_eq(s2.tick, 280)
	assert_false(l.confirm_expired(nil, 1000))
end)

test("job_range: 50 per chunk, never one loop over everything", function()
	local l = logic()
	assert_eq({ l.job_range(0, 553) }, { 1, 50, false })
	assert_eq({ l.job_range(500, 553) }, { 501, 550, false })
	assert_eq({ l.job_range(550, 553) }, { 551, 553, true })
	assert_eq({ l.job_range(0, 0) }, { 1, 0, true })
	local i, chunks = 0, 0
	while true do
		local _, last, done = l.job_range(i, 553)
		i = last
		chunks = chunks + 1
		if done then break end
	end
	assert_eq(chunks, 12)
end)

test("hud_values: totals, worst network, top reason with ties by lowest code", function()
	local l = logic()
	local v = l.hud_values({ [3] = 4, [1] = 4, [7] = 2 }, { ["signal-A"] = 3, ["signal-B"] = 0 })
	assert_eq(v, { unserved = 10, headroom = 0, network = "signal-B", top_reason = 1, top_count = 4 })
	v = l.hud_values({}, {})
	assert_eq(v, { unserved = 0, top_count = 0 })
end)

test("pick_train: named first, then fits + available + largest, ties by id", function()
	local l = logic()
	local c = {
		{ id = 5, available = true, fits = false, capacity = 100 },
		{ id = 3, available = false, fits = true, capacity = 50 },
		{ id = 9, available = true, fits = true, capacity = 40 },
		{ id = 2, available = true, fits = true, capacity = 40 },
	}
	assert_eq(l.pick_train(c), 2)
	assert_eq(l.pick_train(c, 5), 5)
	assert_eq(l.pick_train(c, 77), 2)
	assert_eq(l.pick_train({ { id = 4, available = false, fits = false, capacity = 1 } }), 4)
	assert_eq(l.pick_train({}), nil)
end)
