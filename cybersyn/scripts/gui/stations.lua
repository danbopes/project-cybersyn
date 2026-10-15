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
local UNLIMITED = collector.UNLIMITED

--- Severity order: the status sort and the filter chips both follow it.
local STATUSES = collector.STATUSES
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

--- Active requests of `st` with no provider on any of its networks, in item order, for the status tooltip.
--- @param st SnapshotStation
--- @param starved {[string]: true}
--- @return string[]|false
local function starved_hashes(st, starved)
	local hashes = collector.starved_hashes(st, starved)
	if hashes then util.sort_by(hashes, util.item_rank, true, function(h) return h end) end
	return hashes
end

local function finite_limit(st)
	local limit = st.trains_limit
	return limit < UNLIMITED and limit or nil
end

local function count_keys(tbl)
	local n = 0
	for _ in pairs(tbl) do n = n + 1 end
	return n
end

local OFFSET = 2147483648

--- Sort keys; each must return only numbers or only strings (nil sorts last). Keys are cached per station
--- between collector passes, so they must not depend on the current tick: ages sort by their negated start tick.
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
	wait = function(st)
		local start = st.longest_wait_start
		return start and -start or nil
	end,
	last_delivery = function(st)
		local last = st.last_delivery_tick
		return last and -last or nil
	end,
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

--- Everything the filtered set depends on besides the data itself. The status filter is left out: it is applied
--- after the cached order, so a station changing status mid-pass shows up at once, matching the chip counts.
local function filter_sig(f)
	return table.concat({
		f.terms and table.concat(f.terms, " ") or "", f.item or "", f.network or "", f.mask, f.surface or "",
	}, "\1")
end

local function view_sig(f, column, ascending)
	return column .. "\1" .. (ascending and "+" or "-") .. "\1" .. filter_sig(f)
end

--- Rescans every snapshot station into a fresh per-player query cache.
local function rebuild_query(player_data, snapshot, f, fsig, column, epoch, pos)
	local stations = snapshot.stations
	local key_fn = sort_keys[column]
	local status, keys = {}, {}
	local counts = { all = 0 }
	for _, s in ipairs(STATUSES) do counts[s] = 0 end
	local ctx = { status = status }
	for id, st in pairs(stations) do
		if util.station_passes(st, f) then
			local s = st.status or "ok"
			status[id] = s
			counts[s] = counts[s] + 1
			counts.all = counts.all + 1
			keys[id] = key_fn(st, ctx)
		end
	end
	local cache = {
		epoch = epoch, pos = pos, fsig = fsig, column = column,
		status = status, keys = keys, counts = counts, dirty = true, changed = {},
	}
	player_data.stations_query = cache
	return cache
end

--- Folds the station records the collector refilled, reclassified or removed since the last render into the cache.
local function apply_changes(cache, snapshot, f, ids, first, last)
	local stations = snapshot.stations
	local key_fn = sort_keys[cache.column]
	local status, keys, counts = cache.status, cache.keys, cache.counts
	local changed = cache.changed
	if not changed then
		changed = {}
		cache.changed = changed
	end
	local ctx = { status = status }
	for i = first, last do
		local id = ids[i]
		local st = stations[id]
		local old = status[id]
		local new = st and util.station_passes(st, f) and (st.status or "ok") or nil
		if old ~= new then
			cache.version = (cache.version or 0) + 1
			if old then
				counts[old] = counts[old] - 1
				counts.all = counts.all - 1
			end
			if new then
				counts[new] = counts[new] + 1
				counts.all = counts.all + 1
			end
			status[id] = new
			if not old or not new then
				cache.dirty = true
				changed[id] = true
			end
		end
		local key = new and key_fn(st, ctx) or nil
		if keys[id] ~= key then
			keys[id] = key
			cache.dirty = true
			changed[id] = true
		end
	end
end

--- Ties sort by name, then id.
local function id_of(id) return id end

--- Sorting every station costs about 3 ms on a 2,000-station base and a pass changes the keys of only some of
--- them, so the previous order is kept for the rest and the re-sorted changed ids are merged into it.
--- @return uint[]? order nil when so many ids changed that a full sort is cheaper
local function merge_changes(cache, stations, ascending)
	local keys, status, changed = cache.keys, cache.status, cache.changed
	local moved = {}
	for id in pairs(changed) do
		if status[id] then moved[#moved + 1] = id end
	end
	local old = cache.order
	if #moved * 4 > #old then return nil end
	util.sort_by(moved, function(id) return keys[id] end, ascending, function(id) return stations[id].name_lower end, id_of)
	-- Same order as util.sort_by: key in the requested direction with nil last, then name and id ascending.
	local function less(a, b)
		local ka, kb = keys[a], keys[b]
		if ka ~= kb then
			if ka == nil then return false end
			if kb == nil then return true end
			if ascending then return ka < kb end
			return ka > kb
		end
		local na, nb = stations[a].name_lower, stations[b].name_lower
		if na ~= nb then return na < nb end
		return a < b
	end
	local order = {}
	local n, j, m = 0, 1, #moved
	for _, id in ipairs(old) do
		if status[id] and not changed[id] then
			while j <= m and less(moved[j], id) do
				n = n + 1
				order[n] = moved[j]
				j = j + 1
			end
			n = n + 1
			order[n] = id
		end
	end
	for k = j, m do
		n = n + 1
		order[n] = moved[k]
	end
	return order
end

--- Filters, classifies and sorts the snapshot stations. The status filter applies after counting so the chips
--- always show what each status would yield.
--- Classification is cached per player and updated only for the records the collector replaced since the last
--- render, so a render costs O(changed + page) rather than O(stations). Sorting 2,000 rows costs more than the
--- rest of an update, so the order is kept until the sort or a filter changes, or a completed pass changed a key
--- or the filtered set; in between, rows show live data in the order of the last sort, which also keeps them
--- from shuffling while a pass trickles in.
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
	local wanted = status_filter(player_data)
	local column, ascending = util.get_sort(player_data, TAB, "name")
	if not sort_keys[column] then column = "name" end
	-- The first pass after opening is still filling records: rows and counts from part of the stations would change
	-- on every update and disagree with the other tabs, so there are none until it completes.
	local cache = player_data.stations_query
	-- The first build after a boosted pass is split over the next two updates, so no tick carries more than one of
	-- the pass's last batch, classifying and sorting every station (~5 ms on pY 123) or writing every row of the page
	-- (6-8 ms there for 50 rows): the completing update shows the placeholder still, the next one fills the query
	-- cache and still shows the placeholder, the one after renders from it.
	if not snapshot.tick or (not cache and snapshot.boosted and snapshot.tick == game.tick) then
		return {}, {}, { status = {}, now = game.tick, snapshot = snapshot, pending = true }, column, ascending
	end
	local first_build = not cache and snapshot.boosted

	local fsig = filter_sig(f)
	local epoch, pos = collector.log_position()
	local ids, first, last
	if cache and cache.fsig == fsig and cache.column == column then
		ids, first, last = collector.changed_since(cache.epoch, cache.pos)
	end
	if ids then
		apply_changes(cache, snapshot, f, ids, first, last)
		cache.pos = pos
	else
		cache = rebuild_query(player_data, snapshot, f, fsig, column, epoch, pos)
	end
	local status = cache.status
	local ctx = { status = status, now = game.tick, snapshot = snapshot }

	-- An empty order (the window opened before the first pass completed) has no rows to keep still.
	local resort = not cache.order or cache.ascending ~= ascending or (cache.dirty and #cache.order == 0)
	-- A data-driven re-sort waits for the update after the one that completed the pass, which carries the pass's
	-- last collector batch; the next one carries only the cheap start of a new pass.
	if resort or (cache.dirty and cache.sorted_tick ~= snapshot.tick and snapshot.tick ~= game.tick) then
		local keys = cache.keys
		local function key_of(id) return keys[id] end
		local function name_of(id) return stations[id].name_lower end
		local order = not resort and merge_changes(cache, stations, ascending) or nil
		cache.sort_kind = order and "merged" or "full"
		if not order then
			order = {}
			for id in pairs(status) do order[#order + 1] = id end
			util.sort_by(order, key_of, ascending, name_of, id_of)
		end
		cache.order = order
		cache.ascending = ascending
		cache.sorted_tick = snapshot.tick
		cache.dirty = false
		cache.changed = {}
	end

	-- The row list only changes with the order, the status filter or a status; rebuilding it every update allocated
	-- tens of KB per render on a large base.
	local rows = cache.rows
	if not rows or cache.rows_order ~= cache.order or cache.rows_wanted ~= (wanted or false) or cache.rows_version ~= cache.version then
		rows = {}
		for _, id in ipairs(cache.order) do
			local s = status[id]
			if s and (not wanted or wanted == s) then
				rows[#rows + 1] = stations[id]
			end
		end
		cache.rows, cache.rows_order, cache.rows_wanted, cache.rows_version = rows, cache.order, wanted or false, cache.version
	end
	if first_build then
		return {}, {}, { status = {}, now = game.tick, snapshot = snapshot, pending = true }, column, ascending
	end
	return rows, cache.counts, ctx, column, ascending
end

local NONE_CAPTION = { "cybersyn-gui.none-short" }

--- Everything a row shows that is not a slot table, as plain values comparable between updates. Tooltips and the
--- network cell cost API calls, so they are built by functions that run only when their sig changed.
--- @param st SnapshotStation
--- @param ctx table
local function row_model(st, ctx)
	local now = ctx.now
	local status = ctx.status[st.id]
	local m = { status = status }

	local hashes = status == "starved" and starved_hashes(st, ctx.snapshot.starved) or nil
	m.status_tip_sig = hashes and (status .. "|" .. table.concat(hashes, ",", 1, math.min(#hashes, 10))) or status
	m.status_tooltip = function()
		local tooltip = { "", { status_key(status) .. "-tooltip" } }
		if hashes then
			local icons = {}
			for i = 1, math.min(#hashes, 10) do
				icons[i] = util.rich_text_from_signal(util.signalid_from_hash(hashes[i]))
			end
			tooltip[#tooltip + 1] = "\n" .. table.concat(icons, " ")
		end
		return tooltip
	end

	local network_name = st.network_name
	local mask = st.network_mask
	if not network_name then
		m.net_sig = ""
	elseif network_name == NETWORK_EACH then
		local names = {}
		if type(mask) == "table" then
			for n in pairs(mask) do names[#names + 1] = n end
		end
		table.sort(names)
		local parts = {}
		for i, n in ipairs(names) do parts[i] = n .. "=" .. mask[n] end
		m.net_sig = NETWORK_EACH .. "|" .. table.concat(parts, ",")
		m.net_names = names
	else
		m.net_sig = network_name .. "=" .. (type(mask) == "number" and mask or 0)
	end
	m.network = function()
		if not network_name then
			return "utility/close_black", "", { "cybersyn-gui.station-no-network" }
		elseif network_name == NETWORK_EACH then
			local names = m.net_names
			local lines = { "" }
			for i, n in ipairs(names) do
				if i > 20 then break end
				local _, img = util.generate_item_references(n)
				lines[#lines + 1] = (i > 1 and "\n" or "") .. (img or n) .. " " .. mask[n]
			end
			return "virtual-signal/" .. NETWORK_EACH, { "cybersyn-gui.network-each-count", #names }, lines
		end
		local value = type(mask) == "number" and mask or 0
		local sprite, img = util.generate_item_references(network_name)
		return sprite or "utility/close_black", tostring(value), { "", img or network_name, " ",
			{ "cybersyn-gui.station-network-mask", value, string.format("0x%08X", value < 0 and value + 2 * OFFSET or value) } }
	end

	local limit = finite_limit(st)
	m.dl_caption = { "", st.deliveries_total, "/", limit or { "cybersyn-gui.no-limit-short" } }
	m.dl_sig = st.deliveries_total .. "/" .. (limit or "")

	local start = st.longest_wait_start
	if start then
		m.wait_caption = util.short_duration(now - start)
		m.wait_sig = m.wait_caption
	else
		m.wait_caption, m.wait_sig = NONE_CAPTION, ""
	end
	m.wait_full = start and util.format_duration(now - start) or nil

	local age = collector.delivery_age(st)
	if age then
		m.last_caption = util.short_duration(age)
		m.last_sig = m.last_caption
	else
		m.last_caption, m.last_sig = NONE_CAPTION, ""
	end
	m.last_full = age and util.format_duration(age) or nil
	return m
end

local function wait_tooltip(m)
	return m.wait_full and { "cybersyn-gui.waiting-for", m.wait_full } or { "cybersyn-gui.stations-wait-none" }
end

local function last_tooltip(m)
	return m.last_full and { "cybersyn-gui.time-ago", m.last_full } or { "cybersyn-gui.never" }
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
			def.tooltip = { "", def.tooltip, "\n", { "cybersyn-gui.item-click-hint" } }
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

--- Flattens a LocalisedString so the slot sig follows exact amounts that the abbreviated caption hides.
local function flatten(ls, out)
	if type(ls) == "table" then
		for _, v in ipairs(ls) do flatten(v, out) end
	elseif ls ~= nil then
		out[#out + 1] = tostring(ls)
	end
	return out
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
			sig = def.style .. "|" .. tostring(def.children[1].caption) .. "|" .. minute .. "|" .. table.concat(flatten(def.tooltip, {}), "\1"),
			build = function() return def end,
			update = update_slot,
		}
	end
	return util.sync_children(table_elem, entries, state, hold)
end

local SLOT_TABLES = {
	pr = function(st, item) return decorate_slots(util.slot_table_build_from_station(st), item) end,
	dl = function(st, item) return decorate_slots(util.slot_table_build_from_deliveries(st), item) end,
	ctl = function(st) return util.slot_table_build_from_control_signals(st) end,
}

local function cell_build_defs(st, item)
	return { pr = SLOT_TABLES.pr(st, item), dl = SLOT_TABLES.dl(st, item), ctl = SLOT_TABLES.ctl(st) }
end

local function count_parts(parts, prefix, map)
	for k, v in pairs(map) do
		parts[#parts + 1] = prefix .. k .. "=" .. tostring(v)
	end
end

--- Signatures of what each slot table shows, from the record's data, so an unchanged table is not rebuilt as defs at
--- all. The minute is part of the provided/requested sig only when one of its requests shows a wait.
--- @param st SnapshotStation
--- @param item string?
--- @param minute integer
--- @return {pr: string, dl: string, ctl: string}
local function slot_sigs(st, item, minute)
	local parts = {}
	count_parts(parts, "p", st.provided)
	local waits = false
	local wait = st.wait
	for hash, req in pairs(st.requested) do
		parts[#parts + 1] = "r" .. hash .. "=" .. req.count .. (req.active and "a" or "b")
		if req.active and wait[hash] then
			waits = true
			parts[#parts + 1] = tostring(wait[hash])
		end
	end
	parts[#parts + 1] = item or ""
	if waits then parts[#parts + 1] = tostring(minute) end
	local pr = table.concat(parts, "\1")
	parts = {}
	count_parts(parts, "", st.deliveries)
	parts[#parts + 1] = item or ""
	local dl = table.concat(parts, "\1")
	parts = {}
	count_parts(parts, "c", st.control)
	count_parts(parts, "t", st.thresholds)
	return { pr = pr, dl = dl, ctl = table.concat(parts, "\1") }
end

local function slot_state(slots, name)
	local s = slots[name]
	if not s then
		s = {}
		slots[name] = s
	end
	return s
end

--- Element references of a row, found by name once and kept in the row's memo.
--- @param row LuaGuiElement
local function row_refs(row)
	local c = row.children
	local status = c[2].children
	local net = c[3].children
	local dl = c[5].children
	return {
		name = c[1],
		status_sprite = status[1],
		status_label = status[2],
		net = c[3],
		net_sprite = net[1],
		net_label = net[2],
		pr_frame = c[4],
		pr = c[4].children[1],
		dl_count = dl[1],
		dl_frame = dl[2],
		dl = dl[2].children[1],
		ctl_frame = c[6],
		ctl = c[6].children[1],
		wait = c[7],
		last = c[8],
	}
end

--- @param cell table
--- @param row LuaGuiElement
local function cell_refs(cell, row)
	local refs = cell.refs
	if not (refs and refs.name.valid and refs.last.valid) then
		refs = row_refs(row)
		cell.refs = refs
	end
	return refs
end

--- @param row LuaGuiElement
--- @param st SnapshotStation
--- @param m table row model
--- @param cell table per-row render memo from the previous update (empty on first sight)
--- @param item string? item filter hash
--- @param hold boolean
--- @param minute integer
--- @param sigs {pr: string, dl: string, ctl: string}
local function update_row(row, st, m, cell, item, hold, minute, sigs)
	local r = cell_refs(cell, row)
	if cell.name ~= st.name then
		r.name.caption = st.name
		cell.name = st.name
	end

	if cell.status ~= m.status then
		r.status_sprite.sprite = "flib_indicator_" .. STATUS_COLOR[m.status]
		r.status_label.caption = { status_key(m.status) }
		cell.status = m.status
	end
	if cell.status_tip_sig ~= m.status_tip_sig then
		r.status_label.tooltip = m.status_tooltip()
		cell.status_tip_sig = m.status_tip_sig
	end

	if cell.net_sig ~= m.net_sig then
		local sprite, caption, tooltip = m.network()
		r.net_sprite.sprite = sprite
		r.net_label.caption = caption
		r.net.tooltip = tooltip
		cell.net_sig = m.net_sig
	end

	if cell.dl_sig ~= m.dl_sig then
		r.dl_count.caption = m.dl_caption
		cell.dl_sig = m.dl_sig
	end
	if cell.wait_sig ~= m.wait_sig then
		r.wait.caption = m.wait_caption
		cell.wait_sig = m.wait_sig
	end
	if cell.last_sig ~= m.last_sig then
		r.last.caption = m.last_caption
		cell.last_sig = m.last_sig
	end
	local wait_tip, last_tip = m.wait_full or "", m.last_full or ""
	if cell.wait_tip ~= wait_tip then
		r.wait.tooltip = wait_tooltip(m)
		cell.wait_tip = wait_tip
	end
	if cell.last_tip ~= last_tip then
		r.last.tooltip = last_tooltip(m)
		cell.last_tip = last_tip
	end

	local slots = cell.slots or {}
	cell.slots = slots
	local sig_of = cell.slot_sigs or {}
	cell.slot_sigs = sig_of
	for name, build in pairs(SLOT_TABLES) do
		local sig = sigs[name]
		if sig_of[name] ~= sig then
			local result = sync_slots(r[name], build(st, item), slot_state(slots, name), hold, minute)
			-- A hold deferred a structural change, so the table is retried next update.
			sig_of[name] = result ~= "held" and sig or nil
		end
	end
end

--- Rows alternate their background, so a row that moved to an index of the other parity is restyled. Assigning a
--- style drops style_mods, so the widths are set again.
--- @param refs table row_refs
--- @param row LuaGuiElement
--- @param color "light"|"dark"
--- @param w table stations column widths
local function restyle_row(refs, row, color, w)
	row.style = "ltnm_table_row_frame_" .. color
	local frame = "ltnm_small_slot_table_frame_" .. color
	refs.pr_frame.style = frame
	refs.pr_frame.style.width = w.provided_requested
	refs.dl_frame.style = frame
	refs.dl_frame.style.width = w.shipments
	refs.ctl_frame.style = frame
	refs.ctl_frame.style.width = w.control_signals
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
	local net_sprite, net_caption, net_tooltip = m.network()
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
			{ type = "label", caption = { status_key(m.status) }, tooltip = m.status_tooltip() },
		},
		{
			type = "flow",
			direction = "horizontal",
			style_mods = { width = w.network, vertical_align = "center", horizontal_spacing = 4 },
			tooltip = net_tooltip,
			{ type = "sprite", sprite = net_sprite, resize_to_sprite = false, style_mods = { size = 24 }, ignored_by_interaction = true },
			{ type = "label", caption = net_caption, ignored_by_interaction = true },
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
			-- Left-aligned like Last delivery and both headers: right-aligned, the two durations read as one.
			style_mods = { width = w.wait },
			caption = m.wait_caption,
			tooltip = wait_tooltip(m),
		},
		{
			type = "label",
			style_mods = { width = w.last_delivery },
			caption = m.last_caption,
			tooltip = last_tooltip(m),
		},
	}, SCROLL), defs
end

--- @param count integer? nil while the first pass after opening runs
local function chip_caption(status, count)
	local number = count and format.number(count) or "–"
	if status == "all" then
		return { "", { "cybersyn-gui.station-status-all" }, "  ", number }
	end
	return { "", "[img=flib_indicator_" .. STATUS_COLOR[status] .. "] ", { status_key(status) }, "  ", number }
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
			sig = tostring(count) .. (selected and "+" or "-"),
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
	if ctx.pending then
		-- Rows from before the window was closed stay hidden rather than destroyed: most of them are reused, not
		-- built again, once the first pass completes.
		scroll_pane.visible = false
		local warning = refs.manager_stations_warning_flow
		if warning and warning.valid then
			warning.visible = true
			refs.manager_stations_warning_label.caption = { "cybersyn-gui.stations-collecting" }
		end
		return
	end

	local item = player_data.search_item
	local minute = math.floor(ctx.now / 3600)
	local state = util.gui_state(player_data, SCROLL)
	-- A hold must only defer data-driven reshuffles; a filter, sort, status or page change the user just made
	-- (often by clicking inside a hovered row) has to apply at once.
	local view = view_sig(util.get_filters(player_data), util.get_sort(player_data, TAB, "name")) .. "\1"
		.. (status_filter(player_data) or "") .. "\1" .. tostring(player_data.page and player_data.page[TAB])
	local hold = state.view == view and util.hold_active(player_data, SCROLL)
	state.view = view
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
					slots = slots, slot_sigs = slot_sigs(st, item, minute), name = st.name, status = m.status, color = color,
					status_tip_sig = m.status_tip_sig, net_sig = m.net_sig, dl_sig = m.dl_sig, wait_sig = m.wait_sig,
					last_sig = m.last_sig, wait_tip = m.wait_full or "", last_tip = m.last_full or "",
				}
				return def
			end,
			built = function(elem)
				local cell = cells[id]
				if cell then cell.refs = row_refs(elem) end
			end,
			-- A row that left the page becomes this one: its slot tables keep their buttons where the items match.
			reuse = function(elem, old_id)
				local old = old_cells[old_id]
				old_cells[id] = { slots = old and old.slots, color = old and old.color, refs = old and old.refs }
				local r = cell_refs(old_cells[id], elem)
				for _, e in ipairs({ elem, r.name }) do
					local tags = e.tags
					tags.station_id = id
					e.tags = tags
				end
			end,
			update = function(elem)
				local cell = old_cells[id] or {}
				if cell.color ~= color then
					restyle_row(cell_refs(cell, elem), elem, color, widths.stations)
					cell.color = color
				end
				update_row(elem, st, m, cell, item, hold, minute, slot_sigs(st, item, minute))
				cells[id] = cell
			end,
		}
	end
	local result = util.sync_children(scroll_pane, entries, state, hold, true)
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
			if counts.all > 0 or util.filters_active(util.get_filters(player_data)) then
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
	local stripes_ok = true
	local by_id = ctx.snapshot.stations
	for i, row in ipairs(scroll_pane.children) do
		local id = row.tags.station_id
		ids[i] = id
		local color = i % 2 == 0 and "dark" or "light"
		if row.style.name ~= "ltnm_table_row_frame_" .. color or row.children[4].style.name ~= "ltnm_small_slot_table_frame_" .. color then
			stripes_ok = false
		end
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
		sort_kind = player_data.stations_query and player_data.stations_query.sort_kind,
		stripes_ok = stripes_ok,
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
			util.open_entity(player, player_data, station_comb1)
		else
			util.error_flying_text(player, { "cybersyn-message.error-cybernetic-combinator-not-found" })
		end
	elseif e.alt then
		if station_comb2 ~= nil and station_comb2.valid then
			util.open_entity(player, player_data, station_comb2)
		else
			util.error_flying_text(player, { "cybersyn-message.error-station-control-combinator-not-found" })
		end
	else
		util.open_entity(player, player_data, station_entity)
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
if dev.enabled() and not remote.interfaces["cybersyn-manager-dev-stations"] then
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
