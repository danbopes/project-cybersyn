--- One-time conversion of a stock Cybersyn save to this fork's storage shape.
---
--- From 3.0.0 the fork has its own version line, so installing it over stock Cybersyn
--- (2.0.53 or 2.0.54) is a version change and raises on_configuration_changed. The
--- conversion is still keyed on a flag in storage rather than on that event or its old
--- version: the fork's earlier builds were numbered 2.0.54 like upstream and installed
--- over stock without raising any event, so a save recorded as 2.0.54 may be a stock save
--- or one those builds already converted, and only the flag tells them apart. The flag
--- also lets a conversion that failed part way run again on the next load. It is checked
--- at the start of the mod's scheduled ticks, because on_load may not write to storage.
---
--- Running from the scheduled tick also means upstream's own migration chain has
--- already finished by the time this sees the save, so it always works on a well-formed
--- upstream save rather than an arbitrarily old one. Nothing Cybersyn runs between
--- on_configuration_changed and the first scheduled tick reads the fields changed here.
---
--- It must not hook on_tick just for the first tick: unregistering the handler after it
--- ran left the event registered on load but not in the save, and Factorio refuses
--- every multiplayer join over that difference (multiplayer.script-event-mismatch).
---
--- Keep this idempotent: the flag is written last, so a conversion that errors part
--- way is retried on the next load.

local function migrate_to_fork()
	if storage.fork_migrated then return end

	-- The fork once shipped its own 2.0.27 before upstream shipped a different one, and
	-- saves that recorded a fork version then skipped every upstream migration below it.
	-- Recreate whatever those skipped migrations would have added.
	local tables = {
		"tick_data", "to_comb", "to_comb_params", "to_output", "to_stop",
		"stations", "active_station_ids", "warmup_station_ids", "warmup_station_cycles",
		"depots", "trains", "available_trains", "layouts", "layout_train_count",
		"refuelers", "to_refuelers", "each_refuelers", "perf_cache",
		"se_elevators", "connected_surfaces",
	}
	for _, key in pairs(tables) do
		if storage[key] == nil then storage[key] = {} end
	end
	if storage.total_ticks == nil then storage.total_ticks = 0 end
	if storage.layout_top_id == nil then storage.layout_top_id = 1 end

	-- all_*_stations became all_*_stops when entries changed from station ids to
	-- StopInfo. tick_init rebuilds all three every cycle, so this only drops the old keys.
	storage.economy = { all_r_stops = {}, all_p_stops = {}, all_names = {} }

	for _, station in pairs(storage.stations) do
		station.secondary_inv_combs = station.secondary_inv_combs or {}
		station.tick_signals = nil -- both moved onto StopInfo
		station.item_p_counts = nil
	end

	-- Body of upstream's ["2.0.27"] entry, which saves on a fork version never ran.
	-- is_delivery_allowed_for_train reads depot_surface_id unguarded.
	for _, cybersyn_train in pairs(storage.trains) do
		if cybersyn_train.depot_surface_id == nil then
			local train = cybersyn_train.entity
			if train and train.valid then
				local depot = storage.depots[cybersyn_train.depot_id]
				local depot_stop = depot and depot.entity_stop
				cybersyn_train.depot_surface_id =
					depot_stop and depot_stop.surface_index or train.front_stock.surface_index
			end
		end
	end

	storage.fork_migrated = true

	-- the economy was just replaced under a dispatcher that may be part-way through a
	-- cycle, so restart it the same way on_config_changed does
	storage.tick_state = STATE_INIT
	storage.tick_data = {}
end

local diag = require("scripts.diag")
local stats = require("scripts.stats")
local lint = require("scripts.lint")

-- Bumped whenever a fork release adds storage fields an existing save must get before its first planner tick.
-- 1: diagnostics (storage.diag per setting, storage.acks), Train.in_interrupt/last_state/state_tick, the
-- available-train counters and the cycle fields of storage.stats.
-- 2: the diagnostics sweep and ring fields (cycles, item_served, preallocated columns), the planner-cycle counters
-- and refuel_since of storage.stats.
-- 3: the setup registry (storage.lint_registry), seeded from to_comb/to_stop/to_comb_params.
-- 4: storage.manager.fleet_networks dropped; the Overview's Fleet tile reads the HUD's cache (hud_networks).
-- 5: the Stations tab keeps its toggled chip in stations_chip alone (stations_status_filter folded into it).
-- 6: drops storage.recent_external_items, whose only reader (the recent-items panel) is gone.
-- 7: Station.secondary_inv_combs keyed by unit number on every path (see rekey_secondary_inv_combs).
local SCHEMA = 7

local fork_migrations = {}

--- Stations built from their station combinator once stored their inventory combinators as an array, so removing
--- one or changing its mode looked it up by unit number, missed it and left it registered: a removed entity, or a
--- combinator in another mode whose signals were then read as inventory. Rebuilds every table keyed by unit number
--- from what is really next to the stop. Safe to repeat; the planner rebuilds each station's stops every poll, so
--- nothing else needs refreshing.
--- @return {rekeyed: int, invalid: int, wrong_mode: int, added: int}
function fork_migrations.rekey_secondary_inv_combs()
	local counts = { rekeyed = 0, invalid = 0, wrong_mode = 0, added = 0 }
	local to_stop = storage.to_stop or {}
	for _, station in pairs(storage.stations or {}) do
		local old = station.secondary_inv_combs or {}
		local combs = {}
		for key, comb in pairs(old) do
			if not (comb and comb.valid) then
				counts.invalid = counts.invalid + 1
			elseif not is_secondary_inventory_op(comb.get_or_create_control_behavior().parameters.operation) then
				counts.wrong_mode = counts.wrong_mode + 1
			else
				local unit = comb.unit_number
				if key ~= unit then counts.rekeyed = counts.rekeyed + 1 end
				combs[unit] = comb
			end
		end
		-- The same area and ownership test the build paths use, so an inventory combinator a lost lookup left out
		-- joins its station here.
		local stop = station.entity_stop
		if stop and stop.valid then
			local x, y = stop.position.x, stop.position.y
			local found = stop.surface.find_entities_filtered({
				area = { { x - 2, y - 2 }, { x + 2, y + 2 } }, name = COMBINATOR_NAME,
			})
			for _, comb in pairs(found) do
				local unit = comb.unit_number
				if comb.valid and not combs[unit] and to_stop[unit] == stop
					and is_secondary_inventory_op(comb.get_or_create_control_behavior().parameters.operation) then
					combs[unit] = comb
					counts.added = counts.added + 1
				end
			end
		end
		station.secondary_inv_combs = combs
	end
	if counts.rekeyed + counts.invalid + counts.wrong_mode + counts.added > 0 then
		log(string.format("cybersyn: inventory combinators re-keyed %d, dropped %d invalid and %d in another mode, added %d",
			counts.rekeyed, counts.invalid, counts.wrong_mode, counts.added))
	end
	return counts
end

--- Creates or refreshes every field of SCHEMA; idempotent, and it never touches the dispatcher's cycle state.
function fork_migrations.migrate_schema()
	diag.migrate()
	local tick = game.tick
	for _, train in pairs(storage.trains or {}) do
		local entity = train.entity
		if entity and entity.valid then
			-- Schedule changes made while the mod was not loaded raised no event, so the cache is rebuilt.
			train.in_interrupt = train_in_interrupt(entity)
			if train.last_state == nil then
				train.last_state = entity.state
				train.state_tick = tick
			end
		end
	end
	stats.init()
	-- Rebuilt on every configuration change too: a mod change can add or remove combinators without the build
	-- handlers seeing it.
	lint.registry_seed()
	if storage.manager then storage.manager.fleet_networks = nil end
	-- Once only: from this step on, "setup" in stations_chip names the Setup status, not an older build's Problems chip.
	if (storage.fork_schema or 0) < 5 then
		for _, pd in pairs(storage.manager and storage.manager.players or {}) do
			if pd.stations_chip == "setup" then pd.stations_chip = "problems" end
			if pd.stations_status_filter then pd.stations_chip = pd.stations_status_filter end
			pd.stations_status_filter = nil
		end
	end
	storage.recent_external_items = nil
	fork_migrations.rekey_secondary_inv_combs()
	storage.fork_schema = SCHEMA
end

function fork_migrations.run_once()
	if not storage.fork_migrated then
		migrate_to_fork()
	end
	if (storage.fork_schema or 0) < SCHEMA then
		fork_migrations.migrate_schema()
	end
end

return fork_migrations
