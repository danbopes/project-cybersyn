-- What the Log tab shows (PLAN3 §4.7 Log), read from diag's two rings: the rows (adjacent identical events collapsed
-- into one row with a count), the severity counts, the unread-error badge and the Summary tables. Pure over the ring
-- tables and plain values, so the host tests cover it; scripts/gui/log.lua turns the result into elements.
--
-- Nothing here scans a ring whole per update: a full ring on a 2,030-station base is 20,480 rows, about 4 ms to walk.
-- The rows come from a backward scan from the head that stops once the window's rows are filled, then follow the head
-- forward; the counts are kept per 256-seq bucket so rows leaving the window (or the ring) at the old end are
-- subtracted by recounting one bucket; every scan that may run long examines at most `budget` rows per update and
-- continues from the seq it reached on the next one.

local format = require("__flib__.format")
local diag = require("scripts.diag")

local model = {}

model.BUDGET = 4096
model.BUCKET = 256
model.SUMMARY_TOP = 10
-- Window drop-down: 10 min, 1 h, everything the rings hold.
model.WINDOWS = { 36000, 216000, false }
model.DEFAULT_WINDOW = 3

local at, first_after = diag.ring_at, diag.first_after
local STATION2_IS_STATION = diag.STATION2_IS_STATION
local KIND_ALERT = DIAG_KIND_ALERT

--- Kind groups of the drop-down. An alert belongs to the group of what it is about, by its code.
model.GROUPS = {
	{
		name = "unserved",
		kinds = { DIAG_KIND_UNSERVED_REASON, DIAG_KIND_SERVED, DIAG_KIND_FLAPPING },
		alerts = { DIAG_ALERT_MISSING_TRAIN, DIAG_ALERT_NO_TRAIN_HAS_CAPACITY, DIAG_ALERT_NO_TRAIN_MATCHES_R_LAYOUT,
			DIAG_ALERT_NO_TRAIN_MATCHES_P_LAYOUT, DIAG_ALERT_TRAINS_FILTERED },
	},
	{
		name = "deliveries",
		kinds = { DIAG_KIND_DISPATCH_FAILED, DIAG_KIND_DELIVERY_FAILED, DIAG_KIND_DISPATCHED, DIAG_KIND_ARRIVE_P,
			DIAG_KIND_LEAVE_P, DIAG_KIND_ARRIVE_R, DIAG_KIND_LEAVE_R, DIAG_KIND_RETURNED },
	},
	{
		name = "stations",
		kinds = { DIAG_KIND_STATION_POWER, DIAG_KIND_STATION_LIMIT, DIAG_KIND_STATION_WARMUP_DONE,
			DIAG_KIND_STATION_DISABLED },
		alerts = { DIAG_ALERT_DEPOT_BROKEN, DIAG_ALERT_STATION_BROKEN, DIAG_ALERT_REFUELER_BROKEN,
			DIAG_ALERT_NON_DEFAULT_PRIORITY },
	},
	{
		name = "trains",
		kinds = { DIAG_KIND_TRAIN_STATE, DIAG_KIND_SCHEDULE_EDITED, DIAG_KIND_ALERT },
		alerts = { DIAG_ALERT_STUCK, DIAG_ALERT_NONEMPTY_IN_DEPOT, DIAG_ALERT_AT_INCORRECT_STATION,
			DIAG_ALERT_CANNOT_PATH_BETWEEN_SURFACES, DIAG_ALERT_GROUP_SCHEDULE_BROKEN, DIAG_ALERT_SCHEDULE_BROKEN,
			DIAG_ALERT_UNEXPECTED_TRAIN },
	},
	{
		name = "cargo",
		kinds = { DIAG_KIND_SHORT_LOAD, DIAG_KIND_UNEXPECTED_CARGO, DIAG_KIND_RESIDUAL_CARGO },
		alerts = { DIAG_ALERT_UNEXPECTED_CARGO },
	},
	{ name = "setup", kinds = { DIAG_KIND_LINT } },
	{ name = "actions", kinds = { DIAG_KIND_ACKNOWLEDGED, DIAG_KIND_UNACKNOWLEDGED, DIAG_KIND_MANUAL_ACTION } },
}

--- The kind drop-down, in order: everything, then each group followed by its kinds. The trains group lists the
--- alert kind itself (every alert, whatever it is about); the group filters take alerts by code.
--- @type {group: int?, kind: int?}[]
model.KIND_ITEMS = { {} }
for g, group in ipairs(model.GROUPS) do
	model.KIND_ITEMS[#model.KIND_ITEMS + 1] = { group = g }
	for _, kind in ipairs(group.kinds) do
		model.KIND_ITEMS[#model.KIND_ITEMS + 1] = { kind = kind }
	end
end

--- @class LogFilter per player (player_data.log_filter); plain values only
--- @field sev boolean[] error, warning, info shown
--- @field group int? index into model.GROUPS
--- @field kind int? DIAG_KIND_*
--- @field train uint? from the train-id field
--- @field subject {kind: string, id: uint}? the "this train/stop" chip
--- @field window int index into model.WINDOWS
--- @field follow boolean
--- @field summary boolean

--- @return LogFilter
function model.default_filter()
	return { sev = { true, true, true }, window = model.DEFAULT_WINDOW, follow = true, summary = false }
end

--- @class LogCompiled the filter as the scans read it
--- @field sevs boolean[]
--- @field kinds {[int]: true}?
--- @field alerts {[int]: true}?
--- @field train uint?
--- @field station uint? subject station (station column, or station2 where it names a station)
--- @field subject_train uint?
--- @field item int? item index (the manager's item filter); -1 = an item diagnostics never logged
--- @field min_tick uint?
--- @field any boolean some filter besides the severities and the window is set (else `match` is always true)
--- @field sig string everything but the severities
--- @field sev_sig string

--- @param f LogFilter
--- @param now uint
--- @param item int? the manager's item filter as diag's item index (-1 when diagnostics never logged that item)
--- @return LogCompiled
function model.compile(f, now, item)
	local kinds, alerts
	if f.group and model.GROUPS[f.group] then
		local group = model.GROUPS[f.group]
		kinds = {}
		for _, k in ipairs(group.kinds) do kinds[k] = true end
		if group.alerts then
			alerts = {}
			for _, c in ipairs(group.alerts) do alerts[c] = true end
		end
	elseif f.kind then
		kinds = { [f.kind] = true }
	end
	local station, subject_train
	local s = f.subject
	if s then
		if s.kind == "train" then subject_train = s.id else station = s.id end
	end
	local window = model.WINDOWS[f.window or model.DEFAULT_WINDOW]
	local sevs = { f.sev[1] == true, f.sev[2] == true, f.sev[3] == true }
	return {
		sevs = sevs,
		kinds = kinds,
		alerts = alerts,
		train = f.train,
		item = item,
		station = station,
		subject_train = subject_train,
		min_tick = window and math.max(0, now - window) or nil,
		any = kinds ~= nil or f.train ~= nil or item ~= nil or s ~= nil,
		sig = table.concat({ tostring(f.group), tostring(f.kind), tostring(f.train), s and s.kind or "", s and s.id or "",
			tostring(f.window), tostring(item) }, "|"),
		sev_sig = (sevs[1] and "e" or "") .. (sevs[2] and "w" or "") .. (sevs[3] and "i" or ""),
	}
end

--- Every filter but the severities (those are what the counts split by).
--- @param r DiagRing
--- @param i int ring index
--- @param cf LogCompiled
--- @return boolean
local function match(r, i, cf)
	local kind = r.kind[i]
	local kinds = cf.kinds
	if kinds and not kinds[kind] then
		local alerts = cf.alerts
		if not (alerts and kind == KIND_ALERT and alerts[r.code[i]]) then return false end
	end
	local train = cf.train
	if train and r.train[i] ~= train then return false end
	train = cf.subject_train
	if train and r.train[i] ~= train then return false end
	local item = cf.item
	if item and r.item[i] ~= item then return false end
	local st = cf.station
	if st and r.station[i] ~= st and not (STATION2_IS_STATION[kind] and r.station2[i] == st) then return false end
	return true
end
model.match = match

--- The same filter as diag.export takes it (DiagEventFilter).
--- @param cf LogCompiled
--- @return DiagEventFilter
function model.export_filter(cf)
	local sevs
	if not (cf.sevs[1] and cf.sevs[2] and cf.sevs[3]) then
		sevs = {}
		for s = 1, 3 do
			if cf.sevs[s] then sevs[s] = true end
		end
	end
	local train = cf.train
	if cf.subject_train then
		-- Two different trains match nothing; -1 is no train id.
		train = (train and train ~= cf.subject_train) and -1 or cf.subject_train
	end
	return {
		kinds = cf.kinds,
		alerts = cf.alerts,
		sevs = sevs,
		train = train,
		item = cf.item,
		station = cf.station,
		min_tick = cf.min_tick,
	}
end

-- ---------------------------------------------------------------- scans

--- Visits rows with seq < `below` of both rings merged by seq, newest first, that pass `match` (not the severities),
--- until the rings or the window end, `visit(r, i)` returns true, or `budget` rows have been examined.
--- @param rb DiagRing
--- @param rf DiagRing? the full ring, nil while full is off
--- @param below uint
--- @param cf LogCompiled
--- @param budget int
--- @param visit fun(r: DiagRing, i: int): boolean?
--- @return boolean ended the rings or the window ended
--- @return uint? below where a later call continues (the row that stopped the scan is examined again)
local function scan_back(rb, rf, below, cf, budget, visit)
	local kb = first_after(rb, below - 1) - 1
	local kf = rf and (first_after(rf, below - 1) - 1) or -1
	local min_tick = cf.min_tick
	local any = cf.any ~= false
	local n = 0
	while true do
		local ib = kb >= 0 and at(rb, kb) or nil
		local iff = kf >= 0 and at(rf, kf) or nil
		local r, i
		if ib and (not iff or rb.seq[ib] > rf.seq[iff]) then
			r, i, kb = rb, ib, kb - 1
		elseif iff then
			r, i, kf = rf, iff, kf - 1
		else
			return true, nil
		end
		-- Seq order is tick order in both rings, so the first row before the window ends the whole scan.
		if min_tick and r.tick[i] < min_tick then return true, nil end
		local seq = r.seq[i]
		if n >= budget then return false, seq + 1 end
		n = n + 1
		if (not any or match(r, i, cf)) and visit(r, i) then return false, seq + 1 end
	end
end
model.scan_back = scan_back

--- Visits rows with seq > `after`, both rings merged by seq, oldest first (no filter), at most `budget` of them.
--- @param rb DiagRing
--- @param rf DiagRing?
--- @param after uint
--- @param budget int
--- @param visit fun(r: DiagRing, i: int)
--- @return uint reached every row up to this seq was visited
--- @return boolean ended no row above `reached` was left
local function scan_fwd(rb, rf, after, budget, visit)
	local kb = first_after(rb, after)
	local nb = rb.count
	local kf, nf = 0, 0
	if rf then
		kf, nf = first_after(rf, after), rf.count
	end
	local n, reached = 0, after
	while kb < nb or kf < nf do
		if n >= budget then return reached, false end
		local ib = kb < nb and at(rb, kb) or nil
		local iff = kf < nf and at(rf, kf) or nil
		local r, i
		if ib and (not iff or rb.seq[ib] < rf.seq[iff]) then
			r, i, kb = rb, ib, kb + 1
		else
			r, i, kf = rf, iff, kf + 1
		end
		n = n + 1
		reached = r.seq[i]
		visit(r, i)
	end
	return reached, true
end
model.scan_fwd = scan_fwd

--- First logical row of `r` written at or after `tick` (r.count when none).
--- @param r DiagRing
--- @param tick uint
--- @return int
local function first_at_tick(r, tick)
	local lo, hi = 0, r.count
	local col = r.tick
	while lo < hi do
		local mid = math.floor((lo + hi) / 2)
		if col[at(r, mid)] >= tick then hi = mid else lo = mid + 1 end
	end
	return lo
end
model.first_at_tick = first_at_tick

--- The rings the Log reads: the full ring only while full is on (diag.horizon ignores it otherwise too).
--- @param d DiagState
--- @return DiagRing rb
--- @return DiagRing? rf
local function rings(d)
	return d.ring_basic, d.full and d.ring_full or nil
end
model.rings = rings

--- Changes whenever diagnostics were recreated or full was switched: seqs of an old state mean nothing then.
--- @param d DiagState
--- @return string
local function epoch(d)
	return tostring(d.loaded_tick) .. (d.full and "f" or "b")
end
model.epoch = epoch

-- ---------------------------------------------------------------- rows

--- @class LogGroup one shown row: one event, or adjacent identical events (same kind, code, train, stations, item)
--- @field seq uint newest event of the row
--- @field first uint oldest event of the row (the row's key: stable while newer identical events join at the top)
--- @field tick uint newest event's tick
--- @field first_tick uint
--- @field n int events in the row
--- @field kind int
--- @field sev int
--- @field code int
--- @field delivery uint
--- @field train uint
--- @field station uint
--- @field station2 uint
--- @field item int
--- @field a int
--- @field b int

--- @param r DiagRing
--- @param i int
--- @return LogGroup
local function new_group(r, i)
	local seq, tick = r.seq[i], r.tick[i]
	return {
		seq = seq, first = seq, tick = tick, first_tick = tick, n = 1,
		kind = r.kind[i], sev = r.sev[i], code = r.code[i], delivery = r.delivery[i], train = r.train[i],
		station = r.station[i], station2 = r.station2[i], item = r.item[i], a = r.a[i], b = r.b[i],
	}
end
model.new_group = new_group

--- @param g LogGroup
--- @return boolean
local function identical(g, r, i)
	return g.kind == r.kind[i] and g.code == r.code[i] and g.train == r.train[i] and g.station == r.station[i]
		and g.station2 == r.station2[i] and g.item == r.item[i]
end
model.identical = identical

--- Collapses adjacent identical events, newest first (plain event rows as diag.events returns them, newest first).
--- @param events table[]
--- @param limit int? rows at most
--- @return LogGroup[]
function model.collapse(events, limit)
	local cols = { seq = {}, tick = {}, kind = {}, sev = {}, code = {}, delivery = {}, train = {}, station = {},
		station2 = {}, item = {}, a = {}, b = {} }
	for i, ev in ipairs(events) do
		for c, col in pairs(cols) do col[i] = ev[c] or 0 end
	end
	local out = {}
	for i = 1, #events do
		local last = out[#out]
		if last and identical(last, cols, i) then
			last.n = last.n + 1
			last.first, last.first_tick = cols.seq[i], cols.tick[i]
		else
			if limit and #out >= limit then break end
			out[#out + 1] = new_group(cols, i)
		end
	end
	return out
end

--- @class LogRowsState per player (player_data.log_rows)
--- @field sig string?
--- @field groups LogGroup[] newest first
--- @field top uint every row up to this seq has been considered at the top
--- @field below uint? the backward scan continues below this seq; nil once complete
--- @field anchor uint? Follow off: rows written after this seq are not shown
--- @field limit int

--- Brings the rows up to date. Follow on: new events join at the top (an identical newest row counts them), rows
--- older than the window drop off the bottom. Follow off: the rows stay as they are until a filter changes, and a
--- rescan then reads only rows up to the anchor (the seq at the moment Follow went off).
--- @param rs LogRowsState
--- @param d DiagState
--- @param cf LogCompiled
--- @param limit int rows shown
--- @param follow boolean
--- @param budget int rows examined at most by each scan
--- @return boolean changed
function model.update_rows(rs, d, cf, limit, follow, budget)
	local rb, rf = rings(d)
	local head = d.seq
	if not follow and not rs.anchor then rs.anchor = rs.top or head end
	if follow then rs.anchor = nil end
	local sig = table.concat({ epoch(d), cf.sig, cf.sev_sig, limit, tostring(rs.anchor) }, "|")
	local changed = false
	if rs.sig ~= sig then
		rs.sig = sig
		rs.groups = {}
		rs.top = rs.anchor or head
		rs.below = rs.top + 1
		rs.limit = limit
		changed = true
	end
	local groups = rs.groups
	local sevs = cf.sevs
	if follow and head > rs.top then
		if head - rs.top > budget then
			-- Too far behind (a long pause): start again from the head.
			rs.sig = nil
			return model.update_rows(rs, d, cf, limit, follow, budget)
		end
		local added = 0
		scan_fwd(rb, rf, rs.top, budget, function(r, i)
			if not (sevs[r.sev[i]] and match(r, i, cf)) then return end
			if cf.min_tick and r.tick[i] < cf.min_tick then return end
			added = added + 1
			local g = groups[1]
			if g and identical(g, r, i) then
				g.n = g.n + 1
				g.seq, g.tick, g.sev, g.a, g.b, g.delivery = r.seq[i], r.tick[i], r.sev[i], r.a[i], r.b[i], r.delivery[i]
			else
				table.insert(groups, 1, new_group(r, i))
			end
		end)
		rs.top = head
		if added > 0 then
			changed = true
			if #groups > limit then
				for k = #groups, limit + 1, -1 do groups[k] = nil end
				rs.below = nil
			end
		end
	end
	if follow and cf.min_tick then
		while #groups > 0 and groups[#groups].tick < cf.min_tick do
			groups[#groups] = nil
			changed = true
		end
	end
	if rs.below then
		local ended, below = scan_back(rb, rf, rs.below, cf, budget, function(r, i)
			if not sevs[r.sev[i]] then return false end
			local last = groups[#groups]
			if last and identical(last, r, i) then
				last.n = last.n + 1
				last.first, last.first_tick = r.seq[i], r.tick[i]
				return false
			end
			if #groups >= limit then return true end
			groups[#groups + 1] = new_group(r, i)
			changed = true
			return false
		end)
		-- Stopped by a row that does not fit: the last row's count is complete, and nothing more is needed.
		if ended or (below and #groups >= limit) then
			rs.below = nil
		else
			rs.below = below
		end
		changed = true
	end
	return changed
end

-- ---------------------------------------------------------------- severity counts

--- @class LogCountsState per player (player_data.log_counts)
--- @field sig string?
--- @field hi uint every row up to this seq is counted (or was outside the filter)
--- @field build uint? the first count is still scanning backward below this seq
--- @field lo uint[] per ring: rows below this seq are no longer counted
--- @field buckets {[int]: int[]}[] per ring: seq // BUCKET -> {errors, warnings, infos}
--- @field total int[] {errors, warnings, infos}

--- @param cs LogCountsState
--- @param ring int 1 basic, 2 full
local function count_add(cs, ring, seq, sev)
	local b = math.floor(seq / model.BUCKET)
	local by = cs.buckets[ring]
	local c = by[b]
	if not c then
		c = { 0, 0, 0 }
		by[b] = c
	end
	c[sev] = c[sev] + 1
	cs.total[sev] = cs.total[sev] + 1
end

--- Rows before the window or gone from the ring stop counting: whole buckets below the boundary go, and the bucket
--- the boundary falls in is counted again from the rows still there.
--- @param cs LogCountsState
--- @param ring int
--- @param r DiagRing
--- @param cf LogCompiled
local function count_trim(cs, ring, r, cf)
	local low
	if r.count == 0 then
		low = cs.hi + 1
	else
		local k = cf.min_tick and first_at_tick(r, cf.min_tick) or 0
		low = k < r.count and r.seq[at(r, k)] or cs.hi + 1
	end
	if cs.lo[ring] == low then return end
	cs.lo[ring] = low
	local B = model.BUCKET
	local lb = math.floor(low / B)
	local by, total = cs.buckets[ring], cs.total
	for b, c in pairs(by) do
		if b <= lb then
			total[1], total[2], total[3] = total[1] - c[1], total[2] - c[2], total[3] - c[3]
			by[b] = nil
		end
	end
	local last = math.min(cs.hi, (lb + 1) * B - 1)
	local k = first_after(r, low - 1)
	local n = r.count
	while k < n do
		local i = at(r, k)
		local seq = r.seq[i]
		if seq > last then break end
		if match(r, i, cf) then count_add(cs, ring, seq, r.sev[i]) end
		k = k + 1
	end
end

--- Errors, warnings and infos in the window under every filter but the severities.
--- @param cs LogCountsState
--- @param d DiagState
--- @param cf LogCompiled
--- @param budget int
--- @return boolean building the first count is not complete yet (the totals are a lower bound)
function model.update_counts(cs, d, cf, budget)
	local rb, rf = rings(d)
	local sig = epoch(d) .. "|" .. cf.sig
	if cs.sig ~= sig then
		cs.sig = sig
		cs.hi = d.seq
		cs.build = d.seq + 1
		cs.lo = { -1, -1 }
		cs.buckets = { {}, {} }
		cs.total = { 0, 0, 0 }
	end
	local min_tick = cf.min_tick
	if d.seq > cs.hi then
		scan_fwd(rb, rf, cs.hi, math.huge, function(r, i)
			if (not min_tick or r.tick[i] >= min_tick) and match(r, i, cf) then
				count_add(cs, r == rb and 1 or 2, r.seq[i], r.sev[i])
			end
		end)
		cs.hi = d.seq
	end
	if cs.build then
		local ended, below = scan_back(rb, rf, cs.build, cf, budget, function(r, i)
			count_add(cs, r == rb and 1 or 2, r.seq[i], r.sev[i])
			return false
		end)
		cs.build = (not ended) and below or nil
		if cs.build then return true end
	end
	count_trim(cs, 1, rb, cf)
	if rf then count_trim(cs, 2, rf, cf) end
	return false
end

-- ---------------------------------------------------------------- unread errors (the tab's badge)

--- @class LogBadgeState per player (player_data.log_badge)
--- @field epoch string?
--- @field hi uint every row up to this seq is counted
--- @field n int unread errors
--- @field seen uint? the seen seq the count started from

--- Counts error rows newer than `seen` (the newest seq the player had on screen in the Log), at most `budget` new rows
--- per call.
--- @param bs LogBadgeState
--- @param d DiagState
--- @param seen uint?
--- @param budget int
--- @return int unread
function model.update_badge(bs, d, seen, budget)
	local e = epoch(d)
	if bs.epoch ~= e then
		bs.epoch, bs.hi, bs.n, bs.seen = e, 0, 0, nil
	end
	seen = seen or 0
	-- A seen seq above the head belongs to an earlier diagnostics state.
	if seen > d.seq then seen = 0 end
	if seen ~= bs.seen then
		bs.seen, bs.hi, bs.n = seen, seen, 0
	end
	local rb, rf = rings(d)
	if d.seq > bs.hi then
		local n = bs.n
		bs.hi = scan_fwd(rb, rf, bs.hi, budget, function(r, i)
			if r.sev[i] == DIAG_SEV_ERROR then n = n + 1 end
		end)
		bs.n = n
	end
	return bs.n
end

-- ---------------------------------------------------------------- summary (B14)

--- @class LogSummaryState per player while Summary is on (player_data.log_summary)
--- @field sig string?
--- @field below uint? the scan continues below this seq; nil once done
--- @field as_of uint seq the summary counts up to
--- @field as_of_tick uint
--- @field stations {[uint]: int[]}? while scanning: id -> {events, worst severity}
--- @field items {[int]: int[]}?
--- @field scanned int rows in the summary
--- @field top_stations {id: uint, n: int, sev: int}[]? once done
--- @field top_items {item: int, n: int, sev: int}[]?

--- @param map {[number]: int[]}
--- @param key_name string
--- @return table[]
local function top(map, key_name)
	local list = {}
	for id, c in pairs(map) do list[#list + 1] = { [key_name] = id, n = c[1], sev = c[2] } end
	table.sort(list, function(a, b)
		if a.n ~= b.n then return a.n > b.n end
		if a.sev ~= b.sev then return a.sev < b.sev end
		return a[key_name] < b[key_name]
	end)
	for k = #list, model.SUMMARY_TOP + 1, -1 do list[k] = nil end
	return list
end
model.top = top

--- The top stations (station column) and items by event count in the window, under every filter including the
--- severities, each with its worst severity. Computed once per toggle or filter change by a backward scan of at most
--- `budget` rows per call; it does not follow newer rows.
--- @param ss LogSummaryState
--- @param d DiagState
--- @param cf LogCompiled
--- @param budget int
--- @return boolean done
function model.update_summary(ss, d, cf, budget)
	local rb, rf = rings(d)
	local sig = epoch(d) .. "|" .. cf.sig .. "|" .. cf.sev_sig
	if ss.sig ~= sig then
		ss.sig = sig
		ss.below = d.seq + 1
		ss.as_of = d.seq
		ss.as_of_tick = game.tick
		ss.stations, ss.items = {}, {}
		ss.top_stations, ss.top_items = nil, nil
		ss.scanned = 0
	end
	if not ss.below then return true end
	local stations, items, sevs = ss.stations, ss.items, cf.sevs
	local scanned = ss.scanned
	local ended, below = scan_back(rb, rf, ss.below, cf, budget, function(r, i)
		local sev = r.sev[i]
		if not sevs[sev] then return false end
		scanned = scanned + 1
		local st = r.station[i]
		if st ~= 0 then
			local c = stations[st]
			if c then
				c[1] = c[1] + 1
				if sev < c[2] then c[2] = sev end
			else
				stations[st] = { 1, sev }
			end
		end
		local item = r.item[i]
		if item ~= 0 then
			local c = items[item]
			if c then
				c[1] = c[1] + 1
				if sev < c[2] then c[2] = sev end
			else
				items[item] = { 1, sev }
			end
		end
		return false
	end)
	ss.scanned = scanned
	if ended then
		ss.below = nil
		ss.top_stations = top(stations, "id")
		ss.top_items = top(items, "item")
		ss.stations, ss.items = nil, nil
		return true
	end
	ss.below = below
	return false
end

-- ---------------------------------------------------------------- text

--- "Exported 1,234 rows" style counts and the "×n" of a collapsed row.
--- @param n int
--- @return string
function model.repeat_caption(n)
	if n <= 1 then return "" end
	return "×" .. format.number(n)
end

--- The age column: two units at most.
--- @param now uint
--- @param g LogGroup
--- @param short fun(ticks: number): string util.short_duration
--- @return string
function model.age_caption(now, g, short)
	return short(now - g.tick)
end

--- The age column's tooltip: the absolute tick and the game time it was written at (a range for a collapsed row).
--- @param g LogGroup
--- @param long fun(ticks: number): string util.format_duration
--- @return LocalisedString
function model.age_tooltip(g, long)
	if g.n > 1 then
		return { "cybersyn-gui.log-age-range-tooltip", tostring(g.first_tick), tostring(g.tick), long(g.first_tick),
			long(g.tick), format.number(g.n) }
	end
	return { "cybersyn-gui.log-age-tooltip", tostring(g.tick), long(g.tick) }
end

local STATE_KEYS = {}
for name, v in pairs(defines.train_state) do STATE_KEYS[v] = string.gsub(name, "_", "-") end

--- @class LogTextContext name lookups the message needs; all pure reads
--- @field station fun(id: uint): string? a station's (or depot's) name
--- @field player fun(index: uint): string?
--- @field duration fun(ticks: number): string util.format_duration
--- @field stock fun(reason: int, a: int, b: int): LocalisedString unserved-text stock caption
--- @field chip fun(reason: int): LocalisedString unserved-text chip caption

local ACK_END = { "expired", "reason-changed", "resolved", "manual" }

--- @param n number
--- @return string
local function amount(n)
	return format_signal_count(n or 0)
end

--- The message column (PLAN3 §4.7): what happened, with the row's numbers; the severity dot carries the colour.
--- @param g LogGroup
--- @param ctx LogTextContext
--- @return LocalisedString
function model.message(g, ctx)
	local kind, code, a, b = g.kind, g.code, g.a, g.b
	local key = DIAG_KIND_KEYS[kind]
	if not key then return tostring(kind) end
	local msg = "cybersyn-diag.msg-" .. key
	if kind == DIAG_KIND_UNSERVED_REASON then
		local stock = ctx.stock(code, a, b)
		if stock == "–" then return { msg .. "-plain", ctx.chip(code) } end
		return { msg, ctx.chip(code), stock }
	elseif kind == DIAG_KIND_SERVED then
		return { msg, ctx.duration(a), format.number(b), ctx.chip(code) }
	elseif kind == DIAG_KIND_FLAPPING then
		return { msg, format.number(b), ctx.chip(code) }
	elseif kind == DIAG_KIND_DISPATCH_FAILED then
		local name = DIAG_DISPATCH_NAMES[code]
		return { msg, name and { "cybersyn-diag.dispatch-" .. string.gsub(name, "_", "-") } or tostring(code) }
	elseif kind == DIAG_KIND_DELIVERY_FAILED then
		local name = DIAG_FAIL_NAMES[code]
		local cause = name and { "cybersyn-diag.fail-" .. string.gsub(name, "_", "-") } or tostring(code)
		if a == 1 then return { msg .. "-at-p", cause } end
		if b == 1 then return { msg .. "-at-r", cause } end
		return { msg, cause }
	elseif kind == DIAG_KIND_ALERT then
		local name = DIAG_ALERT_NAMES[code]
		return { msg, name and { "cybersyn-diag.alert-" .. string.gsub(name, "_", "-") } or tostring(code) }
	elseif kind == DIAG_KIND_STATION_POWER then
		return { msg .. (a == 1 and "-on" or "-off") }
	elseif kind == DIAG_KIND_STATION_LIMIT or kind == DIAG_KIND_STATION_DISABLED then
		return { msg, tostring(a), tostring(b) }
	elseif kind == DIAG_KIND_SHORT_LOAD or kind == DIAG_KIND_RESIDUAL_CARGO then
		return { msg, amount(b), amount(a) }
	elseif kind == DIAG_KIND_UNEXPECTED_CARGO then
		return { msg, amount(b) }
	elseif kind == DIAG_KIND_SCHEDULE_EDITED then
		local who = ctx.player(a) or tostring(a)
		if b > 1 then return { msg .. "-group", who, format.number(b) } end
		return { msg, who }
	elseif kind == DIAG_KIND_LINT then
		local check = LINT_KEYS[a]
		local caption = check and { "cybersyn-diag.lint-" .. check } or tostring(a)
		return { msg .. (code == DIAG_LINT_CLEARED and "-cleared" or "-appeared"), caption }
	elseif kind == DIAG_KIND_ACKNOWLEDGED then
		local what = { "cybersyn-diag.ack-kind-" .. (DIAG_ACK_KINDS[code] or "request") }
		local who = ctx.player(g.station2) or "-"
		if a == 0 then return { msg .. "-reason", what, who } end
		return { msg, what, who, ctx.duration(a - g.tick) }
	elseif kind == DIAG_KIND_UNACKNOWLEDGED then
		local what = { "cybersyn-diag.ack-kind-" .. (DIAG_ACK_KINDS[code] or "request") }
		local cause = ACK_END[b] or "expired"
		if b == DIAG_ACK_END_MANUAL then
			return { msg .. "-manual", what, ctx.player(g.station2) or "-" }
		end
		return { msg, what, { "cybersyn-diag.ack-end-" .. cause } }
	elseif kind == DIAG_KIND_MANUAL_ACTION then
		local name = ACTION_NAMES[a]
		local action = name and { "cybersyn-diag.action-" .. string.gsub(name, "_", "-") } or tostring(a)
		local who = g.station2 == 0 and { "cybersyn-diag.log-server" } or (ctx.player(g.station2) or tostring(g.station2))
		return { msg, action, who }
	elseif kind == DIAG_KIND_DISPATCHED then
		return { msg, amount(b), format.number(a) }
	elseif kind == DIAG_KIND_ARRIVE_P or kind == DIAG_KIND_LEAVE_P or kind == DIAG_KIND_ARRIVE_R then
		return { msg, amount(a) }
	elseif kind == DIAG_KIND_TRAIN_STATE then
		if code == defines.train_state.wait_signal then
			return { msg .. "-wait-signal", ctx.duration(a) }
		end
		local state = STATE_KEYS[code]
		return { msg, state and { "cybersyn-diag.train-state-" .. state } or tostring(code) }
	end
	return { msg }
end

--- Chat tags for a row (PLAN3 §11.6): a train by its front stock's unit number, a stop by its unit number, a map
--- position; the engine makes each clickable in chat.
--- @param train_unit uint? front_stock.unit_number
--- @param stop_unit uint? the stop's unit number
--- @param gps {x: number, y: number, surface: string}?
--- @param item string? item hash
--- @return string
function model.chat_tags(train_unit, stop_unit, gps, item)
	local parts = {}
	if train_unit then parts[#parts + 1] = "[train=" .. train_unit .. "]" end
	if stop_unit then parts[#parts + 1] = "[train-stop=" .. stop_unit .. "]" end
	if item then
		local name, quality = unhash_signal(item)
		if prototypes.fluid[name] then
			parts[#parts + 1] = "[fluid=" .. name .. "]"
		elseif quality then
			parts[#parts + 1] = "[item=" .. name .. ",quality=" .. quality .. "]"
		else
			parts[#parts + 1] = "[item=" .. name .. "]"
		end
	end
	if gps then
		parts[#parts + 1] = string.format("[gps=%d,%d,%s]", math.floor(gps.x), math.floor(gps.y), gps.surface)
	end
	return table.concat(parts, " ")
end

return model
