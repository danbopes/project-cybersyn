-- Incremental snapshot of everything the manager renders, so render code never walks entities or reads
-- circuit signals itself. It only runs while a manager window is open and unpaused.
-- Aggregates (inventory_all, starved, station counts) are double-buffered and swap when a pass completes.
-- Station records are replaced in place as the pass reaches them, and trains/fleet/depots/alerts are replaced
-- at the start of each pass: a second full copy would roughly double the memory peak (measured ~7.5 MB per
-- copy on a 2,030-station save).

local collector = {}

-- A full pass over the stations is spread over this many manager updates.
local PASS_UPDATES = 20
local MIN_BATCH = 25
local MAX_BATCH = 200
-- Opening the window on a snapshot older than this finishes a fresh pass synchronously.
local STALE_ON_OPEN_TICKS = 600

local WORKING = defines.entity_status.working
local LOW_POWER = defines.entity_status.low_power
local RED = defines.wire_connector_id.circuit_red
local GREEN = defines.wire_connector_id.circuit_green

--- @class SnapshotRequest
--- @field count int negative signal sum
--- @field threshold int effective request threshold in items/fluid units
--- @field active boolean |count| >= threshold

--- @class SnapshotStation
--- @field id uint
--- @field name string
--- @field name_lower string
--- @field surface_index uint
--- @field network_name string?
--- @field network_mask int|{[string]: int}
--- @field is_p boolean
--- @field is_r boolean
--- @field is_stack boolean
--- @field comb_ok boolean station combinator working or low power
--- @field comb2_ok boolean? nil when the station has no control combinator
--- @field warming_up boolean
--- @field trains_limit int
--- @field deliveries_total int
--- @field last_delivery_tick int?
--- @field priority int?
--- @field provided {[string]: int}
--- @field requested {[string]: SnapshotRequest}
--- @field deliveries {[string]: int} >0 incoming, <0 outgoing
--- @field control {[string]: int} virtual signals on the station combinator
--- @field control2 {[string]: int} virtual signals on the control combinator
--- @field thresholds {[string]: int} per-item request thresholds from the control combinator, in items
--- @field wait {[string]: uint} request start tick per item hash
--- @field longest_wait_start uint?
--- @field secondary boolean
--- @field secondary_count int
--- @field tiebreak string name, then id: a unique sort key, built once per record instead of once per sort

--- @class SnapshotTrain
--- @field id uint
--- @field status uint STATUS_*
--- @field layout_id uint?
--- @field depot_id uint?
--- @field depot_name string
--- @field network_name string?
--- @field network_mask int|{[string]: int}
--- @field p_station_id uint?
--- @field r_station_id uint?
--- @field refueler_id uint?
--- @field manifest {name: string, quality: string?, count: int, hash: string}[]
--- @field manifest_hashes {[string]: int}
--- @field surface_index uint?
--- @field is_available boolean

--- @class Snapshot
--- @field tick uint? game tick the last pass completed; nil = never collected
--- @field started_tick uint
--- @field station_count int
--- @field train_count int
--- @field secondary_count int stations with at least one secondary inventory combinator contributing
--- @field stations {[uint]: SnapshotStation} updated in place during a pass; each record is at most one pass old
--- @field trains {[uint]: SnapshotTrain}
--- @field inventory_all {provided: {[string]: {count: int, stations: int}}, requested: {[string]: {count: int, stations: int, earliest_wait_start: uint?}}, in_transit: {[string]: {count: int, stations: int}}}
--- @field starved {[string]: true} "network:hash" request keys with no provider on that network
--- @field starved_items {[string]: true}
--- @field starved_source "economy"|"snapshot"
--- @field starved_version int bumped only when the contents of `starved` change; equal sets keep their table
--- @field fleet {total: int, by_status: {[uint]: int}, available_by_network: {[string]: int}, by_layout: {[uint]: int}}
--- @field depots {total: int, parked: int}
--- @field alerts {train_id: uint, kind: int, since_tick: int}[]

local function new_inventory()
	return { provided = {}, requested = {}, in_transit = {} }
end

--- @return Snapshot
function collector.empty()
	return {
		tick = nil,
		started_tick = 0,
		station_count = 0,
		train_count = 0,
		secondary_count = 0,
		stations = {},
		trains = {},
		inventory_all = new_inventory(),
		starved = {},
		starved_items = {},
		starved_source = "snapshot",
		starved_version = 0,
		fleet = { total = 0, by_status = {}, available_by_network = {}, by_layout = {} },
		depots = { total = 0, parked = 0 },
		alerts = {},
	}
end

--- Called from on_init and on_migration; a stored snapshot may hold an outdated shape, and migration closes
--- every window anyway, so both buffers start over.
function collector.init()
	local manager = storage.manager
	manager.snapshot = collector.empty()
	manager.snapshot_build = nil
	collector.reset_log()
end

--- Starts a new change log epoch: readers holding a position from an older epoch must rebuild from scratch.
function collector.reset_log()
	local manager = storage.manager
	local old = manager.collect_log
	manager.collect_log = { epoch = (old and old.epoch or 0) + 1, base = 0, ids = {} }
end

--- Ids of station records replaced or removed since `pos`, so per-player caches can update only those.
--- Returns nil when the caller's position is from another epoch or no longer covered by the log.
--- @param epoch int?
--- @param pos int?
--- @return uint[]? ids
--- @return integer first index into ids
--- @return integer last index into ids
function collector.changed_since(epoch, pos)
	local log = storage.manager.collect_log
	if not log or not epoch or not pos or log.epoch ~= epoch then return nil, 0, 0 end
	local n = #log.ids
	if pos < log.base or pos > log.base + n then return nil, 0, 0 end
	return log.ids, pos - log.base + 1, n
end

--- @return int epoch
--- @return int pos
function collector.log_position()
	local log = storage.manager.collect_log
	if not log then
		collector.reset_log()
		log = storage.manager.collect_log
	end
	return log.epoch, log.base + #log.ids
end

local function log_change(id)
	local log = storage.manager.collect_log
	if not log then
		collector.reset_log()
		log = storage.manager.collect_log
	end
	log.ids[#log.ids + 1] = id
end

--- Drops both buffers once no window is open: the snapshot is several MB on large bases and would otherwise
--- be written into every save. Opening a window rebuilds it through ensure_fresh.
function collector.release_if_unused()
	local manager = storage.manager
	if not manager then return end
	for _, player_data in pairs(manager.players) do
		if player_data.is_manager_open then return end
	end
	if manager.snapshot and manager.snapshot.tick == nil and not manager.snapshot_build then return end
	manager.snapshot = collector.empty()
	manager.snapshot_build = nil
	collector.reset_log()
end

--- The last complete snapshot (never nil).
--- @return Snapshot
function collector.get()
	local manager = storage.manager
	local snapshot = manager.snapshot
	if not snapshot then
		snapshot = collector.empty()
		manager.snapshot = snapshot
		collector.reset_log()
	end
	return snapshot
end

local function copy(t)
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in pairs(t) do
		out[k] = v
	end
	return out
end

--- @param network_name string?
--- @param network_mask any
--- @return string[]
local function networks_of(network_name, network_mask)
	if network_name == NETWORK_EACH then
		local out = {}
		if type(network_mask) == "table" then
			for name in pairs(network_mask) do
				out[#out + 1] = name
			end
		end
		return out
	elseif network_name then
		return { network_name }
	end
	return {}
end

local function summarize_trains(b)
	local trains = {}
	local fleet = { total = 0, by_status = {}, available_by_network = {}, by_layout = {} }
	local depot_names = {}
	local depots = storage.depots
	for id, train in pairs(storage.trains) do
		local entity = train.entity
		if entity and entity.valid then
			local depot_id = train.depot_id
			local depot_name = depot_id and depot_names[depot_id]
			if depot_id and not depot_name then
				local depot = depots[depot_id]
				local stop = depot and depot.entity_stop
				depot_name = (stop and stop.valid) and stop.backer_name or ""
				depot_names[depot_id] = depot_name
			end
			local manifest = {}
			local manifest_hashes = {}
			if train.manifest then
				for i, item in ipairs(train.manifest) do
					local hash = hash_item(item.name, item.quality)
					manifest[i] = { name = item.name, quality = item.quality, count = item.count, hash = hash }
					manifest_hashes[hash] = (manifest_hashes[hash] or 0) + item.count
				end
			end
			local any = get_any_train_entity(entity)
			trains[id] = {
				id = id,
				status = train.status,
				layout_id = train.layout_id,
				depot_id = depot_id,
				depot_name = depot_name or "",
				network_name = train.network_name,
				network_mask = copy(train.network_mask),
				p_station_id = train.p_station_id,
				r_station_id = train.r_station_id,
				refueler_id = train.refueler_id,
				manifest = manifest,
				manifest_hashes = manifest_hashes,
				surface_index = any and any.surface_index or nil,
				is_available = train.is_available == true,
			}
			fleet.total = fleet.total + 1
			local status = train.status or STATUS_D
			fleet.by_status[status] = (fleet.by_status[status] or 0) + 1
			if train.layout_id then
				fleet.by_layout[train.layout_id] = (fleet.by_layout[train.layout_id] or 0) + 1
			end
		end
	end
	for network_name, ids in pairs(storage.available_trains or {}) do
		local n = 0
		for _ in pairs(ids) do
			n = n + 1
		end
		fleet.available_by_network[network_name] = n
	end

	local depot_total, parked = 0, 0
	for _, depot in pairs(depots) do
		depot_total = depot_total + 1
		if depot.available_train_id then parked = parked + 1 end
	end

	local alerts = {}
	local ticks_per_main_tick = (mod_settings.tps or 0) > 0 and math.ceil(60 / mod_settings.tps) or 1
	for train_id, data in pairs(storage.active_alerts or {}) do
		local since = data[3] and (game.tick - (storage.total_ticks - data[3]) * ticks_per_main_tick) or game.tick
		alerts[#alerts + 1] = { train_id = train_id, kind = data[2], since_tick = since }
	end
	table.sort(alerts, function(a, c) return a.train_id < c.train_id end)

	-- Written straight into the live snapshot for the same memory reason as station records.
	local live = collector.get()
	live.trains = trains
	live.train_count = fleet.total
	live.fleet = fleet
	live.depots = { total = depot_total, parked = parked }
	live.alerts = alerts
	b.trains = nil
end

local function start_pass(manager)
	local ids = {}
	for id in pairs(storage.stations) do
		ids[#ids + 1] = id
	end
	table.sort(ids)
	local b = collector.empty()
	b.stations = nil
	b.started_tick = game.tick
	b.ids = ids
	b.i = 0
	b.seen = {}
	b.r_keys = {}
	b.p_keys = {}
	-- Every reader is at most one update behind, so entries from the previous pass are no longer needed.
	local log = manager.collect_log
	if log then
		log.base = log.base + #log.ids
		log.ids = {}
	end
	summarize_trains(b)
	manager.snapshot_build = b
	return b
end

local function read_signals(entity)
	if entity and entity.valid then
		local status = entity.status
		if status == WORKING or status == LOW_POWER then
			return entity.get_signals(RED, GREEN), true
		end
		return nil, false
	end
	return nil, nil
end

local function add_request(requested, hash, count, threshold)
	local active = -count >= threshold
	local req = requested[hash]
	if req then
		req.count = req.count + count
		if threshold < req.threshold then req.threshold = threshold end
		req.active = req.active or active
	else
		requested[hash] = { count = count, threshold = threshold, active = active }
	end
end

local function item_threshold(station, hash, name, item_type, base_item, base_fluid)
	local threshold = station.item_thresholds and station.item_thresholds[hash]
	if not threshold then
		threshold = item_type == "fluid" and (base_fluid or base_item) or base_item
	end
	if station.is_stack and item_type == "item" then
		threshold = threshold * (get_stack_size(nil, name) or 1)
	end
	return threshold
end

-- Virtual signals a secondary inventory combinator consumes as settings; every other virtual signal on a
-- NETWORK_EACH station's secondary is one of its networks (tick_poll_station).
local SECONDARY_SETTINGS = {
	[SIGNAL_PRIORITY] = true,
	[REQUEST_THRESHOLD] = true,
	[REQUEST_FLUID_THRESHOLD] = true,
	[RESERVED_FLUID_CAPACITY] = true,
}

--- Records which network:item pairs a combinator provides or actively requests, for the starved derivation.
--- The planner registers each combinator under its own networks, so this runs per source, not on the merge.
local function add_keys(b, networks, provided, requested)
	local r_keys, p_keys = b.r_keys, b.p_keys
	for hash in pairs(provided) do
		for i = 1, #networks do
			p_keys[networks[i] .. ":" .. hash] = true
		end
	end
	for hash, req in pairs(requested) do
		if req.active then
			for i = 1, #networks do
				r_keys[networks[i] .. ":" .. hash] = true
			end
		end
	end
end

--- Mirrors tick_poll_station: negative = request when is_r, positive = provide when is_p.
local function classify(station, signals, st, base_item, base_fluid, control)
	local network_name = station.network_name
	for _, v in pairs(signals) do
		local signal = v.signal
		local name = signal.name
		local item_type = signal.type or "item"
		local count = v.count
		if name and name ~= network_name then
			if item_type == "virtual" then
				if control then control[name] = count end
			elseif item_type == "item" or item_type == "fluid" then
				local hash = hash_signal(signal)
				if count < 0 then
					if station.is_r then
						add_request(st.requested, hash, count, item_threshold(station, hash, name, item_type, base_item, base_fluid))
					end
				elseif count > 0 and station.is_p then
					st.provided[hash] = (st.provided[hash] or 0) + count
				end
			end
		end
	end
end

--- @param b Snapshot
--- @param id uint
--- @param station Station
local function collect_station(b, id, station)
	local stop = station.entity_stop
	if not (stop and stop.valid) then return end
	local comb1 = station.entity_comb1
	if not (comb1 and comb1.valid) then return end

	local name = stop.backer_name
	local default_item = station.r_threshold or mod_settings.r_threshold or 1
	local default_fluid = station.r_fluid_threshold or (mod_settings.r_fluid_threshold and mod_settings.r_fluid_threshold > 0 and mod_settings.r_fluid_threshold) or nil

	--- @type SnapshotStation
	local st = {
		id = id,
		name = name,
		name_lower = string.lower(name),
		tiebreak = string.format("%s\0%010d", string.lower(name), id),
		surface_index = stop.surface_index,
		network_name = station.network_name,
		network_mask = copy(station.network_mask),
		is_p = station.is_p == true,
		is_r = station.is_r == true,
		is_stack = station.is_stack == true,
		comb_ok = false,
		comb2_ok = nil,
		warming_up = station.is_warming_up == true,
		trains_limit = station.trains_limit or 0,
		deliveries_total = station.deliveries_total or 0,
		last_delivery_tick = station.last_delivery_tick,
		priority = station.priority,
		provided = {},
		requested = {},
		deliveries = copy(station.deliveries) or {},
		control = {},
		control2 = {},
		thresholds = {},
		wait = mod_settings.track_request_wait_times and copy(station.request_start_ticks) or {},
		longest_wait_start = nil,
		secondary = false,
		secondary_count = 0,
	}

	-- The planner skips warming-up stations and stations without a network, so they neither provide nor starve.
	local keyed = not st.warming_up and st.network_name ~= nil
	local is_each = st.network_name == NETWORK_EACH

	local signals1, ok1 = read_signals(comb1)
	st.comb_ok = ok1 == true
	if signals1 then
		classify(station, signals1, st, default_item, default_fluid, st.control)
		if keyed then
			add_keys(b, networks_of(st.network_name, st.network_mask), st.provided, st.requested)
		end
	end

	local comb2 = station.entity_comb2
	if comb2 then
		local signals2, ok2 = read_signals(comb2)
		st.comb2_ok = ok2 == true
		if signals2 then
			for _, v in pairs(signals2) do
				local signal = v.signal
				local item_type = signal.type or "item"
				if signal.name then
					if item_type == "virtual" then
						st.control2[signal.name] = v.count
					elseif item_type == "item" or item_type == "fluid" then
						local threshold = math.abs(v.count)
						if station.is_stack and item_type == "item" then
							threshold = threshold * (get_stack_size(nil, signal.name) or 1)
						end
						st.thresholds[hash_signal(signal)] = threshold
					end
				end
			end
		end
	end

	if station.secondary_inv_combs then
		for _, sec in pairs(station.secondary_inv_combs) do
			local signals = read_signals(sec)
			if signals then
				local sec_item, sec_fluid = default_item, default_fluid
				local sec_networks = is_each and {} or nil
				for _, v in pairs(signals) do
					local signal = v.signal
					if signal.type == "virtual" then
						if signal.name == REQUEST_THRESHOLD then
							sec_item = math.abs(v.count)
						elseif signal.name == REQUEST_FLUID_THRESHOLD then
							sec_fluid = math.abs(v.count)
						elseif sec_networks and signal.name and not SECONDARY_SETTINGS[signal.name] then
							sec_networks[#sec_networks + 1] = signal.name
						end
					end
				end
				local own = { provided = {}, requested = {} }
				classify(station, signals, own, sec_item, sec_fluid, nil)
				if keyed then
					add_keys(b, sec_networks or networks_of(st.network_name, st.network_mask), own.provided, own.requested)
				end
				for hash, count in pairs(own.provided) do
					st.provided[hash] = (st.provided[hash] or 0) + count
				end
				for hash, req in pairs(own.requested) do
					add_request(st.requested, hash, req.count, req.threshold)
				end
				st.secondary_count = st.secondary_count + 1
				st.secondary = true
			end
		end
	end

	local inv = b.inventory_all

	for hash, count in pairs(st.provided) do
		local agg = inv.provided[hash]
		if agg then
			agg.count = agg.count + count
			agg.stations = agg.stations + 1
		else
			inv.provided[hash] = { count = count, stations = 1 }
		end
	end

	local wait = st.wait
	for hash, req in pairs(st.requested) do
		if req.active then
			local start = wait[hash]
			if start and (not st.longest_wait_start or start < st.longest_wait_start) then
				st.longest_wait_start = start
			end
			local agg = inv.requested[hash]
			if agg then
				agg.count = agg.count + req.count
				agg.stations = agg.stations + 1
				if start and (not agg.earliest_wait_start or start < agg.earliest_wait_start) then
					agg.earliest_wait_start = start
				end
			else
				inv.requested[hash] = { count = req.count, stations = 1, earliest_wait_start = start }
			end
		end
	end

	for hash, count in pairs(st.deliveries) do
		if count > 0 then
			local agg = inv.in_transit[hash]
			if agg then
				agg.count = agg.count + count
				agg.stations = agg.stations + 1
			else
				inv.in_transit[hash] = { count = count, stations = 1 }
			end
		end
	end

	collector.get().stations[id] = st
	log_change(id)
	b.seen[id] = true
	b.station_count = b.station_count + 1
	if st.secondary then b.secondary_count = b.secondary_count + 1 end
end

local function same_keys(a, b)
	if not a or not b then return false end
	for k in pairs(a) do
		if b[k] == nil then return false end
	end
	for k in pairs(b) do
		if a[k] == nil then return false end
	end
	return true
end

local function hash_of_key(key)
	local s = string.find(key, ":", 1, true)
	return s and string.sub(key, s + 1) or key
end

--- The planner's economy is only complete between polling and the next init, i.e. while dispatching.
local function capture_economy_starved(b)
	if storage.tick_state ~= STATE_DISPATCH then return end
	local economy = storage.economy
	if not economy then return end
	local p_stops = economy.all_p_stops
	local starved, items = {}, {}
	for key in pairs(economy.all_r_stops) do
		if not p_stops[key] then
			starved[key] = true
			items[hash_of_key(key)] = true
		end
	end
	b.starved = starved
	b.starved_items = items
	b.starved_source = "economy"
end

local function finish_pass(manager, b)
	if b.starved_source ~= "economy" then
		local starved, items = {}, {}
		local p_keys = b.p_keys
		for key in pairs(b.r_keys) do
			if not p_keys[key] then
				starved[key] = true
				items[hash_of_key(key)] = true
			end
		end
		b.starved = starved
		b.starved_items = items
		b.starved_source = "snapshot"
	end
	local live = collector.get()
	if same_keys(b.starved, live.starved) then
		b.starved = live.starved
		b.starved_items = live.starved_items
		b.starved_version = live.starved_version
	else
		b.starved_version = (live.starved_version or 0) + 1
	end
	local stations = live.stations
	local seen = b.seen
	for id in pairs(stations) do
		if not seen[id] then
			stations[id] = nil
			log_change(id)
		end
	end
	b.stations = stations
	b.trains = live.trains
	b.train_count = live.train_count
	b.fleet = live.fleet
	b.depots = live.depots
	b.alerts = live.alerts
	b.ids = nil
	b.i = nil
	b.seen = nil
	b.r_keys = nil
	b.p_keys = nil
	b.tick = game.tick
	manager.snapshot = b
	manager.snapshot_build = nil
end

--- Advances the current pass by up to `budget` stations (default: the per-update batch size).
--- @param budget number?
--- @return boolean completed
function collector.step(budget)
	local manager = storage.manager
	local b = manager.snapshot_build
	if not b then
		b = start_pass(manager)
		-- Summarising the fleet costs about as much as a batch of stations, so a budgeted step stops here.
		if not budget then return false end
	end
	local ids = b.ids
	local n = #ids
	budget = budget or math.min(math.max(math.ceil(n / PASS_UPDATES), MIN_BATCH), MAX_BATCH)
	local stations = storage.stations
	local i = b.i
	local stop = math.min(n, i + budget)
	while i < stop do
		i = i + 1
		local id = ids[i]
		local station = stations[id]
		if station then
			collect_station(b, id, station)
		end
	end
	b.i = i
	if b.starved_source ~= "economy" then
		capture_economy_starved(b)
	end
	if i >= n then
		finish_pass(manager, b)
		return true
	end
	return false
end

function collector.run_to_completion()
	while not collector.step(math.huge) do end
end

--- Freshens a missing or stale snapshot synchronously so a newly opened window has current data.
function collector.ensure_fresh()
	local snapshot = collector.get()
	if not snapshot.tick or game.tick - snapshot.tick > STALE_ON_OPEN_TICKS then
		storage.manager.snapshot_build = nil
		collector.run_to_completion()
	end
end

--- True when any open manager is unpaused.
--- @return boolean
function collector.wanted()
	for _, player_data in pairs(storage.manager.players) do
		if player_data.is_manager_open and not player_data.paused then
			return true
		end
	end
	return false
end

--- One manager update's worth of collection; no-op unless a manager is open and unpaused.
--- @return boolean ran
function collector.tick()
	if not storage.manager or not collector.wanted() then return false end
	collector.step()
	return true
end

--- Aggregates provided/requested/in-transit over the stations accepted by `pred`, in the inventory_all shape.
--- @param snapshot Snapshot
--- @param pred fun(st: SnapshotStation): boolean
function collector.aggregate(snapshot, pred)
	local inv = new_inventory()
	for _, st in pairs(snapshot.stations) do
		if pred(st) then
			for hash, count in pairs(st.provided) do
				local agg = inv.provided[hash]
				if agg then
					agg.count = agg.count + count
					agg.stations = agg.stations + 1
				else
					inv.provided[hash] = { count = count, stations = 1 }
				end
			end
			for hash, req in pairs(st.requested) do
				if req.active then
					local start = st.wait[hash]
					local agg = inv.requested[hash]
					if agg then
						agg.count = agg.count + req.count
						agg.stations = agg.stations + 1
						if start and (not agg.earliest_wait_start or start < agg.earliest_wait_start) then
							agg.earliest_wait_start = start
						end
					else
						inv.requested[hash] = { count = req.count, stations = 1, earliest_wait_start = start }
					end
				end
			end
			for hash, count in pairs(st.deliveries) do
				if count > 0 then
					local agg = inv.in_transit[hash]
					if agg then
						agg.count = agg.count + count
						agg.stations = agg.stations + 1
					else
						inv.in_transit[hash] = { count = count, stations = 1 }
					end
				end
			end
		end
	end
	return inv
end

return collector
