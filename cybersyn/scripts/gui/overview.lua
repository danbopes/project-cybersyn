local gui = require("__flib__.gui")
local format = require("__flib__.format")

local constants = require("scripts.gui.constants")
local util = require("scripts.gui.util")
local collector = require("scripts.gui.collector")
local dev = require("scripts.gui.dev")
local stats = require("scripts.stats")
local stations_tab = require("scripts.gui.stations")

--- @class PlayerData
--- @field overview_period int? minutes covered by the Overview's period figures: 10, 60 or 1440; see get_period
--- @field overview_offsets {[string]: int}? first row shown per Overview panel, a multiple of the panel capacity
--- @field overview_cache {view_key: string, data_key: string, base: table, build: table?}? snapshot-derived Overview figures, see cached_snapshot_model

local overview_tab = {}

local TAB = "overview_tab"

local PERIODS = { 10, 60, 1440 }
local DEFAULT_PERIOD = 60

-- Every tab is this tall, so they all end the same distance above the pane's edge. Rows have a fixed height and a
-- panel shows a whole page of them, so no row is ever cut in half.
local CONTENT_HEIGHT = constants.gui_content_frame_height
local TILE_ROW_HEIGHT = 216
local SUBHEADER_HEIGHT = 28
local SPACING = 8
local PANEL_SPACING = 12
local PANEL_CAPTION_HEIGHT = 36
local COLUMN_HEADER_HEIGHT = 20
-- A deep frame is this much taller than its content, and its bottom border covers about as much of the content.
local FRAME_BORDER = 2
local ROW_HEIGHT = 32
local ICON_WIDTH = 28
local PANEL_AREA_HEIGHT = CONTENT_HEIGHT - TILE_ROW_HEIGHT - SUBHEADER_HEIGHT - 2 * SPACING
local PANEL_HEIGHT = math.floor((PANEL_AREA_HEIGHT - PANEL_SPACING) / 2)
local BODY_HEIGHT = PANEL_HEIGHT - FRAME_BORDER - PANEL_CAPTION_HEIGHT
local CAPACITY = math.floor((BODY_HEIGHT - COLUMN_HEADER_HEIGHT) / ROW_HEIGHT)
local ROWS_HEIGHT = CAPACITY * ROW_HEIGHT

local NO_VALUE = "–"
-- Matches the Stations status indicators and the Inventory legend so a status reads the same on every tab.
local STARVED_COLOR = "255,135,230"
local MAX_TOOLTIP_NETWORKS = 12

--- @class OverviewTileDef
--- @field name string
--- @field sprite string
--- @field lines string[]
--- @field tooltips {[string]: true}? lines that have a "-tooltip" locale key
--- @field colors {[string]: string}? rich-text colour for a line while its value is non-zero

--- @type OverviewTileDef[]
local TILES = {
	{
		name = "stations",
		sprite = "item/train-stop",
		lines = { "providers", "requesters", "networks", "warming_up", "faulty", "saturated", "starved" },
		tooltips = { faulty = true, saturated = true, starved = true },
		colors = { warming_up = "cyan", faulty = "red", saturated = "orange", starved = STARVED_COLOR },
	},
	{
		name = "fleet",
		sprite = "item/locomotive",
		lines = { "idle", "parked", "to_provider", "loading", "to_requester", "unloading", "returning", "refuelling", "alerts" },
		tooltips = { idle = true, alerts = true },
		colors = { alerts = "red" },
	},
	{
		name = "depots",
		sprite = "item/rail",
		lines = { "occupied", "empty", "available" },
		tooltips = { available = true },
	},
	{
		name = "demand",
		sprite = "item/cybersyn-combinator",
		lines = { "volume", "starved", "in_transit", "age_1m", "age_5m", "age_30m", "age_over" },
		tooltips = { volume = true, starved = true, in_transit = true },
		colors = { starved = STARVED_COLOR, age_30m = "orange", age_over = "red" },
	},
	{
		name = "flow",
		sprite = "item/cargo-wagon",
		lines = { "amount", "dispatches", "cycle", "wait_avg", "wait_max" },
		tooltips = { amount = true, dispatches = true, cycle = true, wait_avg = true, wait_max = true },
	},
}

local AGE_LINES = { "age_1m", "age_5m", "age_30m", "age_over" }
local WAIT_LINES = { "wait_avg", "wait_max" }

--- @class OverviewPanelDef
--- @field name string
--- @field scope "now"|"period"
--- @field subject "item"|"station"
--- @field limit int rows kept; more than CAPACITY scroll
--- @field columns {[1]: string, [2]: int}[] value columns: locale suffix and width
--- @field tracking true? shows a hint instead of rows while wait tracking is off
--- @field tracking_column int? value column that is hidden while wait tracking is off

--- @type OverviewPanelDef[][] two rows of three
local PANEL_ROWS = {
	{
		{ name = "starved", scope = "now", subject = "item", limit = 20, columns = { { "amount", 56 }, { "stations", 52 }, { "waiting", 60 } }, tracking_column = 3 },
		{ name = "waiting", scope = "now", subject = "station", limit = 20, columns = { { "amount", 56 }, { "waiting", 60 } }, tracking = true },
		{ name = "transit", scope = "now", subject = "item", limit = 20, columns = { { "amount", 56 }, { "stations", 52 } } },
	},
	{
		{ name = "delivered", scope = "period", subject = "item", limit = 20, columns = { { "amount", 56 }, { "rate", 60 } } },
		{ name = "slowest", scope = "period", subject = "station", limit = 60, columns = { { "waited", 60 }, { "when", 64 } }, tracking = true },
		{ name = "saturated", scope = "now", subject = "station", limit = 20, columns = { { "trains", 52 } } },
	},
}

local PANELS = {}
local LIMITS = {}
for _, row in ipairs(PANEL_ROWS) do
	for _, panel in ipairs(row) do
		PANELS[#PANELS + 1] = panel
		LIMITS[panel.name] = panel.limit
	end
end

--- @param player_data PlayerData
--- @return int minutes
local function get_period(player_data)
	local period = player_data.overview_period
	if period ~= 10 and period ~= 60 and period ~= 1440 then
		period = DEFAULT_PERIOD
		player_data.overview_period = period
	end
	return period
end

local function locale_key(prefix, name)
	return prefix .. string.gsub(name, "_", "-")
end

local short_duration = util.short_duration

local AMOUNT_UNITS = { { 1e9, " G" }, { 1e6, " M" }, { 1e3, " k" } }

--- Always one decimal from a thousand up ("3.0 M", "40.0 k"), so a right-aligned column lines up on the decimal
--- point; flib's abbreviation drops a trailing ".0".
--- @param count number
--- @return string
local function amount(count)
	local a = math.abs(count)
	for _, unit in ipairs(AMOUNT_UNITS) do
		-- Rounding to one decimal can carry into the next unit ("1000.0 k"), so compare the rounded value.
		if a >= unit[1] * 0.99995 then
			return string.format("%.1f%s", count / unit[1], unit[2])
		end
	end
	if a < 10 and count ~= math.floor(count) then
		return string.format("%.1f", count)
	end
	return string.format("%d", math.floor(count + 0.5))
end

local function tile_line_def(tile, line)
	local key = locale_key("cybersyn-gui.overview-" .. tile.name .. "-", line)
	local tooltip = tile.tooltips and tile.tooltips[line] and { key .. "-tooltip" } or nil
	local flow = {
		type = "flow",
		name = "overview_" .. tile.name .. "_" .. line .. "_flow",
		direction = "horizontal",
		style = "cybersyn_overview_line_flow",
		{
			type = "label",
			name = "overview_" .. tile.name .. "_" .. line .. "_label",
			style = "cybersyn_overview_line_label",
			caption = { key },
			tooltip = tooltip,
		},
		{ type = "empty-widget", style = "flib_horizontal_pusher" },
	}
	-- The bar sits in the value column, left of the percentage, so the right edge matches every other number.
	if tile.name == "fleet" and line == "idle" then
		flow[#flow + 1] = {
			type = "progressbar",
			name = "overview_fleet_idle_bar",
			style = "cybersyn_overview_idle_bar",
			value = 0,
			tooltip = tooltip,
		}
	end
	flow[#flow + 1] = {
		type = "label",
		name = "overview_" .. tile.name .. "_" .. line,
		style = "cybersyn_overview_line_value",
		caption = NO_VALUE,
		tooltip = tooltip,
	}
	return flow
end

--- @param tile OverviewTileDef
local function tile_def(tile)
	local body = {
		type = "flow",
		direction = "vertical",
		style = "cybersyn_overview_tile_body",
	}
	for _, line in ipairs(tile.lines) do
		body[#body + 1] = tile_line_def(tile, line)
	end
	return {
		type = "frame",
		name = "overview_tile_" .. tile.name,
		direction = "vertical",
		style = "cybersyn_overview_tile",
		{
			type = "frame",
			direction = "horizontal",
			style = "cybersyn_overview_tile_header",
			{
				type = "sprite",
				style = "cybersyn_overview_tile_icon",
				sprite = helpers.is_valid_sprite_path(tile.sprite) and tile.sprite or "utility/questionmark",
				resize_to_sprite = false,
			},
			{
				type = "label",
				name = "overview_tile_" .. tile.name .. "_caption",
				style = "subheader_caption_label",
				style_mods = { horizontally_squashable = true },
				caption = { "cybersyn-gui.overview-tile-" .. tile.name },
				tooltip = { "cybersyn-gui.overview-tile-" .. tile.name .. "-tooltip" },
			},
			{ type = "empty-widget", style = "flib_horizontal_pusher" },
			{
				type = "label",
				name = "overview_" .. tile.name .. "_headline",
				style = "cybersyn_overview_big_number",
				caption = NO_VALUE,
				tooltip = { "cybersyn-gui.overview-tile-" .. tile.name .. "-tooltip" },
			},
		},
		body,
	}
end

-- Wheel scrolling cannot snap to rows, so a panel pages by its capacity instead and never shows half a row.
--- @param panel string
--- @param action "prev"|"next"
--- @param caption string
local function pager_button(panel, action, caption)
	return {
		type = "button",
		name = "overview_" .. panel .. "_" .. action,
		style = "tool_button",
		caption = caption,
		tooltip = { "cybersyn-gui.overview-page-" .. action },
		visible = false,
		tags = { overview_panel = panel, step = action == "next" and 1 or -1 },
		handler = { [defines.events.on_gui_click] = overview_tab.handle.overview_page_click },
	}
end

--- @param panel OverviewPanelDef
--- @param panel OverviewPanelDef
--- @param skip int? value column left out
--- @return int
local function table_columns(panel, skip)
	return 2 + #panel.columns - (skip and 1 or 0)
end

--- @param panel OverviewPanelDef
--- @param skip int? value column left out; a table cannot hide a column, so it is built without it
local function table_def(panel, skip)
	local tbl = {
		type = "table",
		name = "overview_" .. panel.name .. "_table",
		style = "cybersyn_overview_table",
		column_count = table_columns(panel, skip),
		{ type = "empty-widget", style_mods = { width = ICON_WIDTH, height = COLUMN_HEADER_HEIGHT } },
		{
			type = "label",
			style = "cybersyn_overview_cell_header",
			style_mods = { horizontally_stretchable = true },
			caption = { "cybersyn-gui.overview-col-" .. panel.subject },
		},
	}
	for i, column in ipairs(panel.columns) do
		if i ~= skip then
			tbl[#tbl + 1] = {
				type = "label",
				style = "cybersyn_overview_cell_header_value",
				style_mods = { width = column[2] },
				caption = { "cybersyn-gui.overview-col-" .. column[1] },
				tooltip = { "cybersyn-gui.overview-col-" .. column[1] .. "-tooltip" },
			}
		end
	end
	return tbl
end

--- @param panel OverviewPanelDef
local function panel_def(panel)
	local name = panel.name
	local tbl = table_def(panel)
	return {
		type = "frame",
		name = "overview_panel_" .. name,
		direction = "vertical",
		style = "cybersyn_overview_panel",
		{
			type = "frame",
			direction = "horizontal",
			style = "cybersyn_overview_panel_header",
			{
				type = "label",
				name = "overview_" .. name .. "_caption",
				style = "subheader_caption_label",
				-- A small natural width that squashes, so a long caption is cut instead of making its panel wider than
				-- the other two.
				style_mods = { natural_width = 80, horizontally_squashable = true },
				caption = { "cybersyn-gui.overview-list-" .. name },
				tooltip = { "cybersyn-gui.overview-list-" .. name .. "-tooltip" },
			},
			{ type = "empty-widget", style = "flib_horizontal_pusher" },
			{
				type = "label",
				name = "overview_" .. name .. "_count",
				style = "cybersyn_overview_count_label",
			},
			pager_button(name, "prev", "‹"),
			pager_button(name, "next", "›"),
		},
		-- Never scrolls: it only keeps the table's natural width from widening its panel past the other two.
		{
			type = "scroll-pane",
			style = "cybersyn_overview_panel_body",
			style_mods = { height = BODY_HEIGHT },
			horizontal_scroll_policy = "never",
			vertical_scroll_policy = "never",
			tbl,
			{
				type = "flow",
				name = "overview_" .. name .. "_empty_flow",
				direction = "horizontal",
				style = "cybersyn_overview_empty_flow",
				visible = false,
				{
					type = "label",
					name = "overview_" .. name .. "_empty",
					style = "cybersyn_overview_empty_label",
					style_mods = { height = ROWS_HEIGHT },
					caption = { "cybersyn-gui.overview-empty-" .. name },
				},
			},
		},
	}
end

function overview_tab.create()
	local tiles = {
		type = "flow",
		direction = "horizontal",
		style = "cybersyn_overview_tile_row",
		style_mods = { height = TILE_ROW_HEIGHT },
	}
	for _, tile in ipairs(TILES) do
		tiles[#tiles + 1] = tile_def(tile)
	end

	local period_items = {}
	for i, minutes in ipairs(PERIODS) do
		period_items[i] = { "cybersyn-gui.overview-period-" .. minutes }
	end
	local default_index = 1
	for i, minutes in ipairs(PERIODS) do
		if minutes == DEFAULT_PERIOD then default_index = i end
	end

	local panels = {
		type = "flow",
		direction = "vertical",
		style = "cybersyn_overview_panels",
	}
	for _, row in ipairs(PANEL_ROWS) do
		local flow = {
			type = "flow",
			direction = "horizontal",
			style = "cybersyn_overview_panel_row",
		}
		for _, panel in ipairs(row) do
			flow[#flow + 1] = panel_def(panel)
		end
		panels[#panels + 1] = flow
	end

	return {
		tab = {
			name = "manager_overview_tab",
			type = "tab",
			caption = { "cybersyn-gui.overview" },
		},
		content = {
			name = "manager_overview_content_frame",
			type = "flow",
			direction = "vertical",
			style = "cybersyn_overview_content",
			style_mods = { minimal_height = CONTENT_HEIGHT },
			tiles,
			{
				type = "flow",
				direction = "horizontal",
				style = "cybersyn_overview_subheader",
				{
					type = "label",
					name = "overview_filter_note",
					style = "cybersyn_overview_filter_note",
					caption = "",
				},
				{ type = "empty-widget", style = "flib_horizontal_pusher" },
				{
					type = "label",
					name = "overview_period_note",
					style = "cybersyn_overview_filter_note",
					caption = "",
					tooltip = { "cybersyn-gui.overview-period-recorded-tooltip" },
					visible = false,
				},
				{
					type = "label",
					style = "bold_label",
					caption = { "cybersyn-gui.overview-period" },
					tooltip = { "cybersyn-gui.overview-period-tooltip" },
				},
				{
					type = "drop-down",
					name = "overview_period_dropdown",
					style = "cybersyn_overview_period_dropdown",
					items = period_items,
					selected_index = default_index,
					tooltip = { "cybersyn-gui.overview-period-tooltip" },
					handler = { [defines.events.on_gui_selection_state_changed] = overview_tab.handle.overview_period_changed },
				},
			},
			panels,
		},
	}
end

-- MODEL

--- Calls fn(network_name) for each network a station or train belongs to.
--- @param network_name string?
--- @param network_mask int|{[string]: int}?
local function each_network(network_name, network_mask, fn, a, b)
	if network_name == NETWORK_EACH then
		if type(network_mask) == "table" then
			for name in pairs(network_mask) do
				fn(name, a, b)
			end
		end
	elseif network_name then
		fn(network_name, a, b)
	end
end

--- @param st SnapshotStation
--- @param hash string
--- @param starved {[string]: true}
local function request_starved(st, hash, starved)
	local name = st.network_name
	if name == NETWORK_EACH then
		local mask = st.network_mask
		if type(mask) == "table" then
			for net in pairs(mask) do
				if starved[net .. ":" .. hash] then return true end
			end
		end
		return false
	end
	return name ~= nil and starved[name .. ":" .. hash] == true
end

--- Keeps `list` sorted by `less` and at most `k` long.
local function top_k_insert(list, k, row, less)
	local n = #list
	if n >= k then
		if not less(row, list[n]) then return end
		list[n] = nil
		n = n - 1
	end
	local i = n
	while i >= 1 and less(row, list[i]) do
		list[i + 1] = list[i]
		i = i - 1
	end
	list[i + 1] = row
end

local function waiting_less(a, b)
	if a.start ~= b.start then return a.start < b.start end
	if a.id ~= b.id then return a.id < b.id end
	return a.hash < b.hash
end

local STATUS_GROUP = {
	[STATUS_D] = "parked",
	[STATUS_TO_P] = "to_provider",
	[STATUS_P] = "loading",
	[STATUS_TO_R] = "to_requester",
	[STATUS_R] = "unloading",
	[STATUS_TO_D] = "returning",
	[STATUS_TO_D_BYPASS] = "returning",
	[STATUS_TO_F] = "refuelling",
	[STATUS_F] = "refuelling",
}

local function network_entry(networks, name)
	local n = networks[name]
	if not n then
		n = { p = 0, r = 0, trains = 0, available = 0 }
		networks[name] = n
	end
	return n
end

local function count_station_network(name, networks, st)
	local n = network_entry(networks, name)
	if st.is_p then n.p = n.p + 1 end
	if st.is_r then n.r = n.r + 1 end
end

local function count_train_network(name, networks, tr)
	local n = network_entry(networks, name)
	n.trains = n.trains + 1
	if tr.is_available then n.available = n.available + 1 end
end

--- Rows carry a tooltip builder instead of the tooltip: only the rows on screen whose sig changed ever build one.
--- @param hash string
--- @param tail fun(): LocalisedString[]
--- @return table? row partial row with sprite, quality, caption and tooltip builder; nil when the item has no sprite
local function item_row(hash, tail)
	local sprite, quality, name_tooltip = util.item_sprite_and_tooltip(hash)
	if not sprite then return nil end
	return {
		key = hash,
		sprite = sprite,
		quality = quality,
		caption = name_tooltip[4],
		tooltip = function()
			local tooltip = { "", name_tooltip }
			for _, part in ipairs(tail()) do
				tooltip[#tooltip + 1] = part
			end
			tooltip[#tooltip + 1] = "\n"
			tooltip[#tooltip + 1] = { "cybersyn-gui.item-click-hint" }
			return tooltip
		end,
		tags = { kind = "item", item_hash = hash },
	}
end

local MAX_NAME_ICONS = 2
local SEPARATORS = "[%s/|,%-]*"

--- Station names often start with a run of icons. A squashed label cuts from the right, so the readable text after
--- the icons would be lost first; keep at most MAX_NAME_ICONS of them (the tooltip has the full name).
--- @param name string
--- @return string
local function display_name(name)
	if string.sub(name, 1, 1) ~= "[" then return name end
	local pos, icons, keep_end = 1, 0, nil
	while true do
		local s, e = string.find(name, "^" .. SEPARATORS .. "%[[%w%-]+=[^%]]*%]", pos)
		if not s then break end
		icons = icons + 1
		if icons == MAX_NAME_ICONS then keep_end = e end
		pos = e + 1
	end
	if icons <= MAX_NAME_ICONS then return name end
	local rest = string.gsub(string.sub(name, pos), "^" .. SEPARATORS, "")
	return string.sub(name, 1, keep_end) .. "… " .. rest
end

--- @param st SnapshotStation
--- @param key string|number
--- @param sprite string?
--- @param quality string?
--- @param tail fun(): LocalisedString[]
local function station_row(st, key, sprite, quality, tail)
	local name = st.name
	local caption = display_name(name)
	return {
		key = key,
		sprite = sprite or "item/train-stop",
		quality = quality,
		caption = caption,
		name_sig = caption,
		tooltip = function()
			local tooltip = { "", "[font=default-semibold]", name, "[/font]" }
			for _, part in ipairs(tail()) do
				tooltip[#tooltip + 1] = part
			end
			tooltip[#tooltip + 1] = "\n"
			tooltip[#tooltip + 1] = constants.open_station_gui_tooltip
			return tooltip
		end,
		tags = { kind = "station", station_id = st.id },
	}
end

--- The item a saturated station's trains are busy with: its largest delivery, in or out.
--- @param st SnapshotStation
--- @return string?
local function main_delivery_hash(st)
	local best, best_count
	for hash, count in pairs(st.deliveries) do
		local a = math.abs(count)
		if a > 0 and (not best_count or a > best_count or (a == best_count and hash < best)) then
			best, best_count = hash, a
		end
	end
	return best
end

-- Walking every snapshot station costs about 3 ms on a 2,000-station base, so after a completed pass the new figures
-- are built over several updates, this many stations at a time, while the previous ones stay on screen.
local BASE_CHUNK = 500

--- Filters and tracking: a change of these is the player's own action and is shown at once.
--- @param f table
--- @param tracking boolean
--- @return string
local function view_key(f, tracking)
	return table.concat({
		tracking and "t" or "", f.terms and table.concat(f.terms, " ") or "", f.network or "", tostring(f.mask),
		tostring(f.surface or ""),
	}, "\1")
end

--- @param snapshot Snapshot
--- @return string
local function data_key(snapshot)
	return tostring(snapshot.tick) .. "\1" .. tostring(snapshot.pass) .. "\1" .. tostring(snapshot.starved_version)
end

--- Accumulator of the snapshot-derived figures; wait ages are kept as start ticks so it does not depend on the tick.
--- @param snapshot Snapshot
--- @param filtered boolean
--- @return table
local function new_base(snapshot, filtered)
	local ids = {}
	for id in pairs(snapshot.stations) do
		ids[#ids + 1] = id
	end
	table.sort(ids)
	return {
		ids = ids,
		i = 0,
		st_tile = { total = 0, providers = 0, requesters = 0, warming_up = 0, faulty = 0, starved = 0 },
		demand = { total = 0, volume = 0, starved = 0, in_transit = 0 },
		wait_starts = {},
		starved_items = {},
		waiting = {},
		waiting_total = 0,
		transit = filtered and {} or nil,
		networks = {},
	}
end

--- @param base table
--- @param st SnapshotStation
--- @param tracking boolean
--- @param starved_set {[string]: true}
--- @param starved_items_set {[string]: true}
local function add_station(base, st, tracking, starved_set, starved_items_set)
	local st_tile, demand = base.st_tile, base.demand
	st_tile.total = st_tile.total + 1
	if st.is_p then st_tile.providers = st_tile.providers + 1 end
	if st.is_r then st_tile.requesters = st_tile.requesters + 1 end
	if st.warming_up then st_tile.warming_up = st_tile.warming_up + 1 end
	if not st.comb_ok then st_tile.faulty = st_tile.faulty + 1 end
	each_network(st.network_name, st.network_mask, count_station_network, base.networks, st)

	local deliveries = st.deliveries
	local wait = st.wait
	local any_starved = false
	for hash, req in pairs(st.requested) do
		if req.active then
			local volume = -req.count
			demand.total = demand.total + 1
			demand.volume = demand.volume + volume
			local incoming = deliveries[hash]
			if incoming and incoming > 0 then demand.in_transit = demand.in_transit + 1 end
			local start = tracking and wait[hash] or nil
			if start then
				base.wait_starts[#base.wait_starts + 1] = start
				base.waiting_total = base.waiting_total + 1
				top_k_insert(base.waiting, LIMITS.waiting, { start = start, id = st.id, hash = hash, count = volume, st = st }, waiting_less)
			end
			-- The per-item set rejects almost every request without building a "network:item" key.
			if starved_items_set[hash] and request_starved(st, hash, starved_set) then
				any_starved = true
				demand.starved = demand.starved + 1
				local agg = base.starved_items[hash]
				if agg then
					agg.count = agg.count + volume
					agg.stations = agg.stations + 1
					if start and (not agg.earliest or start < agg.earliest) then agg.earliest = start end
				else
					base.starved_items[hash] = { count = volume, stations = 1, earliest = start }
				end
			end
		end
	end
	if any_starved then st_tile.starved = st_tile.starved + 1 end

	local transit = base.transit
	if transit then
		for hash, count in pairs(deliveries) do
			if count > 0 then
				local agg = transit[hash]
				if agg then
					agg.count = agg.count + count
					agg.stations = agg.stations + 1
				else
					transit[hash] = { count = count, stations = 1 }
				end
			end
		end
	end
end

--- Trains, depots and the sorted lists, once every station has been added.
--- @param base table
--- @param snapshot Snapshot
--- @param f table
--- @param filtered boolean
local function finish_base(base, snapshot, f, filtered)
	local networks = base.networks
	for _, tr in pairs(snapshot.trains) do
		if not filtered or util.train_passes(tr, f, true) then
			each_network(tr.network_name, tr.network_mask, count_train_network, networks, tr)
		end
	end

	local network_names = {}
	for name in pairs(networks) do
		if not f.network or f.network == name then
			network_names[#network_names + 1] = name
		end
	end
	util.sort_by(network_names, function(name)
		local n = networks[name]
		return n.p + n.r
	end, false, function(name) return name end)
	base.network_names = network_names
	local st_tile = base.st_tile
	st_tile.networks = #network_names

	local depots = snapshot.depots
	base.depot_tile = {
		total = depots.total,
		occupied = depots.parked,
		empty = depots.total - depots.parked,
	}

	-- Oldest wait first, then the largest shortfall.
	local starved_items = base.starved_items
	local starved_hashes = {}
	for hash, agg in pairs(starved_items) do
		starved_hashes[#starved_hashes + 1] = hash
		agg.tiebreak = string.format("%020.0f|%s", 1e15 - math.min(agg.count, 1e15 - 1), hash)
	end
	util.sort_by(starved_hashes, function(hash)
		local agg = starved_items[hash]
		return agg.earliest or (1e12 - agg.count)
	end, true, function(hash) return starved_items[hash].tiebreak end)
	base.starved_hashes = starved_hashes

	local transit = base.transit or snapshot.inventory_all.in_transit
	base.transit = transit
	local transit_hashes = {}
	for hash in pairs(transit) do
		transit_hashes[#transit_hashes + 1] = hash
	end
	util.sort_by(transit_hashes, function(hash) return transit[hash].count end, false, function(hash) return hash end)
	base.transit_hashes = transit_hashes


	st_tile.headline = st_tile.total
	base.depot_tile.headline = base.depot_tile.total
	base.demand.headline = base.demand.total
	base.ids = nil
	base.i = nil
end

--- Adds up to `budget` more stations to a base under construction; true once it is complete.
--- @return boolean
local function advance_base(base, snapshot, f, filtered, tracking, budget)
	local stations = snapshot.stations
	local starved_set, starved_items_set = snapshot.starved, snapshot.starved_items
	local ids = base.ids
	local n = #ids
	local i = base.i
	local stop = math.min(n, i + budget)
	while i < stop do
		i = i + 1
		local st = stations[ids[i]]
		if st and (not filtered or util.station_passes(st, f, true)) then
			add_station(base, st, tracking, starved_set, starved_items_set)
		end
	end
	base.i = i
	if i < n then return false end
	finish_base(base, snapshot, f, filtered)
	return true
end

--- Fleet figures from the trains the Trains tab shows right now. The collector refreshes trains at the start of a pass
--- and the station figures build over several updates after its end, so the fleet is kept apart from them: the Fleet
--- tile and the Trains tab always count the same trains.
--- @param snapshot Snapshot
--- @param f table
--- @param filtered boolean
--- @return table fleet
--- @return integer available trains available for dispatch, unfiltered like the rest of the Depots tile
local function fleet_model(snapshot, f, filtered)
	local fleet = { total = 0, parked = 0, to_provider = 0, loading = 0, to_requester = 0, unloading = 0, returning = 0, refuelling = 0, other = 0, alerts = 0 }
	local available = 0
	local train_passes = {}
	for id, tr in pairs(snapshot.trains) do
		if tr.is_available then available = available + 1 end
		if not filtered or util.train_passes(tr, f, true) then
			train_passes[id] = true
			fleet.total = fleet.total + 1
			local group = STATUS_GROUP[tr.status or STATUS_D] or "other"
			fleet[group] = fleet[group] + 1
		end
	end
	fleet.idle = fleet.total > 0 and fleet.parked / fleet.total or nil
	for _, alert in ipairs(snapshot.alerts) do
		if not filtered or train_passes[alert.train_id] then
			fleet.alerts = fleet.alerts + 1
		end
	end
	fleet.headline = fleet.total
	return fleet, available
end

--- Saturated stations from the records as they are now, like the Stations chip: the collector refills records in place
--- and sets their status, so a figure kept from the last completed pass would disagree with the chip within a pass.
--- Only saturated records reach the filter, so this stays cheap on large bases.
--- @param snapshot Snapshot
--- @param f table
--- @param filtered boolean
--- @return SnapshotStation[] top the LIMITS.saturated busiest, most deliveries first
--- @return integer total
local function live_saturated(snapshot, f, filtered)
	local list = {}
	-- The first pass after opening is still filling records; every other figure waits for it too.
	if not snapshot.tick then return list, 0 end
	for _, st in pairs(snapshot.stations) do
		if st.status == "saturated" and (not filtered or util.station_passes(st, f, true)) then
			list[#list + 1] = st
		end
	end
	local total = #list
	util.sort_by(list, function(st) return st.deliveries_total end, false, function(st) return st.id end)
	for i = LIMITS.saturated + 1, total do
		list[i] = nil
	end
	return list, total
end

--- @param player_data PlayerData
--- @param snapshot Snapshot
--- @param f table
--- @param filtered boolean
--- @param vkey string
local function cached_fleet(player_data, snapshot, f, filtered, vkey)
	local cache = player_data.overview_cache
	local key = tostring(snapshot.trains_version) .. "\1" .. vkey
	if cache.fleet_key ~= key then
		cache.fleet, cache.available = fleet_model(snapshot, f, filtered)
		cache.fleet_key = key
	end
	return cache.fleet, cache.available
end

--- The snapshot-derived figures for the player's filters. Kept in player_data, not in a Lua local, so every peer
--- shows the same figures.
--- @param player_data PlayerData
--- @param snapshot Snapshot
--- @param f table
--- @param filtered boolean
--- @param tracking boolean
--- @return table
local function cached_snapshot_model(player_data, snapshot, f, filtered, tracking)
	local vkey, dkey = view_key(f, tracking), data_key(snapshot)
	local cache = player_data.overview_cache
	if not cache or cache.view_key ~= vkey then
		local base = new_base(snapshot, filtered)
		advance_base(base, snapshot, f, filtered, tracking, math.huge)
		player_data.overview_cache = { view_key = vkey, data_key = dkey, base = base, empty = snapshot.tick == nil or nil }
		return base
	end
	if cache.data_key ~= dkey then
		local build = cache.build
		if not build then
			build = new_base(snapshot, filtered)
			build.data_key = dkey
			cache.build = build
		end
		-- Figures from before the first completed pass are all zero: nothing worth keeping on screen meanwhile.
		local budget = cache.empty and math.huge or BASE_CHUNK
		if advance_base(build, snapshot, f, filtered, tracking, budget) then
			cache.empty = nil
			cache.base = build
			cache.data_key = build.data_key
			build.data_key = nil
			cache.build = nil
		end
	end
	return cache.base
end

--- Everything the tab shows, from the snapshot and storage.stats only, with every list already sorted and cut.
--- @param player_data PlayerData
--- @return table
function overview_tab.model(player_data)
	local snapshot = collector.get()
	local f = util.get_filters(player_data)
	local filtered = util.filters_active(f, true)
	local now = game.tick
	local period = get_period(player_data)
	-- The planner reads its cached copy, so this matches what is actually being tracked.
	local tracking = mod_settings.track_request_wait_times == true
	local base = cached_snapshot_model(player_data, snapshot, f, filtered, tracking)
	local fleet, available = cached_fleet(player_data, snapshot, f, filtered, view_key(f, tracking))
	local depot_tile = {}
	for k, v in pairs(base.depot_tile) do
		depot_tile[k] = v
	end
	depot_tile.available = available
	local saturated, saturated_total = live_saturated(snapshot, f, filtered)
	local st_tile = {}
	for k, v in pairs(base.st_tile) do
		st_tile[k] = v
	end
	st_tile.saturated = saturated_total

	local demand = {}
	for k, v in pairs(base.demand) do
		demand[k] = v
	end
	if tracking then
		local a1, a5, a30, over = 0, 0, 0, 0
		for _, start in ipairs(base.wait_starts) do
			local age = now - start
			if age < 3600 then
				a1 = a1 + 1
			elseif age < 18000 then
				a5 = a5 + 1
			elseif age < 108000 then
				a30 = a30 + 1
			else
				over = over + 1
			end
		end
		demand.age_1m, demand.age_5m, demand.age_30m, demand.age_over = a1, a5, a30, over
	end

	local window = stats.aggregate(period)
	local flow = {
		headline = window.deliveries,
		amount = window.amount,
		dispatches = window.dispatches,
		cycle = window.cycle_avg and window.cycle_avg * 60 or nil,
		wait_avg = tracking and window.wait_avg or nil,
		wait_max = tracking and window.wait_max or nil,
	}

	local lists = {}

	-- Rows (and their tooltips) are built for the kept top only.
	local starved_items = base.starved_items
	local starved_rows = {}
	for _, hash in ipairs(base.starved_hashes) do
		if #starved_rows >= LIMITS.starved then break end
		local agg = starved_items[hash]
		local row = item_row(hash, function()
			local tail = {
				"\n", { "cybersyn-gui.requested-by-stations", tostring(agg.stations) },
				"\n", { "cybersyn-gui.amount", format.number(agg.count) },
				"\n[color=red]", { "cybersyn-gui.overview-no-provider" }, "[/color]",
			}
			if agg.earliest then
				tail[#tail + 1] = "\n"
				tail[#tail + 1] = { "cybersyn-gui.waiting-for", util.format_duration(now - agg.earliest) }
			end
			return tail
		end)
		if row then
			row.order = agg.earliest or (1e12 - agg.count)
			row.values = { amount(agg.count), tostring(agg.stations), agg.earliest and short_duration(now - agg.earliest) or NO_VALUE }
			starved_rows[#starved_rows + 1] = row
		end
	end
	lists.starved = { rows = starved_rows, total = #base.starved_hashes }

	local waiting_rows = {}
	for i, w in ipairs(base.waiting) do
		local sprite, quality, name_tooltip = util.item_sprite_and_tooltip(w.hash)
		local row = station_row(w.st, w.id .. "|" .. w.hash, sprite, quality, function()
			return {
				"\n", name_tooltip or w.hash,
				"\n", { "cybersyn-gui.amount", format.number(w.count) },
				"\n", { "cybersyn-gui.waiting-for", util.format_duration(now - w.start) },
			}
		end)
		row.order = w.start
		row.values = { amount(w.count), short_duration(now - w.start) }
		waiting_rows[i] = row
	end
	lists.waiting = { rows = waiting_rows, total = base.waiting_total, disabled = not tracking }

	local transit = base.transit
	local transit_rows = {}
	for _, hash in ipairs(base.transit_hashes) do
		if #transit_rows >= LIMITS.transit then break end
		local agg = transit[hash]
		local row = item_row(hash, function()
			return {
				"\n", { "cybersyn-gui.in-transit-to-stations", tostring(agg.stations) },
				"\n", { "cybersyn-gui.amount", format.number(agg.count) },
			}
		end)
		if row then
			row.order = agg.count
			row.values = { amount(agg.count), tostring(agg.stations) }
			transit_rows[#transit_rows + 1] = row
		end
	end
	lists.transit = { rows = transit_rows, total = #base.transit_hashes }

	local period_caption = { "cybersyn-gui.overview-scope-" .. period }
	local delivered_items = window.items
	local span_minutes = math.max(window.span_ticks / 3600, 1)
	local delivered_hashes = {}
	for hash in pairs(delivered_items) do
		delivered_hashes[#delivered_hashes + 1] = hash
	end
	util.sort_by(delivered_hashes, function(hash) return delivered_items[hash] end, false, function(hash) return hash end)
	local delivered_rows = {}
	for _, hash in ipairs(delivered_hashes) do
		if #delivered_rows >= LIMITS.delivered then break end
		local count = delivered_items[hash]
		local rate = amount(count / span_minutes)
		local row = item_row(hash, function()
			return {
				"\n", { "cybersyn-gui.overview-delivered-amount", period_caption, format.number(count) },
				"\n", { "cybersyn-gui.overview-delivered-rate", rate },
			}
		end)
		if row then
			row.order = count
			row.value_sig = period
			row.values = { amount(count), rate }
			delivered_rows[#delivered_rows + 1] = row
		end
	end
	lists.delivered = { rows = delivered_rows, total = #delivered_hashes }

	-- One row per stats bucket: its slowest fulfilled request. Unfiltered, like every period figure.
	local slowest_rows = {}
	local slowest = {}
	if tracking then
		for i, b in ipairs(window.slowest) do
			slowest[i] = b
		end
		util.sort_by(slowest, function(b) return b.wait_max end, false, function(b) return -b.start_tick end)
		local minute_buckets = window.slowest_minutes
		for i = 1, math.min(#slowest, LIMITS.slowest) do
			local b = slowest[i]
			local hash = b.wait_max_hash
			local sprite, quality, name_tooltip
			if hash then sprite, quality, name_tooltip = util.item_sprite_and_tooltip(hash) end
			-- Buckets recorded before wait_max_tick existed only know their start, so their age is a lower bound.
			local age = now - (b.wait_max_tick or b.start_tick)
			local when, when_sig
			if age < stats.MINUTE then
				when, when_sig = { "cybersyn-gui.overview-this-minute" }, "now"
			elseif age < stats.HOUR then
				local m = math.floor(age / stats.MINUTE)
				when, when_sig = { "cybersyn-gui.overview-minutes-ago", tostring(m) }, "m" .. m
			else
				local h = math.floor(age / stats.HOUR)
				when, when_sig = { "cybersyn-gui.overview-hours-ago", tostring(h) }, "h" .. h
			end
			local bucket_key = (period <= 60 or minute_buckets[b]) and "cybersyn-gui.overview-slowest-minute" or "cybersyn-gui.overview-slowest-hour"
			local function tail()
				return {
					"\n", name_tooltip or { "cybersyn-gui.overview-unknown-item" },
					"\n", { "cybersyn-gui.overview-slowest-row", util.format_duration(b.wait_max) },
					"\n", { bucket_key, tostring(b.wait_n), util.format_duration(b.wait_sum / b.wait_n) },
				}
			end
			-- A bucket's maximum moves to another station or item as requests are fulfilled, and the update path keeps
			-- a row's icon and tags, so the key must change with them.
			local key = b.start_tick .. "|" .. tostring(b.wait_max_station) .. "|" .. tostring(hash)
			local st = snapshot.stations[b.wait_max_station]
			local row
			if st then
				row = station_row(st, key, sprite, quality, tail)
			else
				row = {
					key = key,
					sprite = sprite or "utility/questionmark",
					quality = quality,
					caption = { "cybersyn-gui.overview-removed-station" },
					name_sig = "",
					tooltip = function()
						local tooltip = { "", { "cybersyn-gui.overview-removed-station" } }
						for _, part in ipairs(tail()) do
							tooltip[#tooltip + 1] = part
						end
						return tooltip
					end,
					tags = { kind = "none" },
				}
			end
			row.order = b.wait_max
			row.values = { short_duration(b.wait_max), when }
			row.value_sig = when_sig .. ":" .. b.wait_n
			slowest_rows[i] = row
		end
	end
	lists.slowest = { rows = slowest_rows, total = #slowest, disabled = not tracking }

	local saturated_rows = {}
	for i, st in ipairs(saturated) do
		local hash = main_delivery_hash(st)
		local sprite, quality
		if hash then sprite, quality = util.item_sprite_and_tooltip(hash) end
		local deliveries, limit = st.deliveries_total, st.trains_limit
		local row = station_row(st, st.id .. "|" .. tostring(hash), sprite, quality, function()
			return { "\n", { "cybersyn-gui.overview-saturated-row", tostring(deliveries), tostring(limit) } }
		end)
		row.order = st.deliveries_total
		row.values = { st.deliveries_total .. "/" .. st.trains_limit }
		saturated_rows[i] = row
	end
	lists.saturated = { rows = saturated_rows, total = saturated_total }

	return {
		snapshot_tick = snapshot.tick,
		recorded_ticks = window.partial and window.span_ticks or nil,
		filtered = filtered,
		item_filter = f.item,
		tracking = tracking,
		period = period,
		networks = base.networks,
		network_names = base.network_names,
		tiles = {
			stations = st_tile,
			fleet = fleet,
			depots = depot_tile,
			demand = demand,
			flow = flow,
		},
		lists = lists,
	}
end

-- RENDER

local function set_caption(elem, caption)
	if elem and elem.valid and elem.caption ~= caption then
		elem.caption = caption
	end
end

--- Captions and tooltips that are LocalisedStrings cannot be compared with the element's, so the last plain-string
--- signature written is kept per player and element, and the assignment skipped while it is unchanged.
--- @param cache table
--- @param elem LuaGuiElement?
--- @param sig string
--- @param caption LocalisedString
local function set_caption_sig(cache, elem, sig, caption)
	if not (elem and elem.valid) then return end
	local name = elem.name
	if cache[name] == sig then return end
	cache[name] = sig
	elem.caption = caption
end

--- @param cache table
--- @param elems (LuaGuiElement?)[]
--- @param sig string
--- @param tooltip LocalisedString
local function set_tooltip_sig(cache, elems, sig, tooltip)
	for _, elem in ipairs(elems) do
		if elem and elem.valid then
			local key = elem.name .. "#tooltip"
			if cache[key] ~= sig then
				cache[key] = sig
				elem.tooltip = tooltip
			end
		end
	end
end

--- @param player_data PlayerData
--- @return table
local function caption_cache(player_data)
	local state = util.gui_state(player_data, "overview_captions")
	state.captions = state.captions or {}
	return state.captions
end

local function format_line(tile, line, value)
	if value == nil then return NO_VALUE end
	if tile == "flow" then
		if line == "cycle" or line == "wait_avg" or line == "wait_max" then return short_duration(value) end
		if line == "amount" then return amount(value) end
	elseif tile == "demand" and line == "volume" then
		return amount(value)
	elseif tile == "fleet" and line == "idle" then
		return string.format("%d%%", math.floor(value * 100 + 0.5))
	end
	return format.number(value)
end

--- @param model table
--- @return string
local function networks_sig(model)
	local sig = {}
	for i, name in ipairs(model.network_names) do
		local n = model.networks[name]
		sig[i] = name .. ":" .. n.p .. ":" .. n.r .. ":" .. n.trains .. ":" .. n.available
	end
	return table.concat(sig, "|")
end

--- @param model table
--- @return LocalisedString
local function networks_tooltip(model)
	local names, networks = model.network_names, model.networks
	local tooltip = { "", { "cybersyn-gui.overview-stations-networks-tooltip" } }
	for i = 1, math.min(#names, MAX_TOOLTIP_NETWORKS) do
		local name = names[i]
		local n = networks[name]
		local _, image, localised = util.generate_item_references(name)
		tooltip[#tooltip + 1] = {
			"", "\n", image ~= "" and image or "", " ", localised or name, ": ",
			{ "cybersyn-gui.overview-network-row", tostring(n.p), tostring(n.r), tostring(n.trains), tostring(n.available) },
		}
	end
	if #names > MAX_TOOLTIP_NETWORKS then
		tooltip[#tooltip + 1] = { "", "\n", { "cybersyn-gui.overview-more-networks", tostring(#names - MAX_TOOLTIP_NETWORKS) } }
	end
	return tooltip
end

--- @param player_data PlayerData
--- @param model table
local function render_tiles(player_data, model)
	local refs = player_data.refs
	local cache = caption_cache(player_data)
	local tracking = model.tracking
	for _, tile in ipairs(TILES) do
		local values = model.tiles[tile.name]
		set_caption(refs["overview_" .. tile.name .. "_headline"], format.number(values.headline or 0))
		local colors = tile.colors
		for _, line in ipairs(tile.lines) do
			local value = values[line]
			local caption = format_line(tile.name, line, value)
			local color = colors and colors[line]
			if color and value and value > 0 then
				caption = "[color=" .. color .. "]" .. caption .. "[/color]"
			end
			set_caption(refs["overview_" .. tile.name .. "_" .. line], caption)
		end
	end

	local idle = model.tiles.fleet.idle
	local bar = refs.overview_fleet_idle_bar
	if bar and bar.valid then
		local value = idle or 0
		if bar.value ~= value then bar.value = value end
	end

	local period = model.period
	-- The short scope keeps the caption whole at the fixed tile width.
	set_caption_sig(cache, refs.overview_tile_flow_caption, tostring(period),
		{ "", { "cybersyn-gui.overview-tile-flow" }, " · ", { "cybersyn-gui.overview-scope-short-" .. period } })

	-- The two wait panels already explain how to turn tracking on, so the tile only shows "–" with the hint as tooltip.
	for _, line in ipairs(AGE_LINES) do
		set_tooltip_sig(cache, { refs["overview_demand_" .. line .. "_label"], refs["overview_demand_" .. line] },
			tracking and "on" or "off", tracking and "" or { "cybersyn-gui.overview-demand-age-off" })
	end

	for _, line in ipairs(WAIT_LINES) do
		local key = "cybersyn-gui.overview-flow-" .. string.gsub(line, "_", "-")
		set_tooltip_sig(cache, { refs["overview_flow_" .. line .. "_label"], refs["overview_flow_" .. line] },
			tracking and "on" or "off", tracking and { key .. "-tooltip" } or { "cybersyn-gui.overview-flow-wait-off" })
	end

	local net_sig = networks_sig(model)
	local net_label = refs.overview_stations_networks_label
	if net_label and net_label.valid and cache[net_label.name .. "#tooltip"] ~= net_sig then
		set_tooltip_sig(cache, { net_label, refs.overview_stations_networks }, net_sig, networks_tooltip(model))
	end

	local recorded = model.recorded_ticks
	local period_note = refs.overview_period_note
	if period_note and period_note.valid then
		local show = recorded ~= nil
		if period_note.visible ~= show then period_note.visible = show end
		if show then
			local text = short_duration(recorded)
			set_caption_sig(cache, period_note, text, { "cybersyn-gui.overview-period-recorded", text })
		end
	end

	local dropdown = refs.overview_period_dropdown
	if dropdown and dropdown.valid then
		for i, minutes in ipairs(PERIODS) do
			if minutes == period and dropdown.selected_index ~= i then dropdown.selected_index = i end
		end
	end

	-- The tab deliberately ignores the item filter, so say so; otherwise a shift-click on an item row looks like a no-op.
	local note_sig = (model.filtered and "f" or "") .. (model.item_filter and "i" or "")
	local note_caption = ""
	if model.filtered and model.item_filter then
		note_caption = { "", { "cybersyn-gui.overview-filtered" }, " ", { "cybersyn-gui.overview-item-filter-ignored" } }
	elseif model.filtered then
		note_caption = { "cybersyn-gui.overview-filtered" }
	elseif model.item_filter then
		note_caption = { "", "[img=info] ", { "cybersyn-gui.overview-item-filter-ignored" } }
	end
	set_caption_sig(cache, refs.overview_filter_note, note_sig, note_caption)
	set_tooltip_sig(cache, { refs.overview_filter_note }, note_sig, note_caption)
end

--- @param scope string
--- @param row table
--- @param columns {[1]: string, [2]: int}[]
--- @param skip int? value column left out
local function row_entry(scope, row, columns, skip)
	local values = row.values
	local sig_parts = {}
	for i = 1, #columns do
		local v = values[i]
		sig_parts[i] = type(v) == "string" and v or ""
	end
	local sig = table.concat(sig_parts, "|") .. "|" .. tostring(row.value_sig or "") .. "|" .. tostring(row.name_sig or "")
		.. "|" .. tostring(skip or "")
	local tooltip
	local function tip()
		tooltip = tooltip or row.tooltip()
		return tooltip
	end
	return {
		key = row.key,
		sig = sig,
		build = function()
			local handler = { [defines.events.on_gui_click] = overview_tab.handle.overview_row_click }
			local cells = {
				util.hoverable({
					type = "sprite-button",
					style = "cybersyn_overview_cell_icon",
					sprite = row.sprite,
					quality = row.quality,
					tooltip = tip(),
					tags = row.tags,
					handler = handler,
				}, scope),
				util.hoverable({
					type = "label",
					style = "cybersyn_overview_cell_name",
					caption = row.caption,
					tooltip = tip(),
					tags = row.tags,
					handler = handler,
				}, scope),
			}
			for i, column in ipairs(columns) do
				if i ~= skip then
					cells[#cells + 1] = util.hoverable({
						type = "label",
						style = "cybersyn_overview_cell_value",
						style_mods = { width = column[2] },
						caption = values[i] or "",
						tooltip = tip(),
						tags = row.tags,
						handler = handler,
					}, scope)
				end
			end
			return cells
		end,
		update = function(cells)
			local t = tip()
			for _, cell in ipairs(cells) do
				cell.tooltip = t
			end
			if row.name_sig then set_caption(cells[2], row.caption) end
			local c = 2
			for i = 1, #columns do
				if i ~= skip then
					c = c + 1
					local cell = cells[c]
					if cell then
						local v = values[i] or ""
						if type(v) == "string" then
							set_caption(cell, v)
						else
							cell.caption = v
						end
					end
				end
			end
		end,
	}
end

--- @param player_data PlayerData
--- @param name string
--- @param rows int
--- @return int offset first row shown, minus one
local function panel_offset(player_data, name, rows)
	local offsets = player_data.overview_offsets
	local offset = offsets and offsets[name] or 0
	local last_page = math.max(math.ceil(rows / CAPACITY) - 1, 0) * CAPACITY
	if offset > last_page then offset = last_page end
	if offset < 0 then offset = 0 end
	if offsets and offsets[name] ~= offset then offsets[name] = offset end
	return offset
end

--- @param player_data PlayerData
--- @param model table
local function render_panels(player_data, model)
	local refs = player_data.refs
	local cache = caption_cache(player_data)
	local period = model.period
	for _, panel in ipairs(PANELS) do
		local name = panel.name
		local data = model.lists[name]
		local tbl = refs["overview_" .. name .. "_table"]
		if tbl and tbl.valid then
			local scope = tbl.name
			local disabled = data.disabled == true
			local skip = panel.tracking_column and not model.tracking and panel.tracking_column or nil
			if tbl.column_count ~= table_columns(panel, skip) then
				local parent, index = tbl.parent, tbl.get_index_in_parent()
				tbl.destroy()
				local def = table_def(panel, skip)
				def.index = index
				tbl = gui.add(parent, def)[scope]
				refs[scope] = tbl
				local state = util.gui_state(player_data, scope)
				state.keys, state.sigs = nil, nil
			end
			if tbl.visible == disabled then tbl.visible = not disabled end

			local rows = data.rows
			local n = #rows
			local offset = panel_offset(player_data, name, n)
			local entries = {}
			for i = offset + 1, math.min(offset + CAPACITY, n) do
				entries[#entries + 1] = row_entry(scope, rows[i], panel.columns, skip)
			end
			local columns = table_columns(panel, skip)
			util.sync_table_rows(tbl, columns, columns, entries, util.gui_state(player_data, scope), util.hold_active(player_data, scope))

			local paged = not disabled and n > CAPACITY
			local prev, next = refs["overview_" .. name .. "_prev"], refs["overview_" .. name .. "_next"]
			if prev and prev.valid and next and next.valid then
				if prev.visible ~= paged then prev.visible = paged end
				if next.visible ~= paged then next.visible = paged end
				local back, forward = offset > 0, offset + CAPACITY < n
				if prev.enabled ~= back then prev.enabled = back end
				if next.enabled ~= forward then next.enabled = forward end
			end

			local empty = refs["overview_" .. name .. "_empty"]
			local empty_flow = refs["overview_" .. name .. "_empty_flow"]
			if empty and empty.valid and empty_flow and empty_flow.valid then
				local show = disabled or n == 0
				if empty_flow.visible ~= show then empty_flow.visible = show end
				if show then
					local sig = disabled and "off" or ("empty" .. period)
					if cache[empty.name] ~= sig then
						empty.style.height = disabled and COLUMN_HEADER_HEIGHT + ROWS_HEIGHT or ROWS_HEIGHT
					end
					set_caption_sig(cache, empty, sig, disabled and { "cybersyn-gui.overview-empty-" .. name .. "-disabled" }
						or { "cybersyn-gui.overview-empty-" .. name, { "cybersyn-gui.overview-scope-" .. period } })
				end
			end

			local caption_sig = panel.scope == "now" and "now" or tostring(period)
			set_caption_sig(cache, refs["overview_" .. name .. "_caption"], caption_sig, {
				"", { "cybersyn-gui.overview-list-" .. name }, " · ",
				{ panel.scope == "now" and "cybersyn-gui.overview-scope-now" or "cybersyn-gui.overview-scope-" .. period },
			})

			local count = refs["overview_" .. name .. "_count"]
			if disabled then
				set_caption_sig(cache, count, "", "")
			else
				local total = format.number(data.total)
				-- One form whether or not the panel pages, so every caption reads the same.
				if n == 0 then
					set_caption_sig(cache, count, "", "")
				else
					local first, last = offset + 1, math.min(offset + CAPACITY, n)
					set_caption_sig(cache, count, first .. "-" .. last .. "/" .. total,
						{ "cybersyn-gui.pager-range", tostring(first), tostring(last), total })
				end
				set_tooltip_sig(cache, { count }, n .. "/" .. data.total, n < data.total
					and { "cybersyn-gui.overview-count-tooltip", tostring(n), total } or "")
			end
		end
	end
end

--- @param map_data MapData
--- @param player_data PlayerData
function overview_tab.build(map_data, player_data)
	local refs = player_data.refs
	if not (refs.overview_stations_headline and refs.overview_stations_headline.valid) then return end
	local model = overview_tab.model(player_data)
	render_tiles(player_data, model)
	render_panels(player_data, model)
end

dev.register_dump(TAB, function(player_data)
	local model = overview_tab.model(player_data)
	local refs = player_data.refs
	local out = {
		period = model.period,
		filtered = model.filtered,
		tracking = model.tracking,
		snapshot_tick = model.snapshot_tick,
		capacity = CAPACITY,
		offsets = player_data.overview_offsets,
		recorded_ticks = model.recorded_ticks,
		tiles = model.tiles,
		rendered_tiles = {},
		lists = {},
	}
	for _, tile in ipairs(TILES) do
		local lines = {}
		local caption = refs["overview_tile_" .. tile.name .. "_caption"]
		local headline = refs["overview_" .. tile.name .. "_headline"]
		lines.caption = caption and caption.valid and caption.caption or nil
		lines.headline = headline and headline.valid and headline.caption or nil
		for _, line in ipairs(tile.lines) do
			local flow = refs["overview_" .. tile.name .. "_" .. line .. "_flow"]
			local elem = refs["overview_" .. tile.name .. "_" .. line]
			if elem and elem.valid and flow.visible then lines[line] = elem.caption end
		end
		out.rendered_tiles[tile.name] = lines
	end
	for _, panel in ipairs(PANELS) do
		local name = panel.name
		local data = model.lists[name]
		local keys, order, rendered = {}, {}, {}
		for i, row in ipairs(data.rows) do
			keys[i] = row.key
			order[i] = row.order
		end
		local tbl = refs["overview_" .. name .. "_table"]
		if tbl and tbl.valid and tbl.visible then
			local columns = tbl.column_count
			local children = tbl.children
			for r = 1, #children / columns - 1 do
				local base = r * columns
				local cells = { children[base + 1].tags.item_hash or children[base + 1].tags.station_id or "" }
				for c = 2, columns do
					cells[c] = children[base + c].caption
				end
				cells.sprite = children[base + 1].sprite
				rendered[r] = cells
			end
		end
		local caption = refs["overview_" .. name .. "_caption"]
		local count = refs["overview_" .. name .. "_count"]
		local empty = refs["overview_" .. name .. "_empty"]
		out.lists[name] = {
			caption = caption and caption.valid and caption.caption or nil,
			count = count and count.valid and count.caption or nil,
			paged = refs["overview_" .. name .. "_next"] and refs["overview_" .. name .. "_next"].visible or false,
			empty = empty and empty.valid and empty.parent.visible and empty.caption or nil,
			total = data.total,
			keys = keys,
			order = order,
			rendered = rendered,
		}
	end
	return out
end)

dev.register_stats(stats.summary)

overview_tab.handle = {}

--- @param e {player_index: uint}
function overview_tab.wrapper(e, handler)
	local player = game.get_player(e.player_index)
	if not player then return end
	local player_data = storage.manager.players[e.player_index]
	if not player_data then return end
	handler(player, player_data, player_data.refs, e)
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
--- @param e EventData.on_gui_selection_state_changed
function overview_tab.handle.overview_period_changed(player, player_data, refs, e)
	local element = e.element
	if not (element and element.valid) then return end
	local minutes = PERIODS[element.selected_index]
	if not minutes or minutes == player_data.overview_period then return end
	player_data.overview_period = minutes
	local offsets = player_data.overview_offsets
	if offsets then
		for _, panel in ipairs(PANELS) do
			if panel.scope == "period" then offsets[panel.name] = nil end
		end
	end
	util.rerender(player, player_data)
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
--- @param e EventData.on_gui_click
function overview_tab.handle.overview_page_click(player, player_data, refs, e)
	local element = e.element
	if not (element and element.valid) then return end
	local name, step = element.tags.overview_panel, element.tags.step
	if not (name and step and LIMITS[name]) then return end
	local offsets = player_data.overview_offsets
	if not offsets then
		offsets = {}
		player_data.overview_offsets = offsets
	end
	offsets[name] = math.max((offsets[name] or 0) + step * CAPACITY, 0)
	util.rerender(player, player_data)
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
--- @param e EventData.on_gui_click
function overview_tab.handle.overview_row_click(player, player_data, refs, e)
	local element = e.element
	if not (element and element.valid) then return end
	-- Repeated shift-clicks on one row must keep the layout held past the hover timeout.
	util.touch_hover(e)
	local tags = element.tags
	local kind = tags.kind
	if kind == "item" then
		util.item_button_click(player, player_data, e, tags.item_hash --[[@as string]])
	elseif kind == "station" then
		stations_tab.handle.open_station_gui(player, player_data, refs, e)
	end
end

gui.add_handlers(overview_tab.handle, overview_tab.wrapper)

return overview_tab
