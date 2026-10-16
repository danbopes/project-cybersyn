-- Per-item drill-down (PLAN3 §4.10): a left-click on any item cell replaces the active tab's content with one item's
-- providers, requesters (in the dispatcher's order, B2) and trains; the tab strip stays and the back button in the
-- drill-down's subheader returns to the tab that opened it. Everything comes from the collector's snapshot plus the
-- diagnostics' unserved entries; the model (scripts/gui/item-model.lua) is rebuilt only when the snapshot pass or the
-- item changes, and the rows are synced with sig guards, so a steady update writes nothing.

local gui = require("__flib__.gui")
local format = require("__flib__.format")

local util = require("scripts.gui.util")
local collector = require("scripts.gui.collector")
local dev = require("scripts.gui.dev")
local diag = require("scripts.diag")
local text = require("scripts.gui.unserved-text")
local name_cell = require("scripts.gui.name-cell")
local logic = require("scripts.gui.tab-logic")
local item_model = require("scripts.gui.item-model")

--- @class ItemView
--- @field hash string
--- @field from_tab string the tab the drill-down was opened from; back returns there
--- @field host string the tab whose content it replaces (from_tab, or the Inventory when that tab has no content frame)
--- @field hidden int[] indices of the host content's children it hid, shown again on close

--- @class ItemCache
--- @field hash string
--- @field key string snapshot pass the model was built from
--- @field model ItemModel
--- @field alloc {providers: int, requesters: int, trains: int}?
--- @field alloc_sig string?
--- @field delivered int?
--- @field delivered_key string?
--- @field header_sig string?

--- @class PlayerData
--- @field item_view ItemView? the open drill-down
--- @field item_cache ItemCache? its model and render caches; dropped on close
--- @field delivered_items {minute: int, by_period: {[int]: {[string]: int}}}? util.delivered_items' per-minute cache

local item = {}

local TAB = "item_tab"
local VIEW = "item_view"
local NO_VALUE = text.NO_VALUE
local DEFAULT_PERIOD = 60
local ROW = 32
-- Requesters column that shows the wait, and the step of the "last delivery n ago" tooltip age.
local WAIT_COLUMN = 5
local AGE_STEP = 3600
-- Row writes per update (PLAN3 §4.10: 2 ms per update), counted in rows rewritten in place; a new row costs about
-- three rewrites. A table is rewritten whole or not at all, so it always shows one pass's rows in that pass's order
-- (a table left for the next update keeps the previous pass's rows, count and wait clock). New rows are added a few
-- per update below rows that already match the model, as the Trains tab builds its first page.
local WRITE_BUDGET = 18
local BUILD_COST = 3
local RENDER_ORDER = { "requesters", "providers", "trains" }

-- The content element of every tab that can host the drill-down (manager.lua sizes them).
item.CONTENT_FRAMES = {
	overview_tab = "manager_overview_content_frame",
	inventory_tab = "manager_inventory_content_frame",
	stations_tab = "manager_stations_content_frame",
	trains_tab = "manager_trains_tab_content_frame",
	problems_tab = "manager_problems_content_frame",
	log_tab = "manager_log_content_frame",
}

-- The tab captions, for the back button's tooltip.
local TAB_CAPTION = {
	overview_tab = "cybersyn-gui.overview",
	inventory_tab = "cybersyn-gui.inventory",
	stations_tab = "cybersyn-gui.stations",
	trains_tab = "cybersyn-gui.trains",
	problems_tab = "cybersyn-gui.problems",
	log_tab = "cybersyn-gui.log",
	utilization_tab = "cybersyn-gui.utilization-tab",
	delivery_breakdown_tab = "cybersyn-gui.delivery-breakdown-tab",
}

local STATUS_COLOR = {
	no_power = "red",
	disabled = "purple",
	warming_up = "cyan",
	starved = "pink",
	saturated = "orange",
	idle = "white",
	ok = "green",
}

-- Logical px; the station / destination column of each table takes what is left of the content width.
local W = { value = 96, status = 150, priority = 64, wait = 80, why = 132, train = 72, train_status = 150 }
local FRAME_BORDER = 4
local TABLE_PADDING = 4 + 10
local TABLE_SPACING = 8
-- Stations and Trains host the drill-down inside a deep frame, whose border takes a few px of the content width.
local HOST_INSET = 8

--- @class ItemColumn
--- @field kind "station"|"train"|"value"|"text"|"chip"|"status"
--- @field width int? nil = the flexible column
--- @field header string locale key suffix

local COLUMNS = {
	providers = {
		{ kind = "station", header = "station" },
		{ kind = "value", width = W.value, header = "stock" },
		{ kind = "value", width = W.value, header = "threshold" },
		{ kind = "value", width = W.value, header = "out" },
		{ kind = "status", width = W.status, header = "status" },
	},
	requesters = {
		{ kind = "station", header = "station" },
		{ kind = "value", width = W.priority, header = "priority" },
		{ kind = "value", width = W.value, header = "requested" },
		{ kind = "value", width = W.value, header = "threshold" },
		{ kind = "value", width = W.wait, header = "wait" },
		{ kind = "chip", width = W.why, header = "why" },
		{ kind = "value", width = W.value, header = "incoming" },
	},
	trains = {
		{ kind = "train", width = W.train, header = "train" },
		{ kind = "text", width = W.train_status, header = "train-status" },
		{ kind = "value", width = W.value, header = "amount" },
		{ kind = "station", header = "to" },
	},
}

local TRAIN_STATUS

local function train_statuses()
	if not TRAIN_STATUS then
		TRAIN_STATUS = { D = STATUS_D, TO_P = STATUS_TO_P, P = STATUS_P, TO_R = STATUS_TO_R, R = STATUS_R,
			TO_D = STATUS_TO_D, TO_D_BYPASS = STATUS_TO_D_BYPASS, TO_F = STATUS_TO_F, F = STATUS_F }
	end
	return TRAIN_STATUS
end

--- @param t string "providers"|"requesters"|"trains"
local function table_name(t) return "item_" .. t .. "_table" end

--- @param player_data PlayerData
--- @return int minutes
local function get_period(player_data)
	local period = player_data.overview_period
	if period ~= 10 and period ~= 60 and period ~= 1440 then period = DEFAULT_PERIOD end
	return period
end

--- Width of each table's flexible column for the current layout.
--- @param content_width int
--- @return {[string]: int}
local function flex_widths(content_width)
	local out = {}
	for t, cols in pairs(COLUMNS) do
		local fixed = 0
		for _, c in ipairs(cols) do fixed = fixed + (c.width or 0) end
		out[t] = content_width - HOST_INSET - FRAME_BORDER - TABLE_PADDING - (#cols - 1) * TABLE_SPACING - fixed
	end
	return out
end

-- ---------------------------------------------------------------- build

local function header_cell(caption, width, right, tooltip)
	return {
		type = "label",
		style = right and "cybersyn_unserved_header_value" or "cybersyn_unserved_header",
		style_mods = { width = width },
		caption = caption,
		tooltip = tooltip,
	}
end

local function section_def(t, flex)
	local tbl = {
		type = "table",
		name = table_name(t),
		style = "cybersyn_unserved_table",
		column_count = #COLUMNS[t],
	}
	for _, c in ipairs(COLUMNS[t]) do
		local tooltip = c.header == "priority" and { "cybersyn-gui.item-priority-tooltip" } or nil
		tbl[#tbl + 1] = header_cell({ "cybersyn-gui.item-col-" .. c.header }, c.width or flex[t],
			c.kind == "value" or c.kind == "train", tooltip)
	end
	local caption_tooltip = t == "requesters" and { "cybersyn-gui.item-requesters-tooltip" } or nil
	return {
		type = "frame",
		name = "item_" .. t .. "_frame",
		direction = "vertical",
		style = "cybersyn_unserved_frame",
		{
			type = "frame",
			direction = "horizontal",
			style = "cybersyn_unserved_caption_frame",
			style_mods = { height = 36 },
			{
				type = "label",
				name = "item_" .. t .. "_caption",
				style = "subheader_caption_label",
				caption = { "cybersyn-gui.item-" .. t },
				tooltip = caption_tooltip,
			},
			{ type = "empty-widget", style = "flib_horizontal_pusher" },
			{ type = "label", name = "item_" .. t .. "_count", style = "cybersyn_subheader_note", caption = "" },
		},
		{
			type = "flow",
			name = "item_" .. t .. "_body",
			direction = "vertical",
			style_mods = { vertical_spacing = 0 },
			tbl,
			{
				type = "flow",
				name = "item_" .. t .. "_empty_flow",
				direction = "horizontal",
				style = "cybersyn_overview_empty_flow",
				visible = false,
				{
					type = "label",
					style = "cybersyn_overview_empty_label",
					caption = { "cybersyn-gui.item-empty-" .. t },
				},
			},
		},
	}
end

--- @param from_tab string
--- @param layout ManagerLayout
local function view_def(from_tab, layout)
	local flex = flex_widths(layout.content_width)
	local total = function(name)
		return { type = "label", name = "item_total_" .. name, style = "cybersyn_item_total", caption = "" }
	end
	local def = {
		type = "flow",
		name = VIEW,
		direction = "vertical",
		style = "cybersyn_overview_content",
		{
			type = "frame",
			name = "item_subheader",
			style = "cybersyn_tab_subheader",
			{
				type = "sprite-button",
				name = "item_back_button",
				style = "tool_button",
				sprite = "flib_nav_backward_black",
				tooltip = { "cybersyn-gui.item-back-tooltip", { TAB_CAPTION[from_tab] or "cybersyn-gui.overview" } },
				handler = { [defines.events.on_gui_click] = item.handle.item_back },
			},
			{
				type = "sprite-button",
				name = "item_icon",
				style = "cybersyn_item_chip_icon",
				mouse_button_filter = { "left", "right" },
				tags = { kind = "item" },
				handler = { [defines.events.on_gui_click] = util.handle.link_click },
			},
			{ type = "label", name = "item_name", style = "subheader_caption_label", caption = "" },
			{ type = "label", name = "item_collecting", style = "cybersyn_subheader_note", visible = false },
			{ type = "empty-widget", style = "flib_horizontal_pusher" },
			total("provided"),
			total("in_transit"),
			total("requested"),
			total("delivered"),
		},
	}
	for _, t in ipairs(item_model.TABLES) do
		def[#def + 1] = section_def(t, flex)
	end
	return def
end

-- ---------------------------------------------------------------- open / close

--- The tab whose content hosts the drill-down: the tab it is opened from when that tab has a content frame.
--- @param tab string?
--- @return string
local function host_of(tab)
	if tab and item.CONTENT_FRAMES[tab] then return tab end
	return "inventory_tab"
end

--- Drops the drill-down's elements and render state, and shows the host tab's content again.
--- @param player LuaPlayer?
--- @param player_data PlayerData
local function teardown(player, player_data)
	local view = player_data.item_view
	local refs = player_data.refs
	-- Cleared before player.opened is released: the release re-enters on_gui_closed, which must find no drill-down
	-- (otherwise it closes it again with back and re-selects the tab it came from).
	player_data.item_view = nil
	player_data.item_cache = nil
	if view and refs then
		local frame = refs[VIEW]
		-- A rebuilt window has fresh tab contents: nothing of them was hidden.
		local same = frame ~= nil and frame.valid
		if same then frame.destroy() end
		local content = same and refs[item.CONTENT_FRAMES[view.host]]
		if content and content.valid then
			local children = content.children
			for _, i in ipairs(view.hidden or {}) do
				local child = children[i]
				if child then child.visible = true end
			end
		end
	end
	if refs then
		for name, elem in pairs(refs) do
			if string.sub(name, 1, 5) == "item_" and type(elem) == "userdata" then refs[name] = nil end
		end
		refs[VIEW] = nil
	end
	local states = player_data.gui_state
	if states then
		for _, t in ipairs(item_model.TABLES) do states[table_name(t)] = nil end
	end
	util.overlay_closed(player, player_data)
end

--- Closes the drill-down; with `back`, the tab it was opened from is selected again.
--- @param player LuaPlayer?
--- @param player_data PlayerData
--- @param back boolean?
function item.close(player, player_data, back)
	local view = player_data.item_view
	if not view then return end
	local from = view.from_tab
	teardown(player, player_data)
	if back and from then util.select_tab(player_data, from) end
end

--- Opens the drill-down for `hash` in place of the selected tab's content (or switches an open one to `hash`).
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param hash string
function item.open(player, player_data, hash)
	if not util.item_sprite_and_tooltip(hash) then return end
	local view = player_data.item_view
	if view and view.host == player_data.selected_tab and player_data.refs[VIEW] and player_data.refs[VIEW].valid then
		if view.hash ~= hash then
			view.hash = hash
			player_data.item_cache = nil
			-- Every cell is rewritten for the new item: the per-cell memo of the old one says nothing about it.
			local states = player_data.gui_state
			if states then
				for _, t in ipairs(item_model.TABLES) do
					local s = states[table_name(t)]
					if s then s.sigs, s.cells = nil, nil end
				end
			end
		end
		return
	end
	item.close(player, player_data)
	local refs = player_data.refs
	local layout = player_data.layout
	if not layout then return end
	local from = player_data.selected_tab or "overview_tab"
	local host = host_of(from)
	if host ~= from then util.select_tab(player_data, host) end
	local content = refs[item.CONTENT_FRAMES[host]]
	if not (content and content.valid) then return end
	local hidden = {}
	for i, child in ipairs(content.children) do
		if child.name ~= host .. "_banner" and child.visible then
			child.visible = false
			hidden[#hidden + 1] = i
		end
	end
	gui.add(content, view_def(from, layout), refs)
	view = { hash = hash, from_tab = from, host = host, hidden = hidden }
	player_data.item_view = view
	-- A pinned window does not hold player.opened, so Escape would never reach the drill-down: the overlay rule
	-- (manager.PINNED_OVERLAYS_TAKE_OPENED) lets it take it, not in remote view, where Escape must leave the map.
	util.overlay_opened(player, player_data)
end

-- ---------------------------------------------------------------- render

local function station_view(snapshot, id)
	local st = id and snapshot.stations[id]
	if not st then return nil end
	return st
end

--- @param st SnapshotStation?
--- @param extra LocalisedString?
--- @return LocalisedString
local function station_tooltip(st, extra)
	if not st then return "" end
	local tip = { "", "[font=default-semibold]", st.name, "[/font]" }
	if extra then
		tip[#tip + 1] = "\n"
		tip[#tip + 1] = extra
	end
	tip[#tip + 1] = "\n"
	tip[#tip + 1] = util.LINK_FOOTER
	return tip
end

local function network_text(name)
	if not name then return "?" end
	if name == NETWORK_EACH then return { "cybersyn-gui.network-each" } end
	local _, image = util.generate_item_references(name)
	return image ~= "" and image or name
end

--- One cell definition from its column and value.
--- @param col ItemColumn
--- @param v table the cell's value: {caption, tooltip, style?, id?, st?, visible?}
--- @param width int
--- @param scope string
local function cell_def(col, v, width, scope)
	local kind = col.kind
	if kind == "station" then
		local st = v.st
		local name = st and st.name or NO_VALUE
		return name_cell.def(st and st.name_parts, name, { kind = st and "station" or nil, id = st and v.id or nil },
			width, v.tooltip or "", scope)
	elseif kind == "train" then
		return util.hoverable({
			type = "button",
			style = "cybersyn_item_train_button",
			style_mods = { width = width },
			caption = v.caption,
			tooltip = v.tooltip,
			tags = { kind = "train", id = v.id },
			mouse_button_filter = { "left", "right" },
			handler = { [defines.events.on_gui_click] = util.handle.link_click },
		}, scope)
	elseif kind == "chip" then
		return {
			type = "flow",
			direction = "horizontal",
			style = "cybersyn_unserved_cell_flow",
			style_mods = { width = width },
			util.hoverable({
				type = "button",
				style = v.style or "cybersyn_chip_grey",
				style_mods = { maximal_width = width },
				caption = v.caption or "",
				tooltip = v.tooltip,
				visible = v.visible ~= false,
			}, scope),
		}
	elseif kind == "status" then
		return {
			type = "flow",
			direction = "horizontal",
			style = "cybersyn_unserved_cell_flow",
			style_mods = { width = width },
			{ type = "sprite", style = "flib_indicator", sprite = v.sprite },
			{ type = "label", style = "cybersyn_unserved_cell", caption = v.caption, tooltip = v.tooltip },
		}
	end
	return util.hoverable({
		type = "label",
		style = kind == "value" and "cybersyn_unserved_value" or "cybersyn_unserved_cell",
		style_mods = { width = width },
		caption = v.caption,
		tooltip = v.tooltip,
	}, scope)
end

--- Rewrites a cell built by cell_def in place.
local function cell_update(col, cell, v, width, scope)
	local kind = col.kind
	if kind == "station" then
		local st = v.st
		local name = st and st.name or NO_VALUE
		name_cell.update(cell, st and st.name_parts, name, { kind = st and "station" or nil, id = st and v.id or nil },
			width, v.tooltip or "", scope)
	elseif kind == "train" then
		cell.caption = v.caption
		cell.tooltip = v.tooltip
		local t = cell.tags
		t.id = v.id
		cell.tags = t
	elseif kind == "chip" then
		local button = cell.children[1]
		local style = v.style or "cybersyn_chip_grey"
		if button.style.name ~= style then
			button.style = style
			button.style.maximal_width = width
		end
		button.caption = v.caption or ""
		button.tooltip = v.tooltip
		button.visible = v.visible ~= false
	elseif kind == "status" then
		local children = cell.children
		children[1].sprite = v.sprite
		children[2].caption = v.caption
		children[2].tooltip = v.tooltip
	else
		cell.caption = v.caption
		cell.tooltip = v.tooltip
	end
end

--- A row entry for util.sync_table_rows: `values()` builds the cells' values only when the row's sig changed, and a
--- cell is written only when its own sig (`value.sig`) differs from the one memorised for that row position.
--- @param t string
--- @param key int row position
--- @param sig string
--- @param values fun(): table[]
--- @param ctx table widths and the per-table memo (render state, dropped on close)
local function row_entry(t, key, sig, values, ctx)
	local cols = COLUMNS[t]
	local scope = table_name(t)
	local widths = ctx.widths
	local memo = ctx.memo[t]
	return {
		key = key,
		sig = sig,
		build = function()
			local vals = values()
			local defs, sigs = {}, {}
			for i, col in ipairs(cols) do
				defs[i] = cell_def(col, vals[i], col.width or widths[t], scope)
				sigs[i] = vals[i].sig
			end
			memo[key] = sigs
			return defs
		end,
		update = function(cells)
			local vals = values()
			local sigs = memo[key]
			if not sigs then
				sigs = {}
				memo[key] = sigs
			end
			for i, col in ipairs(cols) do
				local v = vals[i]
				if v.sig == nil or sigs[i] ~= v.sig then
					cell_update(col, cells[i], v, col.width or widths[t], scope)
					sigs[i] = v.sig
				end
			end
		end,
	}
end

local function count(n)
	return format_signal_count(n)
end

--- @param r ItemProviderRow
--- @param i int position: rows are keyed by position, so a re-sort rewrites cells instead of rebuilding rows
local function provider_entry(r, ctx, i)
	local st = station_view(ctx.snapshot, r.id)
	local name = st and st.name or ""
	local sig = table.concat({ name, r.stock, tostring(r.threshold), r.out, tostring(r.status) }, "|")
	return row_entry("providers", i, r.id .. "#" .. sig, function()
		local status = r.status or "ok"
		return {
			{ st = st, id = r.id, tooltip = station_tooltip(st, { "cybersyn-gui.item-network", network_text(st and st.network_name) }),
				sig = name .. "\1" .. r.id .. "\1" .. tostring(st and st.network_name) },
			{ caption = count(r.stock), tooltip = format.number(r.stock), sig = tostring(r.stock) },
			r.threshold and { caption = count(r.threshold), tooltip = format.number(r.threshold), sig = tostring(r.threshold) }
				or { caption = NO_VALUE, tooltip = { "cybersyn-gui.item-threshold-none-tooltip" }, sig = "-" },
			{ caption = r.out > 0 and count(r.out) or NO_VALUE, sig = tostring(r.out) },
			{
				sprite = "flib_indicator_" .. (STATUS_COLOR[status] or "white"),
				caption = { "cybersyn-gui.station-status-" .. string.gsub(status, "_", "-") },
				tooltip = { "cybersyn-gui.station-status-" .. string.gsub(status, "_", "-") .. "-tooltip" },
				sig = status,
			},
		}
	end, ctx)
end

--- @param r ItemRequesterRow
--- @param i int
local function requester_entry(r, ctx, i)
	local st = station_view(ctx.snapshot, r.id)
	local name = st and st.name or ""
	local now = ctx.now
	local e = ctx.entries and ctx.ix and ctx.entries[r.id] and ctx.entries[r.id][ctx.ix] or nil
	local acked = e and diag.is_acked("request", r.id, ctx.hash) ~= nil or false
	local wait = r.wait_start and now - r.wait_start or nil
	local age = st and collector.delivery_age(st) or nil
	local network = tostring(st and st.network_name)
	local inherited = e and e.first_tick < ctx.inherit_before or false
	local lost = e and e.lost_n > 0 and e.lost_to and station_view(ctx.snapshot, e.lost_to) or nil
	-- The wait caption has its own clock (wait_clock); the tooltips' ages move in steps, so a steady row is not
	-- rewritten every update. The evaluation count in the chip's tooltip refreshes with that step too.
	local e_sig = e and table.concat({ e.reason, e.a, e.b, acked and "a" or "", inherited and "i" or "",
		math.floor((now - e.first_tick) / text.READ_STEP), table.concat(e.rej, ","), tostring(e.lost_to), e.lost_n,
		lost and lost.name or "" }, "\1") or ""
	local sig = table.concat({
		name, network, r.requested, r.threshold, r.priority, r.group, tostring(r.position), r.incoming, wait and 1 or 0,
		age and math.floor(age / AGE_STEP) or -1, e_sig,
	}, "|")
	local age_step = age and math.floor(age / AGE_STEP) or -1
	local station_sig = table.concat({ name, r.id, tostring(r.position), r.priority, r.group, age_step, network }, "\1")
	-- The chip's tooltip names the requester and its network, so they are part of its sig: rows are keyed by position.
	local chip_sig = table.concat({ r.id, name, network, r.group, r.requested, e_sig, e and e.n or "" }, "\1")
	return row_entry("requesters", i, r.id .. "#" .. sig, function()
		local last = age and { "cybersyn-gui.time-ago", util.short_duration(age - age % AGE_STEP) }
			or { "cybersyn-gui.item-last-served-never" }
		local queue
		if r.position then
			queue = { "cybersyn-gui.item-queue-position", tostring(r.position), tostring(r.priority), last }
		else
			queue = { "cybersyn-gui.item-queue-skipped", { "cybersyn-gui.item-group-" .. item_model.GROUP_KEYS[r.group] },
				tostring(r.priority), last }
		end
		local chip
		if e then
			local reason = e.reason
			chip = {
				sig = chip_sig,
				caption = text.chip_caption(reason),
				style = acked and "cybersyn_chip_acked" or text.chip_style(reason),
				tooltip = text.chip_tooltip({
					item = ctx.item_tooltip,
					requested = r.requested,
					requester = name,
					reason = reason,
					a = e.a,
					b = e.b,
					network = network_text(st and st.network_name),
					rej = e.rej,
					wait = now - e.first_tick,
					inherited = inherited,
					n = e.n,
					surface_name = ctx.surface_name,
				}, util.format_duration),
			}
			if lost then
				local tip = chip.tooltip
				tip[#tip + 1] = "\n"
				tip[#tip + 1] = { "cybersyn-diag.lost-priority", lost.name, tostring(e.lost_n) }
			end
		elseif r.group ~= item_model.QUEUED then
			local key = item_model.GROUP_KEYS[r.group]
			chip = { caption = { "cybersyn-gui.item-group-" .. key }, tooltip = { "cybersyn-gui.item-group-" .. key .. "-tooltip" },
				sig = chip_sig }
		else
			chip = { visible = false, sig = chip_sig }
		end
		return {
			{ st = st, id = r.id, tooltip = station_tooltip(st, { "", queue, "\n",
				{ "cybersyn-gui.item-network", network_text(st and st.network_name) } }), sig = station_sig },
			{ caption = tostring(r.priority), tooltip = { "cybersyn-gui.item-priority-tooltip" }, sig = tostring(r.priority) },
			{ caption = count(r.requested), tooltip = format.number(r.requested), sig = tostring(r.requested) },
			{ caption = count(r.threshold), tooltip = format.number(r.threshold), sig = tostring(r.threshold) },
			-- The seconds are wait_clock's; this cell is written when the row gains or loses a wait.
			{ caption = wait and util.short_duration(wait) or NO_VALUE,
				tooltip = wait and { "cybersyn-gui.waiting-for", util.format_duration(wait) } or { "cybersyn-gui.item-wait-none" },
				sig = wait and "w" or "-" },
			chip,
			{ caption = r.incoming > 0 and count(r.incoming) or NO_VALUE, sig = tostring(r.incoming) },
		}
	end, ctx)
end

--- @param r ItemTrainRow
--- @param i int
local function train_entry(r, ctx, i)
	local to = station_view(ctx.snapshot, r.to)
	local from = station_view(ctx.snapshot, r.from)
	local sig = table.concat({ r.status or -1, r.amount, to and to.name or "", from and from.name or "" }, "|")
	return row_entry("trains", i, r.id .. "#" .. sig, function()
		local chip = item_model.train_chip(r.status, train_statuses())
		local status = chip and { logic.train_chip_locale(chip, false) } or { "cybersyn-gui.trains-custom-status", tostring(r.status) }
		local status_tip = chip and { logic.train_chip_locale(chip, false) .. "-tooltip" } or nil
		local route = { "cybersyn-gui.item-train-route", from and from.name or NO_VALUE, to and to.name or NO_VALUE }
		local route_sig = (from and from.name or "") .. "\1" .. (to and to.name or "")
		return {
			{ caption = tostring(r.id), id = r.id, tooltip = { "", { "cybersyn-gui.item-train-tooltip", tostring(r.id) }, "\n",
				route, "\n", util.LINK_FOOTER }, sig = r.id .. "\1" .. route_sig },
			{ caption = status, tooltip = status_tip, sig = tostring(r.status) },
			{ caption = count(r.amount), tooltip = format.number(r.amount), sig = tostring(r.amount) },
			{ st = to, id = r.to, tooltip = station_tooltip(to, route), sig = tostring(r.to) .. "\1" .. route_sig },
		}
	end, ctx)
end

local ENTRY = { providers = provider_entry, requesters = requester_entry, trains = train_entry }

--- The Wait column of the shown requester rows, every update: one caption write per row whose seconds moved.
--- @param tbl LuaGuiElement
--- @param rows ItemRequesterRow[] the model rows the table shows (the previous pass's while its rewrite waits)
--- @param n int rows built
--- @param now uint
local function wait_clock(tbl, rows, n, now)
	local children
	local cols = #COLUMNS.requesters
	for i = 1, n do
		local start = rows[i] and rows[i].wait_start
		if start then
			children = children or tbl.children
			local cell = children[cols * i + WAIT_COLUMN]
			local caption = util.short_duration(now - start)
			if cell and cell.caption ~= caption then
				cell.caption = caption
				cell.tooltip = { "cybersyn-gui.waiting-for", util.format_duration(now - start) }
			end
		end
	end
end

local function set_caption(elem, caption)
	if elem and elem.valid then elem.caption = caption end
end

--- The subheader: icon, name, totals and delivered in the Overview's period, written when one of them changed.
--- @param player_data PlayerData
--- @param cache ItemCache
local function render_header(player_data, cache)
	local refs = player_data.refs
	local m = cache.model
	local hash = m.hash
	local period = get_period(player_data)
	local minute = math.floor(game.tick / 3600)
	local dkey = period .. ":" .. minute
	if cache.delivered_key ~= dkey then
		cache.delivered_key = dkey
		cache.delivered = util.delivered_items(player_data, period)[hash] or 0
	end
	local t = m.totals
	local collecting = collector.collecting()
	local percent = collecting and math.floor(collecting * 100) or -1
	local sig = table.concat({ hash, t.provided, t.provided_stations, t.in_transit, t.in_transit_stations, t.requested,
		t.requested_stations, cache.delivered, period, percent }, "|")
	if cache.header_sig == sig then return end
	cache.header_sig = sig
	local sprite, quality, name_tooltip = util.item_sprite_and_tooltip(hash)
	local icon = refs.item_icon
	if icon and icon.valid then
		icon.sprite = sprite
		icon.quality = quality
		icon.elem_tooltip = util.elem_tooltip(hash)
		icon.tooltip = { "cybersyn-gui.item-icon-tooltip" }
		local tags = icon.tags
		tags.kind, tags.id = "item", hash
		icon.tags = tags
	end
	set_caption(refs.item_name, name_tooltip and name_tooltip[4] or hash)
	local function total(name, key, value, stations)
		local elem = refs["item_total_" .. name]
		if not (elem and elem.valid) then return end
		elem.caption = { "cybersyn-gui.item-" .. key, count(value) }
		elem.tooltip = stations and { "cybersyn-gui.item-total-tooltip", format.number(value), tostring(stations) } or nil
	end
	total("provided", "provided", t.provided, t.provided_stations)
	total("in_transit", "in-transit", t.in_transit, t.in_transit_stations)
	total("requested", "requested", t.requested, t.requested_stations)
	local delivered = refs.item_total_delivered
	if delivered and delivered.valid then
		delivered.caption = { "cybersyn-gui.item-delivered", { "cybersyn-gui.item-period-" .. period }, count(cache.delivered) }
		delivered.tooltip = { "cybersyn-gui.item-delivered-tooltip", format.number(cache.delivered),
			{ "cybersyn-gui.item-period-" .. period } }
	end
	local note = refs.item_collecting
	if note and note.valid then
		note.visible = collecting ~= nil
		note.caption = collecting and { "cybersyn-gui.collecting-progress", tostring(percent) } or ""
	end
end

--- Body heights from the row split, written only when the split changed.
--- @param refs table
--- @param alloc {[string]: int}
local function apply_alloc(refs, alloc)
	for _, t in ipairs(item_model.TABLES) do
		local rows = alloc[t]
		local body = refs["item_" .. t .. "_body"]
		if body and body.valid then body.style.height = 20 + rows * ROW end
		local empty = refs["item_" .. t .. "_empty_flow"]
		if empty and empty.valid then empty.style.height = rows * ROW end
	end
end

--- @param player_data PlayerData
--- @return ItemCache
--- @return boolean refreshed the model was (re)built in this call: for a new collector pass, a new item or a new view
local function get_cache(player_data, hash)
	local snapshot = collector.get()
	local key = tostring(snapshot.tick) .. ":" .. tostring(snapshot.pass)
	local cache = player_data.item_cache
	if cache and cache.hash == hash and cache.key == key then return cache, false end
	local m = item_model.build(snapshot, hash, SIGNAL_PRIORITY)
	if cache and cache.hash == hash then
		cache.key, cache.model, cache.header_sig = key, m, nil
		return cache, true
	end
	cache = { hash = hash, key = key, model = m }
	player_data.item_cache = cache
	return cache, true
end

--- Renders the open drill-down. False when there is none (or it just closed because another tab was selected),
--- so the selected tab renders instead.
--- @param map_data MapData
--- @param player_data PlayerData
--- @return boolean rendered
function item.build(map_data, player_data)
	local view = player_data.item_view
	if not view then return false end
	local refs = player_data.refs
	local frame = refs[VIEW]
	if player_data.selected_tab ~= view.host or not (frame and frame.valid) or not util.item_sprite_and_tooltip(view.hash) then
		item.close(game.get_player(player_data.player_index), player_data)
		return false
	end
	local profiler = storage.manager.item_samples and game.create_profiler()
	local cache, refreshed = get_cache(player_data, view.hash)
	local m = cache.model
	render_header(player_data, cache)
	-- A new pass rebuilds the model in this update and rewrites the rows in the next ones, so neither update pays
	-- for both (PLAN3 §4.10: 2 ms per update).
	if refreshed then
		cache.rows_pending = true
		if profiler then
			profiler.stop()
			item.samples[#item.samples + 1] = { p = profiler, kind = "R", deferred = 0 }
		end
		return true
	end
	local kind = cache.rows_pending and "P" or "S"
	cache.rows_pending = nil
	local layout = player_data.layout
	local total = layout and layout.rows_by_tab[TAB] or 3

	-- A table under the cursor keeps its rows as they are (the hover hold); new data waits until the cursor leaves.
	local held, any_held = {}, false
	for _, t in ipairs(item_model.TABLES) do
		local name = table_name(t)
		local state = util.gui_state(player_data, name)
		held[t] = state.keys ~= nil and #state.keys > 0 and util.hold_active(player_data, name)
		any_held = any_held or held[t]
	end
	-- A new split changes the three body heights at once, so every table follows it in the same update; it waits
	-- while a table is held.
	local alloc = item_model.split_rows(total, { providers = #m.providers, requesters = #m.requesters, trains = #m.trains })
	local asig = total .. ":" .. alloc.providers .. ":" .. alloc.requesters .. ":" .. alloc.trains
	local forced = false
	if cache.alloc_sig ~= asig and (not any_held or not cache.alloc) then
		cache.alloc_sig = asig
		cache.alloc = alloc
		apply_alloc(refs, alloc)
		forced = true
	end
	alloc = cache.alloc

	local snapshot = collector.get()
	local d = storage.diag
	local hash = view.hash
	local _, _, item_tip = util.item_sprite_and_tooltip(hash)
	local ctx = {
		snapshot = snapshot,
		now = game.tick,
		hash = hash,
		widths = player_data.item_widths or flex_widths(layout.content_width),
		entries = d and d.unserved,
		ix = d and d.item_ix[hash],
		inherit_before = d and diag.inherit_threshold(d) or 0,
		item_tooltip = item_tip,
		surface_name = function(index)
			local s = game.get_surface(index)
			return s and s.name or tostring(index)
		end,
	}
	ctx.memo = {}
	for _, t in ipairs(item_model.TABLES) do
		local state = util.gui_state(player_data, table_name(t))
		-- The cell memo belongs to the rows the state's keys describe; without keys the rows are rebuilt anyway.
		if not (state.cells and state.keys) then state.cells = {} end
		ctx.memo[t] = state.cells
	end
	local budget, wrote, deferred = WRITE_BUDGET, false, 0
	for _, t in ipairs(RENDER_ORDER) do
		local rows = m[t]
		local n = math.min(#rows, alloc[t])
		local name = table_name(t)
		local tbl = refs[name]
		local state = util.gui_state(player_data, name)
		if tbl and tbl.valid and not held[t] then
			local built = state.keys and #state.keys or 0
			local sigs = state.keys and state.sigs
			local entries, changed = {}, 0
			local make = ENTRY[t]
			for i = 1, n do
				local entry = make(rows[i], ctx, i)
				if i <= built and not (sigs and sigs[i] == entry.sig) then changed = changed + 1 end
				entries[i] = entry
			end
			if changed == 0 or forced or not wrote or changed <= budget then
				budget = budget - changed
				wrote = wrote or changed > 0
				if n > built then
					local room = math.max(0, math.floor(budget / BUILD_COST))
					if not wrote and room == 0 then room = 1 end
					local keep = math.min(n, built + room)
					for i = keep + 1, n do entries[i] = nil end
					budget = budget - (keep - built) * BUILD_COST
					wrote = wrote or keep > built
					deferred = deferred + n - keep
				end
				util.sync_table_rows(tbl, #COLUMNS[t], #COLUMNS[t], entries, state)
				state.shown, state.shown_n = rows, n
			else
				deferred = deferred + changed + math.max(0, n - built)
			end
		end
		-- Wait clock, count and empty state follow the rows the table shows, not the model it may not show yet.
		local shown = state.shown
		if t == "requesters" and shown and tbl and tbl.valid then
			wait_clock(tbl, shown, math.min(state.keys and #state.keys or 0, state.shown_n), ctx.now)
		end
		local empty = refs["item_" .. t .. "_empty_flow"]
		local show_empty = shown ~= nil and #shown == 0
		if empty and empty.valid and empty.visible ~= show_empty then empty.visible = show_empty end
		local c = refs["item_" .. t .. "_count"]
		local csig = shown and (state.shown_n .. "/" .. #shown) or ""
		if c and c.valid and state.count_sig ~= csig then
			state.count_sig = csig
			c.caption = shown and { "cybersyn-gui.item-count", tostring(state.shown_n), tostring(#shown) } or ""
		end
	end
	cache.deferred = deferred
	if profiler then
		profiler.stop()
		item.samples[#item.samples + 1] = { p = profiler, kind = kind, deferred = deferred }
	end
	return true
end

--- Recomputes the flexible column widths after a layout change; rows built for other widths are rebuilt.
--- @param player_data PlayerData
--- @param layout ManagerLayout
function item.apply_layout(player_data, layout)
	local widths = flex_widths(layout.content_width)
	local old = player_data.item_widths
	player_data.item_widths = widths
	local cache = player_data.item_cache
	if cache then cache.alloc_sig = nil end
	if old and old.providers == widths.providers then return end
	local refs = player_data.refs
	for _, t in ipairs(item_model.TABLES) do
		local tbl = refs[table_name(t)]
		if tbl and tbl.valid then
			local cols = #COLUMNS[t]
			local children = tbl.children
			for i = #children, cols + 1, -1 do children[i].destroy() end
			for i, col in ipairs(COLUMNS[t]) do
				if not col.width then children[i].style.width = widths[t] end
			end
		end
		local state = util.gui_state(player_data, table_name(t))
		state.keys, state.sigs = nil, nil
	end
end

-- ---------------------------------------------------------------- handlers

item.handle = {}

--- @param e {player_index: uint}
function item.wrapper(e, handler)
	local player = game.get_player(e.player_index)
	if not player then return end
	local player_data = storage.manager.players[e.player_index]
	handler(player, player_data, player_data.refs, e)
end

function item.handle.item_back(player, player_data, refs, e)
	item.close(player, player_data, true)
	util.rerender(player, player_data)
end

gui.add_handlers(item.handle, item.wrapper)

-- The shared item click (util.item_button_click): left opens the drill-down from any item cell.
util.set_item_view({
	open = function(player, player_data, hash)
		-- An item cell outside the window (the stop and train panels) opens the window on the drill-down.
		if not player_data.is_manager_open then
			item.manager.handle.manager_open(player, player_data, player_data.refs)
			if not player_data.is_manager_open then return end
		end
		item.open(player, player_data, hash)
	end,
	close = function(player, player_data)
		item.close(player or game.get_player(player_data.player_index), player_data)
	end,
})

-- ---------------------------------------------------------------- dev

--- Profilers of item.build while storage.manager.item_samples is on; not game state, never read back into it.
item.samples = {}

dev.register_rows(TAB, function(player_data)
	local refs = player_data.refs
	local n = 0
	for _, t in ipairs(item_model.TABLES) do
		local tbl = refs[table_name(t)]
		if tbl and tbl.valid then n = n + #tbl.children / #COLUMNS[t] - 1 end
	end
	return n
end)

--- What the drill-down shows, row by row, plus its model and layout.
--- @param player_data PlayerData
local function dump(player_data)
	local view = player_data.item_view
	if not view then return { open = false } end
	local refs = player_data.refs
	local cache = player_data.item_cache
	local m = cache and cache.model
	local out = {
		open = true,
		hash = view.hash,
		from_tab = view.from_tab,
		host = view.host,
		selected_tab = player_data.selected_tab,
		took_opened = player_data.overlay_took == true,
		alloc = cache and cache.alloc,
		total_rows = player_data.layout and player_data.layout.rows_by_tab[TAB],
		totals = m and m.totals,
		delivered = cache and cache.delivered,
		period = get_period(player_data),
		queued = m and m.queued,
		deferred = cache and cache.deferred,
		model = {},
		rendered = {},
		captions = {},
		header = {},
	}
	for _, name in ipairs({ "provided", "in_transit", "requested", "delivered" }) do
		local e = refs["item_total_" .. name]
		out.header[name] = e and e.valid and e.caption or nil
	end
	out.header.name = refs.item_name and refs.item_name.valid and refs.item_name.caption or nil
	out.header.icon = refs.item_icon and refs.item_icon.valid and refs.item_icon.sprite or nil
	out.header.back = refs.item_back_button and refs.item_back_button.valid and refs.item_back_button.visible or false
	for _, t in ipairs(item_model.TABLES) do
		local ids = {}
		for i, r in ipairs(m and m[t] or {}) do
			ids[i] = t == "requesters" and { id = r.id, priority = r.priority, last_served = r.last_served, group = r.group }
				or r.id
		end
		out.model[t] = ids
		local rows = {}
		local tbl = refs[table_name(t)]
		local cols = #COLUMNS[t]
		if tbl and tbl.valid then
			local children = tbl.children
			for r = 1, #children / cols - 1 do
				local base = r * cols
				local row = { cells = {} }
				for c = 1, cols do
					local cell = children[base + c]
					local kind = COLUMNS[t][c].kind
					if kind == "station" then
						local b = name_cell.button(cell)
						row.cells[c] = b and b.caption
						row.id = row.id or (b and b.tags.id)
						if t == "trains" then row.to = b and b.tags.id end
					elseif kind == "train" then
						row.cells[c] = cell.caption
						row.id = cell.tags.id
					elseif kind == "chip" then
						local button = cell.children[1]
						row.cells[c] = button.visible and button.caption or false
						row.chip_style = button.style.name
						row.chip_tooltip = button.visible and button.tooltip or nil
					elseif kind == "status" then
						row.cells[c] = cell.children[2].caption
						row.dot = cell.children[1].sprite
					else
						row.cells[c] = cell.caption
						row.styles = row.styles or {}
						row.styles[c] = cell.style.name
					end
				end
				rows[r] = row
			end
		end
		out.rendered[t] = rows
		local cap = refs["item_" .. t .. "_caption"]
		local cnt = refs["item_" .. t .. "_count"]
		local empty = refs["item_" .. t .. "_empty_flow"]
		out.captions[t] = {
			caption = cap and cap.valid and cap.caption or nil,
			tooltip = cap and cap.valid and cap.tooltip or nil,
			count = cnt and cnt.valid and cnt.caption or nil,
			empty = empty and empty.valid and empty.visible or false,
		}
	end
	return out
end

dev.add("open_item", function(pi, hash)
	local player = game.get_player(pi)
	local player_data = storage.manager.players[pi]
	util.item_button_click(player, player_data, { button = defines.mouse_button_type.left }, hash)
	return dump(player_data)
end)

dev.add("close_item", function(pi)
	local player = game.get_player(pi)
	local player_data = storage.manager.players[pi]
	item.close(player, player_data, true)
	util.rerender(player, player_data)
	return { open = player_data.item_view ~= nil, selected_tab = player_data.selected_tab }
end)

--- The snapshot's own answer for `hash`, walked here without item-model: the stations that provide and request it,
--- the trains carrying it (ids sorted) and its inventory_all entries.
dev.add("item_oracle", function(hash)
	local snapshot = collector.get()
	local providers, requesters, trains = {}, {}, {}
	for id, st in pairs(snapshot.stations) do
		if st.provided[hash] then providers[#providers + 1] = id end
		if st.requested[hash] then requesters[#requesters + 1] = id end
	end
	for id, tr in pairs(snapshot.trains) do
		if tr.manifest_hashes[hash] then trains[#trains + 1] = id end
	end
	table.sort(providers)
	table.sort(requesters)
	table.sort(trains)
	local inv = snapshot.inventory_all
	return {
		providers = providers,
		requesters = requesters,
		trains = trains,
		provided = inv.provided[hash],
		requested = inv.requested[hash],
		in_transit = inv.in_transit[hash],
		tick = snapshot.tick,
	}
end)

dev.add("item_dump", function(pi)
	return dump(storage.manager.players[pi])
end)

--- Escape on the window (on_gui_closed) as the engine raises it, through the manager's own handler.
dev.add("item_escape", function(pi)
	local player = game.get_player(pi)
	local player_data = storage.manager.players[pi]
	local before = player_data.item_view ~= nil
	item.manager.handle.manager_closed_by_game(player, player_data, player_data.refs)
	return { before = before, open = player_data.item_view ~= nil, manager_open = player_data.is_manager_open == true,
		selected_tab = player_data.selected_tab }
end)

--- `n` renders of the drill-down in this tick. With `rebuild` the model is dropped before each, so every render is the
--- update that rebuilds it (model and header, the "R" kind of item_samples); the row writes follow in later updates.
dev.add("item_profile", function(pi, n, rebuild)
	local player_data = storage.manager.players[pi]
	n = n or 1
	local total = game.create_profiler()
	for _ = 1, n do
		if rebuild then
			player_data.item_cache = nil
			for _, t in ipairs(item_model.TABLES) do
				local s = util.gui_state(player_data, table_name(t))
				s.sigs = nil
			end
		end
		item.build(storage, player_data)
	end
	total.stop()
	total.divide(n)
	return { "", "avg ", total }
end)

--- `n` builds of the model alone for `hash` (the snapshot walk and the sorts).
dev.add("item_model_profile", function(hash, n)
	n = n or 1
	local snapshot = collector.get()
	local p = game.create_profiler()
	for _ = 1, n do item_model.build(snapshot, hash, SIGNAL_PRIORITY) end
	p.stop()
	p.divide(n)
	return { "", "model avg ", p }
end)

--- Records (true) or stops recording a profiler around every drill-down render of the real manager tick; `print`
--- returns the samples: "R" the update that rebuilt the model for a new pass, "P" the rows rewritten after it, "S" the
--- others; "d" counts rows left for a later update.
dev.add("item_samples", function(on, print)
	storage.manager.item_samples = on or nil
	local out
	if print then
		-- A LocalisedString takes at most 20 parameters: 18 samples per call, the rest stay for the next one.
		out = { "" }
		local samples = item.samples
		local n = math.min(#samples, 18)
		for i = 1, n do
			out[#out + 1] = { "", samples[i].kind, " ", samples[i].p, " d", samples[i].deferred, "\n" }
		end
		local rest = {}
		for i = n + 1, #samples do rest[#rest + 1] = samples[i] end
		item.samples = rest
	end
	if not on then item.samples = {} end
	return out
end)

return item
