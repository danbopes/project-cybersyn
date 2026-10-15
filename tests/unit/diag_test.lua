-- scripts/diag.lua (PLAN3 §4.5, §4.13): the unserved state table, the flap rule, the two rings, export and
-- acknowledgements, against a fake tick.

local H = require("harness")
local diag = H.load("scripts.diag")
local stats = require("scripts.stats")

local function at(tick)
	game.tick = tick
end

--- A fresh storage.diag in `mode` with a full ring of `ring` rows.
local function setup(mode, ring)
	settings.global["cybersyn-diagnostics"] = { value = mode or "basic" }
	settings.global["cybersyn-diagnostics-ring"] = { value = ring or 16384 }
	storage.trains = storage.trains or {}
	storage.stations = storage.stations or {}
	return diag.apply()
end

local function kinds(rows)
	local out = {}
	for i, ev in ipairs(rows) do out[i] = DIAG_KIND_NAMES[ev.kind] end
	return out
end

--- Walk of the live entries by confirmed reason, to check the incremental counts against.
local function tally(d)
	local out = {}
	for _, by_item in pairs(d.unserved) do
		for _, e in pairs(by_item) do out[e.reason] = (out[e.reason] or 0) + 1 end
	end
	return out
end

test("apply: off is nil, basic and full create the state, the full ring follows its setting", function()
	at(100)
	assert_nil(setup("off"))
	assert_nil(storage.diag)
	local d = setup("basic", 2048)
	assert_same(storage.diag, d)
	assert_eq(d.mode, "basic")
	assert_false(d.full)
	assert_eq(d.ring_basic.size, diag.BASIC_RING)
	assert_eq(d.ring_full.size, 2048)
	assert_eq(d.loaded_tick, 100)
	local same = setup("full", 4096)
	assert_same(same, d)
	assert_true(d.full)
	assert_eq(d.ring_full.size, 4096)
	assert_eq(d.ring_basic.size, 4096)
	setup("off")
	assert_nil(storage.diag)
end)

test("apply: a new state clears delivery ids an earlier full log left on trains", function()
	storage.trains = { [5] = { delivery_id = 9 } }
	setup("basic")
	assert_nil(storage.trains[5].delivery_id)
end)

test("interning: one index per hash, both directions", function()
	local d = setup()
	assert_eq(diag.intern(d, "iron-plate"), 1)
	assert_eq(diag.intern(d, "copper-plate|rare"), 2)
	assert_eq(diag.intern(d, "iron-plate"), 1)
	assert_eq(d.item_hash, { "iron-plate", "copper-plate|rare" })
	assert_eq(diag.item_hash(2), "copper-plate|rare")
end)

test("fail: the first entry takes effect at once with its payload and event", function()
	at(1000)
	local d = setup()
	local rej = { 0, 0, 0, 0, 3, 0, 0, 0 }
	diag.fail(d, 7, "iron-plate", REASON_P_BELOW_THRESHOLD, 500, 2000, 11, rej, nil)
	local e = d.unserved[7][1]
	assert_eq(e.reason, REASON_P_BELOW_THRESHOLD)
	assert_nil(e.pending)
	assert_eq({ e.a, e.b, e.p_station_id, e.p_count, e.p_threshold }, { 500, 2000, 11, 500, 2000 })
	assert_eq(e.rej, rej)
	assert_true(e.rej ~= rej)
	assert_eq({ e.first_tick, e.last_tick, e.n, e.lost_n }, { 1000, 1000, 1, 0 })
	assert_eq(d.unserved_count[7], 1)
	assert_eq(d.unserved_n, 1)
	assert_eq(d.counts, { [REASON_P_BELOW_THRESHOLD] = 1 })
	local ev = diag.events(nil, 0, 10)
	assert_eq(#ev, 1)
	assert_eq(ev[1].kind, DIAG_KIND_UNSERVED_REASON)
	assert_eq({ ev[1].code, ev[1].station, ev[1].station2, ev[1].item, ev[1].a, ev[1].b },
		{ REASON_P_BELOW_THRESHOLD, 7, 11, 1, 500, 2000 })
	assert_eq(ev[1].sev, DIAG_SEV_WARNING)
end)

test("flap rule: a new reason waits for two evaluations and 30 s; the old one clears it", function()
	at(0)
	local d = setup()
	diag.fail(d, 1, "coal", REASON_NO_PROVIDER, 0, 0)
	at(60)
	diag.fail(d, 1, "coal", REASON_CAPACITY, 50, 40)
	local e = d.unserved[1][1]
	assert_eq({ e.reason, e.pending, e.pending_since, e.pending_n }, { REASON_NO_PROVIDER, REASON_CAPACITY, 60, 1 })
	-- The pending reason's numbers stay out of the entry until it is confirmed.
	assert_eq({ e.a, e.b }, { 0, 0 })
	at(1000)
	diag.fail(d, 1, "coal", REASON_CAPACITY, 50, 40)
	assert_eq(e.reason, REASON_NO_PROVIDER, "two evaluations but under 30 s")
	at(1859)
	diag.fail(d, 1, "coal", REASON_CAPACITY, 50, 40)
	assert_eq(e.reason, REASON_NO_PROVIDER, "1799 ticks")
	at(1860)
	diag.fail(d, 1, "coal", REASON_CAPACITY, 50, 40)
	assert_eq({ e.reason, e.pending, e.a, e.b }, { REASON_CAPACITY, nil, 50, 40 })
	assert_eq(d.counts, { [REASON_CAPACITY] = 1 })
	assert_eq(kinds(diag.events(nil, 0, 10)), { "unserved_reason", "unserved_reason" })
	-- Back to the confirmed reason before the window: pending is dropped and nothing is logged.
	at(2000)
	diag.fail(d, 1, "coal", REASON_MASK_MISMATCH, 1, 2)
	at(5000)
	diag.fail(d, 1, "coal", REASON_CAPACITY, 50, 40)
	assert_nil(e.pending)
	at(5100)
	diag.fail(d, 1, "coal", REASON_MASK_MISMATCH, 1, 2)
	assert_eq(e.pending_since, 5100, "a reason that returns starts its window again")
	assert_eq(#diag.events(nil, 0, 10), 2)
	assert_eq(e.n, 8)
end)

test("flap rule: one evaluation 30 s later is not enough", function()
	at(0)
	local d = setup()
	diag.fail(d, 1, "coal", REASON_NO_PROVIDER, 0, 0)
	at(10)
	diag.fail(d, 1, "coal", REASON_CAPACITY, 1, 1)
	local e = d.unserved[1][1]
	e.pending_n = 0
	at(4000)
	diag.fail(d, 1, "coal", REASON_CAPACITY, 1, 1)
	assert_eq(e.reason, REASON_NO_PROVIDER)
	at(4040)
	diag.fail(d, 1, "coal", REASON_CAPACITY, 1, 1)
	assert_eq(e.reason, REASON_CAPACITY)
end)

--- Confirms `reason` for key (1, coal) at `tick` (two evaluations 1800 ticks apart).
local function flip(d, tick, reason)
	at(tick)
	diag.fail(d, 1, "coal", reason, 0, 0)
	at(tick + 1800)
	diag.fail(d, 1, "coal", reason, 0, 0)
end

test("flapping: the fifth change in 10 min logs one flapping event, then quiet until 10 min stable", function()
	at(0)
	local d = setup()
	diag.fail(d, 1, "coal", REASON_NO_PROVIDER, 0, 0)
	local reasons = { REASON_CAPACITY, REASON_NO_PROVIDER, REASON_CAPACITY, REASON_NO_PROVIDER, REASON_CAPACITY,
		REASON_NO_PROVIDER }
	local t = 100
	for _, r in ipairs(reasons) do
		flip(d, t, r)
		t = t + 1900
	end
	-- first entry + four transitions, then the fifth change is flapping and the sixth is suppressed
	local ev = diag.events(nil, 0, 20)
	assert_eq(kinds(ev), { "unserved_reason", "unserved_reason", "unserved_reason", "unserved_reason",
		"unserved_reason", "flapping" })
	local flap = ev[6]
	assert_eq(flap.b, 5)
	assert_eq(flap.a, bit32.bor(bit32.lshift(1, REASON_NO_PROVIDER - 1), bit32.lshift(1, REASON_CAPACITY - 1)))
	local e = d.unserved[1][1]
	assert_eq(e.reason, REASON_NO_PROVIDER)
	assert_not_nil(e.suppressed_until)
	-- Stable for 10 minutes after the last change: the next change is an ordinary transition again.
	flip(d, e.suppressed_until, REASON_CAPACITY)
	assert_eq(kinds(diag.events(nil, flap.seq, 20)), { "unserved_reason" })
	assert_eq(d.counts, tally(d))
end)

test("lost priority: a counter on the entry beside its reason, kept when an evaluation loses nothing", function()
	at(5)
	local d = setup()
	diag.fail(d, 3, "coal", REASON_P_RESERVED, 2000, 1000, 9, nil, 4)
	diag.fail(d, 3, "coal", REASON_P_RESERVED, 2000, 1000, 9, nil, 4)
	local e = d.unserved[3][1]
	assert_eq({ e.reason, e.lost_n, e.lost_to }, { REASON_P_RESERVED, 2, 4 })
	diag.fail(d, 3, "coal", REASON_P_RESERVED, 2000, 1000, 9, nil, nil)
	assert_eq({ e.lost_n, e.lost_to }, { 2, 4 })
end)

test("skipped: requester-side reasons and their payloads", function()
	at(1)
	local d = setup()
	local stop = { valid = true }
	diag.skipped(d, 1, { trains_limit = 1, deliveries_total = 2, entity_stop = stop, deliveries = {} }, "coal")
	diag.skipped(d, 2, { trains_limit = 0, deliveries_total = 0, entity_stop = stop, deliveries = {} }, "coal")
	diag.skipped(d, 3, { trains_limit = 5, deliveries_total = 1, entity_stop = stop, deliveries = { coal = -400 } }, "coal")
	diag.skipped(d, 4, { trains_limit = 5, deliveries_total = 1, entity_stop = { valid = false }, deliveries = {} }, "coal")
	diag.skipped(d, 5, { trains_limit = 5, deliveries_total = 1, entity_stop = stop, deliveries = { coal = 10 } }, "coal")
	local function view(id)
		local e = d.unserved[id] and d.unserved[id][1]
		return e and { e.reason, e.a, e.b } or false
	end
	assert_eq(view(1), { REASON_R_AT_LIMIT, 2, 1 })
	assert_eq(view(2), { REASON_R_DISABLED, 0, 0 })
	assert_eq(view(3), { REASON_R_IS_PROVIDING, 400, 0 })
	assert_eq(view(4), false)
	assert_eq(view(5), false)
end)

test("served: wait and evaluation count in the event, entry and counts gone", function()
	at(100)
	local d = setup()
	diag.fail(d, 7, "coal", REASON_NO_TRAINS_ON_NETWORK, 0, 3)
	diag.fail(d, 7, "iron-plate", REASON_NO_PROVIDER, 0, 0)
	at(150)
	diag.fail(d, 7, "coal", REASON_NO_TRAINS_ON_NETWORK, 0, 3)
	at(400)
	diag.served(d, 7, "coal", 12, 55, 0)
	diag.served(d, 7, "stone", 12, 55, 0)
	diag.served(d, 8, "coal", 12, 55, 0)
	local ev = diag.events(nil, 0, 10)
	assert_eq(kinds(ev), { "unserved_reason", "unserved_reason", "served" })
	assert_eq({ ev[3].station, ev[3].station2, ev[3].train, ev[3].a, ev[3].b, ev[3].code },
		{ 7, 12, 55, 300, 2, REASON_NO_TRAINS_ON_NETWORK })
	assert_nil(d.unserved[7][1])
	assert_eq(d.unserved_count[7], 1)
	assert_eq(d.counts, { [REASON_NO_PROVIDER] = 1 })
	diag.served(d, 7, "iron-plate", 12, 55, 0)
	assert_nil(d.unserved[7])
	assert_nil(d.unserved_count[7])
	assert_eq(d.unserved_n, 0)
	assert_eq(d.counts, {})
end)

test("cycle: entries no evaluation touched for two cycles are swept", function()
	at(0)
	local d = setup()
	diag.cycle()
	diag.fail(d, 1, "coal", REASON_NO_PROVIDER, 0, 0)
	diag.fail(d, 2, "coal", REASON_NO_PROVIDER, 0, 0)
	at(50)
	diag.cycle()
	diag.fail(d, 2, "coal", REASON_NO_PROVIDER, 0, 0)
	at(100)
	diag.cycle()
	assert_eq(d.unserved_n, 2, "a key last seen in the cycle before the previous one survives")
	at(150)
	diag.cycle()
	assert_nil(d.unserved[1])
	assert_not_nil(d.unserved[2])
	at(200)
	diag.cycle()
	assert_nil(d.unserved[2])
	assert_eq(d.unserved_n, 0)
	assert_eq(d.counts, {})
end)

test("cap: more failing keys than the cap over two cycles; refused keys are counted, logged once, never evicting", function()
	at(0)
	local d = setup()
	diag.cycle()
	local cap, extra = diag.UNSERVED_CAP, 500
	local function evaluate_all(from)
		for i = from, cap + extra do diag.fail(d, i, "coal", REASON_NO_PROVIDER, 0, 0) end
	end
	evaluate_all(1)
	assert_eq({ d.unserved_n, d.unserved_dropped, d.seq }, { cap, extra, cap })
	assert_nil(d.unserved[cap + 1])
	assert_eq(d.counts, tally(d))
	-- The same evaluation order next cycle: the live keys stay put, nothing is logged again, no key churns.
	at(50)
	diag.cycle()
	evaluate_all(1)
	assert_eq({ d.unserved_n, d.unserved_dropped, d.seq }, { cap, 2 * extra, cap })
	assert_eq(d.unserved[1][1].first_tick, 0)
	-- Keys 1..1000 stop failing: the sweep frees their slots and refused keys get in.
	at(100)
	diag.cycle()
	evaluate_all(1001)
	at(150)
	diag.cycle()
	at(200)
	diag.cycle()
	assert_nil(d.unserved[1])
	assert_eq(d.unserved_n, cap - 1000)
	evaluate_all(1001)
	assert_eq(d.unserved_n, cap - 1000 + extra)
	assert_not_nil(d.unserved[cap + extra])
	assert_eq(d.counts, tally(d))
end)

test("acks: the sweep keeps an acknowledgement; a re-created key with another reason ends it; service ends it", function()
	at(0)
	local d = setup()
	diag.cycle()
	diag.fail(d, 1, "coal", REASON_R_AT_LIMIT, 1, 1)
	diag.ack("request", 1, "coal", 3, nil)
	diag.fail(d, 2, "coal", REASON_NO_PROVIDER, 0, 0)
	diag.ack("request", 2, "coal", 3, nil)
	for _, t in ipairs({ 50, 100, 150 }) do
		at(t)
		diag.cycle()
	end
	assert_nil(d.unserved[1])
	assert_nil(d.unserved[2])
	assert_not_nil(diag.is_acked("request", 1, "coal"), "swept, not resolved")
	assert_not_nil(diag.is_acked("request", 2, "coal"))
	diag.fail(d, 1, "coal", REASON_R_AT_LIMIT, 1, 1)
	assert_not_nil(diag.is_acked("request", 1, "coal"), "same reason again")
	diag.fail(d, 2, "coal", REASON_NO_TRAINS_ON_NETWORK, 0, 3)
	assert_nil(diag.is_acked("request", 2, "coal"), "a different reason ends it")
	local un = diag.events({ kind = DIAG_KIND_UNACKNOWLEDGED }, 0, 10)
	assert_eq({ #un, un[1].station, un[1].b }, { 1, 2, DIAG_ACK_END_REASON_CHANGED })
	-- Served while it had no entry: still resolved.
	for _, t in ipairs({ 200, 250, 300 }) do
		at(t)
		diag.cycle()
	end
	assert_nil(d.unserved[1])
	diag.served(d, 1, "coal", 5, 6, 0)
	assert_nil(diag.is_acked("request", 1, "coal"))
	-- An acknowledgement taken without a known reason binds to the reason of the key's next first entry.
	diag.ack("request", 9, "coal", 3, nil)
	assert_nil(storage.acks.request[9].coal.reason)
	diag.fail(d, 9, "coal", REASON_CAPACITY, 2, 1)
	assert_eq(storage.acks.request[9].coal.reason, REASON_CAPACITY)
end)

test("station_removed: entries, counters and acknowledgements of the station go", function()
	at(0)
	local d = setup()
	diag.fail(d, 4, "coal", REASON_NO_PROVIDER, 0, 0)
	diag.fail(d, 4, "stone", REASON_CAPACITY, 1, 1)
	diag.fail(d, 5, "coal", REASON_NO_PROVIDER, 0, 0)
	diag.station_power(d, 4, false)
	diag.ack("station", 4, nil, 1, nil)
	diag.ack("request", 4, "coal", 1, 100)
	diag.station_removed(4)
	assert_nil(d.unserved[4])
	assert_nil(d.unserved_count[4])
	assert_nil(d.unpowered[4])
	assert_eq(d.unserved_n, 1)
	assert_eq(d.counts, { [REASON_NO_PROVIDER] = 1 })
	assert_nil(storage.acks.station[4])
	assert_nil(storage.acks.request[4])
end)

test("fleet_size: every Cybersyn train per network, each-network masks too, once per cycle", function()
	at(0)
	local d = setup()
	storage.trains = {
		{ network_name = "signal-A" },
		{ network_name = "signal-A" },
		{ network_name = NETWORK_EACH, network_mask = { ["signal-A"] = 1, ["signal-B"] = 2 } },
		{ network_name = nil },
	}
	diag.cycle()
	assert_eq(diag.fleet_size(d, "signal-A"), 3)
	assert_eq(diag.fleet_size(d, "signal-B"), 1)
	assert_eq(diag.fleet_size(d, "signal-C"), 0)
	storage.trains[5] = { network_name = "signal-B" }
	assert_eq(diag.fleet_size(d, "signal-B"), 1, "cached for the cycle")
	at(40)
	diag.cycle()
	assert_eq(diag.fleet_size(d, "signal-B"), 2)
end)

test("unserved_summary and unserved_rows: worst reason, oldest wait, top-k by wait", function()
	at(0)
	local d = setup()
	at(300)
	diag.fail(d, 1, "coal", REASON_R_IS_PROVIDING, 0, 0)
	at(100)
	diag.fail(d, 1, "stone", REASON_P_BELOW_THRESHOLD, 1, 2)
	at(200)
	diag.fail(d, 2, "coal", REASON_NO_TRAINS_ON_NETWORK, 0, 0)
	at(100)
	diag.fail(d, 3, "coal", REASON_NO_PROVIDER, 0, 0)
	local n, worst, oldest = diag.unserved_summary(1)
	assert_eq({ n, worst, oldest }, { 2, REASON_P_BELOW_THRESHOLD, 100 })
	assert_eq({ diag.unserved_summary(9) }, { 0 })
	local rows = diag.unserved_rows({ limit = 3 })
	local ids = {}
	for i, r in ipairs(rows) do ids[i] = { r.r_station_id, r.hash } end
	assert_eq(ids, { { 1, "stone" }, { 3, "coal" }, { 2, "coal" } })
	rows = diag.unserved_rows({ item = "coal", reason = REASON_NO_PROVIDER })
	assert_eq(#rows, 1)
	assert_eq(rows[1].r_station_id, 3)
	assert_eq(diag.unserved_rows({ item = "water" }), {})
	assert_same(diag.counts_by_reason(), d.counts)
	assert_eq(d.counts, tally(d))
end)

test("rings: basic kinds and full kinds go to their own ring; full kinds only in full mode", function()
	at(7)
	local d = setup("basic")
	assert_nil(diag.event(d, DIAG_KIND_DISPATCHED, DIAG_SEV_INFO, 0, 1, 2, 3, 4, 5, 6, 7))
	diag.event(d, DIAG_KIND_ALERT, DIAG_SEV_ERROR, 3, 0, 9, 0, 0, 0, 0, 0)
	assert_eq({ d.ring_basic.count, d.ring_full.count, d.seq }, { 1, 0, 1 })
	setup("full")
	diag.event(d, DIAG_KIND_DISPATCHED, DIAG_SEV_INFO, 0, 1, 2, 3, 4, 5, 6, 7)
	diag.event(d, DIAG_KIND_SERVED, DIAG_SEV_INFO, 0, 0, 2, 3, 4, 5, 6, 7)
	diag.event(d, DIAG_KIND_ARRIVE_P, DIAG_SEV_INFO, 0, 1, 2, 3, 0, 0, 0, 0)
	assert_eq({ d.ring_basic.count, d.ring_full.count, d.seq }, { 2, 2, 4 })
	local ev = diag.events(nil, 0, 10)
	assert_eq(kinds(ev), { "alert", "dispatched", "served", "arrive_p" })
	assert_eq({ ev[2].seq, ev[2].tick, ev[2].delivery, ev[2].train, ev[2].station, ev[2].station2, ev[2].item, ev[2].a,
		ev[2].b }, { 2, 7, 1, 2, 3, 4, 5, 6, 7 })
	assert_eq(kinds(diag.events(nil, 2, 10)), { "served", "arrive_p" }, "from_seq is exclusive")
	assert_eq(kinds(diag.events(nil, nil, 2)), { "served", "arrive_p" }, "nil from_seq = the newest, oldest first")
	assert_eq(kinds(diag.events({ kind = DIAG_KIND_SERVED }, 0, 10)), { "served" })
	assert_eq(kinds(diag.events({ station = 4 }, 0, 10)), { "dispatched", "served" })
	assert_eq(kinds(diag.last_for("train", 2, 10)), { "arrive_p", "served", "dispatched" })
	assert_eq(kinds(diag.last_for("delivery", 1, 1)), { "arrive_p" })
	local oldest, span = diag.horizon()
	assert_eq({ oldest, span }, { 7, 0 })
end)

test("rings: wrap keeps the newest rows; merged order follows seq across both rings", function()
	at(0)
	local d = setup("full", 1024)
	for i = 1, 5000 do
		at(i)
		if i % 3 == 0 then
			diag.event(d, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, 0, 0, 0, i, 0, 0, i, 0)
		else
			diag.event(d, DIAG_KIND_ARRIVE_R, DIAG_SEV_INFO, 0, 0, 0, i, 0, 0, i, 0)
		end
	end
	assert_eq(d.ring_basic.count, 1666)
	assert_eq(d.ring_full.count, 1024)
	assert_eq(d.seq, 5000)
	local ev = diag.events(nil, 0, 100000)
	assert_eq(#ev, 1666 + 1024)
	for i = 2, #ev do
		if ev[i].seq <= ev[i - 1].seq then error("out of order at " .. i) end
	end
	-- the full ring keeps its newest 1024 rows: two of every three ticks, so its oldest row is tick 3466
	assert_eq(diag.events({ kind = DIAG_KIND_ARRIVE_R }, 0, 1)[1].a, 3466)
	-- the log is complete only as far back as both rings reach: the full ring's oldest row
	assert_eq(diag.horizon(), 3466)
	d.full = false
	assert_eq(diag.horizon(), 3, "with full off the full ring's leftover rows do not count")
	d.full = true
	assert_eq(#diag.events(nil, 4990, 100), 10)
end)

test("rings: resizing the full ring keeps the newest rows and their order", function()
	at(0)
	local d = setup("full", 2048)
	for i = 1, 3000 do
		diag.event(d, DIAG_KIND_ARRIVE_R, DIAG_SEV_INFO, 0, 0, 0, i, 0, 0, i, 0)
	end
	setup("full", 1024)
	local r = d.ring_full
	assert_eq({ r.size, r.count, r.head }, { 1024, 1024, 1024 })
	local ev = diag.events(nil, 0, 5000)
	assert_eq(#ev, 1024)
	assert_eq({ ev[1].a, ev[1024].a }, { 1977, 3000 })
	diag.event(d, DIAG_KIND_ARRIVE_R, DIAG_SEV_INFO, 0, 0, 0, 3001, 0, 0, 3001, 0)
	ev = diag.events(nil, 0, 5000)
	assert_eq({ #ev, ev[1].a, ev[1024].a }, { 1024, 1978, 3001 })
	setup("full", 4096)
	assert_eq({ r.size, r.count }, { 4096, 1024 })
	diag.event(d, DIAG_KIND_ARRIVE_R, DIAG_SEV_INFO, 0, 0, 0, 3002, 0, 0, 3002, 0)
	ev = diag.events(nil, 0, 5000)
	assert_eq({ #ev, ev[1].a, ev[1025].a }, { 1025, 1978, 3002 })
end)

test("export: csv lines, a header once, chunks of 2,000 rows appended", function()
	at(50)
	local d = setup("full")
	local writes = {}
	helpers.write_file = function(path, data, append, player) writes[#writes + 1] = { path, data, append, player } end
	diag.intern(d, "iron-plate|rare")
	for i = 1, 4000 do
		diag.event(d, DIAG_KIND_UNSERVED_REASON, DIAG_SEV_WARNING, REASON_CAPACITY, 0, 0, 7, 8, 1, 50, 40)
	end
	diag.event(d, DIAG_KIND_TRAIN_STATE, DIAG_SEV_ERROR, defines.train_state.no_path, 3, 4, 0, 0, 0, 0, 0)
	local path = diag.export(1, nil)
	assert_eq(path, "cybersyn/diag-50.csv")
	-- written after the export started: not part of it
	diag.event(d, DIAG_KIND_ALERT, DIAG_SEV_ERROR, 1, 0, 0, 0, 0, 0, 0, 0)
	assert_eq(#d.export_jobs, 1)
	diag.export_tick()
	diag.export_tick()
	assert_eq(#d.export_jobs, 1)
	diag.export_tick()
	assert_eq(#d.export_jobs, 0)
	diag.export_tick()
	assert_eq(#writes, 3)
	assert_eq({ writes[1][1], writes[1][3], writes[1][4] }, { "cybersyn/diag-50.csv", false, 1 })
	assert_eq({ writes[2][3], writes[3][3] }, { true, true })
	local lines = {}
	for i, w in ipairs(writes) do
		for line in string.gmatch(w[2], "[^\n]+") do lines[#lines + 1] = line end
	end
	assert_eq(#lines, 1 + 4001)
	assert_eq(lines[1], "seq,tick,kind,severity,code,delivery,train,station,station2,item,a,b")
	assert_eq(lines[2], "1,50,unserved_reason,warning,CAPACITY,0,0,7,8,iron-plate|rare,50,40")
	assert_eq(lines[4002], "4001,50,train_state,error,no_path,3,4,0,0,,0,0")
	assert_eq(diag.csv_line({ seq = 1, tick = 2, kind = DIAG_KIND_ALERT, sev = 1, code = DIAG_ALERT_STUCK, delivery = 0,
		train = 3, station = 0, station2 = 0, item = 1, a = 0, b = 0 }, { 'odd,"name"' }),
		'1,2,alert,error,stuck,0,3,0,0,"odd,""name""",0,0\n')
	helpers.write_file = function() end
end)

test("export: a selective filter is scanned in bounded steps", function()
	at(60)
	local d = setup("full")
	local writes = {}
	helpers.write_file = function(path, data, append, player) writes[#writes + 1] = { path, data, append, player } end
	for i = 1, 9000 do
		diag.event(d, DIAG_KIND_ARRIVE_P, DIAG_SEV_INFO, 0, 0, 3, 0, 0, 0, 0, 0)
	end
	diag.event(d, DIAG_KIND_ARRIVE_P, DIAG_SEV_INFO, 0, 0, 4, 0, 0, 0, 0, 0)
	diag.export(nil, { train = 4 })
	diag.export_tick()
	assert_eq(#d.export_jobs, 1, "8,000 rows scanned, the match not reached yet")
	diag.export_tick()
	assert_eq(#d.export_jobs, 0)
	assert_eq(#writes, 2)
	assert_eq(writes[2][2], "9001,60,arrive_p,info,0,0,4,0,0,,0,0\n")
	helpers.write_file = function() end
end)

test("acks: expiry by time, by a confirmed reason change, on service; events and log lines", function()
	at(0)
	local d = setup()
	diag.fail(d, 1, "coal", REASON_NO_PROVIDER, 0, 0)
	local ack = diag.ack("request", 1, "coal", 3, 1000)
	assert_eq({ ack.player_index, ack.tick, ack.until_tick, ack.reason }, { 3, 0, 1000, REASON_NO_PROVIDER })
	assert_not_nil(diag.is_acked("request", 1, "coal"))
	diag.ack("station", 2, nil, 3, nil)
	diag.ack("lint", 2, 4, 3, 500)
	at(500)
	assert_nil(diag.is_acked("lint", 2, 4), "until_tick reached")
	diag.expire_acks()
	assert_nil(storage.acks.lint[2])
	assert_not_nil(diag.is_acked("station", 2, nil))
	-- a confirmed change of the request's reason ends its acknowledgement
	at(600)
	diag.fail(d, 1, "coal", REASON_CAPACITY, 1, 1)
	at(2400)
	diag.fail(d, 1, "coal", REASON_CAPACITY, 1, 1)
	assert_nil(storage.acks.request[1])
	assert_eq(kinds(diag.events({ kind = DIAG_KIND_UNACKNOWLEDGED }, 0, 10)), { "unacknowledged", "unacknowledged" })
	local un = diag.events({ kind = DIAG_KIND_UNACKNOWLEDGED }, 0, 10)
	assert_eq({ un[1].code, un[1].b }, { DIAG_ACK_LINT, DIAG_ACK_END_EXPIRED })
	assert_eq({ un[2].code, un[2].b, un[2].item }, { DIAG_ACK_REQUEST, DIAG_ACK_END_REASON_CHANGED, 1 })
	-- served: the acknowledged problem is gone
	diag.ack("request", 1, "coal", 3, nil)
	diag.served(d, 1, "coal", 5, 6, 0)
	assert_nil(storage.acks.request[1])
	assert_true(diag.unack("station", 2, nil, 3))
	assert_false(diag.unack("station", 2, nil, 3))
	local acked = diag.events({ kind = DIAG_KIND_ACKNOWLEDGED }, 0, 10)
	assert_eq(#acked, 4)
	assert_eq({ acked[1].station, acked[1].station2, acked[1].a, acked[1].item }, { 1, 3, 1000, 1 })
	assert_true(#H.logged >= 8)
end)

test("acks: survive diagnostics off, capped at 1,024 with the oldest dropped", function()
	at(0)
	setup("off")
	for i = 1, diag.ACK_CAP do
		at(i)
		diag.ack("station", i, nil, 1, nil)
	end
	at(5000)
	diag.ack("request", 77, "coal", 1, nil)
	local n = 0
	for _ in pairs(storage.acks.station) do n = n + 1 end
	assert_eq(n, diag.ACK_CAP - 1)
	assert_nil(storage.acks.station[1])
	assert_not_nil(storage.acks.request[77].coal)
	assert_nil(diag.is_acked("request", 77, "coal").reason)
	-- replacing an existing acknowledgement does not evict another
	diag.ack("station", 2, nil, 1, 9000)
	assert_not_nil(storage.acks.station[3])
	assert_eq(storage.acks.station[2].until_tick, 9000)
end)

test("alerts: one row per entity and alert until it changes or 10 minutes pass", function()
	at(0)
	local d = setup()
	local stop = { valid = true, unit_number = 40 }
	storage.trains = {}
	diag.alert(DIAG_ALERT_MISSING_TRAIN, nil, stop, nil)
	diag.alert(DIAG_ALERT_MISSING_TRAIN, nil, stop, nil)
	diag.alert(DIAG_ALERT_TRAINS_FILTERED, nil, stop, nil)
	at(36000)
	diag.alert(DIAG_ALERT_TRAINS_FILTERED, nil, stop, nil)
	diag.alert(DIAG_ALERT_STUCK, { valid = true, id = 8 }, nil, nil)
	diag.alert(DIAG_ALERT_STUCK, { valid = true, id = 8 }, nil, nil)
	local ev = diag.events({ kind = DIAG_KIND_ALERT }, 0, 10)
	local codes = {}
	for i, e in ipairs(ev) do codes[i] = e.code end
	assert_eq(codes, { DIAG_ALERT_MISSING_TRAIN, DIAG_ALERT_TRAINS_FILTERED, DIAG_ALERT_TRAINS_FILTERED, DIAG_ALERT_STUCK })
	assert_eq({ ev[4].train, ev[4].sev }, { 8, DIAG_SEV_ERROR })
	-- Two alerts taking turns on one stop are each kept to one row per window.
	diag.alert(DIAG_ALERT_MISSING_TRAIN, nil, stop, nil)
	diag.alert(DIAG_ALERT_TRAINS_FILTERED, nil, stop, nil)
	diag.alert(DIAG_ALERT_MISSING_TRAIN, nil, stop, nil)
	assert_eq(#diag.events({ kind = DIAG_KIND_ALERT }, 0, 10), 5)
	at(71999)
	diag.cycle()
	assert_eq(d.alert_last, { [40 * 32 + DIAG_ALERT_TRAINS_FILTERED] = 36000, [40 * 32 + DIAG_ALERT_MISSING_TRAIN] = 36000,
		[-(8 * 32 + DIAG_ALERT_STUCK)] = 36000 })
	at(107999)
	diag.cycle()
	assert_eq(d.alert_last, {}, "older than 10 minutes pruned")
end)

test("station hooks and full-mode train events", function()
	at(10)
	local d = setup("full")
	diag.station_limit(d, 5, 2, 0)
	diag.station_limit(d, 5, 0, 3)
	diag.station_power(d, 5, false)
	assert_true(d.unpowered[5])
	diag.station_power(d, 5, true)
	assert_nil(d.unpowered[5])
	diag.station_warmup_done(d, 5)
	local train = { manifest = { { name = "coal", count = 50 }, { name = "stone", count = 10 } }, r_station_id = 6 }
	storage.trains = { [3] = train }
	diag.dispatched(d, 3, train, 6, 7, train.manifest)
	assert_eq(train.delivery_id, 1)
	diag.train_event(DIAG_KIND_ARRIVE_P, 3, train, 7)
	diag.train_state(3, train, defines.train_state.on_the_path, 0, defines.train_state.no_path)
	diag.train_state(3, train, defines.train_state.wait_signal, 10 - diag.WAIT_SIGNAL_MIN + 1, defines.train_state.on_the_path)
	diag.train_state(3, train, defines.train_state.wait_signal, 10 - diag.WAIT_SIGNAL_MIN, defines.train_state.on_the_path)
	local ev = diag.events(nil, 0, 20)
	assert_eq(kinds(ev), { "station_disabled", "station_limit", "station_power", "station_power",
		"station_warmup_done", "dispatched", "arrive_p", "train_state", "train_state" })
	assert_eq({ ev[1].a, ev[1].b, ev[2].a, ev[2].b }, { 2, 0, 0, 3 })
	assert_eq({ ev[6].delivery, ev[6].a, ev[6].b, ev[6].station, ev[6].station2 }, { 1, 2, 60, 6, 7 })
	assert_eq({ ev[7].delivery, ev[7].station, ev[7].station2, ev[7].a }, { 1, 7, 6, 60 })
	assert_eq({ ev[8].code, ev[9].code, ev[9].a }, { defines.train_state.no_path, defines.train_state.wait_signal,
		diag.WAIT_SIGNAL_MIN })
	setup("basic")
	diag.dispatched(d, 3, train, 6, 7, train.manifest)
	assert_nil(train.delivery_id)
end)

test("stats: available counters, the window minimum and no-train failures", function()
	at(3600 * 10 + 5)
	storage.available_trains = { ["signal-A"] = { [1] = true, [2] = true }, ["signal-B"] = { [3] = true } }
	stats.init()
	local s = stats.get()
	assert_eq(s.available_count, { ["signal-A"] = 2, ["signal-B"] = 1 })
	assert_eq(stats.min_available(60), { ["signal-A"] = 2, ["signal-B"] = 1 })
	at(3600 * 11)
	stats.available_changed("signal-A", -1)
	stats.available_changed("signal-A", -1)
	at(3600 * 12)
	stats.available_changed("signal-A", 1)
	stats.available_changed("signal-C", 1)
	assert_eq(s.available_count, { ["signal-A"] = 1, ["signal-B"] = 1, ["signal-C"] = 1 })
	assert_eq(stats.min_available(60), { ["signal-A"] = 0, ["signal-B"] = 1, ["signal-C"] = 0 })
	assert_eq(stats.min_available(1), { ["signal-A"] = 0, ["signal-B"] = 1, ["signal-C"] = 0 },
		"a level held since an earlier minute counts")
	at(3600 * 75)
	assert_eq(stats.min_available(60), { ["signal-A"] = 1, ["signal-B"] = 1, ["signal-C"] = 1 })
	assert_eq(stats.aggregate(1440).min_available_by_network, { ["signal-A"] = 0, ["signal-B"] = 1, ["signal-C"] = 0 })
	stats.record_no_train_failure()
	stats.record_no_train_failure()
	assert_eq(stats.aggregate(10).no_train_failures, 2)
	assert_eq(stats.aggregate(1440).no_train_failures, 2)
end)

test("no-train failures come from transitions into no-train reasons only", function()
	at(100)
	local d = setup()
	diag.fail(d, 1, "coal", REASON_NO_TRAINS_ON_NETWORK, 0, 1)
	diag.fail(d, 1, "coal", REASON_NO_TRAINS_ON_NETWORK, 0, 1)
	diag.fail(d, 2, "coal", REASON_NO_PROVIDER, 0, 0)
	at(200)
	diag.fail(d, 2, "coal", REASON_CAPACITY, 5, 4)
	at(2000)
	diag.fail(d, 2, "coal", REASON_CAPACITY, 5, 4)
	assert_eq(stats.aggregate(10).no_train_failures, 2)
end)
