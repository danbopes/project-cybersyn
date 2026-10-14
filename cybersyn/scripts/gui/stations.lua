local gui = require("__flib__.gui")
local format = require("__flib__.format")

local constants = require("scripts.gui.constants")
local util = require("scripts.gui.util")
local templates = require("scripts.gui.templates")
local collector = require("scripts.gui.collector")
local dev = require("scripts.gui.dev")

local stations_tab = {}

local TAB = "stations_tab"
local SCROLL = "manager_stations_tab_scroll_pane"
local CHIPS = "manager_stations_status_flow"
local IDLE_TICKS = 30 * 60 * 60
-- Unset train stop limits read back as uint max; the planner treats anything this large as unlimited.
local UNLIMITED = 2100000000

--- Severity order: the status sort and the filter chips both follow it.
local STATUSES = { "no_power", "disabled", "warming_up", "starved", "saturated", "idle", "ok" }
local STATUS_RANK = {}
for i, s in ipairs(STATUSES) do STATUS_RANK[s] = i end
local STATUS_COLOR = {
	no_power = "red",
	disabled = "purple",
	warming_up = "cyan",
	starved = "pink",
	saturated = "orange",
	idle = "white",
	ok = "green",
}
local function status_key(status)
	return "cybersyn-gui.station-status-" .. string.gsub(status, "_", "-")
end

local COLUMNS = { "name", "station_status", "network", "provided_requested", "deliveries", "control_signals", "wait", "last_delivery" }

function stations_tab.create(widths)
	local headers = { type = "frame", style = "ltnm_table_toolbar_frame" }
	for i, column in ipairs(COLUMNS) do
		headers[#headers + 1] = templates.sort_checkbox(widths, "stations", column, i == 1,
			{ "cybersyn-gui.stations-sort-" .. string.gsub(column, "_", "-") }, false, stations_tab.handle.on_sort_checkbox_changed)
	end
	return {
		tab = {
			name = "manager_stations_tab",
			type = "tab",
			caption = { "cybersyn-gui.stations" },
			handler = stations_tab.handle.on_stations_tab_selected,
		},
		content = {
			name = "manager_stations_content_frame",
			type = "frame",
			style = "ltnm_main_content_frame",
			direction = "vertical",
			-- manager.refresh_sort_headers finds the header as the first child of the scroll pane's parent.
			headers,
			{
				name = SCROLL,
				type = "scroll-pane",
				style = "ltnm_table_scroll_pane",
				style_mods = { vertically_stretchable = true },
			},
			{
				name = "manager_stations_warning_flow",
				type = "flow",
				style = "ltnm_warning_flow",
				visible = false,
				{
					name = "manager_stations_warning_label",
					type = "label",
					style = "ltnm_semibold_label",
					caption = { "cybersyn-gui.no-stations" },
				},
			},
			{
				type = "frame",
				style = "subheader_frame",
				style_mods = { horizontally_stretchable = true, left_padding = 8, right_padding = 8 },
				{
					name = CHIPS,
					type = "flow",
					direction = "horizontal",
					style_mods = { vertical_align = "center", horizontal_spacing = 4 },
				},
				{ type = "empty-widget", style = "flib_horizontal_pusher" },
				templates.pager(TAB, util.handle.pager_click),
			},
		},
	}
end

-- Pure functions of a snapshot station record (replaced, never mutated, on recollection) and the starved set,
-- so weak memoisation cannot make two Lua states disagree.
local starved_memo = setmetatable({}, { __mode = "k" })
local tiebreak_memo = setmetatable({}, { __mode = "k" })

--- Active requests of `st` with no provider on any of the station's networks.
--- @param st SnapshotStation
--- @param starved {[string]: true}
--- @return string[]|false
local function starved_hashes(st, starved)
	local memo = starved_memo[st]
	if memo and memo.set == starved then return memo.hashes end
	local hashes = false
	local name = st.network_name
	if name and not st.warming_up and next(starved) then
		local networks
		if name == NETWORK_EACH then
			networks = {}
			if type(st.network_mask) == "table" then
				for n in pairs(st.network_mask) do networks[#networks + 1] = n end
			end
		else
			networks = { name }
		end
		for hash, req in pairs(st.requested) do
			if req.active then
				for i = 1, #networks do
					if starved[networks[i] .. ":" .. hash] then
						hashes = hashes or {}
						hashes[#hashes + 1] = hash
						break
					end
				end
			end
		end
		if hashes then util.sort_by(hashes, util.item_rank, true, function(h) return h end) end
	end
	starved_memo[st] = { set = starved, hashes = hashes }
	return hashes
end

--- Name first, id second: unique, and keeps equal keys in a readable order.
local function tiebreak(st)
	local key = tiebreak_memo[st]
	if not key then
		key = string.format("%s\0%010d", st.name_lower, st.id)
		tiebreak_memo[st] = key
	end
	return key
end

--- Game ticks since the station's last delivery; last_delivery_tick counts planner ticks, not game ticks.
--- @param st SnapshotStation
--- @return number?
local function delivery_age(st)
	local last = st.last_delivery_tick
	local tps = mod_settings.tps
	if not last or not tps or tps <= 0 then return nil end
	return math.max(0, (storage.total_ticks or 0) - last) * 60 / tps
end

local function has_active_request(st)
	for _, req in pairs(st.requested) do
		if req.active then return true end
	end
	return false
end

local function finite_limit(st)
	local limit = st.trains_limit
	return limit < UNLIMITED and limit or nil
end

--- @param st SnapshotStation
--- @param starved {[string]: true}
--- @return string status one of STATUSES
local function station_status(st, starved)
	if not st.comb_ok then return "no_power" end
	if st.trains_limit == 0 then return "disabled" end
	if st.warming_up then return "warming_up" end
	if starved_hashes(st, starved) then return "starved" end
	local limit = finite_limit(st)
	if limit and st.deliveries_total >= limit then return "saturated" end
	if st.deliveries_total == 0 and not has_active_request(st) then
		local age = delivery_age(st)
		if age and age > IDLE_TICKS then return "idle" end
	end
	return "ok"
end

local function count_keys(tbl)
	local n = 0
	for _ in pairs(tbl) do n = n + 1 end
	return n
end

local OFFSET = 2147483648

--- Sort keys; each must return only numbers or only strings (nil sorts last).
--- @type {[string]: fun(st: SnapshotStation, ctx: table): (number|string|nil)}
local sort_keys = {
	name = function(st) return st.name_lower end,
	station_status = function(st, ctx) return STATUS_RANK[ctx.status[st.id]] end,
	network = function(st)
		local name = st.network_name
		if not name then return nil end
		local mask = st.network_mask
		return string.format("%s\0%010.0f", name, type(mask) == "number" and mask + OFFSET or 0)
	end,
	provided_requested = function(st) return count_keys(st.provided) + count_keys(st.requested) end,
	deliveries = function(st) return st.deliveries_total end,
	control_signals = function(st) return st.priority end,
	wait = function(st, ctx)
		local start = st.longest_wait_start
		return start and ctx.now - start or nil
	end,
	last_delivery = function(st) return delivery_age(st) end,
}

--- @param player_data PlayerData
--- @return string?
local function status_filter(player_data)
	local s = player_data.stations_status_filter
	if s and not STATUS_RANK[s] then
		player_data.stations_status_filter = nil
		return nil
	end
	return s
end

--- Everything the sorted order depends on besides the data itself.
local function order_sig(f, wanted, column, ascending, snapshot)
	return table.concat({
		column, ascending and "+" or "-", wanted or "", f.terms and table.concat(f.terms, " ") or "", f.item or "",
		f.network or "", f.mask, f.surface or "", snapshot.tick or "", snapshot.station_count or 0,
	}, "\1")
end

--- Filters, classifies and sorts the snapshot stations. The status filter applies after counting so the chips
--- always show what each status would yield.
--- Sorting 2,000 rows costs more than the rest of an update, so the order is kept until the sort, a filter or
--- the completed snapshot pass changes; in between, rows show live data in the order of the last sort, which
--- also keeps them from shuffling while a pass trickles in.
--- @param player_data PlayerData
--- @return SnapshotStation[] rows
--- @return {[string]: integer} counts per status over the filtered set, plus `all`
--- @return table ctx {status = {[id]=status}, now, snapshot}
--- @return string column
--- @return boolean ascending
function stations_tab.query(player_data)
	local snapshot = collector.get()
	local stations = snapshot.stations
	local f = util.get_filters(player_data)
	local starved = snapshot.starved
	local wanted = status_filter(player_data)
	local column, ascending = util.get_sort(player_data, TAB, "name")
	local key_fn = sort_keys[column]
	if not key_fn then
		column = "name"
		key_fn = sort_keys.name
	end

	local status = {}
	local counts = { all = 0 }
	for _, s in ipairs(STATUSES) do counts[s] = 0 end
	for id, st in pairs(stations) do
		if util.station_passes(st, f) then
			local s = station_status(st, starved)
			status[id] = s
			counts[s] = counts[s] + 1
			counts.all = counts.all + 1
		end
	end
	local ctx = { status = status, now = game.tick, snapshot = snapshot }

	local sig = order_sig(f, wanted, column, ascending, snapshot)
	local cache = player_data.stations_order
	local rows = {}
	if cache and cache.sig == sig then
		for _, id in ipairs(cache.ids) do
			local s = status[id]
			if s and (not wanted or wanted == s) then
				rows[#rows + 1] = stations[id]
			end
		end
	else
		for id, s in pairs(status) do
			if not wanted or wanted == s then
				rows[#rows + 1] = stations[id]
			end
		end
		util.sort_by(rows, function(st) return key_fn(st, ctx) end, ascending, tiebreak)
		local ids = {}
		for i, st in ipairs(rows) do ids[i] = st.id end
		player_data.stations_order = { sig = sig, ids = ids }
	end
	return rows, counts, ctx, column, ascending
end

--- Compact so it fits a narrow column; full precision is in the tooltip.
--- @param ticks number
--- @return string
local function short_duration(ticks)
	local s = math.floor(ticks / 60)
	if s < 60 then return s .. "s" end
	local m = math.floor(s / 60)
	if m < 60 then return m .. "m" end
	local h = math.floor(m / 60)
	if h < 24 then return string.format("%dh %dm", h, m % 60) end
	return string.format("%dd %dh", math.floor(h / 24), h % 24)
end

--- Everything a row shows that is not a slot table, as plain values comparable between updates.
--- @param st SnapshotStation
--- @param ctx table
local function row_model(st, ctx)
	local now = ctx.now
	local status = ctx.status[st.id]
	local m = { status = status }

	local status_tooltip = { "", { status_key(status) .. "-tooltip" } }
	if status == "starved" then
		local hashes = starved_hashes(st, ctx.snapshot.starved)
		local icons = {}
		for i = 1, math.min(#hashes, 10) do
			icons[i] = util.rich_text_from_signal(util.signalid_from_hash(hashes[i]))
		end
		status_tooltip[#status_tooltip + 1] = "\n" .. table.concat(icons, " ")
	end
	m.status_tooltip = status_tooltip

	local network_name = st.network_name
	if not network_name then
		m.net_sprite = "utility/close_black"
		m.net_caption = ""
		m.net_sig = ""
		m.net_tooltip = { "cybersyn-gui.station-no-network" }
	elseif network_name == NETWORK_EACH then
		local mask = type(st.network_mask) == "table" and st.network_mask or {}
		local names = {}
		for n in pairs(mask) do names[#names + 1] = n end
		table.sort(names)
		local lines = { "" }
		local parts = {}
		for i, n in ipairs(names) do
			local _, img = util.generate_item_references(n)
			local line = (img or n) .. " " .. mask[n]
			parts[i] = line
			if i <= 20 then lines[#lines + 1] = (i > 1 and "\n" or "") .. line end
		end
		m.net_sprite = "virtual-signal/" .. NETWORK_EACH
		m.net_caption = "×" .. #names
		m.net_sig = table.concat(parts, ",")
		m.net_tooltip = lines
	else
		local mask = type(st.network_mask) == "number" and st.network_mask or 0
		local sprite, img = util.generate_item_references(network_name)
		m.net_sprite = sprite or "utility/close_black"
		m.net_caption = tostring(mask)
		m.net_sig = network_name .. "=" .. mask
		m.net_tooltip = { "", img or network_name, " ", { "cybersyn-gui.station-network-mask", mask, string.format("0x%08X", mask < 0 and mask + 2 * OFFSET or mask) } }
	end

	local limit = finite_limit(st)
	m.dl_caption = st.deliveries_total .. "/" .. (limit and tostring(limit) or "∞")

	local start = st.longest_wait_start
	m.wait_caption = start and short_duration(now - start) or "–"
	m.wait_full = start and util.format_duration(now - start) or nil

	local age = delivery_age(st)
	m.last_caption = age and short_duration(age) or "–"
	m.last_full = age and util.format_duration(age) or nil
	return m
end

--- Slot defs become clickable items with the standard item click semantics and hover-hold; the filtered item is
--- highlighted rather than hidden.
local function decorate_slots(defs, item)
	for _, def in pairs(defs) do
		local hash = def.tags and def.tags.item_hash
		if hash then
			def.enabled = true
			def.mouse_button_filter = { "left", "right" }
			def.handler = { [defines.events.on_gui_click] = stations_tab.handle.on_item_click }
			util.hoverable(def, SCROLL)
			if hash == item then
				def.style = string.gsub(def.style, "^ltnm_small_", "ltnm_selected_small_")
			end
		end
	end
	return defs
end

local function slot_key(def)
	return def.tags and def.tags.item_hash or def.sprite
end

local function update_slot(elem, entry)
	local def = entry.def
	if elem.style.name ~= def.style then elem.style = def.style end
	elem.tooltip = def.tooltip
	local label = elem.children[1]
	if label then label.caption = def.children[1].caption end
end

--- Reconciles one slot table keyed by item, so counts update in place and hovered buttons are not recreated.
--- @param table_elem LuaGuiElement
--- @param defs flib.GuiElemDef[]
--- @param state table
--- @param hold boolean
--- @param minute integer re-signs tooltips once a minute so wait times in them do not go stale
local function sync_slots(table_elem, defs, state, hold, minute)
	local entries = {}
	for i, def in ipairs(defs) do
		entries[i] = {
			key = slot_key(def),
			def = def,
			sig = def.style .. "|" .. tostring(def.children[1].caption) .. "|" .. minute,
			build = function() return def end,
			update = update_slot,
		}
	end
	return util.sync_children(table_elem, entries, state, hold)
end

local function cell_build_defs(st, item)
	return {
		pr = decorate_slots(util.slot_table_build_from_station(st), item),
		dl = decorate_slots(util.slot_table_build_from_deliveries(st), item),
		ctl = util.slot_table_build_from_control_signals(st),
	}
end

local function slot_state(slots, name)
	local s = slots[name]
	if not s then
		s = {}
		slots[name] = s
	end
	return s
end

local function set_if_changed(elem, key, value, old)
	if old ~= value then elem[key] = value end
end

--- @param row LuaGuiElement
--- @param st SnapshotStation
--- @param m table row model
--- @param cell table per-row render memo from the previous update (empty on first sight)
--- @param item string? item filter hash
--- @param hold boolean
--- @param minute integer
--- @return boolean settled false when a hold deferred a slot table change, so it is retried next update
local function update_row(row, st, m, cell, item, hold, minute)
	local c = row.children
	if cell.name ~= st.name then c[1].caption = st.name end

	if cell.status ~= m.status then
		local flow = c[2].children
		flow[1].sprite = "flib_indicator_" .. STATUS_COLOR[m.status]
		flow[2].caption = { status_key(m.status) }
	end
	c[2].children[2].tooltip = m.status_tooltip

	if cell.net_sig ~= m.net_sig then
		local flow = c[3].children
		flow[1].sprite = m.net_sprite
		flow[2].caption = m.net_caption
		c[3].tooltip = m.net_tooltip
	end

	local dl_children = c[5].children
	set_if_changed(dl_children[1], "caption", m.dl_caption, cell.dl_caption)
	set_if_changed(c[7], "caption", m.wait_caption, cell.wait_caption)
	set_if_changed(c[8], "caption", m.last_caption, cell.last_caption)
	c[7].tooltip = m.wait_full and { "cybersyn-gui.waiting-for", m.wait_full } or { "cybersyn-gui.stations-wait-none" }
	c[8].tooltip = m.last_full and { "cybersyn-gui.time-ago", m.last_full } or { "cybersyn-gui.never" }

	-- Records are replaced on recollection, so an unchanged reference means unchanged slot contents.
	if cell.st == st and cell.item == item and cell.minute == minute then return true end
	local defs = cell_build_defs(st, item)
	local slots = cell.slots or {}
	cell.slots = slots
	local a = sync_slots(c[4].children[1], defs.pr, slot_state(slots, "pr"), hold, minute)
	local b = sync_slots(dl_children[2].children[1], defs.dl, slot_state(slots, "dl"), hold, minute)
	local d = sync_slots(c[6].children[1], defs.ctl, slot_state(slots, "ctl"), hold, minute)
	return a ~= "held" and b ~= "held" and d ~= "held"
end

--- @param st SnapshotStation
--- @param m table row model
--- @param color "light"|"dark"
--- @param item string?
--- @param widths table
local function row_def(st, m, color, item, widths)
	local w = widths.stations
	local defs = cell_build_defs(st, item)
	local function slot_frame(name, children, columns)
		return {
			type = "frame",
			style = "ltnm_small_slot_table_frame_" .. color,
			style_mods = { width = w[name] },
			{ type = "table", style = "slot_table", column_count = columns, children = children },
		}
	end
	return util.hoverable({
		type = "frame",
		style = "ltnm_table_row_frame_" .. color,
		direction = "horizontal",
		tags = { station_id = st.id },
		util.hoverable({
			type = "label",
			style = "ltnm_clickable_semibold_label",
			style_mods = { width = w.name },
			tooltip = constants.open_station_gui_tooltip,
			caption = st.name,
			tags = { station_id = st.id },
			handler = { [defines.events.on_gui_click] = stations_tab.handle.open_station_gui },
		}, SCROLL),
		{
			type = "flow",
			style = "flib_indicator_flow",
			style_mods = { width = w.station_status, vertical_align = "center" },
			{ type = "sprite", style = "flib_indicator", sprite = "flib_indicator_" .. STATUS_COLOR[m.status] },
			{ type = "label", caption = { status_key(m.status) }, tooltip = m.status_tooltip },
		},
		{
			type = "flow",
			direction = "horizontal",
			style_mods = { width = w.network, vertical_align = "center", horizontal_spacing = 4 },
			tooltip = m.net_tooltip,
			{ type = "sprite", sprite = m.net_sprite, resize_to_sprite = false, style_mods = { size = 24 }, ignored_by_interaction = true },
			{ type = "label", caption = m.net_caption, ignored_by_interaction = true },
		},
		slot_frame("provided_requested", defs.pr, w.provided_requested_columns),
		{
			type = "flow",
			direction = "horizontal",
			style_mods = { width = w.deliveries, vertical_align = "center", horizontal_spacing = 4 },
			{
				type = "label",
				style = "ltnm_semibold_label",
				style_mods = { width = w.deliveries_count, horizontal_align = "right" },
				caption = m.dl_caption,
				tooltip = { "cybersyn-gui.stations-deliveries-count-tooltip" },
			},
			slot_frame("shipments", defs.dl, w.shipments_columns),
		},
		slot_frame("control_signals", defs.ctl, w.control_signals_columns),
		{
			type = "label",
			style_mods = { width = w.wait, horizontal_align = "right" },
			caption = m.wait_caption,
			tooltip = m.wait_full and { "cybersyn-gui.waiting-for", m.wait_full } or { "cybersyn-gui.stations-wait-none" },
		},
		{
			type = "label",
			style_mods = { width = w.last_delivery, horizontal_align = "right" },
			caption = m.last_caption,
			tooltip = m.last_full and { "cybersyn-gui.time-ago", m.last_full } or { "cybersyn-gui.never" },
		},
	}, SCROLL), defs
end

local function chip_caption(status, count)
	if status == "all" then
		return { "", { "cybersyn-gui.station-status-all" }, "  ", format.number(count) }
	end
	return { "", "[img=flib_indicator_" .. STATUS_COLOR[status] .. "] ", { status_key(status) }, "  ", format.number(count) }
end

--- Status chips: counts over the filtered set, click to filter by that status.
local function render_chips(player_data, counts, state)
	local flow = player_data.refs[CHIPS]
	if not (flow and flow.valid) then return end
	local wanted = status_filter(player_data) or "all"
	local order = { "all" }
	for _, s in ipairs(STATUSES) do order[#order + 1] = s end
	local entries = {}
	for i, s in ipairs(order) do
		local count = counts[s]
		local selected = wanted == s
		entries[i] = {
			key = s,
			sig = count .. (selected and "+" or "-"),
			build = function()
				return {
					type = "button",
					style = "button",
					style_mods = { minimal_width = 0, height = 28, left_padding = 6, right_padding = 6 },
					caption = chip_caption(s, count),
					tooltip = s ~= "all" and { status_key(s) .. "-tooltip" } or nil,
					toggled = selected,
					tags = { station_status = s },
					handler = { [defines.events.on_gui_click] = stations_tab.handle.on_status_chip_click },
				}
			end,
			update = function(elem)
				elem.caption = chip_caption(s, count)
				elem.toggled = selected
			end,
		}
	end
	util.sync_children(flow, entries, state, false)
end

--- @param map_data MapData
--- @param player_data PlayerData
function stations_tab.build(map_data, player_data)
	local widths = constants.gui["en"]
	local refs = player_data.refs
	local scroll_pane = refs[SCROLL]
	if not (scroll_pane and scroll_pane.valid) then return end

	local rows, counts, ctx = stations_tab.query(player_data)
	local first, last = util.paginate(player_data, TAB, #rows)
	render_chips(player_data, counts, util.gui_state(player_data, CHIPS))

	local item = player_data.search_item
	local minute = math.floor(ctx.now / 3600)
	local hold = util.hold_active(player_data, SCROLL)
	local state = util.gui_state(player_data, SCROLL)
	local old_cells = state.cells or {}
	local cells = {}
	local entries = {}
	for i = first, last do
		local st = rows[i]
		local id = st.id
		local index = i - first + 1
		local m = row_model(st, ctx)
		local color = index % 2 == 0 and "dark" or "light"
		entries[index] = {
			key = id,
			build = function()
				local def, defs = row_def(st, m, color, item, widths)
				local slots = {}
				for name, list in pairs(defs) do
					local keys = {}
					for k, d in ipairs(list) do keys[k] = slot_key(d) end
					slots[name] = { keys = keys }
				end
				cells[id] = {
					slots = slots, st = st, item = item, minute = minute, name = st.name, status = m.status,
					net_sig = m.net_sig, dl_caption = m.dl_caption, wait_caption = m.wait_caption, last_caption = m.last_caption,
				}
				return def
			end,
			update = function(elem)
				local cell = old_cells[id] or {}
				local settled = update_row(elem, st, m, cell, item, hold, minute)
				cell.st, cell.item, cell.minute, cell.name, cell.status = settled and st or nil, item, minute, st.name, m.status
				cell.net_sig, cell.dl_caption, cell.wait_caption, cell.last_caption = m.net_sig, m.dl_caption, m.wait_caption, m.last_caption
				cells[id] = cell
			end,
		}
	end
	local result = util.sync_children(scroll_pane, entries, state, hold)
	if result == "held" then
		-- Rows that left the page keep their memo until the hold ends and they are rebuilt.
		for id, cell in pairs(old_cells) do
			if not cells[id] then cells[id] = cell end
		end
	end
	state.cells = cells
	state.result = result

	local empty = #rows == 0
	scroll_pane.visible = not empty
	local warning = refs.manager_stations_warning_flow
	if warning and warning.valid then
		warning.visible = empty
		if empty then
			local caption
			if not ctx.snapshot.tick then
				caption = { "cybersyn-gui.stations-collecting" }
			elseif counts.all > 0 or util.filters_active(util.get_filters(player_data)) then
				caption = { "cybersyn-gui.stations-no-match" }
			else
				caption = { "cybersyn-gui.no-stations" }
			end
			refs.manager_stations_warning_label.caption = caption
		end
	end
end

dev.register_dump(TAB, function(player_data)
	local scroll_pane = player_data.refs[SCROLL]
	local rows, counts, ctx, column, ascending = stations_tab.query(player_data)
	local key_fn = sort_keys[column]
	local ids, keys, statuses = {}, {}, {}
	local by_id = ctx.snapshot.stations
	for i, row in ipairs(scroll_pane.children) do
		local id = row.tags.station_id
		ids[i] = id
		local st = by_id[id]
		keys[i] = st and key_fn(st, ctx)
		statuses[i] = ctx.status[id]
	end
	local chips = {}
	local flow = player_data.refs[CHIPS]
	if flow and flow.valid then
		for i, chip in ipairs(flow.children) do
			chips[i] = { chip.tags.station_status, chip.toggled }
		end
	end
	return {
		ids = ids,
		keys = keys,
		statuses = statuses,
		column = column,
		ascending = ascending,
		page = player_data.page and player_data.page[TAB],
		total = #rows,
		counts = counts,
		status_filter = player_data.stations_status_filter,
		visible = scroll_pane.visible,
		warning = player_data.refs.manager_stations_warning_flow.visible,
		chips = chips,
		render = util.gui_state(player_data, SCROLL).result,
	}
end)


stations_tab.handle = {}

--- @param e {player_index: uint}
function stations_tab.wrapper(e, handler)
	local player = game.get_player(e.player_index)
	if not player then return end
	local player_data = storage.manager.players[e.player_index]
	handler(player, player_data, player_data.refs, e)
end

--- @param e GuiEventData
--- @param player LuaPlayer
--- @param player_data PlayerData
function stations_tab.handle.open_station_gui(player, player_data, refs, e)
	local station_id = e.element.tags.station_id
	--- @type Station
	local station = storage.stations[station_id]
	if not station then
		util.error_flying_text(player, { "cybersyn-message.error-station-is-invalid" })
		return
	end
	local station_entity = station.entity_stop
	local station_comb1 = station.entity_comb1
	local station_comb2 = station.entity_comb2

	if not station_entity or not station_entity.valid then
		util.error_flying_text(player, { "message.ltnm-error-station-is-invalid" })
		return
	end

	if e.shift then
		player.centered_on = station_entity

		rendering.draw_circle({
			color = constants.colors.red.tbl,
			target = station_entity.position,
			surface = station_entity.surface,
			radius = 0.5,
			filled = false,
			width = 5,
			time_to_live = 60 * 3,
			players = { player },
		})

		if not player_data.pinning then util.close_manager_window(player, player_data, refs) end
	elseif e.control then
		if station_comb1 ~= nil and station_comb1.valid then
			player.opened = station_comb1
		else
			util.error_flying_text(player, { "cybersyn-message.error-cybernetic-combinator-not-found" })
		end
	elseif e.alt then
		if station_comb2 ~= nil and station_comb2.valid then
			player.opened = station_comb2
		else
			util.error_flying_text(player, { "cybersyn-message.error-station-control-combinator-not-found" })
		end
	else
		player.opened = station_entity
	end
end

--- @param e EventData.on_gui_click
function stations_tab.handle.on_item_click(player, player_data, refs, e)
	local hash = e.element.tags.item_hash
	if hash then util.item_button_click(player, player_data, e, hash) end
end

--- @param e EventData.on_gui_click
function stations_tab.handle.on_status_chip_click(player, player_data, refs, e)
	local s = e.element.tags.station_status
	stations_tab.set_status_filter(player_data, s ~= "all" and s or nil)
	util.rerender(player, player_data)
end

--- @param player_data PlayerData
--- @param status string? one of STATUSES, nil = all; selecting the active status again clears it
function stations_tab.set_status_filter(player_data, status)
	if status and player_data.stations_status_filter == status then status = nil end
	player_data.stations_status_filter = status
	util.reset_page(player_data, TAB)
end

---@param player LuaPlayer
---@param player_data PlayerData
function stations_tab.handle.on_stations_tab_selected(player, player_data)
	player_data.selected_tab = "stations_tab"
end

---@param player LuaPlayer
---@param player_data PlayerData
---@param refs table<string, LuaGuiElement>
---@param e EventData.on_gui_checked_state_changed
function stations_tab.handle.on_sort_checkbox_changed(player, player_data, refs, e)
	local element = e.element
	if not element or not element.tags then return end
	local column = element.tags.column
	if not column then return end

	util.set_sort(player_data, TAB, column)
	local active, ascending = util.get_sort(player_data, TAB, "name")
	util.sync_sort_header(element.parent, active, ascending)
	util.rerender(player, player_data)
end

gui.add_handlers(stations_tab.handle, stations_tab.wrapper)

-- The shared dev interface has no per-tab setters; the status filter is local to this tab.
if not remote.interfaces["cybersyn-manager-dev-stations"] then
	remote.add_interface("cybersyn-manager-dev-stations", {
		set_status_filter = function(pi, status)
			local player = game.get_player(pi)
			local player_data = storage.manager.players[pi]
			player_data.stations_status_filter = nil
			stations_tab.set_status_filter(player_data, status or nil)
			util.rerender(player, player_data)
			return player_data.stations_status_filter or "all"
		end,
	})
end

return stations_tab
