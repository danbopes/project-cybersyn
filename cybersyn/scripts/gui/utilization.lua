-- Utilization tab (PLAN4 D14): one row per train layout with its trains, how busy they were over the period and
-- their average trip. Read from storage.trains (composition, trains, deliveries in flight) and the always-on stats
-- buckets (delivery time per layout), on the manager tick while the tab shows; no chart, no charts library.

local gui = require("__flib__.gui")
local format = require("__flib__.format")
local dev = require("scripts.gui.dev")
local util = require("scripts.gui.util")
local logic = require("scripts.gui.tab-logic")
local stats = require("scripts.stats")

local utilization_tab = {}

local TAB = "utilization_tab"
-- The rows are rebuilt at most this often: busy shares move slowly and a layout appears or goes rarely.
local REFRESH_TICKS = 60
utilization_tab.PERIODS = { 10, 60, 1440 }
local DEFAULT_PERIOD = 2
local W = { layout = 360, trains = 90, busy = 220, trip = 120, deliveries = 120 }
local BAR_WIDTH = 120

-- Statuses on a delivery (to provider, loading, to requester, unloading): what "busy" counts.
local BUSY = { [STATUS_TO_P] = true, [STATUS_P] = true, [STATUS_TO_R] = true, [STATUS_R] = true }

--- @class UtilizationRow
--- @field layout_id uint
--- @field composition string
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

local function header_cell(caption, tooltip, width)
	return { type = "label", style = "bold_label", caption = caption, tooltip = tooltip, style_mods = { width = width } }
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
					{ type = "label", name = "utilization_recorded", style = "cybersyn_subheader_note", caption = "" },
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
					type = "table",
					name = "utilization_table",
					column_count = 5,
					draw_horizontal_line_after_headers = true,
					style_mods = { horizontal_spacing = 12, vertical_spacing = 6, padding = 8 },
					header_cell({ "cybersyn-gui.utilization-col-layout" }, { "cybersyn-gui.utilization-col-layout-tooltip" }, W.layout),
					header_cell({ "cybersyn-gui.utilization-col-trains" }, { "cybersyn-gui.utilization-col-trains-tooltip" }, W.trains),
					header_cell({ "cybersyn-gui.utilization-col-busy" }, { "cybersyn-gui.utilization-col-busy-tooltip" }, W.busy),
					header_cell({ "cybersyn-gui.utilization-col-trip" }, { "cybersyn-gui.utilization-col-trip-tooltip" }, W.trip),
					header_cell({ "cybersyn-gui.utilization-col-deliveries" }, { "cybersyn-gui.utilization-col-deliveries-tooltip" }, W.deliveries),
				},
				{
					type = "flow",
					name = "utilization_empty_flow",
					direction = "horizontal",
					style = "cybersyn_overview_empty_flow",
					visible = false,
					{ type = "label", style = "cybersyn_overview_empty_label", caption = { "cybersyn-gui.utilization-empty" } },
				},
			},
		},
	}
end

--- @param player_data PlayerData
--- @return int minutes
local function period_of(player_data)
	return utilization_tab.PERIODS[player_data.utilization_period or DEFAULT_PERIOD] or 60
end

--- @param row UtilizationRow
--- @return flib.GuiElemDef[]
local function row_defs(row)
	local busy_pct = math.floor(row.busy * 100 + 0.5)
	return {
		{ type = "label", caption = row.composition, tooltip = { "cybersyn-gui.utilization-layout-tooltip", row.composition,
			tostring(row.layout_id) }, style_mods = { width = W.layout } },
		{ type = "label", caption = format.number(row.trains), style_mods = { width = W.trains } },
		{
			type = "flow",
			direction = "horizontal",
			style_mods = { width = W.busy, vertical_align = "center", horizontal_spacing = 8 },
			tooltip = { "cybersyn-gui.utilization-busy-tooltip", tostring(busy_pct), format.number(row.busy_now),
				format.number(row.trains) },
			{ type = "progressbar", value = row.busy, style_mods = { width = BAR_WIDTH } },
			{ type = "label", caption = busy_pct .. " %" },
		},
		{ type = "label", caption = row.trip and util.short_duration(row.trip) or "–", style_mods = { width = W.trip } },
		{ type = "label", caption = format.number(row.deliveries), style_mods = { width = W.deliveries } },
	}
end

---@param map_data MapData
---@param player_data PlayerData
function utilization_tab.build(map_data, player_data)
	local refs = player_data.refs
	local tbl = refs.utilization_table
	if not (tbl and tbl.valid) then return end
	local minutes = period_of(player_data)
	local cache = player_data.utilization_cache
	local now = game.tick
	if cache and cache.minutes == minutes and now - cache.tick < REFRESH_TICKS then return end
	local rows, span = utilization_tab.model(map_data.trains, map_data.layouts, minutes)
	local sig = { minutes }
	for _, r in ipairs(rows) do
		sig[#sig + 1] = table.concat({ r.layout_id, r.composition, r.trains, r.busy_now, math.floor(r.busy * 1000),
			r.trip and math.floor(r.trip / 60) or "", r.deliveries }, ":")
	end
	sig = table.concat(sig, ",")
	player_data.utilization_cache = { tick = now, minutes = minutes, rows = #rows }
	local dropdown = refs.utilization_period
	if dropdown and dropdown.valid then dropdown.selected_index = player_data.utilization_period or DEFAULT_PERIOD end
	local recorded = refs.utilization_recorded
	local partial = span < minutes * 3600
	if recorded and recorded.valid then
		recorded.caption = partial and { "cybersyn-gui.overview-period-recorded", util.short_duration(span) } or ""
	end
	local empty = refs.utilization_empty_flow
	if empty and empty.valid then empty.visible = #rows == 0 end
	if player_data.utilization_sig == sig then return end
	player_data.utilization_sig = sig
	-- The five header cells stay; a handful of layout rows are rebuilt whole when anything in them changed.
	local children = tbl.children
	for i = #children, 6, -1 do children[i].destroy() end
	for _, row in ipairs(rows) do
		for _, def in ipairs(row_defs(row)) do gui.add(tbl, def) end
	end
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
	local tbl = refs.utilization_table
	local rows, cells = {}, tbl and tbl.valid and tbl.children or {}
	for i = 6, #cells, 5 do
		rows[#rows + 1] = {
			layout = cells[i].caption,
			trains = cells[i + 1].caption,
			busy = cells[i + 2].children[2].caption,
			trip = cells[i + 3].caption,
			deliveries = cells[i + 4].caption,
		}
	end
	return { rows = rows, minutes = period_of(player_data), header = refs.utilization_header.caption,
		empty = refs.utilization_empty_flow.visible }
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
