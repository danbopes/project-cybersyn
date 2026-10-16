-- Setup lint (PLAN3 §4.12): finds the setups that will never dispatch before a request exists, and names the reason
-- code each one predicts, so the reason-code suite can hold this model and the dispatcher's to the same answers.
--
-- Two jobs, both driven by the manager tick and neither on a timer of its own:
--   the setup job runs only while a manager window is open (collector.tick calls lint.tick), 50 station, depot and
--   refueler records plus 12 trains per update, from the manager snapshot, the fleet facts the collector builds once
--   per pass, and a few reads of each record's stop; it rebuilds the findings array every pass and writes one `lint`
--   log event per finding that appears or clears. Schedule records are checked against the stop names the snapshot
--   already holds; only a name outside them costs a lookup (a full get_train_stops{} list took 0.85 ms on a
--   2,578-stop base, more than a whole update may).
--   the world scan (lint.scan_world, the /cybersyn-find-problems command and the Problems tab's button) searches the
--   map around every train stop for combinators that keep a station from registering: one get_train_stops call,
--   then chunks of stops and combinators per manager update whether or not a window is open (or per update of its
--   own nth-tick handler while manager updates are off, scripts/main.lua), one scan at a time.
-- Nothing here reads storage.diag except through diag.lint, and nothing runs find_entities_filtered except the
-- world scan.

local diag = require("scripts.diag")

local band = bit32.band
local bor = bit32.bor

local lint = {}

-- PLAN3 §4.12 estimated 100 records and 25 trains per update; measured on a 2,030-station, 551-train base a station
-- record costs 3-8 µs (up to 47 µs with 80 requested items), so 50 records stay well under its 0.5 ms. A train's
-- schedule and wagons are read only between deliveries (see check_train), a few µs each.
local RECORDS_PER_UPDATE = 50
local TRAINS_PER_UPDATE = 12
-- A stop name outside the seeded set costs a get_train_stops lookup of tens of µs; the train loop stops for this
-- update once this many were made and resumes at the same train.
local LOOKUPS_PER_UPDATE = 2
-- Station names for the schedule check, read from the snapshot before the train checks start: looking a name up
-- (get_train_stops by name) costs tens of µs on a big base, reading it from a record a fraction of one.
local SEED_PER_UPDATE = 300
local WORLD_NAMES_PER_UPDATE = 400
local WORLD_STOPS_PER_UPDATE = 100
local WORLD_COMBS_PER_UPDATE = 200
-- "Never refuelled" needs this much tracked time per train: from its first sighting (Train.seen_tick), and never from
-- before refuel_tick existed (storage.stats.refuel_since), so neither a new train nor one from an older save is
-- flagged before it had the chance to visit a refueler.
local REFUEL_GRACE = 216000
-- Unset train limits read back as uint max.
local UNLIMITED = 2100000000

-- Checks only the world scan finds; their acknowledgements end when a scan no longer finds them.
local WORLD_CHECKS = {
	[LINT_DERELICT_COMB] = true,
	[LINT_GHOST_COMB] = true,
	[LINT_NO_COMB] = true,
	[LINT_WRONG_SIDE] = true,
	[LINT_DOUBLE_COMB] = true,
	[LINT_PRIORITY] = true,
	[LINT_NAME_OVERLAP] = true,
}
lint.WORLD_CHECKS = WORLD_CHECKS

lint.RECORDS_PER_UPDATE = RECORDS_PER_UPDATE
lint.TRAINS_PER_UPDATE = TRAINS_PER_UPDATE
lint.REFUEL_GRACE = REFUEL_GRACE

--- @class LintFinding
--- @field subject int LINT_SUBJECT_*
--- @field id uint stop unit number, train id or combinator unit number
--- @field check int LINT_*
--- @field a number? detail numbers for the fix line (see the lint-fix-* locale keys)
--- @field b number?
--- @field network string?
--- @field item string? item hash the finding is about
--- @field entity LuaEntity? world scan: the stop or combinator
--- @field message string? world scan: the [cybersyn-problems] key the command prints

--- @class LintJob
--- @field started_tick uint
--- @field setup int? 1 and 2 while the pass is being set up (start_job, setup_job)
--- @field sids uint[] station ids of this pass, then dids (depots) and fids (refuelers): the cursor i runs over all three
--- @field dids uint[]?
--- @field fids uint[]?
--- @field i int
--- @field tids uint[] train ids of this pass
--- @field ti int
--- @field names {[string]: boolean}? stop name -> exists (the snapshot's names, plus lookups made this pass)
--- @field groups {[string]: int}? vanilla train group -> depot names among its Cybersyn trains
--- @field dest {[uint]: int} stop id -> Cybersyn trains heading to or standing at it
--- @field bound {[uint]: int} station id -> trains its deliveries_total should count
--- @field findings LintFinding[]
--- @field bits {[uint]: int} this pass's masks, committed with the findings when the pass completes
--- @field train_bits {[uint]: int}
--- @field lookups int stop-name lookups made in the current update

--- @class LintState
--- @field bits {[uint]: int} stop unit number -> mask of the last completed check
--- @field train_bits {[uint]: int}
--- @field findings LintFinding[] the last complete pass
--- @field train_live {[uint]: {missing: int?, items: int, fluid: int?}} per train, what its schedule and wagons said
---   when last read between deliveries
--- @field pass int completed passes
--- @field tick uint? when the last pass completed
--- @field updates int updates the last pass took
--- @field job LintJob?
--- @field occupancy_since {[uint]: uint} stop -> tick the occupancy gap was first seen (cleared when it closes)
--- @field phantom_since {[uint]: uint}
--- @field world {tick: uint, findings: LintFinding[], player_index: uint?}?
--- @field world_job table?

--- @return LintState
function lint.state()
	local manager = storage.manager
	local s = manager.lint
	if not s then
		s = { bits = {}, train_bits = {}, findings = {}, pass = 0, updates = 0, occupancy_since = {}, phantom_since = {} }
		manager.lint = s
	end
	if not s.train_live then s.train_live = {} end
	return s
end

--- The last completed mask of a station, depot or refueler (0 when clean or not checked yet).
--- @param id uint
--- @return int
function lint.bits_of(id)
	local manager = storage.manager
	local s = manager and manager.lint
	return s and s.bits[id] or 0
end

--- The key a lint acknowledgement is stored under (storage.acks.lint): stops and combinators by unit number, trains by
--- their negated id, so a train id never collides with a unit number.
--- @param subject int LINT_SUBJECT_*
--- @param id uint
--- @return int
function lint.subject_key(subject, id)
	if subject == LINT_SUBJECT_TRAIN then return -id end
	return id
end

--- The tick from which a train's refuelling is tracked: when Cybersyn first saw it, but not before refuel_tick was
--- recorded at all.
--- @param train Train
--- @return uint
function lint.refuel_from(train)
	local since = storage.stats and storage.stats.refuel_since or 0
	local seen = train.seen_tick
	if seen and seen > since then return seen end
	return since
end

--- @param mask int
--- @param check int
--- @return boolean
function lint.has(mask, check)
	return band(mask, LINT_BIT[check]) ~= 0
end

-- ---------------------------------------------------------------- pure checks (no API calls; unit tested)

--- @param out LintFinding[]
local NO_LAYOUTS = {}

local function find(out, mask, subject, id, check, a, b, network, item)
	out[#out + 1] = { subject = subject, id = id, check = check, a = a, b = b, network = network, item = item }
	return bor(mask, LINT_BIT[check])
end

-- Slots per item for the capacity check, by hash: a stack size for items, false for fluids. Prototype data only, so
-- every Lua state computes the same values whether or not it has filled the cache yet.
local stack_of = {}

--- @param hash string
--- @return number|false
local function stack_size(hash)
	local v = stack_of[hash]
	if v == nil then
		local bar = string.find(hash, "|", 1, true)
		local name = bar and string.sub(hash, 1, bar - 1) or hash
		v = get_stack_size(nil, name) or false
		stack_of[hash] = v
	end
	return v
end

--- Networks of a station, refueler or train as (name, mask) pairs.
--- @param network_name string?
--- @param network_mask int|{[string]: int}?
--- @param fn fun(name: string, mask: int)
local function each_network(network_name, network_mask, fn)
	if network_name == NETWORK_EACH then
		if type(network_mask) == "table" then
			for name, mask in pairs(network_mask) do fn(name, mask) end
		end
	elseif network_name then
		fn(network_name, type(network_mask) == "number" and network_mask or 0)
	end
end
lint.each_network = each_network

--- What the fleet offers a stop on one network: trains whose mask shares a bit with the stop's, the layouts among
--- them the stop accepts, and the largest capacities of those and of all of them. The dispatcher tests capacity
--- before layout, so a train the stop rejects still decides whether the failure is capacity or layout.
--- @param capability {[uint]: {count: int, item_capacity: int, fluid_capacity: int, mask_or: int}}?
--- @param mask int
--- @param allows_all boolean
--- @param accepted {[uint]: true?}
--- @return int trains mask-eligible trains
--- @return int accepted_trains of those, trains with a layout the stop accepts
--- @return int item_capacity largest among the accepted ones
--- @return int fluid_capacity
--- @return int all_items largest among all mask-eligible ones
--- @return int all_fluid
function lint.eligible(capability, mask, allows_all, accepted)
	local trains, ok, items, fluid, all_items, all_fluid = 0, 0, 0, 0, 0, 0
	if not capability then return 0, 0, 0, 0, 0, 0 end
	for layout_id, c in pairs(capability) do
		if band(c.mask_or, mask) ~= 0 then
			trains = trains + c.count
			local ci, cf = c.item_capacity, c.fluid_capacity
			if ci > all_items then all_items = ci end
			if cf > all_fluid then all_fluid = cf end
			if allows_all or accepted[layout_id] then
				ok = ok + c.count
				if ci > items then items = ci end
				if cf > fluid then fluid = cf end
			end
		end
	end
	return trains, ok, items, fluid, all_items, all_fluid
end

--- Mask-eligible layouts the stop's allow list keeps out, counting only those that carry `need` slots (or fluid units
--- with `fluid`) when `need` is given: the trains that would serve the stop if the list accepted them.
--- @param capability {[uint]: {count: int, item_capacity: int, fluid_capacity: int, mask_or: int}}?
--- @param mask int
--- @param allows_all boolean
--- @param accepted {[uint]: true?}
--- @param need number?
--- @param fluid boolean?
--- @return int
function lint.rejected_layouts(capability, mask, allows_all, accepted, need, fluid)
	if not capability or allows_all then return 0 end
	local n = 0
	for layout_id, c in pairs(capability) do
		if band(c.mask_or, mask) ~= 0 and not accepted[layout_id] then
			local have = fluid and c.fluid_capacity or c.item_capacity
			if not need or have >= need then n = n + 1 end
		end
	end
	return n
end

--- The reason code a check predicts for a station in `role`, nil when the dispatcher has none for it.
--- @param check int LINT_*
--- @param role "r"|"p"
--- @return int? REASON_*
function lint.predicts(check, role)
	return role == "p" and LINT_PREDICTS_P[check] or LINT_PREDICTS[check]
end

--- @param t table?
local function count_keys(t)
	local n = 0
	if t then
		for _ in pairs(t) do n = n + 1 end
	end
	return n
end

--- The checks of one network of a station; returns the station's mask with this network's findings added.
--- @param keys {masks: {[string]: int}, overrides: {[string]: number}?, starved: {[string]: true}}
--- @param each boolean? a NETWORK_EACH station (its requests carry no mask of their own)
local function check_network(out, mask, id, st, accepted, allows_all, fleet, keys, net, net_mask, each)
	local S = LINT_SUBJECT_STATION
	local mask_or = fleet.mask_or[net]
	local trains, ok, items, fluid, all_items, all_fluid = 0, 0, 0, 0, 0, 0
	if not mask_or then
		if band(mask, LINT_BIT[LINT_NO_TRAIN]) == 0 then mask = find(out, mask, S, id, LINT_NO_TRAIN, net_mask, 0, net) end
	elseif net_mask == 0 then
		-- Mask 0 shares no bit with any provider or requester either, and the dispatcher's provider check comes first.
		if band(mask, LINT_BIT[LINT_MASK]) == 0 then mask = find(out, mask, S, id, LINT_MASK, 0, mask_or, net) end
	elseif band(net_mask, mask_or) == 0 then
		if band(mask, LINT_BIT[LINT_TRAIN_MASK]) == 0 then
			mask = find(out, mask, S, id, LINT_TRAIN_MASK, net_mask, mask_or, net)
		end
	else
		trains, ok, items, fluid, all_items, all_fluid = lint.eligible(fleet.capability[net], net_mask, allows_all,
			accepted)
		if trains > 0 and ok == 0 and band(mask, LINT_BIT[LINT_LAYOUT]) == 0 then
			mask = find(out, mask, S, id, LINT_LAYOUT, count_keys(accepted),
				lint.rejected_layouts(fleet.capability[net], net_mask, allows_all, accepted), net)
		end
	end
	if not st.is_r then return mask end
	local provider_masks, overrides, starved = keys.masks, keys.overrides, keys.starved
	local prefix
	for hash, req in pairs(st.requested) do
		prefix = prefix or (net .. ":")
		local key = prefix .. hash
		local pm = provider_masks[key]
		-- A request from a secondary combinator goes out under that combinator's own mask.
		local rm = not each and req.mask or net_mask
		if pm and band(pm, rm) == 0 then
			if band(mask, LINT_BIT[LINT_MASK]) == 0 then mask = find(out, mask, S, id, LINT_MASK, rm, pm, net, hash) end
		elseif req.active and starved[key] then
			if band(mask, LINT_BIT[LINT_NO_PROVIDER]) == 0 then
				mask = find(out, mask, S, id, LINT_NO_PROVIDER, 0, 0, net, hash)
			end
		end
		if trains > 0 and band(mask, LINT_BIT[LINT_CAPACITY]) == 0 then
			-- The dispatcher takes a provider's own item threshold when it is the lower one.
			local threshold = req.threshold
			local override = overrides and overrides[key]
			if override and override < threshold then threshold = override end
			local stack = stack_size(hash)
			local need, have, have_any
			if stack then
				need, have, have_any = math.ceil(threshold / stack), items, all_items
			else
				need, have, have_any = threshold, fluid, all_fluid
			end
			if need > have_any then
				mask = find(out, mask, S, id, LINT_CAPACITY, need, have_any, net, hash)
			elseif need > have and ok > 0 and band(mask, LINT_BIT[LINT_LAYOUT]) == 0 then
				mask = find(out, mask, S, id, LINT_LAYOUT, count_keys(accepted),
					lint.rejected_layouts(fleet.capability[net], net_mask, allows_all, accepted, need, not stack), net, hash)
			end
		end
	end
	return mask
end

--- The station checks of §4.12 against one snapshot record.
--- @param out LintFinding[] findings are appended
--- @param id uint
--- @param st SnapshotStation
--- @param station Station
--- @param fleet SnapshotFleet
--- @param keys {masks: {[string]: int}, overrides: {[string]: number}?, starved: {[string]: true}} the snapshot's
---   per network:item facts: providers' masks OR-ed, their lowest item threshold, the keys nobody provides
--- @param live {limit: int, occupancy_gap: boolean, occupancy: int, count: int, phantom: boolean, deliveries: int, bound: int}
--- @return int mask
function lint.check_station(out, id, st, station, fleet, keys, live)
	local mask = 0
	local S = LINT_SUBJECT_STATION
	if live.limit == 0 then mask = find(out, mask, S, id, LINT_LIMIT_ZERO, 0, 0) end
	if live.occupancy_gap then mask = find(out, mask, S, id, LINT_OCCUPANCY, live.occupancy, live.count) end
	if live.phantom then mask = find(out, mask, S, id, LINT_PHANTOM, live.deliveries, live.bound) end

	-- A stop that provides and requests: an item it has on its way out is not requested (R_IS_PROVIDING), one on its
	-- way in is not provided (P_IS_REQUESTING). The dispatcher skips both whatever the item's own threshold, so an item
	-- threshold is no way out of it; splitting the stop is.
	if st.is_r and st.is_p then
		local requested, provided, deliveries = st.requested, st.provided, st.deliveries
		for hash in pairs(requested) do
			if (deliveries[hash] or 0) < 0 or provided[hash] then
				mask = find(out, mask, S, id, LINT_SAME_ITEM, -(deliveries[hash] or 0), 0, nil, hash)
				break
			end
		end
		if band(mask, LINT_BIT[LINT_SAME_ITEM]) == 0 then
			for hash in pairs(provided) do
				if (deliveries[hash] or 0) > 0 then
					-- b = 1: on its way in (P_IS_REQUESTING), where the requested side above is on its way out.
					mask = find(out, mask, S, id, LINT_SAME_ITEM, deliveries[hash], 1, nil, hash)
					break
				end
			end
		end
	end

	local allows_all = station.allows_all_trains == true
	local accepted = station.accepted_layouts or NO_LAYOUTS
	local name, net_mask = st.network_name, st.network_mask
	if name == NETWORK_EACH then
		if type(net_mask) == "table" then
			for net, m in pairs(net_mask) do
				mask = check_network(out, mask, id, st, accepted, allows_all, fleet, keys, net, m, true)
			end
		end
	elseif name then
		mask = check_network(out, mask, id, st, accepted, allows_all, fleet, keys, name,
			type(net_mask) == "number" and net_mask or 0)
	end
	return mask
end

--- @param out LintFinding[]
--- @param group SnapshotDepotGroup?
--- @return int mask
function lint.check_depot(out, id, limit, group)
	local mask = 0
	if limit ~= 1 then mask = find(out, mask, LINT_SUBJECT_DEPOT, id, LINT_DEPOT_LIMIT, limit >= UNLIMITED and -1 or limit, 0) end
	if group and #group.ids > 1 and group.same_depot_bypass > 0 then
		mask = find(out, mask, LINT_SUBJECT_DEPOT, id, LINT_DEPOT_SHARED_NAME, #group.ids, group.same_depot_bypass)
	end
	return mask
end

--- @param out LintFinding[]
--- @param refueler {network_name: string?, network_mask: int|{[string]: int}}
--- @param fleet SnapshotFleet
--- @return int mask
function lint.check_refueler(out, id, refueler, fleet)
	local mask = 0
	each_network(refueler.network_name, refueler.network_mask, function(net, net_mask)
		local mask_or = fleet.mask_or[net] or 0
		if band(net_mask, mask_or) == 0 and mask == 0 then
			mask = find(out, mask, LINT_SUBJECT_REFUELER, id, LINT_REFUELER_MASK, net_mask, mask_or, net)
		end
	end)
	return mask
end

--- @param out LintFinding[]
--- @param live {in_group: boolean, group_depots: int?, missing_record: int?, never_refuelled: string?, tracked: int?, items: int, fluid: int?}
---   in_group: the train's vanilla group holds Cybersyn trains of more than one depot name (group_depots of them)
--- @param train Train
--- @return int mask
function lint.check_train(out, id, train, live)
	local mask = 0
	local T = LINT_SUBJECT_TRAIN
	if live.in_group then mask = find(out, mask, T, id, LINT_IN_GROUP, live.group_depots or 0, 0) end
	if live.missing_record then mask = find(out, mask, T, id, LINT_MISSING_STOP, live.missing_record, 0) end
	if live.never_refuelled then
		mask = find(out, mask, T, id, LINT_NEVER_REFUELLED, live.tracked or 0, 0, live.never_refuelled)
	end
	if live.items ~= (train.item_slot_capacity or 0) then
		mask = find(out, mask, T, id, LINT_CAPACITY_DRIFT, train.item_slot_capacity or 0, live.items)
	elseif live.fluid and live.fluid ~= (train.fluid_capacity or 0) then
		mask = find(out, mask, T, id, LINT_CAPACITY_DRIFT, train.fluid_capacity or 0, live.fluid)
	end
	return mask
end

-- ---------------------------------------------------------------- the setup job

--- @param t {[uint]: any}
--- @param out uint[]
--- @return uint[] out
local function keys_into(t, out)
	for id in pairs(t) do out[#out + 1] = id end
	return out
end

--- Trains Cybersyn has heading to or standing at each stop, and the deliveries each station's counter should hold.
--- @return {[uint]: int} dest
--- @return {[uint]: int} bound
local function occupancy_index()
	local dest, bound = {}, {}
	for _, train in pairs(storage.trains) do
		local status = train.status
		local p, r = train.p_station_id, train.r_station_id
		if status == STATUS_TO_P or status == STATUS_P then
			if p then
				dest[p] = (dest[p] or 0) + 1
				bound[p] = (bound[p] or 0) + 1
			end
			if r then bound[r] = (bound[r] or 0) + 1 end
		elseif status == STATUS_TO_R or status == STATUS_R then
			if r then
				dest[r] = (dest[r] or 0) + 1
				bound[r] = (bound[r] or 0) + 1
			end
		elseif status == STATUS_TO_F or status == STATUS_F then
			local f = train.refueler_id
			if f then dest[f] = (dest[f] or 0) + 1 end
		end
	end
	return dest, bound
end

--- A pass is set up over three updates, so no update lists thousands of ids and indexes them as well: the station
--- and depot ids (the snapshot's own sorted lists), then the refueler and train ids, then the occupancy index and
--- the names every depot and refueler is known by.
--- @param s LintState
--- @param snap Snapshot
--- @return LintJob
local function start_job(s, snap)
	local job = {
		started_tick = game.tick,
		setup = 1,
		sids = snap.station_ids or keys_into(storage.stations, {}),
		i = 0,
		ti = 0,
		findings = {},
		bits = {},
		train_bits = {},
		updates = 0,
	}
	s.job = job
	return job
end

--- @param job LintJob
--- @param snap Snapshot
local function setup_job(job, snap)
	if job.setup == 1 then
		job.dids = snap.depot_ids or keys_into(storage.depots, {})
		job.fids = keys_into(storage.refuelers, {})
		job.tids = keys_into(storage.trains, {})
		job.setup = 2
	else
		job.dest, job.bound = occupancy_index()
		-- The names schedules use are the depots', the refuelers' and the stations' (seeded from the station list in
		-- later updates, before the train checks start); any other name is looked up once per pass (stop_exists).
		local names = {}
		for name in pairs(snap.depots_by_name or NO_LAYOUTS) do names[name] = true end
		for _, refueler in pairs(storage.refuelers) do
			local stop = refueler.entity_stop
			if stop and stop.valid then names[stop.backer_name] = true end
		end
		job.names = names
		job.seeded = 0
		job.setup = nil
	end
end

--- Writes the transitions between `old` and `new` to the log.
local function transitions(subject, id, old, new)
	if old == new then return end
	for check = 1, LINT_COUNT do
		local bit = LINT_BIT[check]
		local was, is = band(old, bit) ~= 0, band(new, bit) ~= 0
		if was ~= is then diag.lint(check, subject, id, is) end
	end
end

--- A gap between two counts must hold for two planner cycles and across two passes before it is a finding:
--- trains_count also counts trains passing through, and the snapshot's index lags the counters by up to a pass.
--- @param since {[uint]: uint}
--- @return boolean
local function persisted(since, id, gap, job, cycle_ticks)
	if not gap then
		since[id] = nil
		return false
	end
	local now = game.tick
	local first = since[id]
	if not first then
		since[id] = now
		return false
	end
	return first < job.started_tick and now - first >= 2 * cycle_ticks
end

--- The refueler's network and mask as its combinator says now. Cybersyn refreshes its own copy only when a train
--- looks for a refueler, so a mask changed since then would otherwise go unnoticed until the next refuel.
--- @param refueler Refueler
--- @return {network_name: string?, network_mask: int|{[string]: int}}
local function live_refueler(refueler)
	local comb = refueler.entity_comb
	if not (comb and comb.valid) or refueler.network_name == NETWORK_EACH then return refueler end
	local signal = get_comb_params(comb).first_signal
	local name = signal and signal.name
	local mask = mod_settings.network_mask or 1
	local signals = comb.get_signals(defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green)
	for _, v in pairs(signals or {}) do
		if v.signal.name == name then mask = v.count end
	end
	return { network_name = name, network_mask = mask }
end

-- Reused for every station of a pass (the values are copied into findings, never kept).
local live = {}
local station_keys = {}

--- @param s LintState
--- @param job LintJob
--- @param snap Snapshot
local function check_record(s, job, snap, k, cycle_ticks)
	local ns, nd = #job.sids, #job.dids
	local id, subject
	if k <= ns then
		id, subject = job.sids[k], LINT_SUBJECT_STATION
	elseif k <= ns + nd then
		id, subject = job.dids[k - ns], LINT_SUBJECT_DEPOT
	else
		id, subject = job.fids[k - ns - nd], LINT_SUBJECT_REFUELER
	end
	local out = job.findings
	local mask
	if subject == LINT_SUBJECT_STATION then
		local station = storage.stations[id]
		local st = snap.stations[id]
		local stop = station and station.entity_stop
		if not (st and stop and stop.valid) then return end
		local count = stop.trains_count
		local occupancy = job.dest[id] or 0
		local deliveries, bound = station.deliveries_total or 0, job.bound[id] or 0
		live.limit = stop.trains_limit
		live.count = count
		live.occupancy = occupancy
		-- Only more trains than Cybersyn sent count: one it sent is routed through a rail record first and is not
		-- in the stop's count until it heads for the stop itself, and a delivery Cybersyn counts but no train serves
		-- is the phantom check's.
		live.occupancy_gap = persisted(s.occupancy_since, id, count > occupancy, job, cycle_ticks)
		live.deliveries = deliveries
		live.bound = bound
		live.phantom = persisted(s.phantom_since, id, deliveries ~= bound, job, cycle_ticks)
		local keys = station_keys
		keys.masks, keys.overrides, keys.starved = snap.provider_masks or NO_LAYOUTS, snap.provider_overrides,
			snap.starved or NO_LAYOUTS
		mask = lint.check_station(out, id, st, station, snap.fleet, keys, live)
	elseif subject == LINT_SUBJECT_DEPOT then
		local depot = storage.depots[id]
		local stop = depot and depot.entity_stop
		if not (stop and stop.valid) then return end
		mask = lint.check_depot(out, id, stop.trains_limit, (snap.depots_by_name or NO_LAYOUTS)[stop.backer_name])
	else
		local refueler = storage.refuelers[id]
		local stop = refueler and refueler.entity_stop
		if not (stop and stop.valid) then return end
		mask = lint.check_refueler(out, id, live_refueler(refueler), snap.fleet)
	end
	local old = s.bits[id] or 0
	if old ~= mask then transitions(subject, id, old, mask) end
	if mask ~= 0 then job.bits[id] = mask end
end

--- Live capacity of a train's wagons, as set_train_layout computes it (fluid only for normal-quality wagons, whose
--- size the prototype gives; nil when any fluid wagon has a quality).
--- @param entity LuaTrain
--- @return int items
--- @return int? fluid
local function live_capacity(entity)
	local items, fluid = 0, 0
	for _, wagon in pairs(entity.cargo_wagons) do
		local inv = wagon.get_inventory(defines.inventory.cargo_wagon)
		if inv then items = items + #inv end
	end
	for _, wagon in pairs(entity.fluid_wagons) do
		if wagon.quality.level ~= 0 then
			fluid = nil
			break
		end
		fluid = fluid + wagon.prototype.fluid_capacity
	end
	return items, fluid
end

-- Reused for every train of a pass, as `live` is for stations.
local train_live = {}

--- @param job LintJob
--- @param name string
--- @return boolean
local function stop_exists(job, name)
	local known = job.names[name]
	if known == nil then
		known = #game.train_manager.get_train_stops({ station_name = name }) > 0
		job.names[name] = known
		job.lookups = job.lookups + 1
	end
	return known
end

-- On a delivery or refuel trip a train's schedule is the one Cybersyn just built from live stops, and its wagons
-- cannot change without the train becoming a new one; reading them costs up to 120 µs per train (get_records
-- builds every record, rail targets included), so they are read between trips and carried while the train is out.
-- A train first seen on a trip has nothing to carry and is read once it is back.
local ON_TRIP = {
	[STATUS_TO_P] = true,
	[STATUS_P] = true,
	[STATUS_TO_R] = true,
	[STATUS_R] = true,
	[STATUS_TO_F] = true,
	[STATUS_F] = true,
}

--- @param s LintState
--- @param job LintJob
local function check_train(s, job, snap, id)
	local train = storage.trains[id]
	local entity = train and train.entity
	if not (entity and entity.valid) then return end
	local seen = s.train_live[id]
	if not ON_TRIP[train.status] then
		local missing
		local records = entity.get_schedule().get_records()
		for k, record in ipairs(records or NO_LAYOUTS) do
			local name = record.station
			if name and not stop_exists(job, name) then
				missing = k
				break
			end
		end
		local items, fluid = live_capacity(entity)
		if not seen then
			seen = {}
			s.train_live[id] = seen
		end
		seen.missing, seen.items, seen.fluid = missing, items, fluid
	end
	local never, tracked
	if not train.refuel_tick then
		tracked = game.tick - lint.refuel_from(train)
		if tracked >= REFUEL_GRACE then
			each_network(train.network_name, train.network_mask, function(net)
				if not never and storage.to_refuelers[net] then never = net end
			end)
		end
	end
	local tr = snap.trains[id]
	local group = tr and tr.group
	local spans = group and group ~= "" and snap.fleet.group_depots and snap.fleet.group_depots[group] or 0
	local mixed = spans > 1
	local t = train_live
	t.in_group = mixed
	t.group_depots = mixed and spans or nil
	t.never_refuelled = never
	t.tracked = tracked
	if seen then
		t.missing_record, t.items, t.fluid = seen.missing, seen.items, seen.fluid
	else
		t.missing_record, t.items, t.fluid = nil, train.item_slot_capacity or 0, nil
	end
	local mask = lint.check_train(job.findings, id, train, t)
	local old = s.train_bits[id] or 0
	if old ~= mask then transitions(LINT_SUBJECT_TRAIN, id, old, mask) end
	if mask ~= 0 then job.train_bits[id] = mask end
end

--- Drops the masks of subjects that left Cybersyn (no event: the subject is gone, not fixed).
--- @param s LintState
local function prune(s)
	for id in pairs(s.bits) do
		if not (storage.stations[id] or storage.depots[id] or storage.refuelers[id]) then
			s.bits[id] = nil
		end
	end
	for id in pairs(s.occupancy_since) do
		if not storage.stations[id] then s.occupancy_since[id] = nil end
	end
	for id in pairs(s.phantom_since) do
		if not storage.stations[id] then s.phantom_since[id] = nil end
	end
	for id in pairs(s.train_bits) do
		if not storage.trains[id] then s.train_bits[id] = nil end
	end
	for id in pairs(s.train_live) do
		if not storage.trains[id] then s.train_live[id] = nil end
	end
end

--- Writes a station's committed mask into the snapshot records the views read (the one being collected too, whose
--- records copied the old mask).
local function set_station_lint(id, mask)
	local manager = storage.manager
	for _, snap in pairs({ manager.snapshot, manager.snapshot_build }) do
		local st = snap.stations and snap.stations[id]
		if st and st.lint ~= mask then st.lint = mask end
	end
end

--- Ends the acknowledgements of setup findings that cleared with this pass (the world-scan checks are the world
--- scan's to end).
--- @param s LintState
local function resolve_acks(s)
	local acks = storage.acks
	if not (acks and acks.lint and next(acks.lint)) then return end
	local ended = {}
	for key, by in pairs(acks.lint) do
		local mask = key < 0 and s.train_bits[-key] or s.bits[key] or 0
		for check in pairs(by) do
			if not WORLD_CHECKS[check] and band(mask, LINT_BIT[check] or 0) == 0 then
				ended[#ended + 1] = { key, check }
			end
		end
	end
	for _, e in ipairs(ended) do diag.resolve_lint_ack(e[1], e[2]) end
end

--- A pass's masks become the current ones together with its findings, so st.lint, the Stations Setup chip, the
--- Overview's misconfigured line and the Problems tab always count the same pass.
--- @param s LintState
--- @param job LintJob
local function commit(s, job)
	local old, new = s.bits, job.bits
	for id, m in pairs(new) do
		if old[id] ~= m and storage.stations[id] then set_station_lint(id, m) end
	end
	for id in pairs(old) do
		if not new[id] and storage.stations[id] then set_station_lint(id, 0) end
	end
	s.bits = new
	s.train_bits = job.train_bits
	resolve_acks(s)
end

--- Advances the setup job by one update's worth: the cursor lists in the first update of a pass, the per-pass
--- indexes in the second, then up to `records` station/depot/refueler records and `trains` trains per update.
--- @param records int?
--- @param trains int?
--- @return boolean completed a pass
function lint.step(records, trains)
	local snap = storage.manager.snapshot
	-- The fleet facts and station records come from a complete pass.
	if not (snap and snap.tick) then return false end
	local s = lint.state()
	local job = s.job
	if not job then
		job = start_job(s, snap)
		job.updates = 1
		if not records then return false end
	end
	while job.setup do
		setup_job(job, snap)
		if not records then
			job.updates = job.updates + 1
			return false
		end
	end
	job.updates = job.updates + 1
	job.lookups = 0
	local cycle = storage.stats and storage.stats.cycle
	local cycle_ticks = math.max(cycle and cycle.ticks_last or 0, 1)
	local n = #job.sids + #job.dids + #job.fids
	local stop_at = math.min(n, job.i + (records or RECORDS_PER_UPDATE))
	while job.i < stop_at do
		job.i = job.i + 1
		check_record(s, job, snap, job.i, cycle_ticks)
	end
	local nt = #job.tids
	local sids = job.sids
	if job.seeded < #sids then
		local names, stations = job.names, snap.stations
		local last = math.min(#sids, job.seeded + (records and records * 10 or SEED_PER_UPDATE))
		for k = job.seeded + 1, last do
			local st = stations[sids[k]]
			if st then names[st.name] = true end
		end
		job.seeded = last
	else
		local last = math.min(nt, job.ti + (trains or TRAINS_PER_UPDATE))
		local lookups = trains and math.huge or LOOKUPS_PER_UPDATE
		while job.ti < last and job.lookups < lookups do
			job.ti = job.ti + 1
			check_train(s, job, snap, job.tids[job.ti])
		end
	end
	if job.i >= n and job.ti >= nt and job.seeded >= #sids then
		commit(s, job)
		s.findings = job.findings
		s.pass = s.pass + 1
		s.tick = game.tick
		s.updates = job.updates
		s.job = nil
		prune(s)
		return true
	end
	return false
end

--- One manager update of the setup job (only while a window is open; see collector.tick).
function lint.tick()
	lint.step()
end

--- Runs a whole fresh pass now (dev and tests).
--- @return LintState
function lint.run_to_completion()
	local s = lint.state()
	s.job = nil
	local guard = 0
	while not lint.step(math.huge, math.huge) do
		guard = guard + 1
		if guard > 4 then break end
	end
	return s
end

--- Findings of the last complete pass (read only).
--- @return LintFinding[]
function lint.findings()
	local manager = storage.manager
	local s = manager and manager.lint
	return s and s.findings or {}
end

-- ---------------------------------------------------------------- the world scan (B8)

local PRIMARY = {
	[MODE_PRIMARY_IO] = true,
	[MODE_PRIMARY_IO_ACTIVE] = true,
	[MODE_PRIMARY_IO_FAILED_REQUEST] = true,
}

--- @param out LintFinding[]
local function world_find(out, check, entity, message)
	local subject = entity.type == "train-stop" and LINT_SUBJECT_STOP or LINT_SUBJECT_COMBINATOR
	out[#out + 1] = { subject = subject, id = entity.unit_number, check = check, entity = entity, message = message }
end

--- Starts the chunked world scan for `player_index` (nil = the server). Refused while a scan runs: a restart would
--- throw away the work done and let anyone keep the scan going forever.
--- @param player_index uint?
--- @param quiet boolean? no chat report when it completes (the Problems tab shows the result)
--- @return int? stops to check, nil when a scan is already running
function lint.scan_world(player_index, quiet)
	local s = lint.state()
	if s.world_job then return nil end
	local stops = game.train_manager.get_train_stops({})
	s.world_job = {
		player_index = player_index,
		started_tick = game.tick,
		stops = stops,
		phase = 1,
		k = 0,
		-- name -> bit 1 station, 2 depot, 4 refueler (the stops registered under that name)
		names = {},
		combs = keys_into(storage.to_comb, {}),
		reported = {},
		findings = {},
		quiet = quiet,
	}
	return #stops
end

--- How far the running world scan is, 0..1, or nil when none runs. The stops are most of the work.
--- @return number?
function lint.world_progress()
	local manager = storage.manager
	local job = manager and manager.lint and manager.lint.world_job
	if not job then return nil end
	if job.phase == 1 then return 0 end
	if job.phase == 2 then return 0.9 * job.k / math.max(#job.stops, 1) end
	return 0.9 + 0.1 * job.k / math.max(#job.combs, 1)
end

--- Ends the acknowledgements of world-scan findings the latest scan no longer has.
--- @param findings LintFinding[]
local function resolve_world_acks(findings)
	local acks = storage.acks
	if not (acks and acks.lint and next(acks.lint)) then return end
	local found = {}
	for _, f in ipairs(findings) do
		local key = lint.subject_key(f.subject, f.id)
		found[key] = found[key] or {}
		found[key][f.check] = true
	end
	local ended = {}
	for key, by in pairs(acks.lint) do
		for check in pairs(by) do
			if WORLD_CHECKS[check] and not (found[key] and found[key][check]) then ended[#ended + 1] = { key, check } end
		end
	end
	for _, e in ipairs(ended) do diag.resolve_lint_ack(e[1], e[2]) end
end

--- @param job table
--- @param stop LuaEntity
local function scan_stop(job, stop)
	local id = stop.unit_number
	local out = job.findings
	local to_stop, params = storage.to_stop, storage.to_comb_params
	local pos = stop.position
	-- One tile wider than the box Cybersyn adopts combinators from, so a combinator rotated away from the stop (whose
	-- own search box misses it) is still found.
	local found = stop.surface.find_entities_filtered({
		area = { { pos.x - 3, pos.y - 3 }, { pos.x + 3, pos.y + 3 } },
		name = { COMBINATOR_NAME, "entity-ghost" },
	})
	local primary, secondary, depot, refueler, attached = 0, 0, 0, 0, 0
	local ghost, wrong
	for _, comb in pairs(found) do
		if comb.valid then
			if comb.name == "entity-ghost" then
				if comb.ghost_name == COMBINATOR_NAME then ghost = ghost or comb end
			else
				local unit = comb.unit_number
				local p = params[unit]
				local op = p and p.operation
				if to_stop[unit] == stop then
					attached = attached + 1
					if PRIMARY[op] then
						primary = primary + 1
					elseif op == MODE_SECONDARY_IO then
						secondary = secondary + 1
					elseif op == MODE_DEPOT then
						depot = depot + 1
					elseif op == MODE_REFUELER then
						refueler = refueler + 1
					end
				elseif to_stop[unit] == nil and op ~= MODE_WAGON then
					wrong = wrong or comb
				end
			end
		end
	end
	local registered = storage.stations[id] or storage.depots[id] or storage.refuelers[id]
	if primary > 1 then world_find(out, LINT_DOUBLE_COMB, stop, "double-station") end
	if secondary > 1 then world_find(out, LINT_DOUBLE_COMB, stop, "double-station-control") end
	if depot > 1 then world_find(out, LINT_DOUBLE_COMB, stop, "double-depot") end
	if refueler > 1 then world_find(out, LINT_DOUBLE_COMB, stop, "double-refueler") end
	if primary > 0 and depot > 0 then world_find(out, LINT_DOUBLE_COMB, stop, "station-and-depot") end
	if primary > 0 and refueler > 0 then world_find(out, LINT_DOUBLE_COMB, stop, "station-and-refueler") end
	if depot > 0 and refueler > 0 then world_find(out, LINT_DOUBLE_COMB, stop, "depot-and-refueler") end
	if not registered then
		if ghost then
			world_find(out, LINT_GHOST_COMB, stop, "ghost-combinator")
		elseif attached > 0 then
			world_find(out, LINT_NO_COMB, stop, "stop-no-combinator")
		end
	end
	if wrong then
		job.reported[wrong.unit_number] = true
		world_find(out, LINT_WRONG_SIDE, stop, "wrong-side-combinator")
	end
	local name = stop.backer_name
	local roles = job.names[name] or 0
	if stop.train_stop_priority ~= 50 and roles ~= 0 then world_find(out, LINT_PRIORITY, stop, "non-default-priority") end
	if band(roles, 2) ~= 0 and not storage.depots[id] then
		world_find(out, LINT_NAME_OVERLAP, stop, "name-overlap-with-depot")
	end
end

--- One update of the world scan: names of the registered stops, then the stops, then the combinators no stop owns.
--- @return boolean done
function lint.world_tick()
	local s = lint.state()
	local job = s.world_job
	if not job then return true end
	if job.phase == 1 then
		local ids = job.name_ids
		if not ids then
			ids = {}
			for _, pair in ipairs({ { storage.stations, 1 }, { storage.depots, 2 }, { storage.refuelers, 4 } }) do
				for id in pairs(pair[1]) do ids[#ids + 1] = { id, pair[2] } end
			end
			job.name_ids = ids
		end
		local last = math.min(#ids, job.k + WORLD_NAMES_PER_UPDATE)
		for k = job.k + 1, last do
			local id, role = ids[k][1], ids[k][2]
			local rec = storage.stations[id] or storage.depots[id] or storage.refuelers[id]
			local stop = rec and rec.entity_stop
			if stop and stop.valid then
				local name = stop.backer_name
				job.names[name] = bor(job.names[name] or 0, role)
			end
		end
		job.k = last
		if last >= #ids then job.phase, job.k = 2, 0 end
	elseif job.phase == 2 then
		local stops = job.stops
		local last = math.min(#stops, job.k + WORLD_STOPS_PER_UPDATE)
		for k = job.k + 1, last do
			local stop = stops[k]
			if stop.valid then scan_stop(job, stop) end
		end
		job.k = last
		if last >= #stops then job.phase, job.k = 3, 0 end
	else
		local combs = job.combs
		local last = math.min(#combs, job.k + WORLD_COMBS_PER_UPDATE)
		local to_comb, to_stop, params = storage.to_comb, storage.to_stop, storage.to_comb_params
		for k = job.k + 1, last do
			local unit = combs[k]
			local comb = to_comb[unit]
			if comb and comb.valid and comb.name == COMBINATOR_NAME and not to_stop[unit] and not job.reported[unit] then
				local p = params[unit]
				if not (p and p.operation == MODE_WAGON) then
					world_find(job.findings, LINT_DERELICT_COMB, comb, "derelict-combinator")
				end
			end
		end
		job.k = last
		if last >= #combs then
			s.world = { tick = game.tick, findings = job.findings, player_index = job.player_index,
				stops = #job.stops, quiet = job.quiet }
			s.world_job = nil
			resolve_world_acks(job.findings)
			lint.report_world(s.world)
			return true
		end
	end
	return false
end

--- Runs the world scan to completion now (dev and tests; the command and the Problems tab use the chunked job). A
--- scan already running is finished instead.
--- @return {tick: uint, findings: LintFinding[]}
function lint.scan_world_now(player_index, quiet)
	lint.scan_world(player_index, quiet)
	local s = lint.state()
	s.world_job.quiet = quiet
	while not lint.world_tick() do end
	return s.world
end

--- The stop or combinator of the last world scan with this unit number (most entities cannot be looked up by unit
--- number, so links to unregistered ones go through the scan that found them).
--- @param unit uint
--- @return LuaEntity?
function lint.world_entity(unit)
	local manager = storage.manager
	local world = manager and manager.lint and manager.lint.world
	if not world then return nil end
	for _, f in ipairs(world.findings) do
		local e = f.entity
		if f.id == unit and e and e.valid then return e end
	end
	return nil
end

--- @param entity LuaEntity
local function gps_text(entity)
	local pos = entity.position
	return string.format("[gps=%f,%f,%s]", pos.x, pos.y, entity.surface.name)
end

--- Prints the world scan the way /cybersyn-find-problems always has: one line per problem with a link to the stop
--- or the combinator's position, or the all-clear line.
--- @param world {findings: LintFinding[], player_index: uint?, quiet: boolean?}
function lint.report_world(world)
	if world.quiet then return end
	local player = world.player_index and game.get_player(world.player_index)
	local function say(message)
		if player and player.valid then player.print(message) else game.print(message) end
	end
	for _, f in ipairs(world.findings) do
		local e = f.entity
		local where
		if e and e.valid then
			if e.type == "train-stop" then
				where = "[train-stop=" .. e.unit_number .. "]"
			else
				where = { "", gps_text(e), " ", e.localised_name }
			end
		end
		local text = { "cybersyn-problems." .. f.message }
		say(where and { "", where, " ", text } or text)
	end
	if #world.findings == 0 then say({ "cybersyn-problems.no-problems-found" }) end
end

return lint
