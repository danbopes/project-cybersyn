-- PLAN3 §4.10 (phase 8): the per-item drill-down's pure model (scripts/gui/item-model.lua): the row split between the
-- three tables, the dispatcher-order comparator for requesters and the model builder.

local H = require("harness")

local function model()
	return H.load("scripts.gui.item-model")
end

local PRIORITY = "cybersyn-priority"

test("split_rows: a third each, Requesters the remainder; the three add up to n", function()
	local m = model()
	local many = { providers = 100, requesters = 100, trains = 100 }
	assert_eq(m.split_rows(26, many), { providers = 8, requesters = 10, trains = 8 })
	assert_eq(m.split_rows(27, many), { providers = 9, requesters = 9, trains = 9 })
	assert_eq(m.split_rows(28, many), { providers = 9, requesters = 10, trains = 9 })
	assert_eq(m.split_rows(3, many), { providers = 1, requesters = 1, trains = 1 })
	for n = 3, 80 do
		local a = m.split_rows(n, many)
		assert_eq(a.providers + a.requesters + a.trains, n, "sum at " .. n)
		assert_true(a.requesters >= a.providers and a.requesters >= a.trains, "requesters most at " .. n)
		assert_true(a.providers >= math.floor(n / 3) and a.trains >= math.floor(n / 3), "a third each at " .. n)
	end
end)

test("split_rows: rows a short table cannot fill go to Requesters, then Providers, then Trains", function()
	local m = model()
	-- 2 providers, 40 requesters, 0 trains: providers keep 2, trains 1 (the empty line), requesters the rest.
	assert_eq(m.split_rows(26, { providers = 2, requesters = 40, trains = 0 }), { providers = 2, requesters = 23, trains = 1 })
	-- Requesters full, providers take the next share.
	assert_eq(m.split_rows(26, { providers = 30, requesters = 12, trains = 0 }), { providers = 13, requesters = 12, trains = 1 })
	-- Nobody needs the spare rows: each table keeps its third as blank space, the sum stays n.
	assert_eq(m.split_rows(26, { providers = 1, requesters = 2, trains = 0 }), { providers = 8, requesters = 10, trains = 8 })
	-- Trains last.
	assert_eq(m.split_rows(26, { providers = 1, requesters = 1, trains = 50 }), { providers = 1, requesters = 1, trains = 24 })
	for n = 3, 60 do
		for _, c in ipairs({ { 0, 0, 0 }, { 5, 0, 100 }, { 100, 3, 1 }, { 2, 2, 2 }, { 0, 70, 0 } }) do
			local a = m.split_rows(n, { providers = c[1], requesters = c[2], trains = c[3] })
			assert_eq(a.providers + a.requesters + a.trains, n, "sum")
			assert_true(a.providers >= 1 and a.requesters >= 1 and a.trains >= 1, "an empty-state row each")
			-- A table with more entries than its rows always has at least its third.
			for t, k in pairs({ providers = c[1], requesters = c[2], trains = c[3] }) do
				if k > a[t] then assert_true(a[t] >= math.floor(n / 3), t .. " starved at " .. n) end
			end
		end
	end
end)

test("effective_priority: the station's, or the control combinator's when the item has its own threshold", function()
	local m = model()
	assert_eq(m.effective_priority({ priority = 5, thresholds = {}, control2 = { [PRIORITY] = 9 } }, "iron-plate", PRIORITY), 5)
	assert_eq(m.effective_priority({ priority = 5, thresholds = { ["iron-plate"] = 100 }, control2 = { [PRIORITY] = 9 } },
		"iron-plate", PRIORITY), 9)
	assert_eq(m.effective_priority({ priority = 5, thresholds = { ["iron-plate"] = 100 }, control2 = {} }, "iron-plate", PRIORITY), 5)
	assert_eq(m.effective_priority({ thresholds = {}, control2 = {} }, "iron-plate", PRIORITY), 0)
end)

test("requester_group: in the order the poll and the dispatcher test them", function()
	local m = model()
	local active = { active = true }
	assert_eq(m.requester_group({ status = "ok", deliveries_total = 0, trains_limit = 2, deliveries = {} }, active, "x"), m.QUEUED)
	assert_eq(m.requester_group({ warming_up = true, deliveries_total = 0, trains_limit = 2 }, active, "x"), m.NOT_POLLED)
	assert_eq(m.requester_group({ status = "no_power", deliveries_total = 0, trains_limit = 2 }, active, "x"), m.NOT_POLLED)
	assert_eq(m.requester_group({ status = "ok", deliveries_total = 0, trains_limit = 2 }, { active = false }, "x"),
		m.BELOW_THRESHOLD)
	assert_eq(m.requester_group({ status = "ok", deliveries_total = 2, trains_limit = 2, deliveries = { x = -5 } }, active, "x"),
		m.AT_LIMIT)
	-- Phase 7: a switched-off stop (train limit 0) is its own group, not "at train limit".
	assert_eq(m.requester_group({ status = "disabled", deliveries_total = 0, trains_limit = 0 }, active, "x"), m.DISABLED)
	assert_true(m.AT_LIMIT < m.DISABLED and m.DISABLED < m.PROVIDING, "listed right after the busy stops")
	assert_eq(m.GROUP_KEYS[m.DISABLED], "disabled")
	assert_eq(m.GROUP_KEYS[m.NOT_REQUESTING], "not-requesting")
	assert_eq(m.requester_group({ status = "ok", deliveries_total = 1, trains_limit = 2, deliveries = { x = -5 } }, active, "x"),
		m.PROVIDING)
	assert_eq(m.requester_group({ status = "ok", deliveries_total = 1, trains_limit = 2, deliveries = { x = 5 } }, active, "x"),
		m.QUEUED)
end)

--- tick_dispatch's own selection, restated as a loop: the requester it picks first from a list, then the next once that
--- one is removed (it evaluates and removes requesters in that order within a call).
local function dispatcher_picks(list)
	local left, order = {}, {}
	for i, r in ipairs(list) do left[i] = r end
	while #left > 0 do
		local best_i, best_prior, best_ts = nil, -math.huge, math.huge
		for i, r in ipairs(left) do
			if not (r.priority < best_prior) and not (r.priority == best_prior and r.last_served > best_ts) then
				best_i, best_prior, best_ts = i, r.priority, r.last_served
			end
		end
		order[#order + 1] = left[best_i].id
		table.remove(left, best_i)
	end
	return order
end

test("dispatch_before: priority descending, then the oldest last delivery, as the dispatcher picks", function()
	local m = model()
	local rows = {
		{ id = 1, group = 0, priority = 0, last_served = 500 },
		{ id = 2, group = 0, priority = 10, last_served = 900 },
		{ id = 3, group = 0, priority = 0, last_served = 100 },
		{ id = 4, group = 0, priority = 10, last_served = 200 },
		{ id = 5, group = 0, priority = -3, last_served = 0 },
	}
	local sorted = {}
	for i, r in ipairs(rows) do sorted[i] = r end
	table.sort(sorted, m.dispatch_before)
	local ids = {}
	for i, r in ipairs(sorted) do ids[i] = r.id end
	assert_eq(ids, { 4, 2, 3, 1, 5 })
	-- With distinct keys the comparator and the dispatcher's own loop agree on the whole order.
	assert_eq(ids, dispatcher_picks(rows))
end)

test("dispatch_before: groups after the queue, a full tie by station id", function()
	local m = model()
	local a = { id = 7, group = 0, priority = 0, last_served = 0 }
	local b = { id = 3, group = 0, priority = 0, last_served = 0 }
	local skipped = { id = 1, group = m.AT_LIMIT, priority = 99, last_served = 0 }
	assert_true(m.dispatch_before(b, a))
	assert_false(m.dispatch_before(a, b))
	assert_true(m.dispatch_before(a, skipped), "queued before a skipped request whatever its priority")
	assert_false(m.dispatch_before(a, a))
end)

local function station(t)
	t.provided = t.provided or {}
	t.requested = t.requested or {}
	t.deliveries = t.deliveries or {}
	t.thresholds = t.thresholds or {}
	t.control2 = t.control2 or {}
	t.wait = t.wait or {}
	t.status = t.status or "ok"
	t.trains_limit = t.trains_limit or 5
	t.deliveries_total = t.deliveries_total or 0
	return t
end

test("build: providers by stock, requesters in dispatch order, trains by amount, totals from inventory_all", function()
	local m = model()
	local H_ = "iron-plate"
	local snapshot = {
		tick = 1234,
		stations = {
			[10] = station({ provided = { [H_] = 500 }, deliveries = { [H_] = -200 }, thresholds = { [H_] = 400 } }),
			[11] = station({ provided = { [H_] = 900, ["copper-plate"] = 1 } }),
			[20] = station({ requested = { [H_] = { count = -3000, threshold = 1000, active = true } }, priority = 0,
				last_delivery_tick = 50, wait = { [H_] = 77 }, deliveries = { [H_] = 400 }, network_name = "signal-A" }),
			[21] = station({ requested = { [H_] = { count = -2000, threshold = 1000, active = true } }, priority = 10,
				last_delivery_tick = 900 }),
			[22] = station({ requested = { [H_] = { count = -100, threshold = 1000, active = false } }, priority = 50 }),
			[23] = station({ requested = { [H_] = { count = -2000, threshold = 1000, active = true } }, priority = 0,
				last_delivery_tick = 10, thresholds = { [H_] = 1000 }, control2 = { [PRIORITY] = 20 } }),
			[30] = station({ requested = { ["copper-plate"] = { count = -1, threshold = 1, active = true } } }),
		},
		trains = {
			[1] = { status = 3, manifest_hashes = { [H_] = 2000 }, r_station_id = 20, p_station_id = 11 },
			[2] = { status = 3, manifest_hashes = { [H_] = 4000 }, r_station_id = 21, p_station_id = 10 },
			[3] = { status = 0, manifest_hashes = {} },
		},
		inventory_all = {
			provided = { [H_] = { count = 1400, stations = 2 } },
			requested = { [H_] = { count = -7000, stations = 3 } },
			in_transit = { [H_] = { count = 400, stations = 1 } },
		},
	}
	local r = m.build(snapshot, H_, PRIORITY)
	assert_eq(r.tick, 1234)
	assert_eq(r.totals, { provided = 1400, provided_stations = 2, requested = 7000, requested_stations = 3,
		in_transit = 400, in_transit_stations = 1 })
	assert_eq(#r.providers, 2)
	assert_eq(r.providers[1], { id = 11, stock = 900, out = 0, status = "ok" })
	assert_eq(r.providers[2], { id = 10, stock = 500, threshold = 400, out = 200, status = "ok" })
	local ids = {}
	for i, x in ipairs(r.requesters) do ids[i] = x.id end
	-- 23 has the item's own threshold, so the control combinator's priority 20 counts; 22 is below threshold.
	assert_eq(ids, { 23, 21, 20, 22 })
	assert_eq(r.queued, 3)
	assert_eq(r.requesters[1].priority, 20)
	assert_eq(r.requesters[3], { id = 20, requested = 3000, threshold = 1000, wait_start = 77, incoming = 400, priority = 0,
		last_served = 50, group = m.QUEUED, network = "signal-A", position = 3 })
	assert_eq(r.requesters[4].group, m.BELOW_THRESHOLD)
	assert_eq(r.requesters[4].position, nil)
	assert_eq(#r.trains, 2)
	assert_eq(r.trains[1], { id = 2, status = 3, amount = 4000, to = 21, from = 10 })
	assert_eq(r.trains[2].id, 1)
end)

test("build: the collector's per-item index, and stations whose only link to the item is a delivery", function()
	local m = model()
	local H_ = "iron-plate"
	local function station(f)
		local st = { provided = {}, requested = {}, deliveries = {}, status = "ok", deliveries_total = 0, trains_limit = 5 }
		for k, v in pairs(f) do st[k] = v end
		return st
	end
	local snapshot = {
		tick = 1,
		stations = {
			[10] = station({ provided = { [H_] = 500 } }),
			-- a pickup under way, nothing provided any more
			[11] = station({ deliveries = { [H_] = -300 } }),
			-- a delivery on its way in, no request any more
			[12] = station({ deliveries = { [H_] = 200 } }),
			-- switched off: train limit 0
			[13] = station({ requested = { [H_] = { count = -900, threshold = 100, active = true } }, trains_limit = 0 }),
			-- in the index but not in the records (removed since the pass): skipped
			[99] = nil,
			-- not in the index: never looked at
			[50] = station({ provided = { [H_] = 7 } }),
		},
		trains = {},
		inventory_all = { provided = {}, requested = {}, in_transit = {} },
		item_stations = { [H_] = { 10, 11, 12, 13, 99 } },
	}
	local r = m.build(snapshot, H_, PRIORITY)
	local pids, rids = {}, {}
	for i, x in ipairs(r.providers) do pids[i] = x.id .. ":" .. x.stock .. ":" .. x.out end
	for i, x in ipairs(r.requesters) do rids[i] = x.id .. ":" .. x.group end
	assert_eq(pids, { "10:500:0", "11:0:300" }, "the outgoing delivery joins Providers with stock 0")
	table.sort(rids)
	assert_eq(rids, { "12:" .. m.NOT_REQUESTING, "13:" .. m.DISABLED }, "the incoming one joins Requesters")
	-- Without the index every record is looked at.
	snapshot.item_stations = nil
	r = m.build(snapshot, H_, PRIORITY)
	assert_eq(#r.providers, 3)
end)

test("build: an item nobody handles gives empty tables and zero totals", function()
	local m = model()
	local r = m.build({ stations = {}, trains = {}, inventory_all = { provided = {}, requested = {}, in_transit = {} } },
		"steel-plate", PRIORITY)
	assert_eq(#r.providers + #r.requesters + #r.trains, 0)
	assert_eq(r.totals.provided + r.totals.requested + r.totals.in_transit, 0)
	assert_eq(r.queued, 0)
end)

test("train_chip: every Cybersyn status maps to a Trains chip", function()
	local m = model()
	local S = { D = 0, TO_P = 1, P = 2, TO_R = 3, R = 4, TO_D = 5, TO_D_BYPASS = 6, TO_F = 7, F = 8 }
	assert_eq(m.train_chip(0, S), "parked")
	assert_eq(m.train_chip(1, S), "to_p")
	assert_eq(m.train_chip(2, S), "loading")
	assert_eq(m.train_chip(3, S), "to_r")
	assert_eq(m.train_chip(4, S), "unloading")
	assert_eq(m.train_chip(5, S), "returning")
	assert_eq(m.train_chip(6, S), "returning")
	assert_eq(m.train_chip(7, S), "refuel")
	assert_eq(m.train_chip(8, S), "refuel")
	assert_eq(m.train_chip(300, S), nil)
end)

test("locale: every key the drill-down uses, in every manager.cfg", function()
	local function read(path)
		local f = assert(io.open(H.mod_root .. "/" .. path, "r"))
		local text = f:read("*a")
		f:close()
		return text
	end
	local src = read("scripts/gui/item.lua")
	local keys = {}
	for k in src:gmatch('"cybersyn%-gui%.(item%-[%w%-]+)"') do keys[k] = true end
	-- Keys built from parts.
	for _, t in ipairs({ "providers", "requesters", "trains" }) do
		keys["item-" .. t] = true
		keys["item-empty-" .. t] = true
	end
	for _, c in ipairs({ "station", "stock", "threshold", "out", "status", "priority", "requested", "wait", "why",
		"incoming", "train", "train-status", "amount", "to" }) do
		keys["item-col-" .. c] = true
	end
	for _, g in ipairs({ "at-limit", "providing", "below-threshold", "not-polled" }) do
		keys["item-group-" .. g] = true
		keys["item-group-" .. g .. "-tooltip"] = true
	end
	for _, p in ipairs({ 10, 60, 1440 }) do keys["item-period-" .. p] = true end
	for _, k in ipairs({ "item-provided", "item-in-transit", "item-requested", "item-click-hint" }) do keys[k] = true end
	keys["item-"] = nil
	keys["item-col-"] = nil
	keys["item-empty-"] = nil
	keys["item-group-"] = nil
	keys["item-period-"] = nil
	local n = 0
	for _ in pairs(keys) do n = n + 1 end
	assert_true(n > 40, "found the keys")
	for _, loc in ipairs({ "en", "de", "es", "fr", "ko", "ru", "sv-SE" }) do
		local text = read("locale/" .. loc .. "/manager.cfg")
		for k in pairs(keys) do
			assert_true(text:find("\n" .. k .. "=", 1, true) ~= nil, loc .. " lacks " .. k)
		end
		assert_true(text:find("\nitem%-requesters=[^\n]*approximate") ~= nil, loc .. ": the Requesters caption says approximate")
	end
end)
