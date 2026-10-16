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
	assert_eq(#vx - 1, l.TRACE_SEGMENTS, "the whole budget is used")
	assert_eq({ vx[1], vy[1] }, { 0, 0 })
	assert_eq({ vx[#vx], vy[#vy] }, { 999, 1 })
	local vx2, vy2 = l.sample_runs(xs, ys, n, 10)
	assert_eq(#vx2 - 1, 10)
	assert_eq({ vx2[11], vy2[11] }, { 999, 1 })
	local seen = {}
	for i = 2, #vx2 do
		assert_true(vx2[i] > vx2[i - 1], "vertices stay in path order")
		seen[#seen + 1] = vx2[i] - vx2[i - 1]
	end
	for _, gap in ipairs(seen) do assert_true(gap >= 99 and gap <= 101, "evenly spread, gap " .. gap) end
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

test("confirm: an armed button is drawn back after 180 ticks", function()
	local l = logic()
	local s = l.confirm_click(nil, "fail:1", 100)
	assert_false(l.confirm_expired(s, 279))
	assert_true(l.confirm_expired(s, 280))
	assert_false(l.confirm_armed(s, "fail:1", 280))
	assert_false(l.confirm_expired(nil, 1000))
end)

test("confirm: a click applied within the grace after the expiry still fires (multiplayer input latency)", function()
	local l = logic()
	local s = l.confirm_click(nil, "fail:1", 100)
	assert_true(l.confirm_expired(s, 280))
	assert_false(l.confirm_gone(s, 309))
	assert_true(l.confirm_gone(s, 310))
	local s3, fire3 = l.confirm_click(s, "fail:1", 285)
	assert_true(fire3)
	assert_nil(s3)
	local _, fire4 = l.confirm_click(s, "rescan:2", 285)
	assert_false(fire4, "another key arms that one")
	local s5, fire5 = l.confirm_click(s, "fail:1", 310)
	assert_false(fire5, "past the grace the click arms again")
	assert_eq(s5.tick, 310)
end)

test("job_continue: 50 trains per chunk, never one loop over everything", function()
	local l = logic()
	local i, chunks = 0, 0
	while i < 553 do
		local n = 0
		while i < 553 and l.job_continue(n, 0, 0) do
			i, n = i + 1, n + 1
		end
		assert_true(n <= 50)
		chunks = chunks + 1
	end
	assert_eq(chunks, 12)
end)

test("job_continue: the stop-visit budget splits singleton layouts, the first train always runs", function()
	local l = logic()
	local stops = 2030
	local single = l.job_cost(true, stops)
	assert_eq(single, 4060)
	assert_eq(l.job_cost(false, stops), 0)
	assert_true(l.job_continue(0, 0, 1e9))
	assert_true(l.job_continue(1, single, 0))
	assert_false(l.job_continue(1, single, single))
	assert_true(l.job_continue(1, 0, single, nil, l.JOB_STOP_VISITS))
	assert_false(l.job_continue(50, 0, 0))
	assert_false(l.job_continue(2, 0, 0, 2))
	assert_false(l.job_continue(1, 0, 2, 50, 1))
	-- 553 trains, every 10th alone on its layout, on pY's stop count: each such train gets its own chunk.
	local i, chunks, worst = 0, 0, 0
	while i < 553 do
		local n, spent = 0, 0
		while i < 553 do
			local cost = l.job_cost((i + 1) % 10 == 0, stops)
			if not l.job_continue(n, spent, cost) then break end
			i, n, spent = i + 1, n + 1, spent + cost
		end
		if spent > worst then worst = spent end
		chunks = chunks + 1
	end
	assert_eq(worst, single)
	assert_true(chunks >= 55)
end)

test("hud_values: totals, worst network, top reason with ties by lowest code", function()
	local l = logic()
	local v = l.hud_values({ [3] = 4, [1] = 4, [7] = 2 }, { ["signal-A"] = 3, ["signal-B"] = 0 })
	assert_eq(v, { unserved = 10, headroom = 0, network = "signal-B", top_reason = 1, top_count = 4 })
	v = l.hud_values({}, {})
	assert_eq(v, { unserved = 0, top_count = 0 })
	v = l.hud_values({}, { ["signal-B"] = 3 }, { ["signal-A"] = true, ["signal-B"] = true })
	assert_eq({ v.headroom, v.network }, { 0, "signal-A" }, "a network with trains but no counter is at 0")
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
