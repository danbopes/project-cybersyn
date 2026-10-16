-- Overview tab (PLAN3 §4.7): four tiles and one full-width table of the requests the dispatcher is not serving now,
-- with the reason it recorded for each (scripts/diag.lua). Obeys the item filter only.

local gui = require("__flib__.gui")
local format = require("__flib__.format")

local util = require("scripts.gui.util")
local collector = require("scripts.gui.collector")
local dev = require("scripts.gui.dev")
local stats = require("scripts.stats")
local diag = require("scripts.diag")
local text = require("scripts.gui.unserved-text")

--- @class PlayerData
--- @field overview_period int? minutes covered by the Throughput tile and the headroom minimum: 10, 60 or 1440
--- @field overview_show_acked true? acknowledged rows are listed (greyed, at the bottom)
--- @field overview_widths {requester: int, provider: int, tile: int}? column widths for the current layout
--- @field stations_chip "unserved"|"failing"? the Stations chip a tile jump selects; read by the Stations chips from
---   phase 4 on (PLAN3 §4.7), until then the jump only sorts the Stations tab
--- @field trains_chip "parked"? the Trains chip the Fleet headroom tile selects (phase 4), with the network filter

local overview_tab = {}

local TAB = "overview_tab"
local TABLE = "overview_unserved_table"
local PERIODS = { 10, 60, 1440 }
local DEFAULT_PERIOD = 60
local NO_VALUE = text.NO_VALUE
local HOUR = 216000
local DAY = 24 * HOUR
local TOP_REASONS = 3
local MAX_TOOLTIP_NETWORKS = 12
local TABLE_COLUMNS = 8
-- Logical px at the 1,392 px content width of a 1,440 px window (PLAN3 §4.7); the requester column takes the rest.
local W = { item = 32, why = 132, provider = 272, stock = 110, lost = 96, wait = 72, ack = 28 }
local BASE_CONTENT_WIDTH = 1392
local TABLE_PADDING = 4 + 10
local TABLE_SPACING = 8
local FRAME_BORDER = 4
local ICON_ROW = 64
local NAME_ICONS = 3

--- @class OverviewTileDef
--- @field name string
--- @field sprite string
--- @field lines int

--- @type OverviewTileDef[]
local TILES = {
	{ name = "unserved", sprite = "utility/warning_icon", lines = 4 },
	{ name = "fleet", sprite = "item/locomotive", lines = 3 },
	{ name = "failing", sprite = "item/train-stop", lines = 4 },
	{ name = "throughput", sprite = "item/cargo-wagon", lines = 3 },
}
local FAILING_LINES = { "no_power", "disabled", "throttling", "misconfigured" }

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

--- @param player_data PlayerData
--- @return int
local function unserved_minutes(player_data)
	local m = player_data.unserved_minutes
	if not m then
		local setting = settings.get_player_settings(player_data.player_index)["cybersyn-manager-unserved-minutes"]
		m = setting and setting.value --[[@as int]] or 5
		player_data.unserved_minutes = m
	end
	return m
end

-- ---------------------------------------------------------------- build

local function line_def(tile, i)
	local base = "overview_" .. tile.name .. "_line" .. i
	return {
		type = "flow",
		name = base,
		direction = "horizontal",
		style = "cybersyn_overview_line_flow",
		ignored_by_interaction = true,
		{ type = "label", name = base .. "_label", style = "cybersyn_overview_line_label", caption = "" },
		{ type = "empty-widget", style = "flib_horizontal_pusher" },
		{ type = "label", name = base .. "_value", style = "cybersyn_overview_line_value", caption = "" },
	}
end

--- @param tile OverviewTileDef
local function tile_def(tile)
	local body = {
		type = "flow",
		direction = "vertical",
		style = "cybersyn_overview_tile_body",
		ignored_by_interaction = true,
		{
			type = "flow",
			direction = "horizontal",
			style = "cybersyn_overview_tile_header",
			{
				type = "sprite",
				style = "cybersyn_overview_tile_icon",
				sprite = tile.sprite,
				resize_to_sprite = false,
			},
			{ type = "label", name = "overview_" .. tile.name .. "_caption", style = "cybersyn_overview_tile_caption" },
			{ type = "empty-widget", style = "flib_horizontal_pusher" },
			{ type = "label", name = "overview_" .. tile.name .. "_note", style = "cybersyn_subheader_note", caption = "" },
			{ type = "label", name = "overview_" .. tile.name .. "_headline", style = "cybersyn_overview_big_number", caption = NO_VALUE },
		},
	}
	for i = 1, tile.lines do
		body[#body + 1] = line_def(tile, i)
	end
	return {
		type = "button",
		name = "overview_tile_" .. tile.name,
		style = "cybersyn_overview_tile",
		tags = { tile = tile.name },
		handler = { [defines.events.on_gui_click] = overview_tab.handle.overview_tile_click },
		body,
	}
end

local function header_cell(caption, width, right, name)
	return {
		type = "label",
		name = name,
		style = right and "cybersyn_unserved_header_value" or "cybersyn_unserved_header",
		style_mods = { width = width },
		caption = caption,
	}
end

--- The subheader's right side; manager.lua puts it after the shared search field, chip and progress note.
--- @return flib.GuiElemDef[]
function overview_tab.subheader_right()
	local period_items = {}
	local default_index = 1
	for i, minutes in ipairs(PERIODS) do
		period_items[i] = { "cybersyn-gui.overview-period-" .. minutes }
		if minutes == DEFAULT_PERIOD then default_index = i end
	end
	return {
		{
			type = "checkbox",
			name = "overview_show_acked",
			caption = { "cybersyn-gui.overview-show-acked", "0" },
			tooltip = { "cybersyn-gui.overview-show-acked-tooltip" },
			state = false,
			handler = { [defines.events.on_gui_checked_state_changed] = overview_tab.handle.overview_show_acked },
		},
		{ type = "empty-widget", style_mods = { width = 12 } },
		{
			type = "label",
			style = "subheader_caption_label",
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
	}
end

function overview_tab.create()
	local tiles = {
		type = "flow",
		name = "overview_tile_row",
		direction = "horizontal",
		style = "cybersyn_overview_tile_row",
	}
	for _, tile in ipairs(TILES) do
		tiles[#tiles + 1] = tile_def(tile)
	end

	local tbl = {
		type = "table",
		name = TABLE,
		style = "cybersyn_unserved_table",
		column_count = TABLE_COLUMNS,
		header_cell("", W.item),
		header_cell({ "cybersyn-gui.unserved-col-requester" }, nil, false, "overview_unserved_h_requester"),
		header_cell({ "cybersyn-gui.unserved-col-why" }, W.why),
		header_cell({ "cybersyn-gui.unserved-col-provider" }, W.provider, false, "overview_unserved_h_provider"),
		header_cell({ "cybersyn-gui.unserved-col-stock" }, W.stock, true),
		header_cell({ "cybersyn-gui.unserved-col-lost" }, W.lost),
		header_cell({ "cybersyn-gui.unserved-col-wait" }, W.wait, true),
		header_cell("", W.ack),
	}
	tbl[5].tooltip = { "cybersyn-gui.unserved-col-stock-tooltip" }
	tbl[6].tooltip = { "cybersyn-gui.unserved-col-lost-tooltip" }
	tbl[7].tooltip = { "cybersyn-gui.unserved-col-wait-tooltip" }

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
			tiles,
			{
				type = "frame",
				name = "overview_unserved_frame",
				direction = "vertical",
				style = "cybersyn_unserved_frame",
				{
					type = "frame",
					direction = "horizontal",
					style = "cybersyn_unserved_caption_frame",
					{ type = "label", name = "overview_unserved_table_caption", style = "subheader_caption_label",
						caption = { "cybersyn-gui.unserved-caption" } },
					{ type = "empty-widget", style = "flib_horizontal_pusher" },
					{ type = "label", name = "overview_unserved_dropped", style = "cybersyn_subheader_note", visible = false },
					{
						type = "button",
						name = "overview_unserved_count",
						style = "cybersyn_unserved_count_button",
						caption = "",
						tooltip = { "cybersyn-gui.unserved-count-tooltip" },
						handler = { [defines.events.on_gui_click] = overview_tab.handle.overview_count_click },
					},
				},
				{
					type = "flow",
					name = "overview_unserved_body",
					direction = "vertical",
					style_mods = { vertical_spacing = 0 },
					tbl,
					{
						type = "flow",
						name = "overview_unserved_empty_flow",
						direction = "horizontal",
						style = "cybersyn_overview_empty_flow",
						visible = false,
						{
							type = "label",
							name = "overview_unserved_empty",
							style = "cybersyn_overview_empty_label",
							caption = { "cybersyn-gui.unserved-empty" },
						},
					},
				},
			},
		},
	}
end

--- Sizes from the window layout: tile widths, the two stretching columns and the table body's height (whole rows).
--- @param player_data PlayerData
--- @param layout ManagerLayout
function overview_tab.apply_layout(player_data, layout)
	local refs = player_data.refs
	local cw = layout.content_width
	local rows = layout.rows_by_tab[TAB]
	local tile = math.floor((cw - 3 * 12) / 4)
	local provider = math.floor(W.provider * math.min(cw, BASE_CONTENT_WIDTH) / BASE_CONTENT_WIDTH)
	local fixed = W.item + W.why + provider + W.stock + W.lost + W.wait + W.ack
	local requester = cw - FRAME_BORDER - TABLE_PADDING - (TABLE_COLUMNS - 1) * TABLE_SPACING - fixed
	local widths = { tile = tile, requester = requester, provider = provider, rows = rows }
	for _, t in ipairs(TILES) do
		local button = refs["overview_tile_" .. t.name]
		if button and button.valid then
			button.style.width = tile
			local body = button.children[1]
			body.style.width = tile
			body.style.height = 108
		end
	end
	local old = player_data.overview_widths
	player_data.overview_widths = widths
	local h_req, h_prov = refs.overview_unserved_h_requester, refs.overview_unserved_h_provider
	if h_req and h_req.valid then h_req.style.width = requester end
	if h_prov and h_prov.valid then h_prov.style.width = provider end
	local body = refs.overview_unserved_body
	if body and body.valid then body.style.height = 20 + rows * 32 end
	local empty = refs.overview_unserved_empty_flow
	if empty and empty.valid then empty.style.height = rows * 32 end
	-- Rows built for other widths are rebuilt rather than restyled cell by cell.
	if not old or old.requester ~= requester or old.provider ~= provider then
		local tbl = refs[TABLE]
		if tbl and tbl.valid then
			local children = tbl.children
			for i = #children, TABLE_COLUMNS + 1, -1 do children[i].destroy() end
		end
		local state = util.gui_state(player_data, TABLE)
		state.keys, state.sigs = nil, nil
	end
end

-- ---------------------------------------------------------------- model

--- @param a table
--- @param b table
--- @return boolean
local function row_before(a, b)
	local ea, eb = a.e, b.e
	if ea.first_tick ~= eb.first_tick then return ea.first_tick < eb.first_tick end
	local sa, sb = REASON_SEVERITY[ea.reason] or 0, REASON_SEVERITY[eb.reason] or 0
	if sa ~= sb then return sa > sb end
	if a.r_id ~= b.r_id then return a.r_id < b.r_id end
	return a.hash < b.hash
end

--- Keeps `list` sorted by row_before and at most `k` long; allocates only for a row that makes the cut.
local function top_k(list, k, r_id, hash, e)
	local n = #list
	if n >= k then
		local last = list[n].e
		if e.first_tick > last.first_tick then return end
	end
	local row = { r_id = r_id, hash = hash, e = e }
	if n >= k then
		if not row_before(row, list[n]) then return end
		list[n] = nil
		n = n - 1
	end
	local i = n
	while i >= 1 and row_before(row, list[i]) do
		list[i + 1] = list[i]
		i = i - 1
	end
	list[i + 1] = row
end

--- @param st SnapshotStation
--- @param item string
--- @return boolean
local function station_has_item(st, item)
	return st.provided[item] ~= nil or st.requested[item] ~= nil or st.deliveries[item] ~= nil
end

--- @param a table
--- @param b table
--- @return boolean
local function counts_before(a, b)
	if a[2] ~= b[2] then return a[2] > b[2] end
	return a[1] < b[1]
end

--- The diagnostics walk: the table's rows (top `rows` by wait, acknowledged ones apart) and the Unserved tile's
--- counts, for the item filter. One pass over the unserved entries, never over the stations.
--- @param d DiagState
--- @param item string?
--- @param rows int
--- @param threshold int ticks a request must have waited for the tile
--- @param now uint
--- @return table
local function unserved_model(d, item, rows, threshold, now)
	local out = {
		open = {}, acked = {}, total = 0, acked_total = 0, old = 0, old_acked = 0, reasons = {}, throttling = {},
	}
	local want_ix
	if item then
		want_ix = d.item_ix[item]
		if not want_ix then want_ix = -1 end
	end
	local acks = storage.acks
	local ack_requests = acks and acks.request
	local reasons = out.reasons
	local throttling = out.throttling
	for r_id, by_item in pairs(d.unserved) do
		local by_ack = ack_requests and ack_requests[r_id]
		for ix, e in pairs(by_item) do
			local reason = e.reason
			if reason == REASON_R_AT_LIMIT then
				throttling[r_id] = true
			elseif reason == REASON_P_AT_LIMIT and e.p_station_id then
				throttling[e.p_station_id] = true
			end
			if not want_ix or ix == want_ix then
				local hash = d.item_hash[ix]
				local acked = by_ack and by_ack[hash] and diag.is_acked("request", r_id, hash) ~= nil
				local old = now - e.first_tick >= threshold
				if acked then
					out.acked_total = out.acked_total + 1
					if old then out.old_acked = out.old_acked + 1 end
					top_k(out.acked, rows, r_id, hash, e)
				else
					out.total = out.total + 1
					if old then
						out.old = out.old + 1
						reasons[reason] = (reasons[reason] or 0) + 1
					end
					top_k(out.open, rows, r_id, hash, e)
				end
			end
		end
	end
	local sorted = {}
	for reason, n in pairs(reasons) do sorted[#sorted + 1] = { reason, n } end
	table.sort(sorted, counts_before)
	out.sorted_reasons = sorted
	return out
end

--- Stations failing: status from the records as they are now (as the Stations chips count them), throttling from
--- the diagnostics walk, misconfigured from the lint bits. Only flagged records reach the item check.
--- @param snapshot Snapshot
--- @param item string?
--- @param throttling {[uint]: true}
--- @return table
local function failing_model(snapshot, item, throttling)
	local out = { no_power = 0, disabled = 0, throttling = 0, misconfigured = 0, total = 0, lint_bits = {} }
	local bits = out.lint_bits
	for id, st in pairs(snapshot.stations) do
		local status = st.status
		local lint = st.lint or 0
		local np, dis, thr = status == "no_power", status == "disabled", throttling[id] == true
		if (np or dis or thr or lint ~= 0) and (not item or station_has_item(st, item)) then
			out.total = out.total + 1
			if np then out.no_power = out.no_power + 1 end
			if dis then out.disabled = out.disabled + 1 end
			if thr then out.throttling = out.throttling + 1 end
			if lint ~= 0 then
				out.misconfigured = out.misconfigured + 1
				local bit = 0
				while lint ~= 0 and bit < 32 do
					if bit32.btest(lint, 1) then bits[bit] = (bits[bit] or 0) + 1 end
					lint = bit32.rshift(lint, 1)
					bit = bit + 1
				end
			end
		end
	end
	return out
end

--- Fleet headroom: the network whose fewest available trains over the period is lowest.
--- @param window StatsWindow
--- @return table
local function fleet_model(window)
	local mins = window.min_available_by_network
	local now = stats.get().available_count
	-- The counters only know networks that had a train available at some point; a network whose trains are all
	-- busy or stuck since the load is the worst of all, at 0.
	local seen = {}
	for _, train in pairs(storage.trains) do
		local net = train.network_name
		if net == NETWORK_EACH then
			local mask = train.network_mask
			if type(mask) == "table" then
				for n in pairs(mask) do seen[n] = true end
			end
		elseif net then
			seen[net] = true
		end
	end
	for name in pairs(seen) do
		if mins[name] == nil then mins[name] = 0 end
	end
	local names = {}
	for name in pairs(mins) do names[#names + 1] = name end
	table.sort(names, function(a, b)
		if mins[a] ~= mins[b] then return mins[a] < mins[b] end
		return a < b
	end)
	local worst = names[1]
	local minutes = math.max(window.span_ticks / 3600, 1 / 60)
	local per_minute = window.deliveries / minutes
	local busy = window.cycle_avg and per_minute * window.cycle_avg / 60 or nil
	return {
		worst = worst,
		headline = worst and mins[worst] or nil,
		now = worst and (now[worst] or 0) or nil,
		failures = window.no_train_failures,
		names = names,
		mins = mins,
		current = now,
		per_minute = per_minute,
		trip = window.cycle_avg,
		busy = busy,
	}
end

--- Everything the tab shows, from the snapshot, storage.diag and storage.stats.
--- @param player_data PlayerData
--- @return table
function overview_tab.model(player_data)
	local snapshot = collector.get()
	local now = game.tick
	local item = player_data.search_item
	if item and not util.signal_hash_valid(item) then item = nil end
	local period = get_period(player_data)
	local minutes = unserved_minutes(player_data)
	local layout = player_data.layout
	local rows = layout and layout.rows_by_tab[TAB] or 10
	local tracking = mod_settings.track_request_wait_times == true
	local window = stats.aggregate(period)
	local d = storage.diag
	local collecting = snapshot.tick == nil
	local unserved = d and unserved_model(d, item, rows, minutes * 3600, now) or nil
	local failing = not collecting and failing_model(snapshot, item, unserved and unserved.throttling or {}) or nil
	local cycle = stats.get().cycle
	return {
		now = now,
		item = item,
		period = period,
		minutes = minutes,
		rows = rows,
		tracking = tracking,
		collecting = collecting,
		diag = d ~= nil,
		inherit_before = d and diag.inherit_threshold(d) or 0,
		dropped = d and d.unserved_dropped or 0,
		unserved = unserved,
		failing = failing,
		fleet = fleet_model(window),
		throughput = {
			deliveries = window.deliveries,
			amount = window.amount,
			dispatches = window.dispatches,
			trip = window.cycle_avg,
			wait_avg = tracking and window.wait_avg or nil,
			wait_max = tracking and window.wait_max or nil,
			recorded = window.partial and window.span_ticks or nil,
			cycle_ticks = cycle.ticks_last or 0,
			cycle_dispatches = cycle.dispatches_last or 0,
		},
	}
end

-- ---------------------------------------------------------------- render: tiles

--- LocalisedString captions cannot be compared with the element's, so the last plain-string signature written is
--- kept per player and element.
--- @param cache table
--- @param elem LuaGuiElement?
--- @param sig string
--- @param caption LocalisedString
local function set_caption(cache, elem, sig, caption)
	if not (elem and elem.valid) then return end
	local key = elem.name
	if cache[key] == sig then return end
	cache[key] = sig
	elem.caption = caption
end

--- @param cache table
--- @param elem LuaGuiElement?
--- @param sig string
--- @param tooltip LocalisedString
local function set_tooltip(cache, elem, sig, tooltip)
	if not (elem and elem.valid) then return end
	local key = elem.name .. "#tooltip"
	if cache[key] == sig then return end
	cache[key] = sig
	elem.tooltip = tooltip
end

--- @param player_data PlayerData
--- @return table
local function caption_cache(player_data)
	local state = util.gui_state(player_data, "overview_captions")
	state.captions = state.captions or {}
	return state.captions
end

--- @param refs table
--- @param cache table
--- @param tile string
--- @param i int
--- @param label_sig string
--- @param label LocalisedString
--- @param value string
local function set_line(refs, cache, tile, i, label_sig, label, value)
	local base = "overview_" .. tile .. "_line" .. i
	set_caption(cache, refs[base .. "_label"], label_sig, label)
	set_caption(cache, refs[base .. "_value"], value, value)
end

local function red_if(n, s)
	if n and n > 0 then return "[color=255,90,90]" .. s .. "[/color]" end
	return s
end

--- @param name string network signal name
--- @return string
local function network_icon(name)
	local _, image = util.generate_item_references(name)
	return image ~= "" and image or name
end

local function render_unserved_tile(refs, cache, model)
	local u = model.unserved
	local minutes = tostring(model.minutes)
	set_caption(cache, refs.overview_unserved_caption, minutes, { "cybersyn-gui.overview-tile-unserved", minutes })
	if not u or model.collecting then
		set_caption(cache, refs.overview_unserved_headline, NO_VALUE, NO_VALUE)
		set_caption(cache, refs.overview_unserved_note, "", "")
		for i = 1, 4 do set_line(refs, cache, "unserved", i, "", "", "") end
		local sig = u and "collecting" or "off"
		set_tooltip(cache, refs.overview_tile_unserved, sig, u and { "cybersyn-gui.stations-collecting" } or { "cybersyn-gui.unserved-diag-off" })
		return
	end
	set_caption(cache, refs.overview_unserved_headline, tostring(u.old), format.number(u.old))
	local note = u.old_acked > 0 and { "cybersyn-gui.overview-acked-note", tostring(u.old_acked) } or ""
	set_caption(cache, refs.overview_unserved_note, tostring(u.old_acked), note)
	local sorted = u.sorted_reasons
	for i = 1, 4 do
		local entry = i <= TOP_REASONS and sorted[i] or nil
		if entry then
			set_line(refs, cache, "unserved", i, "r" .. entry[1], { "cybersyn-diag.chip-" .. REASON_KEYS[entry[1]] }, format.number(entry[2]))
		elseif i == 4 and #sorted > TOP_REASONS then
			local rest = 0
			for k = TOP_REASONS + 1, #sorted do rest = rest + sorted[k][2] end
			set_line(refs, cache, "unserved", i, "other", { "cybersyn-gui.overview-other-reasons" }, format.number(rest))
		else
			set_line(refs, cache, "unserved", i, "", "", "")
		end
	end
	local parts = {}
	for i, entry in ipairs(sorted) do parts[i] = entry[1] .. ":" .. entry[2] end
	local sig = table.concat(parts, ",") .. "|" .. u.old_acked .. "|" .. model.minutes
	local tooltip = { "", { "cybersyn-gui.overview-tile-unserved-tooltip", minutes } }
	for i, entry in ipairs(sorted) do
		if i > 18 then break end
		tooltip[#tooltip + 1] = { "", "\n", { "cybersyn-diag.reason-" .. REASON_KEYS[entry[1]] }, ": ", format.number(entry[2]) }
	end
	if u.old_acked > 0 then
		tooltip[#tooltip + 1] = { "", "\n", { "cybersyn-gui.overview-acked-line", tostring(u.old_acked) } }
	end
	set_tooltip(cache, refs.overview_tile_unserved, sig, tooltip)
end

local function render_fleet_tile(refs, cache, model)
	local f = model.fleet
	set_caption(cache, refs.overview_fleet_caption, "c", { "cybersyn-gui.overview-tile-fleet" })
	set_caption(cache, refs.overview_fleet_note, "", "")
	local headline = f.headline and format.number(f.headline) or NO_VALUE
	if f.headline == 0 then headline = "[color=255,90,90]0[/color]" end
	set_caption(cache, refs.overview_fleet_headline, headline, headline)
	set_line(refs, cache, "fleet", 1, "now", { "cybersyn-gui.overview-fleet-now" }, f.now and format.number(f.now) or NO_VALUE)
	set_line(refs, cache, "fleet", 2, "fail", { "cybersyn-gui.overview-fleet-failures" }, red_if(f.failures, format.number(f.failures)))
	set_line(refs, cache, "fleet", 3, "worst", { "cybersyn-gui.overview-fleet-worst" }, f.worst and network_icon(f.worst) or NO_VALUE)
	local parts = {}
	for i, name in ipairs(f.names) do parts[i] = name .. ":" .. f.mins[name] .. ":" .. (f.current[name] or 0) end
	local busy = f.busy and string.format("%.1f", f.busy) or "-"
	local sig = table.concat(parts, ",") .. "|" .. busy .. "|" .. model.period
	local tooltip = { "", { "cybersyn-gui.overview-tile-fleet-tooltip", { "cybersyn-gui.overview-scope-" .. model.period } } }
	for i, name in ipairs(f.names) do
		if i > MAX_TOOLTIP_NETWORKS then
			tooltip[#tooltip + 1] = { "", "\n", { "cybersyn-gui.overview-more-networks", tostring(#f.names - MAX_TOOLTIP_NETWORKS) } }
			break
		end
		tooltip[#tooltip + 1] = { "", "\n", { "cybersyn-gui.overview-fleet-network", network_icon(name),
			format.number(f.mins[name]), format.number(f.current[name] or 0) } }
	end
	if f.busy then
		tooltip[#tooltip + 1] = { "", "\n\n", { "cybersyn-gui.overview-fleet-littles-law", string.format("%.1f", f.per_minute),
			util.short_duration(f.trip * 60), busy } }
	end
	set_tooltip(cache, refs.overview_tile_fleet, sig, tooltip)
end

local function render_failing_tile(refs, cache, model)
	local f = model.failing
	set_caption(cache, refs.overview_failing_caption, "c", { "cybersyn-gui.overview-tile-failing" })
	set_caption(cache, refs.overview_failing_note, "", "")
	if not f then
		set_caption(cache, refs.overview_failing_headline, NO_VALUE, NO_VALUE)
		for i, line in ipairs(FAILING_LINES) do
			set_line(refs, cache, "failing", i, line, { "cybersyn-gui.overview-failing-" .. string.gsub(line, "_", "-") }, NO_VALUE)
		end
		set_tooltip(cache, refs.overview_tile_failing, "collecting", { "cybersyn-gui.stations-collecting" })
		return
	end
	set_caption(cache, refs.overview_failing_headline, tostring(f.total), red_if(f.total, format.number(f.total)))
	for i, line in ipairs(FAILING_LINES) do
		local n = f[line]
		set_line(refs, cache, "failing", i, line, { "cybersyn-gui.overview-failing-" .. string.gsub(line, "_", "-") },
			red_if(n, format.number(n)))
	end
	local bits = {}
	for bit in pairs(f.lint_bits) do bits[#bits + 1] = bit end
	table.sort(bits)
	local parts = {}
	for i, bit in ipairs(bits) do parts[i] = bit .. ":" .. f.lint_bits[bit] end
	local sig = table.concat(parts, ",")
	local tooltip = { "", { "cybersyn-gui.overview-tile-failing-tooltip" } }
	if #bits > 0 then
		tooltip[#tooltip + 1] = { "", "\n\n", { "cybersyn-gui.overview-failing-lint-header" } }
		for i, bit in ipairs(bits) do
			if i > 16 then break end
			tooltip[#tooltip + 1] = { "", "\n", { "cybersyn-gui.overview-failing-lint-bit", tostring(bit), format.number(f.lint_bits[bit]) } }
		end
	end
	set_tooltip(cache, refs.overview_tile_failing, sig, tooltip)
end

local function render_throughput_tile(refs, cache, model)
	local t = model.throughput
	local period = tostring(model.period)
	set_caption(cache, refs.overview_throughput_caption, period,
		{ "", { "cybersyn-gui.overview-tile-throughput" }, " · ", { "cybersyn-gui.overview-scope-short-" .. period } })
	local recorded = t.recorded and util.short_duration(t.recorded) or ""
	set_caption(cache, refs.overview_throughput_note, recorded, t.recorded and { "cybersyn-gui.overview-period-recorded", recorded } or "")
	set_caption(cache, refs.overview_throughput_headline, tostring(t.deliveries), format.number(t.deliveries))
	local trip = t.trip and util.short_duration(t.trip * 60) or NO_VALUE
	local wait_avg = t.wait_avg and util.short_duration(t.wait_avg) or NO_VALUE
	local wait_max = t.wait_max and util.short_duration(t.wait_max) or NO_VALUE
	set_line(refs, cache, "throughput", 1, "trip", { "cybersyn-gui.overview-throughput-trip" }, trip)
	set_line(refs, cache, "throughput", 2, "wavg", { "cybersyn-gui.overview-throughput-wait-avg" }, wait_avg)
	set_line(refs, cache, "throughput", 3, "wmax", { "cybersyn-gui.overview-throughput-wait-max" }, wait_max)
	local per_cycle = t.cycle_ticks > 0 and string.format("%.1f", t.cycle_dispatches) or ""
	local sig = table.concat({ t.amount, t.dispatches, tostring(model.tracking), t.cycle_ticks, per_cycle, period }, "|")
	local tooltip = {
		"", { "cybersyn-gui.overview-tile-throughput-tooltip", { "cybersyn-gui.overview-scope-" .. period } },
		"\n", { "cybersyn-gui.overview-throughput-items", format.number(t.amount) },
		"\n", { "cybersyn-gui.overview-throughput-dispatches", format.number(t.dispatches) },
	}
	if t.cycle_ticks > 0 then
		tooltip[#tooltip + 1] = "\n"
		tooltip[#tooltip + 1] = { "cybersyn-gui.overview-throughput-cycle", tostring(t.cycle_ticks), per_cycle }
	end
	if not model.tracking then
		tooltip[#tooltip + 1] = "\n\n"
		tooltip[#tooltip + 1] = { "cybersyn-gui.overview-throughput-wait-off" }
	end
	set_tooltip(cache, refs.overview_tile_throughput, sig, tooltip)
end

--- @param player_data PlayerData
--- @param model table
local function render_tiles(player_data, model)
	local refs = player_data.refs
	local cache = caption_cache(player_data)
	render_unserved_tile(refs, cache, model)
	render_fleet_tile(refs, cache, model)
	render_failing_tile(refs, cache, model)
	render_throughput_tile(refs, cache, model)

	local dropdown = refs.overview_period_dropdown
	if dropdown and dropdown.valid then
		for i, minutes in ipairs(PERIODS) do
			if minutes == model.period and dropdown.selected_index ~= i then dropdown.selected_index = i end
		end
	end
	local toggle = refs.overview_show_acked
	if toggle and toggle.valid then
		local n = model.unserved and model.unserved.acked_total or 0
		set_caption(cache, toggle, tostring(n), { "cybersyn-gui.overview-show-acked", tostring(n) })
		local state = player_data.overview_show_acked == true
		if toggle.state ~= state then toggle.state = state end
	end
end

-- ---------------------------------------------------------------- render: Unserved table

--- @class OverviewNameView
--- @field name string full rich-text name, for tooltips
--- @field text string the name's text part
--- @field icons {sprite: string, quality: string?}[]

local parsed_cache = {}

--- Name parts of a station the snapshot does not hold (yet): parsed once per distinct name. A pure function of the
--- name, so a cache that differs between Lua states cannot desync anything.
--- @param name string
--- @return RichNameParts
local function parse_name(name)
	local p = parsed_cache[name]
	if not p then
		p = util.parse_rich_name(name)
		parsed_cache[name] = p
	end
	return p
end

--- @param id uint?
--- @param snapshot Snapshot
--- @return OverviewNameView?
--- @return SnapshotStation?
local function station_view(id, snapshot)
	if not id then return nil end
	local st = snapshot.stations[id]
	local name, parts
	if st then
		name, parts = st.name, st.name_parts
	else
		local station = storage.stations[id]
		local stop = station and station.entity_stop
		if not (stop and stop.valid) then return nil end
		name = stop.backer_name
		parts = parse_name(name)
	end
	local icons = {}
	local lead = parts and parts.lead
	if lead then
		for i = 1, math.min(#lead, NAME_ICONS) do
			icons[i] = { sprite = lead[i], quality = parts.lead_quality and parts.lead_quality[i] or nil }
		end
	end
	local label = parts and parts.text or name
	if label == nil or label == "" then label = name end
	return { name = name, text = label, icons = icons }, st
end

--- @param view OverviewNameView
--- @return string
local function view_sig(view)
	if not view then return "" end
	return view.name
end

--- @param view OverviewNameView?
--- @param extra LocalisedString?
--- @return LocalisedString
local function station_tooltip(view, extra)
	if not view then return "" end
	local tooltip = { "", "[font=default-semibold]", view.name, "[/font]" }
	if extra then
		tooltip[#tooltip + 1] = "\n"
		tooltip[#tooltip + 1] = extra
	end
	tooltip[#tooltip + 1] = "\n"
	tooltip[#tooltip + 1] = util.LINK_FOOTER
	return tooltip
end

--- Every interactive cell joins the table's hover hold, so rows do not reorder under the cursor.
--- @param def flib.GuiElemDef
--- @return flib.GuiElemDef
local function hoverable(def)
	return util.hoverable(def, TABLE)
end

--- @param view OverviewNameView?
--- @param id uint?
--- @return string
local function icons_sig(view, id)
	return (view and view.name or "") .. "|" .. tostring(id)
end

--- @param view OverviewNameView
--- @param tags table
--- @param tooltip LocalisedString
--- @param i int
--- @return flib.GuiElemDef
local function name_icon(view, tags, tooltip, i)
	local icon = view.icons[i]
	-- Each icon gets its own tags table: util.hoverable writes into it.
	return hoverable({
		type = "sprite-button",
		style = "cybersyn_name_icon",
		sprite = helpers.is_valid_sprite_path(icon.sprite) and icon.sprite or "utility/questionmark",
		quality = icon.quality,
		tooltip = tooltip,
		tags = { kind = tags.kind, id = tags.id },
		handler = { [defines.events.on_gui_click] = util.handle.link_click },
	})
end

--- A link cell: up to three icons from the name, then its text. The click handler is always attached, even
--- without a target, because an in-place update rewrites only the tags (flib keeps its handler name there).
--- @param view OverviewNameView?
--- @param kind string
--- @param id uint?
--- @param width int
--- @param tooltip LocalisedString
--- @param acked boolean
--- @return flib.GuiElemDef
local function name_cell(view, kind, id, width, tooltip, acked)
	local tags = id and { kind = kind, id = id } or {}
	local icons = {
		type = "flow",
		direction = "horizontal",
		style = "cybersyn_unserved_icon_flow",
		tags = { s = icons_sig(view, id) },
	}
	if view then
		for i = 1, #view.icons do
			icons[i] = name_icon(view, tags, tooltip, i)
		end
	end
	return {
		type = "flow",
		direction = "horizontal",
		style = "cybersyn_unserved_cell_flow",
		style_mods = { width = width },
		icons,
		hoverable({
			type = "button",
			style = acked and "cybersyn_link_button_acked" or "cybersyn_link_button",
			style_mods = { maximal_width = width - ICON_ROW - 4 },
			caption = view and view.text or NO_VALUE,
			enabled = view ~= nil,
			tooltip = tooltip,
			tags = { kind = tags.kind, id = tags.id },
			mouse_button_filter = { "left" },
			handler = { [defines.events.on_gui_click] = util.handle.link_click },
		}),
	}
end

--- Rewrites a name cell in place; the icons are rebuilt only when the name or the target changed.
--- @param cell LuaGuiElement
--- @param view OverviewNameView?
--- @param kind string
--- @param id uint?
--- @param tooltip LocalisedString
--- @param acked boolean
local function update_name_cell(cell, view, kind, id, tooltip, acked)
	local icons, button = cell.children[1], cell.children[2]
	local tags = id and { kind = kind, id = id } or {}
	local isig = icons_sig(view, id)
	if icons.tags.s ~= isig then
		icons.clear()
		if view then
			for i = 1, #view.icons do
				gui.add(icons, name_icon(view, tags, tooltip, i))
			end
		end
		icons.tags = { s = isig }
	else
		for _, icon in ipairs(icons.children) do
			icon.tooltip = tooltip
		end
	end
	local style = acked and "cybersyn_link_button_acked" or "cybersyn_link_button"
	if button.style.name ~= style then
		local w = button.style.maximal_width
		button.style = style
		button.style.maximal_width = w
	end
	button.caption = view and view.text or NO_VALUE
	button.enabled = view ~= nil
	button.tooltip = tooltip
	-- flib keeps its handler name in the tags (and util.hoverable its scope); only kind and id change.
	local t = button.tags
	t.kind, t.id = tags.kind, tags.id
	button.tags = t
end

--- @param network_name string?
--- @return LocalisedString
local function network_text(network_name)
	if not network_name then return "?" end
	if network_name == NETWORK_EACH then return { "cybersyn-gui.network-each" } end
	return network_icon(network_name)
end

local function surface_name(index)
	local s = game.get_surface(index)
	return s and s.name or tostring(index)
end

--- One table row's data and its cells.
--- @param row {r_id: uint, hash: string, e: DiagEntry}
--- @param acked boolean
--- @param ctx table
--- @return table? entry for util.sync_table_rows
local function row_entry(row, acked, ctx)
	local hash, e, r_id = row.hash, row.e, row.r_id
	local sprite, quality, item_tooltip = util.item_sprite_and_tooltip(hash)
	if not sprite then return nil end
	local now = ctx.now
	local requester, r_st = station_view(r_id, ctx.snapshot)
	local reason = e.reason
	local p_id = reason ~= REASON_NO_PROVIDER and e.p_station_id or nil
	local provider = p_id and station_view(p_id, ctx.snapshot) or nil
	local lost = e.lost_n > 0 and e.lost_to and station_view(e.lost_to, ctx.snapshot) or nil
	local wait = now - e.first_tick
	local inherited = e.first_tick < ctx.inherit_before
	local wait_caption = text.wait_caption(wait, inherited, util.short_duration)
	local read_age = r_st and r_st.read_tick and now - r_st.read_tick or nil
	local requested
	if r_st then
		local req = r_st.requested[hash]
		if req then requested = -req.count end
	end
	local sig = table.concat({
		reason, e.a, e.b, tostring(p_id), view_sig(provider), view_sig(requester), tostring(e.lost_to), e.lost_n, e.n,
		acked and "a" or "", inherited and "i" or "", math.floor(wait / text.READ_STEP), text.read_step(read_age), tostring(requested),
	}, "|")
	local widths = ctx.widths
	local key = r_id .. "|" .. hash
	local function tooltips()
		local read = read_age and text.read_ago(read_age, util.format_duration) or nil
		local chip = text.chip_tooltip({
			item = item_tooltip,
			requested = requested,
			requester = requester and requester.name or tostring(r_id),
			reason = reason,
			a = e.a,
			b = e.b,
			network = network_text(r_st and r_st.network_name),
			rej = e.rej,
			wait = wait,
			inherited = inherited,
			n = e.n,
			read_age = read_age,
			surface_name = surface_name,
		}, util.format_duration)
		local r_tip = station_tooltip(requester, read)
		local p_tip = station_tooltip(provider, nil)
		local l_tip = lost and station_tooltip(lost, { "cybersyn-diag.lost-priority", lost.name, tostring(e.lost_n) }) or ""
		local ack
		if acked then
			local a = diag.is_acked("request", r_id, hash)
			local who = a and a.player_index and game.get_player(a.player_index)
			local until_text = a and a.until_tick and util.format_duration(a.until_tick - now) or nil
			ack = { "cybersyn-gui.unserved-ack-tooltip-acked", who and who.name or "-",
				until_text and { "cybersyn-gui.unserved-ack-for", until_text } or { "cybersyn-gui.unserved-ack-reason" } }
		else
			ack = { "cybersyn-gui.unserved-ack-tooltip" }
		end
		local item_tip = { "", { "cybersyn-gui.item-click-hint" } }
		return chip, r_tip, p_tip, l_tip, ack, item_tip
	end
	local stock = text.stock_caption(reason, e.a, e.b)
	local value_style = acked and "cybersyn_unserved_value_acked" or "cybersyn_unserved_value"
	local link_style = acked and "cybersyn_link_button_acked" or "cybersyn_link_button"
	local cell_style = acked and "cybersyn_unserved_cell_acked" or "cybersyn_unserved_cell"
	local lost_caption = lost and ("×" .. e.lost_n) or ""
	return {
		key = key,
		sig = sig,
		row = row,
		acked = acked,
		build = function()
			local chip, r_tip, p_tip, l_tip, ack, item_tip = tooltips()
			local link = { [defines.events.on_gui_click] = util.handle.link_click }
			return {
				hoverable({
					type = "sprite-button",
					style = "cybersyn_unserved_item",
					sprite = sprite,
					quality = quality,
					elem_tooltip = util.elem_tooltip(hash),
					tooltip = item_tip,
					tags = { kind = "item", id = hash },
					mouse_button_filter = { "left", "right" },
					handler = link,
				}),
				name_cell(requester, "station", r_id, widths.requester, r_tip, acked),
				hoverable({
					type = "button",
					style = acked and "cybersyn_chip_grey" or text.chip_style(reason),
					style_mods = { width = W.why },
					caption = text.chip_caption(reason),
					tooltip = chip,
				}),
				name_cell(provider, "station", p_id, widths.provider, p_tip, acked),
				hoverable({ type = "label", style = value_style, style_mods = { width = W.stock }, caption = stock }),
				{
					type = "flow",
					direction = "horizontal",
					style = "cybersyn_unserved_cell_flow",
					style_mods = { width = W.lost },
					hoverable({
						type = "button",
						style = link_style,
						style_mods = { maximal_width = W.lost - 32 },
						caption = lost and lost.text or "",
						tooltip = l_tip,
						tags = lost and { kind = "station", id = e.lost_to } or {},
						mouse_button_filter = { "left" },
						handler = link,
					}),
					hoverable({ type = "label", style = cell_style, caption = lost_caption, tooltip = l_tip }),
				},
				hoverable({ type = "label", style = value_style, style_mods = { width = W.wait }, caption = wait_caption }),
				hoverable({
					type = "sprite-button",
					style = "cybersyn_unserved_ack",
					sprite = "utility/check_mark",
					toggled = acked,
					tooltip = ack,
					tags = { r_id = r_id, hash = hash },
					handler = { [defines.events.on_gui_click] = overview_tab.handle.overview_ack_click },
				}),
			}
		end,
		update = function(cells)
			local chip, r_tip, p_tip, l_tip, ack, item_tip = tooltips()
			cells[1].tooltip = item_tip
			update_name_cell(cells[2], requester, "station", r_id, r_tip, acked)
			local chip_style = acked and "cybersyn_chip_grey" or text.chip_style(reason)
			if cells[3].style.name ~= chip_style then
				cells[3].style = chip_style
				cells[3].style.width = W.why
			end
			cells[3].caption = text.chip_caption(reason)
			cells[3].tooltip = chip
			update_name_cell(cells[4], provider, "station", p_id, p_tip, acked)
			for _, c in ipairs({ { cells[5], W.stock }, { cells[7], W.wait } }) do
				if c[1].style.name ~= value_style then
					c[1].style = value_style
					c[1].style.width = c[2]
				end
			end
			cells[5].caption = stock
			local lost_button, lost_label = cells[6].children[1], cells[6].children[2]
			if lost_button.style.name ~= link_style then
				lost_button.style = link_style
				lost_button.style.maximal_width = W.lost - 32
			end
			if lost_label.style.name ~= cell_style then lost_label.style = cell_style end
			lost_button.caption = lost and lost.text or ""
			lost_button.tooltip = l_tip
			local t = lost_button.tags
			t.kind, t.id = lost and "station" or nil, lost and e.lost_to or nil
			lost_button.tags = t
			lost_label.caption = lost_caption
			lost_label.tooltip = l_tip
			cells[7].caption = wait_caption
			cells[8].toggled = acked
			cells[8].tooltip = ack
		end,
	}
end

--- @param player_data PlayerData
--- @param model table
local function render_table(player_data, model)
	local refs = player_data.refs
	local tbl = refs[TABLE]
	if not (tbl and tbl.valid) then return end
	local cache = caption_cache(player_data)
	local u = model.unserved
	local widths = player_data.overview_widths
	if not widths then return end
	local entries = {}
	local shown_total = 0
	if u and not model.collecting then
		local ctx = { now = model.now, snapshot = collector.get(), inherit_before = model.inherit_before, widths = widths }
		local rows = model.rows
		for _, row in ipairs(u.open) do
			if #entries >= rows then break end
			local entry = row_entry(row, false, ctx)
			if entry then entries[#entries + 1] = entry end
		end
		if player_data.overview_show_acked then
			for _, row in ipairs(u.acked) do
				if #entries >= rows then break end
				local entry = row_entry(row, true, ctx)
				if entry then entries[#entries + 1] = entry end
			end
		end
		shown_total = u.total + (player_data.overview_show_acked and u.acked_total or 0)
	end
	-- Rows key on (requester, item), so a wait that reorders them is a structural change the hover hold defers.
	util.sync_table_rows(tbl, TABLE_COLUMNS, TABLE_COLUMNS, entries, util.gui_state(player_data, TABLE),
		util.hold_active(player_data, TABLE))

	local empty_flow, empty = refs.overview_unserved_empty_flow, refs.overview_unserved_empty
	local show_empty = #entries == 0
	if empty_flow.visible ~= show_empty then empty_flow.visible = show_empty end
	if show_empty then
		local sig, caption
		if not u then
			sig, caption = "off", { "cybersyn-gui.unserved-diag-off" }
		elseif model.collecting then
			sig, caption = "collecting", { "cybersyn-gui.stations-collecting" }
		elseif model.item then
			sig, caption = "empty-item", { "cybersyn-gui.unserved-empty-item" }
		else
			sig, caption = "empty", { "cybersyn-gui.unserved-empty" }
		end
		set_caption(cache, empty, sig, caption)
	end

	local count = refs.overview_unserved_count
	if u and not model.collecting and shown_total > 0 then
		local shown = tostring(#entries) .. "/" .. shown_total
		set_caption(cache, count, shown, { "cybersyn-gui.unserved-count", format.number(#entries), format.number(shown_total) })
	else
		set_caption(cache, count, "", "")
	end
	local dropped = refs.overview_unserved_dropped
	local n = model.dropped
	if dropped and dropped.valid then
		local show = n > 0
		if dropped.visible ~= show then dropped.visible = show end
		if show then set_caption(cache, dropped, tostring(n), { "cybersyn-gui.unserved-dropped", format.number(n) }) end
	end
	player_data.overview_rendered = #entries
end

--- @param map_data MapData
--- @param player_data PlayerData
function overview_tab.build(map_data, player_data)
	local refs = player_data.refs
	if not (refs.overview_unserved_headline and refs.overview_unserved_headline.valid) then return end
	local model = overview_tab.model(player_data)
	render_tiles(player_data, model)
	render_table(player_data, model)
end

--- Rendered row count of the Unserved table, for dev.rows.
--- @param player_data PlayerData
--- @return int
function overview_tab.rendered_rows(player_data)
	local tbl = player_data.refs[TABLE]
	if not (tbl and tbl.valid) then return 0 end
	return #tbl.children / TABLE_COLUMNS - 1
end

dev.register_rows(TAB, overview_tab.rendered_rows)

dev.register_dump(TAB, function(player_data)
	local model = overview_tab.model(player_data)
	local refs = player_data.refs
	local u = model.unserved
	local tiles = {
		unserved = u and { headline = u.old, acked = u.old_acked, total = u.total, acked_total = u.acked_total,
			reasons = {} } or nil,
		failing = model.failing and { headline = model.failing.total, no_power = model.failing.no_power,
			disabled = model.failing.disabled, throttling = model.failing.throttling,
			misconfigured = model.failing.misconfigured } or nil,
		fleet = { headline = model.fleet.headline, now = model.fleet.now, failures = model.fleet.failures,
			worst = model.fleet.worst },
		throughput = { deliveries = model.throughput.deliveries, amount = model.throughput.amount,
			dispatches = model.throughput.dispatches },
	}
	if u then
		for _, entry in ipairs(u.sorted_reasons) do tiles.unserved.reasons[REASON_NAMES[entry[1]]] = entry[2] end
	end
	local rendered_tiles = {}
	for _, tile in ipairs(TILES) do
		local out = {}
		local function cap(name)
			local e = refs[name]
			return e and e.valid and e.caption or nil
		end
		out.caption = cap("overview_" .. tile.name .. "_caption")
		out.headline = cap("overview_" .. tile.name .. "_headline")
		out.note = cap("overview_" .. tile.name .. "_note")
		out.tooltip = refs["overview_tile_" .. tile.name] and refs["overview_tile_" .. tile.name].tooltip or nil
		out.lines = {}
		for i = 1, tile.lines do
			out.lines[i] = { cap("overview_" .. tile.name .. "_line" .. i .. "_label"), cap("overview_" .. tile.name .. "_line" .. i .. "_value") }
		end
		rendered_tiles[tile.name] = out
	end
	local keys, order, rendered = {}, {}, {}
	local state = util.gui_state(player_data, TABLE)
	if u then
		for i, row in ipairs(u.open) do
			keys[i] = row.r_id .. "|" .. row.hash
			order[i] = row.e.first_tick
		end
	end
	local tbl = refs[TABLE]
	local handler_tag = "__" .. script.mod_name .. "_handler"
	if tbl and tbl.valid then
		local children = tbl.children
		for r = 1, #children / TABLE_COLUMNS - 1 do
			local base = r * TABLE_COLUMNS
			local function c(i) return children[base + i] end
			rendered[r] = {
				item = c(1).tags.id,
				requester = c(2).children[2].caption,
				requester_id = c(2).children[2].tags.id,
				chip = c(3).caption,
				chip_style = c(3).style.name,
				chip_tooltip = c(3).tooltip,
				provider = c(4).children[2].caption,
				provider_id = c(4).children[2].tags.id,
				provider_handler = c(4).children[2].tags[handler_tag] ~= nil,
				hover_scope = c(3).tags.hover_scope,
				stock = c(5).caption,
				lost = c(6).children[2].caption,
				wait = c(7).caption,
				acked = c(8).toggled,
			}
		end
	end
	local empty = refs.overview_unserved_empty
	return {
		period = model.period,
		minutes = model.minutes,
		rows = model.rows,
		tracking = model.tracking,
		diag = model.diag,
		collecting = model.collecting,
		item = model.item,
		show_acked = player_data.overview_show_acked == true,
		tiles = tiles,
		rendered_tiles = rendered_tiles,
		dropped = model.dropped,
		lists = {
			unserved = {
				keys = keys,
				order = order,
				total = u and u.total or 0,
				acked_total = u and u.acked_total or 0,
				rendered = rendered,
				caption = refs.overview_unserved_count.caption,
				empty = empty.parent.visible and empty.caption or nil,
				sigs = state.sigs,
				shown_keys = state.keys,
				held = state.dirty == true,
			},
		},
	}
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

--- @param e EventData.on_gui_selection_state_changed
function overview_tab.handle.overview_period_changed(player, player_data, refs, e)
	local element = e.element
	if not (element and element.valid) then return end
	local minutes = PERIODS[element.selected_index]
	if not minutes or minutes == player_data.overview_period then return end
	player_data.overview_period = minutes
	util.rerender(player, player_data)
end

--- @param e EventData.on_gui_checked_state_changed
function overview_tab.handle.overview_show_acked(player, player_data, refs, e)
	player_data.overview_show_acked = e.element.state or nil
	util.rerender(player, player_data)
end

--- Stations tab with the Unserved chip (phase 4), longest wait first.
--- @param player_data PlayerData
local function jump_unserved(player_data)
	player_data.stations_chip = "unserved"
	util.set_sort(player_data, "stations_tab", "wait", false)
	util.select_tab(player_data, "stations_tab")
end

--- Every tile jumps to the tab that lists what it counts (PLAN3 §4.7).
--- @param e EventData.on_gui_click
function overview_tab.handle.overview_tile_click(player, player_data, refs, e)
	local tile = e.element.tags.tile
	if tile == "unserved" then
		jump_unserved(player_data)
	elseif tile == "fleet" then
		player_data.trains_chip = "parked"
		local worst = overview_tab.model(player_data).fleet.worst
		if worst then player_data.search_network_name = worst end
		util.reset_pages(player_data)
		util.set_sort(player_data, "trains_tab", "train_status", true)
		util.select_tab(player_data, "trains_tab")
		local manager = overview_tab.manager
		if manager then manager.restore_filter_widgets(player_data) end
	elseif tile == "failing" then
		player_data.stations_chip = "failing"
		util.set_sort(player_data, "stations_tab", "station_status", true)
		util.select_tab(player_data, "stations_tab")
	elseif tile == "throughput" then
		util.set_sort(player_data, "inventory_tab", "amount", false)
		util.select_tab(player_data, "inventory_tab")
	else
		return
	end
	local manager = overview_tab.manager
	if manager then manager.refresh_sort_headers(player_data) end
	util.rerender(player, player_data)
end

--- @param e EventData.on_gui_click
function overview_tab.handle.overview_count_click(player, player_data, refs, e)
	jump_unserved(player_data)
	local manager = overview_tab.manager
	if manager then manager.refresh_sort_headers(player_data) end
	util.rerender(player, player_data)
end

--- Acknowledge (PLAN3 §4.13): click = 24 h, shift-click = 1 h, control-click = until the reason changes; a click
--- on an acknowledged row ends it. Display state only; diag.ack writes the event and removes the stop's alerts.
--- @param e EventData.on_gui_click
function overview_tab.handle.overview_ack_click(player, player_data, refs, e)
	local tags = e.element.tags
	local r_id, hash = tags.r_id, tags.hash
	if not (r_id and hash) then return end
	if diag.is_acked("request", r_id, hash) then
		diag.unack("request", r_id, hash, player.index)
	else
		local until_tick
		if e.control then
			until_tick = nil
		elseif e.shift then
			until_tick = game.tick + HOUR
		else
			until_tick = game.tick + DAY
		end
		diag.ack("request", r_id, hash, player.index, until_tick)
	end
	util.rerender(player, player_data)
end

gui.add_handlers(overview_tab.handle, overview_tab.wrapper)

return overview_tab
