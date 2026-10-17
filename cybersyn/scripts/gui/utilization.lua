-- Utilization tab (PLAN4 D14): one row per train layout with its trains, how busy they were over the period and
-- their average trip. Read from storage.trains (composition, trains, deliveries in flight) and the always-on stats
-- buckets (delivery time per layout), on the manager tick while the tab shows; no chart, no charts library.

local gui = require("__flib__.gui")
local format = require("__flib__.format")
local dev = require("scripts.gui.dev")
local util = require("scripts.gui.util")
local logic = require("scripts.gui.tab-logic")
local sizing = require("scripts.gui.sizing")
local stats = require("scripts.stats")

local utilization_tab = {}

local TAB = "utilization_tab"
-- The rows are rebuilt at most this often: busy shares move slowly and a layout appears or goes rarely.
local REFRESH_TICKS = 60
utilization_tab.PERIODS = { 10, 60, 1440 }
local DEFAULT_PERIOD = 2
-- Fixed columns in logical px; Layout takes the rest of the row (layout_width). The four number columns are
-- right-aligned, as on Stations and Trains.
local W = { trains = 90, busy = 200, trip = 120, deliveries = 120 }
local BAR_WIDTH = 120
local PCT_WIDTH = 48
local LAYOUT_MIN = 240
-- The rows' frame borders and padding (cybersyn_station_row_*: 4 + 4), and the gaps between the five columns.
local ROW_CHROME = 8 + 8 + 4 * 8
local ROW_HEIGHT = 32

-- Statuses on a delivery (to provider, loading, to requester, unloading): what "busy" counts.
local BUSY = { [STATUS_TO_P] = true, [STATUS_P] = true, [STATUS_TO_R] = true, [STATUS_R] = true }

--- @class UtilizationRow
--- @field layout_id uint
--- @field composition string "L<CC>", or "#id" when the layout record is gone
--- @field runs {class: int, n: int}[]? logic.composition_runs, nil when the layout record is gone
--- @field trains int
--- @field busy_now int trains on a delivery now
--- @field busy number? share of the trains' time on deliveries over the period, 0..1
--- @field trip number? average dispatch-to-unloaded ticks of the deliveries completed in the period
--- @field deliveries int

--- Rows for every layout that has trains, most trains first: a pure function of the train table, the layouts and the
--- stats buckets, so the host tests and the lab compare it with an oracle.
--- @param trains {[uint]: Train}
--- @param layouts {[uint]: int[]}
--- @param minutes int
--- @return UtilizationRow[] rows
--- @return uint span ticks of the period recorded so far
function utilization_tab.model(trains, layouts, minutes)
	local count, now, inflight = {}, {}, {}
	for _, train in pairs(trains) do
		local id = train.layout_id
		if id then
			count[id] = (count[id] or 0) + 1
			if BUSY[train.status] then
				now[id] = (now[id] or 0) + 1
				local t = train.dispatch_tick
				if t then
					local list = inflight[id]
					if not list then
						list = {}
						inflight[id] = list
					end
					list[#list + 1] = t
				end
			end
		end
	end
	local usage, span = stats.layout_usage(minutes, inflight)
	local rows = {}
	for id, n in pairs(count) do
		local u = usage[id]
		local layout = layouts[id]
		local busy = u and span > 0 and math.min(1, u.busy / (n * span)) or 0
		rows[#rows + 1] = {
			layout_id = id,
			composition = layout and logic.composition(layout) or ("#" .. id),
			runs = layout and logic.composition_runs(layout) or nil,
			trains = n,
			busy_now = now[id] or 0,
			busy = busy,
			trip = u and u.trip_n > 0 and u.trip_sum / u.trip_n or nil,
			deliveries = u and u.trip_n or 0,
		}
	end
	table.sort(rows, function(a, b)
		if a.trains ~= b.trains then return a.trains > b.trains end
		return a.layout_id < b.layout_id
	end)
	return rows, span
end

-- ---------------------------------------------------------------- build

local function header_cell(caption, tooltip, width, right, name)
	return { type = "label", name = name, style = "bold_label", caption = caption, tooltip = tooltip,
		style_mods = { width = width, horizontal_align = right and "right" or "left" } }
end

--- The Layout column's width: what the fixed columns leave of the tab's width.
--- @param player_data PlayerData?
--- @return int
local function layout_width(player_data)
	local layout = player_data and player_data.layout
	local cw = layout and layout.content_width or (sizing.MAX_WIDTH - sizing.OUTER_WIDTH)
	return math.max(LAYOUT_MIN, cw - ROW_CHROME - W.trains - W.busy - W.trip - W.deliveries)
end

function utilization_tab.create()
	local periods = {}
	for i, minutes in ipairs(utilization_tab.PERIODS) do
		periods[i] = { "cybersyn-gui.overview-period-" .. minutes }
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
			style = "cybersyn_overview_content",
			{
				type = "frame",
				name = "utilization_frame",
				direction = "vertical",
				style = "cybersyn_unserved_frame",
				{
					type = "frame",
					direction = "horizontal",
					style = "cybersyn_unserved_caption_frame",
					{ type = "label", name = "utilization_header", style = "subheader_caption_label",
						caption = { "cybersyn-gui.utilization-header" }, tooltip = { "cybersyn-gui.utilization-header-tooltip" },
						style_mods = { horizontally_squashable = true } },
					{ type = "empty-widget", style = "flib_horizontal_pusher" },
					{
						type = "flow",
						name = "utilization_recorded_flow",
						direction = "horizontal",
						visible = false,
						style_mods = { horizontal_spacing = 6 },
						{ type = "label", style = "cybersyn_subheader_note", caption = { "cybersyn-gui.overview-recorded-line" } },
						{ type = "label", name = "utilization_recorded", caption = "" },
					},
					{
						type = "drop-down",
						name = "utilization_period",
						items = periods,
						selected_index = DEFAULT_PERIOD,
						tooltip = { "cybersyn-gui.utilization-period-tooltip" },
						handler = { [defines.events.on_gui_selection_state_changed] = utilization_tab.handle.on_utilization_period_changed },
					},
				},
				{
					type = "frame",
					name = "utilization_header_row",
					style = "cybersyn_list_header",
					header_cell({ "cybersyn-gui.utilization-col-layout" }, { "cybersyn-gui.utilization-col-layout-tooltip" },
						layout_width(nil), false, "utilization_layout_header"),
					header_cell({ "cybersyn-gui.utilization-col-trains" }, { "cybersyn-gui.utilization-col-trains-tooltip" }, W.trains, true),
					header_cell({ "cybersyn-gui.utilization-col-busy" }, { "cybersyn-gui.utilization-col-busy-tooltip" }, W.busy, true),
					header_cell({ "cybersyn-gui.utilization-col-trip" }, { "cybersyn-gui.utilization-col-trip-tooltip" }, W.trip, true),
					header_cell({ "cybersyn-gui.utilization-col-deliveries" }, { "cybersyn-gui.utilization-col-deliveries-tooltip" }, W.deliveries, true),
				},
				{
					type = "flow",
					name = "utilization_empty_flow",
					direction = "horizontal",
					style = "cybersyn_overview_empty_flow",
					visible = false,
					{ type = "label", style = "cybersyn_overview_empty_label", caption = { "cybersyn-gui.utilization-empty" } },
				},
				{ type = "flow", name = "utilization_rows", direction = "vertical", style = "cybersyn_list_rows" },
			},
		},
	}
end

--- @param player_data PlayerData
--- @return int minutes
local function period_of(player_data)
	return utilization_tab.PERIODS[player_data.utilization_period or DEFAULT_PERIOD] or 60
end

--- The Layout cell: the Trains tab's composition icons (one per run of one carriage class, the run's length as its
--- badge), the "L<CC>" text in the tooltip; the last icon the column holds becomes "+n" when a layout has more runs.
--- @param row UtilizationRow
--- @param width int the Layout column's width
--- @return flib.GuiElemDef
local function layout_def(row, width)
	local tooltip = { "cybersyn-gui.utilization-layout-tooltip", row.composition, tostring(row.layout_id) }
	local cell = {
		type = "flow",
		direction = "horizontal",
		tooltip = tooltip,
		style_mods = { width = width, vertical_align = "center", horizontal_spacing = 0 },
	}
	local runs = row.runs
	if not runs then
		cell[1] = { type = "label", caption = row.composition, tooltip = tooltip }
		return cell
	end
	local shown, over = logic.fit_slots(#runs, math.floor(width / logic.COMPOSITION_ICON))
	for i = 1, shown do
		local r = runs[i]
		cell[i] = {
			type = "sprite-button",
			style = "cybersyn_composition_icon",
			sprite = logic.CLASS_SPRITE[r.class],
			number = r.n > 1 and r.n or nil,
			-- Hover falls through to the cell, whose tooltip names the layout; the icons are not buttons.
			ignored_by_interaction = true,
		}
	end
	if over > 0 then
		cell[shown + 1] = { type = "label", style = "cybersyn_overflow_label", caption = "+" .. over, tooltip = tooltip,
			style_mods = { width = logic.COMPOSITION_ICON } }
	end
	return cell
end

--- One layout's row: the shared 32 px list row, the numbers on their columns' right edge.
--- @param row UtilizationRow
--- @param i int
--- @param width int the Layout column's width
--- @return flib.GuiElemDef
local function row_def(row, i, width)
	local busy_pct = math.floor(row.busy * 100 + 0.5)
	return {
		type = "frame",
		style = i % 2 == 1 and "cybersyn_station_row_light" or "cybersyn_station_row_dark",
		style_mods = { height = ROW_HEIGHT },
		direction = "horizontal",
		layout_def(row, width),
		{ type = "label", style = "cybersyn_cell_value", caption = format.number(row.trains), style_mods = { width = W.trains } },
		{
			type = "flow",
			direction = "horizontal",
			style_mods = { width = W.busy, vertical_align = "center", horizontal_align = "right", horizontal_spacing = 8 },
			tooltip = { "cybersyn-gui.utilization-busy-tooltip", tostring(busy_pct), format.number(row.busy_now),
				format.number(row.trains) },
			{ type = "progressbar", value = row.busy, style_mods = { width = BAR_WIDTH } },
			{ type = "label", style = "cybersyn_cell_value", caption = busy_pct .. " %", style_mods = { width = PCT_WIDTH } },
		},
		{ type = "label", style = "cybersyn_cell_value", caption = row.trip and util.short_duration(row.trip) or "–",
			style_mods = { width = W.trip } },
		{ type = "label", style = "cybersyn_cell_value", caption = format.number(row.deliveries), style_mods = { width = W.deliveries } },
	}
end

---@param map_data MapData
---@param player_data PlayerData
function utilization_tab.build(map_data, player_data)
	local refs = player_data.refs
	local tbl = refs.utilization_rows
	if not (tbl and tbl.valid) then return end
	local minutes = period_of(player_data)
	local cache = player_data.utilization_cache
	local now = game.tick
	if cache and cache.minutes == minutes and now - cache.tick < REFRESH_TICKS then return end
	local rows, span = utilization_tab.model(map_data.trains, map_data.layouts, minutes)
	local width = layout_width(player_data)
	local sig = { minutes, width }
	for _, r in ipairs(rows) do
		sig[#sig + 1] = table.concat({ r.layout_id, r.composition, r.trains, r.busy_now, math.floor(r.busy * 1000),
			r.trip and math.floor(r.trip / 60) or "", r.deliveries }, ":")
	end
	sig = table.concat(sig, ",")
	player_data.utilization_cache = { tick = now, minutes = minutes, rows = #rows }
	local dropdown = refs.utilization_period
	if dropdown and dropdown.valid then dropdown.selected_index = player_data.utilization_period or DEFAULT_PERIOD end
	local recorded, recorded_flow = refs.utilization_recorded, refs.utilization_recorded_flow
	local partial = span < minutes * 3600
	if recorded and recorded.valid then
		recorded.caption = partial and util.short_duration(span) or ""
		recorded_flow.visible = partial
	end
	local empty = refs.utilization_empty_flow
	if empty and empty.valid then empty.visible = #rows == 0 end
	if player_data.utilization_sig == sig then return end
	player_data.utilization_sig = sig
	-- A handful of layout rows, rebuilt whole when anything in them changed.
	local header = refs.utilization_layout_header
	if header and header.valid then header.style.width = width end
	tbl.clear()
	for i, row in ipairs(rows) do gui.add(tbl, row_def(row, i, width)) end
end

---@param map_data MapData
---@param player_data PlayerData
function utilization_tab.cleanup(map_data, player_data)
	player_data.utilization_cache = nil
	player_data.utilization_sig = nil
end

utilization_tab.handle = {}

--- @param e {player_index: uint}
function utilization_tab.wrapper(e, handler)
	local player = game.get_player(e.player_index)
	if not player then return end
	local player_data = storage.manager.players[e.player_index]
	if not player_data then return end
	handler(player, player_data, player_data.refs, e)
end

---@param player LuaPlayer
---@param player_data PlayerData
function utilization_tab.handle.on_utilization_tab_selected(player, player_data)
	player_data.selected_tab = TAB
end

--- @param e EventData.on_gui_selection_state_changed
function utilization_tab.handle.on_utilization_period_changed(player, player_data, refs, e)
	player_data.utilization_period = e.element.selected_index
	player_data.utilization_cache = nil
	util.rerender(player, player_data)
end

gui.add_handlers(utilization_tab.handle, utilization_tab.wrapper)

dev.register_dump(TAB, function(player_data)
	local refs = player_data.refs
	local list = refs.utilization_rows
	local rows = {}
	for _, row in ipairs(list and list.valid and list.children or {}) do
		local cells = row.children
		local icons = {}
		for j, icon in ipairs(cells[1].children) do
			icons[j] = icon.type == "sprite-button" and { icon.sprite, icon.number or 1 } or icon.caption
		end
		local busy = cells[3].children[2]
		rows[#rows + 1] = {
			layout = cells[1].tooltip[2],
			icons = icons,
			trains = cells[2].caption,
			busy = busy.caption,
			trip = cells[4].caption,
			deliveries = cells[5].caption,
			style = row.style.name,
			height = row.style.maximal_height,
			numbers_right = cells[2].style.name == "cybersyn_cell_value" and busy.style.name == "cybersyn_cell_value"
				and cells[3].style.horizontal_align == "right" and cells[4].style.name == "cybersyn_cell_value"
				and cells[5].style.name == "cybersyn_cell_value",
		}
	end
	local header_right = {}
	for i, cell in ipairs(refs.utilization_header_row.children) do header_right[i] = cell.style.horizontal_align == "right" end
	return { rows = rows, minutes = period_of(player_data), header = refs.utilization_header.caption,
		empty = refs.utilization_empty_flow.visible, header_right = header_right,
		recorded = refs.utilization_recorded_flow.visible and refs.utilization_recorded.caption or false,
		layout_width = refs.utilization_layout_header.style.minimal_width }
end)

--- The model the tab renders, for oracles: (pi, minutes) -> rows, span.
dev.add("utilization_model", function(pi, minutes)
	local player_data = storage.manager.players[pi]
	local rows, span = utilization_tab.model(storage.trains, storage.layouts, minutes or period_of(player_data))
	return { rows = rows, span = span }
end)

dev.add("utilization_set_period", function(pi, index)
	local player_data = storage.manager.players[pi]
	player_data.utilization_period = index
	player_data.utilization_cache = nil
	local player = game.get_player(pi)
	if player and player_data.is_manager_open then util.rerender(player, player_data) end
	return period_of(player_data)
end)

return utilization_tab
