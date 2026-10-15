-- Dispatcher diagnostics (PLAN3 §4.5): why each request is not served, and a log of what happened.
--
-- Failures are keyed state, not events: tick_dispatch re-evaluates every failing (requester, item) key about once per
-- planner cycle (135 live keys and ~190 failing evaluations per second measured on a 2,030-station base), so each
-- evaluation overwrites its entry in place and only a debounced change of reason reaches the log. The log is two
-- column rings sharing one sequence number: the basic ring holds the rare events (reason changes, failures, alerts,
-- station changes) and the full ring the routine ones (dispatch, arrival, departure), so turning `full` on can never
-- push basic history out. All of it lives in storage.diag, which is nil while the setting is off; every hook checks
-- that one value first, and the planner reads it once per call outside its loops.

local stats = require("scripts.stats")

local diag = {}

local BASIC_RING = 4096
local UNSERVED_CAP = 4096
-- Flap rule: a new reason is confirmed after this many consecutive evaluations and this many ticks.
local FLAP_EVALS = 2
local FLAP_TICKS = 1800
-- More than four confirmed changes inside the window is flapping; the key then stays quiet until stable that long.
local FLAP_CHANGES = 5
local FLAP_WINDOW = 36000
-- wait_signal flaps against on_the_path in normal traffic; only a wait this long is worth a log row.
local WAIT_SIGNAL_MIN = 600
-- The dispatcher re-sends its no-train alerts on every failing evaluation and the stuck-train alert on every visit;
-- the log keeps one row per entity and alert until the alert changes or this long has passed.
local ALERT_REPEAT = 36000
local ACK_CAP = 1024
local EXPORT_CHUNK = 2000

diag.BASIC_RING = BASIC_RING
diag.UNSERVED_CAP = UNSERVED_CAP
diag.FLAP_TICKS = FLAP_TICKS
diag.FLAP_WINDOW = FLAP_WINDOW
diag.ACK_CAP = ACK_CAP
diag.EXPORT_CHUNK = EXPORT_CHUNK
diag.WAIT_SIGNAL_MIN = WAIT_SIGNAL_MIN

local COLUMNS = { "seq", "tick", "kind", "sev", "code", "delivery", "train", "station", "station2", "item", "a", "b" }
diag.COLUMNS = COLUMNS

local NO_TRAIN_REASONS = {
	[REASON_NO_TRAINS_ON_NETWORK] = true,
	[REASON_TRAIN_FILTERED] = true,
	[REASON_CAPACITY] = true,
}

local ALERT_SEVERITY = {
	[DIAG_ALERT_STUCK] = DIAG_SEV_ERROR,
	[DIAG_ALERT_DEPOT_BROKEN] = DIAG_SEV_ERROR,
	[DIAG_ALERT_STATION_BROKEN] = DIAG_SEV_ERROR,
	[DIAG_ALERT_REFUELER_BROKEN] = DIAG_SEV_ERROR,
	[DIAG_ALERT_CANNOT_PATH_BETWEEN_SURFACES] = DIAG_SEV_ERROR,
	[DIAG_ALERT_GROUP_SCHEDULE_BROKEN] = DIAG_SEV_ERROR,
	[DIAG_ALERT_SCHEDULE_BROKEN] = DIAG_SEV_ERROR,
}

--- Scratch counters of the evaluation tick_dispatch is running (indices REJ_*). Not game state: the planner zeroes
--- it before each evaluation and diag.fail copies it into the entry, so every Lua state computes the same thing.
--- @type int[]
diag.rej = { 0, 0, 0, 0, 0, 0, 0, 0 }

--- @class DiagRing parallel integer columns (see COLUMNS); row `head` is the newest, `count` rows are live
--- @field size int
--- @field head int
--- @field count int

--- @class DiagEntry one failing (requester, item) key
--- @field reason int confirmed REASON_*
--- @field pending int? a different reason seen since pending_since, not yet confirmed
--- @field pending_since uint?
--- @field pending_n int consecutive evaluations that returned `pending`
--- @field first_tick uint first failing evaluation
--- @field last_tick uint latest failing evaluation
--- @field n int failing evaluations
--- @field a int payload of the confirmed reason's latest evaluation (PLAN3 §4.5 B1)
--- @field b int
--- @field p_station_id uint? best provider of the latest evaluation
--- @field p_count int? its stock (P_BELOW_THRESHOLD and priority losses)
--- @field p_threshold int? the threshold it was held against
--- @field rej int[] REJ_* counts of the latest evaluation of the confirmed reason
--- @field lost_n int evaluations that found the providers locked by an earlier requester of the same call
--- @field lost_to uint? that requester, at the latest loss
--- @field changes uint[] ticks of the last confirmed changes (at most FLAP_CHANGES)
--- @field change_reasons int[] the reason each of those changes confirmed
--- @field suppressed_until uint? flapping: no transition events before this tick

--- @class DiagState
--- @field mode string "basic"|"full"
--- @field full boolean
--- @field seq uint last sequence number handed out (both rings)
--- @field ring_basic DiagRing
--- @field ring_full DiagRing
--- @field unserved {[uint]: {[int]: DiagEntry}} requester unit number -> item index -> entry
--- @field unserved_count {[uint]: int}
--- @field unserved_n int
--- @field counts {[int]: int} live entries per confirmed reason
--- @field item_ix {[string]: int} item hash -> index
--- @field item_hash string[] index -> item hash
--- @field cycle_start int tick of the latest planner cycle start (tick_init)
--- @field cycle_prev int?
--- @field cycle_prev2 int?
--- @field fleet {[string]: int} Cybersyn trains per network, recounted at most once per cycle
--- @field fleet_tick int
--- @field unpowered {[uint]: true} stations whose combinator was not working at their last poll
--- @field alert_last {[int]: uint} (stop unit number, or -train id) * 32 + alert code -> tick it was last logged
--- @field alert_sweep uint? next tick alert_last is pruned
--- @field next_delivery uint
--- @field export_jobs DiagExportJob[]
--- @field loaded_tick uint when this state was created; a first_tick at or before it may predate the request

-- ---------------------------------------------------------------- state

--- @param size int
--- @return DiagRing
local function new_ring(size)
	local r = { size = size, head = 0, count = 0 }
	for _, c in ipairs(COLUMNS) do r[c] = {} end
	return r
end

--- @return int
local function full_ring_size()
	local s = settings.global["cybersyn-diagnostics-ring"]
	return s and s.value --[[@as int]] or 16384
end

--- @return string "off"|"basic"|"full"
local function mode_setting()
	local s = settings.global["cybersyn-diagnostics"]
	return s and s.value --[[@as string]] or "basic"
end

--- @return DiagState
local function new_state()
	return {
		mode = "basic",
		full = false,
		seq = 0,
		ring_basic = new_ring(BASIC_RING),
		ring_full = new_ring(full_ring_size()),
		unserved = {},
		unserved_count = {},
		unserved_n = 0,
		counts = {},
		item_ix = {},
		item_hash = {},
		cycle_start = -1,
		fleet = {},
		fleet_tick = -2,
		unpowered = {},
		alert_last = {},
		next_delivery = 0,
		export_jobs = {},
		loaded_tick = game.tick,
	}
end

--- Keeps the newest min(count, size) rows, oldest first from index 1.
--- @param r DiagRing
--- @param size int
function diag.resize_ring(r, size)
	if r.size == size then return end
	local keep = math.min(r.count, size)
	local old_size, head = r.size, r.head
	for _, c in ipairs(COLUMNS) do
		local col, out = r[c], {}
		for k = 1, keep do
			out[k] = col[(head - keep + k - 1) % old_size + 1]
		end
		r[c] = out
	end
	r.size = size
	r.count = keep
	r.head = keep
end

--- Trains dispatched while the full log was off still carry an older log's delivery id.
local function clear_delivery_ids()
	for _, train in pairs(storage.trains or {}) do
		train.delivery_id = nil
	end
end

--- Brings storage.diag in line with the settings: nil when off, created when missing, the full ring resized.
--- @return DiagState?
function diag.apply()
	local mode = mode_setting()
	if mode == "off" then
		storage.diag = nil
		return nil
	end
	local d = storage.diag
	if not d then
		d = new_state()
		storage.diag = d
		clear_delivery_ids()
	end
	d.mode = mode
	d.full = mode == "full"
	diag.resize_ring(d.ring_full, full_ring_size())
	return d
end

--- A fresh state in the current mode (dev/test only).
--- @return DiagState?
function diag.reset()
	storage.diag = nil
	return diag.apply()
end

--- @param d DiagState
--- @param hash string
--- @return int
local function intern(d, hash)
	local ix = d.item_ix[hash]
	if ix then return ix end
	ix = #d.item_hash + 1
	d.item_hash[ix] = hash
	d.item_ix[hash] = ix
	return ix
end
diag.intern = intern

--- @param ix int?
--- @return string?
function diag.item_hash(ix)
	local d = storage.diag
	return d and ix and d.item_hash[ix] or nil
end

-- ---------------------------------------------------------------- rings

--- @param d DiagState
--- @param r DiagRing
--- @return uint seq
local function push(d, r, kind, sev, code, delivery, train, station, station2, item, a, b)
	local h = r.head % r.size + 1
	r.head = h
	if r.count < r.size then r.count = r.count + 1 end
	local seq = d.seq + 1
	d.seq = seq
	r.seq[h] = seq
	r.tick[h] = game.tick
	r.kind[h] = kind
	r.sev[h] = sev
	r.code[h] = code or 0
	r.delivery[h] = delivery or 0
	r.train[h] = train or 0
	r.station[h] = station or 0
	r.station2[h] = station2 or 0
	r.item[h] = item or 0
	r.a[h] = a or 0
	r.b[h] = b or 0
	return seq
end

--- Writes one event to the ring its kind belongs to; full-only kinds are dropped unless the mode is full.
--- @param d DiagState
--- @param kind int DIAG_KIND_*
--- @param sev int DIAG_SEV_*
--- @return uint? seq
function diag.event(d, kind, sev, code, delivery, train, station, station2, item, a, b)
	if DIAG_KIND_FULL[kind] then
		if not d.full then return nil end
		return push(d, d.ring_full, kind, sev, code, delivery, train, station, station2, item, a, b)
	end
	return push(d, d.ring_basic, kind, sev, code, delivery, train, station, station2, item, a, b)
end

--- Ring index of logical row k (0 = oldest).
local function at(r, k)
	return (r.head - r.count + k) % r.size + 1
end

--- First logical row whose seq is above `seq` (count when none).
local function first_after(r, seq)
	local lo, hi = 0, r.count
	local col = r.seq
	while lo < hi do
		local mid = math.floor((lo + hi) / 2)
		if col[at(r, mid)] > seq then hi = mid else lo = mid + 1 end
	end
	return lo
end

--- @class DiagEventFilter
--- @field kind int? DIAG_KIND_*
--- @field sev int? at most this DIAG_SEV_* (1 = errors only)
--- @field station uint? requester, provider or subject station
--- @field train uint?
--- @field delivery uint?
--- @field item int? item index
--- @field max_seq uint? ignore rows written after this

--- @return boolean
local function matches(r, i, f)
	if not f then return true end
	if f.max_seq and r.seq[i] > f.max_seq then return false end
	if f.kind and r.kind[i] ~= f.kind then return false end
	if f.sev and r.sev[i] > f.sev then return false end
	if f.train and r.train[i] ~= f.train then return false end
	if f.delivery and r.delivery[i] ~= f.delivery then return false end
	if f.item and r.item[i] ~= f.item then return false end
	if f.station and r.station[i] ~= f.station and r.station2[i] ~= f.station then return false end
	return true
end

--- @return table row with every column
local function row(r, i)
	local out = {}
	for _, c in ipairs(COLUMNS) do out[c] = r[c][i] end
	return out
end

--- Events with seq above `from_seq`, oldest first, merged from both rings; with from_seq nil, the newest `limit`
--- (still oldest first).
--- @param filter DiagEventFilter?
--- @param from_seq uint?
--- @param limit int?
--- @return table[]
function diag.events(filter, from_seq, limit)
	local d = storage.diag
	local out = {}
	if not d then return out end
	limit = limit or 1000
	local rb, rf = d.ring_basic, d.ring_full
	if from_seq == nil then
		-- Newest first, then reversed.
		local kb, kf = rb.count - 1, rf.count - 1
		while #out < limit and (kb >= 0 or kf >= 0) do
			local ib = kb >= 0 and at(rb, kb) or nil
			local iff = kf >= 0 and at(rf, kf) or nil
			local r, i
			if ib and (not iff or rb.seq[ib] > rf.seq[iff]) then
				r, i, kb = rb, ib, kb - 1
			else
				r, i, kf = rf, iff, kf - 1
			end
			if matches(r, i, filter) then out[#out + 1] = row(r, i) end
		end
		local n = #out
		for k = 1, math.floor(n / 2) do
			out[k], out[n - k + 1] = out[n - k + 1], out[k]
		end
		return out
	end
	local kb, kf = first_after(rb, from_seq), first_after(rf, from_seq)
	while #out < limit and (kb < rb.count or kf < rf.count) do
		local ib = kb < rb.count and at(rb, kb) or nil
		local iff = kf < rf.count and at(rf, kf) or nil
		local r, i
		if ib and (not iff or rb.seq[ib] < rf.seq[iff]) then
			r, i, kb = rb, ib, kb + 1
		else
			r, i, kf = rf, iff, kf + 1
		end
		if filter and filter.max_seq and r.seq[i] > filter.max_seq then break end
		if matches(r, i, filter) then out[#out + 1] = row(r, i) end
	end
	return out
end

--- The last `n` events about one train, station or delivery, newest first (a backward scan of both rings).
--- @param kind "train"|"station"|"delivery"
--- @param id uint
--- @param n int
--- @return table[]
function diag.last_for(kind, id, n)
	local f = { [kind] = id }
	local d = storage.diag
	if not d then return {} end
	local out = {}
	local rb, rf = d.ring_basic, d.ring_full
	local kb, kf = rb.count - 1, rf.count - 1
	while #out < n and (kb >= 0 or kf >= 0) do
		local ib = kb >= 0 and at(rb, kb) or nil
		local iff = kf >= 0 and at(rf, kf) or nil
		local r, i
		if ib and (not iff or rb.seq[ib] > rf.seq[iff]) then
			r, i, kb = rb, ib, kb - 1
		else
			r, i, kf = rf, iff, kf - 1
		end
		if matches(r, i, f) then out[#out + 1] = row(r, i) end
	end
	return out
end

--- How far back the log reaches: the tick of the oldest row (both rings), and the ticks since then.
--- @return uint? oldest_tick
--- @return uint ticks
function diag.horizon()
	local d = storage.diag
	if not d then return nil, 0 end
	local oldest
	for _, r in ipairs({ d.ring_basic, d.ring_full }) do
		if r.count > 0 then
			local t = r.tick[at(r, 0)]
			if not oldest or t < oldest then oldest = t end
		end
	end
	return oldest, oldest and (game.tick - oldest) or 0
end

-- ---------------------------------------------------------------- acknowledgements (PLAN3 §4.13)

--- storage.acks lives outside storage.diag so an acknowledgement survives diagnostics off. Request acks are keyed by
--- item hash, not by diag's item index, because that index is rebuilt whenever storage.diag is.
--- @class DiagAck
--- @field player_index uint
--- @field tick uint
--- @field until_tick uint? nil = until the reason changes
--- @field reason int? confirmed reason when acknowledged (requests)

--- @return {request: {[uint]: {[string]: DiagAck}}, station: {[uint]: DiagAck}, lint: {[uint]: {[int]: DiagAck}}}
function diag.acks()
	local acks = storage.acks
	if not acks then
		acks = { request = {}, station = {}, lint = {} }
		storage.acks = acks
	end
	acks.request = acks.request or {}
	acks.station = acks.station or {}
	acks.lint = acks.lint or {}
	return acks
end

local ACK_KIND = { request = DIAG_ACK_REQUEST, station = DIAG_ACK_STATION, lint = DIAG_ACK_LINT }

--- Calls fn(kind_code, id, sub, ack, parent_table, key) for every acknowledgement.
local function each_ack(acks, fn)
	for id, by in pairs(acks.request) do
		for hash, ack in pairs(by) do fn(DIAG_ACK_REQUEST, id, hash, ack, by, hash) end
	end
	for id, ack in pairs(acks.station) do fn(DIAG_ACK_STATION, id, nil, ack, acks.station, id) end
	for id, by in pairs(acks.lint) do
		for bit, ack in pairs(by) do fn(DIAG_ACK_LINT, id, bit, ack, by, bit) end
	end
end

--- @return int
local function ack_total(acks)
	local n = 0
	each_ack(acks, function() n = n + 1 end)
	return n
end

local function log_ack(verb, kind, id, sub, player_index, until_tick)
	log({ "", "Cybersyn diagnostics: ", verb, " ", DIAG_ACK_KINDS[kind] or "?", " ", tostring(id), " ",
		tostring(sub or ""), " by player ", tostring(player_index or "-"), " until ", tostring(until_tick or "reason change") })
end

--- @param kind int DIAG_ACK_*
local function ack_event(kind_event, kind, id, sub, player_index, a, b)
	local d = storage.diag
	if not d then return end
	local item = kind == DIAG_ACK_REQUEST and sub and intern(d, sub) or 0
	diag.event(d, kind_event, DIAG_SEV_INFO, kind, 0, 0, id, player_index or 0, item, a or 0,
		b or (kind == DIAG_ACK_LINT and sub or 0))
end

--- Removes one acknowledgement and writes the unacknowledged event.
local function end_ack(kind, id, sub, parent, key, cause, player_index)
	parent[key] = nil
	local acks = storage.acks
	if kind == DIAG_ACK_REQUEST and next(parent) == nil then acks.request[id] = nil end
	if kind == DIAG_ACK_LINT and next(parent) == nil then acks.lint[id] = nil end
	ack_event(DIAG_KIND_UNACKNOWLEDGED, kind, id, sub, player_index, 0, cause)
	log_ack("unacknowledged", kind, id, sub, player_index, nil)
end

--- @param stop LuaEntity?
local function remove_stop_alerts(stop)
	if not (stop and stop.valid) then return end
	for _, player in pairs(stop.force.players) do
		player.remove_alert({ entity = stop })
	end
end

--- Acknowledge a request (id = requester, sub = item hash), a station (sub nil) or a lint finding (sub = check
--- bit). Display state only: any player may do it, and it always expires.
--- @param kind "request"|"station"|"lint"
--- @param id uint
--- @param sub string|int?
--- @param player_index uint?
--- @param until_tick uint? nil = until the confirmed reason changes
--- @param reason int? defaults to the request's confirmed reason
--- @return DiagAck
function diag.ack(kind, id, sub, player_index, until_tick, reason)
	local code = ACK_KIND[kind]
	if not code then error("unknown acknowledgement kind " .. tostring(kind)) end
	local acks = diag.acks()
	if ack_total(acks) >= ACK_CAP and not diag.is_acked(kind, id, sub) then
		local oldest
		each_ack(acks, function(k, i, s, ack, parent, key)
			if not oldest or ack.tick < oldest[4].tick then oldest = { k, i, s, ack, parent, key } end
		end)
		end_ack(oldest[1], oldest[2], oldest[3], oldest[5], oldest[6], DIAG_ACK_END_EXPIRED, nil)
	end
	local d = storage.diag
	if code == DIAG_ACK_REQUEST and reason == nil and d then
		local by = d.unserved[id]
		local ix = d.item_ix[sub]
		local e = by and ix and by[ix]
		reason = e and e.reason or nil
	end
	local ack = { player_index = player_index, tick = game.tick, until_tick = until_tick, reason = reason }
	if code == DIAG_ACK_REQUEST then
		acks.request[id] = acks.request[id] or {}
		acks.request[id][sub] = ack
	elseif code == DIAG_ACK_STATION then
		acks.station[id] = ack
	else
		acks.lint[id] = acks.lint[id] or {}
		acks.lint[id][sub] = ack
	end
	ack_event(DIAG_KIND_ACKNOWLEDGED, code, id, sub, player_index, until_tick or 0, nil)
	log_ack("acknowledged", code, id, sub, player_index, until_tick)
	local station = storage.stations and storage.stations[id]
	if code ~= DIAG_ACK_LINT and station then remove_stop_alerts(station.entity_stop) end
	return ack
end

--- @return boolean removed
function diag.unack(kind, id, sub, player_index)
	local code = ACK_KIND[kind]
	local acks = diag.acks()
	local parent, key
	if code == DIAG_ACK_REQUEST then
		parent, key = acks.request[id], sub
	elseif code == DIAG_ACK_STATION then
		parent, key = acks.station, id
	elseif code == DIAG_ACK_LINT then
		parent, key = acks.lint[id], sub
	end
	if not (parent and parent[key]) then return false end
	end_ack(code, id, sub, parent, key, DIAG_ACK_END_MANUAL, player_index)
	return true
end

--- @return DiagAck? the acknowledgement while it holds
function diag.is_acked(kind, id, sub)
	local acks = storage.acks
	if not acks then return nil end
	local ack
	if kind == "request" then
		local by = acks.request[id]
		ack = by and by[sub]
	elseif kind == "station" then
		ack = acks.station[id]
	elseif kind == "lint" then
		local by = acks.lint[id]
		ack = by and by[sub]
	end
	if ack and ack.until_tick and ack.until_tick <= game.tick then return nil end
	return ack
end

--- Drops acknowledgements whose time is up. Runs at every planner cycle start, with or without storage.diag.
function diag.expire_acks()
	local acks = storage.acks
	if not acks or (next(acks.request) == nil and next(acks.station) == nil and next(acks.lint) == nil) then return end
	local now = game.tick
	each_ack(acks, function(kind, id, sub, ack, parent, key)
		if ack.until_tick and ack.until_tick <= now then
			end_ack(kind, id, sub, parent, key, DIAG_ACK_END_EXPIRED, nil)
		end
	end)
end

--- @param r_id uint
--- @param hash string
--- @param cause int DIAG_ACK_END_*
local function end_request_ack(r_id, hash, cause)
	local acks = storage.acks
	local by = acks and acks.request[r_id]
	if by and by[hash] then end_ack(DIAG_ACK_REQUEST, r_id, hash, by, hash, cause, nil) end
end

-- ---------------------------------------------------------------- unserved state

--- @param now uint
--- @return DiagEntry
local function new_entry(now)
	return {
		reason = 0,
		pending_n = 0,
		first_tick = now,
		last_tick = now,
		n = 0,
		a = 0,
		b = 0,
		rej = { 0, 0, 0, 0, 0, 0, 0, 0 },
		lost_n = 0,
		changes = {},
		change_reasons = {},
	}
end

--- @param e DiagEntry
local function write_payload(e, reason, a, b, p_id, rej)
	e.a = a or 0
	e.b = b or 0
	e.p_station_id = p_id
	if reason == REASON_P_BELOW_THRESHOLD then
		e.p_count, e.p_threshold = a, b
	else
		e.p_count, e.p_threshold = nil, nil
	end
	local er = e.rej
	if rej then
		for i = 1, REJ_COUNT do er[i] = rej[i] end
	else
		for i = 1, REJ_COUNT do er[i] = 0 end
	end
end

local function count_add(d, reason, delta)
	local n = (d.counts[reason] or 0) + delta
	d.counts[reason] = n ~= 0 and n or nil
end

--- @param reason int
--- @return int DIAG_SEV_*
local function reason_sev(reason)
	return 4 - (REASON_SEVERITY[reason] or 1)
end

--- @param d DiagState
--- @param r_id uint
--- @param by_item {[int]: DiagEntry}
--- @param ix int
--- @param e DiagEntry
local function remove_entry(d, r_id, by_item, ix, e)
	by_item[ix] = nil
	count_add(d, e.reason, -1)
	d.unserved_n = d.unserved_n - 1
	local n = (d.unserved_count[r_id] or 1) - 1
	if n <= 0 then
		d.unserved_count[r_id] = nil
		d.unserved[r_id] = nil
	else
		d.unserved_count[r_id] = n
	end
	end_request_ack(r_id, d.item_hash[ix], DIAG_ACK_END_RESOLVED)
end

--- Makes room at the cap by dropping the entry evaluated longest ago.
local function evict_oldest(d)
	local best_r, best_ix, best_e
	for r_id, by_item in pairs(d.unserved) do
		for ix, e in pairs(by_item) do
			if not best_e or e.last_tick < best_e.last_tick then
				best_r, best_ix, best_e = r_id, ix, e
			end
		end
	end
	if best_e then remove_entry(d, best_r, d.unserved[best_r], best_ix, best_e) end
end

--- @param d DiagState
--- @param e DiagEntry
local function confirm(d, e, r_id, ix, reason, now)
	local old = e.reason
	count_add(d, old, -1)
	count_add(d, reason, 1)
	e.reason = reason
	e.pending = nil
	e.pending_since = nil
	e.pending_n = 0
	local changes, reasons = e.changes, e.change_reasons
	changes[#changes + 1] = now
	reasons[#reasons + 1] = reason
	if #changes > FLAP_CHANGES then
		table.remove(changes, 1)
		table.remove(reasons, 1)
	end
	local suppressed = e.suppressed_until ~= nil and now < e.suppressed_until
	if #changes >= FLAP_CHANGES and now - changes[1] <= FLAP_WINDOW then
		if not suppressed then
			local mask = bit32.lshift(1, old - 1)
			for _, r in ipairs(reasons) do mask = bit32.bor(mask, bit32.lshift(1, r - 1)) end
			diag.event(d, DIAG_KIND_FLAPPING, DIAG_SEV_WARNING, reason, 0, 0, r_id, e.p_station_id, ix, mask, #changes)
		end
		e.suppressed_until = now + FLAP_WINDOW
	elseif suppressed then
		e.suppressed_until = now + FLAP_WINDOW
	else
		e.suppressed_until = nil
		diag.event(d, DIAG_KIND_UNSERVED_REASON, reason_sev(reason), reason, 0, 0, r_id, e.p_station_id, ix, e.a, e.b)
	end
	local acks = storage.acks
	local by = acks and acks.request[r_id]
	if by then
		local hash = d.item_hash[ix]
		local ack = by[hash]
		if ack then end_ack(DIAG_ACK_REQUEST, r_id, hash, by, hash, DIAG_ACK_END_REASON_CHANGED, nil) end
	end
	if NO_TRAIN_REASONS[reason] then stats.record_no_train_failure() end
end

--- One failing evaluation of the key (r_id, hash), called by tick_dispatch at the site that rejected it.
--- @param d DiagState
--- @param r_id uint requester station id (its stop's unit number)
--- @param hash string item hash
--- @param reason int REASON_*
--- @param a int? payload (PLAN3 §4.5 B1)
--- @param b int?
--- @param p_id uint? best provider
--- @param rej int[]? REJ_* counters of this evaluation
--- @param lost_to uint? requester whose evaluation in the same call locked the providers this one needed
function diag.fail(d, r_id, hash, reason, a, b, p_id, rej, lost_to)
	local now = game.tick
	local ix = d.item_ix[hash] or intern(d, hash)
	local by_item = d.unserved[r_id]
	local e = by_item and by_item[ix]
	if not e then
		if d.unserved_n >= UNSERVED_CAP then
			evict_oldest(d)
			by_item = d.unserved[r_id]
		end
		if not by_item then
			by_item = {}
			d.unserved[r_id] = by_item
		end
		e = new_entry(now)
		e.reason = reason
		by_item[ix] = e
		d.unserved_n = d.unserved_n + 1
		d.unserved_count[r_id] = (d.unserved_count[r_id] or 0) + 1
		count_add(d, reason, 1)
		write_payload(e, reason, a, b, p_id, rej)
		diag.event(d, DIAG_KIND_UNSERVED_REASON, reason_sev(reason), reason, 0, 0, r_id, p_id, ix, e.a, e.b)
		if NO_TRAIN_REASONS[reason] then stats.record_no_train_failure() end
	else
		e.last_tick = now
		if reason == e.reason then
			if e.pending then
				e.pending = nil
				e.pending_since = nil
				e.pending_n = 0
			end
			write_payload(e, reason, a, b, p_id, rej)
		elseif reason == e.pending then
			e.pending_n = e.pending_n + 1
			if e.pending_n >= FLAP_EVALS and now - e.pending_since >= FLAP_TICKS then
				write_payload(e, reason, a, b, p_id, rej)
				confirm(d, e, r_id, ix, reason, now)
			end
		else
			e.pending = reason
			e.pending_since = now
			e.pending_n = 1
		end
	end
	e.n = e.n + 1
	if lost_to then
		e.lost_n = e.lost_n + 1
		e.lost_to = lost_to
	end
end

--- A requester the item's requester loop skipped, at the return that ends the item for this cycle (no requester
--- was left to evaluate): its skip reason, re-derived from the same fields the loop tested.
--- @param d DiagState
--- @param r_id uint
--- @param station Station
--- @param hash string
function diag.skipped(d, r_id, station, hash)
	local limit = station.trains_limit
	local total = station.deliveries_total
	if total >= limit then
		diag.fail(d, r_id, hash, limit == 0 and REASON_R_DISABLED or REASON_R_AT_LIMIT, total, limit, nil, nil, nil)
		return
	end
	local stop = station.entity_stop
	if not (stop and stop.valid) then return end
	local deliveries = station.deliveries[hash]
	if deliveries and deliveries < 0 then
		diag.fail(d, r_id, hash, REASON_R_IS_PROVIDING, -deliveries, 0, nil, nil, nil)
	end
end

--- Cybersyn trains per network (every train whose depot serves it, available or not), counted at most once per
--- planner cycle and only when a NO_TRAINS_ON_NETWORK evaluation asks.
--- @param d DiagState
--- @param network_name string
--- @return int
function diag.fleet_size(d, network_name)
	local f = d.fleet
	if d.fleet_tick ~= d.cycle_start then
		for k in pairs(f) do f[k] = nil end
		for _, train in pairs(storage.trains) do
			local net = train.network_name
			if net == NETWORK_EACH then
				local mask = train.network_mask
				if type(mask) == "table" then
					for n in pairs(mask) do f[n] = (f[n] or 0) + 1 end
				end
			elseif net then
				f[net] = (f[net] or 0) + 1
			end
		end
		d.fleet_tick = d.cycle_start
	end
	return f[network_name] or 0
end

--- create_delivery served the key: the wait goes to the log and the entry goes away.
--- @param d DiagState
--- @param r_id uint
--- @param hash string
--- @param p_id uint
--- @param train_id uint
--- @param delivery_id uint?
function diag.served(d, r_id, hash, p_id, train_id, delivery_id)
	local by_item = d.unserved[r_id]
	if not by_item then return end
	local ix = d.item_ix[hash]
	local e = ix and by_item[ix]
	if not e then return end
	diag.event(d, DIAG_KIND_SERVED, DIAG_SEV_INFO, e.reason, delivery_id, train_id, r_id, p_id, ix,
		game.tick - e.first_tick, e.n)
	remove_entry(d, r_id, by_item, ix, e)
end

--- A station left Cybersyn: its entries and its acknowledgements go with it.
--- @param station_id uint
function diag.station_removed(station_id)
	local d = storage.diag
	if d then
		local by_item = d.unserved[station_id]
		if by_item then
			for ix, e in pairs(by_item) do remove_entry(d, station_id, by_item, ix, e) end
		end
		d.unserved[station_id] = nil
		d.unserved_count[station_id] = nil
		d.unpowered[station_id] = nil
		for code = 1, #DIAG_ALERT_NAMES do d.alert_last[station_id * 32 + code] = nil end
	end
	local acks = storage.acks
	if acks then
		acks.request[station_id] = nil
		acks.station[station_id] = nil
		acks.lint[station_id] = nil
	end
end

--- Planner cycle start (tick_init): drops entries no evaluation has touched for two cycles, expires
--- acknowledgements.
function diag.cycle()
	diag.expire_acks()
	local d = storage.diag
	if not d then return end
	local now = game.tick
	d.cycle_prev2 = d.cycle_prev
	d.cycle_prev = d.cycle_start >= 0 and d.cycle_start or nil
	d.cycle_start = now
	if now >= (d.alert_sweep or 0) then
		local last = d.alert_last
		for key, tick in pairs(last) do
			if now - tick >= ALERT_REPEAT then last[key] = nil end
		end
		d.alert_sweep = now + ALERT_REPEAT
	end
	local cutoff = d.cycle_prev2
	if not cutoff or d.unserved_n == 0 then return end
	for r_id, by_item in pairs(d.unserved) do
		for ix, e in pairs(by_item) do
			if e.last_tick < cutoff then remove_entry(d, r_id, by_item, ix, e) end
		end
	end
end

-- ---------------------------------------------------------------- GUI reads

--- @param r_id uint
--- @return {[int]: DiagEntry}? item index -> entry; read only
function diag.unserved_for(r_id)
	local d = storage.diag
	return d and d.unserved[r_id] or nil
end

--- @param r_id uint
--- @return int count
--- @return int? worst_reason
--- @return uint? oldest_first_tick
function diag.unserved_summary(r_id)
	local d = storage.diag
	local by_item = d and d.unserved[r_id]
	if not by_item then return 0, nil, nil end
	local n, worst, oldest = 0, nil, nil
	for _, e in pairs(by_item) do
		n = n + 1
		local r = e.reason
		if not worst or REASON_SEVERITY[r] > REASON_SEVERITY[worst] or
			(REASON_SEVERITY[r] == REASON_SEVERITY[worst] and r < worst) then
			worst = r
		end
		if not oldest or e.first_tick < oldest then oldest = e.first_tick end
	end
	return n, worst, oldest
end

--- Live entries per confirmed reason (the number the Overview tile shows). Read only.
--- @return {[int]: int}
function diag.counts_by_reason()
	local d = storage.diag
	return d and d.counts or {}
end

--- @class DiagUnservedRow
--- @field r_station_id uint
--- @field item int item index
--- @field hash string
--- @field entry DiagEntry read only

--- The `limit` longest-waiting entries (oldest first_tick first; ties by requester id, then item index).
--- @param filter {item: string?, reason: int?, limit: int?}?
--- @return DiagUnservedRow[]
function diag.unserved_rows(filter)
	local d = storage.diag
	local out = {}
	if not d then return out end
	local limit = filter and filter.limit or 100
	local want_ix = filter and filter.item and d.item_ix[filter.item] or nil
	if filter and filter.item and not want_ix then return out end
	local want_reason = filter and filter.reason
	local function before(x, y)
		if x.entry.first_tick ~= y.entry.first_tick then return x.entry.first_tick < y.entry.first_tick end
		if x.r_station_id ~= y.r_station_id then return x.r_station_id < y.r_station_id end
		return x.item < y.item
	end
	for r_id, by_item in pairs(d.unserved) do
		for ix, e in pairs(by_item) do
			if (not want_ix or ix == want_ix) and (not want_reason or e.reason == want_reason) then
				local candidate = { r_station_id = r_id, item = ix, hash = d.item_hash[ix], entry = e }
				local n = #out
				if n < limit or before(candidate, out[n]) then
					local pos = n + 1
					while pos > 1 and before(candidate, out[pos - 1]) do
						out[pos] = out[pos - 1]
						pos = pos - 1
					end
					out[pos] = candidate
					if #out > limit then out[#out] = nil end
				end
			end
		end
	end
	return out
end

-- ---------------------------------------------------------------- hooks outside the planner loops

--- @param stop LuaEntity?
--- @return uint
local function unit(stop)
	return stop and stop.valid and stop.unit_number or 0
end

--- Every send_alert_* in factorio-api.lua.
--- @param code int DIAG_ALERT_*
--- @param train LuaTrain?
--- @param stop LuaEntity?
--- @param stop2 LuaEntity?
function diag.alert(code, train, stop, stop2)
	local d = storage.diag
	if not d then return end
	local station = unit(stop)
	local train_id = train and train.valid and train.id or 0
	-- Per alert, not per entity: one requester can fail two items in turn with two different alerts.
	local key = station ~= 0 and (station * 32 + code) or -(train_id * 32 + code)
	local now = game.tick
	local last = d.alert_last[key]
	if last and now - last < ALERT_REPEAT then return end
	d.alert_last[key] = now
	local ctrain = train_id ~= 0 and storage.trains[train_id]
	diag.event(d, DIAG_KIND_ALERT, ALERT_SEVERITY[code] or DIAG_SEV_WARNING, code, ctrain and ctrain.delivery_id or 0,
		train_id, station, unit(stop2), 0, 0, 0)
end

--- The create_delivery exits that give up on a chosen train.
--- @param code int DIAG_DISPATCH_*
function diag.dispatch_failed(code, train_id, r_id, p_id)
	local d = storage.diag
	if not d then return end
	diag.event(d, DIAG_KIND_DISPATCH_FAILED, DIAG_SEV_ERROR, code, 0, train_id, r_id, p_id, 0, 0, 0)
end

--- on_failed_delivery: a delivery ended without being completed.
--- @param cause int DIAG_FAIL_*
--- @param train Train
function diag.delivery_failed(cause, train_id, train, p_id, r_id, is_p, is_r)
	local d = storage.diag
	if not d then return end
	local manifest = train.manifest
	local first = manifest and manifest[1]
	local item = first and intern(d, hash_item(first.name, first.quality)) or 0
	diag.event(d, DIAG_KIND_DELIVERY_FAILED, DIAG_SEV_ERROR, cause or 0, train.delivery_id, train_id, r_id, p_id, item,
		is_p and 1 or 0, is_r and 1 or 0)
end

--- tick_poll_station saw the stop's train limit change.
function diag.station_limit(d, station_id, old, new)
	if new == 0 then
		diag.event(d, DIAG_KIND_STATION_DISABLED, DIAG_SEV_WARNING, 0, 0, 0, station_id, 0, 0, old, new)
	else
		diag.event(d, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, 0, 0, 0, station_id, 0, 0, old, new)
	end
end

--- tick_poll_station saw the station combinator start or stop working (power, or disabled).
function diag.station_power(d, station_id, working)
	d.unpowered[station_id] = (not working) or nil
	diag.event(d, DIAG_KIND_STATION_POWER, working and DIAG_SEV_INFO or DIAG_SEV_WARNING, 0, 0, 0, station_id, 0, 0,
		working and 1 or 0, 0)
end

function diag.station_warmup_done(d, station_id)
	diag.event(d, DIAG_KIND_STATION_WARMUP_DONE, DIAG_SEV_INFO, 0, 0, 0, station_id, 0, 0, 0, 0)
end

--- create_delivery applied the schedule: in full mode the delivery gets an id its later events carry.
--- @param train Train
--- @param manifest Manifest
function diag.dispatched(d, train_id, train, r_id, p_id, manifest)
	if not d.full then
		train.delivery_id = nil
		return
	end
	local id = d.next_delivery + 1
	d.next_delivery = id
	train.delivery_id = id
	local first = manifest[1]
	local total = 0
	for _, item in ipairs(manifest) do total = total + item.count end
	diag.event(d, DIAG_KIND_DISPATCHED, DIAG_SEV_INFO, 0, id, train_id, r_id, p_id,
		first and intern(d, hash_item(first.name, first.quality)) or 0, #manifest, total)
end

--- Arrivals, departures and the return to a depot (full only).
--- @param kind int DIAG_KIND_ARRIVE_P .. DIAG_KIND_RETURNED
--- @param train Train
function diag.train_event(kind, train_id, train, station_id)
	local d = storage.diag
	if not (d and d.full) then return end
	local manifest = train.manifest
	local total = 0
	if manifest then
		for _, item in ipairs(manifest) do total = total + item.count end
	end
	diag.event(d, kind, DIAG_SEV_INFO, 0, train.delivery_id, train_id, station_id or 0,
		kind == DIAG_KIND_RETURNED and 0 or (train.r_station_id or 0), 0, total, 0)
end

local TS = defines.train_state
local STATE_SEV = {
	[TS.no_path] = DIAG_SEV_ERROR,
	[TS.destination_full] = DIAG_SEV_WARNING,
	[TS.manual_control] = DIAG_SEV_INFO,
}

--- on_train_changed_state for a Cybersyn train (full only): entering no_path, destination_full or manual control,
--- and leaving a signal it waited at for at least WAIT_SIGNAL_MIN.
--- @param train Train
--- @param old_state defines.train_state?
--- @param since uint? tick old_state began
--- @param new_state defines.train_state
function diag.train_state(train_id, train, old_state, since, new_state)
	local d = storage.diag
	if not (d and d.full) then return end
	local sev = STATE_SEV[new_state]
	if sev then
		diag.event(d, DIAG_KIND_TRAIN_STATE, sev, new_state, train.delivery_id, train_id, 0, 0, 0, 0, 0)
	end
	if old_state == TS.wait_signal and since then
		local waited = game.tick - since
		if waited >= WAIT_SIGNAL_MIN then
			diag.event(d, DIAG_KIND_TRAIN_STATE, DIAG_SEV_WARNING, TS.wait_signal, train.delivery_id, train_id, 0, 0,
				0, waited, 0)
		end
	end
end

-- ---------------------------------------------------------------- export

--- @class DiagExportJob
--- @field player_index uint 0 = the server
--- @field path string relative to script-output
--- @field next_seq uint rows above this are still to be written
--- @field end_seq uint rows above this were written after the export started
--- @field filter DiagEventFilter?
--- @field rows int written so far
--- @field started boolean the header is out

local HEADER = "seq,tick,kind,severity,code,delivery,train,station,station2,item,a,b\n"

local STATE_NAMES = {}
for name, v in pairs(defines.train_state) do STATE_NAMES[v] = name end

--- Name of the event's code column: a reason, an alert, a dispatch or delivery failure, a train state or a number.
--- @param kind int
--- @param code int
--- @return string
local function code_name(kind, code)
	if kind == DIAG_KIND_UNSERVED_REASON or kind == DIAG_KIND_SERVED or kind == DIAG_KIND_FLAPPING then
		return REASON_NAMES[code] or tostring(code)
	elseif kind == DIAG_KIND_ALERT then
		return DIAG_ALERT_NAMES[code] or tostring(code)
	elseif kind == DIAG_KIND_DISPATCH_FAILED then
		return DIAG_DISPATCH_NAMES[code] or tostring(code)
	elseif kind == DIAG_KIND_DELIVERY_FAILED then
		return DIAG_FAIL_NAMES[code] or tostring(code)
	elseif kind == DIAG_KIND_ACKNOWLEDGED or kind == DIAG_KIND_UNACKNOWLEDGED then
		return DIAG_ACK_KINDS[code] or tostring(code)
	elseif kind == DIAG_KIND_TRAIN_STATE then
		return STATE_NAMES[code] or tostring(code)
	end
	return tostring(code)
end

diag.code_name = code_name

local LINE = "%d,%d,%s,%s,%s,%d,%d,%d,%d,%s,%d,%d\n"

--- @param item_hash string[]
--- @param ix int
--- @return string
local function csv_item(item_hash, ix)
	local item = ix ~= 0 and item_hash[ix] or ""
	if string.find(item, "[,\"]") then item = '"' .. string.gsub(item, '"', '""') .. '"' end
	return item
end

--- One CSV line for an event row (as returned by diag.events).
--- @param ev table
--- @param item_hash string[]
--- @return string
function diag.csv_line(ev, item_hash)
	return string.format(LINE, ev.seq, ev.tick, DIAG_KIND_NAMES[ev.kind] or tostring(ev.kind),
		DIAG_SEV_NAMES[ev.sev] or tostring(ev.sev), code_name(ev.kind, ev.code), ev.delivery, ev.train, ev.station,
		ev.station2, csv_item(item_hash, ev.item), ev.a, ev.b)
end

--- Queues an export of everything both rings hold now (matching `filter`); the manager tick writes it in chunks.
--- @param player_index uint? whose machine gets the file; 0 or nil = the server
--- @param filter DiagEventFilter?
--- @return string? path relative to script-output, nil while diagnostics are off
function diag.export(player_index, filter)
	local d = storage.diag
	if not d then return nil end
	local path = "cybersyn/diag-" .. game.tick .. ".csv"
	for _, job in ipairs(d.export_jobs) do
		if job.path == path and job.player_index == (player_index or 0) then return path end
	end
	d.export_jobs[#d.export_jobs + 1] = {
		player_index = player_index or 0,
		path = path,
		next_seq = 0,
		end_seq = d.seq,
		filter = filter,
		rows = 0,
		started = false,
	}
	return path
end

--- Writes the next chunk of the oldest export job.
--- @return boolean? done nil when there was no job
function diag.export_step()
	local d = storage.diag
	local job = d and d.export_jobs[1]
	if not job then return nil end
	-- Formatted straight from the ring columns: a row table per event made a 2,000-row chunk cost ~20 ms.
	local rb, rf = d.ring_basic, d.ring_full
	local kb, kf = first_after(rb, job.next_seq), first_after(rf, job.next_seq)
	local filter, end_seq, item_hash = job.filter, job.end_seq, d.item_hash
	local parts, n, rows = {}, 0, 0
	if not job.started then
		n = 1
		parts[1] = HEADER
	end
	local exhausted = true
	while rows < EXPORT_CHUNK do
		local ib = kb < rb.count and at(rb, kb) or nil
		local iff = kf < rf.count and at(rf, kf) or nil
		local r, i
		if ib and (not iff or rb.seq[ib] < rf.seq[iff]) then
			r, i, kb = rb, ib, kb + 1
		elseif iff then
			r, i, kf = rf, iff, kf + 1
		else
			break
		end
		local seq = r.seq[i]
		if seq > end_seq then break end
		job.next_seq = seq
		if matches(r, i, filter) then
			local kind, code = r.kind[i], r.code[i]
			n = n + 1
			parts[n] = string.format(LINE, seq, r.tick[i], DIAG_KIND_NAMES[kind] or tostring(kind),
				DIAG_SEV_NAMES[r.sev[i]] or tostring(r.sev[i]), code_name(kind, code), r.delivery[i], r.train[i],
				r.station[i], r.station2[i], csv_item(item_hash, r.item[i]), r.a[i], r.b[i])
			rows = rows + 1
		end
	end
	if rows == EXPORT_CHUNK then exhausted = job.next_seq >= end_seq end
	helpers.write_file(job.path, table.concat(parts), job.started, job.player_index)
	job.started = true
	job.rows = job.rows + rows
	if exhausted then table.remove(d.export_jobs, 1) end
	return exhausted
end

--- Drained from manager_gui.tick: one chunk per manager update, so an export never stalls a tick.
function diag.export_tick()
	local d = storage.diag
	if d and d.export_jobs[1] then diag.export_step() end
end

-- ---------------------------------------------------------------- migration

--- Creates every diagnostics-related field an older save lacks (storage.diag per the setting, storage.acks,
--- the always-on train fields); idempotent.
function diag.migrate()
	diag.acks()
	diag.apply()
end

return diag
