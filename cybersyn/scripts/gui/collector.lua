-- Incremental snapshot of everything the manager renders, so render code never walks entities or reads
-- circuit signals itself. It only runs while a manager window is open and unpaused (or paused before its first data).
-- Aggregates (inventory_all, starved, station counts) are double-buffered and swap when a pass completes.
-- Station and train records are refilled in place as the pass reaches them, reusing their subtables: a second full
-- copy would roughly double the memory peak (measured ~7.5 MB per copy on a 2,030-station save), and allocating
-- fresh records every pass made the Lua GC run in multi-millisecond steps on large bases.

local rich_name = require("scripts.gui.rich-name")
local diag = require("scripts.diag")
local stats = require("scripts.stats")
local lint = require("scripts.lint")

local collector = {}

-- A full pass over the stations is spread over this many manager updates.
local PASS_UPDATES = 20
local MIN_BATCH = 25
local MAX_BATCH = 200
-- Opening the window on a snapshot older than this starts a fresh pass at BOOST times the batch size. PLAN3 §4.1 asked
-- for 4x; on pY 123 (2,030 stations) a 4x step of the first pass took 6-7 ms and allocated ~2.7 MB, and the GC work
-- that allocation drives landed in the same updates (31-41 ms when a cycle finished). 2x keeps a step near 3.5 ms
-- (§2.11: 5 ms per update) at the price of a first pass of about 11 updates there.
local STALE_ON_OPEN_TICKS = 600
local BOOST = 2
local IDLE_TICKS = 30 * 60 * 60
-- Unset train stop limits read back as uint max; the planner treats anything this large as unlimited.
local UNLIMITED = 2100000000

local WAIT_SIGNAL = defines.train_state.wait_signal
-- The Trains chip "Not refuelled > N h" applies each player's N when it renders; the per-network count in the fleet
-- summary is taken against this fixed hour.
local REFUEL_COUNT_TICKS = 216000
local bor = bit32.bor
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
--- @field name_parts RichNameParts parsed from name, looked up again only when the name changes; shared, read-only
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
--- @field read_tick uint game tick this record was last refreshed
--- @field lint int bitmask of setup findings (PLAN3 §4.12), written by the lint job from phase 2b; 0 until then
--- @field unserved {count: int, worst_reason: int, oldest_first_tick: uint}? copy of the station's diagnostics
--- @field throttling boolean an unacknowledged unserved request names this station at its train limit (R_AT_LIMIT as
---   the requester, P_AT_LIMIT as the best provider), as of the start of the pass that read it
---   entries as of read_tick; nil when it has none or diagnostics are off

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
--- @field state defines.train_state? LuaTrain.state
--- @field state_since uint? tick the train entered `state` (Train.state_tick; the load tick for older trains)
--- @field in_interrupt boolean current schedule record was inserted by an interrupt
--- @field signal_unit_number uint? the signal it waits at, while state is wait_signal
--- @field has_path boolean?
--- @field in_group boolean the train belongs to a vanilla train group (LuaTrain.group ~= "")
--- @field group string? that group's name
--- @field refuel_tick uint? last arrival at a refueler (Train.refuel_tick)
--- @field refuel_from uint? since when refuelling is tracked for this train (lint.refuel_from): a train without a
---   refuel_tick is "not refuelled" only once it is older than the threshold from here

--- @class SnapshotDepotGroup depots sharing one name (PLAN3 §4.2, the Trains tab's group rows)
--- @field ids uint[] depot stop unit numbers
--- @field limit int sum of the stops' train limits (collector.UNLIMITED when any has none)
--- @field count int sum of the stops' vanilla trains_count
--- @field parked int depots with a train parked
--- @field inbound int trains on their way to one of these depots
--- @field trains_bound int Cybersyn trains whose depot is one of these
--- @field compositions {[uint]: int} layout id -> trains bound
--- @field same_depot_bypass int bound trains that require their own depot with depot bypass on

--- @class Snapshot
--- @field tick uint? game tick the last pass completed; nil = never collected
--- @field started_tick uint
--- @field pass int? counts completed passes; two passes can complete on one tick (dev collect)
--- @field boosted true? completed by the opening boost in collector.tick: views may defer a full rebuild to the next update
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
--- @field fleet SnapshotFleet
--- @field depots {total: int, parked: int}
--- @field depots_by_name {[string]: SnapshotDepotGroup} built in the chunked pass (depot stops) and the fleet summary (trains)
--- @field request_keys {[string]: true} "network:hash" keys of the active requests, as of the pass (Inventory's
---   Dim unrequested reads them against provider_masks)
--- @field provider_masks {[string]: int} "network:hash" -> OR of the network masks of the stations providing it, as of
---   the last complete pass (the lint engine's requester-vs-provider mask check)
--- @field provider_overrides {[string]: number} "network:hash" -> the lowest item threshold (in items or fluid units) a
---   provider of it sets; the dispatcher uses it instead of the requester's when it is lower (the lint's capacity check)
--- @field alerts {train_id: uint, kind: int, since_tick: int}[]
--- @field station_ids uint[]? the station ids this snapshot's pass walked, sorted (a complete pass only)
--- @field depot_ids uint[]? the depot ids, sorted

--- @class SnapshotFleet
--- @field total int
--- @field by_status {[uint]: int}
--- @field available_by_network {[string]: int}
--- @field by_layout {[uint]: int}
--- @field min_available_by_network {[string]: int} fewest available trains per network over the last hour (stats)
--- @field capability {[string]: {[uint]: {count: int, item_capacity: int, fluid_capacity: int, mask_or: int}}} per network
---   and layout: Cybersyn trains, the largest capacities among them and the OR of their masks on that network
--- @field mask_or {[string]: int} OR of every Cybersyn train's mask on the network
--- @field in_interrupt_count {[string]: int} trains inside an interrupt, per network
--- @field not_refuelled_count {[string]: int} per network that has a refueler: trains not seen at one for an hour
---   (refuel_tick, or for a train never seen refuelling its refuel_from, older than REFUEL_COUNT_TICKS)
--- @field group_depots {[string]: int} vanilla train group -> distinct depot names among its Cybersyn trains

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
		fleet = { total = 0, by_status = {}, available_by_network = {}, by_layout = {}, min_available_by_network = {},
			capability = {}, mask_or = {}, in_interrupt_count = {}, not_refuelled_count = {}, group_depots = {} },
		depots = { total = 0, parked = 0 },
		depots_by_name = {},
		provider_masks = {},
		provider_overrides = {},
		request_keys = {},
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
	manager.name_parts = nil
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
	-- A half-done lint pass holds an occupancy index of this moment and gap timestamps nobody refreshes while the
	-- window is closed; resumed hours later they would turn stale counts into findings. The masks of the last
	-- complete pass stay, so a reopened window shows them until the next pass ends.
	local s = manager.lint
	if s then
		s.job = nil
		s.occupancy_since = {}
		s.phantom_since = {}
	end
	manager.snapshot = collector.empty()
	manager.snapshot_build = nil
	manager.collect_boost = nil
	manager.collect_spare = nil
	manager.name_parts = nil
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
local net_masks = {}
local nets_n = 0

--- @param network_name string?
--- @param network_mask any
local function set_networks(network_name, network_mask)
	nets_n = 0
	if network_name == NETWORK_EACH then
		if type(network_mask) == "table" then
			for name, mask in pairs(network_mask) do
				nets_n = nets_n + 1
				nets[nets_n] = name
				net_masks[nets_n] = mask
			end
		end
	elseif network_name then
		nets_n = 1
		nets[1] = network_name
		net_masks[1] = type(network_mask) == "number" and network_mask or 0
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

--- Adds one train to the per-network fleet facts on `network`, whose mask for the train is `mask`.
local function add_capability(fleet, network, mask, train, refuel_counted)
	local by_layout = fleet.capability[network]
	if not by_layout then
		by_layout = {}
		fleet.capability[network] = by_layout
	end
	local layout_id = train.layout_id or 0
	local c = by_layout[layout_id]
	if not c then
		c = { count = 0, item_capacity = 0, fluid_capacity = 0, mask_or = 0 }
		by_layout[layout_id] = c
	end
	c.count = c.count + 1
	local items, fluid = train.item_slot_capacity or 0, train.fluid_capacity or 0
	if items > c.item_capacity then c.item_capacity = items end
	if fluid > c.fluid_capacity then c.fluid_capacity = fluid end
	c.mask_or = bor(c.mask_or, mask)
	fleet.mask_or[network] = bor(fleet.mask_or[network] or 0, mask)
	if train.in_interrupt then
		fleet.in_interrupt_count[network] = (fleet.in_interrupt_count[network] or 0) + 1
	end
	local refuelers = storage.to_refuelers
	if refuel_counted and refuelers and refuelers[network] then
		fleet.not_refuelled_count[network] = (fleet.not_refuelled_count[network] or 0) + 1
	end
end

local function summarize_trains(b)
	-- Refilled straight in the live snapshot for the same memory reason as station records.
	local live = collector.get()
	local trains = live.trains
	local fleet = { total = 0, by_status = {}, available_by_network = {}, by_layout = {},
		min_available_by_network = stats.min_available(60), capability = {}, mask_or = {}, in_interrupt_count = {},
		not_refuelled_count = {}, group_depots = {} }
	local group_names = {}
	local now = game.tick
	local by_name = {}
	b.depots_by_name = by_name
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
			local state = entity.state
			tr.state = state
			tr.state_since = train.state_tick
			tr.in_interrupt = train.in_interrupt == true
			if state == WAIT_SIGNAL then
				local signal = entity.signal
				tr.signal_unit_number = signal and signal.valid and signal.unit_number or nil
			else
				tr.signal_unit_number = nil
			end
			tr.has_path = entity.has_path
			local group = entity.group
			tr.in_group = group ~= nil and group ~= ""
			if tr.group ~= group then tr.group = group end
			if tr.in_group then
				local names = group_names[group]
				if not names then
					names = {}
					group_names[group] = names
					fleet.group_depots[group] = 0
				end
				local home = depot_name
				if home ~= "" and not names[home] then
					names[home] = true
					fleet.group_depots[group] = fleet.group_depots[group] + 1
				end
			end
			local refuel_tick = train.refuel_tick
			tr.refuel_tick = refuel_tick
			local refuel_from = lint.refuel_from(train)
			tr.refuel_from = refuel_from
			-- A train never seen refuelling counts once it had as long as the others to get there.
			local stale
			if refuel_tick then
				stale = now - refuel_tick > REFUEL_COUNT_TICKS
			else
				stale = now - refuel_from > REFUEL_COUNT_TICKS
			end
			local network = train.network_name
			if network == NETWORK_EACH then
				if type(train.network_mask) == "table" then
					for name, m in pairs(train.network_mask) do add_capability(fleet, name, m, train, stale) end
				end
			elseif network then
				local m = train.network_mask
				add_capability(fleet, network, type(m) == "number" and m or 0, train, stale)
			end
			if depot_name ~= "" then
				local g = by_name[depot_name]
				if not g then
					g = { ids = {}, limit = 0, count = 0, parked = 0, inbound = 0, trains_bound = 0, compositions = {},
						same_depot_bypass = 0 }
					by_name[depot_name] = g
				end
				g.trains_bound = g.trains_bound + 1
				local layout_id = train.layout_id
				if layout_id then g.compositions[layout_id] = (g.compositions[layout_id] or 0) + 1 end
				local status = train.status
				if status == STATUS_TO_D or status == STATUS_TO_D_BYPASS then g.inbound = g.inbound + 1 end
				if not train.use_any_depot and not train.disable_bypass then
					g.same_depot_bypass = g.same_depot_bypass + 1
				end
			end
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
	live.depots_by_name = live.depots_by_name or {}
	live.provider_masks = live.provider_masks or {}
	live.request_keys = live.request_keys or {}
	live.provider_overrides = live.provider_overrides or {}
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

--- Stations a live, unacknowledged unserved request names at a train limit: the requester for R_AT_LIMIT, the
--- best provider for P_AT_LIMIT. One walk over the diagnostics state per pass (~135 entries on pY 123).
--- @return {[uint]: true}
local function throttled_stations()
	local out = {}
	local d = storage.diag
	if not d then return out end
	local acks = storage.acks
	local ack_requests = acks and acks.request
	local hashes = d.item_hash
	for r_id, by_item in pairs(d.unserved) do
		local by_ack = ack_requests and ack_requests[r_id]
		for ix, e in pairs(by_item) do
			local reason = e.reason
			local target = reason == REASON_R_AT_LIMIT and r_id or reason == REASON_P_AT_LIMIT and e.p_station_id or nil
			if target and not out[target] then
				local hash = by_ack and hashes[ix]
				if not (hash and by_ack[hash] and diag.is_acked("request", r_id, hash)) then out[target] = true end
			end
		end
	end
	return out
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
	b.p_over = spare(manager, "p_over")
	-- Every reader is at most one update behind, so entries from the previous pass are no longer needed.
	local log = manager.collect_log
	if log then
		log.base = log.base + #log.ids
		log.ids = {}
	end
	local depot_ids = {}
	for id in pairs(storage.depots) do
		depot_ids[#depot_ids + 1] = id
	end
	table.sort(depot_ids)
	b.depot_ids = depot_ids
	b.di = 0
	b.trains_pending = true
	b.throttled = throttled_stations()
	manager.snapshot_build = b
	return b
end

--- Adds one depot stop to its name's group (the trains half was filled by summarize_trains).
--- @param by_name {[string]: SnapshotDepotGroup}
--- @param id uint
--- @param depot Depot
local function collect_depot(by_name, id, depot)
	local stop = depot.entity_stop
	if not (stop and stop.valid) then return end
	local name = stop.backer_name
	local g = by_name[name]
	if not g then
		g = { ids = {}, limit = 0, count = 0, parked = 0, inbound = 0, trains_bound = 0, compositions = {},
			same_depot_bypass = 0 }
		by_name[name] = g
	end
	g.ids[#g.ids + 1] = id
	local limit = stop.trains_limit
	if limit >= UNLIMITED or g.limit >= UNLIMITED then
		g.limit = UNLIMITED
	else
		g.limit = g.limit + limit
	end
	g.count = g.count + stop.trains_count
	if depot.available_train_id then g.parked = g.parked + 1 end
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
--- @param mask int? the requesting combinator's network mask (one network; nil on a NETWORK_EACH station)
--- @return boolean active
local function add_request(requested, hash, count, threshold, mask)
	local active = -count >= threshold
	local req = requested[hash]
	if req and req.count ~= 0 then
		req.count = req.count + count
		if threshold < req.threshold then req.threshold = threshold end
		req.active = req.active or active
		if mask then req.mask = bor(req.mask or 0, mask) end
	elseif req then
		req.count, req.threshold, req.active, req.mask = count, threshold, active, mask
	else
		requested[hash] = { count = count, threshold = threshold, active = active, mask = mask }
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
	local r_keys, p_keys, p_over = b and b.r_keys, b and b.p_keys, b and b.p_over
	local overrides = station.item_thresholds
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
						local active = add_request(requested, hash, count,
							item_threshold(station, hash, name, item_type, base_item, base_fluid),
							network_name ~= NETWORK_EACH and nets_n == 1 and net_masks[1] or nil)
						if active and r_keys then
							for i = 1, nets_n do
								r_keys[nets[i] .. ":" .. hash] = true
							end
						end
					end
				elseif count > 0 and station.is_p then
					provided[hash] = (provided[hash] or 0) + count
					if p_keys then
						-- The provider's masks, OR-ed per key: the lint's requester-vs-provider mask check reads them.
						for i = 1, nets_n do
							local key = nets[i] .. ":" .. hash
							p_keys[key] = bor(p_keys[key] or 0, net_masks[i])
						end
						local over = overrides and overrides[hash]
						if over then
							if station.is_stack and item_type == "item" then over = over * (get_stack_size(nil, name) or 1) end
							for i = 1, nets_n do
								local key = nets[i] .. ":" .. hash
								local prev = p_over[key]
								if not prev or over < prev then p_over[key] = over end
							end
						end
					end
				end
			end
		end
	end
end

--- @param b Snapshot
--- Parsed names are shared by every station with that name (read-only; pY 123 has 1,254 distinct names among 2,030
--- stations). The map lives as long as the snapshot, so names renamed away stay in it until the last window closes.
--- @param name string
--- @return RichNameParts
local function parsed_name(name)
	local manager = storage.manager
	local names = manager.name_parts
	if not names then
		names = {}
		manager.name_parts = names
	end
	local parts = names[name]
	if not parts then
		parts = rich_name.parse(name)
		names[name] = parts
	end
	return parts
end

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
		st.name_lower = helpers.multilingual_to_lower(name)
		st.name_parts = parsed_name(name)
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
	st.read_tick = game.tick
	-- The lint job's last result for this stop, which outlives the snapshot (a reopened window shows it at once).
	st.lint = lint.bits_of(id)
	local throttled = b.throttled
	st.throttling = throttled ~= nil and throttled[id] == true
	local n_unserved, worst, oldest = diag.unserved_summary(id)
	if n_unserved > 0 then
		local u = st.unserved
		if not u then
			u = {}
			st.unserved = u
		end
		u.count, u.worst_reason, u.oldest_first_tick = n_unserved, worst, oldest
	elseif st.unserved then
		st.unserved = nil
	end
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
				-- A secondary on one network may carry that network's signal: its own mask, as the planner reads it.
				local sec_mask
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
							net_masks[nets_n] = v.count
						elseif not is_each and signal.name == st.network_name then
							sec_mask = v.count
						end
					end
				end
				if not is_each then set_networks(st.network_name, sec_mask or st.network_mask) end
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
	-- This pass's provider keys become the live provider masks; the previous live set is cleared for the next pass.
	manager.collect_spare = { seen = seen, r_keys = live.request_keys, p_keys = live.provider_masks,
		p_over = live.provider_overrides }
	b.request_keys = b.r_keys
	b.provider_masks = b.p_keys
	b.provider_overrides = b.p_over
	b.stations = stations
	b.trains = live.trains
	b.trains_version = live.trains_version
	b.train_count = live.train_count
	b.fleet = live.fleet
	b.depots = live.depots
	b.alerts = live.alerts
	-- The sorted id lists of this pass stay with the snapshot: the lint job walks them instead of listing storage
	-- again. Never changed after this point, so a job may hold them past the next pass.
	b.station_ids = b.ids
	b.ids = nil
	b.i = nil
	b.di = nil
	b.seen = nil
	b.r_keys = nil
	b.p_keys = nil
	b.p_over = nil
	b.throttled = nil
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
	-- Listing the stations and summarising the fleet each cost about as much as a batch of stations, so a default
	-- step does only one of them and a boosted step both, but no stations on top.
	if not b then
		b = start_pass(manager)
		if not (budget or scale) then return false end
	end
	if b.trains_pending then
		b.trains_pending = nil
		summarize_trains(b)
		if not budget then return false end
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
	-- Depot stops go at the same pace as the stations (two stop reads each).
	local depot_ids = b.depot_ids
	local nd = #depot_ids
	local di = b.di
	local dstop = math.min(nd, di + (budget == math.huge and nd or math.ceil(budget * nd / math.max(n, 1))))
	if i >= n then dstop = nd end
	local depots = storage.depots
	local by_name = b.depots_by_name
	while di < dstop do
		di = di + 1
		local id = depot_ids[di]
		local depot = depots[id]
		if depot then collect_depot(by_name, id, depot) end
	end
	b.di = di
	if b.starved_source ~= "economy" then
		capture_economy_starved(b)
	end
	if i >= n and di >= nd then
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

--- True when any open manager is unpaused, or paused but still waiting for its first data: pausing freezes what a
--- window shows, and a window reopened paused shows nothing until one pass completes.
--- @return boolean
function collector.wanted()
	for _, player_data in pairs(storage.manager.players) do
		if player_data.is_manager_open and (not player_data.paused or not player_data.rendered_snapshot_tick) then
			return true
		end
	end
	return false
end

--- One manager update's worth of collection; no-op unless collector.wanted().
--- @return boolean ran
function collector.tick()
	local manager = storage.manager
	if not manager then return false end
	-- The world scan of /cybersyn-find-problems runs whether or not a window is open.
	if manager.lint and manager.lint.world_job then lint.world_tick() end
	if not collector.wanted() then return false end
	if manager.collect_boost then
		if collector.step(nil, BOOST) then
			manager.collect_boost = nil
			manager.snapshot.boosted = true
		end
	else
		collector.step()
		-- Not during the opening boost: those updates already carry a double collector step.
		lint.tick()
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
