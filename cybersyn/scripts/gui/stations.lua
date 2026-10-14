local gui = require("__flib__.gui")

local constants = require("scripts.gui.constants")
local util = require("scripts.gui.util")
local templates = require("scripts.gui.templates")
local collector = require("scripts.gui.collector")
local dev = require("scripts.gui.dev")

local stations_tab = {}

function stations_tab.create(widths)
	return {
		tab = {
			name = "manager_stations_tab",
			type = "tab",
			caption = { "cybersyn-gui.stations" },
			ref = { "stations", "tab" },
			handler = stations_tab.handle.on_stations_tab_selected,
		},
		content = {
			name = "manager_stations_content_frame",
			type = "frame",
			style = "ltnm_main_content_frame",
			direction = "vertical",
			ref = { "stations", "content_frame" },
			{
				type = "frame",
				style = "ltnm_table_toolbar_frame",
				templates.sort_checkbox(widths, "stations", "name", true, nil, false, stations_tab.handle.on_sort_checkbox_changed),
				templates.sort_checkbox(widths, "stations", "status", false, nil, false, stations_tab.handle.on_sort_checkbox_changed), --repurposed for network signal
				templates.sort_checkbox(widths, "stations", "network_id", false, nil, false, stations_tab.handle.on_sort_checkbox_changed),
				templates.column_label(widths, "stations", "provided_requested"),
				templates.column_label(widths, "stations", "shipments"),
				templates.column_label({ stations = { control_signals = widths.stations.control_signals - 50 } }, "stations", "control_signals"),
			},
			{
				name = "manager_stations_tab_scroll_pane",
				type = "scroll-pane",
				style = "ltnm_table_scroll_pane",
				ref = { "stations", "scroll_pane" }
			},
			templates.pager("stations_tab", util.handle.pager_click),
			{
				type = "flow",
				style = "ltnm_warning_flow",
				visible = false,
				ref = { "stations", "warning_flow" },
				{
					type = "label",
					style = "ltnm_semibold_label",
					caption = { "cybersyn-gui-no-stations" },
					ref = { "stations", "warning_label" },
				},
			},
		},
	}
end

local TAB = "stations_tab"

local sort_keys = {
	name = function(st) return st.name_lower end,
	status = function(st) return st.network_name or "" end,
	network_id = function(st)
		local mask = st.network_mask
		return type(mask) == "number" and mask or 0
	end,
}

--- Filtered and sorted station ids, from the snapshot only.
--- @param player_data PlayerData
--- @return uint[] ids
--- @return Snapshot snapshot
function stations_tab.query(player_data)
	local snapshot = collector.get()
	local f = util.get_filters(player_data)
	local rows = {}
	for _, st in pairs(snapshot.stations) do
		if util.station_passes(st, f) then
			rows[#rows + 1] = st
		end
	end
	local column, ascending = util.get_sort(player_data, TAB, "name")
	local key_fn = sort_keys[column] or sort_keys.name
	util.sort_by(rows, key_fn, ascending, function(st) return st.id end)
	local ids = {}
	for i, st in ipairs(rows) do
		ids[i] = st.id
	end
	return ids, snapshot
end

--- @param map_data MapData
--- @param player_data PlayerData
function stations_tab.build(map_data, player_data)
	local widths = constants.gui["en"]
	local refs = player_data.refs

	local ids, snapshot = stations_tab.query(player_data)
	local first, last = util.paginate(player_data, TAB, #ids)

	local scroll_pane = refs.manager_stations_tab_scroll_pane
	if next(scroll_pane.children) ~= nil then
		scroll_pane.clear()
	end

	for i = first, last do
		local station_id = ids[i]
		local st = snapshot.stations[station_id]
		local network_sprite = "utility/close_black"
		local network_name = st.network_name
		local network_mask = -1
		if network_name then
			local mask = st.network_mask
			network_mask = type(mask) == "number" and mask or (mask[network_name] or 0)
			network_sprite = util.generate_item_references(network_name) or network_sprite
		end
		local color = i % 2 == 0 and "dark" or "light"
		gui.add(scroll_pane, {
			type = "frame",
			tags = { station_id = station_id },
			{
				type = "label",
				style = "ltnm_clickable_semibold_label",
				style_mods = { width = widths.stations.name + 45 },
				tooltip = constants.open_station_gui_tooltip,
				caption = st.name,
				handler = { [defines.events.on_gui_click] = stations_tab.handle.open_station_gui },
				tags = { station_id = station_id },
			},
			{
				type = "sprite",
				style_mods = { width = widths.stations.status - 45, horizontal_align = "center" },
				sprite = network_sprite
			},
			{
				type = "label",
				style_mods = { width = widths.stations.network_id, horizontal_align = "center" },
				caption = network_mask
			},
			templates.small_slot_table(widths.stations, color, "provided_requested"),
			templates.small_slot_table(widths.stations, color, "shipments"),
			templates.small_slot_table(widths.stations, color, "control_signals"),
		}, refs)

		gui.add(refs.provided_requested_table, util.slot_table_build_from_station(st))
		gui.add(refs.shipments_table, util.slot_table_build_from_deliveries(st))
		gui.add(refs.control_signals_table, util.slot_table_build_from_control_signals(st))
	end

	scroll_pane.visible = #ids > 0
end

dev.register_dump(TAB, function(player_data)
	local scroll_pane = player_data.refs.manager_stations_tab_scroll_pane
	local snapshot = collector.get()
	local column, ascending = util.get_sort(player_data, TAB, "name")
	local key_fn = sort_keys[column] or sort_keys.name
	local ids, keys = {}, {}
	for i, row in ipairs(scroll_pane.children) do
		local id = row.tags.station_id
		ids[i] = id
		local st = snapshot.stations[id]
		keys[i] = st and key_fn(st)
	end
	local total = #stations_tab.query(player_data)
	return { ids = ids, keys = keys, column = column, ascending = ascending, page = player_data.page and player_data.page[TAB], total = total }
end)

stations_tab.handle = {}

--- @param e {player_index: uint}
function stations_tab.wrapper(e, handler)
	local player = game.get_player(e.player_index)
	if not player then return end
	local player_data = storage.manager.players[e.player_index]
	handler(player, player_data, player_data.refs, e)
end

--- @param e GuiEventData
--- @param player LuaPlayer
--- @param player_data PlayerData
function stations_tab.handle.open_station_gui(player, player_data, refs, e)
	local station_id = e.element.tags.station_id
	--- @type Station
	local station = storage.stations[station_id]
	if not station then
		util.error_flying_text(player, { "cybersyn-message.error-station-is-invalid" })
		return
	end
	local station_entity = station.entity_stop
	local station_comb1 = station.entity_comb1
	local station_comb2 = station.entity_comb2

	if not station_entity or not station_entity.valid then
		util.error_flying_text(player, { "message.ltnm-error-station-is-invalid" })
		return
	end

	if e.shift then
		player.centered_on = station_entity

		rendering.draw_circle({
			color = constants.colors.red.tbl,
			target = station_entity.position,
			surface = station_entity.surface,
			radius = 0.5,
			filled = false,
			width = 5,
			time_to_live = 60 * 3,
			players = { player },
		})

		if not player_data.pinning then util.close_manager_window(player, player_data, refs) end
	elseif e.control then
		if station_comb1 ~= nil and station_comb1.valid then
			player.opened = station_comb1
		else
			util.error_flying_text(player, { "cybersyn-message.error-cybernetic-combinator-not-found" })
		end
	elseif e.alt then
		if station_comb2 ~= nil and station_comb2.valid then
			player.opened = station_comb2
		else
			util.error_flying_text(player, { "cybersyn-message.error-station-control-combinator-not-found" })
		end
	else
		player.opened = station_entity
	end
end

---@param player LuaPlayer
---@param player_data PlayerData
function stations_tab.handle.on_stations_tab_selected(player, player_data)
	player_data.selected_tab = "stations_tab"
end

---@param player LuaPlayer
---@param player_data PlayerData
---@param refs table<string, LuaGuiElement>
---@param e EventData.on_gui_checked_state_changed
function stations_tab.handle.on_sort_checkbox_changed(player, player_data, refs, e)
	local element = e.element
	if not element or not element.tags then return end
	local column = element.tags.column
	if not column then return end

	util.set_sort(player_data, TAB, column)
	local active, ascending = util.get_sort(player_data, TAB, "name")
	util.sync_sort_header(element.parent, active, ascending)
	util.rerender(player, player_data)
end

gui.add_handlers(stations_tab.handle, stations_tab.wrapper)

return stations_tab
