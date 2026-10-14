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

--- Plain-data summary for the dev interface.
--- @return table
function stats.summary()
	local s = get()
	local d10, p10 = stats.window(10)
	local d60, p60 = stats.window(60)
	local cycle_avg, cycle_n = stats.cycle_average(60)
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
	}
end

return stats
