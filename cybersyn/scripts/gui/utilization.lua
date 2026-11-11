-- Utilization tab: the factorio-charts line chart of the share of each train layout's trains on a delivery, one line
-- per layout, sampled every analytics.SAMPLE_TICKS game ticks by analytics.tick. Shown only while analytics is enabled
-- and the library is installed (analytics.is_enabled).

local gui = require("__flib__.gui")
local analytics = require("scripts.analytics")
local util = require("scripts.gui.util")
local nav = require("scripts.gui.utils.nav")

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

	local interval_index = player_data.tabs.utilization_tab.interval or 1
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
	local camera = refs.utilization_camera
	-- The constant y term is tuned by eye (0.1 at 1100x700).
	local resized = analytics.sync_chart_view(map_data, interval, player, refs, refs.utilization_camera_frame,
		camera, gw, gh, 0.1)
	if resized then player_data.cache.utilization = nil end
	if not interval.chunk then return end

	if not has_data then
		return
	end

	local selected_series = player_data.tabs.utilization_tab.selected or {}
	local current_tick = game.tick
	local cache = player_data.cache.utilization
	local legend_table = refs.utilization_legend_table
	-- A window rebuilt within the cache's life (reset_player) has an empty legend that must not wait for the cache.
	local legend_built = legend_table and legend_table.valid and #legend_table.children > 0
	if legend_built and cache and cache.interval_index == interval_index and (current_tick - cache.tick) < CACHE_DURATION_TICKS then
		return
	end
	local all_series = utilization_tab.sorted_series(interval)
	-- factorio-charts 1.1.0 (the last release for Factorio 2.0) has no X axis or crosshair hover.
	local state = analytics.render_chart(map_data, interval, interval_index, {
		selected_series = selected_series,
		y_range = { 0, 100 },
		label_format = "percent",
		viewport_width = gw,
		viewport_height = gh,
	})
	local drawn = state and state.ordered_sums
	player_data.cache.utilization = {
		tick = current_tick,
		interval_index = interval_index,
		series = #all_series,
		drawn = drawn and #drawn or 0,
	}
	if legend_table and legend_table.valid then
		build_legend(map_data, legend_table, all_series, selected_series)
	end
end

---@param map_data MapData
---@param player_data PlayerData
function utilization_tab.cleanup(map_data, player_data)
	player_data.cache.utilization = nil
	if not map_data.analytics then return end
	if not player_data.player_index then return end

	local series = map_data.analytics.train_utilization
	local interval = series and series[player_data.tabs.utilization_tab.interval or 1]

	local player = game.get_player(player_data.player_index)
	if player and interval and interval.guis[player.index] then
		analytics.interval_unregister_gui(map_data, interval, player)
	end
	-- The chart is every viewer's: only the last one to leave destroys it.
	if interval and interval.viewer_count <= 0 and charts then
		analytics.destroy_chart(interval)
	end
end

utilization_tab.handle = {}

utilization_tab.wrapper = util.wrapper

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
	player_data.tabs.utilization_tab.interval = interval_index
	style_interval_buttons(refs, interval_index)
	nav.rerender(player, player_data)
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

	if not player_data.tabs.utilization_tab.selected then
		player_data.tabs.utilization_tab.selected = {}
	end
	player_data.tabs.utilization_tab.selected[series_name] = element.state
	player_data.cache.utilization = nil
	nav.rerender(player, player_data)
end

gui.add_handlers(utilization_tab.handle, utilization_tab.wrapper)

return utilization_tab
