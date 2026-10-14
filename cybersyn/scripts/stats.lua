-- Delivery throughput counters for the manager's Overview tab. Unlike the collector this is always on, because
-- throughput can only be measured as it happens; every hook is O(1) plus O(manifest) and every structure is a
-- fixed-size ring, so neither UPS nor the save grows with time.

local stats = {}

local MINUTE = 3600
local HOUR = 216000
local MINUTE_SLOTS = 60
local HOUR_SLOTS = 24
local CYCLE_SAMPLES = 200
-- Weight of the newest cycle sample in the moving average: about the last 20 deliveries dominate.
local EMA_ALPHA = 0.1

stats.MINUTE = MINUTE
stats.HOUR = HOUR

--- @class StatsBucket
--- @field start_tick uint
--- @field deliveries int
--- @field dispatches int
--- @field items {[string]: int} delivered amount per item hash

--- @class StatsCycleSample
--- @field seconds number dispatch to unloading complete
--- @field hash string? first manifest item
--- @field tick uint completion tick

--- @class Stats
--- @field minute {[int]: StatsBucket} ring of one-minute buckets
--- @field hour {[int]: StatsBucket} ring of one-hour buckets
--- @field totals {deliveries: int, dispatches: int, items: int, since_tick: uint}
--- @field cycle {ema_seconds: number?, samples: {[int]: StatsCycleSample}, next: int}

--- @return Stats
local function new_stats()
	return {
		minute = {},
		hour = {},
		totals = { deliveries = 0, dispatches = 0, items = 0, since_tick = game and game.tick or 0 },
		cycle = { ema_seconds = nil, samples = {}, next = 1 },
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
	s.cycle = s.cycle or { samples = {}, next = 1 }
	s.cycle.samples = s.cycle.samples or {}
	s.cycle.next = s.cycle.next or 1
	return s
end

function stats.init()
	get()
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

	local first_hash
	local manifest = train.manifest
	if manifest then
		local m_items, h_items = m.items, h.items
		for i, item in ipairs(manifest) do
			local hash = hash_item(item.name, item.quality)
			if i == 1 then first_hash = hash end
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
		local cycle = s.cycle
		cycle.samples[cycle.next] = { seconds = seconds, hash = first_hash, tick = tick }
		cycle.next = cycle.next % CYCLE_SAMPLES + 1
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

--- Mean dispatch-to-unloaded time of the samples completed within `window_ticks`.
--- @param window_ticks uint
--- @return number? seconds nil when no sample is that recent
--- @return int samples
function stats.cycle_average(window_ticks)
	local s = get()
	local oldest = game.tick - window_ticks
	local sum, n = 0, 0
	for _, sample in pairs(s.cycle.samples) do
		if sample.tick >= oldest then
			sum = sum + sample.seconds
			n = n + 1
		end
	end
	if n == 0 then return nil, 0 end
	return sum / n, n
end

--- Plain-data summary for the dev interface.
--- @return table
function stats.summary()
	local s = get()
	local d10, p10 = stats.window(10)
	local d60, p60 = stats.window(60)
	local cycle_avg, cycle_n = stats.cycle_average(HOUR)
	local samples = 0
	for _ in pairs(s.cycle.samples) do
		samples = samples + 1
	end
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
		cycle_samples = samples,
		cycle_ema = s.cycle.ema_seconds,
		item_entries = item_entries,
	}
end

return stats
