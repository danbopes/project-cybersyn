-- Incremental snapshot of everything the manager renders, so render code never walks entities or reads
-- circuit signals itself. It only runs while a manager window is open and unpaused.
-- Aggregates (inventory_all, starved, station counts) are double-buffered and swap when a pass completes.
-- Station and train records are refilled in place as the pass reaches them, reusing their subtables: a second full
-- copy would roughly double the memory peak (measured ~7.5 MB per copy on a 2,030-station save), and allocating
-- fresh records every pass made the Lua GC run in multi-millisecond steps on large bases.

local rich_name = require("scripts.gui.rich-name")

local collector = {}

-- A full pass over the stations is spread over this many manager updates.
local PASS_UPDATES = 20
local MIN_BATCH = 25
local MAX_BATCH = 200
-- Opening the window on a snapshot older than this starts a fresh pass at BOOST times the batch size.
local STALE_ON_OPEN_TICKS = 600
local BOOST = 4
local IDLE_TICKS = 30 * 60 * 60
-- Unset train stop limits read back as uint max; the planner treats anything this large as unlimited.
local UNLIMITED = 2100000000

local WORKING = defines.entity_status.working
local LOW_POWER = defines.entity_status.low_power
local RED = defines.wire_connector_id.circuit_red
local GREEN = defines.wire_connector_id.circuit_green

--- Station statuses in severity order: the Stations status sort and chips follow it.
collector.STATUSES = { "no_power", "disabled", "warming_up", "starved", "saturated", "idle", "ok" }
collector.UNLIMITED = UNLIMITED

--- @class SnapshotRequest
--- @field count int negative signal sum
--- @field threshold int effective request threshold in items/fluid units
--- @field active boolean |count| >= threshold

--- @class SnapshotStation
--- @field id uint
--- @field name string full rich-text backer name
--- @field name_lower string
--- @field name_parts RichNameParts parsed from name, recomputed only when the name changes
--- @field status string one of collector.STATUSES, see collector.station_status
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
--- @field pass int? counts completed passes; two passes can complete on one tick (dev collect)
--- @field station_count int
--- @field train_count int
--- @field trains_version int bumped whenever trains, fleet, depots and alerts are summarised again
--- @field secondary_count int stations with at least one secondary inventory combinator contributing
--- @field stations {[uint]: SnapshotStation} updated in place during a pass; each record is at most one pass old
--- @field trains {[uint]: SnapshotTrain}
--- @field inventory_all {provided: {[string]: {count: int, stations: int}}, requested: {[string]: {count: int, stations: int, earliest_wait_start: uint?}}, in_transit: {[string]: {count: int, stations: int}}}
--- @field starved {[string]: true} "network:hash" request keys with no provider on that network
--- @field starved_items {[string]: true}
--- @field starved_count int number of keys in starved
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
		trains_version = 0,
		inventory_all = new_inventory(),
		starved = {},
		starved_items = {},
		starved_count = 0,
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
	manager.collect_boost = nil
	manager.collect_spare = nil
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
	manager.collect_boost = nil
	manager.collect_spare = nil
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

local function count_keys(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

--- Makes `dst` hold exactly the entries of `src` (nil = none) without replacing it; keys it already had keep their
--- place in its iteration order.
--- @param dst table
--- @param src table?
--- @return table dst
local function refill(dst, src)
	if src then
		for k in pairs(dst) do
			if src[k] == nil then dst[k] = nil end
		end
		for k, v in pairs(src) do
			if dst[k] ~= v then dst[k] = v end
		end
	else
		for k in pairs(dst) do dst[k] = nil end
	end
	return dst
end

--- A network mask is a number or {[network]: mask}; an equal table keeps the old copy.
--- @param old int|{[string]: int}?
--- @param new int|{[string]: int}?
local function mask_of(old, new)
	if type(new) ~= "table" then return new end
	if type(old) == "table" then
		local same = true
		for k, v in pairs(new) do
			if old[k] ~= v then same = false break end
		end
		if same then
			for k in pairs(old) do
				if new[k] == nil then same = false break end
			end
		end
		if same then return old end
	end
	return copy(new)
end

-- In-place refills of count maps: mark every entry, let the read overwrite what is still there, drop the rest.
-- Provided counts are > 0 and request counts < 0, so 0 marks a stale entry; signal maps use false.
local function mark_counts(t)
	for k in pairs(t) do t[k] = 0 end
end
local function sweep_counts(t)
	for k, v in pairs(t) do
		if v == 0 then t[k] = nil end
	end
end
local function mark_requests(t)
	for _, req in pairs(t) do req.count = 0 end
end
local function sweep_requests(t)
	for k, req in pairs(t) do
		if req.count == 0 then t[k] = nil end
	end
end
local function mark_signals(t)
	for k in pairs(t) do t[k] = false end
end
local function sweep_signals(t)
	for k, v in pairs(t) do
		if v == false then t[k] = nil end
	end
end

-- The networks of the combinator being read. Only indices 1..nets_n are ever read, so what earlier calls left behind
-- cannot reach game state.
local nets = {}
local nets_n = 0

--- @param network_name string?
--- @param network_mask any
local function set_networks(network_name, network_mask)
	nets_n = 0
	if network_name == NETWORK_EACH then
		if type(network_mask) == "table" then
			for name in pairs(network_mask) do
				nets_n = nets_n + 1
				nets[nets_n] = name
			end
		end
	elseif network_name then
		nets_n = 1
		nets[1] = network_name
	end
end

local function has_active_request(st)
	for _, req in pairs(st.requested) do
		if req.active then return true end
	end
	return false
end

--- Game ticks since the station's last delivery; last_delivery_tick counts planner ticks, not game ticks.
--- @param st SnapshotStation
--- @return number?
function collector.delivery_age(st)
	local last = st.last_delivery_tick
	local tps = mod_settings.tps
	if not last or not tps or tps <= 0 then return nil end
	return math.max(0, (storage.total_ticks or 0) - last) * 60 / tps
end

--- @param st SnapshotStation
--- @param hash string
--- @param starved {[string]: true}
local function request_starved(st, hash, starved)
	local name = st.network_name
	if name == NETWORK_EACH then
		local mask = st.network_mask
		if type(mask) == "table" then
			for net in pairs(mask) do
				if starved[net .. ":" .. hash] then return true end
			end
		end
		return false
	end
	return starved[name .. ":" .. hash] == true
end

--- Active requests of `st` with no provider on any of the station's networks, in `requested` order; false when none.
--- @param st SnapshotStation
--- @param starved {[string]: true}
--- @return string[]|false
function collector.starved_hashes(st, starved)
	if not st.network_name or st.warming_up or not next(starved) then return false end
	local hashes = false
	for hash, req in pairs(st.requested) do
		if req.active and request_starved(st, hash, starved) then
			hashes = hashes or {}
			hashes[#hashes + 1] = hash
		end
	end
	return hashes
end

local function is_starved(st, starved)
	if not st.network_name or st.warming_up or not next(starved) then return false end
	for hash, req in pairs(st.requested) do
		if req.active and request_starved(st, hash, starved) then return true end
	end
	return false
end

--- The one station status every view shows (PLAN3 §4.2), first match in collector.STATUSES order. "saturated" means
--- the station's deliveries reached a finite train limit.
--- @param st SnapshotStation
--- @param starved {[string]: true}
--- @return string
function collector.station_status(st, starved)
	if not st.comb_ok then return "no_power" end
	if st.trains_limit == 0 then return "disabled" end
	if st.warming_up then return "warming_up" end
	if is_starved(st, starved) then return "starved" end
	local limit = st.trains_limit
	if limit < UNLIMITED and st.deliveries_total >= limit then return "saturated" end
	if st.deliveries_total == 0 and not has_active_request(st) then
		local age = collector.delivery_age(st)
		if age and age > IDLE_TICKS then return "idle" end
	end
	return "ok"
end

local function same_manifest(old, manifest)
	local n = manifest and #manifest or 0
	if #old ~= n then return false end
	for i = 1, n do
		local a, m = old[i], manifest[i]
		if a.name ~= m.name or a.quality ~= m.quality or a.count ~= m.count then return false end
	end
	return true
end

local function summarize_trains(b)
	-- Refilled straight in the live snapshot for the same memory reason as station records.
	local live = collector.get()
	local trains = live.trains
	local fleet = { total = 0, by_status = {}, available_by_network = {}, by_layout = {} }
	local depot_names = {}
	local depots = storage.depots
	local storage_trains = storage.trains
	for id in pairs(trains) do
		local train = storage_trains[id]
		local entity = train and train.entity
		if not (entity and entity.valid) then trains[id] = nil end
	end
	for id, train in pairs(storage_trains) do
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
			local tr = trains[id]
			if not tr then
				tr = { id = id, manifest = {}, manifest_hashes = {} }
				trains[id] = tr
			end
			if not same_manifest(tr.manifest, train.manifest) then
				local manifest = {}
				local manifest_hashes = {}
				if train.manifest then
					for i, item in ipairs(train.manifest) do
						local hash = hash_item(item.name, item.quality)
						manifest[i] = { name = item.name, quality = item.quality, count = item.count, hash = hash }
						manifest_hashes[hash] = (manifest_hashes[hash] or 0) + item.count
					end
				end
				tr.manifest = manifest
				tr.manifest_hashes = manifest_hashes
			end
			local any = get_any_train_entity(entity)
			tr.status = train.status
			tr.layout_id = train.layout_id
			tr.depot_id = depot_id
			-- Collectable values are written only when they change: rewriting a table during a GC cycle queues it for
			-- the collector's atomic step again.
			depot_name = depot_name or ""
			if tr.depot_name ~= depot_name then tr.depot_name = depot_name end
			if tr.network_name ~= train.network_name then tr.network_name = train.network_name end
			local mask = mask_of(tr.network_mask, train.network_mask)
			if tr.network_mask ~= mask then tr.network_mask = mask end
			tr.p_station_id = train.p_station_id
			tr.r_station_id = train.r_station_id
			tr.refueler_id = train.refueler_id
			tr.surface_index = any and any.surface_index or nil
			tr.is_available = train.is_available == true
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

	live.train_count = fleet.total
	live.trains_version = (live.trains_version or 0) + 1
	live.fleet = fleet
	live.depots = { total = depot_total, parked = parked }
	live.alerts = alerts
	b.trains = nil
end

--- Pass bookkeeping tables (seen ids, request and provide keys) are handed from one pass to the next and cleared
--- instead of being allocated again.
--- @param manager Manager
--- @param name string
local function spare(manager, name)
	local spares = manager.collect_spare
	local t = spares and spares[name]
	if not t then return {} end
	spares[name] = nil
	for k in pairs(t) do t[k] = nil end
	return t
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
	b.pass = (collector.get().pass or 0) + 1
	b.ids = ids
	b.i = 0
	b.seen = spare(manager, "seen")
	b.r_keys = spare(manager, "r_keys")
	b.p_keys = spare(manager, "p_keys")
	-- Every reader is at most one update behind, so entries from the previous pass are no longer needed.
	local log = manager.collect_log
	if log then
		log.base = log.base + #log.ids
		log.ids = {}
	end
	b.trains_pending = true
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

--- Adds one source's request into a record whose old requests are marked with count 0 (see mark_requests).
--- @return boolean active
local function add_request(requested, hash, count, threshold)
	local active = -count >= threshold
	local req = requested[hash]
	if req and req.count ~= 0 then
		req.count = req.count + count
		if threshold < req.threshold then req.threshold = threshold end
		req.active = req.active or active
	elseif req then
		req.count, req.threshold, req.active = count, threshold, active
	else
		requested[hash] = { count = count, threshold = threshold, active = active }
	end
	return active
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

--- Mirrors tick_poll_station: negative = request when is_r, positive = provide when is_p. With `b`, also records
--- which network:item pairs this combinator provides or actively requests, under the networks in `nets`: the
--- planner registers each combinator under its own networks, for the starved derivation.
local function classify(station, signals, st, base_item, base_fluid, control, b)
	local network_name = station.network_name
	local r_keys, p_keys = b and b.r_keys, b and b.p_keys
	local provided, requested = st.provided, st.requested
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
						local active = add_request(requested, hash, count, item_threshold(station, hash, name, item_type, base_item, base_fluid))
						if active and r_keys then
							for i = 1, nets_n do
								r_keys[nets[i] .. ":" .. hash] = true
							end
						end
					end
				elseif count > 0 and station.is_p then
					provided[hash] = (provided[hash] or 0) + count
					if p_keys then
						for i = 1, nets_n do
							p_keys[nets[i] .. ":" .. hash] = true
						end
					end
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

	local live = collector.get()
	local name = stop.backer_name
	local default_item = station.r_threshold or mod_settings.r_threshold or 1
	local default_fluid = station.r_fluid_threshold or (mod_settings.r_fluid_threshold and mod_settings.r_fluid_threshold > 0 and mod_settings.r_fluid_threshold) or nil

	--- @type SnapshotStation
	local st = live.stations[id]
	if not st then
		st = { id = id, provided = {}, requested = {}, deliveries = {}, control = {}, control2 = {}, thresholds = {}, wait = {} }
	end
	if st.name ~= name or not st.name_parts then
		st.name = name
		st.name_lower = string.lower(name)
		st.name_parts = rich_name.parse(name)
	end
	st.surface_index = stop.surface_index
	-- Collectable values are written only when they change: rewriting a table during a GC cycle queues it for the
	-- collector's atomic step again.
	if st.network_name ~= station.network_name then st.network_name = station.network_name end
	local mask = mask_of(st.network_mask, station.network_mask)
	if st.network_mask ~= mask then st.network_mask = mask end
	st.is_p = station.is_p == true
	st.is_r = station.is_r == true
	st.is_stack = station.is_stack == true
	st.comb_ok = false
	st.comb2_ok = nil
	st.warming_up = station.is_warming_up == true
	st.trains_limit = station.trains_limit or 0
	st.deliveries_total = station.deliveries_total or 0
	st.last_delivery_tick = station.last_delivery_tick
	st.priority = station.priority
	st.longest_wait_start = nil
	st.secondary = false
	st.secondary_count = 0
	refill(st.deliveries, station.deliveries)
	refill(st.wait, mod_settings.track_request_wait_times and station.request_start_ticks or nil)
	local provided, requested = st.provided, st.requested
	mark_counts(provided)
	mark_requests(requested)
	mark_signals(st.control)
	mark_signals(st.control2)
	mark_signals(st.thresholds)

	-- The planner skips warming-up stations and stations without a network, so they neither provide nor starve.
	local keyed = not st.warming_up and st.network_name ~= nil and b or nil
	local is_each = st.network_name == NETWORK_EACH

	local signals1, ok1 = read_signals(comb1)
	st.comb_ok = ok1 == true
	if signals1 then
		set_networks(st.network_name, st.network_mask)
		classify(station, signals1, st, default_item, default_fluid, st.control, keyed)
	end

	local comb2 = station.entity_comb2
	if comb2 then
		local signals2, ok2 = read_signals(comb2)
		st.comb2_ok = ok2 == true
		if signals2 then
			local control2, thresholds = st.control2, st.thresholds
			for _, v in pairs(signals2) do
				local signal = v.signal
				local item_type = signal.type or "item"
				if signal.name then
					if item_type == "virtual" then
						control2[signal.name] = v.count
					elseif item_type == "item" or item_type == "fluid" then
						local threshold = math.abs(v.count)
						if station.is_stack and item_type == "item" then
							threshold = threshold * (get_stack_size(nil, signal.name) or 1)
						end
						thresholds[hash_signal(signal)] = threshold
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
				if is_each then nets_n = 0 end
				for _, v in pairs(signals) do
					local signal = v.signal
					if signal.type == "virtual" then
						if signal.name == REQUEST_THRESHOLD then
							sec_item = math.abs(v.count)
						elseif signal.name == REQUEST_FLUID_THRESHOLD then
							sec_fluid = math.abs(v.count)
						elseif is_each and signal.name and not SECONDARY_SETTINGS[signal.name] then
							nets_n = nets_n + 1
							nets[nets_n] = signal.name
						end
					end
				end
				if not is_each then set_networks(st.network_name, st.network_mask) end
				classify(station, signals, st, sec_item, sec_fluid, nil, keyed)
				st.secondary_count = st.secondary_count + 1
				st.secondary = true
			end
		end
	end

	sweep_counts(provided)
	sweep_requests(requested)
	sweep_signals(st.control)
	sweep_signals(st.control2)
	sweep_signals(st.thresholds)

	local inv = b.inventory_all

	for hash, count in pairs(provided) do
		local agg = inv.provided[hash]
		if agg then
			agg.count = agg.count + count
			agg.stations = agg.stations + 1
		else
			inv.provided[hash] = { count = count, stations = 1 }
		end
	end

	local wait = st.wait
	for hash, req in pairs(requested) do
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

	-- Against the live starved set; finish_pass reclassifies the stations a change of that set affects.
	local status = collector.station_status(st, live.starved)
	if st.status ~= status then st.status = status end

	if live.stations[id] ~= st then live.stations[id] = st end
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
	local starved, items, n = {}, {}, 0
	for key in pairs(economy.all_r_stops) do
		if not p_stops[key] then
			starved[key] = true
			items[hash_of_key(key)] = true
			n = n + 1
		end
	end
	b.starved = starved
	b.starved_items = items
	b.starved_count = n
	b.starved_source = "economy"
end

--- Request keys without a provider, unless they equal the live set: then the live tables are kept, so an unchanged
--- set allocates nothing.
local function derive_starved(b, live)
	local r_keys, p_keys, old = b.r_keys, b.p_keys, live.starved
	local n, equal = 0, true
	for key in pairs(r_keys) do
		if not p_keys[key] then
			n = n + 1
			if not old[key] then
				equal = false
				break
			end
		end
	end
	if equal and n == (live.starved_count or count_keys(old)) then
		b.starved, b.starved_items, b.starved_count = old, live.starved_items, n
	else
		local starved, items = {}, {}
		n = 0
		for key in pairs(r_keys) do
			if not p_keys[key] then
				starved[key] = true
				items[hash_of_key(key)] = true
				n = n + 1
			end
		end
		b.starved, b.starved_items, b.starved_count = starved, items, n
	end
	b.starved_source = "snapshot"
end

--- After the starved set changed, the status of stations with an active request for an item that became or stopped
--- being starved is recomputed against the new set; every other status cannot have changed.
local function reclassify_starved(stations, old, new)
	local items, any = {}, false
	for key in pairs(old) do
		if not new[key] then
			items[hash_of_key(key)] = true
			any = true
		end
	end
	for key in pairs(new) do
		if not old[key] then
			items[hash_of_key(key)] = true
			any = true
		end
	end
	if not any then return end
	for id, st in pairs(stations) do
		for hash, req in pairs(st.requested) do
			if req.active and items[hash] then
				local status = collector.station_status(st, new)
				if status ~= st.status then
					st.status = status
					log_change(id)
				end
				break
			end
		end
	end
end

local function finish_pass(manager, b)
	local live = collector.get()
	if b.starved_source ~= "economy" then
		derive_starved(b, live)
	end
	local changed = false
	if b.starved == live.starved or same_keys(b.starved, live.starved) then
		b.starved = live.starved
		b.starved_items = live.starved_items
		b.starved_version = live.starved_version
	else
		b.starved_version = (live.starved_version or 0) + 1
		changed = true
	end
	local stations = live.stations
	local seen = b.seen
	for id in pairs(stations) do
		if not seen[id] then
			stations[id] = nil
			log_change(id)
		end
	end
	if changed then reclassify_starved(stations, live.starved, b.starved) end
	manager.collect_spare = { seen = seen, r_keys = b.r_keys, p_keys = b.p_keys }
	b.stations = stations
	b.trains = live.trains
	b.trains_version = live.trains_version
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

--- @param n integer stations in the pass
--- @return integer
local function batch_size(n)
	return math.min(math.max(math.ceil(n / PASS_UPDATES), MIN_BATCH), MAX_BATCH)
end

--- Advances the current pass by up to `budget` stations (default: the per-update batch size times `scale`).
--- @param budget number?
--- @param scale number? only without budget: a multiple of the batch size, in one call with listing and trains
--- @return boolean completed
function collector.step(budget, scale)
	local manager = storage.manager
	local b = manager.snapshot_build
	local budgeted = budget or scale
	-- Listing the stations and summarising the fleet each cost about as much as a batch of stations, so a default
	-- step does only one of them.
	if not b then
		b = start_pass(manager)
		if not budgeted then return false end
	end
	if b.trains_pending then
		b.trains_pending = nil
		summarize_trains(b)
		if not budgeted then return false end
	end
	local ids = b.ids
	local n = #ids
	budget = budget or batch_size(n) * (scale or 1)
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
	storage.manager.collect_boost = nil
end

--- Opening a window on a missing or stale snapshot does not collect synchronously (40-60 ms on a 2,000-station
--- base): the window shows the last snapshot while the next updates run a pass at BOOST times the batch size.
function collector.ensure_fresh()
	local manager = storage.manager
	local snapshot = collector.get()
	if not snapshot.tick or game.tick - snapshot.tick > STALE_ON_OPEN_TICKS then
		local b = manager.snapshot_build
		if b and game.tick - b.started_tick > STALE_ON_OPEN_TICKS then
			manager.snapshot_build = nil
		end
		manager.collect_boost = true
	end
end

--- Fraction of the boosted pass done while a window waits for fresh data, else nil.
--- @return number?
function collector.collecting()
	local manager = storage.manager
	if not (manager and manager.collect_boost) then return nil end
	local b = manager.snapshot_build
	if not (b and b.ids) or #b.ids == 0 then return 0 end
	return b.i / #b.ids
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
	local manager = storage.manager
	if not manager or not collector.wanted() then return false end
	if manager.collect_boost then
		if collector.step(nil, BOOST) then manager.collect_boost = nil end
	else
		collector.step()
	end
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
