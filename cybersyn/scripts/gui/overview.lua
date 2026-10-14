local gui = require("__flib__.gui")
local format = require("__flib__.format")
local train_util = require("__flib__.train")

local constants = require("scripts.gui.constants")
local util = require("scripts.gui.util")
local collector = require("scripts.gui.collector")
local dev = require("scripts.gui.dev")
local stats = require("scripts.stats")
local stations_tab = require("scripts.gui.stations")

local overview_tab = {}

local TAB = "overview_tab"

local TILE_ROW_HEIGHT = 214
local FILTER_NOTE_HEIGHT = 20
local SPACING = 8
local PANEL_CAPTION_HEIGHT = 24
-- What is left of the tab after the tiles and the filter note goes to the panel columns.
local LIST_AREA_HEIGHT = constants.gui_content_frame_height - TILE_ROW_HEIGHT - FILTER_NOTE_HEIGHT - 2 * SPACING

local NO_VALUE = "–"

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
		lines = { "providers", "requesters", "warming_up", "faulty", "saturated", "starved" },
		tooltips = { faulty = true, saturated = true, starved = true },
		colors = { warming_up = "yellow", faulty = "red", saturated = "orange", starved = "red" },
	},
	{
		name = "fleet",
		sprite = "item/locomotive",
		lines = { "parked", "to_provider", "loading", "to_requester", "unloading", "returning", "refuelling" },
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
		colors = { starved = "red", age_30m = "orange", age_over = "red" },
	},
	{
		name = "flow",
		sprite = "item/cargo-wagon",
		lines = { "last_10m", "last_60m", "last_24h", "total", "cycle", "dispatch_rate" },
		tooltips = { cycle = true, dispatch_rate = true },
	},
}

local AGE_LINES = { "age_1m", "age_5m", "age_30m", "age_over" }

--- @class OverviewListDef
--- @field name string
--- @field limit int
--- @field widths int[] value column widths

--- @type OverviewListDef[][] one inner array per column, top to bottom
local LIST_COLUMNS = {
	{
		{ name = "starved", limit = 15, widths = { 64, 40, 64 } },
		{ name = "waiting", limit = 15, widths = { 64, 64 } },
	},
	{
		{ name = "transit", limit = 10, widths = { 64, 40 } },
		{ name = "delivered", limit = 10, widths = { 72 } },
		{ name = "saturated", limit = 10, widths = { 56 } },
	},
	{
		{ name = "alerts", limit = 50, widths = { 120, 64 } },
		{ name = "networks", limit = 50, widths = { 36, 36, 44, 44 } },
	},
}

local LIMITS = {}
for _, column in ipairs(LIST_COLUMNS) do
	for _, list in ipairs(column) do
		LIMITS[list.name] = list.limit
	end
end

local function locale_key(prefix, name)
	return prefix .. string.gsub(name, "_", "-")
end

local function tile_line_def(tile, line)
	local key = locale_key("cybersyn-gui.overview-" .. tile.name .. "-", line)
	return {
		type = "flow",
		name = "overview_" .. tile.name .. "_" .. line .. "_flow",
		direction = "horizontal",
		style = "cybersyn_overview_line_flow",
		{
			type = "label",
			style = "cybersyn_overview_line_label",
			caption = { key },
			tooltip = tile.tooltips and tile.tooltips[line] and { key .. "-tooltip" } or nil,
		},
		{ type = "empty-widget", style = "flib_horizontal_pusher" },
		{
			type = "label",
			name = "overview_" .. tile.name .. "_" .. line,
			style = "cybersyn_overview_line_value",
			caption = NO_VALUE,
		},
	}
end

--- @param tile OverviewTileDef
local function tile_def(tile)
	local body = {
		type = "flow",
		direction = "vertical",
		style = "cybersyn_overview_tile_body",
	}
	if tile.name == "fleet" then
		body[#body + 1] = {
			type = "flow",
			direction = "horizontal",
			style = "cybersyn_overview_line_flow",
			{
				type = "label",
				name = "overview_fleet_idle",
				style = "cybersyn_overview_line_label",
				caption = { "cybersyn-gui.overview-fleet-idle", NO_VALUE },
				tooltip = { "cybersyn-gui.overview-fleet-idle-tooltip" },
			},
			{
				type = "progressbar",
				name = "overview_fleet_idle_bar",
				style = "cybersyn_overview_idle_bar",
				value = 0,
				tooltip = { "cybersyn-gui.overview-fleet-idle-tooltip" },
			},
		}
	end
	for _, line in ipairs(tile.lines) do
		body[#body + 1] = tile_line_def(tile, line)
	end
	if tile.name == "demand" then
		body[#body + 1] = {
			type = "label",
			name = "overview_demand_hint",
			style = "cybersyn_overview_hint_label",
			caption = { "cybersyn-gui.overview-demand-tracking-off" },
			visible = false,
		}
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
				style = "subheader_caption_label",
				caption = { "cybersyn-gui.overview-tile-" .. tile.name },
				tooltip = { "cybersyn-gui.overview-tile-" .. tile.name .. "-tooltip" },
			},
			{ type = "empty-widget", style = "flib_horizontal_pusher" },
			{
				type = "label",
				name = "overview_" .. tile.name .. "_headline",
				style = "cybersyn_overview_big_number",
				caption = NO_VALUE,
			},
		},
		body,
	}
end

--- @param list OverviewListDef
--- @param height int
local function panel_def(list, height)
	return {
		type = "flow",
		direction = "vertical",
		style = "cybersyn_overview_panel_flow",
		{
			type = "flow",
			direction = "horizontal",
			style = "cybersyn_overview_panel_caption_flow",
			{
				type = "label",
				style = "bold_label",
				caption = { "cybersyn-gui.overview-list-" .. list.name },
				tooltip = { "cybersyn-gui.overview-list-" .. list.name .. "-tooltip" },
			},
			{ type = "empty-widget", style = "flib_horizontal_pusher" },
			{
				type = "label",
				name = "overview_" .. list.name .. "_count",
				style = "cybersyn_overview_count_label",
			},
		},
		{
			type = "frame",
			style = "deep_frame_in_shallow_frame",
			style_mods = { height = height - PANEL_CAPTION_HEIGHT, horizontally_stretchable = true },
			{
				type = "scroll-pane",
				style = "cybersyn_overview_panel_scroll",
				horizontal_scroll_policy = "never",
				vertical_scroll_policy = "auto",
				{
					type = "label",
					name = "overview_" .. list.name .. "_empty",
					style = "cybersyn_overview_empty_label",
					caption = { "cybersyn-gui.overview-empty-" .. list.name },
					visible = false,
				},
				{
					type = "flow",
					name = "overview_" .. list.name .. "_list",
					direction = "vertical",
					style = "cybersyn_overview_list_flow",
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

	local columns = {
		type = "flow",
		direction = "horizontal",
		style = "cybersyn_overview_columns",
		style_mods = { height = LIST_AREA_HEIGHT },
	}
	for _, column in ipairs(LIST_COLUMNS) do
		local n = #column
		local height = math.floor((LIST_AREA_HEIGHT - (n - 1) * SPACING) / n)
		local col = {
			type = "flow",
			direction = "vertical",
			style = "cybersyn_overview_column",
		}
		for _, list in ipairs(column) do
			col[#col + 1] = panel_def(list, height)
		end
		columns[#columns + 1] = col
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
			style_mods = { height = constants.gui_content_frame_height },
			tiles,
			{
				type = "label",
				name = "overview_filter_note",
				style = "cybersyn_overview_hint_label",
				style_mods = { height = FILTER_NOTE_HEIGHT },
				caption = "",
			},
			columns,
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

--- @param hash string
--- @param tail LocalisedString[]
--- @return table? row partial row with sprite, quality, caption and tooltip; nil when the item has no sprite
local function item_row(hash, tail)
	local sprite, quality, name_tooltip = util.item_sprite_and_tooltip(hash)
	if not sprite then return nil end
	local tooltip = { "", name_tooltip }
	for _, part in ipairs(tail) do
		tooltip[#tooltip + 1] = part
	end
	tooltip[#tooltip + 1] = "\n"
	tooltip[#tooltip + 1] = { "cybersyn-gui.overview-item-click-hint" }
	return {
		key = hash,
		sprite = sprite,
		quality = quality,
		caption = name_tooltip[4],
		tooltip = tooltip,
		tags = { kind = "item", item_hash = hash },
	}
end

--- @param st SnapshotStation
--- @param key string|number
--- @param sprite string?
--- @param quality string?
--- @param tail LocalisedString[]
local function station_row(st, key, sprite, quality, tail)
	local tooltip = { "", "[font=default-semibold]", st.name, "[/font]" }
	for _, part in ipairs(tail) do
		tooltip[#tooltip + 1] = part
	end
	tooltip[#tooltip + 1] = "\n"
	tooltip[#tooltip + 1] = constants.open_station_gui_tooltip
	return {
		key = key,
		sprite = sprite or "item/train-stop",
		quality = quality,
		caption = st.name,
		name_sig = st.name,
		tooltip = tooltip,
		tags = { kind = "station", station_id = st.id },
	}
end

local function amount(count)
	return format.number(count, true)
end

--- Everything the tab shows, from the snapshot and storage.stats only, with every list already sorted and cut.
--- @param player_data PlayerData
--- @return table
function overview_tab.model(player_data)
	local snapshot = collector.get()
	local f = util.get_filters(player_data)
	local filtered = util.filters_active(f, true)
	local now = game.tick
	-- The planner reads its cached copy, so this matches what is actually being tracked.
	local tracking = mod_settings.track_request_wait_times == true
	local starved_set = snapshot.starved

	local st_tile = { total = 0, providers = 0, requesters = 0, warming_up = 0, faulty = 0, saturated = 0, starved = 0 }
	local demand = { total = 0, volume = 0, starved = 0, in_transit = 0, age_1m = 0, age_5m = 0, age_30m = 0, age_over = 0 }
	local starved_items = {}
	local waiting = {}
	local waiting_total = 0
	local saturated = {}
	local transit = filtered and {} or snapshot.inventory_all.in_transit
	local networks = {}

	for _, st in pairs(snapshot.stations) do
		if not filtered or util.station_passes(st, f, true) then
			st_tile.total = st_tile.total + 1
			if st.is_p then st_tile.providers = st_tile.providers + 1 end
			if st.is_r then st_tile.requesters = st_tile.requesters + 1 end
			if st.warming_up then st_tile.warming_up = st_tile.warming_up + 1 end
			if not st.comb_ok then st_tile.faulty = st_tile.faulty + 1 end
			local limit = st.trains_limit
			if st.deliveries_total > 0 and st.deliveries_total >= limit then
				st_tile.saturated = st_tile.saturated + 1
				saturated[#saturated + 1] = st
			end
			each_network(st.network_name, st.network_mask, count_station_network, networks, st)

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
						local age = now - start
						if age < 3600 then
							demand.age_1m = demand.age_1m + 1
						elseif age < 18000 then
							demand.age_5m = demand.age_5m + 1
						elseif age < 108000 then
							demand.age_30m = demand.age_30m + 1
						else
							demand.age_over = demand.age_over + 1
						end
						waiting_total = waiting_total + 1
						top_k_insert(waiting, LIMITS.waiting, { start = start, id = st.id, hash = hash, count = volume, st = st }, waiting_less)
					end
					if request_starved(st, hash, starved_set) then
						any_starved = true
						demand.starved = demand.starved + 1
						local agg = starved_items[hash]
						if agg then
							agg.count = agg.count + volume
							agg.stations = agg.stations + 1
							if start and (not agg.earliest or start < agg.earliest) then agg.earliest = start end
						else
							starved_items[hash] = { count = volume, stations = 1, earliest = start }
						end
					end
				end
			end
			if any_starved then st_tile.starved = st_tile.starved + 1 end

			if filtered then
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
	end

	local fleet = { total = 0, parked = 0, to_provider = 0, loading = 0, to_requester = 0, unloading = 0, returning = 0, refuelling = 0, other = 0 }
	local available = 0
	local train_passes = {}
	for id, tr in pairs(snapshot.trains) do
		if not filtered or util.train_passes(tr, f, true) then
			train_passes[id] = true
			fleet.total = fleet.total + 1
			local group = STATUS_GROUP[tr.status or STATUS_D] or "other"
			fleet[group] = fleet[group] + 1
			if tr.is_available then available = available + 1 end
			each_network(tr.network_name, tr.network_mask, count_train_network, networks, tr)
		end
	end
	fleet.idle = fleet.total > 0 and fleet.parked / fleet.total or nil

	local depots = snapshot.depots
	local depot_tile = {
		total = depots.total,
		occupied = depots.parked,
		empty = depots.total - depots.parked,
		available = available,
	}

	local d10 = stats.window(10)
	local d60, p60, delivered_items = stats.window(60, true)
	local cycle = stats.cycle_average(60)
	local flow = {
		headline = d60,
		last_10m = d10,
		last_60m = d60,
		last_24h = stats.day_deliveries(),
		total = stats.get().totals.deliveries,
		cycle = cycle,
		dispatch_rate = p60,
	}

	local lists = {}

	-- Starved requests: oldest wait first, then the largest shortfall. Rows (and their tooltips) are built for the
	-- visible top only.
	local starved_hashes = {}
	for hash, agg in pairs(starved_items) do
		starved_hashes[#starved_hashes + 1] = hash
		agg.tiebreak = string.format("%020.0f|%s", 1e15 - math.min(agg.count, 1e15 - 1), hash)
	end
	util.sort_by(starved_hashes, function(hash)
		local agg = starved_items[hash]
		return agg.earliest or (1e12 - agg.count)
	end, true, function(hash) return starved_items[hash].tiebreak end)
	local starved_rows = {}
	for _, hash in ipairs(starved_hashes) do
		if #starved_rows >= LIMITS.starved then break end
		local agg = starved_items[hash]
		local tail = {
			"\n", { "cybersyn-gui.requested-by-stations", tostring(agg.stations) },
			"\n", { "cybersyn-gui.amount", format.number(agg.count) },
			"\n[color=red]", { "cybersyn-gui.overview-no-provider" }, "[/color]",
		}
		if agg.earliest then
			tail[#tail + 1] = "\n"
			tail[#tail + 1] = { "cybersyn-gui.waiting-for", util.format_duration(now - agg.earliest) }
		end
		local row = item_row(hash, tail)
		if row then
			row.order = agg.earliest or (1e12 - agg.count)
			row.values = { amount(agg.count), tostring(agg.stations), agg.earliest and util.format_duration(now - agg.earliest) or NO_VALUE }
			starved_rows[#starved_rows + 1] = row
		end
	end
	lists.starved = { rows = starved_rows, total = #starved_hashes }

	local waiting_rows = {}
	for i, w in ipairs(waiting) do
		local sprite, quality, name_tooltip = util.item_sprite_and_tooltip(w.hash)
		local row = station_row(w.st, w.id .. "|" .. w.hash, sprite, quality, {
			"\n", name_tooltip or w.hash,
			"\n", { "cybersyn-gui.amount", format.number(w.count) },
			"\n", { "cybersyn-gui.waiting-for", util.format_duration(now - w.start) },
		})
		row.order = w.start
		row.values = { amount(w.count), util.format_duration(now - w.start) }
		waiting_rows[i] = row
	end
	lists.waiting = { rows = waiting_rows, total = waiting_total, disabled = not tracking }

	-- Sorting bare hashes and building rows for the visible top only keeps tooltips off the other ~200 items.
	local transit_hashes = {}
	for hash in pairs(transit) do
		transit_hashes[#transit_hashes + 1] = hash
	end
	util.sort_by(transit_hashes, function(hash) return transit[hash].count end, false, function(hash) return hash end)
	local transit_rows = {}
	for _, hash in ipairs(transit_hashes) do
		if #transit_rows >= LIMITS.transit then break end
		local agg = transit[hash]
		local row = item_row(hash, {
			"\n", { "cybersyn-gui.in-transit-to-stations", tostring(agg.stations) },
			"\n", { "cybersyn-gui.amount", format.number(agg.count) },
		})
		if row then
			row.order = agg.count
			row.values = { amount(agg.count), tostring(agg.stations) }
			transit_rows[#transit_rows + 1] = row
		end
	end
	lists.transit = { rows = transit_rows, total = #transit_hashes }

	local delivered_hashes = {}
	for hash in pairs(delivered_items) do
		delivered_hashes[#delivered_hashes + 1] = hash
	end
	util.sort_by(delivered_hashes, function(hash) return delivered_items[hash] end, false, function(hash) return hash end)
	local delivered_rows = {}
	for _, hash in ipairs(delivered_hashes) do
		if #delivered_rows >= LIMITS.delivered then break end
		local count = delivered_items[hash]
		local row = item_row(hash, {
			"\n", { "cybersyn-gui.overview-delivered-amount", format.number(count) },
		})
		if row then
			row.order = count
			row.values = { amount(count) }
			delivered_rows[#delivered_rows + 1] = row
		end
	end
	lists.delivered = { rows = delivered_rows, total = #delivered_hashes }

	util.sort_by(saturated, function(st) return st.deliveries_total end, false, function(st) return st.id end)
	local saturated_rows = {}
	for i = 1, math.min(#saturated, LIMITS.saturated) do
		local st = saturated[i]
		local row = station_row(st, st.id, nil, nil, {
			"\n", { "cybersyn-gui.overview-saturated-row", tostring(st.deliveries_total), tostring(st.trains_limit) },
		})
		row.order = st.deliveries_total
		row.values = { st.deliveries_total .. "/" .. st.trains_limit }
		saturated_rows[i] = row
	end
	lists.saturated = { rows = saturated_rows, total = #saturated }

	local alert_rows = {}
	for _, alert in ipairs(snapshot.alerts) do
		if not filtered or train_passes[alert.train_id] then
			local kind_caption = { "cybersyn-gui.overview-alert-" .. (alert.kind or 0) }
			local age = util.format_duration(now - alert.since_tick)
			alert_rows[#alert_rows + 1] = {
				key = alert.train_id,
				sprite = "item/locomotive",
				caption = { "cybersyn-gui.overview-train", tostring(alert.train_id) },
				tooltip = { "", kind_caption, "\n", { "cybersyn-gui.time-ago", age }, "\n", { "cybersyn-gui.open-train-gui" } },
				tags = { kind = "train", train_id = alert.train_id },
				order = alert.since_tick,
				values = { kind_caption, age },
				sig_extra = alert.kind,
			}
		end
	end
	util.sort_by(alert_rows, function(r) return r.order end, true, function(r) return r.key end)
	lists.alerts = { rows = alert_rows, total = #alert_rows }

	local network_rows = {}
	for name, n in pairs(networks) do
		if not f.network or f.network == name then
			local sprite, _, localised = util.generate_item_references(name)
			network_rows[#network_rows + 1] = {
				key = name,
				sprite = sprite or "utility/questionmark",
				caption = localised or name,
				tooltip = {
					"", localised or name,
					"\n", { "cybersyn-gui.overview-network-row", tostring(n.p), tostring(n.r), tostring(n.trains), tostring(n.available) },
					"\n", { "cybersyn-gui.overview-network-click-hint" },
				},
				tags = { kind = "network", network_name = name },
				order = n.p + n.r,
				values = { tostring(n.p), tostring(n.r), tostring(n.trains), tostring(n.available) },
			}
		end
	end
	util.sort_by(network_rows, function(r) return r.order end, false, function(r) return r.key end)
	lists.networks = { rows = network_rows, total = #network_rows }

	for _, column in ipairs(LIST_COLUMNS) do
		for _, list in ipairs(column) do
			local rows = lists[list.name].rows
			for i = #rows, list.limit + 1, -1 do
				rows[i] = nil
			end
		end
	end

	st_tile.headline = st_tile.total
	fleet.headline = fleet.total
	depot_tile.headline = depot_tile.total
	demand.headline = demand.total

	return {
		snapshot_tick = snapshot.tick,
		filtered = filtered,
		item_filter = f.item,
		tracking = tracking,
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

local function format_line(tile, line, value)
	if value == nil then return NO_VALUE end
	if tile == "flow" then
		if line == "cycle" then return util.format_duration(value * 60) end
		if line == "dispatch_rate" then return format.number(value) end
	elseif tile == "demand" and line == "volume" then
		return amount(value)
	end
	return format.number(value)
end

--- Captions that are LocalisedStrings cannot be compared with the element's caption, so the last plain-string
--- signature written is kept per player and the assignment skipped while it is unchanged.
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

--- @param player_data PlayerData
--- @return table
local function caption_cache(player_data)
	local state = util.gui_state(player_data, "overview_captions")
	state.captions = state.captions or {}
	return state.captions
end

--- @param player_data PlayerData
--- @param model table
local function render_tiles(player_data, model)
	local refs = player_data.refs
	local cache = caption_cache(player_data)
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
	local idle_text = idle and string.format("%d%%", math.floor(idle * 100 + 0.5)) or NO_VALUE
	set_caption_sig(cache, refs.overview_fleet_idle, idle_text, { "cybersyn-gui.overview-fleet-idle", idle_text })

	local tracking = model.tracking
	for _, line in ipairs(AGE_LINES) do
		local elem = refs["overview_demand_" .. line .. "_flow"]
		if elem and elem.valid and elem.visible ~= tracking then elem.visible = tracking end
	end
	local hint = refs.overview_demand_hint
	if hint and hint.valid and hint.visible == tracking then hint.visible = not tracking end

	-- The tab deliberately ignores the item filter, so say so; otherwise a shift-click on an item row looks like a no-op.
	local note_sig = (model.filtered and "f" or "") .. (model.item_filter and "i" or "")
	local note_caption = ""
	if model.filtered and model.item_filter then
		note_caption = { "", { "cybersyn-gui.overview-filtered" }, " ", { "cybersyn-gui.overview-item-filter-ignored" } }
	elseif model.filtered then
		note_caption = { "cybersyn-gui.overview-filtered" }
	elseif model.item_filter then
		note_caption = { "", "[img=utility/info] ", { "cybersyn-gui.overview-item-filter-ignored" } }
	end
	set_caption_sig(cache, refs.overview_filter_note, note_sig, note_caption)
end

--- @param scope string
--- @param row table
--- @param widths int[]
local function row_entry(scope, row, widths)
	local values = row.values
	local sig_parts = {}
	for i = 1, #widths do
		local v = values[i]
		sig_parts[i] = type(v) == "string" and v or ""
	end
	local sig = table.concat(sig_parts, "|") .. "|" .. tostring(row.name_sig or "") .. "|" .. tostring(row.sig_extra or "")
	return {
		key = row.key,
		sig = sig,
		build = function()
			local def = {
				type = "frame",
				direction = "horizontal",
				style = "cybersyn_overview_row",
				tooltip = row.tooltip,
				tags = row.tags,
				handler = { [defines.events.on_gui_click] = overview_tab.handle.overview_row_click },
				{
					type = "sprite-button",
					style = "cybersyn_overview_row_icon",
					sprite = row.sprite,
					quality = row.quality,
					ignored_by_interaction = true,
				},
				{
					type = "label",
					style = "cybersyn_overview_row_name",
					caption = row.caption,
					ignored_by_interaction = true,
				},
			}
			for i, width in ipairs(widths) do
				def[#def + 1] = {
					type = "label",
					style = "cybersyn_overview_row_value",
					style_mods = { width = width },
					caption = values[i] or "",
					ignored_by_interaction = true,
				}
			end
			return util.hoverable(def, scope)
		end,
		update = function(elem)
			elem.tooltip = row.tooltip
			local children = elem.children
			if row.name_sig then set_caption(children[2], row.caption) end
			for i = 1, #widths do
				local child = children[i + 2]
				local v = values[i] or ""
				if type(v) == "string" then
					set_caption(child, v)
				elseif child then
					child.caption = v
				end
			end
		end,
	}
end

--- @param player_data PlayerData
--- @param model table
local function render_lists(player_data, model)
	local refs = player_data.refs
	local cache = caption_cache(player_data)
	for _, column in ipairs(LIST_COLUMNS) do
		for _, list in ipairs(column) do
			local data = model.lists[list.name]
			local container = refs["overview_" .. list.name .. "_list"]
			if container and container.valid then
				local scope = container.name
				local entries = {}
				for i, row in ipairs(data.rows) do
					entries[i] = row_entry(scope, row, list.widths)
				end
				util.sync_children(container, entries, util.gui_state(player_data, scope), util.hold_active(player_data, scope))

				local empty = refs["overview_" .. list.name .. "_empty"]
				if empty and empty.valid then
					local show = #data.rows == 0
					if empty.visible ~= show then empty.visible = show end
					if show and data.disabled then
						empty.caption = { "cybersyn-gui.overview-empty-waiting-disabled" }
					elseif show then
						empty.caption = { "cybersyn-gui.overview-empty-" .. list.name }
					end
				end
				local shown, total = #data.rows, format.number(data.total)
				local partial = shown < data.total
				set_caption_sig(cache, refs["overview_" .. list.name .. "_count"], partial and (shown .. "/" .. total) or total,
					partial and { "cybersyn-gui.overview-shown-of", tostring(shown), total } or total)
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
	render_lists(player_data, model)
end

dev.register_dump(TAB, function(player_data)
	local model = overview_tab.model(player_data)
	local out = { tiles = model.tiles, filtered = model.filtered, tracking = model.tracking, snapshot_tick = model.snapshot_tick, lists = {} }
	local refs = player_data.refs
	for name, data in pairs(model.lists) do
		local keys, order, rendered = {}, {}, {}
		for i, row in ipairs(data.rows) do
			keys[i] = row.key
			order[i] = row.order
		end
		local container = refs["overview_" .. name .. "_list"]
		if container and container.valid then
			for i, child in ipairs(container.children) do
				local tags = child.tags
				rendered[i] = tags.item_hash or tags.station_id or tags.train_id or tags.network_name
			end
		end
		out.lists[name] = { keys = keys, order = order, total = data.total, rendered = rendered }
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
--- @param id uint
local function open_train(player, player_data, id)
	local train = storage.trains[id]
	local entity = train and train.entity
	if not (entity and entity.valid) then
		local alert = storage.active_alerts and storage.active_alerts[id]
		entity = alert and alert[1]
	end
	if not (entity and entity.valid) then
		util.error_flying_text(player, { "cybersyn-message.error-train-is-invalid" })
		return
	end
	train_util.open_gui(player.index, entity)
end

--- Left: filter by the network and go to Stations; shift+left: filter and stay; right: clear the network filter.
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param e EventData.on_gui_click
--- @param name string
local function network_click(player, player_data, e, name)
	if e.button == defines.mouse_button_type.right then
		name = nil
	elseif e.button ~= defines.mouse_button_type.left then
		return
	end
	player_data.search_network_name = name
	local elem = player_data.refs.network
	if elem and elem.valid then
		elem.elem_value = name and util.signalid_from_name(name) or nil
	end
	util.reset_pages(player_data)
	if name and not e.shift then
		util.select_tab(player_data, "stations_tab")
	end
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
	elseif kind == "train" then
		open_train(player, player_data, tags.train_id --[[@as uint]])
	elseif kind == "network" then
		network_click(player, player_data, e, tags.network_name --[[@as string]])
	end
end

gui.add_handlers(overview_tab.handle, overview_tab.wrapper)

return overview_tab
