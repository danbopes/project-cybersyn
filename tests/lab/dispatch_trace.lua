-- Golden dispatch trace recorder, started by run.sh right after lib.lua on a fresh boot, before any test file can
-- touch the world. Reads lab.trace_cfg = {start = tick, length = ticks, speed = n}.
--
-- The dev save is quiescent on its own: by its boot tick every hub train is stuck on a cross-cluster dispatch and
-- no signal-B request clears its threshold, so an unattended trace records nothing. At the start tick the recorder
-- therefore applies a fixed stimulus, the same on every run:
--   * every item and fluid value of every constant combinator on cyb-bench is multiplied by 10, which lifts the
--     signal-B requests and provides over their thresholds.
--   * an operator stands in for inserters and pumps: a train waiting at its provider gets its manifest inserted,
--     a train waiting at its requester is emptied.
--   * the clusters are dead-end lines whose stops all face west-bound traffic, so a train can never reach a stop or
--     its depot east of it. A train in no_path gets one temporary waypoint at the east end of its line (a
--     double-headed train reverses at any schedule record) and then reaches its target west-bound. Cybersyn ignores
--     temporary rail records, as it does for Space Exploration's elevator waypoints. Hub trains whose target is on
--     another line stay in no_path after their one waypoint.
-- From then on every tick (not a sampling interval, so nothing between samples can be missed or aligned
-- differently) the cybersyn train table is read and each change of a tracked field becomes one event
-- {tick, train_id, field, value}; each station's deliveries_total and display_state go to station_events the same
-- way. Nothing here depends on wall-clock time or on when RCON commands arrive, so the trace is a pure function of
-- the save and the mod. At the last tick lab.golden() pins the manager's view of that state in summary.json.

local cfg = lab.trace_cfg
local START, STOP = cfg.start, cfg.start + cfg.length
local STATUS_P, STATUS_R = 2, 4
local WAIT_STATION, NO_PATH = defines.train_state.wait_station, defines.train_state.no_path
local FIELDS = { "status", "p", "r", "depot", "available", "manifest" }
local STATION_FIELDS = { "deliveries_total", "display_state" }

local trace = {
	start = START,
	stop = STOP,
	registered = game.tick,
	events = {},
	last = {},
	station_events = {},
	station_last = {},
	loads = 0,
	unloads = 0,
	turns = 0,
	turned = {},
	line_end = {},
	scaled = 0,
	done = false,
}
lab.trace = trace

if game.tick >= START then
	trace.late = true
	trace.done = true
	rcon.print("TRACE late: registered at tick " .. game.tick .. ", start tick " .. START)
	return
end

local function hash_item(name, quality)
	if quality == nil or quality == "normal" then return name end
	return name .. "|" .. quality
end

local function manifest_string(manifest)
	if not manifest then return false end
	local parts = {}
	for i, m in ipairs(manifest) do
		parts[i] = hash_item(m.name, m.quality) .. "=" .. m.count
	end
	return table.concat(parts, ",")
end

local function nz(v)
	if v == nil or v == 0 then return false end
	return v
end

local function stimulus()
	local surface = game.surfaces["cyb-bench"]
	if not surface then return end
	for _, cc in ipairs(surface.find_entities_filtered({ name = "constant-combinator" })) do
		local b = cc.get_control_behavior()
		if b then
			for i = 1, b.sections_count do
				local section = b.get_section(i)
				local filters = section.filters
				local changed = false
				for _, f in ipairs(filters) do
					if f.value and f.value.type ~= "virtual" and f.min and f.min ~= 0 then
						f.min = f.min * 10
						changed = true
						trace.scaled = trace.scaled + 1
					end
				end
				if changed then section.filters = filters end
			end
		end
	end
end

--- The easternmost straight rail of the line a train stands on.
--- @param t LuaTrain
local function line_end(t)
	local stock = t.front_stock
	local y = stock.position.y
	local rail = trace.line_end[y]
	if rail and rail.valid then return rail end
	for _, r in ipairs(stock.surface.find_entities_filtered({ area = { { -1e4, y - 1 }, { 1e4, y + 1 } }, type = "straight-rail" })) do
		if not rail or r.position.x > rail.position.x then rail = r end
	end
	trace.line_end[y] = rail
	return rail
end

--- @param t LuaTrain
local function turn_around(id, t)
	local schedule = t.get_schedule()
	local current = schedule.current
	local record = schedule.get_record({ schedule_index = current })
	if not record then return end
	local rail = line_end(t)
	if not rail or record.rail == rail then return end
	local target = record.station or (record.rail and string.format("%d,%d/%d", record.rail.position.x,
		record.rail.position.y, record.rail_direction or -1)) or "?"
	if trace.turned[id] == target then return end
	trace.turned[id] = target
	schedule.add_record({
		rail = rail,
		rail_direction = defines.rail_direction.front,
		temporary = true,
		wait_conditions = { { type = "time", ticks = 1 } },
		index = { schedule_index = current },
	})
	schedule.go_to_station(current)
	trace.turns = trace.turns + 1
end

local function operate(id, tr)
	local t = tr.entity
	if not (t and t.valid) then return end
	local state = t.state
	if state == NO_PATH then
		turn_around(id, t)
		return
	end
	if not (state == WAIT_STATION and t.station) then return end
	if tr.status == STATUS_P and tr.manifest then
		local inserted = false
		for _, m in ipairs(tr.manifest) do
			if m.type == "fluid" then
				local have = t.get_fluid_count(m.name)
				if have < m.count and t.insert_fluid({ name = m.name, amount = m.count - have }) > 0 then
					inserted = true
				end
			else
				local have = t.get_item_count({ name = m.name, quality = m.quality })
				if have < m.count and t.insert({ name = m.name, count = m.count - have, quality = m.quality }) > 0 then
					inserted = true
				end
			end
		end
		if inserted then trace.loads = trace.loads + 1 end
	elseif tr.status == STATUS_R then
		if next(t.get_contents()) or next(t.get_fluid_contents()) then
			t.clear_items_inside()
			t.clear_fluids_inside()
			trace.unloads = trace.unloads + 1
		end
	end
end

local function sample(tick)
	local trains = remote.call("cybersyn", "read_global", "trains")
	local ids = {}
	for id in pairs(trains) do ids[#ids + 1] = id end
	for id in pairs(trace.last) do
		if not trains[id] then ids[#ids + 1] = id end
	end
	table.sort(ids)
	local events = trace.events
	for _, id in ipairs(ids) do
		local tr = trains[id]
		local last = trace.last[id]
		if not tr then
			if last then
				events[#events + 1] = { tick, id, "removed", true }
				trace.last[id] = nil
			end
		else
			if not last then
				last = {}
				trace.last[id] = last
			end
			local now = {
				status = tr.status,
				p = nz(tr.p_station_id),
				r = nz(tr.r_station_id),
				depot = nz(tr.depot_id),
				available = tr.is_available == true,
				manifest = manifest_string(tr.manifest),
			}
			for _, field in ipairs(FIELDS) do
				if last[field] ~= now[field] then
					last[field] = now[field]
					events[#events + 1] = { tick, id, field, now[field] }
					-- A new leg may need its own waypoint even when it heads for the same depot as the last one.
					if field == "status" then trace.turned[id] = nil end
				end
			end
			if tick < STOP then operate(id, tr) end
		end
	end
end

--- Station-side counterpart of sample(): the planner's per-station bookkeeping, read field by field so the
--- per-tick cost stays a few remote calls per station rather than a copy of the whole station table.
local station_ids
local function sample_stations(tick)
	if not station_ids then
		station_ids = {}
		for id in pairs(remote.call("cybersyn", "read_global", "stations")) do station_ids[#station_ids + 1] = id end
		table.sort(station_ids)
	end
	local events, last_of = trace.station_events, trace.station_last
	for _, id in ipairs(station_ids) do
		local last = last_of[id]
		if not last then
			last = {}
			last_of[id] = last
		end
		for _, field in ipairs(STATION_FIELDS) do
			local v = remote.call("cybersyn", "read_global", "stations", id, field)
			if v == nil then v = false end
			if last[field] ~= v then
				last[field] = v
				events[#events + 1] = { tick, id, field, v }
			end
		end
	end
end

local function finish(tick)
	trace.done = true
	game.speed = 1
	script.on_event(defines.events.on_tick, nil)
	helpers.write_file("lab/dispatch-trace.json", helpers.table_to_json({
		save = cfg.save,
		start = START,
		stop = STOP,
		stimulus = "x10 every constant combinator item/fluid value; operator loads at P, empties at R, one east-end waypoint per no_path target",
		events = trace.events,
		station_events = trace.station_events,
	}), false, 0)

	-- The summary baseline is taken inside the same tick handler, so it describes exactly tick STOP.
	local D, pi = lab.D, lab.pi
	local ok, err = pcall(function()
		local summary = remote.call(D, "collect")
		remote.call(D, "open", pi)
		lab.big_screen(pi)
		local keys = lab.tab_keys(pi)
		local golden = lab.golden(pi)
		remote.call(D, "close", pi)
		golden.tick = tick
		golden.summary = summary
		golden.tabs = keys
		helpers.write_file("lab/summary.json", helpers.table_to_json(golden), false, 0)
	end)
	trace.summary_error = not ok and err or nil
end

script.on_event(defines.events.on_tick, function(e)
	local tick = e.tick
	if tick < START then return end
	if tick == START then
		stimulus()
	end
	sample(tick)
	sample_stations(tick)
	if tick >= STOP then finish(tick) end
end)

game.speed = cfg.speed or 20
rcon.print("TRACE registered at tick " .. game.tick .. ", window " .. START .. ".." .. STOP)
