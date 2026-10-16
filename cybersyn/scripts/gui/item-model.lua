-- Per-item drill-down model (PLAN3 §4.10): the providers, requesters and trains of one item hash, from the collector's
-- snapshot only. Pure: every function takes plain tables and returns plain tables, so the host unit tests cover the row
-- split, the requester order and the builder without the engine.
--
-- The Requesters order is the dispatcher's (central-planning.lua tick_dispatch, B2): among the requests it would
-- consider this cycle, the highest priority first, and on equal priority the station whose last delivery is oldest.
-- It reads the same inputs the dispatcher sorts by (st.priority, the control combinator's priority when the item has
-- its own threshold there, st.last_delivery_tick) and never re-checks providers, trains or masks (PLAN3 §12: no second
-- eligibility model), so it is labelled approximate. The dispatcher keeps one queue per network; sorted by the same
-- key, the rows of any one network keep that network's order. Requests it skips this cycle follow, grouped by why.

local model = {}

model.TABLES = { "providers", "requesters", "trains" }

-- Requester groups, in display order: the dispatcher's queue, then what keeps a request out of it this cycle.
model.QUEUED = 0
model.AT_LIMIT = 1
model.DISABLED = 2
model.PROVIDING = 3
model.BELOW_THRESHOLD = 4
model.NOT_POLLED = 5
-- A delivery of the item is on its way in, but the stop no longer requests it (the Stations tab lists it too).
model.NOT_REQUESTING = 6
model.GROUP_KEYS = { [1] = "at-limit", [2] = "disabled", [3] = "providing", [4] = "below-threshold", [5] = "not-polled",
	[6] = "not-requesting" }

--- Rows per table out of `n` whole rows. Each table is allotted a third (floor(n / 3)) and Requesters also the
--- remainder, so Requesters never gets fewer than either other table. A table needs one row per entry and at least one
--- (its empty-state line); rows a table cannot fill go to the tables that have more entries than their allotment,
--- Requesters first, then Providers, then Trains; rows nobody can use stay with their table as blank space. The three
--- always add up to `n`, so the drill-down keeps the window's height.
--- @param n int total rows (the layout's item_tab rows, at least 3)
--- @param counts {providers: int, requesters: int, trains: int}
--- @return {providers: int, requesters: int, trains: int}
function model.split_rows(n, counts)
	local base = math.floor(n / 3)
	local share = { providers = base, requesters = n - 2 * base, trains = base }
	local out, spare = {}, 0
	for _, t in ipairs(model.TABLES) do
		local need = math.max(1, counts[t] or 0)
		out[t] = math.min(share[t], need)
		spare = spare + share[t] - out[t]
	end
	for _, t in ipairs({ "requesters", "providers", "trains" }) do
		local need = math.max(1, counts[t] or 0)
		local add = math.min(spare, need - out[t])
		if add > 0 then
			out[t] = out[t] + add
			spare = spare - add
		end
	end
	for _, t in ipairs(model.TABLES) do
		if spare <= 0 then break end
		local back = math.min(spare, share[t] - out[t])
		if back > 0 then
			out[t] = out[t] + back
			spare = spare - back
		end
	end
	return out
end

--- The priority the dispatcher compares for this item: the station's, or the control combinator's priority signal
--- when the item has its own threshold on that combinator (tick_dispatch reads station.item_priority only then).
--- @param st {priority: int?, thresholds: {[string]: int}?, control2: {[string]: int}?}
--- @param hash string
--- @param priority_signal string the priority signal's name (SIGNAL_PRIORITY)
--- @return int
function model.effective_priority(st, hash, priority_signal)
	local prior = st.priority or 0
	local thresholds, control2 = st.thresholds, st.control2
	if thresholds and thresholds[hash] ~= nil and control2 then
		local item_prior = control2[priority_signal]
		if item_prior ~= nil then prior = item_prior end
	end
	return prior
end

--- Why a request is outside the dispatcher's queue this cycle, in the order tick_poll_station and tick_dispatch test it.
--- @param st {status: string?, warming_up: boolean?, deliveries_total: int?, trains_limit: int?, deliveries: {[string]: int}?}
--- @param req {active: boolean}
--- @param hash string
--- @return int group model.QUEUED .. model.NOT_POLLED
function model.requester_group(st, req, hash)
	if st.warming_up or st.status == "no_power" then return model.NOT_POLLED end
	if not req.active then return model.BELOW_THRESHOLD end
	-- Train limit 0: the stop is switched off, not merely busy.
	if (st.trains_limit or 0) == 0 then return model.DISABLED end
	if (st.deliveries_total or 0) >= (st.trains_limit or 0) then return model.AT_LIMIT end
	local d = st.deliveries and st.deliveries[hash]
	if d and d < 0 then return model.PROVIDING end
	return model.QUEUED
end

--- The dispatcher's order: queued first, priority descending, then the oldest last delivery. The dispatcher breaks a
--- full tie by its poll order, which the snapshot does not keep; the station id stands in for it.
--- @param a {group: int, priority: int, last_served: number, id: uint}
--- @param b {group: int, priority: int, last_served: number, id: uint}
--- @return boolean
function model.dispatch_before(a, b)
	if a.group ~= b.group then return a.group < b.group end
	if a.priority ~= b.priority then return a.priority > b.priority end
	if a.last_served ~= b.last_served then return a.last_served < b.last_served end
	return a.id < b.id
end

local function by_amount(key)
	return function(a, b)
		if a[key] ~= b[key] then return a[key] > b[key] end
		return a.id < b.id
	end
end

--- @class ItemProviderRow
--- @field id uint
--- @field stock int
--- @field threshold int? the item's own threshold on the control combinator; nil = the requester's applies
--- @field out int amount on its way out of this station
--- @field status string

--- @class ItemRequesterRow
--- @field id uint
--- @field requested int positive
--- @field threshold int
--- @field wait_start uint? request start tick (nil while wait tracking is off)
--- @field incoming int
--- @field priority int
--- @field last_served number planner ticks of the last delivery
--- @field group int
--- @field network string?
--- @field position int? place in the dispatcher's queue (queued rows only)

--- @class ItemTrainRow
--- @field id uint
--- @field status int STATUS_*
--- @field amount int
--- @field to uint? the requester the cargo goes to
--- @field from uint? the provider

--- @class ItemModel
--- @field hash string
--- @field tick uint? snapshot tick the model was built from
--- @field totals {provided: int, in_transit: int, requested: int, provided_stations: int, requested_stations: int, in_transit_stations: int}
--- @field providers ItemProviderRow[]
--- @field requesters ItemRequesterRow[]
--- @field trains ItemTrainRow[]
--- @field queued int requesters in the dispatcher's queue

--- Every station and train of the snapshot that provides, requests, carries or has a delivery of `hash` (as the
--- Stations tab filtered to the item lists them), sorted: providers by stock, requesters in the dispatcher's order,
--- trains by amount (each with the id as the final tiebreak). A station with only a delivery joins the table of its
--- side: an outgoing one Providers (stock 0), an incoming one Requesters (not requesting).
--- @param snapshot {tick: uint?, stations: table, trains: table, inventory_all: table, item_stations: {[string]: uint[]}?}
--- @param hash string
--- @param priority_signal string
--- @param changed uint[]? stations whose records changed since the index was built (the collector's change log)
--- @return ItemModel
function model.build(snapshot, hash, priority_signal, changed)
	local providers, requesters, trains = {}, {}, {}
	local stations = snapshot.stations
	-- The collector's per-item index (a complete pass) names the few stations to look at; without it, all of them.
	local ids = snapshot.item_stations and (snapshot.item_stations[hash] or {})
	if ids and changed and #changed > 0 then
		local seen, merged = {}, {}
		for _, id in ipairs(ids) do
			seen[id] = true
			merged[#merged + 1] = id
		end
		for _, id in ipairs(changed) do
			if not seen[id] then
				seen[id] = true
				merged[#merged + 1] = id
			end
		end
		ids = merged
	end
	local list
	if not ids then
		list = {}
		for id in pairs(stations) do list[#list + 1] = id end
	end
	for _, id in ipairs(ids or list) do
		local st = stations[id]
		local stock = st and st.provided and st.provided[hash]
		local d = st and st.deliveries and st.deliveries[hash] or 0
		local req = st and st.requested and st.requested[hash]
		if st and not stock and d < 0 then stock = 0 end
		if stock then
			providers[#providers + 1] = {
				id = id,
				stock = stock,
				threshold = st.thresholds and st.thresholds[hash] or nil,
				out = d < 0 and -d or 0,
				status = st.status,
			}
		end
		if req or (st and d > 0) then
			requesters[#requesters + 1] = {
				id = id,
				requested = req and -req.count or 0,
				threshold = req and req.threshold or 0,
				wait_start = req and st.wait and st.wait[hash] or nil,
				incoming = d > 0 and d or 0,
				priority = model.effective_priority(st, hash, priority_signal),
				last_served = st.last_delivery_tick or 0,
				group = req and model.requester_group(st, req, hash) or model.NOT_REQUESTING,
				network = st.network_name,
			}
		end
	end
	for id, tr in pairs(snapshot.trains) do
		local amount = tr.manifest_hashes and tr.manifest_hashes[hash]
		if amount then
			trains[#trains + 1] = { id = id, status = tr.status, amount = amount, to = tr.r_station_id, from = tr.p_station_id }
		end
	end
	table.sort(providers, by_amount("stock"))
	table.sort(requesters, model.dispatch_before)
	table.sort(trains, by_amount("amount"))
	local queued = 0
	for i, r in ipairs(requesters) do
		if r.group == model.QUEUED then
			queued = i
			r.position = i
		end
	end
	local inv = snapshot.inventory_all or {}
	local p = inv.provided and inv.provided[hash]
	local r = inv.requested and inv.requested[hash]
	local t = inv.in_transit and inv.in_transit[hash]
	return {
		hash = hash,
		tick = snapshot.tick,
		totals = {
			provided = p and p.count or 0,
			provided_stations = p and p.stations or 0,
			requested = r and -r.count or 0,
			requested_stations = r and r.stations or 0,
			in_transit = t and t.count or 0,
			in_transit_stations = t and t.stations or 0,
		},
		providers = providers,
		requesters = requesters,
		trains = trains,
		queued = queued,
	}
end

--- The Trains chip a train status belongs to (tab-logic's TRAIN_CHIPS keys), or nil for a custom status.
--- @param status int?
--- @param S {D: int, TO_P: int, P: int, TO_R: int, R: int, TO_D: int, TO_D_BYPASS: int, TO_F: int, F: int} the STATUS_* values
--- @return string?
function model.train_chip(status, S)
	if status == S.D then return "parked" end
	if status == S.TO_P then return "to_p" end
	if status == S.P then return "loading" end
	if status == S.TO_R then return "to_r" end
	if status == S.R then return "unloading" end
	if status == S.TO_D or status == S.TO_D_BYPASS then return "returning" end
	if status == S.TO_F or status == S.F then return "refuel" end
	return nil
end

return model
