-- Reason-code scenarios for the planner (PLAN3 §4.5 table, §6 gate 2), built in level scope on layout-dev.
-- run.sh sends this file after lib.lua; it only defines the global `cases`, so it can be loaded at any time.
--
-- Every scenario gets its own row: one straight east-west line on cyb-bench at y = Y0 + ROW * k, far south of
-- the save's world, with its own power, its own Cybersyn network name (a virtual signal nobody else uses) and
-- its own depot and trains. The planner keys everything it compares by network name and the rows share no rail,
-- so the scenarios cannot see each other or the save's trains, and they can all be built at once.
--
-- All stops face west (as in the benchmark world): a train enters one heading west, so the depot is the east end
-- of the line, providers sit west of it and requesters west of the providers. Trains are double headed and are
-- built east of their depot, which they reach on their own. A train that must stay dispatched without moving
-- (a delivery "in progress" that holds a train limit or a station's delivery counter) has its fuel taken out
-- while it waits at the depot: the dispatcher does not look at fuel, and a train without fuel never leaves.
--
-- A constructor returns a case table:
--   name, expect (reason code name), r_station, p_station (unit numbers), item (hash), network, trains (LuaTrain
--   ids), cleanup()
-- plus the fields the runner in 40_reason_codes_test.lua drives:
--   stages      list of {when = fn(case) -> bool, run = fn(case)}; the runner runs at most one stage per planner
--               cycle, each once its `when` holds. The last stage arms the case: it switches on the request
--               under test, so the key (r_station, item) cannot have been evaluated before the scenario is
--               complete.
--   pre(case)   list of {name, ok, detail}: the preconditions that make the scenario what it claims, read from
--               Cybersyn's own tables and the entities after the case has settled.
--   lift(case)  optional: removes the cause; the runner then expects a delivery to r_station.
--   served      true for the control case: the runner expects the delivery and its trip.
--   lift_station  the requester the lift must get served, when it is not r_station (LOST_PRIORITY: the winner).
--   expect_settled  the reason after the flap window when it is not `expect` (a broken schedule makes the
--               planner drop the train; a lost priority is a counter on top of the requester's own reason).
--   kind        "reason" (default) or "counter" (LOST_PRIORITY: lost_n/lost_to, not a reason).
--   expect_ab   {a, b} the payload numbers of the settled entry (PLAN3 §4.5 B1); nil = any; `unordered` = either
--               order; `at = "first"` checks the first sample instead.
--   expect_rej  the TRAIN_FILTERED cause bucket that must count the rejection (TRAIN_MASK, TRAIN_MANUAL,
--               TRAIN_SURFACE), checked where expect_ab is.
--   flap        {from, to}: the dispatcher's own transition the flap rule must hold back (TRAIN_FILTERED_SCHEDULE).
--   no_offer    the scenario's provider does not offer the item at its threshold (common_pre skips that check).

cases = {
	SURFACE = "cyb-bench",
	ISLAND = "rc-island",
	Y0 = 2040,
	ROW = 32,
	X_MIN = 0,
	X_MAX = 330,
	ITEM = "iron-plate",
	ITEM2 = "copper-plate",
	-- Station slots (stop x) from the depot westward.
	X_D1 = 280,
	X_D2 = 240,
	X_P = { 200, 180, 160 },
	X_R = { 120, 100, 80 },
	ORDER = {
		"CONTROL", "NO_PROVIDER", "R_AT_LIMIT", "R_DISABLED", "R_IS_PROVIDING", "LOST_PRIORITY", "P_AT_LIMIT",
		"P_IS_REQUESTING", "MASK_MISMATCH", "NO_SURFACE_ROUTE", "P_BELOW_THRESHOLD", "NO_TRAINS_ON_NETWORK",
		"TRAIN_FILTERED_MANUAL", "TRAIN_FILTERED_MASK", "TRAIN_FILTERED_SCHEDULE", "CAPACITY", "R_LAYOUT",
		"P_LAYOUT", "ALL_IN_INTERRUPT", "LOST_PRIORITY_LO_FIRST",
	},
	-- One unused network name per scenario; signal-A and signal-B belong to the save.
	NETWORKS = {
		CONTROL = "signal-C", NO_PROVIDER = "signal-D", R_AT_LIMIT = "signal-E", R_DISABLED = "signal-F",
		R_IS_PROVIDING = "signal-G", LOST_PRIORITY = "signal-H", P_AT_LIMIT = "signal-I",
		P_IS_REQUESTING = "signal-J", MASK_MISMATCH = "signal-K", NO_SURFACE_ROUTE = "signal-L",
		P_BELOW_THRESHOLD = "signal-M", NO_TRAINS_ON_NETWORK = "signal-N", TRAIN_FILTERED_MANUAL = "signal-O",
		TRAIN_FILTERED_MASK = "signal-P", TRAIN_FILTERED_SCHEDULE = "signal-Q", CAPACITY = "signal-R",
		R_LAYOUT = "signal-S", P_LAYOUT = "signal-T", ALL_IN_INTERRUPT = "signal-U",
		LOST_PRIORITY_LO_FIRST = "signal-V",
	},
}

local MODE_STATION, MODE_DEPOT = "/", "+"
local PR_BOTH, PR_PROVIDE, PR_REQUEST = 0, 1, 2
local ALLOW_ALL = 4
local THRESHOLD = "cybersyn-request-threshold"
local PRIORITY = "cybersyn-priority"
local STATUS_D, STATUS_TO_P = 0, 1

local function read(...)
	return remote.call("cybersyn", "read_global", ...)
end

local function write(value, ...)
	return remote.call("cybersyn", "write_global", value, ...)
end

--- @param surface LuaSurface
--- @param y number row origin
local function generate(surface, y)
	for x = cases.X_MIN - 32, cases.X_MAX + 32, 32 do
		surface.request_to_generate_chunks({ x, y }, 1)
	end
end

--- The second surface NO_SURFACE_ROUTE needs, flat grass like cyb-bench.
--- @return LuaSurface
function cases.island()
	local s = game.surfaces[cases.ISLAND]
	if s then return s end
	s = game.create_surface(cases.ISLAND, {
		default_enable_all_autoplace_controls = false,
		autoplace_settings = {
			tile = { settings = { ["grass-1"] = {} } },
			entity = { settings = {} },
			decorative = { settings = {} },
		},
		property_expression_names = { elevation = "100", moisture = "0", aux = "0" },
		starting_area = 0,
		peaceful_mode = true,
	})
	s.always_day = true
	s.freeze_daytime = true
	return s
end

-- ---- entities ----------------------------------------------------------------------------------------------

local function add(case, e)
	if e then case.entities[#case.entities + 1] = e end
	return e
end

--- Rail, poles and an energy interface for one row.
--- @param case table
--- @param surface LuaSurface
local function lay_row(case, surface)
	local y = case.y
	local force = game.forces.player
	for x = cases.X_MIN, cases.X_MAX, 2 do
		add(case, surface.create_entity({ name = "straight-rail", position = { x + 1, y + 1 },
			direction = defines.direction.east, force = force }))
	end
	for x = cases.X_MIN, cases.X_MAX, 16 do
		add(case, surface.create_entity({ name = "substation", position = { x + 8.5, y - 9.5 }, force = force }))
	end
	local eei = add(case, surface.create_entity({ name = "electric-energy-interface",
		position = { cases.X_MIN + 4, y - 9 }, force = force }))
	if eei then
		eei.power_production = 100e6
		eei.electric_buffer_size = 100e6
		eei.energy = 100e6
	end
end

--- @param list {[1]: string, [2]: integer, [3]: string?}[] {name, count, type}; type defaults to item, or virtual
---   for the network signal and Cybersyn's control signals
--- @return LogisticFilter[]
local function filters(list)
	local out = {}
	for i, s in ipairs(list) do
		local t = s[3] or (prototypes.item[s[1]] and "item") or (prototypes.fluid[s[1]] and "fluid") or "virtual"
		out[i] = { value = { type = t, name = s[1], quality = "normal" }, min = s[2] }
	end
	return out
end

--- Replaces the signals a station's constant combinator sends (the network signal and its mask included).
--- @param st table station record from cases.station
--- @param list table see filters()
function cases.set_signals(st, list)
	local b = st.cc.get_or_create_control_behavior()
	if b.sections_count == 0 then b.add_section() end
	st.signals = list
	b.get_section(1).filters = filters(list)
end

--- Builds a train stop with a Cybersyn combinator and a constant combinator wired to it. The combinator offsets
--- are the benchmark world's: Cybersyn adopts a combinator only if the stop is inside its search box.
--- @param case table
--- @param spec {name: string, x: number, mode: string?, bits: integer?, signals: table?, surface: LuaSurface?, y: number?, limit: integer?}
--- @return {stop: LuaEntity, comb: LuaEntity, cc: LuaEntity, id: integer, name: string}
function cases.station(case, spec)
	local s = spec.surface or case.surface
	local y = (spec.y or case.y) + 1
	local x = spec.x
	local force = game.forces.player
	local stop = add(case, s.create_entity({ name = "train-stop", position = { x, y - 2 },
		direction = defines.direction.west, force = force, raise_built = true }))
	stop.backer_name = spec.name
	if spec.limit then stop.trains_limit = spec.limit end

	local comb = add(case, s.create_entity({ name = "cybersyn-combinator", position = { x + 1.5, y - 4.5 },
		direction = defines.direction.north, force = force }))
	local ctl = comb.get_or_create_control_behavior()
	local params = ctl.parameters
	params.operation = spec.mode or MODE_STATION
	params.first_signal = { type = "virtual", name = case.network }
	params.second_constant = spec.bits or 0
	ctl.parameters = params
	script.raise_script_built({ entity = comb })

	local cc = add(case, s.create_entity({ name = "constant-combinator", position = { x + 1.5, y - 6.5 },
		force = force }))
	local from = cc.get_wire_connector(defines.wire_connector_id.circuit_red, true)
	local to = comb.get_wire_connector(defines.wire_connector_id.combinator_input_red, true)
	from.connect_to(to, false)

	local st = { stop = stop, comb = comb, cc = cc, id = stop.unit_number, name = spec.name }
	cases.set_signals(st, spec.signals or {})
	case.stations[#case.stations + 1] = st
	return st
end

--- A depot on the case's network; `mask` is the trains' network mask (nil = every bit).
function cases.depot(case, x, name, mask)
	local signals = mask and { { case.network, mask } } or {}
	local d = cases.station(case, { name = name, x = x, mode = MODE_DEPOT, bits = 0, signals = signals })
	case.depots[#case.depots + 1] = d
	return d
end

--- Locomotive, cargo wagon, locomotive (40 slots), built east of `x` with the depot `depot` as its schedule.
--- @return LuaTrain
function cases.train(case, x, depot)
	local s = case.surface
	local y = case.y + 1
	local force = game.forces.player
	local l1 = add(case, s.create_entity({ name = "locomotive", position = { x + 4, y },
		direction = defines.direction.east, force = force }))
	add(case, s.create_entity({ name = "cargo-wagon", position = { x + 11, y },
		direction = defines.direction.east, force = force }))
	local l2 = add(case, s.create_entity({ name = "locomotive", position = { x + 18, y },
		direction = defines.direction.west, force = force }))
	l1.insert({ name = "coal", count = 50 })
	l2.insert({ name = "coal", count = 50 })
	local train = l1.train
	train.schedule = { current = 1, records = { {
		station = depot.name,
		wait_conditions = { { type = "time", ticks = 60, compare_type = "or" } },
	} } }
	train.manual_mode = false
	case.trains[#case.trains + 1] = train.id
	case.train_entities[#case.train_entities + 1] = train
	return train
end

--- Takes the fuel out so a dispatched train stays where it is.
--- @param train LuaTrain
function cases.unfuel(train)
	for _, dir in pairs(train.locomotives) do
		for _, loco in pairs(dir) do
			local inv = loco.get_fuel_inventory()
			if inv then inv.clear() end
			loco.burner.currently_burning = nil
			loco.burner.remaining_burning_fuel = 0
		end
	end
end

-- ---- observations --------------------------------------------------------------------------------------------

--- Cybersyn's record of a train, or nil when it does not know the train.
function cases.ctrain(id)
	return read("trains", id)
end

--- @return boolean every train of the case parked at its depot and available
function cases.trains_ready(case, ids)
	for _, id in ipairs(ids or case.trains) do
		local t = read("trains", id)
		if not (t and t.status == STATUS_D and t.is_available) then return false end
	end
	return true
end

--- Count of `item` the station's last poll saw on its combinator input (negative = requested), or nil.
function cases.polled(station_id, item)
	local sigs = read("stations", station_id, "stops", 0, "tick_signals")
	if not sigs then return nil end
	for _, v in pairs(sigs) do
		if v.signal and v.signal.name == item then return v.count end
	end
	return nil
end

--- Position of a station in the polling queue, which is the order the planner lists requesters in, or nil.
function cases.poll_index(id)
	for i, v in ipairs(read("active_station_ids") or {}) do
		if v == id then return i end
	end
	return nil
end

--- Makes a fresh station take part in the next planner cycle instead of after its warm-up, the same state the
--- planner reaches on its own (as harness/suites/cybersyn.lua does).
function cases.promote(ids)
	local active = read("active_station_ids")
	for _, id in ipairs(ids) do
		if read("stations", id) then
			write(nil, "stations", id, "is_warming_up")
			write(nil, "warmup_station_cycles", id)
			active[#active + 1] = id
		end
	end
	write(active, "active_station_ids")
end

local function check(list, name, ok, detail)
	list[#list + 1] = { name, ok and true or false, detail }
end

-- ---- scenarios -----------------------------------------------------------------------------------------------

--- Common shell: row, depot and (unless opt.no_train) one train parked there.
--- @param name string
--- @param ctx {k: integer}
--- @param opt {no_train: boolean?, depot_mask: integer?}?
local function base(name, ctx, opt)
	opt = opt or {}
	local surface = game.surfaces[cases.SURFACE]
	local case = {
		name = name,
		k = ctx.k,
		y = cases.Y0 + cases.ROW * ctx.k,
		surface = surface,
		network = cases.NETWORKS[name],
		item = cases.ITEM,
		entities = {},
		stations = {},
		depots = {},
		trains = {},
		train_entities = {},
		kind = "reason",
		expect = name,
	}
	generate(surface, case.y)
	surface.force_generate_chunk_requests()
	lay_row(case, surface)
	case.d1 = cases.depot(case, cases.X_D1, "rc-" .. name .. "-depot", opt.depot_mask)
	if not opt.no_train then
		case.t1 = cases.train(case, cases.X_D1 + 6, case.d1)
	end
	return case
end

--- Station names carry the case so a stop is easy to find on the map.
local function sname(case, role) return "rc-" .. case.name .. "-" .. role end

--- The signals of a requester of `count` (negative) of the case item with a request threshold.
local function request(case, count, threshold, extra)
	local list = { { case.item, count }, { THRESHOLD, threshold, "virtual" } }
	for _, s in ipairs(extra or {}) do list[#list + 1] = s end
	return list
end

local function provide(case, count, item)
	return { { item or case.item, count } }
end

local function finish(case)
	local ids = {}
	for _, st in ipairs(case.stations) do ids[#ids + 1] = st.id end
	cases.promote(ids)
	case.cleanup = function() cases.destroy(case) end
	return case
end

--- The usual last stage: once the case's trains (or the given ones) are parked, switch on the request.
--- @param ids integer[]? indices into case.trains
local function arm_when_ready(case, signals, ids)
	return {
		when = function(c)
			local list
			if ids then
				list = {}
				for i, k in ipairs(ids) do list[i] = c.trains[k] end
			end
			return cases.trains_ready(c, list)
		end,
		run = function(c) cases.set_signals(c.r, signals) end,
	}
end

--- Every scenario but the ones about the provider's stock also proves a provider offers the item at the
--- requester's threshold, so "failed request, no delivery" cannot come from a missing provider instead.
local function common_pre(case)
	local out = {}
	local polled = cases.polled(case.r_station, case.item)
	check(out, "requester polled the item as requested", polled ~= nil and polled < 0, polled)
	if not case.no_offer then
		local pc = cases.polled(case.p_station, case.item)
		local threshold = read("stations", case.r_station, "r_threshold")
		check(out, "the provider offers the item at the requester's threshold",
			pc ~= nil and threshold ~= nil and pc >= threshold, { offered = pc, threshold = threshold })
	end
	return out
end

--- A normal request on the same kind of track: dispatched, loaded by the runner, unloaded at the requester.
function cases.CONTROL(ctx)
	local case = base("CONTROL", ctx)
	case.p = cases.station(case, { name = sname(case, "p"), x = cases.X_P[1], bits = PR_PROVIDE + ALLOW_ALL,
		signals = provide(case, 5000) })
	case.r = cases.station(case, { name = sname(case, "r"), x = cases.X_R[1], bits = PR_REQUEST + ALLOW_ALL })
	case.r_station, case.p_station = case.r.id, case.p.id
	case.expect = nil
	case.served = true
	case.operated = true
	case.line_end = case.surface.find_entities_filtered({ name = "straight-rail",
		position = { cases.X_MAX + 1, case.y + 1 } })[1]
	-- The requester's combinator never sees its stock rise, so it would ask again once the train unloads.
	case.on_unload = function(c) cases.set_signals(c.r, {}) end
	case.stages = { arm_when_ready(case, request(case, -2000, 1000)) }
	case.pre = function(c)
		local out = {}
		local pc = cases.polled(c.p_station, c.item)
		check(out, "the provider offers the item", pc ~= nil and pc > 0, pc)
		check(out, "the network has one train", #c.trains == 1)
		return out
	end
	return finish(case)
end

--- The network has a provider, but not of the requested item.
function cases.NO_PROVIDER(ctx)
	local case = base("NO_PROVIDER", ctx)
	case.no_offer = true
	case.p = cases.station(case, { name = sname(case, "p"), x = cases.X_P[1], bits = PR_PROVIDE + ALLOW_ALL,
		signals = provide(case, 5000, cases.ITEM2) })
	case.r = cases.station(case, { name = sname(case, "r"), x = cases.X_R[1], bits = PR_REQUEST + ALLOW_ALL })
	case.r_station, case.p_station = case.r.id, case.p.id
	case.stages = { arm_when_ready(case, request(case, -2000, 1000)) }
	case.pre = function(c)
		local out = common_pre(c)
		local p_item = cases.polled(c.p_station, c.item)
		local p_other = cases.polled(c.p_station, cases.ITEM2)
		check(out, "the network's only provider does not offer the item", p_item == nil and (p_other or 0) > 0,
			{ item = p_item, other = p_other })
		return out
	end
	case.lift = function(c)
		cases.set_signals(c.p, { { cases.ITEM2, 5000 }, { c.item, 5000 } })
	end
	return finish(case)
end

--- Train limit 1 with one delivery inbound (a train held at its depot), then a second item requested.
function cases.R_AT_LIMIT(ctx)
	local case = base("R_AT_LIMIT", ctx)
	case.p = cases.station(case, { name = sname(case, "p"), x = cases.X_P[1], bits = PR_PROVIDE + ALLOW_ALL,
		signals = provide(case, 5000, cases.ITEM2) })
	case.p2 = cases.station(case, { name = sname(case, "p2"), x = cases.X_P[2], bits = PR_PROVIDE + ALLOW_ALL,
		signals = provide(case, 5000) })
	case.r = cases.station(case, { name = sname(case, "r"), x = cases.X_R[1], bits = PR_REQUEST + ALLOW_ALL,
		limit = 1 })
	case.r_station, case.p_station = case.r.id, case.p2.id
	case.expect_ab = { 1, 1 }
	case.stages = {
		{
			when = function(c) return cases.trains_ready(c) end,
			run = function(c)
				cases.unfuel(c.t1)
				cases.set_signals(c.r, { { cases.ITEM2, -2000 }, { THRESHOLD, 1000, "virtual" } })
			end,
		},
		{
			when = function(c)
				local t = cases.ctrain(c.trains[1])
				return t and t.status == STATUS_TO_P and t.r_station_id == c.r_station
			end,
			run = function(c)
				c.d2 = cases.depot(c, cases.X_D2, sname(c, "depot2"))
				cases.promote({ c.d2.id })
				c.t2 = cases.train(c, cases.X_D2 + 6, c.d2)
			end,
		},
		arm_when_ready(case, { { cases.ITEM2, -2000 }, { case.item, -2000 }, { THRESHOLD, 1000, "virtual" } }, { 2 }),
	}
	case.pre = function(c)
		local out = common_pre(c)
		local st = read("stations", c.r_station)
		check(out, "requester trains_limit is 1", st and st.trains_limit == 1, st and st.trains_limit)
		check(out, "one delivery inbound (deliveries_total 1)", st and st.deliveries_total == 1,
			st and st.deliveries_total)
		check(out, "a second train is available", cases.trains_ready(c, { c.trains[2] }))
		return out
	end
	return finish(case)
end

--- Train limit 0 with an active request.
function cases.R_DISABLED(ctx)
	local case = base("R_DISABLED", ctx)
	case.p = cases.station(case, { name = sname(case, "p"), x = cases.X_P[1], bits = PR_PROVIDE + ALLOW_ALL,
		signals = provide(case, 5000) })
	case.r = cases.station(case, { name = sname(case, "r"), x = cases.X_R[1], bits = PR_REQUEST + ALLOW_ALL,
		limit = 0 })
	case.r_station, case.p_station = case.r.id, case.p.id
	case.stages = { arm_when_ready(case, request(case, -2000, 1000)) }
	case.pre = function(c)
		local out = common_pre(c)
		local st = read("stations", c.r_station)
		check(out, "requester trains_limit is 0", st and st.trains_limit == 0, st and st.trains_limit)
		return out
	end
	case.lift = function(c)
		c.r.stop.trains_limit = nil
	end
	return finish(case)
end

--- A stop that provides the item (one pickup in progress) and then requests it while another provider has it.
function cases.R_IS_PROVIDING(ctx)
	local case = base("R_IS_PROVIDING", ctx)
	-- a: provides, then requests. b: the first requester. c: the second provider, switched on later.
	case.a = cases.station(case, { name = sname(case, "a"), x = cases.X_P[1], bits = PR_BOTH + ALLOW_ALL,
		signals = provide(case, 5000) })
	case.c = cases.station(case, { name = sname(case, "c"), x = cases.X_P[2], bits = PR_PROVIDE + ALLOW_ALL })
	case.b = cases.station(case, { name = sname(case, "b"), x = cases.X_R[1], bits = PR_REQUEST + ALLOW_ALL })
	case.r = case.a
	case.r_station, case.p_station = case.a.id, case.c.id
	case.stages = {
		{
			when = function(c) return cases.trains_ready(c) end,
			run = function(c)
				cases.unfuel(c.t1)
				cases.set_signals(c.b, request(c, -2000, 1000))
			end,
		},
		{
			when = function(c)
				local t = cases.ctrain(c.trains[1])
				return t and t.status == STATUS_TO_P and t.p_station_id == c.a.id
			end,
			run = function(c)
				cases.set_signals(c.b, {})
				cases.set_signals(c.c, provide(c, 5000))
				c.d2 = cases.depot(c, cases.X_D2, sname(c, "depot2"))
				cases.promote({ c.d2.id })
				c.t2 = cases.train(c, cases.X_D2 + 6, c.d2)
			end,
		},
		arm_when_ready(case, request(case, -3000, 1000), { 2 }),
	}
	case.pre = function(c)
		local out = common_pre(c)
		local d = read("stations", c.a.id, "deliveries", c.item)
		check(out, "the requester has a pickup of the item in progress", d ~= nil and d < 0, d)
		return out
	end
	return finish(case)
end

--- Two requesters of the same item, priorities 10 and 0, on a network with no train. Every cycle the planner
--- picks "hi", fails it (no train) and only then evaluates "lo", so the item's requester loop ends without a
--- candidate (the r591 return, where PLAN3 §4.5 records requester-side skips) with lo having lost to hi once.
--- `lo_first` puts lo ahead of hi in the polling queue: the planner then picks lo first and replaces it with hi
--- instead of skipping lo, and the loss must be counted all the same. Lift: a train arrives; hi is served, and
--- the provider's stock (one delivery) is gone, so lo never is.
local function lost_priority(name, ctx, lo_first)
	local case = base(name, ctx, { no_train = true })
	case.p = cases.station(case, { name = sname(case, "p"), x = cases.X_P[1], bits = PR_PROVIDE + ALLOW_ALL,
		signals = provide(case, 2000) })
	local function requester(role, x)
		return cases.station(case, { name = sname(case, role), x = x, bits = PR_REQUEST + ALLOW_ALL })
	end
	if lo_first then
		case.r = requester("lo", cases.X_R[2])
		case.hi = requester("hi", cases.X_R[1])
	else
		case.hi = requester("hi", cases.X_R[1])
		case.r = requester("lo", cases.X_R[2])
	end
	case.r_station, case.p_station = case.r.id, case.p.id
	case.winner = case.hi.id
	case.lift_station = case.hi.id
	case.kind = "counter"
	case.expect = "LOST_PRIORITY"
	case.expect_settled = "NO_TRAINS_ON_NETWORK"
	case.expect_ab = { 0, 0 }
	case.stages = {
		{
			when = function() return true end,
			run = function(c)
				cases.set_signals(c.hi, request(c, -2000, 2000, { { PRIORITY, 10, "virtual" } }))
				cases.set_signals(c.r, request(c, -2000, 2000))
			end,
		},
	}
	case.pre = function(c)
		local out = common_pre(c)
		local hi = read("stations", c.hi.id)
		local lo = read("stations", c.r_station)
		check(out, "requester priorities 10 and 0", hi and lo and hi.priority == 10 and lo.priority == 0,
			{ hi = hi and hi.priority, lo = lo and lo.priority })
		local hi_i, lo_i = cases.poll_index(c.hi.id), cases.poll_index(c.r_station)
		check(out, (lo_first and "lo" or "hi") .. " is polled first",
			hi_i ~= nil and lo_i ~= nil and (lo_i < hi_i) == (lo_first == true), { hi = hi_i, lo = lo_i })
		check(out, "no train on the network", read("available_trains", c.network) == nil)
		return out
	end
	case.lift = function(c)
		c.t1 = cases.train(c, cases.X_D1 + 6, c.d1)
	end
	return finish(case)
end

function cases.LOST_PRIORITY(ctx) return lost_priority("LOST_PRIORITY", ctx, false) end

function cases.LOST_PRIORITY_LO_FIRST(ctx) return lost_priority("LOST_PRIORITY_LO_FIRST", ctx, true) end

--- The only provider is at its train limit (1, a pickup in progress) while a requester waits.
function cases.P_AT_LIMIT(ctx)
	local case = base("P_AT_LIMIT", ctx)
	case.p = cases.station(case, { name = sname(case, "p"), x = cases.X_P[1], bits = PR_PROVIDE + ALLOW_ALL,
		signals = provide(case, 10000), limit = 1 })
	case.r1 = cases.station(case, { name = sname(case, "r1"), x = cases.X_R[1], bits = PR_REQUEST + ALLOW_ALL })
	case.r = cases.station(case, { name = sname(case, "r"), x = cases.X_R[2], bits = PR_REQUEST + ALLOW_ALL })
	case.r_station, case.p_station = case.r.id, case.p.id
	case.expect_ab = { 1, 1 }
	case.stages = {
		{
			when = function(c) return cases.trains_ready(c) end,
			run = function(c)
				cases.unfuel(c.t1)
				cases.set_signals(c.r1, request(c, -2000, 1000))
			end,
		},
		{
			when = function(c)
				local t = cases.ctrain(c.trains[1])
				return t and t.status == STATUS_TO_P and t.r_station_id == c.r1.id
			end,
			run = function(c)
				c.d2 = cases.depot(c, cases.X_D2, sname(c, "depot2"))
				cases.promote({ c.d2.id })
				c.t2 = cases.train(c, cases.X_D2 + 6, c.d2)
			end,
		},
		arm_when_ready(case, request(case, -2000, 1000), { 2 }),
	}
	case.pre = function(c)
		local out = common_pre(c)
		local st = read("stations", c.p_station)
		check(out, "provider at its train limit (1 of 1)", st and st.trains_limit == 1 and st.deliveries_total == 1,
			st and { limit = st.trains_limit, total = st.deliveries_total })
		check(out, "a second train is available", cases.trains_ready(c, { c.trains[2] }))
		return out
	end
	return finish(case)
end

--- The only provider has a delivery of the item inbound (it requested it first).
function cases.P_IS_REQUESTING(ctx)
	local case = base("P_IS_REQUESTING", ctx)
	-- p0 serves q first and then stops providing; q then provides and is the network's only provider.
	case.p0 = cases.station(case, { name = sname(case, "p0"), x = cases.X_P[1], bits = PR_PROVIDE + ALLOW_ALL,
		signals = provide(case, 5000) })
	case.q = cases.station(case, { name = sname(case, "q"), x = cases.X_P[2], bits = PR_BOTH + ALLOW_ALL })
	case.r = cases.station(case, { name = sname(case, "r"), x = cases.X_R[1], bits = PR_REQUEST + ALLOW_ALL })
	case.r_station, case.p_station = case.r.id, case.q.id
	case.stages = {
		{
			when = function(c) return cases.trains_ready(c) end,
			run = function(c)
				cases.unfuel(c.t1)
				cases.set_signals(c.q, request(c, -2000, 1000))
			end,
		},
		{
			when = function(c)
				local t = cases.ctrain(c.trains[1])
				return t and t.status == STATUS_TO_P and t.r_station_id == c.q.id
			end,
			run = function(c)
				cases.set_signals(c.p0, {})
				cases.set_signals(c.q, provide(c, 5000))
				c.d2 = cases.depot(c, cases.X_D2, sname(c, "depot2"))
				cases.promote({ c.d2.id })
				c.t2 = cases.train(c, cases.X_D2 + 6, c.d2)
			end,
		},
		arm_when_ready(case, request(case, -2000, 1000), { 2 }),
	}
	case.pre = function(c)
		local out = common_pre(c)
		local d = read("stations", c.q.id, "deliveries", c.item)
		check(out, "the provider has a delivery of the item inbound", d ~= nil and d > 0, d)
		local qp = cases.polled(c.q.id, c.item)
		local p0 = cases.polled(c.p0.id, c.item)
		check(out, "it is the only provider of the item", qp ~= nil and qp > 0 and p0 == nil, { q = qp, p0 = p0 })
		return out
	end
	return finish(case)
end

--- Requester mask 1, provider mask 2, trains on both.
function cases.MASK_MISMATCH(ctx)
	local case = base("MASK_MISMATCH", ctx, { depot_mask = 3 })
	case.p = cases.station(case, { name = sname(case, "p"), x = cases.X_P[1], bits = PR_PROVIDE + ALLOW_ALL,
		signals = { { case.item, 5000 }, { case.network, 2 } } })
	case.r = cases.station(case, { name = sname(case, "r"), x = cases.X_R[1], bits = PR_REQUEST + ALLOW_ALL })
	case.r_station, case.p_station = case.r.id, case.p.id
	case.stages = { arm_when_ready(case, request(case, -2000, 1000, { { case.network, 1 } })) }
	case.pre = function(c)
		local out = common_pre(c)
		local rm = read("stations", c.r_station, "network_mask")
		local pm = read("stations", c.p_station, "network_mask")
		check(out, "requester mask 1, provider mask 2", rm == 1 and pm == 2, { r = rm, p = pm })
		local t = cases.ctrain(c.trains[1])
		check(out, "the train serves both masks (3)", t and t.network_mask == 3, t and t.network_mask)
		return out
	end
	return finish(case)
end

--- Provider on a surface the test creates, requester on cyb-bench, no surface connection between them.
function cases.NO_SURFACE_ROUTE(ctx)
	local case = base("NO_SURFACE_ROUTE", ctx)
	local island = cases.island()
	generate(island, 0)
	island.force_generate_chunk_requests()
	local shell = { y = 0, entities = case.entities }
	lay_row(shell, island)
	case.p = cases.station(case, { name = sname(case, "p"), x = cases.X_P[1], bits = PR_PROVIDE + ALLOW_ALL,
		signals = provide(case, 5000), surface = island, y = 0 })
	case.r = cases.station(case, { name = sname(case, "r"), x = cases.X_R[1], bits = PR_REQUEST + ALLOW_ALL })
	case.r_station, case.p_station = case.r.id, case.p.id
	case.stages = { arm_when_ready(case, request(case, -2000, 1000)) }
	case.pre = function(c)
		local out = common_pre(c)
		check(out, "provider and requester on different surfaces",
			c.p.stop.surface_index ~= c.r.stop.surface_index)
		local conn = read("connected_surfaces")
		check(out, "no surface connections exist", next(conn or {}) == nil, conn)
		return out
	end
	case.expect_ab = { case.p.stop.surface_index, case.r.stop.surface_index, unordered = true }
	finish(case)
	local destroy = case.cleanup
	case.cleanup = function()
		destroy()
		if game.surfaces[cases.ISLAND] then game.delete_surface(cases.ISLAND) end
	end
	return case
end

--- The provider has less than the requester's threshold.
function cases.P_BELOW_THRESHOLD(ctx)
	local case = base("P_BELOW_THRESHOLD", ctx)
	case.no_offer = true
	case.expect_ab = { 500, 2000 }
	case.p = cases.station(case, { name = sname(case, "p"), x = cases.X_P[1], bits = PR_PROVIDE + ALLOW_ALL,
		signals = provide(case, 500) })
	case.r = cases.station(case, { name = sname(case, "r"), x = cases.X_R[1], bits = PR_REQUEST + ALLOW_ALL })
	case.r_station, case.p_station = case.r.id, case.p.id
	case.stages = { arm_when_ready(case, request(case, -3000, 2000)) }
	case.pre = function(c)
		local out = common_pre(c)
		local pc = cases.polled(c.p_station, c.item)
		check(out, "provider has 500, threshold 2000", pc == 500, pc)
		return out
	end
	case.lift = function(c)
		cases.set_signals(c.p, provide(c, 5000))
	end
	return finish(case)
end

--- A provider and a requester on a network whose depot has no train.
function cases.NO_TRAINS_ON_NETWORK(ctx)
	local case = base("NO_TRAINS_ON_NETWORK", ctx, { no_train = true })
	case.expect_ab = { 0, 0 }
	case.p = cases.station(case, { name = sname(case, "p"), x = cases.X_P[1], bits = PR_PROVIDE + ALLOW_ALL,
		signals = provide(case, 5000) })
	case.r = cases.station(case, { name = sname(case, "r"), x = cases.X_R[1], bits = PR_REQUEST + ALLOW_ALL })
	case.r_station, case.p_station = case.r.id, case.p.id
	case.stages = { arm_when_ready(case, request(case, -2000, 1000)) }
	case.pre = function(c)
		local out = common_pre(c)
		local avail = read("available_trains", c.network)
		check(out, "no train available on the network", avail == nil, avail)
		return out
	end
	return finish(case)
end

local function filtered_base(name, ctx, opt)
	local case = base(name, ctx, opt)
	case.p = cases.station(case, { name = sname(case, "p"), x = cases.X_P[1], bits = PR_PROVIDE + ALLOW_ALL,
		signals = provide(case, 5000, nil) })
	case.r = cases.station(case, { name = sname(case, "r"), x = cases.X_R[1], bits = PR_REQUEST + ALLOW_ALL })
	case.r_station, case.p_station = case.r.id, case.p.id
	case.expect = "TRAIN_FILTERED"
	case.expect_ab = { 1, 0 }
	return case
end

--- The network's only train is in manual mode.
function cases.TRAIN_FILTERED_MANUAL(ctx)
	local case = filtered_base("TRAIN_FILTERED_MANUAL", ctx)
	case.expect_rej = "TRAIN_MANUAL"
	case.stages = {
		{
			when = function(c) return cases.trains_ready(c) end,
			run = function(c) c.t1.manual_mode = true end,
		},
		{
			when = function() return true end,
			run = function(c) cases.set_signals(c.r, request(c, -2000, 1000)) end,
		},
	}
	case.pre = function(c)
		local out = common_pre(c)
		check(out, "the only train is in manual mode and still available",
			c.t1.valid and c.t1.manual_mode and cases.trains_ready(c))
		return out
	end
	return finish(case)
end

--- The network's only train has a mask that shares no bit with the stations'.
function cases.TRAIN_FILTERED_MASK(ctx)
	local case = filtered_base("TRAIN_FILTERED_MASK", ctx, { depot_mask = 2 })
	case.expect_rej = "TRAIN_MASK"
	cases.set_signals(case.p, { { case.item, 5000 }, { case.network, 1 } })
	case.stages = { arm_when_ready(case, request(case, -2000, 1000, { { case.network, 1 } })) }
	case.pre = function(c)
		local out = common_pre(c)
		local t = cases.ctrain(c.trains[1])
		local rm = read("stations", c.r_station, "network_mask")
		local pm = read("stations", c.p_station, "network_mask")
		check(out, "train mask 2, station masks 1", t and t.network_mask == 2 and rm == 1 and pm == 1,
			{ t = t and t.network_mask, r = rm, p = pm })
		check(out, "the train is available", cases.trains_ready(c))
		return out
	end
	return finish(case)
end

--- The network's only train has an empty schedule. Clearing it at the depot would make Cybersyn drop the train
--- (leaving a stop with no records), so it is cleared under manual control and handed back: Cybersyn reacts
--- only to a state change out of wait_station, and the train stays available until the planner validates it.
--- That validation removes the train (validate_train_base_schedule), so the reason settles on
--- NO_TRAINS_ON_NETWORK.
function cases.TRAIN_FILTERED_SCHEDULE(ctx)
	local case = filtered_base("TRAIN_FILTERED_SCHEDULE", ctx)
	case.expect_settled = "NO_TRAINS_ON_NETWORK"
	-- The train is in the table when the first evaluation starts and is dropped during it, so only `usable` is fixed.
	case.expect_ab = { nil, 0, at = "first" }
	case.expect_rej = "TRAIN_MANUAL"
	case.flap = { from = "TRAIN_FILTERED", to = "NO_TRAINS_ON_NETWORK" }
	case.stages = {
		{
			when = function(c) return cases.trains_ready(c) end,
			run = function(c)
				c.t1.manual_mode = true
				c.t1.get_schedule().clear_records()
			end,
		},
		{
			when = function() return true end,
			run = function(c) c.t1.manual_mode = false end,
		},
		{
			when = function(c) return cases.trains_ready(c) end,
			run = function(c) cases.set_signals(c.r, request(c, -2000, 1000)) end,
		},
	}
	case.pre = function(c)
		local out = common_pre(c)
		check(out, "the train's schedule is empty", c.t1.valid and c.t1.get_schedule().get_record_count() == 0)
		check(out, "the planner dropped the train", cases.ctrain(c.trains[1]) == nil)
		return out
	end
	return finish(case)
end

--- Request threshold 5000 iron plates (50 stacks); the only train carries 40 stacks.
function cases.CAPACITY(ctx)
	local case = base("CAPACITY", ctx)
	case.expect_ab = { 50, 40 }
	case.p = cases.station(case, { name = sname(case, "p"), x = cases.X_P[1], bits = PR_PROVIDE + ALLOW_ALL,
		signals = provide(case, 20000) })
	case.r = cases.station(case, { name = sname(case, "r"), x = cases.X_R[1], bits = PR_REQUEST + ALLOW_ALL })
	case.r_station, case.p_station = case.r.id, case.p.id
	case.stages = { arm_when_ready(case, request(case, -10000, 5000)) }
	case.pre = function(c)
		local out = common_pre(c)
		local t = cases.ctrain(c.trains[1])
		check(out, "largest train carries 40 stacks, request needs 50",
			t and t.item_slot_capacity == 40 and read("stations", c.r_station, "r_threshold") == 5000,
			t and t.item_slot_capacity)
		return out
	end
	return finish(case)
end

--- A stop with "disable allow list" off and no inserters accepts no layout with a cargo wagon.
local function layout_case(name, ctx, r_open, p_open)
	local case = base(name, ctx)
	case.p = cases.station(case, { name = sname(case, "p"), x = cases.X_P[1],
		bits = PR_PROVIDE + (p_open and ALLOW_ALL or 0), signals = provide(case, 5000) })
	case.r = cases.station(case, { name = sname(case, "r"), x = cases.X_R[1],
		bits = PR_REQUEST + (r_open and ALLOW_ALL or 0) })
	case.r_station, case.p_station = case.r.id, case.p.id
	case.stages = { arm_when_ready(case, request(case, -2000, 1000)) }
	case.pre = function(c)
		local out = common_pre(c)
		local r = read("stations", c.r_station)
		local p = read("stations", c.p_station)
		local t = cases.ctrain(c.trains[1])
		local function accepts(st)
			return st and (st.allows_all_trains or (t and st.accepted_layouts[t.layout_id])) and true or false
		end
		check(out, (r_open and "requester accepts" or "requester rejects") .. " the train's layout",
			accepts(r) == r_open)
		check(out, (p_open and "provider accepts" or "provider rejects") .. " the train's layout",
			accepts(p) == p_open)
		return out
	end
	return finish(case)
end

function cases.R_LAYOUT(ctx) return layout_case("R_LAYOUT", ctx, false, true) end

function cases.P_LAYOUT(ctx) return layout_case("P_LAYOUT", ctx, true, false) end

--- Every available train is executing an always-true interrupt. A train that leaves its depot for an interrupt
--- elsewhere is dropped by Cybersyn (a depot departure without a delivery), so the interrupt sends the train to
--- its own depot with a long inactivity wait. On that arrival Cybersyn's set_depot_schedule takes the interrupt's
--- record for its own depot record (same station, one inactivity condition) and keeps it as the only record: the
--- train is parked and available, and its current record is the interrupt's.
function cases.ALL_IN_INTERRUPT(ctx)
	local case = base("ALL_IN_INTERRUPT", ctx)
	case.p = cases.station(case, { name = sname(case, "p"), x = cases.X_P[1], bits = PR_PROVIDE + ALLOW_ALL,
		signals = provide(case, 5000) })
	case.r = cases.station(case, { name = sname(case, "r"), x = cases.X_R[1], bits = PR_REQUEST + ALLOW_ALL })
	case.r_station, case.p_station = case.r.id, case.p.id
	case.stages = {
		{
			when = function(c) return cases.trains_ready(c) end,
			run = function(c)
				c.t1.get_schedule().add_interrupt({
					name = "rc-always",
					conditions = { { type = "item_count", compare_type = "or",
						condition = { first_signal = { type = "item", name = "iron-plate" }, comparator = "≥", constant = 0 } } },
					targets = { { station = c.d1.name,
						wait_conditions = { { type = "inactivity", compare_type = "or", ticks = 3600 * 60 } } } },
				})
			end,
		},
		{
			when = function(c)
				return cases.in_interrupt(c.t1) and c.t1.state == defines.train_state.wait_station and
					cases.trains_ready(c)
			end,
			run = function(c) cases.set_signals(c.r, request(c, -2000, 1000)) end,
		},
	}
	case.pre = function(c)
		local out = common_pre(c)
		check(out, "the only train is available and inside an interrupt",
			cases.in_interrupt(c.t1) and cases.trains_ready(c))
		return out
	end
	return finish(case)
end

--- @param train LuaTrain
function cases.in_interrupt(train)
	if not train.valid then return false end
	local schedule = train.get_schedule()
	local rec = schedule.get_record({ schedule_index = schedule.current })
	return rec ~= nil and rec.created_by_interrupt == true
end

-- ---- the control case's operator ---------------------------------------------------------------------------

--- Stands in for inserters on the control case's train: loads the manifest at the provider, empties the train
--- at the requester, and sends it round the east end of the line once it has nowhere to go (the line is a dead
--- end whose stops all face west, as in dispatch_trace.lua). Called every tick while the case runs.
--- @param case table
function cases.operate(case)
	local t = case.t1
	if not (t and t.valid) then return end
	local ct = cases.ctrain(t.id)
	if not ct then return end
	if t.state == defines.train_state.no_path and case.line_end then
		local schedule = t.get_schedule()
		local current = schedule.current
		local record = schedule.get_record({ schedule_index = current })
		local rail = case.line_end
		if record and rail and rail.valid and record.rail ~= rail and case.turned ~= ct.status then
			case.turned = ct.status
			schedule.add_record({
				rail = rail,
				rail_direction = defines.rail_direction.front,
				temporary = true,
				wait_conditions = { { type = "time", ticks = 1 } },
				index = { schedule_index = current },
			})
			schedule.go_to_station(current)
		end
		return
	end
	if not (t.state == defines.train_state.wait_station and t.station) then return end
	if ct.status == 2 and ct.manifest then
		for _, m in ipairs(ct.manifest) do
			local have = t.get_item_count({ name = m.name, quality = m.quality })
			if have < m.count then t.insert({ name = m.name, count = m.count - have, quality = m.quality }) end
		end
	elseif ct.status == 4 and next(t.get_contents()) then
		t.clear_items_inside()
		if case.on_unload then case.on_unload(case) end
	end
end

-- ---- teardown ------------------------------------------------------------------------------------------------

--- Destroys everything the case built, trains first, with raise_destroy so Cybersyn drops its stations, depots
--- and trains the way it does for a player's deconstruction.
function cases.destroy(case)
	for _, t in ipairs(case.train_entities) do
		if t.valid then
			for _, car in pairs(t.carriages) do
				if car.valid then car.destroy({ raise_destroy = true }) end
			end
		end
	end
	for i = #case.entities, 1, -1 do
		local e = case.entities[i]
		if e.valid then e.destroy({ raise_destroy = true }) end
	end
end

--- The planner-facing state a scenario could leave behind, for a before/after comparison around the suite.
--- @return table
function cases.fingerprint()
	local function keys(t)
		local out = {}
		for k in pairs(t or {}) do out[#out + 1] = k end
		table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
		return out
	end
	-- The planner prunes ids of removed stations from active_station_ids lazily, so only live ids are compared.
	local stations = read("stations") or {}
	local sorted = {}
	for _, id in ipairs(read("active_station_ids") or {}) do
		if stations[id] then sorted[#sorted + 1] = id end
	end
	table.sort(sorted)
	return {
		stations = keys(stations),
		trains = keys(read("trains")),
		depots = keys(read("depots")),
		available_trains = keys(read("available_trains")),
		layouts = keys(read("layouts")),
		refuelers = keys(read("refuelers")),
		warmup = keys(read("warmup_station_cycles")),
		active_station_ids = sorted,
		connected_surfaces = keys(read("connected_surfaces")),
		surfaces = keys(game.surfaces),
	}
end

rcon.print("INFO cases: " .. #cases.ORDER .. " scenarios loaded")
