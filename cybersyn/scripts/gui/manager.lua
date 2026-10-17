local gui = require("__flib__.gui")

local constants = require("scripts.gui.constants")

local templates = require("scripts.gui.templates")

local overview_tab = require("scripts.gui.overview")
local stations_tab = require("scripts.gui.stations")
local trains_tab = require("scripts.gui.trains")
local inventory_tab = require("scripts.gui.inventory")
local log_tab = require("scripts.gui.log")
local utilization_tab = require("scripts.gui.utilization")
local delivery_breakdown_tab = require("scripts.gui.delivery-breakdown")
local problems_tab = require("scripts.gui.problems")
local item = require("scripts.gui.item")
local explain = require("scripts.gui.explain")
local util = require("scripts.gui.util")
local collector = require("scripts.gui.collector")
local analytics = require("scripts.analytics")
local sizing = require("scripts.gui.sizing")

local manager = {}

local DEFAULT_TAB = "overview_tab"
-- Tabs whose content gets the banner and subheader, in pane order.
local HEADER_TABS = { "overview_tab", "inventory_tab", "stations_tab", "trains_tab", "problems_tab", "log_tab",
	"utilization_tab", "delivery_breakdown_tab" }
-- Tabs that ignore the item filter, so they never show its chip (the Problems tab lists every finding).
local NO_ITEM_CHIP = { problems_tab = true }
-- Tabs the station-name search applies to.
local SEARCH_TABS = { inventory_tab = true, stations_tab = true, trains_tab = true }
-- The last render must be this old before the title bar says how old it is.
local STALE_TICKS = 180

local function set_frame_toggle(elem, selected)
	if elem and elem.valid then
		elem.style = selected and "flib_selected_frame_action_button" or "frame_action_button"
	end
end

local function frame_toggle(name, sprite, tooltip, handler)
	local def = templates.frame_action_button(name, sprite, tooltip, nil)
	def.handler = { [defines.events.on_gui_click] = handler }
	return def
end

--- @param def {content: flib.GuiElemDef}
--- @param tab string
--- @param handlers table
--- @param right flib.GuiElemDef[]?
local function add_header(def, tab, handlers, right)
	local banner, subheader = templates.tab_header(tab, handlers, right, SEARCH_TABS[tab] == true)
	local content = def.content
	local children = content.children or content
	table.insert(children, 1, subheader)
	table.insert(children, 1, banner)
	return def
end

--- @param player LuaPlayer
function manager.create(player)
	local widths = constants.gui["en"]
	---@type table<string, LuaGuiElement>
	local refs = {}
	local header = {
		search_changed = manager.handle.manager_search_changed,
		search_click = manager.handle.manager_search_click,
		search_confirmed = manager.handle.manager_search_confirmed,
		chip_click = manager.handle.manager_chip_click,
	}
	local tabs = {
		add_header(overview_tab.create(), "overview_tab", header, overview_tab.subheader_right()),
		add_header(inventory_tab.create(), "inventory_tab", header),
		add_header(stations_tab.create(widths), "stations_tab", header),
		add_header(trains_tab.create(widths), "trains_tab", header),
		add_header(problems_tab.create(), "problems_tab", header, problems_tab.subheader_right()),
		add_header(log_tab.create(), "log_tab", header, log_tab.subheader_right()),
	}
	if analytics.setting_enabled() then
		tabs[#tabs + 1] = add_header(utilization_tab.create(), "utilization_tab", header)
	end
	if analytics.is_enabled() then
		tabs[#tabs + 1] = add_header(delivery_breakdown_tab.create(), "delivery_breakdown_tab", header)
	end
	local pane = {
		name = "manager_tabbed_pane",
		type = "tabbed-pane",
		style = "ltnm_tabbed_pane",
		handler = { [defines.events.on_gui_selected_tab_changed] = manager.handle.manager_tab_changed },
	}
	for i, t in ipairs(tabs) do pane[i] = t end

	gui.add(player.gui.screen, {
		{
			name = "manager_window",
			type = "frame",
			direction = "vertical",
			visible = false,
			handler = { [defines.events.on_gui_location_changed] = manager.handle.manager_location_changed },
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
							name = "manager_updated_label",
							type = "label",
							visible = false,
							style_mods = { top_margin = 1, right_margin = 4 },
							tooltip = { "cybersyn-gui.updated-tooltip" },
						},
						{
							type = "sprite-button",
							name = "manager_back_button",
							style = "frame_action_button",
							sprite = "flib_nav_backward_white",
							hovered_sprite = "flib_nav_backward_black",
							clicked_sprite = "flib_nav_backward_black",
							visible = false,
							tooltip = { "cybersyn-gui.back-from-map-tooltip" },
							handler = { [defines.events.on_gui_click] = manager.handle.manager_back },
						},
						frame_toggle("manager_search_button", "utility/search", { "cybersyn-gui.search-button-tooltip" }, manager.handle.manager_toggle_search),
						frame_toggle("manager_filter_button", "cybersyn_filter_white", { "cybersyn-gui.filter-button-tooltip" }, manager.handle.manager_toggle_filter_row),
						frame_toggle("manager_pause_button", "cybersyn_pause_white", { "cybersyn-gui.pause-tooltip" }, manager.handle.manager_toggle_pause),
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
							name = "manager_filter_row",
							type = "frame",
							style = "cybersyn_filter_row",
							visible = false,
							children = {
								{ type = "label", style = "subheader_caption_label", caption = { "cybersyn-gui.search-item-label" } },
								{
									type = "choose-elem-button",
									name = "manager_item_filter",
									elem_type = "signal",
									style = "slot_button_in_shallow_frame",
									style_mods = { size = 28 },
									handler = { [defines.events.on_gui_elem_changed] = manager.handle.manager_update_item_search },
								},
								{ type = "label", style = "subheader_caption_label", caption = { "cybersyn-gui.network-name-label" } },
								{
									type = "choose-elem-button",
									name = "network",
									elem_type = "signal",
									style = "slot_button_in_shallow_frame",
									style_mods = { size = 28 },
									tooltip = { "cybersyn-gui.network-tooltip" },
									handler = { [defines.events.on_gui_elem_changed] = manager.handle.manager_update_network_name },
								},
								{ type = "label", style = "subheader_caption_label", caption = { "cybersyn-gui.network-id-label" } },
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
								{ type = "label", name = "manager_surface_label", style = "subheader_caption_label", caption = { "cybersyn-gui.surface-label" } },
								{
									name = "manager_surface_dropdown",
									type = "drop-down",
									handler = { [defines.events.on_gui_selection_state_changed] = manager.handle.manager_update_surface },
								},
								{ type = "empty-widget", style = "flib_horizontal_pusher" },
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
						pane,
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

-- ---------------------------------------------------------------- layout (PLAN3 §4.3)

--- @return boolean
function manager.dispatch_paused()
	return settings.global["cybersyn-enable-planner"].value == false
end

--- Network, network id and surface live only in the filter row; while one is set the row stays open.
--- @param player_data PlayerData
--- @return boolean
local function row_filters_active(player_data)
	return player_data.search_network_name ~= nil or (player_data.search_network_mask or -1) ~= -1
		or player_data.search_surface_idx ~= nil
end

--- @param player_data PlayerData
--- @return boolean
function manager.filter_row_shown(player_data)
	return player_data.filter_row_open == true or row_filters_active(player_data)
end

--- The window size for this player's screen (or the screen dev.set_layout emulates); stored in player_data.layout.
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @return ManagerLayout
function manager.layout(player, player_data)
	local o = player_data.layout_override
	local res_w, res_h, scale
	if o then
		res_w, res_h, scale = o.width, o.height, o.scale
	else
		local res = player.display_resolution
		res_w, res_h, scale = res.width, res.height, player.display_scale
	end
	local layout = sizing.compute(res_w, res_h, scale, manager.filter_row_shown(player_data), manager.dispatch_paused())
	layout.res_width, layout.res_height, layout.scale = res_w, res_h, scale
	player_data.layout = layout
	return layout
end

local CONTENT_FRAMES = {
	overview_tab = "manager_overview_content_frame",
	inventory_tab = "manager_inventory_content_frame",
	stations_tab = "manager_stations_content_frame",
	trains_tab = "manager_trains_tab_content_frame",
	problems_tab = "manager_problems_content_frame",
	log_tab = "manager_log_content_frame",
}

--- Writes the layout into the window: its width, every tab's height and the per-tab row areas.
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @return ManagerLayout
function manager.apply_layout(player, player_data)
	local layout = manager.layout(player, player_data)
	local refs = player_data.refs
	local window = refs.manager_window
	if not (window and window.valid) then return layout end
	window.style.width = layout.width
	local height = layout.content_height + (manager.dispatch_paused() and sizing.BANNER_HEIGHT or 0)
	for _, name in pairs(CONTENT_FRAMES) do
		local content = refs[name]
		if content and content.valid then
			content.style.height = height
			content.style.width = layout.content_width
		end
	end
	overview_tab.apply_layout(player_data, layout)
	inventory_tab.apply_layout(player_data, layout)
	problems_tab.apply_layout(player_data, layout)
	log_tab.apply_layout(player_data, layout)
	item.apply_layout(player_data, layout)
	return layout
end

--- Restores the stored position, or centres the window when there is none or it would be off the screen.
--- @param player LuaPlayer
--- @param player_data PlayerData
function manager.place_window(player, player_data)
	local window = player_data.refs.manager_window
	if not (window and window.valid) then return end
	local res = player.display_resolution
	local layout = player_data.layout
	local scale = player.display_scale
	local width_px = (layout and layout.width or sizing.MAX_WIDTH) * scale
	local height_px = (layout and layout.window_height or 0) * scale
	local loc = sizing.fit_location(player_data.location, res.width, res.height, width_px, height_px)
	if loc then
		player_data.location = loc
		window.location = loc
	else
		player_data.location = nil
		window.force_auto_center()
	end
end

--- The resolution or UI scale changed, or the window was rebuilt: size it again and check its position.
--- @param player LuaPlayer
--- @param player_data PlayerData
function manager.relayout(player, player_data)
	local refs = player_data.refs
	if not (refs and refs.manager_window and refs.manager_window.valid) then return end
	manager.apply_layout(player, player_data)
	-- A hidden window is placed when it opens; centring it now would use a stale size.
	if player_data.is_manager_open then
		manager.place_window(player, player_data)
		manager.render(player, player_data)
	end
end

-- ---------------------------------------------------------------- strips: banner, search, chip, filter row

--- @param player_data PlayerData
function manager.refresh_banners(player_data)
	local refs = player_data.refs
	local paused = manager.dispatch_paused()
	local caption
	if paused then
		local by = storage.manager.paused_by
		local who = by and by > 0 and game.get_player(by)
		caption = who and { "cybersyn-gui.dispatch-paused-by", who.name } or { "cybersyn-gui.dispatch-paused" }
	end
	for _, tab in ipairs(HEADER_TABS) do
		local banner = refs[tab .. "_banner"]
		if banner and banner.valid then
			banner.visible = paused
			if paused then
				local label = refs[tab .. "_banner_label"]
				label.caption = caption
				label.tooltip = { "cybersyn-gui.dispatch-paused-tooltip" }
			end
		end
	end
end

--- @param player_data PlayerData
--- @return boolean
local function search_shown(player_data)
	return player_data.search_open == true or player_data.search_query ~= nil
end

--- @param player_data PlayerData
function manager.refresh_search_fields(player_data)
	local refs = player_data.refs
	local shown = search_shown(player_data)
	local text = player_data.search_query or ""
	for tab in pairs(SEARCH_TABS) do
		local field = refs[tab .. "_search_field"]
		if field and field.valid then
			if field.visible ~= shown then field.visible = shown end
			if field.text ~= text then field.text = text end
		end
	end
	set_frame_toggle(refs.manager_search_button, shown)
end

--- @param player_data PlayerData
function manager.refresh_chips(player_data)
	local refs = player_data.refs
	local hash = player_data.search_item
	if hash and not util.signal_hash_valid(hash) then hash = nil end
	local sig = hash or ""
	if player_data.chip_sig == sig then return end
	player_data.chip_sig = sig
	local sprite, quality, name_tooltip = nil, nil, nil
	if hash then sprite, quality, name_tooltip = util.item_sprite_and_tooltip(hash) end
	local shown = sprite ~= nil
	for _, tab in ipairs(HEADER_TABS) do
		local flow = not NO_ITEM_CHIP[tab] and refs[tab .. "_chip_flow"]
		if flow and flow.valid then
			flow.visible = shown
			if shown then
				local tooltip = tab == "overview_tab" and { "cybersyn-gui.filter-chip-overview-tooltip" } or { "cybersyn-gui.filter-chip-tooltip" }
				local icon = refs[tab .. "_chip_icon"]
				icon.sprite = sprite
				icon.quality = quality
				icon.elem_tooltip = util.elem_tooltip(hash)
				icon.tooltip = tooltip
				local chip = refs[tab .. "_chip"]
				chip.caption = { "cybersyn-gui.filter-chip", name_tooltip[4] or hash }
				chip.tooltip = tooltip
			end
		end
	end
end

--- @param player_data PlayerData
--- @return boolean
local function any_filter(player_data)
	return row_filters_active(player_data) or player_data.search_item ~= nil
end

--- Shows or hides the filter row; a change of its visibility changes the rows that fit.
--- @param player LuaPlayer
--- @param player_data PlayerData
function manager.refresh_filter_row(player, player_data)
	local refs = player_data.refs
	local row = refs.manager_filter_row
	if not (row and row.valid) then return end
	local shown = manager.filter_row_shown(player_data)
	local multi = #game.surfaces > 1
	if refs.manager_surface_label.visible ~= multi then
		refs.manager_surface_label.visible = multi
		refs.manager_surface_dropdown.visible = multi
	end
	set_frame_toggle(refs.manager_filter_button, any_filter(player_data))
	if row.visible ~= shown then
		row.visible = shown
		manager.apply_layout(player, player_data)
	end
end

--- @param player_data PlayerData
function manager.refresh_toggles(player_data)
	local refs = player_data.refs
	local pause = refs.manager_pause_button
	if pause and pause.valid then
		set_frame_toggle(pause, player_data.paused)
		local sprite = player_data.paused and "utility/play" or "cybersyn_pause_white"
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
	local back = refs.manager_back_button
	if back and back.valid then back.visible = player_data.auto_pinned == true end
end

util.set_refresh_toggles(manager.refresh_toggles)

--- The title-bar age (only once the last render is STALE_TICKS old, or while paused) and the subheaders'
--- "Collecting… n %"; cheap enough to run every manager update, paused or not.
--- @param player_data PlayerData
function manager.update_status(player_data)
	local refs = player_data.refs
	local label = refs.manager_updated_label
	if not label or not label.valid then return end
	-- The caption tracks renders; the snapshot age cycles through a whole collector pass even while the window
	-- refreshes every second, so it only goes in the tooltip.
	local render_tick = player_data.last_update_tick
	local data_tick = player_data.rendered_snapshot_tick
	local stale = player_data.paused or not render_tick or game.tick - render_tick > STALE_TICKS
	if label.visible ~= stale then label.visible = stale end
	-- Hidden while renders are recent (nearly always): nothing to write then. Shown, written when its text changed.
	if stale then
		local age = render_tick and util.format_duration(game.tick - render_tick) or "-"
		local data_age = data_tick and util.format_duration(game.tick - data_tick) or "-"
		local held = false
		local hover = player_data.hover
		if not player_data.paused and hover and util.hold_active(player_data, hover.scope) then
			local state = player_data.gui_state and player_data.gui_state[hover.scope]
			held = state ~= nil and state.dirty == true
		end
		local sig = age .. "|" .. data_age .. "|" .. (player_data.paused and "p" or "") .. (held and "h" or "")
		if player_data.status_sig ~= sig then
			player_data.status_sig = sig
			label.tooltip = { "", { "cybersyn-gui.updated-tooltip" }, "\n", { "cybersyn-gui.data-age", data_age } }
			local caption
			if player_data.paused then
				caption = { "", "[color=yellow]", { "cybersyn-gui.paused-updated-ago", age }, "[/color]" }
			else
				caption = { "cybersyn-gui.updated-ago", age }
				if held then caption = { "", caption, " ", { "cybersyn-gui.layout-held" } } end
			end
			label.caption = caption
		end
	else
		player_data.status_sig = nil
	end

	local collecting = collector.collecting()
	local show = collecting ~= nil and not (player_data.paused and data_tick)
	local percent = show and math.floor(collecting * 100) or -1
	if player_data.collecting_shown ~= percent then
		player_data.collecting_shown = percent
		for _, tab in ipairs(HEADER_TABS) do
			local note = refs[tab .. "_collecting"]
			if note and note.valid then
				note.visible = show
				note.caption = show and { "cybersyn-gui.collecting-progress", tostring(percent) } or ""
			end
		end
	end
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

--- Writes the stored filters into the filter row, the search fields and the chips; done on open and after a
--- filter change, not every update.
--- @param player_data PlayerData
function manager.restore_filter_widgets(player_data)
	local refs = player_data.refs
	if player_data.search_item and not util.signal_hash_valid(player_data.search_item) then
		player_data.search_item = nil
	end
	if player_data.search_network_name and not util.signal_hash_valid(player_data.search_network_name) then
		player_data.search_network_name = nil
	end
	refs.manager_item_filter.elem_value = player_data.search_item and util.signalid_from_hash(player_data.search_item) or nil
	refs.network.elem_value = player_data.search_network_name and util.signalid_from_name(player_data.search_network_name) or nil
	refs.manager_network_mask_field.text = tostring(player_data.search_network_mask or -1)
	manager.rebuild_surface_dropdown(player_data)
	manager.refresh_search_fields(player_data)
	player_data.chip_sig = nil
	manager.refresh_chips(player_data)
	local player = game.get_player(player_data.player_index)
	if player then manager.refresh_filter_row(player, player_data) end
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
			-- The header sits right above the scroll pane.
			util.sync_sort_header(pane.parent.children[pane.get_index_in_parent() - 1], column, ascending)
		end
	end
end

local tab_builders = {
	overview_tab = overview_tab,
	inventory_tab = inventory_tab,
	stations_tab = stations_tab,
	trains_tab = trains_tab,
	log_tab = log_tab,
	utilization_tab = utilization_tab,
	delivery_breakdown_tab = delivery_breakdown_tab,
	problems_tab = problems_tab,
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

	-- The drill-down replaces the selected tab's content while it is open.
	if player_data.item_view and item.build(map_data, player_data) then return end

	local builder = tab_builders[current_tab]
	if builder then
		builder.build(map_data, player_data)
	end
end

--- Train alerts as the Trains tab's badge (PLAN3 §4.6).
--- @param player_data PlayerData
local function refresh_badges(player_data)
	problems_tab.refresh_tab(player_data)
	local tab = player_data.refs.manager_trains_tab
	if not (tab and tab.valid) then return end
	local n = #collector.get().alerts
	if player_data.trains_badge ~= n then
		player_data.trains_badge = n
		tab.badge_text = n > 0 and tostring(n) or ""
		tab.tooltip = n > 0 and { "cybersyn-gui.trains-badge-tooltip", tostring(n) } or ""
	end
end

--- Renders the selected tab from the current snapshot and refreshes the status label.
--- @param player LuaPlayer?
--- @param player_data PlayerData
function manager.render(player, player_data)
	if not player_data.is_manager_open then return end
	log_tab.refresh_visibility(player_data)
	manager.update(storage, player_data)
	player_data.last_update_tick = game.tick
	player_data.rendered_snapshot_tick = collector.get().tick
	manager.update_status(player_data)
	manager.refresh_chips(player_data)
	refresh_badges(player_data)
	log_tab.refresh_badge(player_data)
end

util.set_rerender(manager.render)
manager.log_tab = log_tab
overview_tab.manager = manager
item.manager = manager

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
	if not (refs.manager_filter_row and refs.manager_filter_row.valid and refs.manager_problems_tab
			and refs.manager_problems_tab.valid) then
		if refs.manager_window and refs.manager_window.valid then
			refs.manager_window.destroy()
		end
		refs = manager.create(player)
		player_data.refs = refs
		player_data.gui_state = {}
	end
	player_data.chip_sig = nil
	player_data.collecting_shown = nil
	player_data.trains_badge = nil
	player_data.problems_badge = nil
	player_data.problems_scan_sig = nil
	player_data.status_sig = nil
	manager.refresh_banners(player_data)
	manager.apply_layout(player, player_data)
	refs.manager_window.visible = true
	player_data.visible = true
	manager.place_window(player, player_data)
	refs.manager_window.bring_to_front()

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
	log_tab.restore_widgets(player_data)
	log_tab.refresh_visibility(player_data)
	if not util.select_tab(player_data, player_data.selected_tab or DEFAULT_TAB) then
		util.select_tab(player_data, DEFAULT_TAB)
	end

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
	player_data.search_open = nil
	player_data.overlay_took = nil
	item.close(player, player_data)
	explain.close(player, player_data)
	util.close_manager_window(player, player_data, refs, true)
end

-- ---------------------------------------------------------------- overlays and Escape

--- One rule for every overlay of the window (Explain, the item drill-down, the Trains detail pane; top first): Escape
--- closes the top overlay and the window stays. An unpinned window holds player.opened anyway. A pinned one does not,
--- so while an overlay is open it takes player.opened when this is set (and gives it up with the last overlay), and
--- Escape peels its overlays too; with it unset a pinned window's overlays close only by their own buttons, and Escape
--- goes past the window. Open question for Daniel in DECISIONS.md (phase 7); this flag is the whole answer.
manager.PINNED_OVERLAYS_TAKE_OPENED = true

--- The overlay Escape closes next, or nil. A search field that has the keyboard counts as the top one: Escape
--- clears and closes it.
--- @param player_data PlayerData
--- @return "search"|"explain"|"item"|"pane"|nil
function manager.top_overlay(player_data)
	if player_data.search_focused then return "search" end
	if player_data.explain then return "explain" end
	if player_data.item_view then return "item" end
	if trains_tab.pane_shown(player_data) then return "pane" end
	return nil
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @return boolean
local function may_take_opened(player, player_data)
	return manager.PINNED_OVERLAYS_TAKE_OPENED and player_data.pinning and not player_data.auto_pinned
		and player.controller_type ~= defines.controllers.remote and player_data.is_manager_open == true
end

--- An overlay opened: a pinned window takes player.opened so that Escape reaches it (only when no GUI holds it).
--- @param player LuaPlayer
--- @param player_data PlayerData
function manager.overlay_opened(player, player_data)
	if player_data.overlay_took or not may_take_opened(player, player_data) then return end
	local window = player_data.refs and player_data.refs.manager_window
	if not (window and window.valid) or player.opened_gui_type ~= defines.gui_type.none then return end
	player.opened = window
	player_data.overlay_took = player.opened == window or nil
end

--- An overlay closed by its own button or a tab switch: with the last one gone, a pinned window that took
--- player.opened for them gives it up (the on_gui_closed that raises is ignored: pinned, nothing taken).
--- @param player LuaPlayer
--- @param player_data PlayerData
function manager.overlay_closed(player, player_data)
	if not player_data.overlay_took or manager.top_overlay(player_data) then return end
	player_data.overlay_took = nil
	local window = player_data.refs and player_data.refs.manager_window
	if window and window.valid and player.opened == window then player.opened = nil end
end

util.set_overlay_fns({ opened = manager.overlay_opened, closed = manager.overlay_closed })

--- Closes the top overlay; returns its kind and, for the pane, the train it showed.
--- @return string?
--- @return uint?
local function peel_overlay(player, player_data)
	local kind = manager.top_overlay(player_data)
	if kind == "search" then
		manager.cancel_search(player, player_data)
	elseif kind == "explain" then
		explain.close(player, player_data)
	elseif kind == "item" then
		item.close(player, player_data, true)
	elseif kind == "pane" then
		return kind, trains_tab.close_pane(player_data)
	end
	return kind, nil
end

--- on_gui_closed (Escape / E) of the window. Escape peels the top overlay (manager.top_overlay); with none, an unpinned
--- window closes and a pinned one ignores it.
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.handle.manager_closed_by_game(player, player_data, refs)
	if not player_data.is_manager_open then return end
	-- The action dialog took player.opened from the window: it hands it back when it closes (repair.lua).
	if player_data.dialog_opening == game.tick then return end
	local pinned = player_data.pinning
	-- A pinned window without player.opened taken for its overlays: Escape was not for it.
	if pinned and not player_data.overlay_took then return end
	-- A link of this window just opened an entity GUI: stay on screen and take player.opened back once it is closed.
	local return_to = player_data.return_to
	-- Without a manager tick (updates per second 0) nothing would ever hand player.opened back.
	if return_to and return_to.tick == game.tick and (pinned or mod_settings.manager_ups > DELTA) then
		player_data.return_to = nil
		player_data.restore_opened = { entity = return_to.entity, controller = return_to.controller }
		return
	end
	if player_data.restore_opened and player_data.handed_back_tick == game.tick then return end
	-- Escape while the search field has the keyboard cancels the search, not the window.
	if not pinned and manager.cancel_search(player, player_data) then
		player.opened = refs.manager_window
		return
	end
	-- Escape with an overlay open closes the overlay. This event cannot tell Escape from another GUI replacing the
	-- window (an entity clicked in the world, the map, another mod), and taking player.opened back here would take it
	-- from that GUI. So the window gets player.opened back on a later tick (manager.settle_pane_escapes), unless a GUI
	-- opens or the controller changes first (manager.interrupt_pane_escape): then an unpinned window closes as it did
	-- before the overlay (a pane's train stays selected). A pinned window stays on screen through other GUIs and remote
	-- view (PLAN3 §1), so its overlay is peeled only once the later tick shows nothing replaced the window.
	local kind, train
	if pinned then
		kind = manager.top_overlay(player_data)
	else
		kind, train = peel_overlay(player, player_data)
	end
	if kind then
		local manager_data = storage.manager
		local pending = manager_data.pane_escapes or {}
		manager_data.pane_escapes = pending
		pending[player.index] = { tick = game.tick, train = train, controller = player.controller_type, kind = kind,
			pinned = pinned, peel = pinned or nil }
		if not pinned then manager.render(player, player_data) end
		return
	end
	if pinned then
		player_data.overlay_took = nil
		return
	end
	manager.handle.manager_close(player, player_data, refs)
end

--- @param manager_data Manager
--- @param pi uint
--- @return {tick: uint, train: uint?, controller: defines.controllers, kind: string?, pinned: boolean?}?
local function take_pane_escape(manager_data, pi)
	local pending = manager_data and manager_data.pane_escapes
	local p = pending and pending[pi]
	if not p then return nil end
	pending[pi] = nil
	if not next(pending) then manager_data.pane_escapes = nil end
	return p
end

--- A pinned window whose player.opened another GUI or remote view took keeps its overlays. A search field lost the
--- keyboard (its query stays); the window takes player.opened back for the rest once no GUI holds it, on the
--- controller it has now (manager.restore_opened), so Escape reaches them again.
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param entity LuaEntity? the entity whose GUI replaced the window: closing it hands player.opened back at once
local function keep_pinned_overlays(player, player_data, entity)
	player_data.overlay_took = nil
	if player_data.search_focused then
		player_data.search_focused = nil
		manager.refresh_search_fields(player_data)
	end
	if manager.top_overlay(player_data) and not player_data.restore_opened then
		player_data.restore_opened = { entity = entity, controller = player.controller_type }
	end
end

--- A GUI opened or the controller changed while an Escape waits for its hand-back: something replaced the window. An
--- unpinned window closes (the pane's train stays selected for the next open); a pinned one stays with its overlays.
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param entity LuaEntity? the entity of the GUI that opened
function manager.interrupt_pane_escape(player, player_data, entity)
	local p = take_pane_escape(storage.manager, player.index)
	if not (p and player_data.is_manager_open) then return end
	if p.pinned then
		keep_pinned_overlays(player, player_data, entity)
		return
	end
	if p.train then trains_tab.select(player_data, p.train) end
	manager.handle.manager_close(player, player_data, player_data.refs)
end

--- on_gui_opened: any GUI but the manager window itself interrupts a waiting Escape.
--- @param e EventData.on_gui_opened
function manager.on_other_gui_opened(e)
	local manager_data = storage.manager
	if not (manager_data and manager_data.pane_escapes and manager_data.pane_escapes[e.player_index]) then return end
	local player_data = manager_data.players[e.player_index]
	local window = player_data and player_data.refs and player_data.refs.manager_window
	if e.element and window and e.element == window then return end
	local player = game.get_player(e.player_index)
	if player and player_data then manager.interrupt_pane_escape(player, player_data, e.entity) end
end

--- Hands player.opened back to windows an Escape peeled an overlay of in an earlier tick, when nothing else took the
--- screen meanwhile; otherwise an unpinned window closes. A pinned window peels its overlay here, and only when nothing
--- replaced it, then takes player.opened back while an overlay is still open. Runs every few ticks (scripts/main.lua: the planner's tick, the manager tick and the fixed export tick).
function manager.settle_pane_escapes()
	local manager_data = storage.manager
	local pending = manager_data and manager_data.pane_escapes
	if not pending then return end
	local tick = game.tick
	for pi, p in pairs(pending) do
		if p.tick ~= tick then
			take_pane_escape(manager_data, pi)
			local player = game.get_player(pi)
			local player_data = manager_data.players[pi]
			local window = player_data and player_data.refs and player_data.refs.manager_window
			if player and player_data and player_data.is_manager_open and window and window.valid then
				local replaced = (player.opened_gui_type ~= defines.gui_type.none and player.opened ~= window)
					or player.controller_type ~= p.controller
				if p.pinned then
					if replaced then
						keep_pinned_overlays(player, player_data, nil)
					else
						if p.peel then
							peel_overlay(player, player_data)
							manager.render(player, player_data)
						end
						if not (manager.top_overlay(player_data) and may_take_opened(player, player_data)) then
							player_data.overlay_took = nil
						elseif player.opened ~= window then
							player.opened = window
							player_data.overlay_took = player.opened == window or nil
						end
					end
				elseif replaced then
					manager.handle.manager_close(player, player_data, player_data.refs)
				elseif player.opened ~= window then
					player.opened = window
				end
			end
		end
	end
end

--- Gives player.opened back to an unpinned manager whose link opened another GUI, once no GUI holds player.opened.
--- Runs on the manager tick and from on_gui_closed of the linked entity; only the manager tick may call it done,
--- because a GUI opened inside on_gui_closed while the engine is switching to another GUI is force-closed without an
--- event. opened_gui_type, not opened, tells whether a GUI is open: the trains overview, production statistics and
--- similar GUIs read as opened == nil. Remote view closes an unpinned manager (PLAN3 §4.6), also while a hand-back
--- is pending.
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @return boolean done
function manager.restore_opened(player, player_data)
	local refs = player_data.refs
	local window = refs and refs.manager_window
	if not player_data.is_manager_open or not (window and window.valid) then return true end
	local pinned = player_data.pinning
	-- A pinned window takes player.opened back only for its overlays (a drill-down link opened the entity GUI).
	if pinned and not (manager.top_overlay(player_data) and may_take_opened(player, player_data)) then
		player_data.overlay_took = nil
		return true
	end
	if player.opened == window then return true end
	if player.opened_gui_type ~= defines.gui_type.none then return false end
	-- Checked only once no GUI is open: a locomotive on another surface opens its GUI in remote view and leaves it
	-- when that GUI closes.
	local pending = player_data.restore_opened
	if pending and pending.controller and player.controller_type ~= pending.controller then
		if pinned then
			player_data.overlay_took = nil
		else
			manager.handle.manager_close(player, player_data, refs)
		end
		return true
	end
	player.opened = window
	if pinned then player_data.overlay_took = player.opened == window or nil end
	return player.opened == window
end

--- Leaving the remote view that "show on map" opened: the window it pinned is unpinned and takes player.opened
--- again.
--- @param player LuaPlayer
--- @param player_data PlayerData
function manager.on_controller_changed(player, player_data)
	manager.interrupt_pane_escape(player, player_data)
	if not player_data.auto_pinned or player.controller_type == defines.controllers.remote then return end
	manager.unpin_after_map(player, player_data)
end

--- The window "show on map" pinned is unpinned and takes player.opened again.
--- @param player LuaPlayer
--- @param player_data PlayerData
function manager.unpin_after_map(player, player_data)
	player_data.auto_pinned = nil
	player_data.map_from = nil
	player_data.pinning = false
	manager.refresh_toggles(player_data)
	local window = player_data.refs and player_data.refs.manager_window
	if player_data.is_manager_open and window and window.valid then
		player.opened = window
	end
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.handle.manager_back(player, player_data, refs)
	local from = player_data.map_from
	if from and player.controller_type == defines.controllers.remote then
		-- A platform's own view is remote: no controller change follows, so the window is unpinned here.
		local surface = game.get_surface(from.surface)
		if surface then player.set_controller({ type = defines.controllers.remote, position = from.position, surface = surface }) end
		if player_data.auto_pinned then manager.unpin_after_map(player, player_data) end
		return
	end
	if player.controller_type == defines.controllers.remote then
		player.exit_remote_view()
	end
	manager.on_controller_changed(player, player_data)
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
		player_data.location = nil
		refs.manager_window.force_auto_center()
	end
end

--- @param e EventData.on_gui_location_changed
function manager.handle.manager_location_changed(player, player_data, refs, e)
	local window = e.element
	-- Centring a hidden window moves it too; only a position the player can see is worth keeping.
	if window and window.valid and window == refs.manager_window and window.visible and player_data.is_manager_open then
		local loc = window.location
		player_data.location = { x = loc.x, y = loc.y }
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
	-- Pinning by hand keeps the window pinned after remote view.
	player_data.auto_pinned = nil
	manager.refresh_toggles(player_data)
	if not player_data.is_manager_open then return end
	if player_data.pinning then
		-- Releasing player.opened raises on_gui_closed, which a pinned window ignores. Open overlays keep it
		-- (manager.PINNED_OVERLAYS_TAKE_OPENED).
		if player.opened == refs.manager_window then
			if manager.top_overlay(player_data) and may_take_opened(player, player_data) then
				player_data.overlay_took = true
			else
				player.opened = nil
			end
		end
	else
		player_data.overlay_took = nil
		player.opened = refs.manager_window
	end
end

--- Opens the search field of the selected tab and gives it the keyboard; the Overview has none, so its search goes
--- to the Stations tab.
--- @param player LuaPlayer
--- @param player_data PlayerData
function manager.focus_search(player, player_data)
	-- The search field lives in the tab's subheader, which the drill-down hides.
	item.close(player, player_data)
	if not SEARCH_TABS[player_data.selected_tab] then
		util.select_tab(player_data, "stations_tab")
	end
	player_data.search_open = true
	manager.refresh_search_fields(player_data)
	local field = player_data.refs[player_data.selected_tab .. "_search_field"]
	if field and field.valid then
		player_data.search_focused = true
		-- Before the focus: taking player.opened must not take the keyboard from the field again.
		manager.overlay_opened(player, player_data)
		field.focus()
		field.select_all()
	end
	manager.render(player, player_data)
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.handle.manager_toggle_search(player, player_data, refs)
	if search_shown(player_data) and SEARCH_TABS[player_data.selected_tab] then
		player_data.search_open = nil
		if player_data.search_query then
			util.set_search_query(player_data, nil)
			util.reset_pages(player_data)
		end
		manager.refresh_search_fields(player_data)
		manager.render(player, player_data)
	else
		manager.focus_search(player, player_data)
	end
end

--- The search custom input (linked to the game's focus-search, Ctrl+F by default): only while the window is open.
--- @param e EventData.CustomInputEvent
function manager.on_search_input(e)
	local player_data = storage.manager and storage.manager.players[e.player_index]
	if not (player_data and player_data.is_manager_open) then return end
	local player = game.get_player(e.player_index)
	if not player then return end
	-- The input is linked to the game's focus-search, which the GUI in front gets too: a pinned window behind another
	-- GUI (a chest, the train window) leaves Ctrl+F to that GUI instead of taking the keyboard from it.
	local window = player_data.refs and player_data.refs.manager_window
	if player.opened_gui_type ~= defines.gui_type.none and player.opened ~= window then return end
	-- With no GUI open at all (a pinned window without overlays), the client turns the same keypress into the map
	-- search in remote view; taking the keyboard here would only lose it to that again.
	if player.opened_gui_type == defines.gui_type.none then return end
	manager.focus_search(player, player_data)
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
--- @param e EventData.on_gui_text_changed
function manager.handle.manager_search_changed(player, player_data, refs, e)
	util.set_search_query(player_data, e.element.text)
	util.reset_pages(player_data)
	manager.refresh_search_fields(player_data)
	manager.render(player, player_data)
end

--- @param e EventData.on_gui_click
function manager.handle.manager_search_click(player, player_data, refs, e)
	player_data.search_focused = true
	manager.overlay_opened(player, player_data)
end

--- @param e EventData.on_gui_confirmed
function manager.handle.manager_search_confirmed(player, player_data, refs, e)
	player_data.search_focused = nil
	manager.overlay_closed(player, player_data)
end

--- Escape while the search field has the keyboard: the text goes, the field closes, the window stays.
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @return boolean handled
function manager.cancel_search(player, player_data)
	if not player_data.search_focused then return false end
	player_data.search_focused = nil
	player_data.search_open = nil
	util.set_search_query(player_data, nil)
	util.reset_pages(player_data)
	manager.refresh_search_fields(player_data)
	manager.render(player, player_data)
	return true
end

--- The item chip (either half): any click removes the item filter.
--- @param e EventData.on_gui_click
function manager.handle.manager_chip_click(player, player_data, refs, e)
	util.set_item_filter(player_data, nil)
	manager.restore_filter_widgets(player_data)
	manager.render(player, player_data)
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.handle.manager_toggle_filter_row(player, player_data, refs)
	player_data.filter_row_open = not player_data.filter_row_open
	manager.refresh_filter_row(player, player_data)
	manager.render(player, player_data)
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
	player_data.stations_chip = nil
	player_data.trains_chip = nil
	util.reset_pages(player_data)
	manager.restore_filter_widgets(player_data)
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
	else
		player_data.search_item = nil
	end
	util.reset_pages(player_data)
	manager.refresh_filter_row(player, player_data)
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
	manager.refresh_filter_row(player, player_data)
	manager.render(player, player_data)
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
--- @param e EventData.on_gui_text_changed
function manager.handle.manager_update_network_mask(player, player_data, refs, e)
	player_data.search_network_mask = tonumber(e.text) or -1
	util.reset_pages(player_data)
	manager.refresh_filter_row(player, player_data)
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
	manager.refresh_filter_row(player, player_data)
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
		-- Another tab hides the pane and closes the drill-down: a pinned window may give player.opened up.
		manager.overlay_closed(player, player_data)
	end
end

gui.add_handlers(manager.handle, manager.wrapper)

return manager
