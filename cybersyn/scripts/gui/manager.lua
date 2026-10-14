local gui = require("__flib__.gui")

local constants = require("scripts.gui.constants")

local templates = require("scripts.gui.templates")

local overview_tab = require("scripts.gui.overview")
local stations_tab = require("scripts.gui.stations")
local trains_tab = require("scripts.gui.trains")
local inventory_tab = require("scripts.gui.inventory")
local utilization_tab = require("scripts.gui.utilization")
local delivery_breakdown_tab = require("scripts.gui.delivery-breakdown")
local util = require("scripts.gui.util")
local collector = require("scripts.gui.collector")
local analytics = require("scripts.analytics")

local manager = {}

local DEFAULT_TAB = "overview_tab"

local function frame_toggle(name, sprite, tooltip, handler)
	local def = templates.frame_action_button(name, sprite, tooltip, nil)
	def.handler = { [defines.events.on_gui_click] = handler }
	return def
end

--- @param player LuaPlayer
function manager.create(player)
	local widths = constants.gui["en"]
	---@type table<string, LuaGuiElement>
	local refs = {}

	gui.add(player.gui.screen, {
		{
			name = "manager_window",
			type = "frame",
			direction = "vertical",
			visible = false,
			children = {
				{
					name = "manager_titlebar",
					type = "flow",
					style = "flib_titlebar_flow",
					handler = manager.handle.manager_titlebar_click,
					children = {
						{ type = "label", style = "frame_title", caption = { "mod-name.cybersyn" }, ignored_by_interaction = true },
						{ type = "empty-widget", style = "flib_titlebar_drag_handle", ignored_by_interaction = true },
						{
							name = "manager_dispatcher_status_label",
							type = "label",
							style = "bold_label",
							style_mods = { font_color = constants.colors.red.tbl, left_margin = -4, top_margin = 1 },
							caption = { "cybersyn-gui.dispatcher-disabled" },
							tooltip = { "cybersyn-gui.dispatcher-disabled-description" },
							visible = not settings.global["cybersyn-enable-planner"].value,
						},
						{
							name = "manager_updated_label",
							type = "label",
							style_mods = { top_margin = 1, right_margin = 4 },
							tooltip = { "cybersyn-gui.updated-tooltip" },
						},
						{
							name = "cybersyn_recent_items_flow",
							type = "flow",
							direction = "horizontal",
							style_mods = { horizontal_spacing = 2 },
						},
						frame_toggle("manager_pause_button", "utility/pause", { "cybersyn-gui.pause-tooltip" }, manager.handle.manager_toggle_pause),
						frame_toggle("manager_pin_button", "ltnm_pin_white", { "cybersyn-gui.pin-tooltip" }, manager.handle.manager_toggle_pinned),
						frame_toggle(nil, "utility/close", { "gui.close-instruction" }, manager.handle.manager_close),
					},
				},
				{
					type = "frame",
					style = "inside_deep_frame",
					direction = "vertical",
					children = {
						{
							type = "frame",
							style = "ltnm_main_toolbar_frame",
							children = {
								{ type = "label", style = "subheader_caption_label", caption = { "cybersyn-gui.search-label" } },
								{
									name = "manager_text_search_field",
									type = "textfield",
									clear_and_focus_on_right_click = true,
									tooltip = { "cybersyn-gui.search-tooltip" },
									handler = { [defines.events.on_gui_text_changed] = manager.handle.manager_update_text_search },
								},
								{ type = "label", name = "manager_item_filter_label", style = "subheader_caption_label", caption = { "cybersyn-gui.search-item-label" } },
								{
									type = "choose-elem-button",
									name = "manager_item_filter",
									elem_type = "signal",
									handler = { [defines.events.on_gui_elem_changed] = manager.handle.manager_update_item_search },
								},
								{ type = "empty-widget", style = "flib_horizontal_pusher" },
								{ type = "label", style = "caption_label", caption = { "cybersyn-gui.network-name-label" } },
								{
									type = "choose-elem-button",
									name = "network",
									elem_type = "signal",
									tooltip = { "cybersyn-gui.network-tooltip" },
									handler = { [defines.events.on_gui_elem_changed] = manager.handle.manager_update_network_name },
								},
								{ type = "label", style = "caption_label", caption = { "cybersyn-gui.network-id-label" } },
								{
									name = "manager_network_mask_field",
									type = "textfield",
									style_mods = { width = 120 },
									numeric = true,
									allow_negative = true,
									clear_and_focus_on_right_click = true,
									text = "-1",
									handler = { [defines.events.on_gui_text_changed] = manager.handle.manager_update_network_mask },
								},
								{ type = "label", style = "caption_label", caption = { "cybersyn-gui.surface-label" } },
								{
									name = "manager_surface_dropdown",
									type = "drop-down",
									handler = { [defines.events.on_gui_selection_state_changed] = manager.handle.manager_update_surface },
								},
								{
									name = "manager_clear_filters_button",
									type = "sprite-button",
									style = "tool_button",
									sprite = "utility/reset",
									tooltip = { "cybersyn-gui.clear-filters-tooltip" },
									handler = { [defines.events.on_gui_click] = manager.handle.manager_clear_filters },
								},
							},
						},
						{
							name = "manager_tabbed_pane",
							type = "tabbed-pane",
							style = "ltnm_tabbed_pane",
							handler = { [defines.events.on_gui_selected_tab_changed] = manager.handle.manager_tab_changed },
							overview_tab.create(),
							inventory_tab.create(),
							stations_tab.create(widths),
							trains_tab.create(widths),
							analytics.is_enabled() and utilization_tab.create() or nil,
							analytics.is_enabled() and delivery_breakdown_tab.create() or nil,
						},
					},
				},
			},
		},
	}, refs)

	refs.manager_titlebar.drag_target = refs.manager_window
	refs.manager_tabbed_pane.selected_tab_index = 1
	refs.manager_window.force_auto_center()

	return refs
end

local function set_frame_toggle(elem, selected)
	if elem and elem.valid then
		elem.style = selected and "flib_selected_frame_action_button" or "frame_action_button"
	end
end

--- @param player_data PlayerData
function manager.refresh_toggles(player_data)
	local refs = player_data.refs
	local pause = refs.manager_pause_button
	if pause and pause.valid then
		set_frame_toggle(pause, player_data.paused)
		local sprite = player_data.paused and "utility/play" or "utility/pause"
		pause.sprite = sprite
		pause.hovered_sprite = sprite
		pause.clicked_sprite = sprite
		pause.tooltip = player_data.paused and { "cybersyn-gui.resume-tooltip" } or { "cybersyn-gui.pause-tooltip" }
	end
	local pin = refs.manager_pin_button
	if pin and pin.valid then
		set_frame_toggle(pin, player_data.pinning)
		local sprite = player_data.pinning and "ltnm_pin_black" or "ltnm_pin_white"
		pin.sprite = sprite
		pin.hovered_sprite = sprite
		pin.clicked_sprite = sprite
	end
end

--- Refreshes the "Updated Ns ago" label; cheap enough to run every manager update, paused or not.
--- @param player_data PlayerData
function manager.update_status(player_data)
	local label = player_data.refs.manager_updated_label
	if not label or not label.valid then return end
	-- The caption tracks renders; the snapshot age cycles through a whole collector pass even while the window
	-- refreshes every second, so it only goes in the tooltip.
	local render_tick = player_data.last_update_tick
	local age = render_tick and util.format_duration(game.tick - render_tick) or "-"
	local data_tick = player_data.rendered_snapshot_tick
	local data_age = data_tick and util.format_duration(game.tick - data_tick) or "-"
	label.tooltip = { "", { "cybersyn-gui.updated-tooltip" }, "\n", { "cybersyn-gui.data-age", data_age } }
	local caption
	if player_data.paused then
		caption = { "", "[color=yellow]", { "cybersyn-gui.paused-updated-ago", age }, "[/color]" }
	else
		caption = { "cybersyn-gui.updated-ago", age }
		local hover = player_data.hover
		if hover and util.hold_active(player_data, hover.scope) then
			local state = player_data.gui_state and player_data.gui_state[hover.scope]
			if state and state.dirty then
				caption = { "", caption, " ", { "cybersyn-gui.layout-held" } }
			end
		end
	end
	label.caption = caption
end

--- Rebuilds the surface drop-down; only on open and when the number of surfaces changes.
--- @param player_data PlayerData
function manager.rebuild_surface_dropdown(player_data)
	local dropdown = player_data.refs.manager_surface_dropdown
	if not dropdown or not dropdown.valid then return end
	local surfaces = {}
	for _, surface in pairs(game.surfaces) do
		surfaces[#surfaces + 1] = surface
	end
	table.sort(surfaces, function(a, b) return a.index < b.index end)

	local items = { { "cybersyn-gui.all-surfaces" } }
	local ids = {}
	local selected = 1
	if player_data.search_surface_idx and not game.get_surface(player_data.search_surface_idx) then
		player_data.search_surface_idx = nil
	end
	for i, surface in ipairs(surfaces) do
		items[i + 1] = surface.localised_name or surface.name
		ids[i + 1] = surface.index
		if surface.index == player_data.search_surface_idx then
			selected = i + 1
		end
	end
	dropdown.items = items
	dropdown.selected_index = selected
	player_data.surface_dropdown_ids = ids
	player_data.surface_count = #game.surfaces
end

--- Writes the stored filters into the toolbar widgets; done once on open instead of every update.
--- @param player_data PlayerData
function manager.restore_filter_widgets(player_data)
	local refs = player_data.refs
	if player_data.search_item and not util.signal_hash_valid(player_data.search_item) then
		player_data.search_item = nil
	end
	if player_data.search_network_name and not util.signal_hash_valid(player_data.search_network_name) then
		player_data.search_network_name = nil
	end
	refs.manager_text_search_field.text = player_data.search_query or ""
	refs.manager_item_filter.elem_value = player_data.search_item and util.signalid_from_hash(player_data.search_item) or nil
	refs.network.elem_value = player_data.search_network_name and util.signalid_from_name(player_data.search_network_name) or nil
	refs.manager_network_mask_field.text = tostring(player_data.search_network_mask or -1)
	manager.rebuild_surface_dropdown(player_data)
end

local sort_headers = {
	stations_tab = { scroll_pane = "manager_stations_tab_scroll_pane", default = "name" },
	trains_tab = { scroll_pane = "manager_trains_tab_scroll_pane", default = "train_id" },
}

--- Restores the sort header state from player_data.sort, which survives window rebuilds the headers do not.
--- @param player_data PlayerData
function manager.refresh_sort_headers(player_data)
	local refs = player_data.refs
	for tab, header in pairs(sort_headers) do
		local pane = refs[header.scroll_pane]
		if pane and pane.valid then
			local column, ascending = util.get_sort(player_data, tab, header.default)
			util.sync_sort_header(pane.parent.children[1], column, ascending)
		end
	end
end

local tab_builders = {
	overview_tab = overview_tab,
	inventory_tab = inventory_tab,
	stations_tab = stations_tab,
	trains_tab = trains_tab,
	utilization_tab = utilization_tab,
	delivery_breakdown_tab = delivery_breakdown_tab,
}

--- @param map_data MapData
--- @param player_data PlayerData
function manager.update(map_data, player_data)
	local previous_tab = player_data.previous_tab
	local current_tab = player_data.selected_tab
	if previous_tab ~= current_tab then
		if previous_tab == "utilization_tab" then
			utilization_tab.cleanup(map_data, player_data)
		elseif previous_tab == "delivery_breakdown_tab" then
			delivery_breakdown_tab.cleanup(map_data, player_data)
		elseif previous_tab == "inventory_tab" then
			-- Coming back must show current totals at once, not a refresh spread over the next renders.
			player_data.inventory_cache = nil
		end
		player_data.previous_tab = current_tab
	end

	local builder = tab_builders[current_tab]
	if builder then
		builder.build(map_data, player_data)
	end
end

--- Renders the selected tab from the current snapshot and refreshes the status label.
--- @param player LuaPlayer?
--- @param player_data PlayerData
function manager.render(player, player_data)
	if not player_data.is_manager_open then return end
	manager.update(storage, player_data)
	player_data.last_update_tick = game.tick
	player_data.rendered_snapshot_tick = collector.get().tick
	manager.update_status(player_data)
end

util.set_rerender(manager.render)

manager.handle = {}

--- @param e {player_index: uint}
function manager.wrapper(e, handler)
	local player = game.get_player(e.player_index)
	if not player then return end
	local player_data = storage.manager.players[e.player_index]
	handler(player, player_data, player_data.refs, e)
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.handle.manager_open(player, player_data, refs)
	-- A window built by an older version of this file survives a script update that has no version bump.
	if not (refs.manager_updated_label and refs.manager_updated_label.valid) then
		if refs.manager_window and refs.manager_window.valid then
			refs.manager_window.destroy()
		end
		refs = manager.create(player)
		player_data.refs = refs
		player_data.gui_state = {}
	end
	refs.manager_window.bring_to_front()
	refs.manager_window.visible = true
	player_data.visible = true

	if not player_data.pinning then
		player.opened = refs.manager_window
	end

	player_data.is_manager_open = true
	player.set_shortcut_toggled("cybersyn-toggle-gui", true)

	player_data.page_size = nil
	player_data.hover = nil
	manager.restore_filter_widgets(player_data)
	manager.refresh_toggles(player_data)
	manager.refresh_sort_headers(player_data)
	if not util.select_tab(player_data, player_data.selected_tab or DEFAULT_TAB) then
		util.select_tab(player_data, DEFAULT_TAB)
	end

	manager.build_recent_panel(player, player_data)

	collector.ensure_fresh()
	manager.render(player, player_data)

	local analytics_setting = settings.global["cybersyn-enable-analytics"]
	if analytics_setting and analytics_setting.value and not analytics.is_library_available() then
		player.print({ "cybersyn-gui.analytics-library-missing" })
	end
end

--- Close button and toggle shortcut: closes even when pinned.
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.handle.manager_close(player, player_data, refs)
	if player_data.selected_tab == "utilization_tab" then
		utilization_tab.cleanup(storage, player_data)
	elseif player_data.selected_tab == "delivery_breakdown_tab" then
		delivery_breakdown_tab.cleanup(storage, player_data)
	end
	-- Cleanup above runs again on reopen otherwise.
	player_data.previous_tab = nil
	util.close_manager_window(player, player_data, refs, true)
end

--- on_gui_closed (Escape / E): a pinned window ignores it.
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.handle.manager_closed_by_game(player, player_data, refs)
	if player_data.pinning or not player_data.is_manager_open then return end
	manager.handle.manager_close(player, player_data, refs)
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.handle.manager_toggle(player, player_data, refs)
	if player_data.is_manager_open then
		manager.handle.manager_close(player, player_data, refs)
	else
		manager.handle.manager_open(player, player_data, refs)
	end
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.handle.manager_titlebar_click(player, player_data, refs, e)
	if e.name == defines.events.on_gui_click and e.button == defines.mouse_button_type.middle then
		refs.manager_window.force_auto_center()
	end
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.handle.manager_toggle_pause(player, player_data, refs)
	player_data.paused = not player_data.paused
	manager.refresh_toggles(player_data)
	if player_data.paused then
		manager.update_status(player_data)
	else
		manager.render(player, player_data)
	end
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.handle.manager_toggle_pinned(player, player_data, refs)
	player_data.pinning = not player_data.pinning
	manager.refresh_toggles(player_data)
	if not player_data.is_manager_open then return end
	if player_data.pinning then
		-- Releasing player.opened raises on_gui_closed, which a pinned window ignores.
		if player.opened == refs.manager_window then
			player.opened = nil
		end
	else
		player.opened = refs.manager_window
	end
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.handle.manager_clear_filters(player, player_data, refs)
	util.set_search_query(player_data, nil)
	player_data.search_item = nil
	player_data.search_network_name = nil
	player_data.search_network_mask = -1
	player_data.search_surface_idx = nil
	player_data.stations_status_filter = nil
	util.reset_pages(player_data)
	manager.restore_filter_widgets(player_data)
	manager.render(player, player_data)
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
--- @param e EventData.on_gui_text_changed
function manager.handle.manager_update_text_search(player, player_data, refs, e)
	util.set_search_query(player_data, e.text)
	util.reset_pages(player_data)
	manager.render(player, player_data)
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
--- @param e EventData.on_gui_elem_changed
function manager.handle.manager_update_item_search(player, player_data, refs, e)
	local element = e.element
	if not element then return end
	local signal = element.elem_value --[[@as SignalID?]]
	if signal and signal.name then
		player_data.search_item = hash_signal(signal)
		interface_raise_item_selected(e.player_index, signal.name)
		interop_add_recent_item(e.player_index, signal.name, "cybersyn")
		player_data.recent_panel_dirty = true
	else
		player_data.search_item = nil
	end
	util.reset_pages(player_data)
	manager.render(player, player_data)
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
--- @param e EventData.on_gui_elem_changed
function manager.handle.manager_update_network_name(player, player_data, refs, e)
	local element = e.element
	if not element then return end
	local signal = element.elem_value --[[@as SignalID?]]
	player_data.search_network_name = signal and signal.name or nil
	util.reset_pages(player_data)
	manager.render(player, player_data)
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
--- @param e EventData.on_gui_text_changed
function manager.handle.manager_update_network_mask(player, player_data, refs, e)
	player_data.search_network_mask = tonumber(e.text) or -1
	util.reset_pages(player_data)
	manager.render(player, player_data)
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
--- @param e EventData.on_gui_selection_state_changed
function manager.handle.manager_update_surface(player, player_data, refs, e)
	local element = e.element
	if not element then return end
	local ids = player_data.surface_dropdown_ids or {}
	local surface_index = ids[element.selected_index]
	if surface_index and not game.get_surface(surface_index) then
		surface_index = nil
	end
	player_data.search_surface_idx = surface_index
	util.reset_pages(player_data)
	manager.render(player, player_data)
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
--- @param e EventData.on_gui_selected_tab_changed
function manager.handle.manager_tab_changed(player, player_data, refs, e)
	local pane = e.element
	local tab = pane.tabs[pane.selected_tab_index]
	if not tab then return end
	local name = string.match(tab.tab.name, "^manager_(.+)$")
	if name then
		player_data.selected_tab = name
		manager.render(player, player_data)
	end
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
--- @param e GuiEventData
function manager.handle.recent_item_click(player, player_data, refs, e)
	local element = e.element
	if not element then return end
	local tags = element.tags
	if tags and tags.item_name then
		util.item_button_click(player, player_data, e, tags.item_name)
	end
end

--- Update the recent items buttons in the titlebar.
--- @param player LuaPlayer
--- @param player_data PlayerData
function manager.build_recent_panel(player, player_data)
	local flow = player_data.refs.cybersyn_recent_items_flow
	if not flow then return end

	flow.clear()

	local items = storage.recent_external_items and storage.recent_external_items[player.index]
	if not items or #items == 0 then return end

	for i, entry in ipairs(items) do
		local sprite_path
		if prototypes.item[entry.item_name] then
			sprite_path = "item/" .. entry.item_name
		elseif prototypes.fluid[entry.item_name] then
			sprite_path = "fluid/" .. entry.item_name
		end

		if sprite_path then
			local proto = prototypes.item[entry.item_name] or prototypes.fluid[entry.item_name]
			local tooltip = { "", proto and proto.localised_name or entry.item_name, "\n", { "cybersyn-gui.item-click-hint" } }
			gui.add(flow, {
				{
					type = "sprite-button",
					sprite = sprite_path,
					tooltip = tooltip,
					style = "frame_action_button",
					tags = { item_name = entry.item_name },
					mouse_button_filter = { "left", "right" },
					handler = { [defines.events.on_gui_click] = manager.handle.recent_item_click },
				},
			})
		end
	end
end

gui.add_handlers(manager.handle, manager.wrapper)

return manager
