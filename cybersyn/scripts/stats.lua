-- Delivery throughput counters for the manager's Overview tab. Unlike the collector this is always on, because
-- throughput can only be measured as it happens; every hook is O(1) plus O(manifest) and every structure is a
-- fixed-size ring, so neither UPS nor the save grows with time.

local stats = {}

local MINUTE = 3600
local HOUR = 216000
local MINUTE_SLOTS = 60
local HOUR_SLOTS = 24
-- Weight of the newest cycle sample in the moving average: about the last 20 deliveries dominate.
local EMA_ALPHA = 0.1

stats.MINUTE = MINUTE
stats.HOUR = HOUR

--- @class StatsBucket
--- @field start_tick uint
--- @field deliveries int
--- @field dispatches int
--- @field items {[string]: int} delivered amount per item hash
--- @field cycle_sum number? seconds from dispatch to unloaded, summed over the deliveries completed in this bucket
--- @field cycle_n int? deliveries that contributed to cycle_sum
--- @field wait_sum number? request wait in ticks, summed over the requests fulfilled (dispatched) in this bucket
--- @field wait_n int? fulfilled requests that contributed to wait_sum
--- @field wait_max uint? longest of those waits, in ticks
--- @field wait_max_station uint? requester station id of the longest wait
--- @field wait_max_hash string? item hash of the longest wait
--- @field wait_max_tick uint? when the longest wait ended (its train was dispatched)

--- @class Stats
--- @field minute {[int]: StatsBucket} ring of one-minute buckets
--- @field hour {[int]: StatsBucket} ring of one-hour buckets
--- @field totals {deliveries: int, dispatches: int, items: int, since_tick: uint}
--- @field cycle {ema_seconds: number?}

--- @return Stats
local function new_stats()
	return {
		minute = {},
		hour = {},
		totals = { deliveries = 0, dispatches = 0, items = 0, since_tick = game and game.tick or 0 },
		cycle = { ema_seconds = nil },
	}
end

--- Repairs a missing or partial table so saves from older versions keep working.
--- @return Stats
local function get()
	local s = storage.stats
	if not s then
		s = new_stats()
		storage.stats = s
		return s
	end
	s.minute = s.minute or {}
	s.hour = s.hour or {}
	s.totals = s.totals or { deliveries = 0, dispatches = 0, items = 0, since_tick = game.tick }
	s.cycle = s.cycle or {}
	-- Early builds kept a fixed sample ring, which covered under a minute on busy bases.
	s.cycle.samples = nil
	s.cycle.next = nil
	return s
end

--- @param hash string
--- @return boolean
local function hash_is_valid(hash)
	local name, quality = unhash_signal(hash)
	if quality and not prototypes.quality[quality] then return false end
	return prototypes.item[name] ~= nil or prototypes.fluid[name] ~= nil
end

--- Buckets outlive mod changes, so a removed item or quality would otherwise reach the GUI and fail there.
--- @param s Stats
local function purge_invalid_hashes(s)
	for _, ring in pairs({ s.minute, s.hour }) do
		for _, b in pairs(ring) do
			for hash in pairs(b.items) do
				if not hash_is_valid(hash) then b.items[hash] = nil end
			end
			if b.wait_max_hash and not hash_is_valid(b.wait_max_hash) then b.wait_max_hash = nil end
		end
	end
end

function stats.init()
	purge_invalid_hashes(get())
end

--- @return Stats
function stats.get()
	return get()
end

--- @param ring {[int]: StatsBucket}
--- @param slots int
--- @param width uint
--- @param tick uint
--- @return StatsBucket
local function bucket(ring, slots, width, tick)
	local start = tick - tick % width
	local index = (start / width) % slots + 1
	local b = ring[index]
	if not b or b.start_tick ~= start then
		b = { start_tick = start, deliveries = 0, dispatches = 0, items = {} }
		ring[index] = b
	end
	return b
end

--- Called from create_delivery once the schedule is applied.
--- @param train Train
function stats.record_dispatch(train)
	local tick = game.tick
	train.dispatch_tick = tick
	local s = get()
	local m = bucket(s.minute, MINUTE_SLOTS, MINUTE, tick)
	m.dispatches = m.dispatches + 1
	local h = bucket(s.hour, HOUR_SLOTS, HOUR, tick)
	h.dispatches = h.dispatches + 1
	s.totals.dispatches = s.totals.dispatches + 1
end

--- @param b StatsBucket
--- @param ticks uint
--- @param station_id uint
--- @param hash string
local function add_wait(b, ticks, station_id, hash)
	b.wait_sum = (b.wait_sum or 0) + ticks
	b.wait_n = (b.wait_n or 0) + 1
	local max = b.wait_max
	-- Ties keep the first request, so a bucket's maximum does not flicker between equal waits.
	if not max or ticks > max then
		b.wait_max = ticks
		b.wait_max_station = station_id
		b.wait_max_hash = hash
		b.wait_max_tick = game.tick
	end
end

--- Called from create_delivery for each manifest item whose request start was tracked. Only bucket aggregates are
--- kept, so the cost and the save size do not depend on the number of deliveries.
--- @param ticks uint time from the request start until the delivery was created
--- @param station_id uint requester station id
--- @param hash string item hash
function stats.record_fulfilment(ticks, station_id, hash)
	local tick = game.tick
	local s = get()
	add_wait(bucket(s.minute, MINUTE_SLOTS, MINUTE, tick), ticks, station_id, hash)
	add_wait(bucket(s.hour, HOUR_SLOTS, HOUR, tick), ticks, station_id, hash)
end

--- Called when a train has finished unloading at the requester, before its manifest is cleared.
--- @param train Train
function stats.record_delivery_complete(train)
	local tick = game.tick
	local s = get()
	local m = bucket(s.minute, MINUTE_SLOTS, MINUTE, tick)
	local h = bucket(s.hour, HOUR_SLOTS, HOUR, tick)
	m.deliveries = m.deliveries + 1
	h.deliveries = h.deliveries + 1
	local totals = s.totals
	totals.deliveries = totals.deliveries + 1

	local manifest = train.manifest
	if manifest then
		local m_items, h_items = m.items, h.items
		for _, item in ipairs(manifest) do
			local hash = hash_item(item.name, item.quality)
			local count = item.count or 0
			m_items[hash] = (m_items[hash] or 0) + count
			h_items[hash] = (h_items[hash] or 0) + count
			totals.items = totals.items + count
		end
	end

	-- Trains already on a delivery when this version was installed have no dispatch tick.
	local dispatch_tick = train.dispatch_tick
	if dispatch_tick and dispatch_tick <= tick then
		local seconds = (tick - dispatch_tick) / 60
		m.cycle_sum = (m.cycle_sum or 0) + seconds
		m.cycle_n = (m.cycle_n or 0) + 1
		h.cycle_sum = (h.cycle_sum or 0) + seconds
		h.cycle_n = (h.cycle_n or 0) + 1
		local cycle = s.cycle
		local ema = cycle.ema_seconds
		cycle.ema_seconds = ema and (ema + EMA_ALPHA * (seconds - ema)) or seconds
	end
	train.dispatch_tick = nil
end

--- Sums the minute buckets of the last `minutes` minutes, the current partial minute included.
--- @param minutes int 1..60
--- @param want_items boolean? also sum delivered amounts per item
--- @return int deliveries
--- @return int dispatches
--- @return {[string]: int}? items
function stats.window(minutes, want_items)
	local s = get()
	local tick = game.tick
	local oldest = tick - tick % MINUTE - (minutes - 1) * MINUTE
	local deliveries, dispatches = 0, 0
	local items = want_items and {} or nil
	for _, b in pairs(s.minute) do
		if b.start_tick >= oldest and b.start_tick <= tick then
			deliveries = deliveries + b.deliveries
			dispatches = dispatches + b.dispatches
			if items then
				for hash, count in pairs(b.items) do
					items[hash] = (items[hash] or 0) + count
				end
			end
		end
	end
	return deliveries, dispatches, items
end

--- Deliveries over the last 24 hourly buckets, the current partial hour included.
--- @return int
function stats.day_deliveries()
	local s = get()
	local tick = game.tick
	local oldest = tick - tick % HOUR - (HOUR_SLOTS - 1) * HOUR
	local n = 0
	for _, b in pairs(s.hour) do
		if b.start_tick >= oldest and b.start_tick <= tick then
			n = n + b.deliveries
		end
	end
	return n
end

--- Mean dispatch-to-unloaded time over the deliveries completed in the last `minutes` minute buckets,
--- the current partial minute included.
--- @param minutes int 1..60
--- @return number? seconds nil when no timed delivery completed in the window
--- @return int deliveries that were timed
function stats.cycle_average(minutes)
	local s = get()
	local tick = game.tick
	local oldest = tick - tick % MINUTE - (minutes - 1) * MINUTE
	local sum, n = 0, 0
	for _, b in pairs(s.minute) do
		if b.cycle_n and b.start_tick >= oldest and b.start_tick <= tick then
			sum = sum + b.cycle_sum
			n = n + b.cycle_n
		end
	end
	if n == 0 then return nil, 0 end
	return sum / n, n
end

--- @class StatsWindow
--- @field minutes int
--- @field span_ticks uint time the buckets cover so far, for rates
--- @field partial boolean recording started inside the period, so span_ticks is shorter than the period
--- @field deliveries int
--- @field dispatches int
--- @field items {[string]: int} delivered amount per item hash
--- @field amount int all delivered amounts together
--- @field cycle_avg number? seconds from dispatch to unloaded
--- @field cycle_n int
--- @field wait_avg number? ticks from request start to dispatch
--- @field wait_n int
--- @field wait_max uint? ticks
--- @field slowest StatsBucket[] buckets with a fulfilled request, as they are; read only
--- @field slowest_minutes {[StatsBucket]: true} entries of `slowest` that are minute buckets in an hour-bucket period

--- Everything the Overview shows for one period: minute buckets for 10 and 60 minutes, hour buckets for longer
--- periods (rounded up to whole hours), the current partial bucket included.
--- @param minutes int 10, 60 or 1440
--- @return StatsWindow
function stats.aggregate(minutes)
	local s = get()
	local tick = game.tick
	local ring, width, count
	if minutes <= MINUTE_SLOTS then
		ring, width, count = s.minute, MINUTE, minutes
	else
		ring, width, count = s.hour, HOUR, math.min(math.ceil(minutes / 60), HOUR_SLOTS)
	end
	local oldest = tick - tick % width - (count - 1) * width
	local since = s.totals.since_tick or 0
	local out = {
		minutes = minutes,
		span_ticks = tick - math.max(oldest, since) + 1,
		partial = since > oldest,
		deliveries = 0,
		dispatches = 0,
		items = {},
		amount = 0,
		cycle_n = 0,
		wait_n = 0,
		slowest = {},
		slowest_minutes = {},
	}
	local items = out.items
	local amount, cycle_sum, wait_sum, wait_max = 0, 0, 0, nil
	for _, b in pairs(ring) do
		if b.start_tick >= oldest and b.start_tick <= tick then
			out.deliveries = out.deliveries + b.deliveries
			out.dispatches = out.dispatches + b.dispatches
			for hash, n in pairs(b.items) do
				items[hash] = (items[hash] or 0) + n
				amount = amount + n
			end
			if b.cycle_n then
				cycle_sum = cycle_sum + b.cycle_sum
				out.cycle_n = out.cycle_n + b.cycle_n
			end
			if b.wait_n then
				wait_sum = wait_sum + b.wait_sum
				out.wait_n = out.wait_n + b.wait_n
				if not wait_max or b.wait_max > wait_max then wait_max = b.wait_max end
				out.slowest[#out.slowest + 1] = b
			end
		end
	end
	-- The current hour holds a single maximum until it closes, so a longer period would list fewer of the recent
	-- slow requests than a shorter one; its minute buckets stand in for it in the list (not in the sums).
	if ring == s.hour then
		local hour_start = tick - tick % HOUR
		local slowest, minutes = {}, out.slowest_minutes
		for _, b in ipairs(out.slowest) do
			if b.start_tick ~= hour_start then slowest[#slowest + 1] = b end
		end
		for _, b in pairs(s.minute) do
			if b.wait_n and b.start_tick >= hour_start and b.start_tick <= tick then
				slowest[#slowest + 1] = b
				minutes[b] = true
			end
		end
		out.slowest = slowest
	end
	out.amount = amount
	if out.cycle_n > 0 then out.cycle_avg = cycle_sum / out.cycle_n end
	if out.wait_n > 0 then out.wait_avg = wait_sum / out.wait_n end
	out.wait_max = wait_max
	return out
end

--- Plain-data summary for the dev interface.
--- @return table
function stats.summary()
	local s = get()
	local d10, p10 = stats.window(10)
	local d60, p60 = stats.window(60)
	local cycle_avg, cycle_n = stats.cycle_average(60)
	local w60, w24 = stats.aggregate(60), stats.aggregate(1440)
	local item_entries = 0
	for _, ring in pairs({ s.minute, s.hour }) do
		for _, b in pairs(ring) do
			for _ in pairs(b.items) do
				item_entries = item_entries + 1
			end
		end
	end
	return {
		tick = game.tick,
		totals = s.totals,
		deliveries_10m = d10,
		dispatches_10m = p10,
		deliveries_60m = d60,
		dispatches_60m = p60,
		deliveries_24h = stats.day_deliveries(),
		cycle_avg_60m = cycle_avg,
		cycle_samples_60m = cycle_n,
		cycle_ema = s.cycle.ema_seconds,
		item_entries = item_entries,
		waits_60m = { n = w60.wait_n, avg = w60.wait_avg, max = w60.wait_max, buckets = #w60.slowest },
		waits_24h = { n = w24.wait_n, avg = w24.wait_avg, max = w24.wait_max, buckets = #w24.slowest },
	}
end

return stats
