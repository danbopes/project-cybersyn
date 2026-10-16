-- Characterization tests for scripts/gui/collector.lua at 3b5fe31, on a synthetic storage with fake entities.

local H = require("harness")
local collector = require("scripts.gui.collector")

local WORKING = defines.entity_status.working
local LOW_POWER = defines.entity_status.low_power
local NO_POWER = defines.entity_status.no_power

local function sig(name, count, type, quality)
	return { signal = { name = name, type = type, quality = quality }, count = count }
end

-- `signals` and `status` stay writable, so a test can change a combinator's inputs between two passes.
local function comb(status, signals)
	local c = { valid = true, status = status, signals = signals }
	function c.get_signals(red, green)
		assert(red == defines.wire_connector_id.circuit_red and green == defines.wire_connector_id.circuit_green)
		return c.signals
	end
	return c
end

local function stop(name, surface)
	return { valid = true, backer_name = name, surface_index = surface or 1 }
end

local function manager()
	storage.manager = { players = {} }
	collector.init()
end

-- Six stations covering provider, requester, warming up, each-network + stack, missing combinator, secondary.
local function scenario()
	mod_settings = { r_threshold = 2000, r_fluid_threshold = 0, track_request_wait_times = true, tps = 30 }
	manager()
	storage.stations = {
		[1] = {
			entity_stop = stop("Iron Mine"),
			entity_comb1 = comb(WORKING, {
				sig("iron-ore", 500),
				sig("signal-A", 1, "virtual"),
				sig("cybersyn-priority", 3, "virtual"),
				sig("coal", -100),
				sig("water", 2000, "fluid"),
			}),
			network_name = "signal-A",
			network_mask = 1,
			is_p = true,
			trains_limit = 2,
			deliveries_total = 3,
			last_delivery_tick = 700,
			priority = 5,
			deliveries = { ["iron-ore"] = -400 },
		},
		[2] = {
			entity_stop = stop("Smelter"),
			entity_comb1 = comb(WORKING, {
				sig("iron-ore", -1000),
				sig("copper-ore", -100),
				sig("coal", -800),
				sig("water", -50, "fluid"),
				sig("stone", 10),
			}),
			entity_comb2 = comb(WORKING, {
				sig("cybersyn-request-threshold", 7, "virtual"),
				sig("iron-ore", -300),
				sig("copper-ore", 20, "item", "rare"),
			}),
			network_name = "signal-A",
			network_mask = 1,
			is_r = true,
			r_threshold = 500,
			item_thresholds = { ["copper-ore"] = 50 },
			deliveries = { ["iron-ore"] = 400 },
			request_start_ticks = { ["iron-ore"] = 50, coal = 20, ["copper-ore"] = 5 },
		},
		[3] = {
			entity_stop = stop("Warming"),
			entity_comb1 = comb(LOW_POWER, { sig("stone", -5000) }),
			network_name = "signal-A",
			network_mask = 1,
			is_r = true,
			is_warming_up = true,
		},
		[4] = {
			entity_stop = stop("Each", 2),
			entity_comb1 = comb(WORKING, { sig("stone", -60), sig("coal", -200), sig("signal-B", 1, "virtual") }),
			network_name = NETWORK_EACH,
			network_mask = { ["signal-A"] = 1, ["signal-B"] = 2 },
			is_r = true,
			is_stack = true,
			r_threshold = 2,
		},
		[5] = {
			entity_stop = stop("No combinator"),
			network_name = "signal-A",
			network_mask = 1,
			is_p = true,
		},
		[6] = {
			entity_stop = stop("Unpowered"),
			entity_comb1 = comb(NO_POWER, { sig("iron-plate", 999) }),
			secondary_inv_combs = {
				comb(WORKING, { sig("iron-plate", 100), sig("copper-plate", -30), sig(REQUEST_THRESHOLD, 20, "virtual") }),
			},
			network_name = "signal-B",
			network_mask = 1,
			is_p = true,
			is_r = true,
		},
	}
	storage.trains = {
		[10] = {
			entity = { valid = true, front_stock = { surface_index = 1 } },
			status = STATUS_TO_P,
			layout_id = 1,
			depot_id = 100,
			network_name = "signal-A",
			network_mask = 1,
			manifest = { { name = "iron-ore", count = 200 }, { name = "iron-ore", quality = "rare", count = 5 }, { name = "iron-ore", count = 50 } },
			p_station_id = 1,
			r_station_id = 2,
		},
		[11] = { entity = { valid = false }, status = STATUS_D },
		[12] = {
			entity = { valid = true, back_stock = { surface_index = 2 } },
			depot_id = 101,
			network_name = NETWORK_EACH,
			network_mask = { ["signal-A"] = 1 },
			is_available = true,
		},
	}
	storage.depots = {
		[100] = { entity_stop = { valid = true, backer_name = "Depot 1", trains_limit = 1, trains_count = 0 } },
		[101] = { entity_stop = { valid = false }, available_train_id = 12 },
	}
	storage.available_trains = { ["signal-A"] = { [12] = true } }
	storage.active_alerts = { [12] = { "x", 3 }, [10] = { "x", 2, 90 } }
	storage.total_ticks = 100
	storage.tick_state = STATE_POLL_STATIONS
	game.tick = 1000
end

test("empty: the snapshot shape", function()
	assert_eq(collector.empty(), {
		started_tick = 0,
		station_count = 0,
		train_count = 0,
		secondary_count = 0,
		stations = {},
		trains = {},
		trains_version = 0,
		inventory_all = { provided = {}, requested = {}, in_transit = {} },
		starved = {},
		starved_items = {},
		starved_count = 0,
		starved_source = "snapshot",
		starved_version = 0,
		-- PLAN3 §4.2: the hour's minimum from stats (phase 2); the fleet facts, depot groups and provider masks the lint
		-- engine reads (phase 2b).
		fleet = { total = 0, by_status = {}, available_by_network = {}, by_layout = {}, min_available_by_network = {},
			capability = {}, mask_or = {}, in_interrupt_count = {}, not_refuelled_count = {}, group_depots = {} },
		depots = { total = 0, parked = 0 },
		depots_by_name = {},
		provider_masks = {},
		provider_overrides = {},
		alerts = {},
	})
	assert_true(collector.empty() ~= collector.empty())
end)

test("init and reset_log: new snapshot, epoch counts up", function()
	storage.manager = { players = {}, snapshot_build = {} }
	collector.init()
	assert_eq(storage.manager.snapshot, collector.empty())
	assert_nil(storage.manager.snapshot_build)
	assert_eq(storage.manager.collect_log, { epoch = 1, base = 0, ids = {} })
	collector.reset_log()
	assert_eq(storage.manager.collect_log, { epoch = 2, base = 0, ids = {} })
	collector.init()
	assert_eq(storage.manager.collect_log.epoch, 3)
end)

test("log_position: creates a log when missing", function()
	storage.manager = { players = {} }
	assert_eq({ collector.log_position() }, { 1, 0 })
	storage.manager.collect_log = { epoch = 4, base = 10, ids = { 7, 8 } }
	assert_eq({ collector.log_position() }, { 4, 12 })
end)

test("changed_since: epoch and range checks", function()
	storage.manager = { players = {} }
	assert_eq({ collector.changed_since(1, 0) }, { nil, 0, 0 })
	local ids = { 7, 8, 9 }
	storage.manager.collect_log = { epoch = 3, base = 10, ids = ids }
	assert_eq({ collector.changed_since(nil, 10) }, { nil, 0, 0 })
	assert_eq({ collector.changed_since(3, nil) }, { nil, 0, 0 })
	assert_eq({ collector.changed_since(2, 10) }, { nil, 0, 0 })
	assert_eq({ collector.changed_since(3, 9) }, { nil, 0, 0 })
	assert_eq({ collector.changed_since(3, 14) }, { nil, 0, 0 })
	local r, first, last = collector.changed_since(3, 10)
	assert_same(r, ids)
	assert_eq({ first, last }, { 1, 3 })
	assert_eq({ select(2, collector.changed_since(3, 12)) }, { 3, 3 })
	-- Up to date: an empty range.
	assert_eq({ select(2, collector.changed_since(3, 13)) }, { 4, 3 })
end)

test("get: creates an empty snapshot and a new log epoch when missing", function()
	storage.manager = { players = {}, collect_log = { epoch = 5, base = 3, ids = { 1 } } }
	local s = collector.get()
	assert_eq(s, collector.empty())
	assert_same(storage.manager.snapshot, s)
	assert_eq(storage.manager.collect_log, { epoch = 6, base = 0, ids = {} })
	assert_same(collector.get(), s)
	assert_eq(storage.manager.collect_log.epoch, 6)
end)

test("release_if_unused: keeps data while any window is open; drops it otherwise", function()
	collector.release_if_unused()
	assert_nil(storage.manager)
	manager()
	local snap = storage.manager.snapshot
	snap.tick = 5
	storage.manager.players = { [1] = { is_manager_open = false }, [2] = { is_manager_open = true } }
	collector.release_if_unused()
	assert_same(storage.manager.snapshot, snap)
	storage.manager.players[2].is_manager_open = false
	storage.manager.snapshot_build = {}
	collector.release_if_unused()
	assert_true(storage.manager.snapshot ~= snap)
	assert_eq(storage.manager.snapshot, collector.empty())
	assert_nil(storage.manager.snapshot_build)
	assert_eq(storage.manager.collect_log.epoch, 2)
	-- Already empty: nothing to release, the epoch stays.
	collector.release_if_unused()
	assert_eq(storage.manager.collect_log.epoch, 2)
end)

test("wanted and tick: an open manager collects unless it is paused with data shown", function()
	scenario()
	storage.manager.players = { [1] = { is_manager_open = true, paused = true }, [2] = { is_manager_open = false } }
	-- Paused before its first data (reopened paused): it still needs one pass.
	assert_true(collector.wanted())
	storage.manager.players[1].rendered_snapshot_tick = 10
	assert_false(collector.wanted())
	assert_false(collector.tick())
	assert_nil(storage.manager.snapshot_build)
	storage.manager.players[1].paused = false
	assert_true(collector.wanted())
	assert_true(collector.tick())
	assert_not_nil(storage.manager.snapshot_build)
	storage.manager = nil
	assert_false(collector.tick())
end)

test("full pass: provider record", function()
	scenario()
	collector.run_to_completion()
	local snap = collector.get()
	assert_eq(snap.stations[1], {
		id = 1,
		name = "Iron Mine",
		name_lower = "iron mine",
		-- PLAN3 §4.1: no tiebreak string (sorts compare name_lower, then id); §4.2: parsed name and status.
		name_parts = { text = "Iron Mine" },
		status = "saturated",
		surface_index = 1,
		network_name = "signal-A",
		network_mask = 1,
		is_p = true,
		is_r = false,
		is_stack = false,
		comb_ok = true,
		warming_up = false,
		trains_limit = 2,
		deliveries_total = 3,
		last_delivery_tick = 700,
		priority = 5,
		provided = { ["iron-ore"] = 500, water = 2000 },
		requested = {},
		deliveries = { ["iron-ore"] = -400 },
		control = { ["cybersyn-priority"] = 3 },
		control2 = {},
		thresholds = {},
		wait = {},
		secondary = false,
		secondary_count = 0,
		-- PLAN3 §4.2 (phase 2): when the record was read, and the lint bitmask (0 until phase 2b).
		read_tick = 1000,
		lint = 0,
	})
	-- Copied, not shared, so the planner's later writes do not leak into the snapshot.
	assert_true(snap.stations[1].deliveries ~= storage.stations[1].deliveries)
end)

test("full pass: requester record with thresholds, control combinator and waits", function()
	scenario()
	collector.run_to_completion()
	local st = collector.get().stations[2]
	assert_eq(st.requested, {
		["iron-ore"] = { count = -1000, threshold = 500, active = true, mask = 1 },
		["copper-ore"] = { count = -100, threshold = 50, active = true, mask = 1 },
		coal = { count = -800, threshold = 500, active = true, mask = 1 },
		-- No fluid threshold anywhere: the item threshold applies to fluids.
		water = { count = -50, threshold = 500, active = false, mask = 1 },
	})
	assert_eq(st.provided, {})
	assert_eq(st.control, {})
	assert_eq(st.control2, { [REQUEST_THRESHOLD] = 7 })
	assert_eq(st.thresholds, { ["iron-ore"] = 300, ["copper-ore|rare"] = 20 })
	assert_true(st.comb2_ok)
	assert_eq(st.wait, { ["iron-ore"] = 50, coal = 20, ["copper-ore"] = 5 })
	assert_eq(st.longest_wait_start, 5)
	assert_eq(st.trains_limit, 0)
	assert_eq(st.deliveries_total, 0)
	assert_nil(st.last_delivery_tick)
end)

test("full pass: warming up, each-network stack station, skipped and secondary stations", function()
	scenario()
	collector.run_to_completion()
	local snap = collector.get()
	local warm = snap.stations[3]
	assert_true(warm.warming_up)
	assert_true(warm.comb_ok)
	assert_eq(warm.requested, { stone = { count = -5000, threshold = 2000, active = true, mask = 1 } })
	local each = snap.stations[4]
	assert_eq(each.surface_index, 2)
	assert_eq(each.requested, {
		stone = { count = -60, threshold = 100, active = false },
		coal = { count = -200, threshold = 100, active = true },
	})
	assert_eq(each.control, { ["signal-B"] = 1 })
	assert_eq(each.network_mask, { ["signal-A"] = 1, ["signal-B"] = 2 })
	assert_true(each.network_mask ~= storage.stations[4].network_mask)
	assert_nil(snap.stations[5])
	local sec = snap.stations[6]
	assert_false(sec.comb_ok)
	assert_true(sec.secondary)
	assert_eq(sec.secondary_count, 1)
	assert_eq(sec.provided, { ["iron-plate"] = 100 })
	assert_eq(sec.requested, { ["copper-plate"] = { count = -30, threshold = 20, active = true, mask = 1 } })
	assert_eq(sec.control, {})
	assert_eq(snap.station_count, 5)
	assert_eq(snap.secondary_count, 1)
	assert_eq(snap.tick, 1000)
	assert_eq(snap.started_tick, 1000)
end)

test("full pass: inventory_all sums active requests and incoming deliveries only", function()
	scenario()
	collector.run_to_completion()
	local inv = collector.get().inventory_all
	assert_eq(inv.provided, {
		["iron-ore"] = { count = 500, stations = 1 },
		water = { count = 2000, stations = 1 },
		["iron-plate"] = { count = 100, stations = 1 },
	})
	assert_eq(inv.requested, {
		["iron-ore"] = { count = -1000, stations = 1, earliest_wait_start = 50 },
		["copper-ore"] = { count = -100, stations = 1, earliest_wait_start = 5 },
		coal = { count = -1000, stations = 2, earliest_wait_start = 20 },
		-- Warming-up stations still count here, although they are not keyed for starvation.
		stone = { count = -5000, stations = 1 },
		["copper-plate"] = { count = -30, stations = 1 },
	})
	assert_eq(inv.in_transit, { ["iron-ore"] = { count = 400, stations = 1 } })
end)

test("full pass: starved keys per network, each-network stations on all their networks", function()
	scenario()
	collector.run_to_completion()
	local snap = collector.get()
	assert_eq(snap.starved, {
		["signal-A:coal"] = true,
		["signal-B:coal"] = true,
		["signal-A:copper-ore"] = true,
		["signal-B:copper-plate"] = true,
	})
	assert_eq(snap.starved_items, { coal = true, ["copper-ore"] = true, ["copper-plate"] = true })
	assert_eq(snap.starved_source, "snapshot")
	assert_eq(snap.starved_version, 1)
end)

test("full pass: trains, fleet, depots and alerts", function()
	scenario()
	collector.run_to_completion()
	local snap = collector.get()
	assert_eq(H.keys(snap.trains), { 10, 12 })
	assert_eq(snap.trains[10], {
		id = 10,
		status = STATUS_TO_P,
		layout_id = 1,
		depot_id = 100,
		depot_name = "Depot 1",
		network_name = "signal-A",
		network_mask = 1,
		p_station_id = 1,
		r_station_id = 2,
		manifest = {
			{ name = "iron-ore", count = 200, hash = "iron-ore" },
			{ name = "iron-ore", quality = "rare", count = 5, hash = "iron-ore|rare" },
			{ name = "iron-ore", count = 50, hash = "iron-ore" },
		},
		manifest_hashes = { ["iron-ore"] = 250, ["iron-ore|rare"] = 5 },
		surface_index = 1,
		is_available = false,
		-- PLAN3 §4.2 (phase 2); the stub entity has no state, signal or path, so only the cached flag shows.
		in_interrupt = false,
		in_group = false,
	})
	local t12 = snap.trains[12]
	assert_eq(t12.depot_name, "")
	assert_eq(t12.surface_index, 2)
	assert_true(t12.is_available)
	assert_nil(t12.status)
	assert_eq(t12.manifest, {})
	assert_eq(snap.train_count, 2)
	assert_eq(snap.fleet, {
		total = 2,
		by_status = { [STATUS_TO_P] = 1, [STATUS_D] = 1 },
		available_by_network = { ["signal-A"] = 1 },
		by_layout = { [1] = 1 },
		min_available_by_network = {},
		-- Phase 2b: per network and layout (train 12 has no layout yet: 0), and the OR of the masks.
		capability = { ["signal-A"] = {
			[1] = { count = 1, item_capacity = 0, fluid_capacity = 0, mask_or = 1 },
			[0] = { count = 1, item_capacity = 0, fluid_capacity = 0, mask_or = 1 },
		} },
		mask_or = { ["signal-A"] = 1 },
		in_interrupt_count = {},
		not_refuelled_count = {},
		group_depots = {},
	})
	assert_eq(snap.depots, { total = 2, parked = 1 })
	-- Depot 101's stop is invalid; train 12's depot has no name, so only Depot 1 forms a group.
	assert_eq(snap.depots_by_name, { ["Depot 1"] = { ids = { 100 }, limit = 1, count = 0, parked = 0, inbound = 0,
		trains_bound = 1, compositions = { [1] = 1 }, same_depot_bypass = 1 } })
	-- tps 30 = 2 ticks per main tick: alert raised 10 main ticks ago.
	assert_eq(snap.alerts, { { train_id = 10, kind = 2, since_tick = 980 }, { train_id = 12, kind = 3, since_tick = 1000 } })
end)

test("alerts: tps 0 means one tick per main tick", function()
	scenario()
	mod_settings.tps = 0
	collector.run_to_completion()
	assert_eq(collector.get().alerts[1].since_tick, 990)
end)

test("passes: change log, removed stations, stable starved set", function()
	scenario()
	collector.run_to_completion()
	local log = storage.manager.collect_log
	assert_eq(log, { epoch = 1, base = 0, ids = { 1, 2, 3, 4, 6 } })
	assert_eq({ collector.log_position() }, { 1, 5 })
	local starved = collector.get().starved
	game.tick = 1100
	collector.run_to_completion()
	log = storage.manager.collect_log
	assert_eq(log, { epoch = 1, base = 5, ids = { 1, 2, 3, 4, 6 } })
	assert_eq({ select(2, collector.changed_since(1, 5)) }, { 1, 5 })
	assert_nil(collector.changed_since(1, 0))
	local snap = collector.get()
	assert_same(snap.starved, starved)
	assert_eq(snap.starved_version, 1)
	assert_eq(snap.tick, 1100)
	storage.stations[3] = nil
	collector.run_to_completion()
	snap = collector.get()
	assert_eq(storage.manager.collect_log.ids, { 1, 2, 4, 6, 3 })
	assert_nil(snap.stations[3])
	assert_eq(snap.station_count, 4)
	assert_eq(snap.starved_version, 1)
	storage.stations[2] = nil
	collector.run_to_completion()
	snap = collector.get()
	assert_eq(snap.starved, { ["signal-A:coal"] = true, ["signal-B:coal"] = true, ["signal-B:copper-plate"] = true })
	assert_eq(snap.starved_version, 2)
end)

test("economy: while dispatching, the planner's own r/p stops define starved", function()
	scenario()
	storage.tick_state = STATE_DISPATCH
	storage.economy = {
		all_r_stops = { ["signal-A:coal"] = {}, ["signal-A:iron-ore"] = {} },
		all_p_stops = { ["signal-A:iron-ore"] = {} },
	}
	collector.run_to_completion()
	local snap = collector.get()
	assert_eq(snap.starved, { ["signal-A:coal"] = true })
	assert_eq(snap.starved_items, { coal = true })
	assert_eq(snap.starved_source, "economy")
	assert_eq(snap.starved_version, 1)
end)

test("empty starved sets compare equal, so the version stays 0", function()
	mod_settings = {}
	manager()
	storage.stations, storage.trains, storage.depots = {}, {}, {}
	collector.run_to_completion()
	local snap = collector.get()
	assert_eq(snap.tick, 0)
	assert_eq(snap.starved_version, 0)
	assert_eq(snap.station_count, 0)
end)

test("step: unbudgeted steps list, then summarise trains, then collect a batch", function()
	scenario()
	assert_false(collector.step())
	local b = storage.manager.snapshot_build
	assert_eq(b.ids, { 1, 2, 3, 4, 5, 6 })
	assert_eq(b.i, 0)
	assert_true(b.trains_pending)
	assert_eq(collector.get().train_count, 0)
	assert_false(collector.step())
	assert_nil(b.trains_pending)
	assert_eq(collector.get().train_count, 2)
	-- Six stations fit in the minimum batch of 25.
	assert_true(collector.step())
	assert_nil(storage.manager.snapshot_build)
	assert_same(storage.manager.snapshot, b)
	assert_nil(b.ids)
	assert_nil(b.seen)
	assert_nil(b.r_keys)
end)

test("step: a budget covers listing and trains in the same call", function()
	scenario()
	assert_false(collector.step(2))
	local b = storage.manager.snapshot_build
	assert_eq(b.i, 2)
	assert_eq(H.keys(collector.get().stations), { 1, 2 })
	assert_false(collector.step(3))
	assert_eq(b.i, 5)
	assert_true(collector.step(3))
	assert_eq(collector.get().station_count, 5)
end)

test("step: stations removed mid-pass are skipped", function()
	scenario()
	collector.step(1)
	storage.stations[2] = nil
	collector.run_to_completion()
	assert_eq(collector.get().station_count, 4)
	assert_nil(collector.get().stations[2])
end)

test("batch size: ceil(n / 20) clamped to 25..200", function()
	mod_settings = {}
	manager()
	storage.trains, storage.depots = {}, {}
	storage.stations = {}
	for i = 1, 1000 do
		storage.stations[i] = { entity_stop = stop("S" .. i), entity_comb1 = comb(WORKING, {}), network_name = "signal-A", network_mask = 1 }
	end
	collector.step()
	collector.step()
	collector.step()
	assert_eq(storage.manager.snapshot_build.i, 50)
	for i = 101, 1000 do storage.stations[i] = nil end
	storage.manager.snapshot_build = nil
	collector.step()
	collector.step()
	collector.step()
	assert_eq(storage.manager.snapshot_build.i, 25)
	for i = 101, 5000 do
		storage.stations[i] = { entity_stop = stop("S" .. i), entity_comb1 = comb(WORKING, {}), network_name = "signal-A", network_mask = 1 }
	end
	storage.manager.snapshot_build = nil
	collector.step()
	collector.step()
	collector.step()
	assert_eq(storage.manager.snapshot_build.i, 200)
end)

-- PLAN3 §4.1: opening no longer collects synchronously; a missing or stale snapshot gets a boosted pass instead.
test("ensure_fresh: never collected or older than 600 ticks boosts the next passes, nothing synchronous", function()
	scenario()
	storage.manager.players[1] = { is_manager_open = true }
	collector.ensure_fresh()
	assert_nil(collector.get().tick)
	assert_true(storage.manager.collect_boost)
	assert_eq(collector.collecting(), 0)
	-- The first boosted step lists the stations and summarises the trains, with no stations on top.
	assert_true(collector.tick())
	assert_nil(collector.get().tick)
	assert_eq(collector.collecting(), 0)
	-- Six stations fit the next boosted step (4 x the minimum batch).
	assert_true(collector.tick())
	assert_eq(collector.get().tick, 1000)
	assert_nil(storage.manager.collect_boost)
	assert_nil(collector.collecting())
	game.tick = 1600
	collector.ensure_fresh()
	assert_nil(storage.manager.collect_boost)
	game.tick = 1601
	collector.ensure_fresh()
	assert_true(storage.manager.collect_boost)
	assert_eq(collector.get().tick, 1000)
	-- A pass in progress that started long ago is dropped; a recent one is kept and boosted.
	storage.manager.snapshot_build = { started_tick = 1000, stale = true }
	collector.ensure_fresh()
	assert_nil(storage.manager.snapshot_build)
	collector.step()
	local b = storage.manager.snapshot_build
	collector.ensure_fresh()
	assert_same(storage.manager.snapshot_build, b)
end)

test("collecting: progress of the boosted pass", function()
	scenario()
	storage.manager.players[1] = { is_manager_open = true }
	for id = 7, 106 do
		storage.stations[id] = { entity_stop = stop("S" .. id), entity_comb1 = comb(WORKING, {}), network_name = "signal-A", network_mask = 1 }
	end
	collector.ensure_fresh()
	-- 106 stations: default batch 25, boosted 100, after a first step that only lists them and the trains.
	assert_false(collector.step(nil, 4))
	assert_eq(collector.collecting(), 0)
	assert_false(collector.step(nil, 4))
	assert_eq(collector.collecting(), 100 / 106)
	assert_true(collector.tick())
	assert_eq(collector.get().tick, 1000)
	assert_nil(collector.collecting())
end)

test("aggregate: provided, active requests and incoming deliveries over the accepted stations", function()
	local snapshot = collector.empty()
	snapshot.stations = {
		[1] = {
			provided = { coal = 10 },
			requested = { stone = { count = -5, active = true }, water = { count = -1, active = false } },
			deliveries = { coal = -3, stone = 4 },
			wait = { stone = 30 },
			surface_index = 1,
		},
		[2] = {
			provided = { coal = 5 },
			requested = { stone = { count = -7, active = true } },
			deliveries = { stone = 6 },
			wait = { stone = 20 },
			surface_index = 2,
		},
		[3] = {
			provided = {},
			requested = { stone = { count = -1, active = true } },
			deliveries = {},
			wait = {},
			surface_index = 1,
		},
	}
	assert_eq(collector.aggregate(snapshot, function() return true end), {
		provided = { coal = { count = 15, stations = 2 } },
		requested = { stone = { count = -13, stations = 3, earliest_wait_start = 20 } },
		in_transit = { stone = { count = 10, stations = 2 } },
	})
	assert_eq(collector.aggregate(snapshot, function(st) return st.surface_index == 1 end), {
		provided = { coal = { count = 10, stations = 1 } },
		requested = { stone = { count = -6, stations = 2, earliest_wait_start = 30 } },
		in_transit = { stone = { count = 4, stations = 1 } },
	})
	assert_eq(collector.aggregate(snapshot, function() return false end), { provided = {}, requested = {}, in_transit = {} })
end)

test("wait tracking off: no wait data copied", function()
	scenario()
	mod_settings.track_request_wait_times = false
	collector.run_to_completion()
	local st = collector.get().stations[2]
	assert_eq(st.wait, {})
	assert_nil(st.longest_wait_start)
	assert_nil(collector.get().inventory_all.requested.coal.earliest_wait_start)
end)

test("thresholds: a request exactly at its threshold is active", function()
	mod_settings = { r_threshold = 500 }
	manager()
	storage.trains, storage.depots = {}, {}
	storage.stations = {
		[1] = {
			entity_stop = stop("R"),
			entity_comb1 = comb(WORKING, { sig("coal", -500), sig("stone", -499), sig("water", -40, "fluid") }),
			network_name = "signal-A",
			network_mask = 1,
			is_r = true,
			r_fluid_threshold = 40,
		},
	}
	collector.run_to_completion()
	assert_eq(collector.get().stations[1].requested, {
		coal = { count = -500, threshold = 500, active = true, mask = 1 },
		stone = { count = -499, threshold = 500, active = false, mask = 1 },
		water = { count = -40, threshold = 40, active = true, mask = 1 },
	})
end)

test("alerts: tps 25 rounds ticks per main tick up", function()
	scenario()
	mod_settings.tps = 25
	collector.run_to_completion()
	-- ceil(60 / 25) = 3 ticks per main tick, 10 main ticks ago.
	assert_eq(collector.get().alerts[1].since_tick, 970)
end)

-- PLAN3: §4.1 refills the previous record's subtables in place; every changed input must replace the old value.
test("second pass: changed inputs replace every field of the previous record", function()
	scenario()
	collector.run_to_completion()
	local s1, s2, s3 = storage.stations[1], storage.stations[2], storage.stations[3]
	s1.entity_comb1.status = NO_POWER
	s2.entity_comb1.signals = {
		sig("iron-ore", -1000),
		sig("copper-ore", -100),
		sig("stone", -700),
		sig("water", -50, "fluid"),
	}
	s2.entity_comb2.signals = { sig(REQUEST_THRESHOLD, 9, "virtual"), sig("stone", -200) }
	s2.item_thresholds = { stone = 300 }
	s2.deliveries = { stone = 200 }
	s2.request_start_ticks = { stone = 900, ["iron-ore"] = 60 }
	s2.network_mask = 3
	s3.is_warming_up = nil
	game.tick = 1100
	collector.run_to_completion()
	local snap = collector.get()

	assert_eq(snap.stations[1], {
		id = 1,
		name = "Iron Mine",
		name_lower = "iron mine",
		name_parts = { text = "Iron Mine" },
		status = "no_power",
		surface_index = 1,
		network_name = "signal-A",
		network_mask = 1,
		is_p = true,
		is_r = false,
		is_stack = false,
		comb_ok = false,
		warming_up = false,
		trains_limit = 2,
		deliveries_total = 3,
		last_delivery_tick = 700,
		priority = 5,
		provided = {},
		requested = {},
		deliveries = { ["iron-ore"] = -400 },
		control = {},
		control2 = {},
		thresholds = {},
		wait = {},
		secondary = false,
		secondary_count = 0,
		-- PLAN3 §4.2 (phase 2): when the record was read, and the lint bitmask (0 until phase 2b).
		read_tick = 1100,
		lint = 0,
	})
	assert_eq(snap.stations[2], {
		id = 2,
		name = "Smelter",
		name_lower = "smelter",
		name_parts = { text = "Smelter" },
		status = "disabled",
		surface_index = 1,
		network_name = "signal-A",
		network_mask = 3,
		is_p = false,
		is_r = true,
		is_stack = false,
		comb_ok = true,
		comb2_ok = true,
		warming_up = false,
		trains_limit = 0,
		deliveries_total = 0,
		provided = {},
		requested = {
			["iron-ore"] = { count = -1000, threshold = 500, active = true, mask = 3 },
			["copper-ore"] = { count = -100, threshold = 500, active = false, mask = 3 },
			stone = { count = -700, threshold = 300, active = true, mask = 3 },
			water = { count = -50, threshold = 500, active = false, mask = 3 },
		},
		deliveries = { stone = 200 },
		control = {},
		control2 = { [REQUEST_THRESHOLD] = 9 },
		thresholds = { stone = 200 },
		wait = { stone = 900, ["iron-ore"] = 60 },
		longest_wait_start = 60,
		secondary = false,
		secondary_count = 0,
		-- PLAN3 §4.2 (phase 2): when the record was read, and the lint bitmask (0 until phase 2b).
		read_tick = 1100,
		lint = 0,
	})
	assert_eq(snap.stations[3].warming_up, false)
	assert_eq(snap.stations[3].requested, { stone = { count = -5000, threshold = 2000, active = true, mask = 1 } })

	-- The refilled record still owns its tables: later planner writes must not show through.
	local rec = snap.stations[2]
	assert_true(rec.deliveries ~= s2.deliveries)
	assert_true(rec.wait ~= s2.request_start_ticks)
	assert_true(rec.thresholds ~= s2.item_thresholds)
	s2.deliveries.stone = 999
	s2.request_start_ticks.stone = 1
	assert_eq(rec.deliveries, { stone = 200 })
	assert_eq(rec.wait.stone, 900)

	assert_eq(snap.inventory_all, {
		provided = { ["iron-plate"] = { count = 100, stations = 1 } },
		requested = {
			["iron-ore"] = { count = -1000, stations = 1, earliest_wait_start = 60 },
			stone = { count = -5700, stations = 2, earliest_wait_start = 900 },
			coal = { count = -200, stations = 1 },
			["copper-plate"] = { count = -30, stations = 1 },
		},
		in_transit = { stone = { count = 200, stations = 1 } },
	})
	assert_eq(snap.starved, {
		["signal-A:iron-ore"] = true,
		["signal-A:stone"] = true,
		["signal-A:coal"] = true,
		["signal-B:coal"] = true,
		["signal-B:copper-plate"] = true,
	})
	assert_eq(snap.starved_items, { ["iron-ore"] = true, stone = true, coal = true, ["copper-plate"] = true })
	assert_eq(snap.starved_version, 2)
	assert_eq(snap.station_count, 5)
	assert_eq(storage.manager.collect_log, { epoch = 1, base = 5, ids = { 1, 2, 3, 4, 6 } })
end)

-- Primary and secondary combinators contributing to the same hashes, each-network secondaries, a stack station with
-- a control combinator and two requesters of one item with different wait starts.
local function merge_scenario()
	mod_settings = { r_threshold = 2000, r_fluid_threshold = 0, track_request_wait_times = true, tps = 30 }
	manager()
	storage.stations = {
		[1] = {
			entity_stop = stop("Merge"),
			entity_comb1 = comb(WORKING, { sig("iron-ore", -80), sig("copper-ore", 40), sig("signal-A", 1, "virtual") }),
			secondary_inv_combs = {
				comb(WORKING, {
					sig("iron-ore", -50),
					sig("copper-ore", 60),
					sig("water", -15, "fluid"),
					sig(REQUEST_THRESHOLD, 40, "virtual"),
					sig(REQUEST_FLUID_THRESHOLD, 10, "virtual"),
					sig(SIGNAL_PRIORITY, 2, "virtual"),
					sig("signal-B", 1, "virtual"),
				}),
				comb(WORKING, { sig("iron-ore", -30), sig("copper-ore", 5) }),
			},
			network_name = NETWORK_EACH,
			network_mask = { ["signal-A"] = 1 },
			is_p = true,
			is_r = true,
			r_threshold = 100,
		},
		[2] = {
			entity_stop = stop("Stack"),
			entity_comb1 = comb(WORKING, { sig("stone", -150) }),
			entity_comb2 = comb(WORKING, {
				sig("stone", -3),
				sig("iron-plate", 2),
				sig("water", -7, "fluid"),
				sig(REQUEST_THRESHOLD, 4, "virtual"),
			}),
			network_name = "signal-A",
			network_mask = 1,
			is_r = true,
			is_stack = true,
			r_threshold = 2,
		},
		[3] = {
			entity_stop = stop("Unpowered control"),
			entity_comb1 = comb(WORKING, { sig("coal", -10) }),
			entity_comb2 = comb(NO_POWER, { sig("stone", -3), sig(REQUEST_THRESHOLD, 4, "virtual") }),
			network_name = "signal-A",
			network_mask = 1,
			is_r = true,
			r_threshold = 5,
			request_start_ticks = { coal = 10 },
		},
		[4] = {
			entity_stop = stop("Coal 2"),
			entity_comb1 = comb(WORKING, { sig("coal", -20) }),
			network_name = "signal-A",
			network_mask = 1,
			is_r = true,
			r_threshold = 5,
			request_start_ticks = { coal = 30 },
		},
	}
	storage.trains, storage.depots = {}, {}
	storage.tick_state = STATE_POLL_STATIONS
	game.tick = 1000
end

test("merge: primary and secondaries sum counts, keep the lowest threshold and OR the active flags", function()
	merge_scenario()
	collector.run_to_completion()
	local st = collector.get().stations[1]
	assert_eq(st.provided, { ["copper-ore"] = 105 })
	assert_eq(st.requested, {
		-- -80 below 100 (primary), -50 above 40 (first secondary), -30 below 100 (second secondary).
		["iron-ore"] = { count = -160, threshold = 40, active = true },
		-- The secondary's own fluid threshold applies to its fluid requests.
		water = { count = -15, threshold = 10, active = true },
	})
	assert_eq(st.control, { ["signal-A"] = 1 })
	assert_true(st.comb_ok)
	assert_nil(st.comb2_ok)
	assert_true(st.secondary)
	assert_eq(st.secondary_count, 2)
	assert_eq(collector.get().secondary_count, 1)
end)

test("merge: each-network secondaries key on their own network signals, not on settings signals", function()
	merge_scenario()
	collector.run_to_completion()
	local snap = collector.get()
	-- The primary's iron-ore request is below threshold, so only the secondary's signal-B request is keyed; its
	-- priority signal is a setting, not a network.
	assert_eq(snap.starved, {
		["signal-B:iron-ore"] = true,
		["signal-B:water"] = true,
		["signal-A:stone"] = true,
		["signal-A:coal"] = true,
	})
	assert_eq(snap.starved_items, { ["iron-ore"] = true, water = true, stone = true, coal = true })
end)

test("control combinator: stack stations multiply item thresholds, an unpowered one reads nothing", function()
	merge_scenario()
	collector.run_to_completion()
	local snap = collector.get()
	local stack = snap.stations[2]
	assert_true(stack.comb2_ok)
	assert_eq(stack.thresholds, { stone = 150, ["iron-plate"] = 200, water = 7 })
	assert_eq(stack.control2, { [REQUEST_THRESHOLD] = 4 })
	assert_eq(stack.requested, { stone = { count = -150, threshold = 100, active = true, mask = 1 } })
	local unpowered = snap.stations[3]
	assert_false(unpowered.comb2_ok)
	assert_eq(unpowered.thresholds, {})
	assert_eq(unpowered.control2, {})
	assert_eq(unpowered.requested, { coal = { count = -10, threshold = 5, active = true, mask = 1 } })
end)

test("merge: inventory_all keeps the earliest wait start across requesters", function()
	merge_scenario()
	collector.run_to_completion()
	assert_eq(collector.get().inventory_all, {
		provided = { ["copper-ore"] = { count = 105, stations = 1 } },
		requested = {
			["iron-ore"] = { count = -160, stations = 1 },
			water = { count = -15, stations = 1 },
			stone = { count = -150, stations = 1 },
			coal = { count = -30, stations = 2, earliest_wait_start = 10 },
		},
		in_transit = {},
	})
end)

test("longest_wait_start: the earliest start over active requests, whatever the hash order", function()
	mod_settings = { r_threshold = 10, track_request_wait_times = true }
	manager()
	storage.trains, storage.depots = {}, {}
	local function requester(name, waits)
		return {
			entity_stop = stop(name),
			entity_comb1 = comb(WORKING, { sig("coal", -100), sig("stone", -100), sig("iron-ore", -5) }),
			network_name = "signal-A",
			network_mask = 1,
			is_r = true,
			request_start_ticks = waits,
		}
	end
	-- Both records build `requested` from the same signals in the same order, so they iterate it in the same order
	-- and one of them has its earliest start last.
	storage.stations = {
		[1] = requester("A", { coal = 10, stone = 20, ["iron-ore"] = 1 }),
		[2] = requester("B", { coal = 20, stone = 10, ["iron-ore"] = 1 }),
	}
	collector.run_to_completion()
	local snap = collector.get()
	-- iron-ore is below the threshold, so its earlier start does not count.
	assert_eq(snap.stations[1].longest_wait_start, 10)
	assert_eq(snap.stations[2].longest_wait_start, 10)
end)

-- ---------------------------------------------------------------- PLAN3 §4.1/§4.2: in-place refill, status, names

test("refill: unchanged inputs keep the record and every subtable, and allocate no new request tables", function()
	scenario()
	collector.run_to_completion()
	local snap = collector.get()
	local before = {}
	for id, st in pairs(snap.stations) do
		before[id] = {
			st = st, provided = st.provided, requested = st.requested, deliveries = st.deliveries, control = st.control,
			control2 = st.control2, thresholds = st.thresholds, wait = st.wait, mask = st.network_mask,
			parts = st.name_parts, reqs = H.copy(st.requested),
		}
		before[id].req_tables = {}
		for hash, req in pairs(st.requested) do before[id].req_tables[hash] = req end
	end
	local trains = snap.trains
	local train10, manifest10 = trains[10], trains[10].manifest
	game.tick = 1100
	collector.run_to_completion()
	snap = collector.get()
	assert_same(snap.trains, trains)
	assert_same(snap.trains[10], train10)
	assert_same(snap.trains[10].manifest, manifest10)
	for id, b in pairs(before) do
		local st = snap.stations[id]
		assert_same(st, b.st, "record " .. id)
		for _, field in ipairs({ "provided", "requested", "deliveries", "control", "control2", "thresholds", "wait" }) do
			assert_same(st[field], b[field], field .. " of " .. id)
		end
		assert_same(st.network_mask, b.mask, "mask of " .. id)
		assert_same(st.name_parts, b.parts, "name_parts of " .. id)
		assert_eq(st.requested, b.reqs)
		for hash, req in pairs(st.requested) do assert_same(req, b.req_tables[hash]) end
	end
end)

test("refill: removed entries go, new ones arrive, and a changed manifest or mask is copied again", function()
	scenario()
	collector.run_to_completion()
	local snap = collector.get()
	local smelter = snap.stations[2]
	local requested = smelter.requested
	local each_mask = snap.stations[4].network_mask
	local s2 = storage.stations[2]
	s2.entity_comb1.signals = { sig("iron-ore", -1000), sig("gravel", -900) }
	s2.deliveries = { gravel = 50 }
	storage.stations[4].network_mask = { ["signal-A"] = 1, ["signal-B"] = 4 }
	storage.trains[10].manifest = { { name = "coal", count = 1 } }
	local old_manifest = snap.trains[10].manifest
	game.tick = 1100
	collector.run_to_completion()
	snap = collector.get()
	assert_same(snap.stations[2], smelter)
	assert_same(smelter.requested, requested)
	assert_eq(smelter.requested, {
		["iron-ore"] = { count = -1000, threshold = 500, active = true, mask = 1 },
		gravel = { count = -900, threshold = 500, active = true, mask = 1 },
	})
	assert_eq(smelter.deliveries, { gravel = 50 })
	assert_eq(smelter.thresholds, { ["iron-ore"] = 300, ["copper-ore|rare"] = 20 })
	assert_eq(snap.stations[4].network_mask, { ["signal-A"] = 1, ["signal-B"] = 4 })
	assert_true(snap.stations[4].network_mask ~= each_mask)
	assert_true(snap.stations[4].network_mask ~= storage.stations[4].network_mask)
	assert_true(snap.trains[10].manifest ~= old_manifest)
	assert_eq(snap.trains[10].manifest_hashes, { coal = 1 })
	storage.trains[12] = nil
	collector.run_to_completion()
	assert_nil(collector.get().trains[12])
	assert_eq(collector.get().train_count, 1)
end)

test("name_parts: parsed on first sight and again only after a rename", function()
	scenario()
	storage.stations[1].entity_stop.backer_name = "[item=iron-ore] Iron Mine [virtual-signal=signal-P]"
	collector.run_to_completion()
	local st = collector.get().stations[1]
	assert_eq(st.name_parts, { lead = { "item/iron-ore" }, text = "Iron Mine", tail = { "virtual-signal/signal-P" } })
	assert_eq(st.name_lower, "[item=iron-ore] iron mine [virtual-signal=signal-p]")
	local parts = st.name_parts
	collector.run_to_completion()
	assert_same(st.name_parts, parts)
	storage.stations[1].entity_stop.backer_name = "Iron Mine 2"
	collector.run_to_completion()
	assert_eq(st.name, "Iron Mine 2")
	assert_eq(st.name_lower, "iron mine 2")
	assert_eq(st.name_parts.text, "Iron Mine 2")
end)

test("name_parts: one shared table per distinct name, dropped with the snapshot", function()
	scenario()
	storage.stations[2].entity_stop.backer_name = storage.stations[1].entity_stop.backer_name
	collector.run_to_completion()
	local snap = collector.get()
	assert_same(snap.stations[1].name_parts, snap.stations[2].name_parts)
	assert_same(storage.manager.name_parts[snap.stations[1].name], snap.stations[1].name_parts)
	storage.manager.players = {}
	collector.release_if_unused()
	assert_nil(storage.manager.name_parts)
end)

local function ladder_station(over)
	local st = {
		comb_ok = true, trains_limit = 2, warming_up = false, deliveries_total = 0, network_name = "signal-A",
		network_mask = 1, requested = {}, last_delivery_tick = nil,
	}
	for k, v in pairs(over or {}) do st[k] = v end
	return st
end

test("station_status: the ladder, first match wins", function()
	mod_settings = { tps = 60 }
	storage.total_ticks = 200000
	local starved = { ["signal-A:coal"] = true }
	local coal = { coal = { count = -5, threshold = 1, active = true } }
	local s = collector.station_status
	assert_eq(collector.STATUSES, { "no_power", "disabled", "warming_up", "starved", "saturated", "idle", "ok" })
	-- Each rung beats every rung below it.
	assert_eq(s(ladder_station({ comb_ok = false, trains_limit = 0, warming_up = true, requested = coal }), starved), "no_power")
	assert_eq(s(ladder_station({ trains_limit = 0, warming_up = true, requested = coal }), starved), "disabled")
	assert_eq(s(ladder_station({ warming_up = true, requested = coal, deliveries_total = 5 }), starved), "warming_up")
	assert_eq(s(ladder_station({ requested = coal, deliveries_total = 5 }), starved), "starved")
	assert_eq(s(ladder_station({ deliveries_total = 2 }), starved), "saturated")
	assert_eq(s(ladder_station({ last_delivery_tick = 1 }), starved), "idle")
	assert_eq(s(ladder_station(), starved), "ok")
end)

test("station_status: saturated means deliveries at a finite limit, nothing else", function()
	mod_settings = { tps = 60 }
	storage.total_ticks = 0
	local s = collector.station_status
	assert_eq(s(ladder_station({ trains_limit = 3, deliveries_total = 3 }), {}), "saturated")
	assert_eq(s(ladder_station({ trains_limit = 3, deliveries_total = 4 }), {}), "saturated")
	assert_eq(s(ladder_station({ trains_limit = 3, deliveries_total = 2 }), {}), "ok")
	-- The Overview used to count these two as saturated too (B2).
	assert_eq(s(ladder_station({ trains_limit = 0, deliveries_total = 1 }), {}), "disabled")
	assert_eq(s(ladder_station({ trains_limit = 4294967295, deliveries_total = 9 }), {}), "ok")
	assert_eq(s(ladder_station({ trains_limit = collector.UNLIMITED - 1, deliveries_total = collector.UNLIMITED }), {}), "saturated")
end)

test("station_status: starved needs an active request without a provider on one of its networks", function()
	mod_settings = { tps = 60 }
	storage.total_ticks = 0
	local s = collector.station_status
	local inactive = { coal = { count = -5, threshold = 10, active = false } }
	local active = { coal = { count = -5, threshold = 1, active = true } }
	assert_eq(s(ladder_station({ requested = inactive }), { ["signal-A:coal"] = true }), "ok")
	assert_eq(s(ladder_station({ requested = active }), { ["signal-B:coal"] = true }), "ok")
	assert_eq(s(ladder_station({ network_name = false, requested = active }), { ["signal-A:coal"] = true }), "ok")
	local each = { network_name = NETWORK_EACH, network_mask = { ["signal-B"] = 1, ["signal-C"] = 2 }, requested = active }
	assert_eq(s(ladder_station(each), { ["signal-C:coal"] = true }), "starved")
	assert_eq(s(ladder_station(each), { ["signal-A:coal"] = true }), "ok")
	assert_eq(collector.starved_hashes(ladder_station(each), { ["signal-C:coal"] = true }), { "coal" })
	assert_false(collector.starved_hashes(ladder_station(each), {}))
end)

test("status: set once per pass, and a changed starved set reclassifies and logs the affected stations", function()
	scenario()
	collector.run_to_completion()
	local snap = collector.get()
	local status = {}
	for id, st in pairs(snap.stations) do status[id] = st.status end
	-- No train limit set reads as 0, i.e. disabled.
	assert_eq(status, { [1] = "saturated", [2] = "disabled", [3] = "disabled", [4] = "disabled", [6] = "no_power" })
	-- Smelter requests coal on signal-A, which nobody provides.
	storage.stations[2].trains_limit = 3
	storage.stations[4].trains_limit = 3
	game.tick = 1100
	collector.run_to_completion()
	assert_eq(collector.get().stations[2].status, "starved")
	-- Providers of coal and copper ore on signal-A appear: the finish of that pass sees the new set and reclassifies.
	storage.stations[1].entity_comb1.signals = { sig("coal", 5000), sig("iron-ore", 500), sig("copper-ore", 500) }
	game.tick = 1200
	collector.run_to_completion()
	snap = collector.get()
	assert_eq(snap.stations[2].status, "ok")
	-- Each still lacks coal on signal-B.
	assert_eq(snap.stations[4].status, "starved")
	local log = storage.manager.collect_log.ids
	assert_eq(log[#log], 2)
end)

test("fleet: train groups count the depot names of their Cybersyn trains", function()
	scenario()
	storage.trains[10].entity.group = "G"
	storage.trains[12].entity.group = "G"
	storage.trains[12].depot_id = 100
	storage.trains[13] = { entity = { valid = true, group = "H", front_stock = { surface_index = 1 } }, depot_id = 100,
		network_name = "signal-A", network_mask = 1, status = STATUS_D }
	storage.depots[101].entity_stop = { valid = true, backer_name = "Depot 2", trains_limit = 1, trains_count = 0 }
	storage.trains[13].depot_id = 101
	collector.run_to_completion()
	local snap = collector.get()
	assert_eq(snap.fleet.group_depots, { G = 1, H = 1 })
	assert_eq({ snap.trains[10].in_group, snap.trains[10].group, snap.trains[13].group }, { true, "G", "H" })
	storage.trains[13].entity.group = "G"
	collector.run_to_completion()
	assert_eq(collector.get().fleet.group_depots, { G = 2 })
end)

test("fleet: a Cybersyn train whose depot has no name does not count as another depot name", function()
	scenario()
	storage.trains[10].entity.group = "G"
	storage.trains[12].entity.group = "G"
	collector.run_to_completion()
	local snap = collector.get()
	assert_eq(snap.trains[12].depot_name, "")
	assert_eq(snap.fleet.group_depots, { G = 1 })
end)

test("provider keys: the providers' masks OR-ed and their lowest item threshold per network:item", function()
	scenario()
	storage.stations[1].item_thresholds = { ["iron-ore"] = 300, water = 1500 }
	storage.stations[5].entity_comb1 = comb(WORKING, { sig("iron-ore", 900) })
	storage.stations[5].network_mask = 2
	storage.stations[5].item_thresholds = { ["iron-ore"] = 200 }
	collector.run_to_completion()
	local snap = collector.get()
	assert_eq(snap.provider_masks["signal-A:iron-ore"], 3)
	assert_eq(snap.provider_overrides, { ["signal-A:iron-ore"] = 200, ["signal-A:water"] = 1500 })
	-- In stack mode an item threshold counts stacks; fluids keep their units.
	storage.stations[5].is_stack = true
	storage.stations[5].item_thresholds = { ["iron-ore"] = 2 }
	collector.run_to_completion()
	assert_eq(collector.get().provider_overrides["signal-A:iron-ore"], 2 * get_stack_size(nil, "iron-ore"))
end)

test("secondary combinator on one network: its own mask for what it provides and requests", function()
	scenario()
	-- Station 6 (signal-B, mask 1): its secondary carries signal-B = 2, as the planner reads it for that combinator.
	storage.stations[6].entity_comb1 = comb(WORKING, { sig("iron-plate", 999) })
	storage.stations[6].secondary_inv_combs = {
		comb(WORKING, { sig("coal", 100), sig("copper-plate", -30), sig("signal-B", 2, "virtual"),
			sig(REQUEST_THRESHOLD, 20, "virtual") }),
	}
	collector.run_to_completion()
	local snap = collector.get()
	assert_eq(snap.provider_masks["signal-B:coal"], 2)
	assert_eq(snap.provider_masks["signal-B:iron-plate"], 1)
	assert_eq(snap.stations[6].requested["copper-plate"].mask, 2)
end)
