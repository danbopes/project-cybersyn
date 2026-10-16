-- scripts/lint.lua (PLAN3 §4.12): the check predicates against plain records.

local H = require("harness")
local lint = H.load("scripts.lint")

local function checks(out)
	local names = {}
	for i, f in ipairs(out) do names[i] = LINT_NAMES[f.check] end
	return names
end

--- A requester record on signal-A (mask `mask`) asking for `hashes` = {hash = {threshold, active}}.
local function station(mask, hashes, extra)
	local st = { is_r = true, is_p = false, network_name = "signal-A", network_mask = mask, requested = {}, provided = {},
		deliveries = {}, thresholds = {} }
	for hash, r in pairs(hashes or {}) do
		st.requested[hash] = { count = -r[1], threshold = r[1], active = r[2] ~= false }
	end
	for k, v in pairs(extra or {}) do st[k] = v end
	return st
end

local function fleet(by_layout, mask_or)
	return { capability = { ["signal-A"] = by_layout }, mask_or = { ["signal-A"] = mask_or } }
end

local CLEAN = { limit = 2, count = 0, occupancy = 0, occupancy_gap = false, deliveries = 0, bound = 0, phantom = false }

local function run(st, rec, fl, pm, starved, live)
	local out = {}
	local mask = lint.check_station(out, 7, st, rec or { allows_all_trains = true, accepted_layouts = {} }, fl,
		pm or {}, starved or {}, live or CLEAN)
	return mask, out
end

test("constants: one bit, key, name and severity per check", function()
	assert_eq(#LINT_NAMES, LINT_COUNT)
	local seen = 0
	for check = 1, LINT_COUNT do
		assert_eq(LINT_BY_NAME[LINT_NAMES[check]], check)
		assert_eq(LINT_BIT[check], 2 ^ (check - 1))
		assert_not_nil(LINT_SEVERITY[check])
		assert_true(bit32.band(seen, LINT_BIT[check]) == 0)
		seen = bit32.bor(seen, LINT_BIT[check])
	end
	assert_eq(LINT_KEYS[LINT_DEPOT_SHARED_NAME], "depot-shared-name")
	assert_eq(LINT_PREDICTS[LINT_CAPACITY], REASON_CAPACITY)
end)

test("eligible: mask-matching trains, the ones the stop accepts and their largest capacities", function()
	local cap = {
		[1] = { count = 2, item_capacity = 40, fluid_capacity = 0, mask_or = 1 },
		[2] = { count = 3, item_capacity = 80, fluid_capacity = 50000, mask_or = 2 },
		[3] = { count = 1, item_capacity = 120, fluid_capacity = 0, mask_or = 1 },
	}
	assert_eq({ lint.eligible(cap, 1, true, {}) }, { 3, 3, 120, 0 })
	assert_eq({ lint.eligible(cap, 1, false, { [1] = true }) }, { 3, 2, 40, 0 })
	assert_eq({ lint.eligible(cap, 3, false, { [2] = true }) }, { 6, 3, 80, 50000 })
	assert_eq({ lint.eligible(cap, 4, true, {}) }, { 0, 0, 0, 0 })
	assert_eq({ lint.eligible(nil, 1, true, {}) }, { 0, 0, 0, 0 })
end)

test("capacity: a threshold above the largest eligible train, in stacks for items and units for fluids", function()
	local fl = fleet({ [1] = { count = 1, item_capacity = 40, fluid_capacity = 25000, mask_or = 1 } }, 1)
	-- 5,000 iron plates (stack 100) = 50 slots > 40.
	local mask, out = run(station(1, { ["iron-plate"] = { 5000 } }), nil, fl)
	assert_eq(checks(out), { "capacity" })
	assert_eq({ out[1].a, out[1].b, out[1].network, out[1].item }, { 50, 40, "signal-A", "iron-plate" })
	assert_true(lint.has(mask, LINT_CAPACITY))
	-- 4,000 = 40 slots fits; an inactive request is configured all the same.
	assert_eq(checks(select(2, run(station(1, { ["iron-plate"] = { 4000, false } }), nil, fl))), {})
	assert_eq(checks(select(2, run(station(1, { ["iron-plate"] = { 4100, false } }), nil, fl))), { "capacity" })
	-- Quality hashes use the item's stack size; fluids compare units.
	assert_eq(checks(select(2, run(station(1, { ["iron-plate|rare"] = { 4100 } }), nil, fl))), { "capacity" })
	assert_eq(checks(select(2, run(station(1, { water = { 25000 } }), nil, fl))), {})
	assert_eq(checks(select(2, run(station(1, { water = { 25001 } }), nil, fl))), { "capacity" })
	-- Only trains whose layout the stop accepts count: a 400-slot train it rejects does not help.
	local fl2 = fleet({
		[1] = { count = 1, item_capacity = 40, fluid_capacity = 0, mask_or = 1 },
		[2] = { count = 1, item_capacity = 400, fluid_capacity = 0, mask_or = 1 },
	}, 1)
	assert_eq(checks(select(2, run(station(1, { ["iron-plate"] = { 5000 } }), { accepted_layouts = { [1] = true } }, fl2))),
		{ "capacity" })
	assert_eq(checks(select(2, run(station(1, { ["iron-plate"] = { 5000 } }), { allows_all_trains = true }, fl2))), {})
end)

test("layout: trains on the network but none with a layout the stop accepts", function()
	local fl = fleet({ [1] = { count = 2, item_capacity = 40, fluid_capacity = 0, mask_or = 1 } }, 1)
	local mask, out = run(station(1, { ["iron-plate"] = { 1000 } }), { accepted_layouts = { [9] = true } }, fl)
	assert_eq(checks(out), { "layout" })
	assert_eq({ out[1].a, out[1].b }, { 1, 2 })
	-- A provider is checked the same way.
	local p = station(1, {}, { is_r = false, is_p = true })
	assert_eq(checks(select(2, run(p, { accepted_layouts = {} }, fl))), { "layout" })
	assert_eq(checks(select(2, run(p, { accepted_layouts = { [1] = true } }, fl))), {})
end)

test("mask: no train shares a bit, or the item's providers share none with the requester", function()
	local fl = fleet({ [1] = { count = 1, item_capacity = 40, fluid_capacity = 0, mask_or = 2 } }, 2)
	local _, out = run(station(1, { ["iron-plate"] = { 1000 } }), nil, fl)
	assert_eq(checks(out), { "mask" })
	assert_eq({ out[1].a, out[1].b }, { 1, 2 })
	-- No train at all on the network: mask_or 0 (NO_TRAINS_ON_NETWORK's setup case).
	local _, none = run(station(1, {}), nil, { capability = {}, mask_or = {} })
	assert_eq(checks(none), { "mask" })
	-- Trains fine, but every provider of the item is on mask 2.
	local fl3 = fleet({ [1] = { count = 1, item_capacity = 40, fluid_capacity = 0, mask_or = 3 } }, 3)
	local _, prov = run(station(1, { ["iron-plate"] = { 1000 } }), nil, fl3, { ["signal-A:iron-plate"] = 2 })
	assert_eq(checks(prov), { "mask" })
	assert_eq({ prov[1].a, prov[1].b, prov[1].item }, { 1, 2, "iron-plate" })
	assert_eq(checks(select(2, run(station(1, { ["iron-plate"] = { 1000 } }), nil, fl3, { ["signal-A:iron-plate"] = 3 }))),
		{})
end)

test("no_provider: an active request whose key is starved; an inactive one is not", function()
	local fl = fleet({ [1] = { count = 1, item_capacity = 40, fluid_capacity = 0, mask_or = 1 } }, 1)
	local starved = { ["signal-A:iron-plate"] = true }
	assert_eq(checks(select(2, run(station(1, { ["iron-plate"] = { 1000 } }), nil, fl, {}, starved))), { "no_provider" })
	assert_eq(checks(select(2, run(station(1, { ["iron-plate"] = { 1000, false } }), nil, fl, {}, starved))), {})
end)

test("limit 0, same item both ways, occupancy and phantom come from the record and the live reads", function()
	local fl = fleet({ [1] = { count = 1, item_capacity = 40, fluid_capacity = 0, mask_or = 1 } }, 1)
	local live = { limit = 0, count = 2, occupancy = 1, occupancy_gap = true, deliveries = 3, bound = 1, phantom = true }
	local mask, out = run(station(1, {}), nil, fl, nil, nil, live)
	assert_eq(checks(out), { "limit_zero", "occupancy", "phantom" })
	assert_eq({ out[2].a, out[2].b, out[3].a, out[3].b }, { 1, 2, 3, 1 })
	assert_eq(mask, LINT_BIT[LINT_LIMIT_ZERO] + LINT_BIT[LINT_OCCUPANCY] + LINT_BIT[LINT_PHANTOM])
	-- Requesting what it is sending out (R_IS_PROVIDING), or providing what it has inbound (P_IS_REQUESTING).
	local both = station(1, { ["iron-plate"] = { 1000 } }, { is_p = true, deliveries = { ["iron-plate"] = -2000 } })
	local _, o1 = run(both, nil, fl)
	assert_eq(checks(o1), { "same_item" })
	assert_eq(o1[1].a, 2000)
	local inbound = station(1, {}, { is_p = true, provided = { ["iron-plate"] = 500 }, deliveries = { ["iron-plate"] = 800 } })
	assert_eq(checks(select(2, run(inbound, nil, fl))), { "same_item" })
	-- An item threshold of its own clears it; a stop that only requests never has it.
	both.thresholds = { ["iron-plate"] = 500 }
	assert_eq(checks(select(2, run(both, nil, fl))), {})
	local r_only = station(1, { ["iron-plate"] = { 1000 } }, { deliveries = { ["iron-plate"] = -2000 } })
	assert_eq(checks(select(2, run(r_only, nil, fl))), {})
end)

test("each network of a NETWORK_EACH stop is checked with its own mask", function()
	local st = station({ ["signal-A"] = 1, ["signal-B"] = 4 }, { ["iron-plate"] = { 1000 } }, { network_name = NETWORK_EACH })
	local fl = { capability = {
		["signal-A"] = { [1] = { count = 1, item_capacity = 40, fluid_capacity = 0, mask_or = 1 } },
		["signal-B"] = { [1] = { count = 1, item_capacity = 40, fluid_capacity = 0, mask_or = 1 } },
	}, mask_or = { ["signal-A"] = 1, ["signal-B"] = 1 } }
	local _, out = run(st, nil, fl)
	assert_eq(checks(out), { "mask" })
	assert_eq(out[1].network, "signal-B")
end)

test("depot: limit not 1 (unset reads as -1) and a shared name with same-depot trains and bypass", function()
	local out = {}
	local mask = lint.check_depot(out, 5, 4294967295, nil)
	assert_eq(checks(out), { "depot_limit" })
	assert_eq(out[1].a, -1)
	assert_eq(lint.check_depot({}, 5, 1, nil), 0)
	out = {}
	lint.check_depot(out, 5, 1, { ids = { 5, 6 }, same_depot_bypass = 3 })
	assert_eq(checks(out), { "depot_shared_name" })
	assert_eq({ out[1].a, out[1].b }, { 2, 3 })
	assert_eq(lint.check_depot({}, 5, 1, { ids = { 5, 6 }, same_depot_bypass = 0 }), 0)
	assert_eq(lint.check_depot({}, 5, 1, { ids = { 5 }, same_depot_bypass = 2 }), 0)
	assert_true(mask ~= 0)
end)

test("refueler: a mask that shares no bit with the network's trains", function()
	local fl = { capability = {}, mask_or = { ["signal-A"] = 3 } }
	local out = {}
	lint.check_refueler(out, 9, { network_name = "signal-A", network_mask = 4 }, fl)
	assert_eq(checks(out), { "refueler_mask" })
	assert_eq({ out[1].a, out[1].b }, { 4, 3 })
	assert_eq(lint.check_refueler({}, 9, { network_name = "signal-A", network_mask = 2 }, fl), 0)
	assert_eq(lint.check_refueler({}, 9, { network_name = nil }, fl), 0)
end)

test("train: group, missing record, never refuelled, capacity drift (items, then fluid)", function()
	local train = { item_slot_capacity = 40, fluid_capacity = 0 }
	local out = {}
	lint.check_train(out, 3, train, { in_group = true, missing_record = 2, never_refuelled = "signal-A", items = 40,
		fluid = 0 })
	assert_eq(checks(out), { "in_group", "missing_stop", "never_refuelled" })
	assert_eq(out[2].a, 2)
	out = {}
	lint.check_train(out, 3, train, { in_group = false, items = 80, fluid = 0 })
	assert_eq(checks(out), { "capacity_drift" })
	assert_eq({ out[1].a, out[1].b }, { 40, 80 })
	out = {}
	lint.check_train(out, 3, { item_slot_capacity = 0, fluid_capacity = 25000 }, { items = 0, fluid = 50000 })
	assert_eq(checks(out), { "capacity_drift" })
	-- A quality fluid wagon's size is not known from the prototype: no fluid comparison.
	assert_eq(lint.check_train({}, 3, { item_slot_capacity = 0, fluid_capacity = 25000 }, { items = 0 }), 0)
end)
