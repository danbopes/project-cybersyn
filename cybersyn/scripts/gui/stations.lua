-- Stations tab (PLAN3 §4.7, PLAN4 D7): filter chips in the tab's subheader (a second line below it when they do not
-- fit), one 32 px row per station (name with its icons, status, network, provided / requested, deliveries, wait, last
-- dispatch), exactly as many rows as the window fits, the pager in a subfooter. The Problems chip is the setup lint's
-- view: a Problems column takes the place of Provided / requested, and the findings about stops and combinators that
-- are not a station (the registry) follow the stations as rows of their own.

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
local diag = require("scripts.diag")
local lint = require("scripts.lint")
local pm = require("scripts.gui.problems-model")
local lint_text = require("scripts.gui.lint-text")

local stations_tab = {}

--- @class PlayerData
--- @field stations_status_filter string? the status chip that is toggled (one of collector.STATUSES)
--- @field stations_chip "unserved"|"problems"|"stuck"|"failing"? the other chip that is toggled; never both
--- @field stations_problems_view boolean? the Problems chip was on at the last query (its sort is set on the way in)

local TAB = "stations_tab"
-- The row list. A flow since phase 4; the name stays because manager.refresh_sort_headers looks it up.
local SCROLL = "manager_stations_tab_scroll_pane"
local HEADER = "manager_stations_header"
local CHIPS = "manager_stations_status_flow"
-- The second line of chips, below the subheader.
local CHIP_ROW = "manager_stations_chip_row"
local CHIPS2 = "manager_stations_chip_flow2"
local UNLIMITED = collector.UNLIMITED
local ROW_HEIGHT = sizing.ROW_HEIGHT[TAB]
local SLOT = 32
-- Banner, subheader, column header and subfooter (styles cybersyn_tab_subheader, cybersyn_list_header,
-- cybersyn_list_subfooter).
local STRIP_HEIGHT = 36
local FIRST_UPDATE_ROWS = 15
local band = bit32.band
local FLAG_UNSERVED, FLAG_SETUP, FAILING = logic.FLAG_UNSERVED, logic.FLAG_SETUP, logic.FAILING
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
local FLAG_CHIPS = { unserved = logic.FLAG_UNSERVED, problems = logic.FLAG_SETUP, failing = logic.FAILING }
local CHIP_ORDER = { "all" }
for _, s in ipairs(STATUSES) do CHIP_ORDER[#CHIP_ORDER + 1] = s end
for _, c in ipairs({ "unserved", "problems", "stuck", "failing" }) do CHIP_ORDER[#CHIP_ORDER + 1] = c end
local CHIP_ICON = {
	unserved = "utility/warning_icon",
	problems = "utility/status_yellow",
	stuck = "item/locomotive",
	failing = "utility/danger_icon",
}
-- Widths of the chips with their names and a one-digit count at the default font (English, measured on a screenshot at
-- UI scale 1.0), so the chips that do not fit beside the search field go to the second line instead of overflowing.
local CHIP_WIDTH = {
	all = 50, no_power = 110, disabled = 108, warming_up = 125, starved = 92, saturated = 114, idle = 75, ok = 72,
	unserved = 114, problems = 108, stuck = 152, failing = 98,
}
-- Each further digit of a count, separators included.
local DIGIT_WIDTH = 8

local COLUMNS = { "name", "station_status", "network", "provided_requested", "deliveries", "wait", "last_delivery" }
-- While the Problems chip is on, the fourth column shows a station's lint findings instead of its slots.
local PROBLEM_COLUMNS = { "name", "station_status", "network", "problems", "deliveries", "wait", "last_delivery" }
local PROBLEMS_COLUMN = 4
local WAIT_COLUMN = 6
local RIGHT = { wait = true, last_delivery = true }
-- Column captions and sort tooltips whose locale key is not the column's name.
local CAPTION_KEY = { last_delivery = "stations-last-dispatch", problems = "stations-problems" }
local SORT_KEY = { last_delivery = "stations-sort-last-dispatch", problems = "stations-sort-problems" }
-- Fixed widths in logical px; the name and the two slot strips share the rest (column_widths).
local W = { station_status = 156, network = 80, dl_count = 40, wait = 64, last_delivery = 88 }
local NAME_MIN = 160
-- The Problems column: a share of what the fixed columns leave, never under PROBLEMS_MIN while the name keeps NAME_MIN.
local PROBLEMS_SHARE = 0.5
local PROBLEMS_MIN = 300

--- Column widths for a tab content width: fixed columns, slot strips of whole slots (Provided / requested 5..12,
--- Deliveries 2..6), the name takes the rest. With `problems` the Problems column takes Provided / requested's place
--- and half the rest; a hidden Wait column gives its width to the name.
--- @param cw int
--- @param problems boolean?
--- @param hide_wait boolean?
--- @return table
local function column_widths(cw, problems, hide_wait)
	-- Row padding, frame borders and six gaps of 8 between seven columns (one fewer with Wait hidden).
	local avail = cw - 72
	local wait = W.wait
	if hide_wait then
		wait = 0
		avail = avail + 8
	end
	local fixed = W.station_status + W.network + W.dl_count + 4 + wait + W.last_delivery
	local rest = avail - fixed
	local pr = math.min(12, math.max(5, math.floor(rest * 0.45 / SLOT)))
	local dl = math.min(6, math.max(2, math.floor(rest * 0.2 / SLOT)))
	local fourth = problems and math.max(PROBLEMS_MIN, math.floor(rest * PROBLEMS_SHARE)) or pr * SLOT
	local name = rest - fourth - dl * SLOT
	while name < NAME_MIN and not problems and pr > 5 do
		pr = pr - 1
		fourth = pr * SLOT
		name = name + SLOT
	end
	while name < NAME_MIN and dl > 2 do
		dl = dl - 1
		name = name + SLOT
	end
	if problems and name < NAME_MIN and fourth > PROBLEMS_MIN then
		local give = math.min(NAME_MIN - name, fourth - PROBLEMS_MIN)
		fourth = fourth - give
		name = name + give
	end
	return {
		cw = cw,
		sig = cw .. (problems and "p" or "") .. (hide_wait and "w" or ""),
		problems_view = problems == true,
		hide_wait = hide_wait == true,
		name = name,
		station_status = W.station_status,
		network = W.network,
		pr_slots = pr,
		provided_requested = pr * SLOT,
		problems = fourth,
		dl_slots = dl,
		dl_count = W.dl_count,
		deliveries = W.dl_count + 4 + dl * SLOT,
		wait = wait,
		last_delivery = W.last_delivery,
	}
end

--- @param player_data PlayerData
--- @param problems boolean?
--- @param hide_wait boolean?
--- @return table
local function widths_for(player_data, problems, hide_wait)
	local layout = player_data.layout
	return column_widths(layout and layout.content_width or (sizing.MAX_WIDTH - sizing.OUTER_WIDTH), problems, hide_wait)
end

--- @param column string
--- @return LocalisedString caption
--- @return LocalisedString tooltip
local function header_texts(column)
	local locale = string.gsub(column, "_", "-")
	return { "cybersyn-gui." .. (CAPTION_KEY[column] or locale) },
		{ "cybersyn-gui." .. (SORT_KEY[column] or ("stations-sort-" .. locale)) }
end

local function header_cell(column, width, selected)
	local caption, tooltip = header_texts(column)
	return {
		type = "flow",
		direction = "horizontal",
		style_mods = { width = width, horizontal_align = RIGHT[column] and "right" or "left", vertical_align = "center" },
		{
			type = "checkbox",
			style = selected and "ltnm_selected_sort_checkbox" or "ltnm_sort_checkbox",
			caption = caption,
			tooltip = tooltip,
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
			-- Right below the subheader (manager.add_header puts the banner and the subheader first).
			{
				type = "frame",
				name = CHIP_ROW,
				style = "cybersyn_chip_row",
				visible = false,
				{ type = "empty-widget", style = "flib_horizontal_pusher" },
				{
					type = "flow",
					name = CHIPS2,
					direction = "horizontal",
					style_mods = { vertical_align = "center", horizontal_spacing = 4 },
				},
			},
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

-- Natural sort keys of station names ("stn-2" before "stn-10"): a pure function of the name, so a cache that differs
-- between Lua states cannot desync anything.
local natural_cache = {}

--- @param name_lower string
--- @return string
local function natural(name_lower)
	local key = natural_cache[name_lower]
	if not key then
		key = util.natural_key(name_lower)
		natural_cache[name_lower] = key
	end
	return key
end

--- True while no train has been dispatched to or from the station since it was built: Cybersyn starts
--- last_delivery_tick at the build tick, which the station record keeps as created_tick (stations built before that
--- field existed cannot tell and show their age). The tick is the snapshot's, as the age and the sort key are, so the
--- three agree during a pass; created_tick never changes and is read live.
--- @param st SnapshotStation
--- @return boolean
local function never_dispatched(st)
	local stations = storage.stations
	local station = stations and stations[st.id]
	return station ~= nil and station.created_tick ~= nil and st.last_delivery_tick == station.created_tick
end
stations_tab.never_dispatched = never_dispatched

--- Sort keys; each must return only numbers or only strings (nil sorts last). Keys are cached per station
--- between collector passes, so they must not depend on the current tick: ages sort by their negated start tick.
--- @type {[string]: fun(st: SnapshotStation, ctx: table): (number|string|nil)}
local sort_keys = {
	name = function(st) return natural(st.name_lower) end,
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
		if not last or never_dispatched(st) then return nil end
		return -last
	end,
	-- Open errors first (the Overview's Misconfigured stations), then open warnings and info, then stations whose
	-- findings are all acknowledged; by worst check within each. Acknowledgements change without a change-log entry,
	-- so query refreshes these keys when storage.acks.lint_version moves (diag.expire_acks bumps it as well).
	problems = function(st) return pm.station_rank(st.id, st.lint, diag.is_acked) end,
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
		-- The Setup chip of round 3 is the Problems chip.
		if c == "setup" then
			c = "problems"
			player_data.stations_chip = c
		end
		if FLAG_CHIPS[c] or c == "stuck" then return c end
		player_data.stations_chip = nil
	end
	return nil
end

--- The sort column for the view: the Problems column sorts only while it shows, and stands in for Provided /
--- requested there.
--- @param column string
--- @param problems boolean
--- @return string
local function view_column(column, problems)
	if problems and column == "provided_requested" then return "problems" end
	if not problems and column == "problems" then return "provided_requested" end
	return column
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
	if band(flags, logic.FLAG_SETUP) ~= 0 then counts.problems = counts.problems + d end
	if band(flags, logic.FAILING) ~= 0 then counts.failing = counts.failing + d end
end

--- @return int
local function lint_ack_version()
	local acks = storage.acks
	return acks and acks.lint_version or 0
end

--- Re-reads the Problems sort key of every listed station with a finding after an acknowledgement changed; the
--- stations whose place moved are merged into the order on this render: one explicit click, not a data-driven
--- reshuffle that waits for the pass.
--- @param cache table
--- @param stations {[uint]: SnapshotStation}
local function refresh_problem_keys(cache, stations)
	local keys, key_fn = cache.keys, sort_keys.problems
	local changed = cache.changed
	if not changed then
		changed = {}
		cache.changed = changed
	end
	for id, fl in pairs(cache.flags) do
		local st = stations[id]
		if st and band(fl, FLAG_SETUP) ~= 0 then
			local key = key_fn(st)
			if keys[id] ~= key then
				keys[id] = key
				changed[id] = true
				cache.dirty = true
				cache.sort_now = true
			end
		end
	end
end

--- Stations of the filtered set with an error nobody acknowledged, and those whose errors are all acknowledged: the
--- Overview's Misconfigured line and its "+n acked" under the same filters (pm.open_errors is its rule).
--- @param cache table
--- @return int open
--- @return int acked
local function open_error_counts(cache)
	local stations = collector.get().stations
	local error_mask, open_errors, is_acked = pm.error_mask(), pm.open_errors, diag.is_acked
	local open, acked = 0, 0
	for id, fl in pairs(cache.flags) do
		local st = stations[id]
		if st and band(fl, FLAG_SETUP) ~= 0 and band(st.lint or 0, error_mask) ~= 0 then
			if open_errors(id, st.lint, is_acked) > 0 then open = open + 1 else acked = acked + 1 end
		end
	end
	return open, acked
end

--- Rescans every snapshot station into a fresh per-player query cache.
local function rebuild_query(player_data, snapshot, f, fsig, column, epoch, pos)
	local stations = snapshot.stations
	local key_fn = sort_keys[column]
	local status, keys, flags, nat = {}, {}, {}, {}
	local counts = { all = 0, unserved = 0, problems = 0, failing = 0 }
	for _, s in ipairs(STATUSES) do counts[s] = 0 end
	local ctx = { status = status }
	local station_flags, passes = logic.station_flags, util.station_passes
	local all, unserved, setup, failing = 0, 0, 0, 0
	for id, st in pairs(stations) do
		if passes(st, f) then
			local s = st.status or "ok"
			status[id] = s
			counts[s] = counts[s] + 1
			all = all + 1
			local fl = station_flags(st)
			-- Records without a chip flag keep no entry (most stations on a large base).
			if fl ~= 0 then
				flags[id] = fl
				if band(fl, FLAG_UNSERVED) ~= 0 then unserved = unserved + 1 end
				if band(fl, FLAG_SETUP) ~= 0 then setup = setup + 1 end
				if band(fl, FAILING) ~= 0 then failing = failing + 1 end
			end
			keys[id] = key_fn(st, ctx)
			nat[id] = natural(st.name_lower)
		end
	end
	counts.all, counts.unserved, counts.problems, counts.failing = all, unserved, setup, failing
	local cache = {
		epoch = epoch, pos = pos, fsig = fsig, column = column,
		status = status, keys = keys, flags = flags, nat = nat, counts = counts, dirty = true, changed = {},
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
		local old_flags = flags[id] or 0
		local new_flags = new and logic.station_flags(st) or 0
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
			count_flags(counts, old_flags, -1)
			count_flags(counts, new_flags, 1)
			flags[id] = new_flags ~= 0 and new_flags or nil
			cache.version = (cache.version or 0) + 1
		end
		local key = new and key_fn(st, ctx) or nil
		local name_key = new and natural(st.name_lower) or nil
		if cache.nat[id] ~= name_key then
			cache.nat[id] = name_key
			cache.dirty = true
			changed[id] = true
		end
		if keys[id] ~= key then
			keys[id] = key
			cache.dirty = true
			changed[id] = true
		end
	end
end

--- The display order as a comparator over station ids: key in the requested direction with nil last, then the
--- natural name key and id ascending (the order util.sort_by gives, without its per-row tables: 2,030 of them per sort
--- on pY 123).
--- @param keys {[uint]: any}
--- @param nat {[uint]: string} natural name keys
--- @param ascending boolean
--- @return fun(a: uint, b: uint): boolean
local function order_less(keys, nat, ascending)
	return function(a, b)
		local ka, kb = keys[a], keys[b]
		if ka ~= kb then
			if ka == nil then return false end
			if kb == nil then return true end
			if ascending then return ka < kb end
			return ka > kb
		end
		local na, nb = nat[a], nat[b]
		if na ~= nb then return na < nb end
		return a < b
	end
end

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
	local less = order_less(keys, cache.nat, ascending)
	table.sort(moved, less)
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
	local problems = wanted == "problems"
	-- The Overview's Misconfigured jump narrows the Problems view to the stations its line counts (p1's contract).
	if not problems then player_data.stations_problems_scope = nil end
	local errors_only = problems and player_data.stations_problems_scope == "errors"
	if problems ~= (player_data.stations_problems_view == true) then
		-- The Problems view opens worst first; leaving it drops its sort.
		player_data.stations_problems_view = problems or nil
		local current = util.get_sort(player_data, TAB, "name")
		if problems then
			util.set_sort(player_data, TAB, "problems", true)
		elseif current == "problems" then
			util.set_sort(player_data, TAB, "name", true)
		end
	end
	local column, ascending = util.get_sort(player_data, TAB, "name")
	column = view_column(column, problems)
	if not sort_keys[column] then column = "name" end
	-- The first pass after opening is still filling records: rows and counts from part of the stations would change
	-- on every update and disagree with the other tabs, so there are none until it completes.
	local cache = player_data.stations_query
	-- The first build after a boosted pass is split over the next three updates, so no tick carries more than one of
	-- the pass's last batch, classifying every station, sorting them (together 6.4-6.6 ms on pY 123 with the chip
	-- flags) or writing every row of the page (3.8-4.4 ms): the completing update shows the placeholder still, the
	-- next one classifies, the one after sorts, both still showing the placeholder, and the next renders the rows.
	if not snapshot.tick or (not cache and snapshot.boosted and snapshot.tick == game.tick) then
		return {}, {}, { status = {}, flags = {}, stuck = {}, now = game.tick, snapshot = snapshot, pending = true }, column, ascending
	end
	local first_build = not cache and snapshot.boosted

	local fsig = filter_sig(f)
	local epoch, pos = collector.log_position()
	local ids, first, last
	if cache and cache.fsig == fsig and cache.column == column and cache.flags and cache.nat then
		ids, first, last = collector.changed_since(cache.epoch, cache.pos)
	end
	local av = column == "problems" and lint_ack_version() or nil
	if ids then
		apply_changes(cache, snapshot, f, ids, first, last)
		cache.pos = pos
	else
		cache = rebuild_query(player_data, snapshot, f, fsig, column, epoch, pos)
		cache.av = av
	end
	if av and cache.av ~= av then
		refresh_problem_keys(cache, stations)
		cache.av = av
	end
	if first_build then
		cache.defer_sort = true
		return {}, {}, { status = {}, flags = {}, stuck = {}, now = game.tick, snapshot = snapshot, pending = true }, column, ascending
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
	if resort or cache.sort_now or (cache.dirty and cache.sorted_tick ~= snapshot.tick and snapshot.tick ~= game.tick) then
		cache.sort_now = nil
		local order = not resort and merge_changes(cache, stations, ascending) or nil
		cache.sort_kind = order and "merged" or "full"
		if not order then
			order = {}
			for id in pairs(status) do order[#order + 1] = id end
			table.sort(order, order_less(cache.keys, cache.nat, ascending))
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
	if errors_only then
		local ls = storage.manager.lint
		want_sig = want_sig .. "\2" .. lint_ack_version() .. ":" .. (ls and ls.pass or 0)
	end
	if not rows or cache.rows_order ~= cache.order or cache.rows_wanted ~= want_sig or cache.rows_version ~= cache.version then
		rows = {}
		local open_errors = util.open_setup_errors
		for _, id in ipairs(cache.order) do
			if status[id] and chip_passes(wanted, id, cache, stuck)
				and (not errors_only or open_errors(id, stations[id].lint) > 0) then
				rows[#rows + 1] = stations[id]
			end
		end
		cache.rows, cache.rows_order, cache.rows_wanted, cache.rows_version = rows, cache.order, want_sig, cache.version
	end
	if cache.defer_sort then
		cache.defer_sort = nil
		return {}, {}, { status = {}, flags = {}, stuck = {}, now = game.tick, snapshot = snapshot, pending = true }, column, ascending
	end
	return rows, cache.counts, ctx, column, ascending
end

-- ---------------------------------------------------------------- rows

local NONE_CAPTION = { "cybersyn-gui.none-short" }
local NEVER_CAPTION = { "cybersyn-gui.never" }
-- Findings a Problems cell's tooltip spells out; the rest are counted.
local TOOLTIP_FINDINGS = 6
local HOUR = 216000
local DAY = 24 * HOUR
-- Subjects that have a row of their own elsewhere (stations here, the rest on Trains); every other subject is a stop
-- or combinator the registry reports, listed after the stations.
local NOT_REGISTRY = {
	[LINT_SUBJECT_STATION] = true,
	[LINT_SUBJECT_DEPOT] = true,
	[LINT_SUBJECT_REFUELER] = true,
	[LINT_SUBJECT_TRAIN] = true,
}

-- ---------------------------------------------------------------- problems

--- @class StationsProblems
--- @field src LintFinding[] lint.findings() it was built from
--- @field av int storage.acks.lint_version it was built at
--- @field expiry uint? the earliest end of an acknowledgement it shows
--- @field by_id {[uint]: ProblemEntry[]} a station's findings in the order its cell shows them
--- @field registry ProblemEntry[] findings about stops and combinators that are not a station

--- The last lint pass's findings by station, and the registry's, rebuilt only when the pass, the registry or an
--- acknowledgement changed (or one of the acknowledgements shown ran out).
--- @param cache table the player's stations query cache
--- @return StationsProblems
local function problem_index(cache)
	local findings = lint.findings()
	local acks = storage.acks
	local av = acks and acks.lint_version or 0
	local px = cache.problems
	if px and px.src == findings and px.av == av and not (px.expiry and game.tick >= px.expiry) then
		return px
	end
	local by_station, registry = {}, {}
	local function add(f)
		if f.subject == LINT_SUBJECT_STATION then
			local list = by_station[f.id]
			if not list then
				list = {}
				by_station[f.id] = list
			end
			list[#list + 1] = f
		elseif not NOT_REGISTRY[f.subject] then
			registry[#registry + 1] = f
		end
	end
	for _, f in ipairs(findings) do add(f) end
	local expiry
	local function is_acked(f)
		local a = diag.is_acked("lint", lint.subject_key(f.subject, f.id), f.check)
		if a and a.until_tick and (not expiry or a.until_tick < expiry) then expiry = a.until_tick end
		return a
	end
	local by_id = {}
	for id, list in pairs(by_station) do by_id[id] = pm.order(list, is_acked) end
	px = { src = findings, av = av, by_id = by_id, registry = pm.order(registry, is_acked) }
	px.expiry = expiry
	cache.problems = px
	return px
end

--- Progress of the first lint pass in percent while there is no result yet, nil once there is one.
--- @return int?
local function lint_pending()
	local s = storage.manager.lint
	if s and (s.pass or 0) > 0 then return nil end
	local job = s and s.job
	if not job then return 0 end
	local n = #(job.sids or {}) + #(job.dids or {}) + #(job.fids or {}) + #(job.tids or {})
	local done = (job.i or 0) + (job.ti or 0)
	return math.floor(100 * done / math.max(n, 1))
end

--- @param a DiagAck
--- @param now uint
--- @return LocalisedString
local function acked_line(a, now)
	local who = a.player_index and game.get_player(a.player_index)
	local until_text = a.until_tick and util.format_duration(a.until_tick - now) or nil
	return { "cybersyn-gui.unserved-ack-tooltip-acked", who and who.name or "-",
		until_text and { "cybersyn-gui.unserved-ack-for", until_text } or { "cybersyn-gui.problems-ack-until-clear" } }
end

--- Caption, severity, predicted reason, fix line and numbers of each finding, worst first.
--- @param entries ProblemEntry[]
--- @param snapshot Snapshot
--- @param now uint
--- @return LocalisedString
local function problems_tooltip(entries, snapshot, now)
	local out = { "" }
	for i = 1, math.min(#entries, TOOLTIP_FINDINGS) do
		local e = entries[i]
		local f = e.f
		local t = lint_text.texts(f.check, lint_text.role_of(f, snapshot))
		local part = { "", "[img=" .. (e.ack and pm.ACKED_DOT or pm.DOT[e.sev]) .. "] ", t.tooltip, "\n",
			pm.detail(f, lint_text.ENV) }
		if e.ack then
			part[#part + 1] = "\n"
			part[#part + 1] = acked_line(e.ack, now)
		end
		if i > 1 then out[#out + 1] = "\n\n" end
		out[#out + 1] = part
	end
	if #entries > TOOLTIP_FINDINGS then
		out[#out + 1] = "\n\n"
		out[#out + 1] = { "cybersyn-gui.stations-problems-more", tostring(#entries - TOOLTIP_FINDINGS) }
	end
	return out
end

--- What a Problems cell shows: the first finding spelled out, "+n" for the others, all of them in the tooltip, and an
--- acknowledge button for the row (tags: `sid` = station id, or `rk`/`ck` = subject key and check of a registry row).
--- @param entries ProblemEntry[]?
--- @param tags table
--- @param ctx table
--- @return table
local function problems_view(entries, tags, ctx)
	local n = entries and #entries or 0
	local p = { n = n, tags = tags }
	if n == 0 then
		p.sig = "0"
		return p
	end
	local parts = { tostring(n), tostring(tags.sid or ((tags.rk or "") .. ":" .. (tags.ck or ""))) }
	local open = 0
	for _, e in ipairs(entries) do
		local a = e.ack
		if not a then open = open + 1 end
		parts[#parts + 1] = e.f.check .. ":" .. pm.detail_sig(e.f)
			.. (a and (":" .. tostring(a.until_tick) .. "/" .. tostring(a.player_index)) or "")
	end
	p.sig = table.concat(parts, "|")
	p.all_acked = open == 0
	p.write = function(r)
		local first = entries[1]
		local f = first.f
		local acked = first.ack ~= nil
		r.dot.sprite = acked and pm.ACKED_DOT or pm.DOT[first.sev]
		r.dot.visible = true
		local style = acked and "cybersyn_chip_acked" or pm.CHIP_STYLE[first.sev]
		local chip = r.chip
		if chip.style.name ~= style then
			chip.style = style
			-- The check stays readable; the detail squashes instead (assigning a style drops this).
			chip.style.horizontally_squashable = false
		end
		chip.caption = pm.chip(f.check)
		chip.visible = true
		r.detail.caption = pm.detail(f, lint_text.ENV)
		local detail_style = acked and "cybersyn_lint_detail_acked" or "cybersyn_lint_detail"
		if r.detail.style.name ~= detail_style then r.detail.style = detail_style end
		r.more.caption = n > 1 and ("+" .. (n - 1)) or ""
		r.more.visible = n > 1
		r.cell.tooltip = problems_tooltip(entries, ctx.snapshot, ctx.now)
		local ack = r.ack
		ack.visible = true
		-- Merged into the element's tags: they also carry flib's handler name.
		local t = ack.tags
		t.sid, t.rk, t.ck = tags.sid, tags.rk, tags.ck
		ack.tags = t
		if ack.toggled ~= p.all_acked then ack.toggled = p.all_acked end
		ack.tooltip = p.all_acked and acked_line(first.ack, ctx.now) or { "cybersyn-gui.problems-ack-tooltip" }
	end
	return p
end

--- @param r table problems cell refs
local function clear_problems(r)
	r.dot.visible = false
	r.chip.visible = false
	r.detail.caption = ""
	r.more.visible = false
	r.ack.visible = false
	r.cell.tooltip = ""
end

-- Name parts of stops the snapshot does not hold: a pure function of the name, so a cache that differs between Lua
-- states cannot desync anything.
local parsed_cache = {}

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

--- The stop or combinator a registry finding is about, while it exists.
--- @param f LintFinding
--- @return LuaEntity?
local function entity_of(f)
	local e = f.entity
	if e and e.valid then return e end
	if lint.world_entity then
		e = lint.world_entity(f.id)
		if e and e.valid then return e end
	end
	return nil
end

--- The registry findings the filters let through: they belong to no network and carry no item, so a network, network
--- ID or item filter hides them; the surface filter and the name search apply.
--- @param px StationsProblems
--- @param f ManagerFilters
--- @return {e: ProblemEntry, entity: LuaEntity?, name: string}[]
local function registry_rows(px, f)
	local out = {}
	if #px.registry == 0 or f.network or f.item or (f.mask and f.mask ~= -1) then return out end
	for _, e in ipairs(px.registry) do
		local gone = e.f.entity
		-- A world-scan finding whose entity was removed since: no row (the scan is not repeated to prune it).
		if gone and not gone.valid then goto continue end
		local entity = entity_of(e.f)
		local name
		if entity then
			if entity.type == "train-stop" then
				name = entity.backer_name
			else
				local pos = entity.position
				name = "[item=" .. COMBINATOR_NAME .. "] " .. math.floor(pos.x) .. ", " .. math.floor(pos.y)
			end
		else
			name = "#" .. e.f.id
		end
		-- Without its entity a row cannot tell its surface: a surface filter hides it.
		local pass = not (f.surface and (not entity or entity.surface_index ~= f.surface))
		if pass and f.terms then pass = util.terms_match(helpers.multilingual_to_lower(name), f.terms) end
		if pass then out[#out + 1] = { e = e, entity = entity, name = name } end
		::continue::
	end
	return out
end

--- @param f LintFinding
--- @return string
local function registry_key(f)
	return "r" .. f.check .. ":" .. f.subject .. ":" .. f.id .. ":" .. tostring(f.message or f.item or "")
end

--- A registry row in the shape of a station row (rows are reused across both): the stop's name or the combinator's
--- position linked to the entity, "Train stop" or "Combinator" in the Status column, the finding in the Problems
--- column, the other cells empty.
--- @param row {e: ProblemEntry, entity: LuaEntity?, name: string}
--- @param ctx table
--- @return table
local function registry_model(row, ctx)
	local f = row.e.f
	local kind = "entity"
	if f.subject == LINT_SUBJECT_STOP then
		kind = storage.stations[f.id] and "station" or storage.depots[f.id] and "depot"
			or storage.refuelers[f.id] and "refueler" or "entity"
	end
	local subject = LINT_SUBJECT_NAMES[f.subject] or "stop"
	local m = {
		registry = true,
		key = registry_key(f),
		name = row.name,
		parts = parse_name(row.name),
		link = { kind = kind, id = f.id },
		status_sig = "registry:" .. subject,
		status_sprite = "flib_indicator_white",
		status_caption = { "cybersyn-gui.stations-registry-" .. subject },
		status_tip_sig = "registry",
		net_sig = "-",
		dl_caption = "",
		dl_sig = "-",
		wait_caption = "",
		wait_sig = "-",
		last_caption = "",
		last_sig = "-",
	}
	m.name_sig = row.name .. "\1" .. kind .. f.id
	m.name_tooltip = function()
		return { "", "[font=default-semibold]", row.name, "[/font]\n", { "cybersyn-gui.stations-registry-tooltip" }, "\n",
			util.LINK_FOOTER }
	end
	m.status_tooltip = function() return { "cybersyn-gui.stations-registry-tooltip" } end
	m.network = function() return "", "", "" end
	m.problems = problems_view({ row.e }, { rk = lint.subject_key(f.subject, f.id), ck = f.check }, ctx)
	return m
end

--- Everything a row shows that is not a slot table, as plain values comparable between updates. Tooltips and the
--- network cell cost API calls, so they are built by functions that run only when their sig changed.
--- @param st SnapshotStation
--- @param ctx table
local function row_model(st, ctx)
	local now = ctx.now
	local status = ctx.status[st.id]
	local m = {
		key = st.id,
		name = st.name,
		parts = st.name_parts,
		link = { kind = "station", id = st.id },
		status_sig = status,
		status_sprite = "flib_indicator_" .. STATUS_COLOR[status],
		status_caption = { status_key(status) },
	}
	if ctx.problems_view then
		m.problems = problems_view(ctx.lint.by_id[st.id], { sid = st.id }, ctx)
	end

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
	if age and never_dispatched(st) then
		m.last_caption, m.last_sig, m.last_never = NEVER_CAPTION, "never", true
	elseif age then
		m.last_caption = util.short_duration(age)
		m.last_sig = m.last_caption
	else
		m.last_caption, m.last_sig = NONE_CAPTION, ""
	end
	m.last_full = age and util.format_duration(age) or nil
	return m
end

local function wait_tooltip(m)
	if m.registry then return "" end
	return m.wait_full and { "cybersyn-gui.waiting-for", m.wait_full } or { "cybersyn-gui.stations-wait-none" }
end

local function last_tooltip(m)
	if m.last_never then return { "cybersyn-gui.stations-last-dispatch-never" } end
	if m.registry then return "" end
	return m.last_full and { "cybersyn-gui.time-ago", m.last_full } or { "cybersyn-gui.never" }
end

--- Slot buttons of the 32 px rows: clickable items with the standard item click semantics and hover-hold, the
--- filtered item highlighted rather than hidden.
local function decorate_slots(defs, item)
	for _, def in pairs(defs) do
		local tags = def.tags
		local hash = tags and tags.kind == "item" and tags.id or nil
		if hash then
			def.enabled = true
			def.mouse_button_filter = { "left", "right" }
			-- The one item click of every view (util.handle_link_click -> util.item_button_click).
			def.handler = { [defines.events.on_gui_click] = util.handle.link_click }
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
	return def.tags and def.tags.kind == "item" and def.tags.id or def.sprite
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

-- A registry row (no station) has empty slot tables.
local SLOT_TABLES = {
	pr = function(st, item, w)
		if not st then return {} end
		return fit_slots(decorate_slots(util.slot_table_build_from_station(st), item), w.pr_slots)
	end,
	dl = function(st, item, w)
		if not st then return {} end
		return fit_slots(decorate_slots(util.slot_table_build_from_deliveries(st), item), w.dl_slots)
	end,
}
local NO_SLOTS = { pr = "", dl = "" }

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
--- @param problems boolean the row was built for the Problems view
local function row_refs(row, problems)
	local c = row.children
	local status = c[2].children
	local net = c[3].children
	local dl = c[5].children
	local refs = {
		name = c[1],
		status_sprite = status[1],
		status_label = status[2],
		net = c[3],
		net_sprite = net[1],
		net_label = net[2],
		dl_count = dl[1],
		dl = dl[2],
		wait = c[6],
		last = c[7],
	}
	if problems then
		local p = c[PROBLEMS_COLUMN]
		local pc = p.children
		refs.problems = { cell = p, dot = pc[1], chip = pc[2], detail = pc[3], more = pc[4], ack = pc[6] }
	else
		refs.pr = c[PROBLEMS_COLUMN].children[1]
	end
	return refs
end

--- @param cell table
--- @param row LuaGuiElement
--- @param problems boolean
local function cell_refs(cell, row, problems)
	local refs = cell.refs
	if not (refs and refs.name.valid and refs.last.valid and (refs.problems ~= nil) == problems) then
		refs = row_refs(row, problems)
		cell.refs = refs
	end
	return refs
end

--- @param r table refs.problems
--- @param p table? problems_view
--- @param cell table
local function update_problems(r, p, cell)
	local sig = p and p.sig or "0"
	if cell.problems_sig == sig then return end
	if p and p.write then p.write(r) else clear_problems(r) end
	cell.problems_sig = sig
end

--- @param row LuaGuiElement
--- @param st SnapshotStation? nil for a registry row
--- @param m table row model
--- @param cell table per-row render memo from the previous update (empty on first sight)
--- @param item string? item filter hash
--- @param hold boolean
--- @param minute integer
--- @param sigs {pr: string, dl: string}
--- @param w table column widths
local function update_row(row, st, m, cell, item, hold, minute, sigs, w)
	local r = cell_refs(cell, row, w.problems_view)
	if cell.name_sig ~= m.name_sig then
		name_cell.update(r.name, m.parts, m.name, m.link, w.name, m.name_tooltip(), SCROLL)
		cell.name_sig = m.name_sig
	end

	if cell.status ~= m.status_sig then
		r.status_sprite.sprite = m.status_sprite
		r.status_label.caption = m.status_caption
		cell.status = m.status_sig
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
		r.dl_count.tooltip = m.registry and "" or { "cybersyn-gui.stations-deliveries-count-tooltip" }
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
	local wait_tip, last_tip = m.wait_full or m.wait_sig, (m.last_full or m.last_sig)
	if cell.wait_tip ~= wait_tip then
		r.wait.tooltip = wait_tooltip(m)
		cell.wait_tip = wait_tip
	end
	if cell.last_tip ~= last_tip then
		r.last.tooltip = last_tooltip(m)
		cell.last_tip = last_tip
	end
	if r.problems then update_problems(r.problems, m.problems, cell) end

	local slots = cell.slots or {}
	cell.slots = slots
	local sig_of = cell.slot_sigs or {}
	cell.slot_sigs = sig_of
	for name, build in pairs(SLOT_TABLES) do
		local table_elem = r[name]
		local sig = sigs[name]
		if table_elem and sig_of[name] ~= sig then
			local result = sync_slots(table_elem, build(st, item, w), slot_state(slots, name), hold, minute)
			-- A hold deferred a structural change, so the table is retried next update.
			sig_of[name] = result ~= "held" and sig or nil
		end
	end
end

--- The Problems column's cell: written by update_problems, so a new row starts empty.
--- @param w table
--- @return flib.GuiElemDef
local function problems_cell_def(w)
	return {
		type = "flow",
		style = "cybersyn_cell_flow",
		style_mods = { width = w.problems, horizontal_spacing = 6 },
		{ type = "sprite", style = "cybersyn_lint_dot", sprite = "flib_indicator_white", visible = false, ignored_by_interaction = true },
		-- A chip that shows the check, not a button: no hover glow, the cell carries the tooltip.
		{ type = "button", style = "cybersyn_chip_grey", caption = "", visible = false, ignored_by_interaction = true,
			style_mods = { horizontally_squashable = false } },
		{ type = "label", style = "cybersyn_lint_detail", caption = "", ignored_by_interaction = true },
		{ type = "label", style = "cybersyn_overflow_label", caption = "", visible = false, ignored_by_interaction = true },
		{ type = "empty-widget", style = "flib_horizontal_pusher", ignored_by_interaction = true },
		{
			type = "sprite-button",
			style = "cybersyn_unserved_ack",
			sprite = "utility/check_mark",
			visible = false,
			tags = {},
			handler = { [defines.events.on_gui_click] = stations_tab.handle.on_lint_ack_click },
		},
	}
end

--- @param st SnapshotStation? nil for a registry row
--- @param m table row model
--- @param color "light"|"dark"
--- @param item string?
--- @param w table column widths
local function row_def(st, m, color, item, w)
	local defs = { pr = w.problems_view and {} or SLOT_TABLES.pr(st, item, w), dl = SLOT_TABLES.dl(st, item, w) }
	local net_sprite, net_caption, net_tooltip = m.network()
	local fourth
	if w.problems_view then
		fourth = problems_cell_def(w)
	else
		fourth = {
			type = "flow",
			style = "cybersyn_cell_flow",
			style_mods = { width = w.provided_requested },
			{ type = "table", style = "slot_table", column_count = w.pr_slots, children = defs.pr },
		}
	end
	return util.hoverable({
		type = "frame",
		style = "cybersyn_station_row_" .. color,
		style_mods = { height = ROW_HEIGHT },
		direction = "horizontal",
		tags = { station_id = st and st.id or nil, registry = m.registry and m.key or nil },
		name_cell.def(m.parts, m.name, m.link, w.name, m.name_tooltip(), SCROLL),
		{
			type = "flow",
			style = "cybersyn_cell_flow",
			style_mods = { width = w.station_status },
			{ type = "sprite", style = "flib_indicator", sprite = m.status_sprite },
			{ type = "label", style = "cybersyn_cell_label", caption = m.status_caption, tooltip = m.status_tooltip() },
		},
		{
			type = "flow",
			style = "cybersyn_cell_flow",
			style_mods = { width = w.network },
			tooltip = net_tooltip,
			{ type = "sprite", sprite = net_sprite, resize_to_sprite = false, style_mods = { size = 24 }, ignored_by_interaction = true },
			{ type = "label", caption = net_caption, ignored_by_interaction = true },
		},
		fourth,
		{
			type = "flow",
			style = "cybersyn_cell_flow",
			style_mods = { width = w.deliveries },
			{
				type = "label",
				style = "cybersyn_cell_value",
				style_mods = { width = w.dl_count },
				caption = m.dl_caption,
				tooltip = m.registry and "" or { "cybersyn-gui.stations-deliveries-count-tooltip" },
			},
			{ type = "table", style = "slot_table", column_count = w.dl_slots, children = defs.dl },
		},
		{ type = "label", style = "cybersyn_cell_value", style_mods = { width = w.wait }, caption = m.wait_caption,
			tooltip = wait_tooltip(m), visible = not w.hide_wait },
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
--- @param count integer? nil while the first pass after opening (or the first lint pass) runs
local function chip_caption(key, count)
	local number = count and format.number(count) or "–"
	if key == "all" then
		return { "", { "cybersyn-gui.station-status-all" }, "  ", number }
	end
	local name = STATUS_COLOR[key] and { status_key(key) } or { "cybersyn-gui.stations-chip-" .. key }
	return { "", "[img=" .. chip_icon(key) .. "] ", name, "  ", number }
end

--- @param key string
--- @param pending int? the first lint pass's progress while it runs
--- @return LocalisedString?
local function chip_tooltip(key, pending)
	if key == "all" then return nil end
	if STATUS_COLOR[key] then return { "", "[font=default-semibold]", { status_key(key) }, "[/font]\n", { status_key(key) .. "-tooltip" } } end
	local tip = { "", "[font=default-semibold]", { "cybersyn-gui.stations-chip-" .. key }, "[/font]\n", { "cybersyn-gui.stations-chip-" .. key .. "-tooltip" } }
	if key == "problems" and pending then
		tip[#tip + 1] = "\n"
		tip[#tip + 1] = { "cybersyn-gui.problems-pending-progress", tostring(pending) }
	end
	return tip
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

--- @param key string
--- @param count int?
--- @return int
local function chip_width(key, count)
	return CHIP_WIDTH[key] + 4 + DIGIT_WIDTH * (#format.number(count or 0) - 1)
end

--- Which chips show, and on which line (PLAN4 D15 item 13): a chip with nothing to show is hidden (All and the
--- toggled chip always show, `always` too); the chips take the subheader's line while they fit beside what else it
--- shows and continue on a second line below it, in order and never abbreviated; what does not fit there either is
--- dropped.
--- @param counts {[string]: int}
--- @param selected string the toggled chip or "all"
--- @param space1 int px left in the subheader
--- @param space2 int px of the second line
--- @param always {[string]: true}?
--- @return string[] line1
--- @return string[] line2
function stations_tab.chip_lines(counts, selected, space1, space2, always)
	local line1, line2 = {}, {}
	local used1, used2 = 0, 0
	local second = false
	for _, key in ipairs(CHIP_ORDER) do
		local count = counts[key]
		if key == "all" or key == selected or (always and always[key]) or (count and count > 0) then
			local w = chip_width(key, count)
			if not second and used1 + w <= space1 then
				line1[#line1 + 1] = key
				used1 = used1 + w
			else
				second = true
				if used2 + w <= space2 or key == selected then
					line2[#line2 + 1] = key
					used2 = used2 + w
				end
			end
		end
	end
	return line1, line2
end

--- @param flow LuaGuiElement
--- @param keys string[]
--- @param counts {[string]: int}
--- @param wanted string
--- @param state table
--- @param pending int?
local function sync_chip_line(flow, keys, counts, wanted, state, pending)
	local entries = {}
	for i, key in ipairs(keys) do
		local count = counts[key]
		local waiting = key == "problems" and pending or nil
		if waiting then count = nil end
		local selected = wanted == key
		local enabled = selected or (count ~= nil and count > 0)
		entries[i] = {
			key = key,
			sig = tostring(count) .. (selected and "+" or "-") .. tostring(waiting),
			build = function()
				return {
					type = "button",
					style = "cybersyn_filter_chip",
					caption = chip_caption(key, count),
					tooltip = chip_tooltip(key, waiting),
					toggled = selected,
					enabled = enabled,
					tags = { station_chip = key },
					handler = { [defines.events.on_gui_click] = stations_tab.handle.on_status_chip_click },
				}
			end,
			update = function(elem)
				elem.caption = chip_caption(key, count)
				elem.tooltip = chip_tooltip(key, waiting)
				elem.toggled = selected
				elem.enabled = enabled
			end,
		}
	end
	util.sync_children(flow, entries, state, false)
end

--- Chips: counts over the filtered set, click to show only that set, click again for all.
--- @return boolean wrapped the second line shows (the page has one row less)
local function render_chips(player_data, counts)
	local flow = chip_flow(player_data)
	if not flow then return false end
	local refs = player_data.refs
	local wanted = active_chip(player_data) or "all"
	local pending = lint_pending()
	local layout = player_data.layout
	local cw = layout and layout.content_width or (sizing.MAX_WIDTH - sizing.OUTER_WIDTH)
	local line1, line2 = stations_tab.chip_lines(counts, wanted, stations_tab.chip_space(player_data, TAB), cw - 24,
		pending and { problems = true } or nil)
	sync_chip_line(flow, line1, counts, wanted, util.gui_state(player_data, CHIPS), pending)
	local row, flow2 = refs[CHIP_ROW], refs[CHIPS2]
	if not (row and row.valid and flow2 and flow2.valid) then return false end
	local wrapped = #line2 > 0
	if row.visible ~= wrapped then row.visible = wrapped end
	-- Written into the element so measured_rows can read it (a style prototype's height reads back as nothing).
	if row.style.maximal_height ~= ROW_HEIGHT then row.style.height = ROW_HEIGHT end
	sync_chip_line(flow2, line2, counts, wanted, util.gui_state(player_data, CHIPS2), pending)
	return wrapped
end

-- ---------------------------------------------------------------- render

--- Writes the column widths, the fourth column's caption and the Wait column's visibility into the header, and the sort
--- state into its checkboxes, when either changed.
--- @param player_data PlayerData
--- @param w table
--- @return boolean widths_changed
local function sync_header(player_data, w, column, ascending)
	local header = player_data.refs[HEADER]
	if not (header and header.valid) then return false end
	local state = util.gui_state(player_data, HEADER)
	-- A rebuilt window has a new header built with the default widths.
	if state.index ~= header.index then
		state.cw, state.sort, state.index = nil, nil, header.index
	end
	local changed = state.cw ~= w.sig
	if changed then
		local columns = w.problems_view and PROBLEM_COLUMNS or COLUMNS
		local cells = header.children
		for i, cell in ipairs(cells) do
			cell.style.width = w[columns[i]]
			cell.visible = not (i == WAIT_COLUMN and w.hide_wait)
		end
		local box = cells[PROBLEMS_COLUMN].children[1]
		local tags = box.tags
		if tags.column ~= columns[PROBLEMS_COLUMN] then
			box.caption, box.tooltip = header_texts(columns[PROBLEMS_COLUMN])
			tags.column = columns[PROBLEMS_COLUMN]
			box.tags = tags
		end
		state.cw = w.sig
	end
	local sig = column .. (ascending and "+" or "-")
	if changed or state.sort ~= sig then
		for _, cell in ipairs(header.children) do util.sync_sort_header(cell, column, ascending) end
		state.sort = sig
	end
	return changed
end

--- The rows of the view: the stations, then (in the Problems view) the registry's findings.
--- @param player_data PlayerData
--- @param rows SnapshotStation[]
--- @param ctx table
--- @return {e: ProblemEntry, entity: LuaEntity?, name: string}[]
local function view_registry(player_data, rows, ctx)
	ctx.problems_view = active_chip(player_data) == "problems"
	if not ctx.problems_view or ctx.pending then return {} end
	local cache = player_data.stations_query
	if not cache then return {} end
	ctx.lint = problem_index(cache)
	-- The Misconfigured jump's scope counts stations only.
	if player_data.stations_problems_scope == "errors" then return {} end
	return registry_rows(ctx.lint, util.get_filters(player_data))
end

--- @param map_data MapData
--- @param player_data PlayerData
function stations_tab.build(map_data, player_data)
	local refs = player_data.refs
	local list = refs[SCROLL]
	if not (list and list.valid) then return end

	local rows, counts, ctx, column, ascending = stations_tab.query(player_data)
	stations_tab.fix_heights(refs, { TAB .. "_banner", TAB .. "_subheader", HEADER, "manager_stations_subfooter" })
	local registry = view_registry(player_data, rows, ctx)
	local problems = ctx.problems_view
	local state = util.gui_state(player_data, SCROLL)
	local wrapped = render_chips(player_data, counts)
	local size = math.max(1, util.page_size(player_data, TAB) - (wrapped and 1 or 0))
	local n_rows = #rows
	local first, last = util.paginate(player_data, TAB, n_rows + #registry, size)
	-- A column the page leaves empty gives its width to the name (PLAN4 D15 item 14), unless it carries the sort.
	local hide_wait = not ctx.pending and column ~= "wait"
	for i = first, math.min(last, n_rows) do
		if rows[i].longest_wait_start then
			hide_wait = false
			break
		end
	end
	local w = widths_for(player_data, problems, hide_wait)
	if sync_header(player_data, w, column, ascending) or state.cw ~= w.sig then
		-- Rows built for other widths are rebuilt rather than resized cell by cell.
		state.keys = nil
		state.cells = nil
		state.cw = w.sig
	end
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
		if summary and summary.valid then
			summary.caption = ""
			state.summary = nil
		end
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
		local st = i <= n_rows and rows[i] or nil
		local index = i - first + 1
		local m = st and row_model(st, ctx) or registry_model(registry[i - n_rows], ctx)
		local key = m.key
		local color = index % 2 == 0 and "dark" or "light"
		entries[index] = {
			key = key,
			build = function()
				local def, defs = row_def(st, m, color, item, w)
				local slots = {}
				for name, list_defs in pairs(defs) do
					local keys = {}
					for k, d in ipairs(list_defs) do keys[k] = slot_key(d) end
					slots[name] = { keys = keys }
				end
				cells[key] = {
					slots = slots, slot_sigs = st and slot_sigs(st, item, minute) or NO_SLOTS, name_sig = m.name_sig,
					status = m.status_sig, color = color, status_tip_sig = m.status_tip_sig, net_sig = m.net_sig,
					dl_sig = m.dl_sig, wait_sig = m.wait_sig, last_sig = m.last_sig, wait_tip = m.wait_full or m.wait_sig,
					last_tip = m.last_full or m.last_sig,
				}
				return def
			end,
			built = function(elem)
				local cell = cells[key]
				if cell then
					cell.refs = row_refs(elem, w.problems_view)
					if cell.refs.problems then update_problems(cell.refs.problems, m.problems, cell) end
				end
			end,
			-- A row that left the page becomes this one: its slot tables keep their buttons where the items match.
			reuse = function(elem, old_key)
				local old = old_cells[old_key]
				old_cells[key] = { slots = old and old.slots, color = old and old.color, refs = old and old.refs }
				local tags = elem.tags
				tags.station_id = st and st.id or nil
				tags.registry = m.registry and key or nil
				elem.tags = tags
			end,
			update = function(elem)
				local cell = old_cells[key] or {}
				if cell.color ~= color then
					-- Assigning a style drops style_mods: the fixed height is written again.
					elem.style = "cybersyn_station_row_" .. color
					elem.style.height = ROW_HEIGHT
					cell.color = color
				end
				update_row(elem, st, m, cell, item, hold, minute, st and slot_sigs(st, item, minute) or NO_SLOTS, w)
				cells[key] = cell
			end,
		}
	end
	-- The window's first render after a reopen rewrites every row (the memo went with the close): half of them now,
	-- the rest on the next update, so neither carries the whole page on a large base.
	if not state.cells and #entries > FIRST_UPDATE_ROWS then
		for i = FIRST_UPDATE_ROWS + 1, #entries do entries[i].update = nil end
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
		local open, acked
		if problems then open, acked = open_error_counts(player_data.stations_query) end
		local sig = counts.all .. "|" .. n_rows .. "|" .. #registry .. "|" .. summary.index .. "|" .. tostring(open)
			.. "|" .. tostring(acked)
		if state.summary ~= sig then
			local caption
			if #registry > 0 then
				caption = { "cybersyn-gui.stations-summary-registry", format.number(n_rows), format.number(counts.all),
					format.number(#registry) }
			else
				caption = { "cybersyn-gui.stations-summary", format.number(n_rows), format.number(counts.all) }
			end
			-- The Overview's Misconfigured number, under the same filters: the stations this view lists first.
			if open then
				caption = { "", caption, " · ", acked > 0
					and { "cybersyn-gui.stations-open-errors-acked", format.number(open), format.number(acked) }
					or { "cybersyn-gui.stations-open-errors", format.number(open) } }
				summary.tooltip = { "cybersyn-gui.stations-open-errors-tooltip" }
			else
				summary.tooltip = ""
			end
			summary.caption = caption
			state.summary = sig
			state.open_errors = open and { open, acked } or nil
		end
	end

	local empty = n_rows + #registry == 0
	list.visible = not empty
	local warning = refs.manager_stations_warning_flow
	if warning and warning.valid then
		warning.visible = empty
		if empty then
			local caption
			local pending = problems and lint_pending()
			local filtered = util.filters_active(util.get_filters(player_data))
			if pending then
				caption = { "cybersyn-gui.problems-pending-progress", tostring(pending) }
			elseif problems then
				caption = { filtered and "cybersyn-gui.stations-problems-none-filtered" or "cybersyn-gui.stations-problems-none" }
			elseif counts.all > 0 or filtered then
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
	-- Every shown row counts, not just those that fit: rows past the space (more rows than computed, or rows
	-- taller than their style says) make the result negative, so dev.rows reports over-rendering.
	local n, used = 0, 0
	for _, row in ipairs(list.children) do
		if row.visible then
			local style = row.style
			local h = style.maximal_height
			if not h or h <= 0 or style.minimal_height ~= h then return -1 end
			used = used + h
			n = n + 1
		end
	end
	if used > avail then return -n end
	return n
end

dev.register_rows(TAB, function(player_data)
	return stations_tab.measured_rows(player_data, "manager_stations_content_frame", SCROLL)
end)

--- @param cell LuaGuiElement a Problems cell
--- @return table?
local function problems_cell_view(cell)
	local pc = cell.children
	if #pc ~= 6 or pc[1].type ~= "sprite" then return nil end
	return {
		dot = pc[1].visible and pc[1].sprite or false,
		chip = pc[2].visible and pc[2].caption or false,
		chip_style = pc[2].style.name,
		detail = pc[3].caption,
		more = pc[4].visible and pc[4].caption or false,
		ack = pc[6].visible and pc[6].toggled == true,
		ack_tags = pc[6].tags,
		tooltip = cell.tooltip,
	}
end

dev.register_dump(TAB, function(player_data)
	local list = player_data.refs[SCROLL]
	local rows, counts, ctx, column, ascending = stations_tab.query(player_data)
	local key_fn = sort_keys[column]
	local ids, keys, statuses, names, problems, last, registry, status_children = {}, {}, {}, {}, {}, {}, {}, {}
	local stripes_ok = true
	local registry_last = true
	local by_id = ctx.snapshot.stations
	for i, row in ipairs(list.children) do
		local tags = row.tags
		local color = i % 2 == 0 and "dark" or "light"
		if row.style.name ~= "cybersyn_station_row_" .. color then stripes_ok = false end
		local cells = row.children
		local button = name_cell.button(cells[1])
		local prob = problems_cell_view(cells[PROBLEMS_COLUMN])
		local id = tags.station_id
		if id then
			local n = #ids + 1
			ids[n] = id
			local st = by_id[id]
			keys[n] = st and key_fn(st, ctx)
			statuses[n] = ctx.status[id]
			names[n] = button and button.caption
			problems[n] = prob or false
			last[n] = cells[7].caption
			status_children[n] = #cells[2].children
			if #registry > 0 then registry_last = false end
		else
			registry[#registry + 1] = {
				key = tags.registry,
				name = button and button.caption,
				link = button and { button.tags.kind, button.tags.id },
				status = cells[2].children[2].caption,
				problems = prob,
			}
		end
	end
	local chips, chip_counts, wrapped = {}, {}, {}
	local flow = player_data.refs[CHIPS]
	if flow and flow.valid then
		for i, chip in ipairs(flow.children) do
			chips[i] = { chip.tags.station_chip, chip.toggled, chip.enabled }
		end
	end
	local flow2 = player_data.refs[CHIPS2]
	if flow2 and flow2.valid and flow2.parent.visible then
		for _, chip in ipairs(flow2.children) do
			chips[#chips + 1] = { chip.tags.station_chip, chip.toggled, chip.enabled, 2 }
			wrapped[#wrapped + 1] = chip.tags.station_chip
		end
	end
	local status_counts = {}
	for k, v in pairs(counts) do
		if k == "all" or STATUS_RANK[k] then status_counts[k] = v else chip_counts[k] = v end
	end
	local header = player_data.refs[HEADER]
	local hidden = {}
	local header_columns = {}
	if header and header.valid then
		for i, cell in ipairs(header.children) do
			local column_name = cell.children[1].tags.column
			header_columns[i] = column_name
			if not cell.visible then hidden[#hidden + 1] = column_name end
		end
	end
	local chip_row = player_data.refs[CHIP_ROW]
	return {
		ids = ids,
		keys = keys,
		statuses = statuses,
		names = names,
		problems = problems,
		last = last,
		registry = registry,
		registry_last = registry_last,
		status_children = status_children,
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
		warning_caption = player_data.refs.manager_stations_warning_label.caption,
		chips = chips,
		wrapped = wrapped,
		chip_row = chip_row and chip_row.valid and chip_row.visible or false,
		header = header_columns,
		hidden = hidden,
		render = util.gui_state(player_data, SCROLL).result,
		sort_kind = player_data.stations_query and player_data.stations_query.sort_kind,
		stripes_ok = stripes_ok,
		widths = util.gui_state(player_data, HEADER).cw,
		summary = player_data.refs.manager_stations_summary.caption,
		open_errors = util.gui_state(player_data, SCROLL).open_errors,
	}
end)

--- @param e ProblemEntry
--- @return table
local function entry_view(e)
	local f = e.f
	return {
		check = LINT_NAMES[f.check], subject = LINT_SUBJECT_NAMES[f.subject], id = f.id, item = f.item,
		message = f.message, a = f.a, b = f.b, c = f.c, network = f.network, sev = e.sev, acked = e.ack ~= nil,
		detail = pm.detail(f, lint_text.ENV), fix = pm.fix(f.check), chip = pm.chip(f.check),
	}
end

--- The Problems view without filters, over all pages, built by the functions the tab renders with: the stations the
--- chip lets through (st.lint ~= 0) with their findings in cell order, the registry rows, and for comparison the raw
--- registry findings and the findings about depots, refuelers and trains (those render on the Trains tab) with their
--- texts. The lab compares it with lint_findings and with what the window shows.
--- @return table
local function lint_view()
	local snapshot = collector.get()
	local px = problem_index({})
	local out = { stations = {}, registry = {}, others = {}, raw_registry = {}, snapshot = snapshot.tick ~= nil }
	local ids = {}
	for id, st in pairs(snapshot.stations) do
		if (st.lint or 0) ~= 0 then ids[#ids + 1] = id end
	end
	table.sort(ids)
	for i, id in ipairs(ids) do
		local list = {}
		for k, e in ipairs(px.by_id[id] or {}) do list[k] = entry_view(e) end
		out.stations[i] = { id = id, lint = snapshot.stations[id].lint, entries = list }
	end
	for i, r in ipairs(registry_rows(px, { mask = -1 })) do
		out.registry[i] = { key = registry_key(r.e.f), name = r.name, entity = r.entity ~= nil, entry = entry_view(r.e) }
	end
	local function raw(list)
		for _, f in ipairs(list or {}) do
			local sev = LINT_SEVERITY[f.check] or DIAG_SEV_WARNING
			if f.subject ~= LINT_SUBJECT_STATION and NOT_REGISTRY[f.subject] then
				out.others[#out.others + 1] = entry_view({ f = f, sev = sev })
			elseif not NOT_REGISTRY[f.subject] and not (f.entity and not f.entity.valid) then
				out.raw_registry[#out.raw_registry + 1] = entry_view({ f = f, sev = sev })
			end
		end
	end
	raw(lint.findings())
	return out
end

dev.add("stations_lint_view", lint_view)

stations_tab.handle = {}

--- @param e {player_index: uint}
function stations_tab.wrapper(e, handler)
	local player = game.get_player(e.player_index)
	if not player then return end
	local player_data = storage.manager.players[e.player_index]
	handler(player, player_data, player_data.refs, e)
end

--- @param e EventData.on_gui_click
function stations_tab.handle.on_status_chip_click(player, player_data, refs, e)
	stations_tab.set_chip(player_data, e.element.tags.station_chip)
	util.rerender(player, player_data)
end

--- Acknowledge a row's findings: click = 24 h, shift = 1 h, control = until they clear; a click on a row whose
--- findings are all acknowledged ends them. Display state only, so any player may acknowledge (PLAN3 §4.13).
--- @param e EventData.on_gui_click
function stations_tab.handle.on_lint_ack_click(player, player_data, refs, e)
	local tags = e.element.tags
	local targets = {}
	if tags.sid then
		local cache = player_data.stations_query
		local px = cache and problem_index(cache)
		local seen = {}
		for _, en in ipairs(px and px.by_id[tags.sid] or {}) do
			local key = lint.subject_key(en.f.subject, en.f.id)
			local id = key .. ":" .. en.f.check
			if not seen[id] then
				seen[id] = true
				targets[#targets + 1] = { key, en.f.check, en.ack ~= nil }
			end
		end
	elseif tags.rk and tags.ck then
		targets[1] = { tags.rk, tags.ck, diag.is_acked("lint", tags.rk, tags.ck) ~= nil }
	end
	if #targets == 0 then return end
	local open = false
	for _, t in ipairs(targets) do
		if not t[3] then open = true end
	end
	if open then
		local until_tick
		if e.control then
			until_tick = nil
		elseif e.shift then
			until_tick = game.tick + HOUR
		else
			until_tick = game.tick + DAY
		end
		for _, t in ipairs(targets) do
			if not t[3] then diag.ack("lint", t[1], t[2], player.index, until_tick) end
		end
	else
		for _, t in ipairs(targets) do diag.unack("lint", t[1], t[2], player.index) end
	end
	-- The click is the change the player asked for: the row updates now, not once the cursor leaves.
	player_data.hover = nil
	util.rerender(player, player_data)
end

--- Toggles a chip: a status, "unserved", "problems", "stuck", "failing"; "all" or the active chip again clears it.
--- @param player_data PlayerData
--- @param chip string?
function stations_tab.set_chip(player_data, chip)
	if chip == "all" or chip == active_chip(player_data) then chip = nil end
	player_data.stations_status_filter = nil
	player_data.stations_chip = nil
	player_data.stations_problems_scope = nil
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
