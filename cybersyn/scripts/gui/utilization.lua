-- Utilization tab: the factorio-charts line chart of the share of each train layout's trains on a delivery, one line
-- per layout, sampled every analytics.SAMPLE_TICKS game ticks by analytics.tick. Shown only while analytics is enabled
-- and the library is installed (analytics.is_enabled).

local gui = require("__flib__.gui")
local analytics = require("scripts.analytics")
local util = require("scripts.gui.util")
local dev = require("scripts.gui.dev")

local charts_available, charts = pcall(require, "__factorio-charts__.charts")
if not charts_available then
	charts = nil
end

local utilization_tab = {}

local TAB = "utilization_tab"
local CACHE_DURATION_TICKS = 300 -- 5 seconds at 60 UPS

-- Button i shows analytics.UTILIZATION_INTERVALS[i], which spans exactly the time its caption names (unit-tested).
local interval_names = { "1m", "10m", "1h", "10h", "50h", "250h", "1000h" }
utilization_tab.INTERVAL_NAMES = interval_names

-- Graph size in logical px before the first layout is known; build() sizes it to the tab (graph_size).
local GRAPH_WIDTH = 1100
local GRAPH_HEIGHT = 700
local LEGEND_WIDTH = 150
-- Above the graph: the tab subheader 36, the item filter note 24, the time range row 32, the gaps between them.
local GRAPH_CHROME = 104
local GRAPH_MIN_WIDTH, GRAPH_MIN_HEIGHT = 400, 300
local UNSELECTED_COLOR = { r = 0.5, g = 0.5, b = 0.5 }

--- The graph's size for the player's window: the tab's width beside the legend and its height below the time range.
--- @param player_data PlayerData
--- @return int width
--- @return int height
local function graph_size(player_data)
	local layout = player_data.layout
	if not layout then return GRAPH_WIDTH, GRAPH_HEIGHT end
	return math.max(GRAPH_MIN_WIDTH, layout.content_width - LEGEND_WIDTH - 8),
		math.max(GRAPH_MIN_HEIGHT, layout.content_height - GRAPH_CHROME)
end

local function locked_size(width, height)
	return {
		width = width,
		height = height,
		minimal_width = width,
		minimal_height = height,
		maximal_width = width,
		maximal_height = height,
	}
end

function utilization_tab.create()
	local interval_buttons = {}
	for i, name in ipairs(interval_names) do
		interval_buttons[i] = {
			type = "button",
			caption = name,
			style = i == 1 and "flib_selected_tool_button" or "tool_button",
			tags = { interval_name = name, interval_index = i },
			handler = utilization_tab.handle.on_utilization_interval_click,
		}
	end

	return {
		tab = {
			name = "manager_utilization_tab",
			type = "tab",
			caption = { "cybersyn-gui.utilization-tab" },
			handler = utilization_tab.handle.on_utilization_tab_selected,
		},
		content = {
			name = "manager_utilization_content_frame",
			type = "flow",
			direction = "vertical",
			{
				type = "label",
				caption = { "cybersyn-gui.utilization-item-filter-note" },
				style_mods = { single_line = false, bottom_margin = 4 },
			},
			{
				type = "flow",
				direction = "horizontal",
				style_mods = { vertical_align = "center", horizontal_spacing = 8, bottom_margin = 4 },
				{
					type = "label",
					caption = { "cybersyn-gui.time-range" },
					style = "caption_label",
				},
				{
					name = "utilization_interval_buttons",
					type = "flow",
					direction = "horizontal",
					table.unpack(interval_buttons),
				},
			},
			{
				name = "utilization_main_flow",
				type = "flow",
				direction = "horizontal",
				style_mods = {
					horizontal_spacing = 8,
					horizontally_stretchable = true,
					vertically_stretchable = true,
				},
				visible = false,
				{
					name = "utilization_legend_flow",
					type = "flow",
					direction = "vertical",
					style_mods = { width = LEGEND_WIDTH, vertically_stretchable = true },
					{
						type = "label",
						caption = { "cybersyn-gui.train-types" },
						style = "caption_label",
					},
					{
						type = "scroll-pane",
						style = "flib_naked_scroll_pane_no_padding",
						style_mods = { vertically_stretchable = true },
						{
							name = "utilization_legend_table",
							type = "table",
							column_count = 1,
						},
					},
				},
				{
					name = "utilization_camera_frame",
					type = "frame",
					style = "deep_frame_in_shallow_frame",
					style_mods = locked_size(GRAPH_WIDTH, GRAPH_HEIGHT),
					{
						name = "utilization_camera",
						type = "camera",
						position = { 0, 0 },
						surface_index = 1,
						zoom = 1,
						style_mods = locked_size(GRAPH_WIDTH, GRAPH_HEIGHT),
					},
				},
			},
			{
				name = "utilization_no_data_label",
				type = "label",
				caption = { "cybersyn-gui.no-analytics-data" },
				visible = true,
			},
		},
	}
end

--- The legend's order (and the chart's colour order): the highest sum first, then by name.
--- @param interval {counts: {[string]: int}, sum: {[string]: number}}
--- @return {name: string, sum: number, count: int}[]
function utilization_tab.sorted_series(interval)
	local all_series = {}
	for name, count in pairs(interval.counts) do
		all_series[#all_series + 1] = { name = name, sum = interval.sum[name] or 0, count = count }
	end
	table.sort(all_series, function(a, b)
		if a.sum ~= b.sum then
			return a.sum > b.sum
		end
		return a.name < b.name
	end)
	return all_series
end

--- @param refs table<string, LuaGuiElement>
--- @param interval_index int
local function style_interval_buttons(refs, interval_index)
	local interval_buttons = refs.utilization_interval_buttons
	if not (interval_buttons and interval_buttons.valid) then return end
	for _, button in pairs(interval_buttons.children) do
		if button.tags and button.tags.interval_index then
			button.style = button.tags.interval_index == interval_index and "flib_selected_tool_button" or "tool_button"
		end
	end
end

--- @param map_data MapData
--- @param legend_table LuaGuiElement
--- @param all_series {name: string, sum: number, count: int}[]
--- @param selected_series {[string]: boolean}
local function build_legend(map_data, legend_table, all_series, selected_series)
	legend_table.clear()
	local colors = charts.get_series_colors()
	for i, entry in ipairs(all_series) do
		local layout_id = tonumber(entry.name)
		local layout = layout_id and map_data.layouts[layout_id]
		local avg_util = entry.sum / (entry.count or 1)
		local color = colors[((i - 1) % #colors) + 1]
		local is_selected = selected_series[entry.name] ~= false
		gui.add(legend_table, {
			{
				type = "flow",
				direction = "horizontal",
				style_mods = { vertical_align = "center", horizontal_spacing = 4 },
				{
					type = "progressbar",
					value = 1,
					style_mods = {
						width = 12,
						height = 4,
						color = is_selected and color or UNSELECTED_COLOR,
					},
				},
				{
					type = "checkbox",
					state = is_selected,
					caption = analytics.format_layout_name(layout, layout_id),
					tags = { series_name = entry.name },
					-- A click on a checkbox raises on_gui_click too; the state change is the one event that carries it.
					handler = { [defines.events.on_gui_checked_state_changed] = utilization_tab.handle.on_utilization_legend_checkbox_changed },
				},
				{
					type = "label",
					caption = string.format("%.1f%%", avg_util),
					style_mods = { font_color = is_selected and color or UNSELECTED_COLOR },
				},
			},
		})
	end
end

---@param map_data MapData
---@param player_data PlayerData
function utilization_tab.build(map_data, player_data)
	if not analytics.is_enabled() then
		return
	end
	analytics.init(map_data)
	if not map_data.analytics then
		return
	end

	local refs = player_data.refs
	local data = map_data.analytics

	local interval_index = player_data.utilization_interval or 1
	if not interval_names[interval_index] then interval_index = 1 end
	local intervals = data.train_utilization
	local interval = intervals[interval_index]

	style_interval_buttons(refs, interval_index)

	local has_data = interval and next(interval.counts) ~= nil or false
	if refs.utilization_no_data_label then
		refs.utilization_no_data_label.visible = not has_data
	end
	if refs.utilization_main_flow then
		refs.utilization_main_flow.visible = has_data
	end

	local player = game.get_player(player_data.player_index)
	if not player then return end

	-- The graph fills the tab: its size follows the window's layout.
	local gw, gh = graph_size(player_data)
	local frame, camera = refs.utilization_camera_frame, refs.utilization_camera
	local resized = frame and frame.valid and (frame.style.minimal_width ~= gw or frame.style.minimal_height ~= gh)
	if resized then
		for _, e in ipairs({ frame, camera }) do
			if e and e.valid then
				e.style.width, e.style.height = gw, gh
				e.style.minimal_width, e.style.minimal_height = gw, gh
				e.style.maximal_width, e.style.maximal_height = gw, gh
			end
		end
		if interval.chunk and data.surface_data then
			charts.ensure_tile_coverage(data.surface_data, interval.chunk, { viewport_width = gw, viewport_height = gh })
		end
		player_data.utilization_cache = nil
	end

	-- Keeps the camera off the player's own surface even when no chunk could be allocated.
	if camera and data.surface then
		camera.surface_index = data.surface.index
	end

	if not player_data.utilization_registered then
		analytics.interval_register_gui(map_data, interval, player, refs, { viewport_width = gw, viewport_height = gh })
		player_data.utilization_registered = true
	end

	local chunk = interval.chunk
	if not chunk then
		return
	end

	-- zoom = scale / density puts one tile on 32 logical px on any display (Windows density 1.0-1.75, Mac 2.0). The
	-- library centres the camera on a 900x700 viewport (it is not told the size); the offsets move it onto the graph's
	-- centre (tuned on the former fixed 1100x700 graph: 3.0, 0.1).
	local display_scale = player.display_scale or 1.0
	local display_density = player.display_density_scale or 1.0
	local zoom = display_scale / display_density
	local xoffset = (gw - 900) / 64 - 0.125
	local yoffset = (gh - 700) / 64 + 0.1
	if camera and charts then
		charts.setup_camera_widget(camera, data.surface, chunk, {
			widget_width = gw,
			widget_height = gh,
			display_scale = display_scale,
			position_offset = { x = xoffset, y = yoffset },
			zoom_override = zoom,
		})
	end

	if not has_data then
		return
	end

	local selected_series = player_data.utilization_selected or {}
	local current_tick = game.tick
	local cache = player_data.utilization_cache
	if cache and cache.interval_index == interval_index and (current_tick - cache.tick) < CACHE_DURATION_TICKS then
		return
	end
	local all_series = utilization_tab.sorted_series(interval)
	local drawn = analytics.render_graph(map_data, intervals, interval_index, selected_series, { 0, 100 }, nil, gw, gh)
	player_data.utilization_cache = {
		tick = current_tick,
		interval_index = interval_index,
		series = #all_series,
		drawn = drawn and #drawn or 0,
	}
	local legend_table = refs.utilization_legend_table
	if legend_table and legend_table.valid then
		build_legend(map_data, legend_table, all_series, selected_series)
	end
end

---@param map_data MapData
---@param player_data PlayerData
function utilization_tab.cleanup(map_data, player_data)
	player_data.utilization_cache = nil
	if not map_data.analytics then return end
	if not player_data.player_index then return end

	local series = map_data.analytics.train_utilization
	local interval = series and series[player_data.utilization_interval or 1]

	-- Lines left behind would overlap the next tab's chart on the shared surface.
	if interval and interval.line_ids and charts then
		charts.destroy_render_objects(interval.line_ids)
		interval.line_ids = {}
	end

	local player = game.get_player(player_data.player_index)
	if player and interval and player_data.utilization_registered then
		analytics.interval_unregister_gui(map_data, interval, player)
	end
	player_data.utilization_registered = nil
end

utilization_tab.handle = {}

utilization_tab.wrapper = util.wrapper

---@param player LuaPlayer
---@param player_data PlayerData
function utilization_tab.handle.on_utilization_tab_selected(player, player_data)
	player_data.selected_tab = TAB
end

---@param player LuaPlayer
---@param player_data PlayerData
---@param refs table<string, LuaGuiElement>
---@param e EventData.on_gui_click
function utilization_tab.handle.on_utilization_interval_click(player, player_data, refs, e)
	local element = e.element
	if not element or not element.tags then return end
	local interval_index = element.tags.interval_index
	if not interval_index then return end

	-- Unregisters the interval shown so far; build registers the new one.
	utilization_tab.cleanup(storage, player_data)
	player_data.utilization_interval = interval_index
	style_interval_buttons(refs, interval_index)
	util.rerender(player, player_data)
end

---@param player LuaPlayer
---@param player_data PlayerData
---@param refs table<string, LuaGuiElement>
---@param e EventData.on_gui_checked_state_changed
function utilization_tab.handle.on_utilization_legend_checkbox_changed(player, player_data, refs, e)
	local element = e.element
	if not element or not element.tags then return end
	local series_name = element.tags.series_name
	if not series_name then return end

	if not player_data.utilization_selected then
		player_data.utilization_selected = {}
	end
	player_data.utilization_selected[series_name] = element.state
	player_data.utilization_cache = nil
	util.rerender(player, player_data)
end

gui.add_handlers(utilization_tab.handle, utilization_tab.wrapper)

dev.register_dump(TAB, function(player_data)
	local refs = player_data.refs
	local legend = {}
	local list = refs.utilization_legend_table
	for _, row in ipairs(list and list.valid and list.children or {}) do
		local cells = row.children
		legend[#legend + 1] = { series = cells[2].tags.series_name, caption = cells[2].caption, state = cells[2].state,
			average = cells[3].caption }
	end
	local selected = {}
	local buttons = refs.utilization_interval_buttons
	for i, button in ipairs(buttons and buttons.valid and buttons.children or {}) do
		selected[i] = button.style.name == "flib_selected_tool_button"
	end
	local cache = player_data.utilization_cache
	local camera = refs.utilization_camera
	local gw, gh = graph_size(player_data)
	local layout = player_data.layout
	return {
		interval = player_data.utilization_interval or 1,
		buttons = selected,
		captions = interval_names,
		legend = legend,
		chart = refs.utilization_main_flow.visible,
		no_data = refs.utilization_no_data_label.visible,
		registered = player_data.utilization_registered == true,
		series = cache and cache.series or 0,
		drawn = cache and cache.drawn or 0,
		camera_surface = camera and camera.valid and camera.surface_index or nil,
		camera_width = camera and camera.valid and camera.style.minimal_width or nil,
		width = gw,
		height = gh,
		content_width = layout and layout.content_width,
		content_height = layout and layout.content_height,
		legend_width = LEGEND_WIDTH,
		chrome = GRAPH_CHROME,
	}
end)

--- The legend checkbox of `series` toggled as a player's click toggles it.
dev.add("utilization_toggle", function(pi, series)
	local player_data = storage.manager.players[pi]
	local list = player_data.refs.utilization_legend_table
	for _, row in ipairs(list and list.valid and list.children or {}) do
		local box = row.children[2]
		if box.tags.series_name == series then
			local state = not box.state
			box.state = state
			-- The handler rebuilds the legend, so `box` is gone afterwards.
			util.dispatch({ name = defines.events.on_gui_checked_state_changed, element = box, player_index = pi,
				tick = game.tick })
			return state
		end
	end
	return "no series " .. tostring(series)
end)

--- The chart's samples (per interval: series -> sample count), whether the library loaded and the tick the missing
--- library was named to player `pi`, for oracles.
dev.add("utilization_samples", function(pi)
	local data = storage.analytics
	local player_data = pi and storage.manager.players[pi]
	local out = { library = analytics.is_library_available(), enabled = analytics.is_enabled() and true or false,
		notice = player_data and player_data.analytics_notice_tick }
	if data and data.train_utilization then
		out.intervals = {}
		for i, interval in ipairs(data.train_utilization) do
			local coord = interval.chunk and interval.chunk.coord
			out.intervals[i] = { name = interval.name, counts = interval.counts, viewers = interval.viewer_count,
				chunk = coord and (coord.x .. "," .. coord.y) }
		end
	end
	return out
end)

return utilization_tab
