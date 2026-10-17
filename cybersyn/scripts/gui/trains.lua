-- Trains tab (PLAN3 §4.7, PLAN4 D11): chips in the tab's subheader, one 36 px row per train (id link, status with the
-- stop as a link, network, composition icons, depot, state icon, time in state, last refuel, fuel, shipment), columns
-- whose value is the same for every listed train hidden, optionally grouped by depot name (group rows with their
-- compositions, a hover box with every composition and the trains by state, and a marker for setup findings).
-- Exactly as many rows as the window fits.
-- A row click selects the train and opens the detail pane right of the table (PLAN3 §4.11): a camera on the train and
-- the train panel of scripts/gui/relative.lua, mounted in the window.

local gui = require("__flib__.gui")
local format = require("__flib__.format")

local constants = require("constants")
local util = require("scripts.gui.util")
local templates = require("scripts.gui.templates")
local collector = require("scripts.gui.collector")
local dev = require("scripts.gui.dev")
local sizing = require("scripts.gui.sizing")
local logic = require("scripts.gui.tab-logic")
local name_cell = require("scripts.gui.name-cell")
local rich_name = require("scripts.gui.rich-name")
local stations_tab = require("scripts.gui.stations")
local extras = require("scripts.gui.extras")
local lint = require("scripts.lint")

local trains_tab = {}

-- scripts/gui/relative.lua requires the manager, which requires this file: gui/main.lua hands it over.
local relative

--- @param r table scripts/gui/relative.lua
function trains_tab.set_relative(r)
	relative = r
end

--- @class PlayerData
--- @field trains_chip string? the toggled Trains chip (TRAIN_CHIPS), "parked" from the Overview's Fleet tile
--- @field trains_group_by_depot true? rows grouped by depot name
--- @field expanded_depots {[string]: true}? depot groups showing their trains
--- @field selected_train uint? the train the detail pane shows

local TAB = "trains_tab"
-- The row list; a flow since phase 4, the name kept for manager.refresh_sort_headers.
local SCROLL = "manager_trains_tab_scroll_pane"
local HEADER = "manager_trains_header"
local CONTENT = "manager_trains_tab_content_frame"
local BODY = "manager_trains_body"
local TABLE = "manager_trains_table"
local PANE = "manager_trains_pane"
local PANE_CAPTION = "manager_trains_pane_caption"
local PANE_CAMERA_FLOW = "manager_trains_pane_camera_flow"
local PANE_MOUNT = "manager_trains_pane_mount"
local CAMERA = "manager_trains_pane_camera"
local CAMERA_WIDTH, CAMERA_ZOOM = 300, 0.5
local PANE_PADDING = logic.PANE_CAMERA_GAP
local CHIPS = "manager_trains_chip_flow"
-- Chips that do not fit the subheader wrap onto this strip above the column header; it is one row tall, so the page
-- has one row fewer while it shows.
local CHIP_STRIP = "manager_trains_chip_strip"
local CHIPS_WRAPPED = "manager_trains_chip_flow_2"
local DEFAULT_COLUMN = "train_id"
local ROW_HEIGHT = sizing.ROW_HEIGHT[TAB]
local SLOT = 32
local REFUELERS = "\1refuelers"
-- Fuel is read from the locomotives of the rows on the page, again every this many renders.
local FUEL_EVERY = 5
-- Rows built from nothing per update (a new or reopened list): about 0.3-0.45 ms each on pY 123, so a 27-row page
-- takes three updates instead of one 5+ ms one.
local FIRST_BUILD_ROWS = 9
-- Rows whose content changed (status, target, network, cargo) rewritten per update; the rest wait for the next one.
local REWRITE_ROWS = 9

local STATE_NAME = {}
for name, value in pairs(defines.train_state) do STATE_NAME[value] = name end

local COLUMNS = { "train_id", "train_status", "network", "layout", "depot", "state", "time_in_state", "last_refuel",
	"fuel", "shipment" }
local SORTABLE = { train_id = true, train_status = true, network = true, layout = true, depot = true, state = true,
	time_in_state = true, last_refuel = true, shipment = true }
local RIGHT = { train_id = true, time_in_state = true, last_refuel = true, fuel = true }
local HEADER_HEIGHT = 36
local NETWORK_COLUMNS = 3

local TRAIN_CHIPS = logic.TRAIN_CHIPS
local NO_FINDINGS = {}
-- Widths of the chips with their names and a one-digit count (English, measured at UI scale 1.0); each further digit
-- adds DIGIT_WIDTH. The group toggle takes 32 more.
local CHIP_WIDTH = {
	all = 46, parked = 75, to_p = 98, loading = 78, to_r = 106, unloading = 92, returning = 92, refuel = 95,
	interrupt = 99, not_refuelled = 145, in_group = 123, trouble = 91, problems = 92,
}
local DIGIT_WIDTH = 8
-- The [img=] prefix of a chip caption: a 16 px icon at the default font and its space.
local ICON_WIDTH = 22
-- The icon each chip's caption starts with, like the Stations chips (stations.lua CHIP_ICON).
local CHIP_ICON = {
	parked = "item/train-stop",
	to_p = "virtual-signal/signal-output",
	loading = "virtual-signal/signal-output",
	to_r = "virtual-signal/signal-input",
	unloading = "virtual-signal/signal-input",
	returning = "item/train-stop",
	refuel = "virtual-signal/signal-fuel",
	interrupt = "virtual-signal/signal-alarm",
	not_refuelled = "utility/fuel_icon",
	in_group = "item/locomotive",
	trouble = "utility/warning_icon",
	problems = "utility/status_yellow",
}

local ALERT_MESSAGE = {
	[1] = "cybersyn-messages.stuck-train",
	[2] = "cybersyn-messages.nonempty-train",
	[3] = "cybersyn-messages.depot-broken",
	[4] = "cybersyn-messages.station-broken",
	[5] = "cybersyn-messages.refueler-broken",
	[6] = "cybersyn-messages.train-at-incorrect",
	[7] = "cybersyn-messages.cannot-path-between-surfaces",
	[8] = "cybersyn-gui.overview-alert-8",
	[9] = "cybersyn-messages.train-schedule-broken",
}

function trains_tab.create()
	local header = { type = "frame", name = HEADER, style = "cybersyn_list_header" }
	for _, column in ipairs(COLUMNS) do
		local locale = string.gsub(column, "_", "-")
		local inner
		if SORTABLE[column] then
			inner = {
				type = "checkbox",
				style = column == DEFAULT_COLUMN and "ltnm_selected_sort_checkbox" or "ltnm_sort_checkbox",
				caption = { "cybersyn-gui.trains-col-" .. locale },
				tooltip = { "cybersyn-gui.trains-sort-" .. locale },
				state = false,
				tags = { column = column, default_state = false },
				handler = { [defines.events.on_gui_checked_state_changed] = trains_tab.handle.on_trains_sort_checkbox_changed },
			}
		else
			inner = {
				type = "label",
				style = "ltnm_column_label",
				caption = { "cybersyn-gui.trains-col-" .. locale },
				tooltip = { "cybersyn-gui.trains-col-" .. locale .. "-tooltip" },
			}
		end
		header[#header + 1] = {
			type = "flow",
			direction = "horizontal",
			tags = { column = column },
			style_mods = { horizontal_align = RIGHT[column] and "right" or "left", vertical_align = "center" },
			inner,
		}
	end
	return {
		tab = {
			name = "manager_trains_tab",
			type = "tab",
			caption = { "cybersyn-gui.trains" },
			handler = { [defines.events.on_gui_click] = trains_tab.handle.on_trains_tab_selected },
		},
		content = {
			name = CONTENT,
			type = "frame",
			style = "ltnm_main_content_frame",
			direction = "vertical",
			children = {
				{
					name = BODY,
					type = "flow",
					direction = "horizontal",
					style_mods = { horizontal_spacing = logic.PANE_GAP, horizontally_stretchable = true, vertically_stretchable = true },
					{
						name = TABLE,
						type = "flow",
						direction = "vertical",
						style_mods = { vertical_spacing = 0, horizontally_stretchable = true, vertically_stretchable = true },
						{
							name = CHIP_STRIP,
							type = "frame",
							style = "subheader_frame",
							visible = false,
							style_mods = { height = ROW_HEIGHT, horizontally_stretchable = true },
							{
								name = CHIPS_WRAPPED,
								type = "flow",
								direction = "horizontal",
								style_mods = { vertical_align = "center", horizontal_spacing = 4 },
							},
						},
						header,
						{ name = SCROLL, type = "flow", direction = "vertical", style = "cybersyn_list_rows" },
					},
					{
						name = PANE,
						type = "frame",
						style = "inside_shallow_frame",
						direction = "vertical",
						visible = false,
						style_mods = { width = logic.PANE_WIDTH },
						{
							type = "frame",
							style = "subheader_frame",
							style_mods = { horizontally_stretchable = true },
							{ type = "label", name = PANE_CAPTION, style = "subheader_caption_label" },
							{ type = "empty-widget", style = "flib_horizontal_pusher" },
							{
								type = "sprite-button",
								name = "manager_trains_pane_close",
								style = "tool_button",
								sprite = "utility/close",
								tooltip = { "cybersyn-gui.trains-pane-close-tooltip" },
								handler = { [defines.events.on_gui_click] = trains_tab.handle.on_pane_close },
							},
						},
						{
							name = PANE_CAMERA_FLOW,
							type = "flow",
							direction = "vertical",
							style_mods = { left_padding = PANE_PADDING, right_padding = PANE_PADDING, top_padding = PANE_PADDING },
						},
						{
							name = PANE_MOUNT,
							type = "flow",
							direction = "vertical",
							style_mods = { padding = PANE_PADDING },
						},
					},
				},
				{
					type = "frame",
					name = "manager_trains_subfooter",
					style = "cybersyn_list_subfooter",
					{
						name = "manager_trains_tab_summary",
						type = "label",
						style = "cybersyn_subheader_note",
					},
					{ type = "empty-widget", style = "flib_horizontal_pusher" },
					templates.pager(TAB, util.handle.pager_click),
				},
			},
		},
	}
end

--- Where the train is headed or parked, from its status; the STATUS_* globals are not yet defined at require time.
--- @param tr SnapshotTrain
--- @return "station"|"refueler"|"depot"|nil kind
--- @return uint? id
local function target_of(tr)
	local s = tr.status
	if s == STATUS_TO_P or s == STATUS_P then
		return "station", tr.p_station_id
	elseif s == STATUS_TO_R or s == STATUS_R then
		return "station", tr.r_station_id
	elseif s == STATUS_TO_F or s == STATUS_F then
		return "refueler", tr.refueler_id
	elseif s == STATUS_D or s == STATUS_TO_D or s == STATUS_TO_D_BYPASS then
		return "depot", tr.depot_id
	end
	return nil, nil
end

--- @param tr SnapshotTrain
--- @return LocalisedString
local function status_caption(tr)
	local s = tr.status
	local t = constants.gui_translations
	if s == STATUS_D then
		if next(tr.manifest_hashes) then return t.parked_at_depot_with_residue end
		return t.parked_at_depot
	elseif s == STATUS_TO_P then
		return t.fetching_from
	elseif s == STATUS_P then
		return t.loading_at
	elseif s == STATUS_TO_R then
		return t.delivering_to
	elseif s == STATUS_R then
		return t.unloading_at
	elseif s == STATUS_TO_D or s == STATUS_TO_D_BYPASS then
		return t.returning_to_depot
	elseif s == STATUS_TO_F then
		return { "cybersyn-gui.trains-going-to-refuel" }
	elseif s == STATUS_F then
		return { "cybersyn-gui.trains-refuelling" }
	elseif s then
		return { "cybersyn-gui.trains-custom-status", s }
	end
	return t.not_available
end

--- The Cybersyn status chip a train belongs to.
--- @param tr SnapshotTrain
--- @return string?
local function status_chip(tr)
	local s = tr.status
	if s == STATUS_D then return "parked" end
	if s == STATUS_TO_P then return "to_p" end
	if s == STATUS_P then return "loading" end
	if s == STATUS_TO_R then return "to_r" end
	if s == STATUS_R then return "unloading" end
	if s == STATUS_TO_D or s == STATUS_TO_D_BYPASS then return "returning" end
	if s == STATUS_TO_F or s == STATUS_F then return "refuel" end
	return nil
end

--- Per-build name lookups. Station names come from the snapshot; refueler names cost an API call, so they are
--- resolved lazily and only for trains that are actually refuelling.
--- @param snapshot Snapshot
local function new_name_cache(snapshot)
	local refuelers = {}
	local stations = snapshot.stations
	--- @param tr SnapshotTrain
	--- @return string? name
	--- @return string? name_lower
	--- @return RichNameParts? parts
	return function(tr, kind, id)
		if kind == "depot" then
			return tr.depot_name, string.lower(tr.depot_name), nil
		elseif kind == "station" then
			local st = id and stations[id]
			if st then return st.name, st.name_lower, st.name_parts end
			local station = id and storage.stations[id]
			local stop = station and station.entity_stop
			if stop and stop.valid then
				local name = stop.backer_name
				return name, string.lower(name), nil
			end
		elseif kind == "refueler" and id then
			local cached = refuelers[id]
			if cached == nil then
				local refueler = storage.refuelers[id]
				local stop = refueler and refueler.entity_stop
				cached = (stop and stop.valid) and stop.backer_name or false
				refuelers[id] = cached
			end
			if cached then return cached, string.lower(cached), nil end
		end
		return nil, nil, nil
	end
end

--- @param map_data MapData
--- @return {[uint]: string} sort keys (carriage count first, so short trains group together)
--- @return {[uint]: string} composition strings
--- @return {[uint]: string} rich-text icons per car
--- @return {[uint]: {class: int, n: int}[]} carriage-class runs (logic.composition_runs)
local function layout_strings(map_data)
	local keys, comps, icons, runs = {}, {}, {}, {}
	for id, layout in pairs(map_data.layouts) do
		keys[id] = string.format("%03d", #layout) .. table.concat(layout, "")
		comps[id] = logic.composition(layout)
		icons[id] = logic.composition_icons(layout)
		runs[id] = logic.composition_runs(layout)
	end
	return keys, comps, icons, runs
end

--- @param mask integer
--- @return string
local function mask_key(mask)
	return string.format("%010d", mask % 4294967296)
end

--- @param tr SnapshotTrain
--- @return string?
local function network_key(tr)
	local name = tr.network_name
	if not name then return nil end
	local mask = tr.network_mask
	if type(mask) == "number" then return name .. "|" .. mask_key(mask) end
	if type(mask) == "table" then
		local names = {}
		for n, m in pairs(mask) do names[#names + 1] = n .. "=" .. m end
		table.sort(names)
		return name .. "|" .. table.concat(names, ",")
	end
	return name
end

--- @param tr SnapshotTrain
local function shipment_total(tr)
	local total = 0
	for _, count in pairs(tr.manifest_hashes) do
		total = total + count
	end
	if total == 0 then return nil end
	return total
end

--- Builds the sort-key function for a column; keys are computed once per row by util.sort_by. Ages sort by their
--- start tick, so the first (ascending) sort of Time in state and Last refuel puts the longest first.
--- @param column string
--- @param names function
--- @param layout_keys {[uint]: string}
local function key_fn_for(column, names, layout_keys)
	if column == "train_status" then
		return function(tr)
			local kind, id = target_of(tr)
			local _, lower = names(tr, kind, id)
			return string.format("%05d|", tr.status or 99999) .. (lower or "")
		end
	elseif column == "network" then
		return network_key
	elseif column == "layout" then
		return function(tr) return tr.layout_id and layout_keys[tr.layout_id] or nil end
	elseif column == "depot" then
		return function(tr)
			local _, lower = names(tr, "depot")
			return lower
		end
	elseif column == "shipment" then
		return shipment_total
	elseif column == "state" then
		return function(tr) return logic.state_sort_key(tr.state and STATE_NAME[tr.state]) end
	elseif column == "time_in_state" then
		return function(tr) return tr.state_since end
	elseif column == "last_refuel" then
		return function(tr) return tr.refuel_tick end
	end
	return function(tr) return tr.id end
end

local function train_id_of(tr) return tr.id end

--- Network signal sprites, memoised per render: each lookup is up to three is_valid_sprite_path calls.
--- @return fun(name: string): string?
local function new_sprite_cache()
	local cache = {}
	return function(name)
		local sprite = cache[name]
		if sprite == nil then
			sprite = util.generate_item_references(name) or false
			cache[name] = sprite
		end
		return sprite or nil
	end
end

--- @param player_data PlayerData
--- @return string?
local function active_chip(player_data)
	local c = player_data.trains_chip
	if c and CHIP_WIDTH[c] and c ~= "all" then return c end
	player_data.trains_chip = nil
	return nil
end

--- @param player_data PlayerData
--- @return number hours
local function refuel_hours(player_data)
	local s = settings.get_player_settings(player_data.player_index)["cybersyn-manager-refuel-hours"]
	return s and s.value --[[@as number]] or 1
end

--- Whether a train is on a network some refueler serves: only those count as not refuelled (the collector's
--- not_refuelled_count follows the same rule).
--- @param tr SnapshotTrain
--- @param to_refuelers table?
--- @return boolean
local function has_refueler(tr, to_refuelers)
	if not to_refuelers then return false end
	local name = tr.network_name
	if name == NETWORK_EACH then
		if type(tr.network_mask) == "table" then
			for n in pairs(tr.network_mask) do
				if to_refuelers[n] then return true end
			end
		end
		return false
	end
	return name ~= nil and to_refuelers[name] ~= nil
end

--- Whether a train counts as in trouble: a red or orange state chip, or a Cybersyn alert on it.
--- @param tr SnapshotTrain
--- @param now uint
--- @param alerts {[uint]: int}
--- @return boolean
local function train_in_trouble(tr, now, alerts)
	if alerts[tr.id] then return true end
	return logic.in_trouble(tr.state and STATE_NAME[tr.state], now - (tr.state_since or now))
end

--- Counts one train into the chip counts and says whether it belongs to the chip `wanted` (nil = all).
--- @param tr SnapshotTrain
--- @param counts {[string]: int}
--- @param wanted string?
--- @param now uint
--- @param hours number
--- @param to_refuelers table?
--- @param alerts {[uint]: int}
--- @param problems {[uint]: int} trains with setup findings (their count)
--- @return boolean
local function count_train(tr, counts, wanted, now, hours, to_refuelers, alerts, problems)
	local member = wanted == nil
	local s = status_chip(tr)
	if s then
		counts[s] = counts[s] + 1
		if s == wanted then member = true end
	end
	if tr.in_interrupt then
		counts.interrupt = counts.interrupt + 1
		if wanted == "interrupt" then member = true end
	end
	if tr.in_group then
		counts.in_group = counts.in_group + 1
		if wanted == "in_group" then member = true end
	end
	if has_refueler(tr, to_refuelers) and logic.not_refuelled(now, tr.refuel_tick, hours, tr.refuel_from) then
		counts.not_refuelled = counts.not_refuelled + 1
		if wanted == "not_refuelled" then member = true end
	end
	if train_in_trouble(tr, now, alerts) then
		counts.trouble = counts.trouble + 1
		if wanted == "trouble" then member = true end
	end
	if problems[tr.id] then
		counts.problems = counts.problems + 1
		if wanted == "problems" then member = true end
	end
	return member
end

--- @param snapshot Snapshot
--- @return {[uint]: int}
local function alerts_by_train(snapshot)
	local out = {}
	for _, alert in ipairs(snapshot.alerts or {}) do
		out[alert.train_id] = alert.kind
	end
	return out
end

--- The setup findings of the last lint pass by what the Trains tab shows them on: trains (the Problems chip), depot
--- groups by name and the refuelers group (the group row markers). Built once per pass: lint.findings() is a new
--- array every pass.
--- @param findings LintFinding[]
--- @param snapshot Snapshot
--- @return {of: LintFinding[], trains: {[uint]: int}, groups: {[string]: LintFinding[]}}
local function index_findings(findings, snapshot)
	local trains, groups = {}, {}
	local depot_name = {}
	for name, g in pairs(snapshot.depots_by_name or {}) do
		for _, id in ipairs(g.ids or {}) do depot_name[id] = name end
	end
	for _, f in ipairs(findings) do
		local key
		if f.subject == LINT_SUBJECT_TRAIN then
			trains[f.id] = (trains[f.id] or 0) + 1
		elseif f.subject == LINT_SUBJECT_DEPOT then
			key = depot_name[f.id]
		elseif f.subject == LINT_SUBJECT_REFUELER then
			key = REFUELERS
		end
		if key then
			local list = groups[key]
			if not list then
				list = {}
				groups[key] = list
			end
			list[#list + 1] = f
		end
	end
	local s = storage.manager.lint
	return { of = findings, depots_by_name = snapshot.depots_by_name, trains = trains, groups = groups,
		pass = s and s.pass or 0 }
end

--- Filtered and sorted trains, cached until the fleet is summarised again or the filters or sort change; chip
--- counts and the chip filter are applied on every render (trouble and refuel age move with time).
--- @param map_data MapData
--- @param player_data PlayerData
--- @return SnapshotTrain[] rows the trains the chip shows
--- @return Snapshot snapshot
--- @return table ctx
function trains_tab.query(map_data, player_data)
	local snapshot = collector.get()
	local f = util.get_filters(player_data)
	local column, ascending = util.get_sort(player_data, TAB, DEFAULT_COLUMN)
	if not SORTABLE[column] then column = DEFAULT_COLUMN end
	local names = new_name_cache(snapshot)
	local qsig = table.concat({
		tostring(snapshot.trains_version), tostring(snapshot.tick), f.terms and table.concat(f.terms, " ") or "",
		f.item or "", f.network or "", f.mask, f.surface or "", column, ascending and "+" or "-",
	}, "\1")
	local cache = player_data.trains_query
	if not (cache and cache.sig == qsig) then
		local layout_keys, comps, icons, runs = layout_strings(map_data)
		local all = {}
		for _, tr in pairs(snapshot.trains) do
			if util.train_passes(tr, f) then all[#all + 1] = tr end
		end
		util.sort_by(all, key_fn_for(column, names, layout_keys), ascending, train_id_of)
		cache = { sig = qsig, all = all, layout_keys = layout_keys, comps = comps, icons = icons, runs = runs }
		player_data.trains_query = cache
	end
	local layout_keys, comps, icons, runs = cache.layout_keys, cache.comps, cache.icons, cache.runs
	local findings = lint.findings()
	-- Before the first lint pass lint.findings() is a new empty table per call; one shared empty keeps the caches hit.
	if next(findings) == nil then findings = NO_FINDINGS end
	local found = cache.findings
	if not (found and found.of == findings and found.depots_by_name == snapshot.depots_by_name) then
		found = index_findings(findings, snapshot)
		cache.findings = found
	end
	local key_fn = key_fn_for(column, names, layout_keys)
	local now = game.tick
	local hours = refuel_hours(player_data)
	local to_refuelers = storage.to_refuelers
	local wanted = active_chip(player_data)
	local alerts = cache.alerts
	if not alerts then
		alerts = alerts_by_train(snapshot)
		cache.alerts = alerts
	end
	-- Trouble and refuel age move with time: the counts hold until the first train whose chips time alone changes
	-- (logic.chip_change_tick), a new pass (a new query cache) or another chip or refuel setting.
	local chips = cache.chips
	if not (chips and chips.wanted == wanted and chips.hours == hours and chips.findings == findings
			and not (chips.next and chips.next <= now)) then
		local counts = { all = #cache.all }
		for _, key in ipairs(TRAIN_CHIPS) do if key ~= "all" then counts[key] = 0 end end
		local rows = {}
		local next_change
		for _, tr in ipairs(cache.all) do
			if count_train(tr, counts, wanted, now, hours, to_refuelers, alerts, found.trains) then rows[#rows + 1] = tr end
			local at = logic.chip_change_tick(now, tr.state and STATE_NAME[tr.state], tr.state_since,
				tr.refuel_tick or tr.refuel_from, hours, has_refueler(tr, to_refuelers))
			if at and (not next_change or at < next_change) then next_change = at end
		end
		chips = { wanted = wanted, hours = hours, findings = findings, next = next_change, counts = counts, rows = rows }
		cache.chips = chips
	end
	return chips.rows, snapshot, {
		names = names, layout_keys = layout_keys, comps = comps, icons = icons, runs = runs, found = found, key_fn = key_fn,
		sprite_of = new_sprite_cache(), counts = chips.counts, all = cache.all, hours = hours, now = now, column = column,
		ascending = ascending, to_refuelers = to_refuelers, cache = cache, chips = chips, alerts = alerts,
	}
end

--- @param train_entity LuaTrain
--- @return LuaEntity?
local function front_locomotive(train_entity)
	local locomotives = train_entity.locomotives
	return locomotives.front_movers[1] or locomotives.back_movers[1]
end

-- ---------------------------------------------------------------- hidden columns

--- A train's network as the Status header tooltip names it: the signal and its mask, signed like the circuit value.
--- @param tr SnapshotTrain
--- @return string?
local function network_display(tr)
	local name = tr.network_name
	if not name then return nil end
	local mask = tr.network_mask
	if type(mask) == "number" then return name .. " · " .. mask end
	if type(mask) == "table" then
		local names = {}
		for n, m in pairs(mask) do names[#names + 1] = n .. " · " .. m end
		table.sort(names)
		return table.concat(names, ", ")
	end
	return name
end

--- Network, layout, depot and last refuel are hidden when every listed train shares one value; fuel when every
--- train on the page does (an electric fleet reads nil everywhere).
--- @param all SnapshotTrain[]
--- @return {[string]: true} hidden
--- @return table values the shared value per hidden column (the network as network_display shows it)
local function hidden_columns(all)
	local hidden, values = {}, {}
	local checks = {
		network = network_key,
		layout = function(tr) return tr.layout_id end,
		depot = function(tr) return tr.depot_name end,
		last_refuel = function(tr) return tr.refuel_tick end,
	}
	for column, fn in pairs(checks) do
		local uniform, value = logic.single_value(all, fn)
		-- A refuel tick is per train: the column only goes when no train has one.
		if uniform and #all > 0 and (column ~= "last_refuel" or value == nil) then
			hidden[column] = true
			values[column] = column == "network" and value ~= nil and network_display(all[1]) or value
		end
	end
	return hidden, values
end

-- ---------------------------------------------------------------- fuel

-- The last fuel refresh per player, for the dev interface only: a profiler is no storage value.
local fuel_profiles = {}

-- fuel_value and stack size per item name: a pure function of the prototypes, so the same in every Lua state.
local fuel_proto = {}
local function fuel_of(name)
	local p = fuel_proto[name]
	if p == nil then
		local proto = prototypes.item[name]
		p = proto and { value = proto.fuel_value or 0, stack = proto.stack_size or 1 } or false
		fuel_proto[name] = p
	end
	return p or nil
end

--- Fuel left in a train's burner locomotives as a percentage of full, nil when none burns fuel.
--- @param train_entity LuaTrain
--- @return int?
local function read_fuel(train_entity)
	local locos = {}
	local all = train_entity.locomotives
	for _, list in pairs({ all.front_movers, all.back_movers }) do
		for _, loco in ipairs(list) do
			local burner = loco.burner
			if burner then
				local energy = burner.remaining_burning_fuel
				local best
				local burning = burner.currently_burning
				if burning then
					local name = burning.name
					if type(name) ~= "string" then name = name and name.name end
					best = name and fuel_of(name)
				end
				local inv = burner.inventory
				for _, item in pairs(inv.get_contents()) do
					local p = fuel_of(item.name)
					if p then
						energy = energy + item.count * p.value
						if not best or p.value > best.value then best = p end
					end
				end
				local capacity = best and (#inv * best.stack * best.value + best.value) or 0
				locos[#locos + 1] = { energy = energy, capacity = capacity }
			end
		end
	end
	return logic.fuel_percent(locos)
end

-- ---------------------------------------------------------------- rows

--- @param tr SnapshotTrain
--- @param sprite_of fun(name: string): string?
--- @return {sprite: string, number: int?}[] entries
--- @return string sig
local function network_entries(tr, sprite_of)
	local name = tr.network_name
	local fallback = "utility/close_black"
	if not name then
		return { { sprite = fallback } }, "-"
	end
	if name ~= NETWORK_EACH then
		local mask = tr.network_mask --[[@as int]]
		local sprite = sprite_of(name) or fallback
		return { { sprite = sprite, number = mask } }, name .. "|" .. tostring(mask)
	end
	local list = { { sprite = sprite_of(NETWORK_EACH) or fallback } }
	local names = {}
	for n in pairs(tr.network_mask or {}) do
		names[#names + 1] = n
	end
	table.sort(names)
	local sig = { NETWORK_EACH }
	for _, n in ipairs(names) do
		local sprite = sprite_of(n)
		if sprite and #list < NETWORK_COLUMNS then
			local mask = tr.network_mask[n]
			list[#list + 1] = { sprite = sprite, number = mask }
			sig[#sig + 1] = n .. "|" .. mask
		end
	end
	return list, table.concat(sig, ",")
end

--- The network icon(s), the mask beside the icon rather than drawn over it: one network shows its mask as text,
--- an "each" train its networks' icons with the masks in their tooltips.
--- @param entries {sprite: string, number: int?}[]
local function network_children(entries)
	local children = {}
	local single = #entries == 1
	for _, entry in ipairs(entries) do
		local mask = entry.number
		local tooltip = mask and { "cybersyn-gui.trains-network-mask", tostring(mask) } or nil
		children[#children + 1] = {
			type = "sprite-button",
			style = "cybersyn_slot_32_default",
			ignored_by_interaction = tooltip == nil,
			sprite = entry.sprite,
			tooltip = tooltip,
		}
		if single and mask then
			children[#children + 1] = { type = "label", style = "cybersyn_cell_label", caption = tostring(mask),
				tooltip = tooltip, style_mods = { left_padding = 4 } }
		end
	end
	return children
end

--- The shipment cell's content; the slot capacity is memoised apart (update_row's resize), so a narrower table does
--- not count as a changed dispatch.
--- @param tr SnapshotTrain
--- @param filter_item string?
--- @return string
local function shipment_sig(tr, filter_item)
	local parts = {}
	for i, item in ipairs(tr.manifest) do
		parts[i] = item.hash .. "=" .. item.count
	end
	if filter_item and tr.manifest_hashes[filter_item] then
		parts[#parts + 1] = "*" .. filter_item
	end
	return table.concat(parts, ",")
end

--- One line of shipment slots; the last slot becomes "+n" when the cargo has more item types than fit.
--- @param tr SnapshotTrain
--- @param filter_item string?
--- @param capacity int
local function shipment_children(tr, filter_item, capacity)
	local hashes = {}
	for _, hash in ipairs(util.hashes_in_item_order(tr.manifest_hashes)) do
		if util.item_sprite_and_tooltip(hash) then hashes[#hashes + 1] = hash end
	end
	local shown, over = logic.fit_slots(#hashes, capacity)
	local children = {}
	for i = 1, shown do
		local hash = hashes[i]
		local sprite, quality, name_tooltip = util.item_sprite_and_tooltip(hash)
		local count = tr.manifest_hashes[hash]
		children[#children + 1] = util.hoverable({
			type = "sprite-button",
			sprite = sprite,
			quality = quality,
			style = hash == filter_item and "cybersyn_selected_slot_32_default" or "cybersyn_slot_32_default",
			mouse_button_filter = { "left", "right" },
			tooltip = { "", name_tooltip, "\n", { "cybersyn-gui.amount", format.number(count) }, "\n", { "cybersyn-gui.item-click-hint" } },
			elem_tooltip = util.elem_tooltip(hash),
			tags = { kind = "item", id = hash },
			handler = { [defines.events.on_gui_click] = util.handle.link_click },
			{
				type = "label",
				style = "cybersyn_slot_32_count",
				ignored_by_interaction = true,
				caption = format_signal_count(count),
			},
		}, SCROLL)
	end
	if over > 0 then
		local lines = {}
		for i = shown + 1, math.min(#hashes, shown + 24) do
			local sprite = util.item_sprite_and_tooltip(hashes[i])
			lines[#lines + 1] = "[img=" .. sprite .. "] " .. format_signal_count(tr.manifest_hashes[hashes[i]])
		end
		children[#children + 1] = {
			type = "label",
			style = "cybersyn_overflow_label",
			style_mods = { width = SLOT, height = SLOT, vertical_align = "center" },
			caption = "+" .. over,
			tooltip = table.concat(lines, "\n"),
		}
	end
	return children
end

--- "for [item] [item]" after the stop of a train that carries or fetches cargo.
--- @param tr SnapshotTrain
--- @return LocalisedString?
local function cargo_caption(tr)
	local s = tr.status
	if not (s == STATUS_TO_P or s == STATUS_P or s == STATUS_TO_R or s == STATUS_R) then return nil end
	local icons = {}
	for _, item in ipairs(tr.manifest) do
		if #icons >= 3 then break end
		icons[#icons + 1] = (item.quality and ("[item=" .. item.name .. ",quality=" .. item.quality .. "]"))
			or (prototypes.fluid[item.name] and ("[fluid=" .. item.name .. "]")) or ("[item=" .. item.name .. "]")
	end
	if #icons == 0 then return nil end
	if #tr.manifest > 3 then icons[#icons + 1] = "+" .. (#tr.manifest - 3) end
	return { "cybersyn-gui.trains-for", table.concat(icons, " ") }
end

--- Everything a row shows, for the trains on the page. `sig` covers what changes with the train's dispatch (status,
--- target, network, cargo); the state chip, time in state, last refuel and fuel move with the clock and have their
--- own memo in update_row, so a row whose train only aged writes a caption or two.
--- @param tr SnapshotTrain
--- @param ctx table
--- @param alerts {[uint]: int}
--- @param filter_item string?
--- @param fuel int?|false
--- @param w table column widths
local function row_view(tr, ctx, alerts, filter_item, fuel, w)
	local kind, id = target_of(tr)
	local target_name, _, target_parts
	if kind and kind ~= "depot" then
		target_name, _, target_parts = ctx.names(tr, kind, id)
	end
	local net, net_sig = network_entries(tr, ctx.sprite_of)
	local capacity = w.shipment and math.floor(w.shipment / SLOT) or 0
	local now = ctx.now
	local state = tr.state and STATE_NAME[tr.state]
	local in_state = now - (tr.state_since or now)
	local residue = tr.status == STATUS_D and next(tr.manifest_hashes) ~= nil
	local sc = logic.state_chip(state, tr.state_since or now, now,
		residue and "residue" or (tr.status == STATUS_F and "refuel" or nil))
	local chip = sc.style and sc or nil
	local layout_cap = w.layout and math.max(math.floor(w.layout / logic.COMPOSITION_ICON), 1) or 0
	local view = {
		id = tr.id,
		tr = tr,
		status = status_caption(tr),
		target_kind = kind ~= "depot" and kind or nil,
		target_id = kind ~= "depot" and id or nil,
		target_name = target_name,
		target_parts = target_parts,
		cargo = cargo_caption(tr),
		alert = alerts[tr.id],
		net = net,
		net_sig = net_sig,
		layout = tr.layout_id and ctx.comps[tr.layout_id] or "",
		layout_icons = tr.layout_id and ctx.icons[tr.layout_id] or "",
		layout_runs = tr.layout_id and ctx.runs[tr.layout_id] or nil,
		layout_sig = tostring(tr.layout_id) .. "|" .. layout_cap,
		layout_cap = layout_cap,
		depot_id = tr.depot_id,
		depot_name = tr.depot_name,
		chip = chip,
		chip_sig = chip and (chip.key .. "|" .. chip.style) or "",
		state = state,
		in_state = util.short_duration(in_state),
		refuel = logic.age_caption(now, tr.refuel_tick, util.short_duration),
		refuel_overdue = has_refueler(tr, ctx.to_refuelers) and logic.not_refuelled(now, tr.refuel_tick, ctx.hours, tr.refuel_from),
		fuel = fuel,
		capacity = capacity,
		ship_sig = shipment_sig(tr, filter_item),
		filter_item = filter_item,
	}
	view.sig = table.concat({
		tostring(tr.status), residue and 1 or 0, kind or "", tostring(id), target_name or "", tostring(view.alert),
		net_sig, view.layout, tostring(tr.depot_id), tr.depot_name, view.ship_sig, tostring(view.cargo and #tr.manifest),
	}, "\31")
	return view
end

--- @param view table
local function alert_tooltip(view)
	if not view.alert then return nil end
	return { ALERT_MESSAGE[view.alert] or "cybersyn-gui.overview-alert-0" }
end

local function stop_tooltip(name)
	return { "", "[font=default-semibold]", name or "", "[/font]\n", util.LINK_FOOTER }
end

--- Rich-name parts of a depot or refueler name, parsed once per name while the snapshot lives (station names come
--- with their record's name_parts).
--- @param name string?
--- @return RichNameParts?
local function parts_of(name)
	if not name then return nil end
	local manager = storage.manager
	local names = manager.name_parts
	if not names then
		names = {}
		manager.name_parts = names
	end
	local parts = names[name]
	if not parts then
		parts = rich_name.parse(name)
		names[name] = parts
	end
	return parts
end

--- "<state> · <age>" and what a click on the icon does.
--- @param view table
--- @return LocalisedString
local function state_tooltip(view)
	return { "", view.chip.tooltip, "\n", { "cybersyn-gui.trains-slot-footer" } }
end

-- Sprite paths checked once per Lua state: a pure function of the loaded prototypes.
local sprite_ok = {}

--- The state's icon, or the fallback where an install lacks it (signal-fuel predates 2.0 in no install, but a mod
--- may hide it).
--- @param chip StateChip
--- @return string
local function state_sprite(chip)
	local sprite = chip.sprite
	local ok = sprite_ok[sprite]
	if ok == nil then
		ok = helpers.is_valid_sprite_path(sprite)
		sprite_ok[sprite] = ok
	end
	if ok then return sprite end
	return chip.key == "refuel" and logic.REFUEL_FALLBACK or "utility/questionmark"
end

--- @param view table
--- @return string
local function state_style(view)
	return "cybersyn_state_slot_" .. (view.chip and view.chip.style or "grey")
end

--- The composition cell: one icon per run of one carriage class with the run's length as its badge; the last icon
--- becomes "+n" when the runs do not fit the column.
--- @param view table
--- @return flib.GuiElemDef[]
local function composition_children(view)
	local runs = view.layout_runs
	if not runs or view.layout_cap == 0 then return {} end
	local shown, over = logic.fit_slots(#runs, view.layout_cap)
	local children = {}
	for i = 1, shown do
		local r = runs[i]
		children[i] = {
			type = "sprite-button",
			style = "cybersyn_composition_icon",
			sprite = logic.CLASS_SPRITE[r.class],
			number = r.n > 1 and r.n or nil,
			tooltip = view.layout_icons,
		}
	end
	if over > 0 then
		children[#children + 1] = {
			type = "label",
			style = "cybersyn_overflow_label",
			style_mods = { width = logic.COMPOSITION_ICON, vertical_align = "center" },
			caption = "+" .. over,
			tooltip = view.layout_icons,
		}
	end
	return children
end

--- @param view table
--- @return LocalisedString
local function refuel_label(view)
	return view.refuel or { "cybersyn-gui.never" }
end

--- Orange only for a train the Not refuelled chip counts: a train on a network without a refueler, or one still in
--- its grace, reads "never" in the default colour.
local function refuel_style(view)
	return view.refuel_overdue and "cybersyn_cell_value_orange" or "cybersyn_cell_value"
end

--- @param view table
--- @return string
local function refuel_sig(view)
	return tostring(view.refuel) .. (view.refuel_overdue and "!" or "")
end

--- The memo update_row compares against, as a row built from `view` shows it.
--- @param view table
--- @param color string
--- @return table
--- @param w table the column widths the row is built with
local function row_memo(view, color, w)
	return {
		sig = view.sig, net = view.net_sig, ship = view.ship_sig, color = color, chip = view.chip_sig,
		in_state = view.in_state, refuel = refuel_sig(view), fuel = view.fuel, wsig = w.sig, cap = view.capacity,
		lay = view.layout_sig,
	}
end

--- The shipment cell's slot table for the row's capacity; empty while the column is not shown (capacity 0).
--- @param view table
--- @return flib.GuiElemDef
local function shipment_table(view)
	if view.capacity == 0 then return { type = "table", style = "slot_table", column_count = 1 } end
	return { type = "table", style = "slot_table", column_count = view.capacity, children = shipment_children(view.tr, view.filter_item, view.capacity) }
end

--- @param view table
--- @param color "light"|"dark"
--- @param w table
--- @return flib.GuiElemDef
local function build_row(view, color, w)
	-- A column without a width is hidden (every train shares its value) or dropped for the detail pane.
	local function cell(column, def)
		def.visible = w[column] ~= nil
		return def
	end
	return util.hoverable({
		type = "frame",
		style = "cybersyn_train_row_" .. color,
		style_mods = { height = ROW_HEIGHT },
		tags = { train_id = view.id },
		util.hoverable({
			type = "button",
			style = "cybersyn_train_id_button",
			style_mods = { width = w.train_id },
			caption = tostring(view.id),
			tooltip = { "cybersyn-gui.trains-open-train-tooltip" },
			tags = { kind = "train", id = view.id },
			mouse_button_filter = { "left", "right" },
			handler = { [defines.events.on_gui_click] = util.handle.link_click },
		}, SCROLL),
		{
			type = "flow",
			style = "cybersyn_cell_flow",
			style_mods = { width = w.train_status },
			{ type = "label", style = "cybersyn_cell_label", caption = view.status },
			(function()
				local def = name_cell.def(view.target_parts or parts_of(view.target_name), view.target_name or "",
					{ kind = view.target_kind or "station", id = view.target_id }, math.max(w.train_status - 160, 80),
					stop_tooltip(view.target_name), SCROLL, true)
				def.visible = view.target_name ~= nil
				return def
			end)(),
			{ type = "label", style = "cybersyn_cell_label", caption = view.cargo or "", visible = view.cargo ~= nil },
		},
		cell("network", {
			type = "flow",
			style = "cybersyn_cell_flow",
			style_mods = { width = w.network, horizontal_spacing = 0 },
			children = network_children(view.net),
		}),
		cell("layout", {
			type = "flow",
			style = "cybersyn_cell_flow",
			style_mods = { width = w.layout, horizontal_spacing = 0 },
			children = composition_children(view),
		}),
		cell("depot", name_cell.def(parts_of(view.depot_name), view.depot_name, { kind = "depot", id = view.depot_id },
			w.depot or 150, stop_tooltip(view.depot_name), SCROLL)),
		{
			type = "flow",
			style = "cybersyn_cell_flow",
			style_mods = { width = w.state },
			{ type = "sprite", sprite = "utility/warning_icon", resize_to_sprite = false, style_mods = { size = 20 },
				visible = view.alert ~= nil, tooltip = alert_tooltip(view) },
			util.hoverable({
				type = "sprite-button",
				style = state_style(view),
				sprite = view.chip and state_sprite(view.chip) or nil,
				tooltip = view.chip and state_tooltip(view) or nil,
				visible = view.chip ~= nil,
				tags = { state_train = view.id },
				handler = { [defines.events.on_gui_click] = trains_tab.handle.on_state_click },
			}, SCROLL),
		},
		cell("time_in_state", { type = "label", style = "cybersyn_cell_value", style_mods = { width = w.time_in_state }, caption = view.in_state }),
		cell("last_refuel", { type = "label", style = refuel_style(view), style_mods = { width = w.last_refuel }, caption = refuel_label(view) }),
		cell("fuel", { type = "label", style = "cybersyn_cell_value", style_mods = { width = w.fuel },
			caption = view.fuel and (view.fuel .. "%") or "" }),
		cell("shipment", {
			type = "flow",
			style = "cybersyn_cell_flow",
			style_mods = { width = w.shipment },
			shipment_table(view),
		}),
	}, SCROLL)
end

--- Writes new column widths into a built row (the detail pane opened or closed); the slot table is rebuilt only when
--- its capacity changed.
--- @param row LuaGuiElement
--- @param view table
--- @param m table the row's memo
--- @param w table
local function resize_row(row, view, m, w)
	local c = row.children
	for i, column in ipairs(COLUMNS) do
		local cell = c[i]
		local width = w[column]
		if cell.visible ~= (width ~= nil) then cell.visible = width ~= nil end
		if width and column ~= "depot" then cell.style.width = width end
	end
	local target = c[2].children[2]
	if target.visible then
		name_cell.resize(target, view.target_parts or parts_of(view.target_name), math.max(w.train_status - 160, 80), true)
	end
	if w.depot then name_cell.resize(c[5], parts_of(view.depot_name), w.depot) end
	if m.lay ~= view.layout_sig then
		c[4].clear()
		gui.add(c[4], composition_children(view))
		m.lay = view.layout_sig
	end
	local ship = c[10]
	if m.cap ~= view.capacity then
		ship.clear()
		gui.add(ship, shipment_table(view))
		m.cap = view.capacity
		m.ship = view.ship_sig
	end
	m.wsig = w.sig
end

--- In-place update of a row, against its memo `m` (row_memo). The dispatch part (status, target, network, layout,
--- depot, alert, shipment) is rewritten only when view.sig moved, and then only while `budget.rewrites` lasts; the
--- clock-driven cells are written when their own caption or style changed.
--- @param row LuaGuiElement
--- @param view table
--- @param m table? the row's memo, nil when it was dropped (window closed)
--- @param color "light"|"dark"
--- @param w table
--- @param budget {rewrites: int}
--- @return table? m the memo to keep, nil when the row waits for a later update
local function update_row(row, view, m, color, w, budget)
	if m and m.wsig ~= w.sig then resize_row(row, view, m, w) end
	if not (m and m.sig == view.sig) then
		if budget.rewrites <= 0 then return m end
		budget.rewrites = budget.rewrites - 1
		local c = row.children
		local status = c[2].children
		status[1].caption = view.status
		local target = status[2]
		target.visible = view.target_name ~= nil
		if view.target_name then
			name_cell.update(target, view.target_parts or parts_of(view.target_name), view.target_name,
				{ kind = view.target_kind, id = view.target_id }, math.max(w.train_status - 160, 80), stop_tooltip(view.target_name), SCROLL)
		end
		status[3].caption = view.cargo or ""
		status[3].visible = view.cargo ~= nil
		if not (m and m.net == view.net_sig) then
			local net = c[3]
			net.clear()
			gui.add(net, network_children(view.net))
		end
		if not (m and m.lay == view.layout_sig) then
			c[4].clear()
			gui.add(c[4], composition_children(view))
		end
		name_cell.update(c[5], parts_of(view.depot_name), view.depot_name, { kind = "depot", id = view.depot_id }, w.depot or 150,
			stop_tooltip(view.depot_name), SCROLL)
		local alert = c[6].children[1]
		alert.visible = view.alert ~= nil
		alert.tooltip = alert_tooltip(view)
		if not (m and m.ship == view.ship_sig and m.cap == view.capacity) then
			local ship = c[10]
			ship.clear()
			gui.add(ship, shipment_table(view))
		end
		local old = m
		m = { sig = view.sig, net = view.net_sig, ship = view.ship_sig, lay = view.layout_sig }
		if old then
			m.color, m.chip, m.in_state, m.refuel, m.fuel = old.color, old.chip, old.in_state, old.refuel, old.fuel
			m.wsig = old.wsig
		end
		m.cap = view.capacity
	end
	if m.color ~= color then
		local style = "cybersyn_train_row_" .. color
		if row.style.name ~= style then
			-- Assigning a style drops style_mods: the fixed height is written again.
			row.style = style
			row.style.height = ROW_HEIGHT
		end
		m.color = color
	end
	local chip_changed = m.chip ~= view.chip_sig
	if chip_changed then
		local chip = row.children[6].children[2]
		chip.visible = view.chip ~= nil
		if view.chip then
			local style = state_style(view)
			if chip.style.name ~= style then chip.style = style end
			chip.sprite = state_sprite(view.chip)
			chip.tooltip = state_tooltip(view)
		end
		m.chip = view.chip_sig
	end
	if m.in_state ~= view.in_state then
		row.children[7].caption = view.in_state
		-- The icon's tooltip carries the same age.
		if view.chip and not chip_changed then row.children[6].children[2].tooltip = state_tooltip(view) end
		m.in_state = view.in_state
	end
	local rsig = refuel_sig(view)
	if m.refuel ~= rsig then
		local cell = row.children[8]
		local style = refuel_style(view)
		if cell.style.name ~= style then
			cell.style = style
			if w.last_refuel then cell.style.width = w.last_refuel end
		end
		cell.caption = refuel_label(view)
		m.refuel = rsig
	end
	if m.fuel ~= view.fuel then
		row.children[9].caption = view.fuel and (view.fuel .. "%") or ""
		m.fuel = view.fuel
	end
	return m
end

-- ---------------------------------------------------------------- depot groups

--- The group a train is listed under: its depot's name, or the refuelers while it refuels.
--- @param tr SnapshotTrain
--- @return string
local function group_key(tr)
	return (tr.status == STATUS_TO_F or tr.status == STATUS_F) and REFUELERS or tr.depot_name
end

--- Per group, over the trains the filters show (the chip aside), the numbers its row shows: parked (status parked,
--- residue included, as the Parked chip counts), inbound, bound (listed under the group), how many of those may
--- bypass their depot, their compositions (layout id -> trains) and their states (logic.state_bucket -> trains).
--- Counted from the same trains as the group's members, so the row agrees with its expansion.
--- @param all SnapshotTrain[]
--- @return {[string]: {parked: int, inbound: int, bound: int, bypass: int, layouts: {[uint]: int}, states: {[string]: int}}}
local function group_stats(all)
	local out = {}
	local trains = storage.trains
	for _, tr in ipairs(all) do
		local key = group_key(tr)
		local g = out[key]
		if not g then
			g = { parked = 0, inbound = 0, bound = 0, bypass = 0, layouts = {}, states = {} }
			out[key] = g
		end
		g.bound = g.bound + 1
		local s = tr.status
		if s == STATUS_D then
			g.parked = g.parked + 1
		elseif s == STATUS_TO_D or s == STATUS_TO_D_BYPASS then
			g.inbound = g.inbound + 1
		end
		-- Cybersyn's train.disable_bypass false = the train may skip its depot.
		local train = trains[tr.id]
		if train and not train.disable_bypass then g.bypass = g.bypass + 1 end
		local layout = tr.layout_id
		if layout then g.layouts[layout] = (g.layouts[layout] or 0) + 1 end
		local bucket = logic.state_bucket(tr.state and STATE_NAME[tr.state])
		g.states[bucket] = (g.states[bucket] or 0) + 1
	end
	return out
end

--- Group rows from snapshot.depots_by_name plus a refuelers group; members are the listed trains of each group.
--- @param rows SnapshotTrain[] the trains the chip shows, sorted
--- @param snapshot Snapshot
--- @param filtering boolean a filter or chip is active: groups without listed trains are left out
--- @return string[] names
--- @return {[string]: SnapshotTrain[]} members
local function depot_groups(rows, snapshot, filtering)
	local members = {}
	for _, tr in ipairs(rows) do
		local key = group_key(tr)
		local list = members[key]
		if not list then
			list = {}
			members[key] = list
		end
		list[#list + 1] = tr
	end
	local names = {}
	for name in pairs(snapshot.depots_by_name or {}) do
		if not filtering or members[name] then names[#names + 1] = name end
	end
	for name in pairs(members) do
		if name ~= REFUELERS and not (snapshot.depots_by_name or {})[name] then names[#names + 1] = name end
	end
	local lower = {}
	for _, name in ipairs(names) do lower[name] = string.lower(name) end
	table.sort(names, function(a, b)
		if lower[a] ~= lower[b] then return lower[a] < lower[b] end
		return a < b
	end)
	if members[REFUELERS] or (not filtering and next(storage.refuelers or {})) then names[#names + 1] = REFUELERS end
	return names, members
end

local EMPTY_STATS = { parked = 0, inbound = 0, bound = 0, bypass = 0, layouts = {}, states = {} }
-- A tooltip lists this many compositions and findings at most; LocalisedStrings take 20 parameters per table.
local TIP_COMPOSITIONS, TIP_FINDINGS, STATES_PER_LINE = 12, 8, 4

--- A LocalisedString of any number of parts, nested so no table has more than 20 parameters.
--- @param parts LocalisedString[]
--- @return LocalisedString
local function joined(parts)
	if #parts <= 19 then
		local out = { "" }
		for i, p in ipairs(parts) do out[i + 1] = p end
		return out
	end
	local chunks = {}
	for i = 1, #parts, 19 do
		local chunk = { "" }
		for j = i, math.min(i + 18, #parts) do chunk[#chunk + 1] = parts[j] end
		chunks[#chunks + 1] = chunk
	end
	return joined(chunks)
end

--- A group's compositions, most trains first: {id, n, runs}.
--- @param layouts {[uint]: int}
--- @param runs {[uint]: {class: int, n: int}[]}
--- @return {id: uint, n: int, runs: int}[]
local function composition_list(layouts, runs)
	local list = {}
	for id, n in pairs(layouts) do list[#list + 1] = { id = id, n = n, runs = runs[id] and #runs[id] or 1 } end
	table.sort(list, function(a, b)
		if a.n ~= b.n then return a.n > b.n end
		return a.id < b.id
	end)
	return list
end

--- The worst severity among findings (DIAG_SEV_ERROR is the lowest number).
--- @param findings LintFinding[]
--- @return int
local function worst_severity(findings)
	local worst = DIAG_SEV_INFO
	for _, f in ipairs(findings) do
		local sev = LINT_SEVERITY[f.check] or DIAG_SEV_WARNING
		if sev < worst then worst = sev end
	end
	return worst
end

--- The hover box of a group row: name and trains, every composition with its count, the trains by state.
--- @param title string|LocalisedString
--- @param stats table group_stats entry
--- @param comps {id: uint, n: int}[]
--- @param ctx table
--- @return LocalisedString
local function group_tooltip(title, stats, comps, ctx)
	local parts = { "[font=default-semibold]", { "cybersyn-gui.trains-group-head", title, tostring(stats.bound) }, "[/font]" }
	for i, c in ipairs(comps) do
		if i > TIP_COMPOSITIONS then
			parts[#parts + 1] = "\n"
			parts[#parts + 1] = { "cybersyn-gui.trains-group-more", tostring(#comps - TIP_COMPOSITIONS) }
			break
		end
		parts[#parts + 1] = "\n" .. (ctx.icons[c.id] or "?") .. "  ×" .. format.number(c.n)
	end
	parts[#parts + 1] = "\n\n[font=default-semibold]"
	parts[#parts + 1] = { "cybersyn-gui.trains-group-by-state" }
	parts[#parts + 1] = "[/font]"
	local on_line = 0
	for _, b in ipairs(logic.STATE_BUCKETS) do
		local n = stats.states[b]
		if n and n > 0 then
			parts[#parts + 1] = (on_line % STATES_PER_LINE == 0) and "\n" or "    "
			local chip = logic.bucket_chip(b)
			parts[#parts + 1] = "[img=" .. chip.sprite .. "] "
			parts[#parts + 1] = chip.caption
			parts[#parts + 1] = " " .. format.number(n)
			on_line = on_line + 1
		end
	end
	return joined(parts)
end

--- The marker's tooltip: every finding of the group as the stop panel words it (relative.finding_text).
--- @param head string locale key
--- @param findings LintFinding[]
--- @return LocalisedString
local function findings_tooltip(head, findings)
	local parts = { "[font=default-semibold]", { head }, "[/font]" }
	for i, f in ipairs(findings) do
		if i > TIP_FINDINGS then
			parts[#parts + 1] = "\n"
			parts[#parts + 1] = { "cybersyn-gui.relative-more", tostring(#findings - TIP_FINDINGS) }
			break
		end
		parts[#parts + 1] = "\n"
		parts[#parts + 1] = relative.finding_text(f)
	end
	return joined(parts)
end

--- @param name string
--- @param snapshot Snapshot
--- @param members SnapshotTrain[]?
--- @param ctx table
--- @param expanded boolean
--- @return table view
local function group_view(name, snapshot, members, ctx, expanded)
	local n = members and #members or 0
	local stats = ctx.group_stats[name] or EMPTY_STATS
	local findings = ctx.found.groups[name]
	local states = {}
	for i, b in ipairs(logic.STATE_BUCKETS) do states[i] = stats.states[b] or 0 end
	local marker = findings and {
		count = #findings,
		sev = worst_severity(findings),
		tooltip = findings_tooltip(name == REFUELERS and "cybersyn-gui.trains-group-problems-refuelers"
			or "cybersyn-gui.trains-group-problems-head", findings),
	} or nil
	local marker_sig = marker and (marker.count .. "|" .. marker.sev .. "|" .. ctx.found.pass) or "-"
	if name == REFUELERS then
		local refuelers = 0
		for _ in pairs(storage.refuelers or {}) do refuelers = refuelers + 1 end
		local caption = { "cybersyn-gui.trains-group-refuelers", tostring(refuelers) }
		return {
			key = name, refuelers = true, expanded = expanded, n = n, marker = marker,
			caption = caption,
			tip = group_tooltip(caption, stats, {}, ctx),
			struct = "r|" .. refuelers .. "|" .. n .. "|" .. tostring(expanded) .. "|" .. marker_sig,
			tip_sig = table.concat(states, ","),
		}
	end
	local g = (snapshot.depots_by_name or {})[name] or {}
	local limit = g.limit or 0
	local comps = composition_list(stats.layouts, ctx.runs)
	local shown, more = logic.fit_compositions(comps, logic.GROUP_COMPS, 2)
	local comp_sig = {}
	for i, c in ipairs(comps) do comp_sig[i] = c.id .. "=" .. c.n end
	comp_sig = table.concat(comp_sig, ",")
	return {
		key = name,
		name = name,
		parts = parts_of(name),
		id = g.ids and g.ids[1] or nil,
		depots = g.ids and #g.ids or 0,
		parked = stats.parked,
		limit = limit >= collector.UNLIMITED and "∞" or tostring(limit),
		inbound = stats.inbound,
		bound = stats.bound,
		bypass = stats.bypass,
		comps = comps,
		comps_shown = shown,
		comps_more = more,
		marker = marker,
		expanded = expanded,
		n = n,
		tip = group_tooltip(name, stats, comps, ctx),
		struct = table.concat({ name, tostring(g.ids and g.ids[1]), g.ids and #g.ids or 0, stats.parked, limit,
			stats.inbound, stats.bound, stats.bypass, comp_sig, tostring(expanded), n, marker_sig }, "\1"),
		tip_sig = table.concat(states, ","),
	}
end

--- The Problems marker of a group row: icon and count of the setup findings at its depots (or refuelers), detail in
--- the tooltip; a plain label, nothing to click. Empty but as wide where there is none, so group rows stay aligned.
--- @param view table
--- @param w table
--- @return flib.GuiElemDef
local function marker_def(view, w)
	local m = view.marker
	local width = w.group_marker or logic.GROUP_MARKER
	if not m then
		return { type = "empty-widget", style_mods = { width = width } }
	end
	local icon = m.sev == DIAG_SEV_ERROR and "utility/danger_icon" or "utility/warning_icon"
	return {
		type = "label",
		name = "group_marker",
		style = m.sev == DIAG_SEV_ERROR and "cybersyn_marker_red" or "cybersyn_marker_orange",
		style_mods = { width = width },
		caption = width >= logic.GROUP_MARKER and { "", "[img=" .. icon .. "] ", { "cybersyn-gui.trains-group-problems", tostring(m.count) } }
			or "[img=" .. icon .. "]",
		tooltip = m.tooltip,
	}
end

--- A group row's compositions: up to two as icon runs with their train count, then "+n".
--- @param view table
--- @return flib.GuiElemDef
local function compositions_def(view, ctx)
	local children = {}
	for i = 1, view.comps_shown do
		local c = view.comps[i]
		if i > 1 then
			children[#children + 1] = { type = "label", style = "cybersyn_subheader_note", caption = "·", tooltip = view.tip,
				style_mods = { left_padding = 4 } }
		end
		for _, r in ipairs(ctx.runs[c.id] or {}) do
			children[#children + 1] = {
				type = "sprite-button",
				style = "cybersyn_composition_icon",
				sprite = logic.CLASS_SPRITE[r.class],
				number = r.n > 1 and r.n or nil,
				tooltip = view.tip,
			}
		end
		children[#children + 1] = { type = "label", style = "cybersyn_cell_label", caption = "×" .. format.number(c.n),
			tooltip = view.tip, style_mods = { left_padding = 4 } }
	end
	if view.comps_more > 0 then
		children[#children + 1] = { type = "label", style = "cybersyn_cell_label", style_mods = { left_padding = 8 },
			caption = { "cybersyn-gui.trains-group-more", tostring(view.comps_more) },
			tooltip = view.tip }
	end
	return {
		type = "flow",
		name = "group_comps",
		direction = "horizontal",
		style_mods = { vertical_align = "center", horizontal_spacing = 2 },
		children = children,
	}
end

--- @param view table
--- @param w table
--- @param ctx table
--- @return flib.GuiElemDef[]
local function group_children(view, w, ctx)
	local toggle = util.hoverable({
		type = "sprite-button",
		style = "cybersyn_sort_tool_button",
		sprite = view.expanded and "utility/collapse" or "utility/expand",
		tooltip = { view.expanded and "cybersyn-gui.trains-group-collapse" or "cybersyn-gui.trains-group-expand" },
		tags = { depot_group = view.key },
		handler = { [defines.events.on_gui_click] = trains_tab.handle.on_group_toggle },
	}, SCROLL)
	if view.refuelers then
		return {
			toggle,
			{ type = "label", name = "group_caption", style = "subheader_caption_label", caption = view.caption, tooltip = view.tip },
			marker_def(view, w),
			{ type = "label", name = "group_count", style = "cybersyn_cell_label",
				caption = { "cybersyn-gui.trains-group-refuelling", tostring(view.n) }, tooltip = view.tip },
		}
	end
	local tooltip = { "", "[font=default-semibold]", view.name, "[/font]\n",
		{ "cybersyn-gui.trains-group-tooltip", tostring(view.depots) }, "\n", util.LINK_FOOTER }
	local out = {
		toggle,
		name_cell.def(view.parts, view.name, { kind = "depot", id = view.id }, math.max(w.group_name, 120), tooltip, SCROLL),
		marker_def(view, w),
		{ type = "label", style = "cybersyn_cell_value", style_mods = { width = 110 },
			caption = { "cybersyn-gui.trains-group-parked", tostring(view.parked), view.limit },
			tooltip = { "cybersyn-gui.trains-group-parked-tooltip" } },
		{ type = "label", style = "cybersyn_cell_value", style_mods = { width = 100 },
			caption = { "cybersyn-gui.trains-group-inbound", tostring(view.inbound) } },
		{ type = "label", style = "cybersyn_cell_value", style_mods = { width = 100 },
			caption = { "cybersyn-gui.trains-group-bound", tostring(view.bound) },
			tooltip = { "cybersyn-gui.trains-group-bound-tooltip", tostring(view.n) } },
		-- A label, not a chip: it says something about the depot, there is nothing to click.
		{
			type = "label",
			style = "cybersyn_marker_grey",
			style_mods = { width = 90, horizontal_align = "center" },
			caption = { "cybersyn-gui.trains-group-bypassed" },
			tooltip = { "cybersyn-gui.trains-group-bypassed-tooltip", tostring(view.bypass) },
			visible = view.bypass > 0 and w.group_bypass,
		},
	}
	if w.group_comps then out[#out + 1] = compositions_def(view, ctx) end
	return out
end

--- Writes a group row's hover box into the elements that carry it, without rebuilding the row.
--- @param elem LuaGuiElement the group row
--- @param tip LocalisedString
local function write_group_tip(elem, tip)
	elem.tooltip = tip
	local comps = elem.group_comps
	if comps then
		for _, child in ipairs(comps.children) do child.tooltip = tip end
	end
	-- Child names that are not LuaGuiElement properties: elem.caption would be the row's own caption.
	for _, name in ipairs({ "group_caption", "group_count" }) do
		local child = elem[name]
		if child then child.tooltip = tip end
	end
end

-- ---------------------------------------------------------------- chips

-- Chip icons checked once per Lua state (prototype data only).
local chip_icon_ok = {}

--- @param key string
--- @return string?
local function chip_icon(key)
	local icon = CHIP_ICON[key]
	if not icon then return nil end
	local ok = chip_icon_ok[icon]
	if ok == nil then
		ok = helpers.is_valid_sprite_path(icon)
		chip_icon_ok[icon] = ok
	end
	return ok and icon or nil
end

--- "[img] Name  n": the icon, the whole name (never shortened, D15 item 13) and the count.
--- @param key string
--- @param count int
--- @param hours number
local function chip_caption(key, count, hours)
	local locale = logic.train_chip_locale(key)
	local name = key == "not_refuelled" and { locale, logic.hours_caption(hours) } or { locale }
	local icon = chip_icon(key)
	return { "", icon and ("[img=" .. icon .. "] ") or "", name, "  ", format.number(count) }
end

--- The px a chip takes in the subheader with its spacing.
--- @param key string
--- @param count int
--- @return int
local function chip_width(key, count)
	return CHIP_WIDTH[key] + 4 + DIGIT_WIDTH * (#format.number(count) - 1) + (CHIP_ICON[key] and ICON_WIDTH or 0)
end

--- The subheader gets the chips and the group toggle at its right end on first use.
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
	local _, toggle = gui.add(subheader, {
		type = "sprite-button",
		name = "manager_trains_group_toggle",
		style = "tool_button",
		sprite = "item/train-stop",
		tooltip = { "cybersyn-gui.trains-group-by-depot-tooltip" },
		handler = { [defines.events.on_gui_click] = trains_tab.handle.on_group_by_depot },
	})
	refs.manager_trains_group_toggle = toggle
	return elem
end

local function chip_space(player_data)
	local refs = player_data.refs
	local layout = player_data.layout
	local space = (layout and layout.content_width or (sizing.MAX_WIDTH - sizing.OUTER_WIDTH)) - 24
	local function shown(name)
		local e = refs[TAB .. name]
		return e and e.valid and e.visible
	end
	if shown("_search_field") then space = space - 208 end
	if shown("_chip_flow") then space = space - 260 end
	if shown("_collecting") then space = space - 160 end
	return space
end

--- @param keys string[]
--- @param counts {[string]: int}
--- @param wanted string
--- @param hours number
--- @return table[] entries for util.sync_children
local function chip_entries(keys, counts, wanted, hours)
	local entries = {}
	for i, key in ipairs(keys) do
		local count = counts[key] or 0
		local selected = wanted == key
		local enabled = selected or count > 0
		local locale = string.gsub(key, "_", "-")
		local tooltip = key ~= "all" and { "cybersyn-gui.trains-chip-" .. locale .. "-tooltip", logic.hours_caption(hours) } or nil
		entries[i] = {
			key = key,
			sig = count .. (selected and "+" or "-") .. hours,
			build = function()
				return {
					type = "button",
					style = "cybersyn_filter_chip",
					caption = chip_caption(key, count, hours),
					tooltip = tooltip,
					toggled = selected,
					enabled = enabled,
					tags = { trains_chip = key },
					handler = { [defines.events.on_gui_click] = trains_tab.handle.on_chip_click },
				}
			end,
			update = function(elem)
				elem.caption = chip_caption(key, count, hours)
				elem.toggled = selected
				elem.enabled = enabled
				elem.tooltip = tooltip
			end,
		}
	end
	return entries
end

--- The chips with their names in the subheader; when they do not fit, the zero-count ones go (All and the toggled
--- one stay), and what still does not fit wraps onto the strip above the column header (logic.chip_lines).
--- @param player_data PlayerData
--- @param counts {[string]: int}
--- @param hours number
--- @return boolean wrapped the strip shows: the page has one row fewer
local function render_chips(player_data, counts, hours)
	local flow = chip_flow(player_data)
	if not flow then return false end
	local refs = player_data.refs
	local toggle = refs.manager_trains_group_toggle
	if toggle and toggle.valid then toggle.toggled = player_data.trains_group_by_depot == true end
	local wanted = active_chip(player_data) or "all"
	local list = {}
	for i, key in ipairs(TRAIN_CHIPS) do
		local count = counts[key] or 0
		list[i] = { key = key, width = chip_width(key, count), count = count, keep = key == "all" or key == wanted }
	end
	-- The group toggle sits right of the chips.
	local _, lines = logic.chip_lines(list, chip_space(player_data) - 32)
	util.sync_children(flow, chip_entries(lines[1] or {}, counts, wanted, hours), util.gui_state(player_data, CHIPS), false)
	local rest = {}
	for i = 2, #lines do
		for _, key in ipairs(lines[i]) do rest[#rest + 1] = key end
	end
	local strip, wrapped_flow = refs[CHIP_STRIP], refs[CHIPS_WRAPPED]
	if not (strip and strip.valid and wrapped_flow and wrapped_flow.valid) then return false end
	local wrapped = #rest > 0
	if strip.visible ~= wrapped then strip.visible = wrapped end
	util.sync_children(wrapped_flow, chip_entries(rest, counts, wanted, hours), util.gui_state(player_data, CHIPS_WRAPPED), false)
	return wrapped
end

-- ---------------------------------------------------------------- render

--- The Status header's tooltip names the values of the hidden columns, with the composition string.
--- @param hidden {[string]: true}
--- @param values table
--- @param ctx table
--- @return LocalisedString
local function status_header_tooltip(hidden, values, ctx)
	local out = { "", { "cybersyn-gui.trains-sort-train-status" } }
	if hidden.network then
		local v = values.network
		out[#out + 1] = "\n"
		out[#out + 1] = { "cybersyn-gui.trains-hidden-network", v or "–" }
	end
	if hidden.layout then
		local id = values.layout
		out[#out + 1] = "\n"
		out[#out + 1] = { "cybersyn-gui.trains-hidden-layout", id and ctx.comps[id] or "–", id and ctx.icons[id] or "" }
	end
	if hidden.depot then
		out[#out + 1] = "\n"
		out[#out + 1] = { "cybersyn-gui.trains-hidden-depot", values.depot or "–" }
	end
	if hidden.last_refuel then
		out[#out + 1] = "\n"
		out[#out + 1] = { "cybersyn-gui.trains-hidden-refuel" }
	end
	if hidden.fuel then
		out[#out + 1] = "\n"
		out[#out + 1] = { "cybersyn-gui.trains-hidden-fuel" }
	end
	return out
end

--- Column widths for the content width, the hidden set and the detail pane (logic.train_widths), kept while those
--- three stay the same.
--- @param player_data PlayerData
--- @param hidden {[string]: true}
--- @return table
local function widths_for(player_data, hidden)
	local layout = player_data.layout
	local content_width = layout and layout.content_width or (sizing.MAX_WIDTH - sizing.OUTER_WIDTH)
	local pane = player_data.selected_train ~= nil
	local mask = 0
	for i, c in ipairs(COLUMNS) do
		if hidden[c] then mask = mask + 2 ^ i end
	end
	local key = mask * 2 ^ 20 + content_width * 2 + (pane and 1 or 0)
	local state = util.gui_state(player_data, HEADER)
	local cached = state.widths
	if cached and cached.key == key then return cached end
	local w = logic.train_widths(content_width, hidden, pane)
	local parts = { w.cw }
	for i, c in ipairs(COLUMNS) do parts[i + 1] = w[c] or 0 end
	parts[#parts + 1] = tostring(w.group_comps) .. tostring(w.group_bypass)
	w.sig = table.concat(parts, "|")
	w.key = key
	w.hidden_mask = mask
	state.widths = w
	return w
end

--- @param player_data PlayerData
--- @param w table
--- @param hidden {[string]: true}
--- @param values table the hidden columns' shared values
--- @param ctx table
--- @param tip_sig string
--- @param column string
--- @param ascending boolean
--- @return boolean changed the hidden set changed (rows are built again; a width change alone is written in place)
local function sync_header(player_data, w, hidden, values, ctx, tip_sig, column, ascending)
	local header = player_data.refs[HEADER]
	if not (header and header.valid) then return false end
	local state = util.gui_state(player_data, HEADER)
	-- A rebuilt window has a new header built without widths.
	if state.index ~= header.index then
		state.hidden, state.wsig, state.sort, state.tip, state.index = nil, nil, nil, nil, header.index
	end
	local changed = state.hidden ~= w.hidden_mask
	local resized = state.wsig ~= w.sig
	if changed or resized then
		for _, cell in ipairs(header.children) do
			local c = cell.tags.column
			cell.visible = w[c] ~= nil
			if w[c] then cell.style.width = w[c] end
		end
		state.hidden, state.wsig = w.hidden_mask, w.sig
	end
	local sig = column .. (ascending and "+" or "-")
	if changed or resized or state.sort ~= sig then
		for _, cell in ipairs(header.children) do util.sync_sort_header(cell, column, ascending) end
		state.sort = sig
	end
	if state.tip ~= tip_sig then
		local tooltip = status_header_tooltip(hidden, values, ctx)
		for _, cell in ipairs(header.children) do
			if cell.tags.column == "train_status" then cell.children[1].tooltip = tooltip end
		end
		state.tip = tip_sig
	end
	return changed
end

-- ---------------------------------------------------------------- detail pane

--- The front stock of a train Cybersyn knows whose entity is valid.
--- @param id uint
--- @return LuaEntity?
local function front_stock_of(id)
	local train = storage.trains[id]
	local entity = train and train.entity
	if not (entity and entity.valid) then return nil end
	return entity.front_stock
end

--- The pane is as tall as the column header and the rows the window fits, so its bottom edge is the last row's.
--- @param player_data PlayerData
--- @return int
local function pane_height(player_data)
	local layout = player_data.layout
	local rows = layout and layout.rows_by_tab and layout.rows_by_tab[TAB] or sizing.MIN_ROWS
	return HEADER_HEIGHT + rows * ROW_HEIGHT
end

--- Selects a train for the detail pane (nil, or a train that is gone: none). The pane follows on the next render.
--- @param player_data PlayerData
--- @param id uint?
function trains_tab.select(player_data, id)
	if id and not front_stock_of(id) then id = nil end
	player_data.selected_train = id
	-- A path trace belongs to the train it was drawn for; another selection (or none) removes it.
	extras.on_selection(player_data, "train", id)
	if not id and relative then relative.unmount(player_data) end
end

--- Shows the pane for `selected` (or hides it): caption, height, the player's one camera on the front stock, and the
--- train panel mounted through relative.mount, which relative.tick then refreshes. Writes only what changed.
--- @param player_data PlayerData
--- @param selected uint?
--- @param front LuaEntity? the selected train's front stock
local function sync_pane(player_data, selected, front)
	local refs = player_data.refs
	local pane = refs[PANE]
	if not (pane and pane.valid) then return end
	local state = util.gui_state(player_data, PANE)
	if not (selected and front and relative) then
		if pane.visible then pane.visible = false end
		if player_data.relative_pane_open and relative then relative.unmount(player_data) end
		return
	end
	if state.index ~= pane.index then
		state.height, state.caption, state.camera, state.camera_height, state.body, state.index = nil, nil, nil, nil, nil, pane.index
	end
	local height = pane_height(player_data)
	if state.height ~= height then
		pane.style.height = height
		state.height = height
	end
	if not pane.visible then pane.visible = true end
	if state.caption ~= selected then
		refs[PANE_CAPTION].caption = { "cybersyn-gui.trains-pane-caption", tostring(selected) }
		state.caption = selected
	end
	-- A short window keeps the panel's body readable and shrinks, then drops, the camera.
	local camera_height, body = logic.pane_split(height)
	local flow = refs[PANE_CAMERA_FLOW]
	if flow.visible ~= (camera_height > 0) then flow.visible = camera_height > 0 end
	if camera_height > 0 then
		local camera = flow[CAMERA]
		if not camera then
			camera = flow.add({ type = "camera", name = CAMERA, position = front.position, surface_index = front.surface_index,
				zoom = CAMERA_ZOOM })
			camera.style.width = CAMERA_WIDTH
			state.camera, state.camera_height = nil, nil
		end
		if state.camera_height ~= camera_height then
			camera.style.height = camera_height
			state.camera_height = camera_height
		end
		-- Keyed on the train too: a train split off another keeps its front stock under a new id.
		local unit = front.unit_number
		if state.camera ~= unit or state.camera_train ~= selected then
			camera.surface_index = front.surface_index
			camera.position = front.position
			camera.entity = front
			camera.tooltip = { "cybersyn-gui.trains-pane-camera-tooltip", tostring(selected) }
			state.camera, state.camera_train = unit, selected
		end
	end
	local open = player_data.relative_pane_open
	if not (open and open.id == selected and open.panel and open.panel.valid and state.body == body) then
		state.body = body
		if not relative.mount(player_data, refs[PANE_MOUNT], "train", selected, body) then
			trains_tab.select(player_data, nil)
			pane.visible = false
		end
	end
end

--- @param map_data MapData
--- @param player_data PlayerData
function trains_tab.build(map_data, player_data)
	local refs = player_data.refs
	local list = refs[SCROLL]
	if not (list and list.valid) then return end

	local rows, snapshot, ctx = trains_tab.query(map_data, player_data)
	stations_tab.fix_heights(refs, { TAB .. "_banner", TAB .. "_subheader", HEADER, "manager_trains_subfooter", CHIP_STRIP })
	local selected = player_data.selected_train
	local front = selected and front_stock_of(selected)
	if selected and not front then
		trains_tab.select(player_data, nil)
		selected = nil
	end
	sync_pane(player_data, selected, front)
	selected = player_data.selected_train
	local wrapped = render_chips(player_data, ctx.counts, ctx.hours)
	local alerts = ctx.alerts
	local filter_item = player_data.search_item
	local state = util.gui_state(player_data, SCROLL)
	local grouped = player_data.trains_group_by_depot == true

	-- The sequence of rows the pager pages over: trains, or group rows with the trains of expanded groups.
	local seq
	if grouped then
		-- Members follow the chip rows (recounted once a second), the numbers the filtered trains (once a pass).
		local chips, cache = ctx.chips, ctx.cache
		if not chips.groups then
			local filtering = util.filters_active(util.get_filters(player_data)) or active_chip(player_data) ~= nil
			local names, members = depot_groups(rows, snapshot, filtering)
			chips.groups = { names = names, members = members }
		end
		if not cache.group_stats then cache.group_stats = group_stats(ctx.all) end
		ctx.group_stats = cache.group_stats
		seq = logic.group_rows(chips.groups.names, chips.groups.members, player_data.expanded_depots)
		ctx.members = chips.groups.members
	else
		seq = rows
	end
	local first, last = util.paginate(player_data, TAB, #seq, wrapped and 1 or 0)

	-- Fuel is read for the trains on the page only, again every FUEL_EVERY renders.
	local fuel = state.fuel or {}
	local renders = (state.renders or 0) + 1
	state.renders = renders
	local refresh = renders % FUEL_EVERY == 1
	local new_fuel = {}
	local page = {}
	local profiler = refresh and dev.enabled() and game.create_profiler() or nil
	for i = first, last do
		local tr = grouped and seq[i].train or (not grouped and seq[i]) or nil
		if tr then
			page[#page + 1] = tr
			local f = fuel[tr.id]
			if f == nil or refresh then
				local train = storage.trains[tr.id]
				local entity = train and train.entity
				f = (entity and entity.valid) and read_fuel(entity) or false
			end
			new_fuel[tr.id] = f
		end
	end
	if profiler then
		profiler.stop()
		fuel_profiles[player_data.player_index] = profiler
	end
	state.fuel = new_fuel

	local cache = ctx.cache
	if not cache.hidden then cache.hidden, cache.values = hidden_columns(ctx.all) end
	local hidden, values = {}, cache.values
	for k in pairs(cache.hidden) do hidden[k] = true end
	local fuel_uniform, fuel_value = logic.single_value(page, function(tr) return new_fuel[tr.id] or nil end)
	if fuel_uniform and fuel_value == nil then hidden.fuel = true end
	local w = widths_for(player_data, hidden)
	local tip_parts = {}
	for k in pairs(hidden) do tip_parts[#tip_parts + 1] = k .. "=" .. tostring(values[k]) end
	table.sort(tip_parts)
	-- New widths alone (the pane opened or closed) are written into the built rows by update_row.
	if sync_header(player_data, w, hidden, values, ctx, table.concat(tip_parts, ","), ctx.column, ctx.ascending)
		or state.grouped ~= grouped then
		state.keys = nil
		state.grouped = grouped
	end
	-- Row memos (row_memo), dropped with the sigs when the window closes.
	local cells = state.cells
	if not cells or not state.keys then
		cells = {}
		state.cells = cells
	end
	local budget = { rewrites = REWRITE_ROWS }

	local entries = {}
	if last < first then
		local empty_key
		if not snapshot.tick then
			empty_key = "cybersyn-gui.trains-collecting"
		elseif (util.filters_active(util.get_filters(player_data)) or active_chip(player_data)) and next(snapshot.trains) then
			empty_key = "cybersyn-gui.trains-no-match"
		else
			empty_key = "cybersyn-gui.no-trains"
		end
		entries[1] = {
			key = empty_key,
			build = function()
				return {
					type = "flow",
					style = "ltnm_warning_flow",
					{ type = "label", style = "ltnm_semibold_label", caption = { empty_key } },
				}
			end,
		}
	else
		local expanded = player_data.expanded_depots or {}
		for i = first, last do
			local index = i - first + 1
			local color = index % 2 == 0 and "dark" or "light"
			local item = seq[i]
			local tr = grouped and item.train or (not grouped and item) or nil
			if tr then
				if tr.id == selected then color = "selected" end
				local view = row_view(tr, ctx, alerts, filter_item, new_fuel[tr.id] or nil, w)
				-- No sig: update_row runs for every row and compares the row's own memo cell by cell.
				entries[#entries + 1] = {
					key = view.id,
					build = function()
						cells[view.id] = row_memo(view, color, w)
						return build_row(view, color, w)
					end,
					update = function(elem)
						cells[view.id] = update_row(elem, view, cells[view.id], color, w, budget)
					end,
				}
			else
				-- A group row is the same for as long as the chip count it was made from lives (its members and counts
				-- come from it and the query), so its view and sig are made once per recount, expanded state and widths.
				local is_expanded = expanded[item.group] == true
				local gviews = ctx.chips.gviews
				if not gviews then
					gviews = {}
					ctx.chips.gviews = gviews
				end
				local view = gviews[item.group]
				if not (view and view.expanded == is_expanded) then
					view = group_view(item.group, snapshot, ctx.members[item.group], ctx, is_expanded)
					gviews[item.group] = view
				end
				if view.wsig ~= w.sig then
					view.wsig = w.sig
					view.struct_w = view.struct .. "\1" .. w.sig
					view.key_g = "g\1" .. item.group
				end
				-- The row is rebuilt when what it shows changed; the hover box alone (trains changing state) is
				-- written into the row as it is.
				local key = view.key_g
				entries[#entries + 1] = {
					key = key,
					sig = view.struct_w .. "\2" .. view.tip_sig,
					build = function()
						cells[key] = view.struct_w
						local def = { type = "frame", style = "cybersyn_group_row", style_mods = { height = ROW_HEIGHT },
							tags = { depot_group = item.group }, tooltip = view.tip }
						for k, child in ipairs(group_children(view, w, ctx)) do def[k] = child end
						return util.hoverable(def, SCROLL)
					end,
					update = function(elem)
						if cells[key] == view.struct_w then
							write_group_tip(elem, view.tip)
							return
						end
						cells[key] = view.struct_w
						elem.clear()
						for _, child in ipairs(group_children(view, w, ctx)) do gui.add(elem, child) end
						elem.tooltip = view.tip
					end,
				}
			end
		end
	end

	-- A list built from nothing (the window was just created, it showed "Collecting…" while a reopened window waited
	-- for its first pass, or the columns changed) gets FIRST_BUILD_ROWS more rows per update: 27 rows cost 4-6 ms on
	-- pY 123 in one go. Rows whose content changed are bounded by REWRITE_ROWS in update_row.
	local building = #list.children == 0 or state.placeholder or not state.keys or state.building
	state.building = nil
	if building and last >= first then
		local old, prefix = state.keys, 0
		if old and not state.placeholder then
			while prefix < #old and entries[prefix + 1] and old[prefix + 1] == entries[prefix + 1].key do prefix = prefix + 1 end
		end
		if #entries > prefix + FIRST_BUILD_ROWS then
			for i = #entries, prefix + FIRST_BUILD_ROWS + 1, -1 do entries[i] = nil end
			state.building = true
		end
	end
	local result = util.sync_children(list, entries, state, util.hold_active(player_data, SCROLL))
	state.last_result = result
	state.last_rewrites = REWRITE_ROWS - budget.rewrites
	state.placeholder = (last < first and not snapshot.tick) or nil
	if result == "rebuilt" then
		local live = {}
		for _, key in ipairs(state.keys) do
			if cells[key] then live[key] = cells[key] end
		end
		state.cells = live
	end

	local summary = refs.manager_trains_tab_summary
	if summary and summary.valid then
		local sig = #rows .. "|" .. #ctx.all .. "|" .. tostring(grouped) .. "|" .. summary.index
		if state.summary_sig ~= sig then
			summary.caption = { "cybersyn-gui.trains-summary", format.number(#rows), format.number(#ctx.all) }
			state.summary_sig = sig
		end
	end
end

dev.register_dump(TAB, function(player_data)
	local list = player_data.refs[SCROLL]
	local rows, snapshot, ctx = trains_tab.query(storage, player_data)
	local key_of = {}
	for _, tr in ipairs(rows) do
		key_of[tr.id] = ctx.key_fn(tr)
	end
	local ids, keys, statuses, targets, groups, chips_shown, states, layouts = {}, {}, {}, {}, {}, {}, {}, {}
	for _, row in ipairs(list.children) do
		local id = row.tags.train_id
		if id then
			local n = #ids + 1
			ids[n] = id
			keys[n] = key_of[id]
			local status_flow = row.children[2].children
			statuses[n] = status_flow[1].caption
			targets[n] = status_flow[2].visible and name_cell.button(status_flow[2]).caption or false
			local chip = row.children[6].children[2]
			states[n] = chip.visible and { sprite = chip.sprite, style = chip.style.name, tooltip = chip.tooltip,
				type = chip.type } or false
			local runs = {}
			for _, icon in ipairs(row.children[4].children) do
				runs[#runs + 1] = icon.type == "sprite-button" and { icon.sprite, icon.number or 1 } or icon.caption
			end
			layouts[n] = runs
		elseif row.tags.depot_group then
			local g = { name = row.tags.depot_group, captions = {}, tooltip = row.tooltip }
			for _, child in ipairs(row.children) do
				if child.name == "group_marker" then
					g.marker = { caption = child.caption, tooltip = child.tooltip, type = child.type, style = child.style.name }
				elseif child.name == "group_comps" then
					g.comps = {}
					for _, c in ipairs(child.children) do
						g.comps[#g.comps + 1] = c.type == "sprite-button" and { c.sprite, c.number or 1 } or c.caption
					end
				elseif child.type == "label" and child.style.name == "cybersyn_marker_grey" then
					g.bypassed = child.visible
				elseif child.type == "label" then
					g.captions[#g.captions + 1] = child.caption
				end
			end
			groups[#groups + 1] = g
		end
	end
	local hidden = {}
	local header = player_data.refs[HEADER]
	for _, cell in ipairs(header.children) do
		if not cell.visible then hidden[#hidden + 1] = cell.tags.column end
	end
	local chips = {}
	local flow = player_data.refs[CHIPS]
	if flow and flow.valid then
		for i, chip in ipairs(flow.children) do chips_shown[i] = { chip.tags.trains_chip, chip.toggled, chip.enabled } end
	end
	local all = {}
	for i, tr in ipairs(ctx.all) do all[i] = tr.id end
	local column, ascending = util.get_sort(player_data, TAB, DEFAULT_COLUMN)
	local state = util.gui_state(player_data, SCROLL)
	local status_tip
	for _, cell in ipairs(header.children) do
		if cell.tags.column == "train_status" then status_tip = cell.children[1].tooltip end
	end
	return {
		ids = ids,
		keys = keys,
		statuses = statuses,
		targets = targets,
		states = states,
		layouts = layouts,
		groups = groups,
		hidden = hidden,
		status_tooltip = status_tip,
		column = column,
		ascending = ascending,
		page = player_data.page and player_data.page[TAB],
		total = #rows,
		all = all,
		counts = ctx.counts,
		chip = active_chip(player_data),
		chips = chips_shown,
		grouped = player_data.trains_group_by_depot == true,
		fuel = state.fuel,
		last_result = state.last_result,
		last_rewrites = state.last_rewrites,
		building = state.building == true,
		in_state = (function()
			local out = {}
			for i, row in ipairs(list.children) do
				if row.tags.train_id then out[#out + 1] = row.children[7].caption end
			end
			return out
		end)(),
		summary = player_data.refs.manager_trains_tab_summary.caption,
		selected = player_data.selected_train,
		pane = player_data.refs[PANE].visible,
		pager = player_data.refs[TAB .. "_pager_label"].caption,
		children = #list.children,
		refuel_hours = ctx.hours,
	}
end)

--- Rows that fit, measured as stations_tab.measured_rows does, through the table flow that holds the column header
--- and the rows beside the pane; -1 when a strip has no fixed height or the open pane is taller than the space.
--- @param player_data PlayerData
--- @return int
local function measured_rows(player_data)
	local refs = player_data.refs
	local list, content, body, tbl, pane = refs[SCROLL], refs[CONTENT], refs[BODY], refs[TABLE], refs[PANE]
	if not (list and list.valid and list.visible and content and content.valid) then return 0 end
	local avail = content.style.maximal_height
	if not avail or avail <= 0 then return 0 end
	local function fixed(elem)
		local style = elem.style
		local h = style.maximal_height
		if not h or h ~= style.minimal_height then return nil end
		return h
	end
	for _, container in ipairs({ content, tbl }) do
		for _, child in ipairs(container.children) do
			if child ~= list and child ~= body and child.visible then
				local h = fixed(child)
				if not h then return -1 end
				avail = avail - h
			end
		end
	end
	if pane.visible then
		local h = fixed(pane)
		if not h or h > avail + HEADER_HEIGHT then return -1 end
	end
	-- Every shown row counts; rows past the space make the result negative (over-rendering, see stations).
	local n, used = 0, 0
	for _, row in ipairs(list.children) do
		if row.visible then
			local h = fixed(row)
			if not h or h <= 0 then return -1 end
			used = used + h
			n = n + 1
		end
	end
	if used > avail then return -n end
	return n
end

dev.register_rows(TAB, measured_rows)

trains_tab.handle = {}

--- @param e {player_index: uint}
function trains_tab.wrapper(e, handler)
	local player = game.get_player(e.player_index)
	if not player then return end
	local player_data = storage.manager.players[e.player_index]
	handler(player, player_data, player_data.refs, e)
end

--- The pane's × button.
function trains_tab.handle.on_pane_close(player, player_data)
	trains_tab.select(player_data, nil)
	util.rerender(player, player_data)
	util.overlay_closed(player, player_data)
end

--- Whether the detail pane shows: a train selected on the Trains tab, no drill-down over it (manager.top_overlay).
--- @param player_data PlayerData
--- @return boolean
function trains_tab.pane_shown(player_data)
	if not (player_data.selected_train and player_data.selected_tab == TAB) or player_data.item_view then return false end
	local pane = player_data.refs and player_data.refs[PANE]
	return pane ~= nil and pane.valid and pane.visible
end

--- Escape while the Trains tab shows the pane: the pane closes (manager.manager_closed_by_game).
--- @param player_data PlayerData
--- @return uint? train the train that was selected, nil when no pane showed
function trains_tab.close_pane(player_data)
	local id = player_data.selected_train
	-- Under the item drill-down the pane is hidden; Escape belongs to the drill-down then.
	if not (id and player_data.selected_tab == TAB) or player_data.item_view then return nil end
	local pane = player_data.refs and player_data.refs[PANE]
	if not (pane and pane.valid and pane.visible) then return nil end
	trains_tab.select(player_data, nil)
	return id
end

--- relative.tick found the pane's train gone.
--- @param player LuaPlayer
--- @param player_data PlayerData
function trains_tab.on_pane_gone(player, player_data)
	trains_tab.select(player_data, nil)
	util.rerender(player, player_data)
end

--- A left click on a train row that no element handler took (scripts/main.lua): anywhere on the row but its links
--- and item slots selects the train, a click on the selected row closes the pane.
--- @param e EventData.on_gui_click
--- @return boolean handled
function trains_tab.on_row_click(e)
	local elem = e.element
	if not (elem and elem.valid) or e.button ~= defines.mouse_button_type.left then return false end
	local manager_data = storage.manager
	local player_data = manager_data and manager_data.players[e.player_index]
	if not (player_data and player_data.is_manager_open and player_data.selected_tab == TAB) then return false end
	local list = player_data.refs[SCROLL]
	if not (list and list.valid) then return false end
	local index = list.index
	while true do
		local parent = elem.parent
		if not parent then return false end
		if parent.index == index then
			local id = elem.tags.train_id
			if not id then return false end
			trains_tab.select(player_data, player_data.selected_train ~= id and id or nil)
			local player = game.get_player(e.player_index)
			util.rerender(player, player_data)
			if player_data.selected_train then
				util.overlay_opened(player, player_data)
			else
				util.overlay_closed(player, player_data)
			end
			return true
		end
		elem = parent
	end
end

--- The state icon: a click selects the row like any other cell, a shift-click shows the train on the map.
--- @param e EventData.on_gui_click
function trains_tab.handle.on_state_click(player, player_data, refs, e)
	if e.shift and e.button == defines.mouse_button_type.left then
		util.handle_link_click(player, player_data, e, "train", e.element.tags.state_train)
		return
	end
	trains_tab.on_row_click(e)
end

--- @param player_data PlayerData
--- @param chip string?
function trains_tab.set_chip(player_data, chip)
	if chip == "all" or chip == active_chip(player_data) then chip = nil end
	player_data.trains_chip = chip
	util.reset_page(player_data, TAB)
end

--- @param e EventData.on_gui_click
function trains_tab.handle.on_chip_click(player, player_data, refs, e)
	trains_tab.set_chip(player_data, e.element.tags.trains_chip)
	util.rerender(player, player_data)
end

--- @param e EventData.on_gui_click
function trains_tab.handle.on_group_by_depot(player, player_data, refs, e)
	player_data.trains_group_by_depot = not player_data.trains_group_by_depot or nil
	util.reset_page(player_data, TAB)
	util.rerender(player, player_data)
end

--- @param e EventData.on_gui_click
function trains_tab.handle.on_group_toggle(player, player_data, refs, e)
	local name = e.element.tags.depot_group
	if not name then return end
	util.touch_hover(e)
	local expanded = player_data.expanded_depots or {}
	expanded[name] = not expanded[name] or nil
	player_data.expanded_depots = expanded
	util.rerender(player, player_data)
end

---@param player LuaPlayer
---@param player_data PlayerData
function trains_tab.handle.on_trains_tab_selected(player, player_data)
	player_data.selected_tab = TAB
end

---@param player LuaPlayer
---@param player_data PlayerData
---@param refs table<string, LuaGuiElement>
---@param e EventData.on_gui_checked_state_changed
function trains_tab.handle.on_trains_sort_checkbox_changed(player, player_data, refs, e)
	local element = e.element
	if not element or not element.tags then return end
	local column = element.tags.column
	if not column then return end
	util.set_sort(player_data, TAB, column)
	util.rerender(player, player_data)
end

gui.add_handlers(trains_tab.handle, trains_tab.wrapper)

-- ---------------------------------------------------------------- dev interface: the detail pane

--- What the pane shows: selection, visibility and size, the camera, the mounted panel's sections (as relative_dump
--- shows them), the table's header cells and the rows' styles.
--- @param pi uint
--- @return table
local function pane_dump(pi)
	local pd = storage.manager.players[pi]
	local refs = pd.refs
	local pane = refs[PANE]
	local open = pd.relative_pane_open
	local out = {
		selected = pd.selected_train,
		visible = pane.visible,
		open = open and { kind = open.kind, id = open.id } or nil,
		width = pane.style.minimal_width,
		height = pane.style.minimal_height,
		gap = refs[BODY].style.horizontal_spacing,
		pane_rows_height = pane_height(pd),
	}
	out.fixed = logic.PANE_FIXED
	out.camera_gap = logic.PANE_CAMERA_GAP
	local camera = refs[PANE_CAMERA_FLOW][CAMERA]
	if camera then
		local front = pd.selected_train and front_stock_of(pd.selected_train)
		out.camera = {
			visible = refs[PANE_CAMERA_FLOW].visible and camera.visible,
			entity = camera.entity and camera.entity.valid and camera.entity.unit_number or nil,
			front = front and front.unit_number or nil,
			zoom = camera.zoom,
			width = camera.style.minimal_width,
			height = camera.style.minimal_height,
			surface = camera.surface_index,
			index = camera.index,
		}
	end
	if open and open.panel and open.panel.valid and pd.relative_pane then
		out.panel = relative.view(open.panel, pd.relative_pane)
		out.panel_tags = open.panel.tags
		out.body_max = open.panel.scroll.style.maximal_height
		local buttons = open.panel.footer.buttons.children[1]
		out.open_manager = buttons and buttons.open_manager and buttons.open_manager.visible or false
		out.panel_subheader = open.panel.subheader.visible
		out.panel_banner = open.panel.banner.visible
	end
	local pending = storage.manager.pane_escapes
	out.escape_pending = pending and pending[pi] ~= nil or false
	local header = refs[HEADER]
	local cells, total, shown = {}, 0, 0
	for _, cell in ipairs(header.children) do
		if cell.visible then
			local w = cell.style.minimal_width
			cells[#cells + 1] = { cell.tags.column, w }
			total = total + (w or 0)
			shown = shown + 1
		end
	end
	out.columns = cells
	-- Cells, the 8 px gaps between them and the row's 4 + 4 px padding (the header's 6 + 6 sits in the same 20).
	out.columns_total = total + math.max(shown - 1, 0) * 8 + 20
	local state = util.gui_state(pd, HEADER)
	out.table_width = tonumber(string.match(state.wsig or "", "^(%d+)"))
	local w = state.widths
	if w then
		local dropped = {}
		for k in pairs(w.dropped) do dropped[#dropped + 1] = k end
		table.sort(dropped)
		out.dropped = dropped
		out.group = { name = w.group_name, comps = w.group_comps, bypass = w.group_bypass }
	end
	out.rows = {}
	for i, row in ipairs(refs[SCROLL].children) do
		local id = row.tags.train_id
		local ship = id and row.children[10].children[1]
		local visible = {}
		if id then
			for k, cell in ipairs(row.children) do
				if cell.visible then visible[#visible + 1] = COLUMNS[k] end
			end
		end
		out.rows[i] = { id = id, style = row.style.name, height = row.style.minimal_height,
			slots = ship and ship.column_count or nil, shipment_width = id and row.children[10].style.minimal_width or nil,
			cells = id and table.concat(visible, ",") or nil }
		if id then out.rows[i].shipment_visible = row.children[10].visible end
	end
	return out
end

dev.add("pane_dump", pane_dump)

--- Selects a train as a row click would (nil or an unknown id: none) and renders.
dev.add("select_train", function(pi, id)
	local pd = storage.manager.players[pi]
	local player = game.get_player(pi)
	trains_tab.select(pd, id)
	util.rerender(player, pd)
	util.overlay_opened(player, pd)
	return pane_dump(pi)
end)

dev.add("deselect_train", function(pi)
	local pd = storage.manager.players[pi]
	local player = game.get_player(pi)
	trains_tab.select(pd, nil)
	util.rerender(player, pd)
	util.overlay_closed(player, pd)
	return pane_dump(pi)
end)

--- A left click on child `path` (indices below the row) of the Trains row `row` as scripts/main.lua handles it: the
--- element's own handler first, the row selection when there is none. Returns "handler", "row" or false.
dev.add("row_click", function(pi, row, path, mods)
	local pd = storage.manager.players[pi]
	local elem = pd.refs[SCROLL].children[row]
	if not elem then return "no row " .. tostring(row) end
	for _, i in ipairs(path or {}) do
		elem = elem.children[i]
		if not elem then return "no child " .. serpent.line(path) end
	end
	mods = mods or {}
	local e = {
		name = defines.events.on_gui_click, element = elem, player_index = pi, tick = game.tick,
		button = mods.right and defines.mouse_button_type.right or defines.mouse_button_type.left,
		shift = mods.shift == true, control = mods.control == true, alt = mods.alt == true,
	}
	if gui.dispatch(e) then return "handler" end
	return trains_tab.on_row_click(e) and "row" or false
end)

--- `n` refreshes of the pane's train panel, profiled (relative_refresh_ms for the mounted instance).
dev.add("pane_refresh_ms", function(pi, n, rebuild)
	local pd = storage.manager.players[pi]
	local open = pd.relative_pane_open
	if not (open and open.panel and open.panel.valid) then return "no pane open" end
	n = n or 1
	local total = game.create_profiler()
	for _ = 1, n do
		if rebuild then pd.relative_pane.sigs = {} end
		relative.render(pd, pd.relative_pane, open.panel)
	end
	total.stop()
	local avg = game.create_profiler()
	avg.stop()
	avg.add(total)
	avg.divide(n)
	return { "", "n=", n, " total ", total, " avg ", avg }
end)

if dev.enabled() and not remote.interfaces["cybersyn-manager-dev-trains"] then
	remote.add_interface("cybersyn-manager-dev-trains", {
		--- Toggles a chip as a click would ("all" clears); returns the active chip or "all".
		set_chip = function(pi, chip)
			local player = game.get_player(pi)
			local player_data = storage.manager.players[pi]
			player_data.trains_chip = nil
			trains_tab.set_chip(player_data, chip or nil)
			util.rerender(player, player_data)
			return active_chip(player_data) or "all"
		end,
		set_grouped = function(pi, on, expanded)
			local player = game.get_player(pi)
			local player_data = storage.manager.players[pi]
			player_data.trains_group_by_depot = on or nil
			player_data.expanded_depots = expanded
			util.reset_page(player_data, TAB)
			util.rerender(player, player_data)
		end,
		--- Profiler of the last fuel refresh (the page's locomotives), and the renders since.
		fuel_profile = function(pi)
			local state = util.gui_state(storage.manager.players[pi], SCROLL)
			return { "", "fuel read ", fuel_profiles[pi] or "none", " renders ", tostring(state.renders) }
		end,
		composition = function(layout_id)
			local layout = storage.layouts[layout_id]
			return layout and logic.composition(layout) or nil
		end,
		--- Carriage-class runs of a layout as the Composition column draws them: {{sprite, n}, ...}.
		runs = function(layout_id)
			local layout = storage.layouts[layout_id]
			if not layout then return nil end
			local out = {}
			for i, r in ipairs(logic.composition_runs(layout)) do out[i] = { logic.CLASS_SPRITE[r.class], r.n } end
			return out
		end,
		--- Every sprite the tab draws, by what it stands for, with helpers.is_valid_sprite_path of each.
		sprites = function()
			local out = {}
			local function add(kind, name, sprite)
				out[#out + 1] = { kind = kind, name = name, sprite = sprite, valid = helpers.is_valid_sprite_path(sprite) }
			end
			for name in pairs(defines.train_state) do add("state", name, logic.state_chip(name, 0, 0).sprite) end
			add("state", "residue", logic.state_chip("wait_station", 0, 0, "residue").sprite)
			add("state", "refuel", logic.state_chip("wait_station", 0, 0, "refuel").sprite)
			for _, b in ipairs(logic.STATE_BUCKETS) do add("bucket", b, logic.bucket_chip(b).sprite) end
			for class, sprite in pairs(logic.CLASS_SPRITE) do add("class", tostring(class), sprite) end
			for key, sprite in pairs(CHIP_ICON) do add("chip", key, sprite) end
			return out
		end,
		--- The chips the subheader shows, and those wrapped onto the strip.
		chip_lines = function(pi)
			local refs = storage.manager.players[pi].refs
			local function keys(flow)
				local out = {}
				if flow and flow.valid then
					for i, c in ipairs(flow.children) do out[i] = c.tags.trains_chip end
				end
				return out
			end
			local strip = refs[CHIP_STRIP]
			return { line = keys(refs[CHIPS]), wrapped = keys(refs[CHIPS_WRAPPED]), strip = strip and strip.visible or false }
		end,
	})
end

return trains_tab
