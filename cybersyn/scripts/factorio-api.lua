--By Mami
local get_distance = require("__flib__.position").distance
local table_insert = table.insert
local bit_extract = bit32.extract
local bit_replace = bit32.replace
local string_sub = string.sub
local string_len = string.len

local DEFINES_WORKING = defines.entity_status.working
local DEFINES_LOW_POWER = defines.entity_status.low_power
local DEFINES_COMBINATOR_INPUT = defines.circuit_connector_id.combinator_input


---@param map_data MapData
---@param item_name string
function get_stack_size(map_data, item_name)
	return game.item_prototypes[item_name].stack_size
end

---@param item_order table<string, int>
---@param item1_name string
---@param item2_name string
function item_lt(item_order, item1_name, item2_name)
	return item_order[item1_name] < item_order[item2_name]
end


---NOTE: does not check .valid
---@param entity0 LuaEntity
---@param entity1 LuaEntity
function get_dist(entity0, entity1)
	local surface0 = entity0.surface.index
	local surface1 = entity1.surface.index
	return (surface0 == surface1 and get_distance(entity0.position, entity1.position) or DIFFERENT_SURFACE_DISTANCE)
end


---@param cache PerfCache
---@param surface LuaSurface
function se_get_space_elevator_name(cache, surface)
	---@type LuaEntity?
	local entity = nil
	local cache_idx = surface.index
	if cache.se_get_space_elevator_name then
		entity = cache.se_get_space_elevator_name[cache_idx]
	else
		cache.se_get_space_elevator_name = {}
	end

	if not entity or not entity.valid then
		--Caching failed, default to expensive lookup
		entity = surface.find_entities_filtered({
			name = SE_ELEVATOR_STOP_PROTO_NAME,
			type = "train-stop",
			limit = 1,
		})[1]

		if entity then
			cache.se_get_space_elevator_name[cache_idx] = entity
		end
	end

	if entity and entity.valid then
		return string_sub(entity.backer_name, 1, string_len(entity.backer_name) - SE_ELEVATOR_SUFFIX_LENGTH)
	else
		return nil
	end
end
---@param cache PerfCache
---@param surface_index uint
local function se_get_zone_from_surface_index(cache, surface_index)
	---@type uint?
	local zone_index = nil
	---@type uint?
	local zone_orbit_index = nil
	local cache_idx = 2*surface_index
	if cache.se_get_zone_from_surface_index then
		zone_index = cache.se_get_zone_from_surface_index[cache_idx - 1]--[[@as uint]]
		--zones may not have an orbit_index
		zone_orbit_index = cache.se_get_zone_from_surface_index[cache_idx]--[[@as uint?]]
	else
		cache.se_get_zone_from_surface_index = {}
	end

	if not zone_index then
		zone = remote.call("space-exploration", "get_zone_from_surface_index", {surface_index = surface_index})

		if zone and type(zone.index) == "number" then
			zone_index = zone.index--[[@as uint]]
			zone_orbit_index = zone.orbit_index--[[@as uint?]]
			--NOTE: caching these indices could be a problem if SE is not deterministic in choosing them
			cache.se_get_zone_from_surface_index[cache_idx - 1] = zone_index
			cache.se_get_zone_from_surface_index[cache_idx] = zone_orbit_index
		end
	end

	return zone_index, zone_orbit_index
end

---@param train LuaTrain
---@return LuaEntity?
function get_any_train_entity(train)
	return train.valid and (train.front_stock or train.back_stock or train.carriages[1]) or nil
end


---@param e Station|Refueler|Train
---@param network_name string
---@return int
function get_network_mask(e, network_name)
	return e.network_name == NETWORK_EACH and (e.network_mask[network_name] or 0) or e.network_mask--[[@as int]]
end


------------------------------------------------------------------------------
--[[train schedules]]--
------------------------------------------------------------------------------


local condition_wait_inactive = {type = "inactivity", compare_type = "and", ticks = INACTIVITY_TIME}
local condition_only_inactive = {condition_wait_inactive}
local condition_unloading_order = {{type = "empty", compare_type = "and"}}
local condition_direct_to_station = {{type = "time", compare_type = "and", ticks = 1}}
---@param stop LuaEntity
---@param manifest Manifest
---@param enable_inactive boolean
function create_loading_order(stop, manifest, enable_inactive)
	local condition = {}
	for _, item in ipairs(manifest) do
		local cond_type
		if item.type == "fluid" then
			cond_type = "fluid_count"
		else
			cond_type = "item_count"
		end

		condition[#condition + 1] = {
			type = cond_type,
			compare_type = "and",
			condition = {comparator = "≥", first_signal = {type = item.type, name = item.name}, constant = item.count}
		}

		condition[#condition + 1] = condition_wait_inactive
	end
	if enable_inactive then
		condition[#condition + 1] = condition_wait_inactive
	end
	return {station = stop.backer_name, wait_conditions = condition}
end

---@param stop LuaEntity
---@param enable_inactive boolean
function create_unloading_order(stop, enable_inactive)
	if enable_inactive then
		return {station = stop.backer_name, wait_conditions = condition_only_inactive}
	else
		return {station = stop.backer_name, wait_conditions = condition_unloading_order}
	end
end

---@param depot_name string
function create_inactivity_order(depot_name)
	return {station = depot_name, wait_conditions = condition_only_inactive}
end

---@param stop LuaEntity
function create_direct_to_station_order(stop)
	return {rail = stop.connected_rail, rail_direction = stop.connected_rail_direction, wait_conditions = condition_direct_to_station}
end

---@param train LuaTrain
---@param depot_name string
function set_depot_schedule(train, depot_name)
	if train.valid then
		train.schedule = {current = 1, records = {create_inactivity_order(depot_name)}}
	end
end

---@param train LuaTrain
function lock_train(train)
	if train.valid then
		train.manual_mode = true
	end
end
---@param train LuaTrain
function lock_train_to_depot(train)
	if train.valid then
		local schedule = train.schedule
		if schedule then
			local record = schedule.records[schedule.current]
			if record then
				local wait = record.wait_conditions
				if wait and wait[1] then
					wait[1].ticks = LOCK_TRAIN_TIME
				else
					record.wait_conditions = {{type = "inactivity", compare_type = "and", ticks = LOCK_TRAIN_TIME}}
				end
				train.schedule = schedule
			else
				train.manual_mode = true
			end
		else
			train.manual_mode = true
		end
	end
end

---@param train LuaTrain
---@param stop LuaEntity
---@param old_name string
function rename_manifest_schedule(train, stop, old_name)
	if train.valid then
		local new_name = stop.backer_name
		local schedule = train.schedule
		if not schedule then return end
		for i, record in ipairs(schedule.records) do
			if record.station == old_name then
				record.station = new_name
			end
		end
		train.schedule = schedule
	end
end

---@param elevator_name string
---@param is_train_in_orbit boolean
function se_create_elevator_order(elevator_name, is_train_in_orbit)
	return {station = elevator_name..(is_train_in_orbit and SE_ELEVATOR_ORBIT_SUFFIX or SE_ELEVATOR_PLANET_SUFFIX)}
end
---NOTE: does not check .valid
---@param map_data MapData
---@param train LuaTrain
---@param depot_stop LuaEntity
---@param same_depot boolean
---@param p_stop LuaEntity
---@param p_enable_inactive boolean
---@param r_stop LuaEntity
---@param r_enable_inactive boolean
---@param manifest Manifest
---@param start_at_depot boolean?
function set_manifest_schedule(map_data, train, depot_stop, same_depot, p_stop, p_enable_inactive, r_stop, r_enable_inactive, manifest, start_at_depot)
	--NOTE: can only return false if start_at_depot is false, it should be incredibly rare that this function returns false
	if not p_stop.connected_rail or not r_stop.connected_rail then
		--NOTE: create a schedule that cannot be fulfilled, the train will be stuck but it will give the player information what went wrong
		train.schedule = {current = 1, records = {
			create_inactivity_order(depot_stop.backer_name),
			create_loading_order(p_stop, manifest, p_enable_inactive),
			create_unloading_order(r_stop, r_enable_inactive),
		}}
		lock_train(train)
		send_alert_station_of_train_broken(map_data, train)
		return true
	end
	if same_depot and not depot_stop.connected_rail then
		--NOTE: create a schedule that cannot be fulfilled, the train will be stuck but it will give the player information what went wrong
		train.schedule = {current = 1, records = {
			create_inactivity_order(depot_stop.backer_name),
			create_loading_order(p_stop, manifest, p_enable_inactive),
			create_unloading_order(r_stop, r_enable_inactive),
		}}
		lock_train(train)
		send_alert_depot_of_train_broken(map_data, train)
		return true
	end

	local old_schedule
	if not start_at_depot then
		old_schedule = train.schedule
	end
	local t_surface = train.front_stock.surface
	local p_surface = p_stop.surface
	local r_surface = r_stop.surface
	local d_surface_i = depot_stop.surface.index
	local t_surface_i = t_surface.index
	local p_surface_i = p_surface.index
	local r_surface_i = r_surface.index
	local is_p_on_t = t_surface_i == p_surface_i
	local is_r_on_t = t_surface_i == r_surface_i
	local is_d_on_t = t_surface_i == d_surface_i
	if is_p_on_t and is_r_on_t and is_d_on_t then
		local records = {
			create_inactivity_order(depot_stop.backer_name),
			create_direct_to_station_order(p_stop),
			create_loading_order(p_stop, manifest, p_enable_inactive),
			create_direct_to_station_order(r_stop),
			create_unloading_order(r_stop, r_enable_inactive),
		}
		if same_depot then
			records[6] = create_direct_to_station_order(depot_stop)
		end
		train.schedule = {
			current = start_at_depot and 1 or 2--[[@as uint]],
			records = records
		}
		if old_schedule and not train.has_path then
			train.schedule = old_schedule
			return false
		else
			return true
		end
	elseif IS_SE_PRESENT then
		local other_surface_i = (not is_p_on_t and p_surface_i) or (not is_r_on_t and r_surface_i) or d_surface_i
		if (is_p_on_t or p_surface_i == other_surface_i) and (is_r_on_t or r_surface_i == other_surface_i) and (is_d_on_t or d_surface_i == other_surface_i) then
			local t_zone_index, t_zone_orbit_index = se_get_zone_from_surface_index(map_data.perf_cache, t_surface_i)
			local other_zone_index, other_zone_orbit_index = se_get_zone_from_surface_index(map_data.perf_cache, other_surface_i)
			if t_zone_index and other_zone_index then
				local is_train_in_orbit = other_zone_orbit_index == t_zone_index
				if is_train_in_orbit or t_zone_orbit_index == other_zone_index then
					local elevator_name = se_get_space_elevator_name(map_data.perf_cache, t_surface)
					if elevator_name then
						local records = {create_inactivity_order(depot_stop.backer_name)}
						if t_surface_i == p_surface_i then
							records[#records + 1] = create_direct_to_station_order(p_stop)
						else
							records[#records + 1] = se_create_elevator_order(elevator_name, is_train_in_orbit)
							is_train_in_orbit = not is_train_in_orbit
						end
						records[#records + 1] = create_loading_order(p_stop, manifest, p_enable_inactive)

						if p_surface_i ~= r_surface_i then
							records[#records + 1] = se_create_elevator_order(elevator_name, is_train_in_orbit)
							is_train_in_orbit = not is_train_in_orbit
						elseif t_surface_i == r_surface_i then
							records[#records + 1] = create_direct_to_station_order(r_stop)
						end
						records[#records + 1] = create_unloading_order(r_stop, r_enable_inactive)
						if r_surface_i ~= d_surface_i then
							records[#records + 1] = se_create_elevator_order(elevator_name, is_train_in_orbit)
							is_train_in_orbit = not is_train_in_orbit
						end

						train.schedule = {current = start_at_depot and 1 or 2--[[@as uint]], records = records}
						if old_schedule and not train.has_path then
							train.schedule = old_schedule
							return false
						else
							return true
						end
					end
				end
			end
		end
	end
	--NOTE: create a schedule that cannot be fulfilled, the train will be stuck but it will give the player information what went wrong
	train.schedule = {current = 1, records = {
		create_inactivity_order(depot_stop.backer_name),
		create_loading_order(p_stop, manifest, p_enable_inactive),
		create_unloading_order(r_stop, r_enable_inactive),
	}}
	lock_train(train)
	send_alert_cannot_path_between_surfaces(map_data, train)
	return true
end

---NOTE: does not check .valid
---@param map_data MapData
---@param train LuaTrain
---@param stop LuaEntity
function add_refueler_schedule(map_data, train, stop)
	local schedule = train.schedule or {current = 1, records = {}}
	local i = schedule.current
	if i == 1 then
		i = #schedule.records + 1--[[@as uint]]
		schedule.current = i
	end

	if not stop.connected_rail then
		send_alert_refueler_of_train_broken(map_data, train)
		return false
	end

	local t_surface = train.front_stock.surface
	local f_surface = stop.surface
	local t_surface_i = t_surface.index
	local f_surface_i = f_surface.index
	if t_surface_i == f_surface_i then
		table_insert(schedule.records, i, create_direct_to_station_order(stop))
		i = i + 1
		table_insert(schedule.records, i, create_inactivity_order(stop.backer_name))

		train.schedule = schedule
		return true
	elseif IS_SE_PRESENT then
		local t_zone_index, t_zone_orbit_index = se_get_zone_from_surface_index(map_data.perf_cache, t_surface_i)
		local other_zone_index, other_zone_orbit_index = se_get_zone_from_surface_index(map_data.perf_cache, f_surface_i)
		if t_zone_index and other_zone_index then
			local is_train_in_orbit = other_zone_orbit_index == t_zone_index
			if is_train_in_orbit or t_zone_orbit_index == other_zone_index then
				local elevator_name = se_get_space_elevator_name(map_data.perf_cache, t_surface)
				if elevator_name then
					local cur_order = schedule.records[i]
					local is_elevator_in_orders_already = cur_order and cur_order.station == elevator_name..(is_train_in_orbit and SE_ELEVATOR_ORBIT_SUFFIX or SE_ELEVATOR_PLANET_SUFFIX)
					if not is_elevator_in_orders_already then
						table_insert(schedule.records, i, se_create_elevator_order(elevator_name, is_train_in_orbit))
					end
					i = i + 1
					is_train_in_orbit = not is_train_in_orbit
					table_insert(schedule.records, i, create_inactivity_order(stop.backer_name))
					i = i + 1
					if not is_elevator_in_orders_already then
						table_insert(schedule.records, i, se_create_elevator_order(elevator_name, is_train_in_orbit))
						i = i + 1
						is_train_in_orbit = not is_train_in_orbit
					end

					train.schedule = schedule
					return true
				end
			end
		end
	end
	--create an order that probably cannot be fulfilled and alert the player
	table_insert(schedule.records, i, create_inactivity_order(stop.backer_name))
	lock_train(train)
	train.schedule = schedule
	send_alert_cannot_path_between_surfaces(map_data, train)
	return false
end


------------------------------------------------------------------------------
--[[combinators]]--
------------------------------------------------------------------------------


---@param comb LuaEntity
function get_comb_control(comb)
	--NOTE: using this as opposed to get_comb_params gives you R/W access
	return comb.get_or_create_control_behavior()--[[@as LuaArithmeticCombinatorControlBehavior]]
end
---@param comb LuaEntity
function get_comb_params(comb)
	return comb.get_or_create_control_behavior().parameters--[[@as ArithmeticCombinatorParameters]]
end

---NOTE: does not check .valid
---@param station Station
function set_station_from_comb(station)
	--NOTE: this does nothing to update currently active deliveries
	--NOTE: this can only be called at the tick init boundary
	local params = get_comb_params(station.entity_comb1)
	local signal = params.first_signal

	local bits = params.second_constant or 0
	local is_pr_state = bit_extract(bits, 0, 2)
	local allows_all_trains = bit_extract(bits, SETTING_DISABLE_ALLOW_LIST) > 0
	local is_stack = bit_extract(bits, SETTING_IS_STACK) > 0
	local enable_inactive = bit_extract(bits, SETTING_ENABLE_INACTIVE) > 0

	station.allows_all_trains = allows_all_trains
	station.is_stack = is_stack
	station.enable_inactive = enable_inactive
	station.is_p = (is_pr_state == 0 or is_pr_state == 1) or nil
	station.is_r = (is_pr_state == 0 or is_pr_state == 2) or nil

	local new_name = signal and signal.name or nil
	if station.network_name ~= new_name then
		station.network_name = new_name
		if station.network_name == NETWORK_EACH then
			station.network_mask = {}
		else
			station.network_mask = 0
		end
	end
end
---NOTE: does not check .valid
---@param mod_settings CybersynModSettings
---@param train Train
---@param comb LuaEntity
function set_train_from_comb(mod_settings, train, comb)
	--NOTE: this does nothing to update currently active deliveries
	local params = get_comb_params(comb)
	local signal = params.first_signal
	local network_name = signal and signal.name or nil

	local bits = params.second_constant or 0
	local disable_bypass = bit_extract(bits, SETTING_DISABLE_DEPOT_BYPASS) > 0
	local use_any_depot = bit_extract(bits, SETTING_USE_ANY_DEPOT) > 0

	train.network_name = network_name
	train.disable_bypass = disable_bypass
	train.use_any_depot = use_any_depot

	local is_each = train.network_name == NETWORK_EACH
	if is_each then
		train.network_mask = {}
	else
		train.network_mask = mod_settings.network_mask
	end
	train.priority = mod_settings.priority
	local signals = comb.get_merged_signals(defines.circuit_connector_id.combinator_input)
	if signals then
		for k, v in pairs(signals) do
			local item_name = v.signal.name
			local item_type = v.signal.type
			local item_count = v.count
			if item_name then
				if item_type == "virtual" then
					if item_name == SIGNAL_PRIORITY then
						train.priority = item_count
					elseif is_each then
						if item_name ~= REQUEST_THRESHOLD and item_name ~= LOCKED_SLOTS then
							train.network_mask[item_name] = item_count
						end
					end
				end
				if item_name == network_name then
					train.network_mask = item_count
				end
			end
		end
	end
end
---@param map_data MapData
---@param mod_settings CybersynModSettings
---@param id uint
---@param refueler Refueler
function set_refueler_from_comb(map_data, mod_settings, id, refueler)
	--NOTE: this does nothing to update currently active deliveries
	local params = get_comb_params(refueler.entity_comb)
	local bits = params.second_constant or 0
	local signal = params.first_signal
	local old_network = refueler.network_name
	local old_network_mask = refueler.network_mask

	refueler.network_name = signal and signal.name or nil
	refueler.allows_all_trains = bit_extract(bits, SETTING_DISABLE_ALLOW_LIST) > 0
	refueler.priority = mod_settings.priority

	local is_each = refueler.network_name == NETWORK_EACH
	if is_each then
		map_data.each_refuelers[id] = true
		refueler.network_mask = {}
	else
		map_data.each_refuelers[id] = nil
		refueler.network_mask = mod_settings.network_mask
	end

	local signals = refueler.entity_comb.get_merged_signals(DEFINES_COMBINATOR_INPUT)
	if signals then
		for k, v in pairs(signals) do
			local item_name = v.signal.name
			local item_type = v.signal.type
			local item_count = v.count
			if item_name then
				if item_type == "virtual" then
					if item_name == SIGNAL_PRIORITY then
						refueler.priority = item_count
					elseif is_each then
						if item_name ~= REQUEST_THRESHOLD and item_name ~= LOCKED_SLOTS then
							refueler.network_mask[item_name] = item_count
						end
					end
				end
				if item_name == refueler.network_name then
					refueler.network_mask = item_count
				end
			end
		end
	end

	local f, a
	if old_network == NETWORK_EACH then
		f, a = pairs(old_network_mask--[[@as {[string]: int}]])
	elseif old_network ~= refueler.network_name then
		f, a = once, old_network
	else
		f, a = once, nil
	end
	for network_name, _ in f, a do
		local network = map_data.to_refuelers[network_name]
		if network then
			network[id] = nil
			if next(network) == nil then
				map_data.to_refuelers[network_name] = nil
			end
		end
	end

	if refueler.network_name == NETWORK_EACH then
		f, a = pairs(refueler.network_mask--[[@as {[string]: int}]])
	elseif old_network ~= refueler.network_name then
		f, a = once, refueler.network_name
	else
		f, a = once, nil
	end
	for network_name, _ in f, a do
		local network = map_data.to_refuelers[network_name]
		if not network then
			network = {}
			map_data.to_refuelers[network_name] = network
		end
		network[id] = true
	end
end

---@param map_data MapData
---@param station Station
function update_display(map_data, station)
	local comb = station.entity_comb1
	if comb.valid then
		local control = get_comb_control(comb)
		local params = control.parameters
		--NOTE: the following check can cause a bug where the display desyncs if the player changes the operation of the combinator and then changes it back before the mod can notice, however removing it causes a bug where the user's change is overwritten and ignored. Everything's bad we need an event to catch copy-paste by blueprint.
		if params.operation == MODE_PRIMARY_IO or params.operation == MODE_PRIMARY_IO_ACTIVE or params.operation == MODE_PRIMARY_IO_FAILED_REQUEST then
			if station.display_state == 0 then
				params.operation = MODE_PRIMARY_IO
			elseif station.display_state%2 == 1 then
				params.operation = MODE_PRIMARY_IO_ACTIVE
			else
				params.operation = MODE_PRIMARY_IO_FAILED_REQUEST
			end
			control.parameters = params
		end
	end
end

---@param comb LuaEntity
function get_comb_gui_settings(comb)
	local params = get_comb_params(comb)
	local op = params.operation

	local selected_index = 0
	local switch_state = "none"
	local bits = params.second_constant or 0
	local is_pr_state = bit_extract(bits, 0, 2)
	if is_pr_state == 0 then
		switch_state = "none"
	elseif is_pr_state == 1 then
		switch_state = "left"
	elseif is_pr_state == 2 then
		switch_state = "right"
	end

	if op == MODE_PRIMARY_IO or op == MODE_PRIMARY_IO_ACTIVE or op == MODE_PRIMARY_IO_FAILED_REQUEST then
		selected_index = 1
	elseif op == MODE_DEPOT then
		selected_index = 2
	elseif op == MODE_REFUELER then
		selected_index = 3
	elseif op == MODE_SECONDARY_IO then
		selected_index = 4
	elseif op == MODE_WAGON then
		selected_index = 5
	end
	return selected_index--[[@as uint]], params.first_signal, switch_state, bits
end
---@param comb LuaEntity
---@param is_pr_state 0|1|2
function set_comb_is_pr_state(comb, is_pr_state)
	local control = get_comb_control(comb)
	local param = control.parameters
	local bits = param.second_constant or 0

	param.second_constant = bit_replace(bits, is_pr_state, 0, 2)
	control.parameters = param
end
---@param comb LuaEntity
---@param n int
---@param bit boolean
function set_comb_setting(comb, n, bit)
	local control = get_comb_control(comb)
	local param = control.parameters
	local bits = param.second_constant or 0

	param.second_constant = bit_replace(bits, bit and 1 or 0, n)
	control.parameters = param
end
---@param comb LuaEntity
---@param signal SignalID?
function set_comb_network_name(comb, signal)
	local control = get_comb_control(comb)
	local param = control.parameters

	param.first_signal = signal
	control.parameters = param
end
---@param comb LuaEntity
---@param op string
function set_comb_operation(comb, op)
	local control = get_comb_control(comb)
	local params = control.parameters
	params.operation = op
	control.parameters = params
end


---@param map_data MapData
---@param comb LuaEntity
---@param signals ConstantCombinatorParameters[]?
function set_combinator_output(map_data, comb, signals)
	local out = map_data.to_output[comb.unit_number]
	if out.valid then
		out.get_or_create_control_behavior().parameters = signals
	end
end

---@param station Station
function get_signals(station)
	local comb1 = station.entity_comb1
	local status1 = comb1.status
	---@type Signal[]?
	local comb1_signals = nil
	---@type Signal[]?
	local comb2_signals = nil
	if status1 == DEFINES_WORKING or status1 == DEFINES_LOW_POWER then
		comb1_signals = comb1.get_merged_signals(DEFINES_COMBINATOR_INPUT)
	end
	local comb2 = station.entity_comb2
	if comb2 then
		local status2 = comb2.status
		if status2 == DEFINES_WORKING or status2 == DEFINES_LOW_POWER then
			comb2_signals = comb2.get_merged_signals(DEFINES_COMBINATOR_INPUT)
		end
	end
	return comb1_signals, comb2_signals
end

---@param map_data MapData
---@param station Station
function set_comb2(map_data, station)
	local sign = mod_settings.invert_sign and -1 or 1
	if station.entity_comb2 then
		local deliveries = station.deliveries
		local signals = {}
		for item_name, count in pairs(deliveries) do
			local i = #signals + 1
			local is_fluid = game.item_prototypes[item_name] == nil--NOTE: this is expensive
			signals[i] = {index = i, signal = {type = is_fluid and "fluid" or "item", name = item_name}, count = sign*count}
		end
		set_combinator_output(map_data, station.entity_comb2, signals)
	end
end


------------------------------------------------------------------------------
--[[alerts]]--
------------------------------------------------------------------------------


---@param train LuaTrain
---@param icon {}
---@param message string
local function send_alert_for_train(train, icon, message)
	local loco = train.front_stock or train.back_stock
	if loco then
		for _, player in pairs(loco.force.players) do
			player.add_custom_alert(
			loco,
			icon,
			{message},
			true)
		end
	end
end
local send_alert_about_missing_train_icon = {name = MISSING_TRAIN_NAME, type = "fluid"}
---@param r_stop LuaEntity
---@param p_stop LuaEntity
---@param message string
function send_alert_about_missing_train(r_stop, p_stop, message)
	for _, player in pairs(r_stop.force.players) do
		player.add_custom_alert(
		r_stop,
		send_alert_about_missing_train_icon,
		{message, r_stop.backer_name, p_stop.backer_name},
		true)
	end
end

---@param train LuaTrain
function send_alert_sounds(train)
	local loco = get_any_train_entity(train)
	if loco then
		for _, player in pairs(loco.force.players) do
			player.play_sound({path = ALERT_SOUND})
		end
	end
end


---@param r_stop LuaEntity
---@param p_stop LuaEntity
function send_alert_missing_train(r_stop, p_stop)
	send_alert_about_missing_train(r_stop, p_stop, "cybersyn-messages.missing-train")
end
---@param r_stop LuaEntity
---@param p_stop LuaEntity
function send_alert_no_train_has_capacity(r_stop, p_stop)
	send_alert_about_missing_train(r_stop, p_stop, "cybersyn-messages.no-train-has-capacity")
end
---@param r_stop LuaEntity
---@param p_stop LuaEntity
function send_alert_no_train_matches_r_layout(r_stop, p_stop)
	send_alert_about_missing_train(r_stop, p_stop, "cybersyn-messages.no-train-matches-r-layout")
end
---@param r_stop LuaEntity
---@param p_stop LuaEntity
function send_alert_no_train_matches_p_layout(r_stop, p_stop)
	send_alert_about_missing_train(r_stop, p_stop, "cybersyn-messages.no-train-matches-p-layout")
end


local send_stuck_train_alert_icon = {name = LOST_TRAIN_NAME, type = "fluid"}
---@param map_data MapData
---@param train LuaTrain
function send_alert_stuck_train(map_data, train)
	send_alert_for_train(train, send_stuck_train_alert_icon, "cybersyn-messages.stuck-train")
	map_data.active_alerts = map_data.active_alerts or {}
	map_data.active_alerts[train.id] = {train, 1, map_data.total_ticks}
end

local send_nonempty_train_in_depot_alert_icon = {name = NONEMPTY_TRAIN_NAME, type = "fluid"}
---@param map_data MapData
---@param train LuaTrain
function send_alert_nonempty_train_in_depot(map_data, train)
	send_alert_for_train(train, send_nonempty_train_in_depot_alert_icon, "cybersyn-messages.nonempty-train")
	send_alert_sounds(train)
	map_data.active_alerts = map_data.active_alerts or {}
	map_data.active_alerts[train.id] = {train, 2, map_data.total_ticks}
end

local send_lost_train_alert_icon = {name = LOST_TRAIN_NAME, type = "fluid"}
---@param map_data MapData
---@param train LuaTrain
function send_alert_depot_of_train_broken(map_data, train)
	send_alert_for_train(train, send_lost_train_alert_icon, "cybersyn-messages.depot-broken")
	send_alert_sounds(train)
	map_data.active_alerts = map_data.active_alerts or {}
	map_data.active_alerts[train.id] = {train, 3, map_data.total_ticks}
end
---@param map_data MapData
---@param train LuaTrain
function send_alert_station_of_train_broken(map_data, train)
	send_alert_for_train(train, send_lost_train_alert_icon, "cybersyn-messages.station-broken")
	send_alert_sounds(train)
	map_data.active_alerts = map_data.active_alerts or {}
	map_data.active_alerts[train.id] = {train, 4, map_data.total_ticks}
end
---@param map_data MapData
---@param train LuaTrain
function send_alert_refueler_of_train_broken(map_data, train)
	send_alert_for_train(train, send_lost_train_alert_icon, "cybersyn-messages.refueler-broken")
	send_alert_sounds(train)
	map_data.active_alerts = map_data.active_alerts or {}
	map_data.active_alerts[train.id] = {train, 5, map_data.total_ticks}
end
---@param map_data MapData
---@param train LuaTrain
function send_alert_train_at_incorrect_station(map_data, train)
	send_alert_for_train(train, send_lost_train_alert_icon, "cybersyn-messages.train-at-incorrect")
	send_alert_sounds(train)
	map_data.active_alerts = map_data.active_alerts or {}
	map_data.active_alerts[train.id] = {train, 6, map_data.total_ticks}
end
---@param map_data MapData
---@param train LuaTrain
function send_alert_cannot_path_between_surfaces(map_data, train)
	send_alert_for_train(train, send_lost_train_alert_icon, "cybersyn-messages.cannot-path-between-surfaces")
	send_alert_sounds(train)
	map_data.active_alerts = map_data.active_alerts or {}
	map_data.active_alerts[train.id] = {train, 7, map_data.total_ticks}
end

---@param train LuaTrain
function send_alert_unexpected_train(train)
	send_alert_for_train(train, send_lost_train_alert_icon, "cybersyn-messages.unexpected-train")
end


---@param map_data MapData
function process_active_alerts(map_data)
	for train_id, data in pairs(map_data.active_alerts) do
		local train = data[1]
		if train.valid then
			local id = data[2]
			if id == 1 then
				send_alert_for_train(train, send_stuck_train_alert_icon, "cybersyn-messages.stuck-train")
			elseif id == 2 then
				--this is an alert that we have to actively check if we can clear
				local is_train_empty = next(train.get_contents()) == nil and next(train.get_fluid_contents()) == nil
				if is_train_empty then
					--NOTE: this function could get confused being called internally, be sure it can handle that
					on_train_changed({train = train})
				else
					send_alert_for_train(train, send_nonempty_train_in_depot_alert_icon, "cybersyn-messages.nonempty-train")
				end
			elseif id == 3 then
				send_alert_for_train(train, send_lost_train_alert_icon, "cybersyn-messages.depot-broken")
			elseif id == 4 then
				send_alert_for_train(train, send_lost_train_alert_icon, "cybersyn-messages.station-broken")
			elseif id == 5 then
				send_alert_for_train(train, send_lost_train_alert_icon, "cybersyn-messages.refueler-broken")
			elseif id == 6 then
				send_alert_for_train(train, send_lost_train_alert_icon, "cybersyn-messages.train-at-incorrect")
			elseif id == 7 then
				send_alert_for_train(train, send_lost_train_alert_icon, "cybersyn-messages.cannot-path-between-surfaces")
			end
		else
			map_data.active_alerts[train_id] = nil
		end
	end
end
