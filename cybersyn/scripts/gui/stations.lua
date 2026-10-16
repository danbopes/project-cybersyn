-- Stations tab (PLAN3 §4.7): filter chips in the tab's subheader, one 32 px row per station (name with its icons,
-- status with a setup chip, network, provided / requested, deliveries, wait, last delivery), exactly as many rows as the
-- window fits, the pager in a subfooter.

local gui = require("__flib__.gui")
local format = require("__flib__.format")

local util = require("scripts.gui.util")
local collector = require("scripts.gui.collector")
local dev = require("scripts.gui.dev")
local sizing = require("scripts.gui.sizing")
local logic = require("scripts.gui.tab-logic")
local name_cell = require("scripts.gui.name-cell")
local text = require("scripts.gui.unserved-text")
local templates = require("scripts.gui.templates")

local stations_tab = {}

--- @class PlayerData
--- @field stations_status_filter string? the status chip that is toggled (one of collector.STATUSES)
--- @field stations_chip "unserved"|"setup"|"stuck"|"failing"? the other chip that is toggled; never both

local TAB = "stations_tab"
-- The row list. A flow since phase 4; the name stays because manager.refresh_sort_headers looks it up.
local SCROLL = "manager_stations_tab_scroll_pane"
local HEADER = "manager_stations_header"
local CHIPS = "manager_stations_status_flow"
local UNLIMITED = collector.UNLIMITED
local ROW_HEIGHT = sizing.ROW_HEIGHT[TAB]
local SLOT = 32
-- Banner, subheader, column header and subfooter (styles cybersyn_tab_subheader, cybersyn_list_header,
-- cybersyn_list_subfooter).
local STRIP_HEIGHT = 36
local band = bit32.band
-- Alert kind 1 is Cybersyn's stuck-train alert (storage.active_alerts).
local ALERT_STUCK = 1

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

--- Chips besides the statuses, by the station flag they test (tab-logic); stuck comes from the trains.
local FLAG_CHIPS = { unserved = logic.FLAG_UNSERVED, setup = logic.FLAG_SETUP, failing = logic.FAILING }
local CHIP_ORDER = { "all" }
for _, s in ipairs(STATUSES) do CHIP_ORDER[#CHIP_ORDER + 1] = s end
for _, c in ipairs({ "unserved", "setup", "stuck", "failing" }) do CHIP_ORDER[#CHIP_ORDER + 1] = c end
local CHIP_ICON = {
	unserved = "utility/warning_icon",
	setup = "utility/status_yellow",
	stuck = "item/locomotive",
	failing = "utility/danger_icon",
}
-- Widths of the chips with their names at the default font (English, measured on screenshots at UI scale 1.0), so the
-- subheader can fall back to icon and count before it overflows.
local CHIP_WIDTH = {
	all = 52, no_power = 96, disabled = 88, warming_up = 112, starved = 84, saturated = 96, idle = 60, ok = 52,
	unserved = 96, setup = 72, stuck = 104, failing = 80,
}

local COLUMNS = { "name", "station_status", "network", "provided_requested", "deliveries", "wait", "last_delivery" }
local RIGHT = { wait = true, last_delivery = true }
-- Fixed widths in logical px; the name and the two slot strips share the rest (column_widths).
local W = { station_status = 156, network = 80, dl_count = 40, wait = 64, last_delivery = 88 }
local NAME_MIN = 160

--- Column widths for a tab content width: fixed columns, slot strips of whole slots (Provided / requested 5..12,
--- Deliveries 2..6), the name takes the rest.
--- @param cw int
--- @return table
local function column_widths(cw)
	-- Row padding, frame borders and six gaps of 8 between seven columns.
	local avail = cw - 72
	local fixed = W.station_status + W.network + W.dl_count + 4 + W.wait + W.last_delivery
	local rest = avail - fixed
	local pr = math.min(12, math.max(5, math.floor(rest * 0.45 / SLOT)))
	local dl = math.min(6, math.max(2, math.floor(rest * 0.2 / SLOT)))
	local name = rest - (pr + dl) * SLOT
	while name < NAME_MIN and pr > 5 do
		pr = pr - 1
		name = name + SLOT
	end
	while name < NAME_MIN and dl > 2 do
		dl = dl - 1
		name = name + SLOT
	end
	return {
		cw = cw,
		name = name,
		station_status = W.station_status,
		network = W.network,
		pr_slots = pr,
		provided_requested = pr * SLOT,
		dl_slots = dl,
		dl_count = W.dl_count,
		deliveries = W.dl_count + 4 + dl * SLOT,
		wait = W.wait,
		last_delivery = W.last_delivery,
	}
end

--- @param player_data PlayerData
--- @return table
local function widths_for(player_data)
	local layout = player_data.layout
	return column_widths(layout and layout.content_width or (sizing.MAX_WIDTH - sizing.OUTER_WIDTH))
end

local function header_cell(column, width, selected)
	local locale = string.gsub(column, "_", "-")
	return {
		type = "flow",
		direction = "horizontal",
		style_mods = { width = width, horizontal_align = RIGHT[column] and "right" or "left", vertical_align = "center" },
		{
			type = "checkbox",
			style = selected and "ltnm_selected_sort_checkbox" or "ltnm_sort_checkbox",
			caption = { "cybersyn-gui." .. locale },
			tooltip = { "cybersyn-gui.stations-sort-" .. locale },
			state = false,
			tags = { column = column, default_state = false },
			handler = { [defines.events.on_gui_checked_state_changed] = stations_tab.handle.on_sort_checkbox_changed },
		},
	}
end

function stations_tab.create()
	local w = column_widths(sizing.MAX_WIDTH - sizing.OUTER_WIDTH)
	local header = { type = "frame", name = HEADER, style = "cybersyn_list_header" }
	for i, column in ipairs(COLUMNS) do
		header[#header + 1] = header_cell(column, w[column], i == 1)
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
			header,
			{ name = SCROLL, type = "flow", direction = "vertical", style = "cybersyn_list_rows" },
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
				name = "manager_stations_subfooter",
				style = "cybersyn_list_subfooter",
				{ type = "label", name = "manager_stations_summary", style = "cybersyn_subheader_note" },
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
	wait = function(st)
		local start = st.longest_wait_start
		return start and -start or nil
	end,
	last_delivery = function(st)
		local last = st.last_delivery_tick
		return last and -last or nil
	end,
}

--- The toggled chip: a status, one of the flag chips, or nil (All). A stale value from an older version is dropped.
--- @param player_data PlayerData
--- @return string?
local function active_chip(player_data)
	local s = player_data.stations_status_filter
	if s then
		if STATUS_RANK[s] then return s end
		player_data.stations_status_filter = nil
	end
	local c = player_data.stations_chip
	if c then
		if FLAG_CHIPS[c] or c == "stuck" then return c end
		player_data.stations_chip = nil
	end
	return nil
end

--- Everything the filtered set depends on besides the data itself. The chip is left out: it is applied after the
--- cached order, so a station changing status mid-pass shows up at once, matching the chip counts.
local function filter_sig(f)
	return table.concat({
		f.terms and table.concat(f.terms, " ") or "", f.item or "", f.network or "", f.mask, f.surface or "",
	}, "\1")
end

local function view_sig(f, column, ascending)
	return column .. "\1" .. (ascending and "+" or "-") .. "\1" .. filter_sig(f)
end

--- @param counts table
--- @param flags int
--- @param d int +1 or -1
local function count_flags(counts, flags, d)
	if band(flags, logic.FLAG_UNSERVED) ~= 0 then counts.unserved = counts.unserved + d end
	if band(flags, logic.FLAG_SETUP) ~= 0 then counts.setup = counts.setup + d end
	if band(flags, logic.FAILING) ~= 0 then counts.failing = counts.failing + d end
end

--- Rescans every snapshot station into a fresh per-player query cache.
local function rebuild_query(player_data, snapshot, f, fsig, column, epoch, pos)
	local stations = snapshot.stations
	local key_fn = sort_keys[column]
	local status, keys, flags = {}, {}, {}
	local counts = { all = 0, unserved = 0, setup = 0, failing = 0 }
	for _, s in ipairs(STATUSES) do counts[s] = 0 end
	local ctx = { status = status }
	for id, st in pairs(stations) do
		if util.station_passes(st, f) then
			local s = st.status or "ok"
			status[id] = s
			counts[s] = counts[s] + 1
			counts.all = counts.all + 1
			local fl = logic.station_flags(st)
			flags[id] = fl
			count_flags(counts, fl, 1)
			keys[id] = key_fn(st, ctx)
		end
	end
	local cache = {
		epoch = epoch, pos = pos, fsig = fsig, column = column,
		status = status, keys = keys, flags = flags, counts = counts, dirty = true, changed = {},
	}
	player_data.stations_query = cache
	return cache
end

--- Folds the station records the collector refilled, reclassified or removed since the last render into the cache.
local function apply_changes(cache, snapshot, f, ids, first, last)
	local stations = snapshot.stations
	local key_fn = sort_keys[cache.column]
	local status, keys, counts, flags = cache.status, cache.keys, cache.counts, cache.flags
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
		local old_flags = flags[id]
		local new_flags = new and logic.station_flags(st) or nil
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
		if old_flags ~= new_flags then
			if old_flags then count_flags(counts, old_flags, -1) end
			if new_flags then count_flags(counts, new_flags, 1) end
			flags[id] = new_flags
			cache.version = (cache.version or 0) + 1
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

--- Stations named by a train with a stuck alert, and a signature of the set for the row cache.
--- @param snapshot Snapshot
--- @return {[uint]: true}
--- @return string
local function stuck_set(snapshot)
	local set = logic.stuck_stations(snapshot.alerts, snapshot.trains, ALERT_STUCK)
	local ids = {}
	for id in pairs(set) do ids[#ids + 1] = id end
	table.sort(ids)
	return set, table.concat(ids, ",")
end

--- @param chip string?
--- @param id uint
--- @param cache table
--- @param stuck {[uint]: true}
--- @return boolean
local function chip_passes(chip, id, cache, stuck)
	if not chip then return true end
	if STATUS_RANK[chip] then return cache.status[id] == chip end
	if chip == "stuck" then return stuck[id] == true end
	return band(cache.flags[id] or 0, FLAG_CHIPS[chip]) ~= 0
end

--- Filters, classifies and sorts the snapshot stations. The chip applies after counting so every chip shows what
--- it would yield.
--- Classification is cached per player and updated only for the records the collector replaced since the last
--- render, so a render costs O(changed + page) rather than O(stations). Sorting 2,000 rows costs more than the
--- rest of an update, so the order is kept until the sort or a filter changes, or a completed pass changed a key
--- or the filtered set; in between, rows show live data in the order of the last sort, which also keeps them
--- from shuffling while a pass trickles in.
--- @param player_data PlayerData
--- @return SnapshotStation[] rows
--- @return {[string]: integer} counts per status and chip over the filtered set, plus `all`
--- @return table ctx {status = {[id]=status}, flags, stuck, now, snapshot}
--- @return string column
--- @return boolean ascending
function stations_tab.query(player_data)
	local snapshot = collector.get()
	local stations = snapshot.stations
	local f = util.get_filters(player_data)
	local wanted = active_chip(player_data)
	local column, ascending = util.get_sort(player_data, TAB, "name")
	if not sort_keys[column] then column = "name" end
	-- The first pass after opening is still filling records: rows and counts from part of the stations would change
	-- on every update and disagree with the other tabs, so there are none until it completes.
	local cache = player_data.stations_query
	-- The first build after a boosted pass is split over the next two updates, so no tick carries more than one of
	-- the pass's last batch, classifying and sorting every station (~5 ms on pY 123) or writing every row of the page:
	-- the completing update shows the placeholder still, the next one fills the query cache and still shows the
	-- placeholder, the one after renders from it.
	if not snapshot.tick or (not cache and snapshot.boosted and snapshot.tick == game.tick) then
		return {}, {}, { status = {}, flags = {}, stuck = {}, now = game.tick, snapshot = snapshot, pending = true }, column, ascending
	end
	local first_build = not cache and snapshot.boosted

	local fsig = filter_sig(f)
	local epoch, pos = collector.log_position()
	local ids, first, last
	if cache and cache.fsig == fsig and cache.column == column and cache.flags then
		ids, first, last = collector.changed_since(cache.epoch, cache.pos)
	end
	if ids then
		apply_changes(cache, snapshot, f, ids, first, last)
		cache.pos = pos
	else
		cache = rebuild_query(player_data, snapshot, f, fsig, column, epoch, pos)
	end
	local status = cache.status
	local stuck, stuck_sig = stuck_set(snapshot)
	local n_stuck = 0
	for id in pairs(stuck) do
		if status[id] then n_stuck = n_stuck + 1 end
	end
	cache.counts.stuck = n_stuck
	local ctx = { status = status, flags = cache.flags, stuck = stuck, now = game.tick, snapshot = snapshot }

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

	-- The row list only changes with the order, the chip, a status or flag, or the stuck set; rebuilding it every
	-- update allocated tens of KB per render on a large base.
	local rows = cache.rows
	local want_sig = (wanted or "") .. (wanted == "stuck" and ("\1" .. stuck_sig) or "")
	if not rows or cache.rows_order ~= cache.order or cache.rows_wanted ~= want_sig or cache.rows_version ~= cache.version then
		rows = {}
		for _, id in ipairs(cache.order) do
			if status[id] and chip_passes(wanted, id, cache, stuck) then
				rows[#rows + 1] = stations[id]
			end
		end
		cache.rows, cache.rows_order, cache.rows_wanted, cache.rows_version = rows, cache.order, want_sig, cache.version
	end
	if first_build then
		return {}, {}, { status = {}, flags = {}, stuck = {}, now = game.tick, snapshot = snapshot, pending = true }, column, ascending
	end
	return rows, cache.counts, ctx, column, ascending
end

-- ---------------------------------------------------------------- rows

local NONE_CAPTION = { "cybersyn-gui.none-short" }

--- Names of the setup checks in a lint bitmask, for the setup chip's tooltip.
--- @param lint int
--- @return LocalisedString
local function setup_tooltip(lint)
	local out = { "", { "cybersyn-gui.stations-setup-chip-tooltip" } }
	for check = 1, LINT_COUNT do
		if bit32.btest(lint, LINT_BIT[check]) and #out < 18 then
			out[#out + 1] = "\n• "
			out[#out + 1] = { "cybersyn-diag.lint-" .. LINT_KEYS[check] }
		end
	end
	return out
end

--- Everything a row shows that is not a slot table, as plain values comparable between updates. Tooltips and the
--- network cell cost API calls, so they are built by functions that run only when their sig changed.
--- @param st SnapshotStation
--- @param ctx table
local function row_model(st, ctx)
	local now = ctx.now
	local status = ctx.status[st.id]
	local m = { status = status, lint = st.lint or 0 }

	local read_age = st.read_tick and now - st.read_tick or nil
	m.name_sig = st.name .. "\1" .. st.id .. "\1" .. (read_age and text.read_step(read_age) or "")
	m.name_tooltip = function()
		local tip = { "", "[font=default-semibold]", st.name, "[/font]" }
		if read_age then
			tip[#tip + 1] = "\n"
			tip[#tip + 1] = text.read_ago(read_age, util.format_duration)
		end
		tip[#tip + 1] = "\n"
		tip[#tip + 1] = util.LINK_FOOTER
		return tip
	end

	local hashes = status == "starved" and starved_hashes(st, ctx.snapshot.starved) or nil
	local unserved = st.unserved and st.unserved.count or 0
	m.status_tip_sig = (hashes and (status .. "|" .. table.concat(hashes, ",", 1, math.min(#hashes, 10))) or status)
		.. "|" .. unserved .. (st.throttling and "|t" or "")
	m.status_tooltip = function()
		local tooltip = { "", { status_key(status) .. "-tooltip" } }
		if hashes then
			local icons = {}
			for i = 1, math.min(#hashes, 10) do
				icons[i] = util.rich_text_from_signal(util.signalid_from_hash(hashes[i]))
			end
			tooltip[#tooltip + 1] = "\n" .. table.concat(icons, " ")
		end
		if unserved > 0 then
			tooltip[#tooltip + 1] = "\n"
			tooltip[#tooltip + 1] = { "cybersyn-gui.stations-unserved-line", tostring(unserved) }
		end
		if st.throttling then
			tooltip[#tooltip + 1] = "\n"
			tooltip[#tooltip + 1] = { "cybersyn-gui.stations-throttling-line" }
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

--- Slot buttons of the 32 px rows: clickable items with the standard item click semantics and hover-hold, the
--- filtered item highlighted rather than hidden.
local function decorate_slots(defs, item)
	for _, def in pairs(defs) do
		local hash = def.tags and def.tags.item_hash
		if hash then
			def.enabled = true
			def.mouse_button_filter = { "left", "right" }
			def.handler = { [defines.events.on_gui_click] = stations_tab.handle.on_item_click }
			util.hoverable(def, SCROLL)
			def.tooltip = { "", def.tooltip, "\n", { "cybersyn-gui.item-click-hint" } }
		end
		local count = def.children and def.children[1]
		if count then count.style = "cybersyn_slot_32_count" end
		local style = def.style
		if hash and hash == item then
			style = string.gsub(style, "^ltnm_small_slot_button_", "cybersyn_selected_slot_32_")
		else
			style = string.gsub(style, "^ltnm_small_slot_button_", "cybersyn_slot_32_")
		end
		def.style = style
	end
	return defs
end

--- One line of slots: when the items do not fit, the last slot shows "+n" with the rest in its tooltip.
--- @param defs flib.GuiElemDef[]
--- @param capacity int
--- @return flib.GuiElemDef[]
local function fit_slots(defs, capacity)
	local shown, over = logic.fit_slots(#defs, capacity)
	if over == 0 then return defs end
	local out = {}
	for i = 1, shown do out[i] = defs[i] end
	local lines = {}
	for i = shown + 1, math.min(#defs, shown + 24) do
		local d = defs[i]
		lines[#lines + 1] = "[img=" .. d.sprite .. "] " .. tostring(d.children[1].caption)
	end
	out[shown + 1] = {
		type = "label",
		style = "cybersyn_overflow_label",
		style_mods = { width = SLOT, height = SLOT, vertical_align = "center" },
		caption = "+" .. over,
		tooltip = table.concat(lines, "\n"),
		tags = { overflow = true },
	}
	return out
end

local function slot_key(def)
	if def.type == "label" then return "+" end
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
	if def.type == "label" then
		elem.caption = def.caption
		elem.tooltip = def.tooltip
		return
	end
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
		local caption = def.type == "label" and def.caption or def.children[1].caption
		entries[i] = {
			key = slot_key(def),
			def = def,
			sig = tostring(def.style) .. "|" .. tostring(caption) .. "|" .. minute .. "|" .. table.concat(flatten(def.tooltip, {}), "\1"),
			build = function() return def end,
			update = update_slot,
		}
	end
	return util.sync_children(table_elem, entries, state, hold)
end

local SLOT_TABLES = {
	pr = function(st, item, w)
		return fit_slots(decorate_slots(util.slot_table_build_from_station(st), item), w.pr_slots)
	end,
	dl = function(st, item, w)
		return fit_slots(decorate_slots(util.slot_table_build_from_deliveries(st), item), w.dl_slots)
	end,
}

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
--- @return {pr: string, dl: string}
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
	return { pr = pr, dl = table.concat(parts, "\1") }
end

local function slot_state(slots, name)
	local s = slots[name]
	if not s then
		s = {}
		slots[name] = s
	end
	return s
end

--- Element references of a row, found once and kept in the row's memo.
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
		setup = status[3],
		net = c[3],
		net_sprite = net[1],
		net_label = net[2],
		pr = c[4].children[1],
		dl_count = dl[1],
		dl = dl[2],
		wait = c[6],
		last = c[7],
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
--- @param sigs {pr: string, dl: string}
--- @param w table column widths
local function update_row(row, st, m, cell, item, hold, minute, sigs, w)
	local r = cell_refs(cell, row)
	if cell.name_sig ~= m.name_sig then
		name_cell.update(r.name, st.name_parts, st.name, { kind = "station", id = st.id }, w.name, m.name_tooltip(), SCROLL)
		cell.name_sig = m.name_sig
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
	if cell.lint ~= m.lint then
		r.setup.visible = m.lint ~= 0
		if m.lint ~= 0 then r.setup.tooltip = setup_tooltip(m.lint) end
		cell.lint = m.lint
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
			local result = sync_slots(r[name], build(st, item, w), slot_state(slots, name), hold, minute)
			-- A hold deferred a structural change, so the table is retried next update.
			sig_of[name] = result ~= "held" and sig or nil
		end
	end
end

--- @param st SnapshotStation
--- @param m table row model
--- @param color "light"|"dark"
--- @param item string?
--- @param w table column widths
local function row_def(st, m, color, item, w)
	local defs = { pr = SLOT_TABLES.pr(st, item, w), dl = SLOT_TABLES.dl(st, item, w) }
	local net_sprite, net_caption, net_tooltip = m.network()
	return util.hoverable({
		type = "frame",
		style = "cybersyn_station_row_" .. color,
		style_mods = { height = ROW_HEIGHT },
		direction = "horizontal",
		tags = { station_id = st.id },
		name_cell.def(st.name_parts, st.name, { kind = "station", id = st.id }, w.name, m.name_tooltip(), SCROLL),
		{
			type = "flow",
			style = "cybersyn_cell_flow",
			style_mods = { width = w.station_status },
			{ type = "sprite", style = "flib_indicator", sprite = "flib_indicator_" .. STATUS_COLOR[m.status] },
			{ type = "label", style = "cybersyn_cell_label", caption = { status_key(m.status) }, tooltip = m.status_tooltip() },
			util.hoverable({
				type = "button",
				style = "cybersyn_small_chip_orange",
				caption = { "cybersyn-gui.stations-setup-chip" },
				tooltip = m.lint ~= 0 and setup_tooltip(m.lint) or nil,
				visible = m.lint ~= 0,
			}, SCROLL),
		},
		{
			type = "flow",
			style = "cybersyn_cell_flow",
			style_mods = { width = w.network },
			tooltip = net_tooltip,
			{ type = "sprite", sprite = net_sprite, resize_to_sprite = false, style_mods = { size = 24 }, ignored_by_interaction = true },
			{ type = "label", caption = net_caption, ignored_by_interaction = true },
		},
		{
			type = "flow",
			style = "cybersyn_cell_flow",
			style_mods = { width = w.provided_requested },
			{ type = "table", style = "slot_table", column_count = w.pr_slots, children = defs.pr },
		},
		{
			type = "flow",
			style = "cybersyn_cell_flow",
			style_mods = { width = w.deliveries },
			{
				type = "label",
				style = "cybersyn_cell_value",
				style_mods = { width = w.dl_count },
				caption = m.dl_caption,
				tooltip = { "cybersyn-gui.stations-deliveries-count-tooltip" },
			},
			{ type = "table", style = "slot_table", column_count = w.dl_slots, children = defs.dl },
		},
		{ type = "label", style = "cybersyn_cell_value", style_mods = { width = w.wait }, caption = m.wait_caption, tooltip = wait_tooltip(m) },
		{ type = "label", style = "cybersyn_cell_value", style_mods = { width = w.last_delivery }, caption = m.last_caption, tooltip = last_tooltip(m) },
	}, SCROLL), defs
end

-- ---------------------------------------------------------------- chips

--- @param key string
--- @return string
local function chip_icon(key)
	if STATUS_COLOR[key] then return "flib_indicator_" .. STATUS_COLOR[key] end
	local icon = CHIP_ICON[key]
	if icon and helpers.is_valid_sprite_path(icon) then return icon end
	return "utility/warning_icon"
end

--- @param key string
--- @param count integer? nil while the first pass after opening runs
--- @param compact boolean
local function chip_caption(key, count, compact)
	local number = count and format.number(count) or "–"
	if key == "all" then
		return { "", { "cybersyn-gui.station-status-all" }, "  ", number }
	end
	local name = STATUS_COLOR[key] and { status_key(key) } or { "cybersyn-gui.stations-chip-" .. key }
	if compact then return "[img=" .. chip_icon(key) .. "] " .. number end
	return { "", "[img=" .. chip_icon(key) .. "] ", name, "  ", number }
end

--- @param key string
--- @return LocalisedString?
local function chip_tooltip(key)
	if key == "all" then return nil end
	if STATUS_COLOR[key] then return { "", "[font=default-semibold]", { status_key(key) }, "[/font]\n", { status_key(key) .. "-tooltip" } } end
	return { "", "[font=default-semibold]", { "cybersyn-gui.stations-chip-" .. key }, "[/font]\n", { "cybersyn-gui.stations-chip-" .. key .. "-tooltip" } }
end

--- The subheader of the tab (templates.tab_header) gets the chip flow at its right end on first use.
--- @param player_data PlayerData
--- @return LuaGuiElement?
local function chip_flow(player_data)
	local refs = player_data.refs
	local flow = refs[CHIPS]
	if flow and flow.valid then return flow end
	local subheader = refs[TAB .. "_subheader"]
	if not (subheader and subheader.valid) then return nil end
	local _, elem = gui.add(subheader, {
		type = "flow",
		name = CHIPS,
		direction = "horizontal",
		style_mods = { vertical_align = "center", horizontal_spacing = 4 },
	})
	refs[CHIPS] = elem
	return elem
end

--- Width left for the chips in the subheader after the search field, the item chip and the collecting note.
--- @param player_data PlayerData
--- @param tab string
--- @return int
function stations_tab.chip_space(player_data, tab)
	local refs = player_data.refs
	local layout = player_data.layout
	local space = (layout and layout.content_width or (sizing.MAX_WIDTH - sizing.OUTER_WIDTH)) - 24
	local function shown(name)
		local e = refs[tab .. name]
		return e and e.valid and e.visible
	end
	if shown("_search_field") then space = space - 208 end
	if shown("_chip_flow") then space = space - 260 end
	if shown("_collecting") then space = space - 160 end
	return space
end

local FULL_CHIPS = 0
for _, key in ipairs(CHIP_ORDER) do FULL_CHIPS = FULL_CHIPS + CHIP_WIDTH[key] + 4 end

--- Chips: counts over the filtered set, click to show only that set, click again for all.
local function render_chips(player_data, counts, state)
	local flow = chip_flow(player_data)
	if not flow then return end
	local wanted = active_chip(player_data) or "all"
	local compact = logic.chip_mode(stations_tab.chip_space(player_data, TAB), FULL_CHIPS) == "compact"
	local entries = {}
	for i, key in ipairs(CHIP_ORDER) do
		local count = counts[key]
		local selected = wanted == key
		local enabled = selected or (count ~= nil and count > 0)
		entries[i] = {
			key = key,
			sig = tostring(count) .. (selected and "+" or "-") .. (compact and "c" or "f"),
			build = function()
				return {
					type = "button",
					style = "cybersyn_filter_chip",
					caption = chip_caption(key, count, compact),
					tooltip = chip_tooltip(key),
					toggled = selected,
					enabled = enabled,
					tags = { station_chip = key },
					handler = { [defines.events.on_gui_click] = stations_tab.handle.on_status_chip_click },
				}
			end,
			update = function(elem)
				elem.caption = chip_caption(key, count, compact)
				elem.toggled = selected
				elem.enabled = enabled
			end,
		}
	end
	util.sync_children(flow, entries, state, false)
end

-- ---------------------------------------------------------------- render

--- Writes the column widths into the header and the sort state into its checkboxes when either changed.
--- @param player_data PlayerData
--- @param w table
--- @return boolean widths_changed
local function sync_header(player_data, w, column, ascending)
	local header = player_data.refs[HEADER]
	if not (header and header.valid) then return false end
	local state = util.gui_state(player_data, HEADER)
	local changed = state.cw ~= w.cw
	if changed then
		for i, cell in ipairs(header.children) do
			cell.style.width = w[COLUMNS[i]]
		end
		state.cw = w.cw
	end
	local sig = column .. (ascending and "+" or "-")
	if changed or state.sort ~= sig then
		for _, cell in ipairs(header.children) do util.sync_sort_header(cell, column, ascending) end
		state.sort = sig
	end
	return changed
end

--- @param map_data MapData
--- @param player_data PlayerData
function stations_tab.build(map_data, player_data)
	local refs = player_data.refs
	local list = refs[SCROLL]
	if not (list and list.valid) then return end

	local rows, counts, ctx, column, ascending = stations_tab.query(player_data)
	stations_tab.fix_heights(refs, { TAB .. "_banner", TAB .. "_subheader", HEADER, "manager_stations_subfooter" })
	local w = widths_for(player_data)
	local state = util.gui_state(player_data, SCROLL)
	if sync_header(player_data, w, column, ascending) or state.cw ~= w.cw then
		-- Rows built for other widths are rebuilt rather than resized cell by cell.
		state.keys = nil
		state.cells = nil
		state.cw = w.cw
	end
	local first, last = util.paginate(player_data, TAB, #rows)
	render_chips(player_data, counts, util.gui_state(player_data, CHIPS))
	local summary = refs.manager_stations_summary
	if ctx.pending then
		-- Rows from before the window was closed stay hidden rather than destroyed: most of them are reused, not
		-- built again, once the first pass completes.
		list.visible = false
		local warning = refs.manager_stations_warning_flow
		if warning and warning.valid then
			warning.visible = true
			refs.manager_stations_warning_label.caption = { "cybersyn-gui.stations-collecting" }
		end
		if summary and summary.valid then summary.caption = "" end
		return
	end

	local item = player_data.search_item
	local minute = math.floor(ctx.now / 3600)
	-- A hold must only defer data-driven reshuffles; a filter, sort, chip or page change the user just made (often
	-- by clicking inside a hovered row) has to apply at once.
	local view = view_sig(util.get_filters(player_data), column, ascending) .. "\1"
		.. (active_chip(player_data) or "") .. "\1" .. tostring(player_data.page and player_data.page[TAB])
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
				local def, defs = row_def(st, m, color, item, w)
				local slots = {}
				for name, list_defs in pairs(defs) do
					local keys = {}
					for k, d in ipairs(list_defs) do keys[k] = slot_key(d) end
					slots[name] = { keys = keys }
				end
				cells[id] = {
					slots = slots, slot_sigs = slot_sigs(st, item, minute), name_sig = m.name_sig, status = m.status,
					color = color, lint = m.lint, status_tip_sig = m.status_tip_sig, net_sig = m.net_sig, dl_sig = m.dl_sig,
					wait_sig = m.wait_sig, last_sig = m.last_sig, wait_tip = m.wait_full or "", last_tip = m.last_full or "",
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
				local tags = elem.tags
				tags.station_id = id
				elem.tags = tags
			end,
			update = function(elem)
				local cell = old_cells[id] or {}
				if cell.color ~= color then
					-- Assigning a style drops style_mods: the fixed height is written again.
					elem.style = "cybersyn_station_row_" .. color
					elem.style.height = ROW_HEIGHT
					cell.color = color
				end
				update_row(elem, st, m, cell, item, hold, minute, slot_sigs(st, item, minute), w)
				cells[id] = cell
			end,
		}
	end
	local result = util.sync_children(list, entries, state, hold, true)
	if result == "held" then
		-- Rows that left the page keep their memo until the hold ends and they are rebuilt.
		for id, cell in pairs(old_cells) do
			if not cells[id] then cells[id] = cell end
		end
	end
	state.cells = cells
	state.result = result

	if summary and summary.valid then
		local sig = counts.all .. "|" .. #rows
		if state.summary ~= sig then
			summary.caption = { "cybersyn-gui.stations-summary", format.number(#rows), format.number(counts.all) }
			state.summary = sig
		end
	end

	local empty = #rows == 0
	list.visible = not empty
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

--- Writes the strips' fixed heights into the elements (a height from a style prototype cannot be read back through
--- LuaStyle), so measured_rows can count what they leave for rows. Once per element.
--- @param refs table<string, LuaGuiElement>
--- @param names string[]
function stations_tab.fix_heights(refs, names)
	for _, name in ipairs(names) do
		local e = refs[name]
		if e and e.valid and e.style.maximal_height ~= STRIP_HEIGHT then e.style.height = STRIP_HEIGHT end
	end
end

--- Rows that fit the tab, measured from the elements: the content frame's height less every other visible strip's
--- fixed height, then rows counted while their fixed heights still fit. A strip or row without a fixed height cannot
--- be measured and yields -1 (strip) or ends the count (row).
--- @param player_data PlayerData
--- @param content_name string
--- @param list_name string
--- @return int
function stations_tab.measured_rows(player_data, content_name, list_name)
	local refs = player_data.refs
	local list, content = refs[list_name], refs[content_name]
	if not (list and list.valid and list.visible and content and content.valid) then return 0 end
	local avail = content.style.maximal_height
	if not avail or avail <= 0 then return 0 end
	for _, child in ipairs(content.children) do
		if child ~= list and child.visible then
			local style = child.style
			local h = style.maximal_height
			if not h or h ~= style.minimal_height then return -1 end
			avail = avail - h
		end
	end
	local n, used = 0, 0
	for _, row in ipairs(list.children) do
		local style = row.style
		local h = style.maximal_height
		if not h or h <= 0 or style.minimal_height ~= h then break end
		if used + h > avail then break end
		used = used + h
		n = n + 1
	end
	return n
end

dev.register_rows(TAB, function(player_data)
	return stations_tab.measured_rows(player_data, "manager_stations_content_frame", SCROLL)
end)

dev.register_dump(TAB, function(player_data)
	local list = player_data.refs[SCROLL]
	local rows, counts, ctx, column, ascending = stations_tab.query(player_data)
	local key_fn = sort_keys[column]
	local ids, keys, statuses, names, setup = {}, {}, {}, {}, {}
	local stripes_ok = true
	local by_id = ctx.snapshot.stations
	for i, row in ipairs(list.children) do
		local id = row.tags.station_id
		ids[i] = id
		local color = i % 2 == 0 and "dark" or "light"
		if row.style.name ~= "cybersyn_station_row_" .. color then stripes_ok = false end
		local st = by_id[id]
		keys[i] = st and key_fn(st, ctx)
		statuses[i] = ctx.status[id]
		names[i] = row.children[1].children[2].caption
		setup[i] = row.children[2].children[3].visible
	end
	local chips, chip_counts = {}, {}
	local flow = player_data.refs[CHIPS]
	if flow and flow.valid then
		for i, chip in ipairs(flow.children) do
			chips[i] = { chip.tags.station_chip, chip.toggled, chip.enabled }
		end
	end
	local status_counts = {}
	for k, v in pairs(counts) do
		if k == "all" or STATUS_RANK[k] then status_counts[k] = v else chip_counts[k] = v end
	end
	return {
		ids = ids,
		keys = keys,
		statuses = statuses,
		names = names,
		setup = setup,
		column = column,
		ascending = ascending,
		page = player_data.page and player_data.page[TAB],
		total = #rows,
		counts = status_counts,
		chip_counts = chip_counts,
		chip = active_chip(player_data),
		status_filter = player_data.stations_status_filter,
		visible = list.visible,
		warning = player_data.refs.manager_stations_warning_flow.visible,
		chips = chips,
		render = util.gui_state(player_data, SCROLL).result,
		sort_kind = player_data.stations_query and player_data.stations_query.sort_kind,
		stripes_ok = stripes_ok,
		widths = widths_for(player_data),
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

--- @param e EventData.on_gui_click
function stations_tab.handle.on_item_click(player, player_data, refs, e)
	local hash = e.element.tags.item_hash
	if hash then util.item_button_click(player, player_data, e, hash) end
end

--- @param e EventData.on_gui_click
function stations_tab.handle.on_status_chip_click(player, player_data, refs, e)
	stations_tab.set_chip(player_data, e.element.tags.station_chip)
	util.rerender(player, player_data)
end

--- Toggles a chip: a status, "unserved", "setup", "stuck", "failing"; "all" or the active chip again clears it.
--- @param player_data PlayerData
--- @param chip string?
function stations_tab.set_chip(player_data, chip)
	if chip == "all" or chip == active_chip(player_data) then chip = nil end
	player_data.stations_status_filter = nil
	player_data.stations_chip = nil
	if chip and STATUS_RANK[chip] then
		player_data.stations_status_filter = chip
	elseif chip and (FLAG_CHIPS[chip] or chip == "stuck") then
		player_data.stations_chip = chip
	end
	util.reset_page(player_data, TAB)
end

--- @param player_data PlayerData
--- @param status string? one of STATUSES, nil = all; selecting the active status again clears it
function stations_tab.set_status_filter(player_data, status)
	stations_tab.set_chip(player_data, status)
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
	util.rerender(player, player_data)
end

gui.add_handlers(stations_tab.handle, stations_tab.wrapper)

-- The shared dev interface has no per-tab setters; the chips are local to this tab.
if dev.enabled() and not remote.interfaces["cybersyn-manager-dev-stations"] then
	remote.add_interface("cybersyn-manager-dev-stations", {
		set_status_filter = function(pi, status)
			local player = game.get_player(pi)
			local player_data = storage.manager.players[pi]
			player_data.stations_status_filter = nil
			player_data.stations_chip = nil
			stations_tab.set_chip(player_data, status or nil)
			util.rerender(player, player_data)
			return player_data.stations_status_filter or "all"
		end,
		--- Toggles any chip as a click would ("all" clears); returns the active chip or "all".
		set_chip = function(pi, chip)
			local player = game.get_player(pi)
			local player_data = storage.manager.players[pi]
			player_data.stations_status_filter = nil
			player_data.stations_chip = nil
			stations_tab.set_chip(player_data, chip or nil)
			util.rerender(player, player_data)
			return active_chip(player_data) or "all"
		end,
		column_widths = column_widths,
	})
end

return stations_tab
