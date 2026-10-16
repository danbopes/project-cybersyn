-- Trains tab (PLAN3 §4.7): chips in the tab's subheader, one 36 px row per train (id link, status with the stop as a
-- link, network, composition, depot, state chip, time in state, last refuel, fuel, shipment), columns whose value is
-- the same for every listed train hidden, optionally grouped by depot name. Exactly as many rows as the window fits.

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

local trains_tab = {}

--- @class PlayerData
--- @field trains_chip string? the toggled Trains chip (TRAIN_CHIPS), "parked" from the Overview's Fleet tile
--- @field trains_group_by_depot true? rows grouped by depot name
--- @field expanded_depots {[string]: true}? depot groups showing their trains

local TAB = "trains_tab"
-- The row list; a flow since phase 4, the name kept for manager.refresh_sort_headers.
local SCROLL = "manager_trains_tab_scroll_pane"
local HEADER = "manager_trains_header"
local CHIPS = "manager_trains_chip_flow"
local DEFAULT_COLUMN = "train_id"
local ROW_HEIGHT = sizing.ROW_HEIGHT[TAB]
local SLOT = 32
local REFUELERS = "\1refuelers"
-- Fuel is read from the locomotives of the rows on the page, again every this many renders.
local FUEL_EVERY = 5
local FIRST_BUILD_ROWS = 14

local STATE_NAME = {}
for name, value in pairs(defines.train_state) do STATE_NAME[value] = name end

local COLUMNS = { "train_id", "train_status", "network", "layout", "depot", "state", "time_in_state", "last_refuel",
	"fuel", "shipment" }
local SORTABLE = { train_id = true, train_status = true, network = true, layout = true, depot = true, state = true,
	time_in_state = true, last_refuel = true, shipment = true }
local RIGHT = { train_id = true, time_in_state = true, last_refuel = true, fuel = true }
-- {key, width, min = shrinkable down to}; the status takes the rest (logic.allocate).
local WIDTHS = {
	{ "train_id", 52 },
	{ "train_status", 0 },
	{ "network", 96, min = 64 },
	{ "layout", 112, min = 80 },
	{ "depot", 150, min = 100 },
	{ "state", 128, min = 100 },
	{ "time_in_state", 72 },
	{ "last_refuel", 80 },
	{ "fuel", 52 },
	{ "shipment", 6 * SLOT, min = 3 * SLOT },
}
local STATUS_MIN = 260
local NETWORK_COLUMNS = 3

local TRAIN_CHIPS = { "all", "parked", "to_p", "loading", "to_r", "unloading", "returning", "refuel", "interrupt",
	"not_refuelled", "in_group", "trouble" }
-- Widths of the chips with their names and a one-digit count (English, measured at UI scale 1.0); each further digit
-- adds DIGIT_WIDTH. The group toggle takes 32 more.
local CHIP_WIDTH = {
	all = 46, parked = 75, to_p = 98, loading = 78, to_r = 106, unloading = 92, returning = 92, refuel = 95,
	interrupt = 99, not_refuelled = 145, in_group = 123, trouble = 91,
}
local DIGIT_WIDTH = 8

--- @param counts {[string]: int}
--- @return int
local function full_chips_width(counts)
	local w = 32
	for _, key in ipairs(TRAIN_CHIPS) do
		w = w + CHIP_WIDTH[key] + 4 + DIGIT_WIDTH * (#format.number(counts[key] or 0) - 1)
	end
	return w
end

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
			name = "manager_trains_tab_content_frame",
			type = "frame",
			style = "ltnm_main_content_frame",
			direction = "vertical",
			children = {
				header,
				{ name = SCROLL, type = "flow", direction = "vertical", style = "cybersyn_list_rows" },
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

--- Rich-name parts for names that are not station records (depots, refuelers): parsed per render, a few per page.
local function parts_of(name)
	if not name then return nil end
	return rich_name.parse(name)
end

--- @param map_data MapData
--- @return {[uint]: string} sort keys (carriage count first, so short trains group together)
--- @return {[uint]: string} composition strings
--- @return {[uint]: string} rich-text icons per car
local function layout_strings(map_data)
	local keys, comps, icons = {}, {}, {}
	for id, layout in pairs(map_data.layouts) do
		local raw = table.concat(layout, "")
		keys[id] = string.format("%03d", #layout) .. raw
		comps[id] = logic.composition(layout)
		icons[id] = raw:gsub("0", "[item=locomotive]"):gsub("1", "[item=cargo-wagon]"):gsub("2", "[item=fluid-wagon]")
	end
	return keys, comps, icons
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
		return function(tr) return tr.state and STATE_NAME[tr.state] or nil end
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

--- Counts one train into the chip counts and says whether it belongs to the chip `wanted` (nil = all).
--- @param tr SnapshotTrain
--- @param counts {[string]: int}
--- @param wanted string?
--- @param now uint
--- @param hours number
--- @param to_refuelers table?
--- @return boolean
local function count_train(tr, counts, wanted, now, hours, to_refuelers)
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
	if has_refueler(tr, to_refuelers) and logic.not_refuelled(now, tr.refuel_tick, hours) then
		counts.not_refuelled = counts.not_refuelled + 1
		if wanted == "not_refuelled" then member = true end
	end
	if logic.in_trouble(tr.state and STATE_NAME[tr.state], now - (tr.state_since or now)) then
		counts.trouble = counts.trouble + 1
		if wanted == "trouble" then member = true end
	end
	return member
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
	local layout_keys, comps, icons = layout_strings(map_data)
	local key_fn = key_fn_for(column, names, layout_keys)
	local qsig = table.concat({
		tostring(snapshot.trains_version), tostring(snapshot.tick), f.terms and table.concat(f.terms, " ") or "",
		f.item or "", f.network or "", f.mask, f.surface or "", column, ascending and "+" or "-",
	}, "\1")
	local cache = player_data.trains_query
	if not (cache and cache.sig == qsig) then
		local all = {}
		for _, tr in pairs(snapshot.trains) do
			if util.train_passes(tr, f) then all[#all + 1] = tr end
		end
		util.sort_by(all, key_fn, ascending, train_id_of)
		cache = { sig = qsig, all = all }
		player_data.trains_query = cache
	end
	local now = game.tick
	local hours = refuel_hours(player_data)
	local to_refuelers = storage.to_refuelers
	local wanted = active_chip(player_data)
	-- Trouble and refuel age move with time, so the chips are counted again once a second, not on every render.
	local csig = tostring(wanted) .. "\1" .. hours .. "\1" .. math.floor(now / 60)
	local chips = cache.chips
	if not (chips and chips.sig == csig) then
		local counts = { all = #cache.all }
		for _, key in ipairs(TRAIN_CHIPS) do if key ~= "all" then counts[key] = 0 end end
		local rows = {}
		for _, tr in ipairs(cache.all) do
			if count_train(tr, counts, wanted, now, hours, to_refuelers) then rows[#rows + 1] = tr end
		end
		chips = { sig = csig, counts = counts, rows = rows }
		cache.chips = chips
	end
	return chips.rows, snapshot, {
		names = names, layout_keys = layout_keys, comps = comps, icons = icons, key_fn = key_fn,
		sprite_of = new_sprite_cache(), counts = chips.counts, all = cache.all, hours = hours, now = now, column = column,
		ascending = ascending, to_refuelers = to_refuelers, cache = cache,
	}
end

--- @param train_entity LuaTrain
--- @return LuaEntity?
local function front_locomotive(train_entity)
	local locomotives = train_entity.locomotives
	return locomotives.front_movers[1] or locomotives.back_movers[1]
end

-- ---------------------------------------------------------------- hidden columns

--- Network, layout, depot and last refuel are hidden when every listed train shares one value; fuel when every
--- train on the page does (an electric fleet reads nil everywhere).
--- @param all SnapshotTrain[]
--- @return {[string]: true} hidden
--- @return table values the shared value per hidden column
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
			values[column] = value
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

--- @param entries {sprite: string, number: int?}[]
local function network_children(entries)
	local children = {}
	for i, entry in ipairs(entries) do
		children[i] = {
			type = "sprite-button",
			style = "cybersyn_slot_32_default",
			ignored_by_interaction = true,
			sprite = entry.sprite,
			number = entry.number,
		}
	end
	return children
end

--- @param tr SnapshotTrain
--- @param filter_item string?
--- @param capacity int
--- @return string
local function shipment_sig(tr, filter_item, capacity)
	local parts = { tostring(capacity) }
	for i, item in ipairs(tr.manifest) do
		parts[i + 1] = item.hash .. "=" .. item.count
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
			tags = { item_hash = hash },
			handler = { [defines.events.on_gui_click] = trains_tab.handle.on_trains_item_click },
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

--- Everything a row shows, for the trains on the page.
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
	local capacity = math.floor(w.shipment / SLOT)
	local now = ctx.now
	local state = tr.state and STATE_NAME[tr.state]
	local in_state = now - (tr.state_since or now)
	local residue = tr.status == STATUS_D and next(tr.manifest_hashes) ~= nil
	local chip, chip_style = logic.state_chip(state, in_state, residue)
	local refuel_caption = logic.age_caption(now, tr.refuel_tick, util.short_duration)
	local view = {
		id = tr.id,
		tr = tr,
		status = status_caption(tr),
		target_kind = kind ~= "depot" and kind or nil,
		target_id = kind ~= "depot" and id or nil,
		target_name = target_name,
		target_parts = target_parts or parts_of(target_name),
		cargo = cargo_caption(tr),
		alert = alerts[tr.id],
		net = net,
		net_sig = net_sig,
		layout = tr.layout_id and ctx.comps[tr.layout_id] or "",
		layout_icons = tr.layout_id and ctx.icons[tr.layout_id] or "",
		depot_id = tr.depot_id,
		depot_name = tr.depot_name,
		chip = chip,
		chip_style = chip_style,
		state = state,
		in_state = util.short_duration(in_state),
		in_state_full = util.format_duration(in_state),
		refuel = refuel_caption,
		refuel_overdue = has_refueler(tr, ctx.to_refuelers) and logic.not_refuelled(now, tr.refuel_tick, ctx.hours),
		fuel = fuel,
		capacity = capacity,
		ship_sig = shipment_sig(tr, filter_item, capacity),
		filter_item = filter_item,
	}
	view.sig = table.concat({
		tostring(tr.status), residue and 1 or 0, kind or "", tostring(id), target_name or "", tostring(view.alert),
		net_sig, view.layout, tostring(tr.depot_id), tr.depot_name, view.ship_sig, tostring(chip), tostring(chip_style),
		view.in_state, tostring(refuel_caption), tostring(view.refuel_overdue), tostring(fuel), tostring(view.cargo and #tr.manifest),
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

--- @param view table
--- @return LocalisedString
local function state_tooltip(view)
	local name = view.chip == "residue" and { "cybersyn-gui.trains-state-residue" }
		or { "cybersyn-gui.trains-state-" .. string.gsub(view.chip or "", "_", "-") }
	return { "", name, "\n", { "cybersyn-gui.trains-in-state-for", view.in_state_full } }
end

--- @param view table
--- @return LocalisedString
local function refuel_label(view)
	return view.refuel or { "cybersyn-gui.never" }
end

local function refuel_style(view)
	if not view.refuel or view.refuel_overdue then return "cybersyn_cell_value_orange" end
	return "cybersyn_cell_value"
end

--- @param view table
--- @param color "light"|"dark"
--- @param w table
--- @param hidden {[string]: true}
--- @return flib.GuiElemDef
local function build_row(view, color, w, hidden)
	local function cell(column, def)
		def.visible = not hidden[column]
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
			mouse_button_filter = { "left" },
			handler = { [defines.events.on_gui_click] = util.handle.link_click },
		}, SCROLL),
		{
			type = "flow",
			style = "cybersyn_cell_flow",
			style_mods = { width = w.train_status },
			{ type = "label", style = "cybersyn_cell_label", caption = view.status },
			(function()
				local def = name_cell.def(view.target_parts, view.target_name or "", { kind = view.target_kind or "station", id = view.target_id },
					math.max(w.train_status - 160, 80), stop_tooltip(view.target_name), SCROLL, true)
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
			type = "label",
			style = "cybersyn_cell_label",
			style_mods = { width = w.layout },
			caption = view.layout,
			tooltip = view.layout_icons,
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
				type = "button",
				style = "cybersyn_small_chip_" .. (view.chip_style or "grey"),
				caption = view.chip and { "cybersyn-gui.trains-state-" .. string.gsub(view.chip, "_", "-") } or "",
				tooltip = view.chip and state_tooltip(view) or nil,
				visible = view.chip ~= nil,
			}, SCROLL),
		},
		{ type = "label", style = "cybersyn_cell_value", style_mods = { width = w.time_in_state }, caption = view.in_state,
			tooltip = { "cybersyn-gui.trains-in-state-for", view.in_state_full } },
		cell("last_refuel", { type = "label", style = refuel_style(view), style_mods = { width = w.last_refuel }, caption = refuel_label(view) }),
		cell("fuel", { type = "label", style = "cybersyn_cell_value", style_mods = { width = w.fuel },
			caption = view.fuel and (view.fuel .. "%") or "" }),
		{
			type = "flow",
			style = "cybersyn_cell_flow",
			style_mods = { width = w.shipment },
			{ type = "table", style = "slot_table", column_count = view.capacity, children = shipment_children(view.tr, view.filter_item, view.capacity) },
		},
	}, SCROLL)
end

--- In-place update of a row whose sig changed. Network and shipment tables are only rebuilt when their own part
--- changed.
--- @param row LuaGuiElement
--- @param view table
--- @param parts {[uint]: {net: string, ship: string}}
--- @param w table
local function update_row(row, view, parts, w)
	local c = row.children
	local part = parts[view.id]
	if not part then
		part = {}
		parts[view.id] = part
	end
	local status = c[2].children
	status[1].caption = view.status
	local target = status[2]
	target.visible = view.target_name ~= nil
	if view.target_name then
		name_cell.update(target, view.target_parts, view.target_name, { kind = view.target_kind, id = view.target_id },
			math.max(w.train_status - 160, 80), stop_tooltip(view.target_name), SCROLL)
	end
	status[3].caption = view.cargo or ""
	status[3].visible = view.cargo ~= nil

	if part.net ~= view.net_sig then
		local net = c[3]
		net.clear()
		gui.add(net, network_children(view.net))
		part.net = view.net_sig
	end
	c[4].caption = view.layout
	c[4].tooltip = view.layout_icons
	name_cell.update(c[5], parts_of(view.depot_name), view.depot_name, { kind = "depot", id = view.depot_id }, w.depot or 150,
		stop_tooltip(view.depot_name), SCROLL)

	local state = c[6].children
	state[1].visible = view.alert ~= nil
	state[1].tooltip = alert_tooltip(view)
	local chip = state[2]
	chip.visible = view.chip ~= nil
	if view.chip then
		local style = "cybersyn_small_chip_" .. view.chip_style
		if chip.style.name ~= style then chip.style = style end
		chip.caption = { "cybersyn-gui.trains-state-" .. string.gsub(view.chip, "_", "-") }
		chip.tooltip = state_tooltip(view)
	end
	c[7].caption = view.in_state
	c[7].tooltip = { "cybersyn-gui.trains-in-state-for", view.in_state_full }
	local refuel_st = refuel_style(view)
	if c[8].style.name ~= refuel_st then
		c[8].style = refuel_st
		c[8].style.width = w.last_refuel
	end
	c[8].caption = refuel_label(view)
	c[9].caption = view.fuel and (view.fuel .. "%") or ""

	if part.ship ~= view.ship_sig then
		local ship = c[10].children[1]
		ship.clear()
		gui.add(ship, shipment_children(view.tr, view.filter_item, view.capacity))
		part.ship = view.ship_sig
	end
end

-- ---------------------------------------------------------------- depot groups

--- Group rows from snapshot.depots_by_name plus a refuelers group; members are the listed trains of each group.
--- @param rows SnapshotTrain[] the trains the chip shows, sorted
--- @param snapshot Snapshot
--- @param filtering boolean a filter or chip is active: groups without listed trains are left out
--- @return string[] names
--- @return {[string]: SnapshotTrain[]} members
local function depot_groups(rows, snapshot, filtering)
	local members = {}
	for _, tr in ipairs(rows) do
		local key = (tr.status == STATUS_TO_F or tr.status == STATUS_F) and REFUELERS or tr.depot_name
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

--- Top compositions of a group, "L<CC>L ×12 · L<C> ×2".
--- @param compositions {[uint]: int}
--- @param comps {[uint]: string}
--- @return string
local function composition_line(compositions, comps)
	local list = {}
	for id, n in pairs(compositions or {}) do list[#list + 1] = { id, n } end
	table.sort(list, function(a, b)
		if a[2] ~= b[2] then return a[2] > b[2] end
		return a[1] < b[1]
	end)
	local out = {}
	for i = 1, math.min(#list, 3) do
		out[i] = (comps[list[i][1]] or "?") .. " ×" .. list[i][2]
	end
	if #list > 3 then out[#out + 1] = "+" .. (#list - 3) end
	return table.concat(out, " · ")
end

--- Trains bound to the group whose depot lets them bypass it (Cybersyn's train.disable_bypass is false).
--- @param members SnapshotTrain[]?
--- @return int
local function bypass_count(members)
	local n = 0
	local trains = storage.trains
	for _, tr in ipairs(members or {}) do
		local train = trains[tr.id]
		if train and not train.disable_bypass then n = n + 1 end
	end
	return n
end

--- @param name string
--- @param snapshot Snapshot
--- @param members SnapshotTrain[]?
--- @param ctx table
--- @param expanded boolean
--- @return table view
local function group_view(name, snapshot, members, ctx, expanded)
	local n = members and #members or 0
	if name == REFUELERS then
		local refuelers = 0
		for _ in pairs(storage.refuelers or {}) do refuelers = refuelers + 1 end
		return {
			key = name, refuelers = true, expanded = expanded, n = n,
			caption = { "cybersyn-gui.trains-group-refuelers", tostring(refuelers) },
			sig = "r|" .. refuelers .. "|" .. n .. "|" .. tostring(expanded),
		}
	end
	local g = (snapshot.depots_by_name or {})[name] or {}
	local limit = g.limit or 0
	local bypass = bypass_count(members)
	local comps = composition_line(g.compositions, ctx.comps)
	return {
		key = name,
		name = name,
		parts = parts_of(name),
		id = g.ids and g.ids[1] or nil,
		depots = g.ids and #g.ids or 0,
		parked = g.parked or 0,
		limit = limit >= collector.UNLIMITED and "∞" or tostring(limit),
		inbound = g.inbound or 0,
		bound = g.trains_bound or 0,
		bypass = bypass,
		comps = comps,
		expanded = expanded,
		n = n,
		sig = table.concat({ name, tostring(g.ids and g.ids[1]), g.ids and #g.ids or 0, g.parked or 0, limit, g.inbound or 0,
			g.trains_bound or 0, bypass, comps, tostring(expanded), n }, "\1"),
	}
end

--- @param view table
--- @return flib.GuiElemDef[]
local function group_children(view, w)
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
			{ type = "label", style = "subheader_caption_label", caption = view.caption },
			{ type = "label", style = "cybersyn_cell_label", caption = { "cybersyn-gui.trains-group-refuelling", tostring(view.n) } },
		}
	end
	local tooltip = { "", "[font=default-semibold]", view.name, "[/font]\n",
		{ "cybersyn-gui.trains-group-tooltip", tostring(view.depots) }, "\n", util.LINK_FOOTER }
	return {
		toggle,
		name_cell.def(view.parts, view.name, { kind = "depot", id = view.id }, math.max(w.group_name, 120), tooltip, SCROLL),
		{ type = "label", style = "cybersyn_cell_value", style_mods = { width = 110 },
			caption = { "cybersyn-gui.trains-group-parked", tostring(view.parked), view.limit },
			tooltip = { "cybersyn-gui.trains-group-parked-tooltip" } },
		{ type = "label", style = "cybersyn_cell_value", style_mods = { width = 100 },
			caption = { "cybersyn-gui.trains-group-inbound", tostring(view.inbound) } },
		{ type = "label", style = "cybersyn_cell_value", style_mods = { width = 100 },
			caption = { "cybersyn-gui.trains-group-bound", tostring(view.bound) },
			tooltip = { "cybersyn-gui.trains-group-bound-tooltip", tostring(view.n) } },
		{
			type = "button",
			style = "cybersyn_small_chip_grey",
			caption = { "cybersyn-gui.trains-group-bypassed" },
			tooltip = { "cybersyn-gui.trains-group-bypassed-tooltip", tostring(view.bypass) },
			visible = view.bypass > 0,
		},
		{ type = "label", style = "cybersyn_subheader_note", caption = view.comps, tooltip = { "cybersyn-gui.trains-group-compositions" } },
	}
end

-- ---------------------------------------------------------------- chips

--- @param key string
--- @param count int
--- @param compact boolean
--- @param hours number
local function chip_caption(key, count, compact, hours)
	local number = format.number(count)
	local locale = string.gsub(key, "_", "-")
	if key == "not_refuelled" then
		local h = (hours % 1 == 0) and tostring(hours) or string.format("%.2g", hours)
		if compact then return { "", { "cybersyn-gui.trains-chip-not-refuelled-short", h }, "  ", number } end
		return { "", { "cybersyn-gui.trains-chip-not-refuelled", h }, "  ", number }
	end
	if compact then return { "", { "cybersyn-gui.trains-chip-" .. locale .. "-short" }, "  ", number } end
	return { "", { "cybersyn-gui.trains-chip-" .. locale }, "  ", number }
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

--- @param player_data PlayerData
--- @param counts {[string]: int}
--- @param hours number
local function render_chips(player_data, counts, hours)
	local flow = chip_flow(player_data)
	if not flow then return end
	local toggle = player_data.refs.manager_trains_group_toggle
	if toggle and toggle.valid then toggle.toggled = player_data.trains_group_by_depot == true end
	local wanted = active_chip(player_data) or "all"
	local compact = logic.chip_mode(chip_space(player_data), full_chips_width(counts)) == "compact"
	local entries = {}
	for i, key in ipairs(TRAIN_CHIPS) do
		local count = counts[key] or 0
		local selected = wanted == key
		local enabled = selected or count > 0
		local locale = string.gsub(key, "_", "-")
		entries[i] = {
			key = key,
			sig = count .. (selected and "+" or "-") .. (compact and "c" or "f") .. hours,
			build = function()
				return {
					type = "button",
					style = "cybersyn_filter_chip",
					caption = chip_caption(key, count, compact, hours),
					tooltip = key ~= "all" and { "cybersyn-gui.trains-chip-" .. locale .. "-tooltip", tostring(hours) } or nil,
					toggled = selected,
					enabled = enabled,
					tags = { trains_chip = key },
					handler = { [defines.events.on_gui_click] = trains_tab.handle.on_chip_click },
				}
			end,
			update = function(elem)
				elem.caption = chip_caption(key, count, compact, hours)
				elem.toggled = selected
				elem.enabled = enabled
				elem.tooltip = key ~= "all" and { "cybersyn-gui.trains-chip-" .. locale .. "-tooltip", tostring(hours) } or nil
			end,
		}
	end
	util.sync_children(flow, entries, util.gui_state(player_data, CHIPS), false)
end

-- ---------------------------------------------------------------- render

--- @param snapshot Snapshot
--- @return {[uint]: int}
local function alerts_by_train(snapshot)
	local out = {}
	for _, alert in ipairs(snapshot.alerts or {}) do
		out[alert.train_id] = alert.kind
	end
	return out
end

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
		out[#out + 1] = { "cybersyn-gui.trains-hidden-network", v and string.gsub(v, "|0*(%d)", " · ") or "–" }
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

--- Column widths for the content width and the hidden set.
--- @param player_data PlayerData
--- @param hidden {[string]: true}
--- @return table
local function widths_for(player_data, hidden)
	local layout = player_data.layout
	local cw = layout and layout.content_width or (sizing.MAX_WIDTH - sizing.OUTER_WIDTH)
	local shown = 0
	for _, c in ipairs(COLUMNS) do
		if not hidden[c] then shown = shown + 1 end
	end
	-- Row padding, frame borders and the gaps between the shown columns.
	local avail = cw - 20 - (shown - 1) * 8
	local w = logic.allocate(WIDTHS, hidden, avail, "train_status", STATUS_MIN)
	w.shipment = math.max(SLOT, math.floor((w.shipment or SLOT) / SLOT) * SLOT)
	w.cw = cw
	w.group_name = math.min(360, cw - 20 - 8 * 7 - 28 - 110 - 100 - 100 - 90 - 220)
	return w
end

--- @param player_data PlayerData
--- @param w table
--- @param hidden {[string]: true}
--- @param tooltip LocalisedString
--- @param tip_sig string
--- @param column string
--- @param ascending boolean
--- @return boolean changed widths or hidden set
local function sync_header(player_data, w, hidden, tooltip, tip_sig, column, ascending)
	local header = player_data.refs[HEADER]
	if not (header and header.valid) then return false end
	local state = util.gui_state(player_data, HEADER)
	-- A rebuilt window has a new header built without widths.
	if state.index ~= header.index then
		state.layout, state.sort, state.tip, state.index = nil, nil, nil, header.index
	end
	local layout_sig = w.cw
	for _, c in ipairs(COLUMNS) do layout_sig = layout_sig .. (hidden[c] and "h" or "") .. "|" .. (w[c] or 0) end
	local changed = state.layout ~= layout_sig
	if changed then
		for _, cell in ipairs(header.children) do
			local c = cell.tags.column
			cell.visible = not hidden[c]
			if w[c] then cell.style.width = w[c] end
		end
		state.layout = layout_sig
	end
	local sig = column .. (ascending and "+" or "-")
	if changed or state.sort ~= sig then
		for _, cell in ipairs(header.children) do util.sync_sort_header(cell, column, ascending) end
		state.sort = sig
	end
	if state.tip ~= tip_sig then
		for _, cell in ipairs(header.children) do
			if cell.tags.column == "train_status" then cell.children[1].tooltip = tooltip end
		end
		state.tip = tip_sig
	end
	return changed
end

--- @param map_data MapData
--- @param player_data PlayerData
function trains_tab.build(map_data, player_data)
	local refs = player_data.refs
	local list = refs[SCROLL]
	if not (list and list.valid) then return end

	local rows, snapshot, ctx = trains_tab.query(map_data, player_data)
	stations_tab.fix_heights(refs, { TAB .. "_banner", TAB .. "_subheader", HEADER, "manager_trains_subfooter" })
	render_chips(player_data, ctx.counts, ctx.hours)
	local alerts = alerts_by_train(snapshot)
	local filter_item = player_data.search_item
	local state = util.gui_state(player_data, SCROLL)
	local grouped = player_data.trains_group_by_depot == true

	-- The sequence of rows the pager pages over: trains, or group rows with the trains of expanded groups.
	local seq
	if grouped then
		local filtering = util.filters_active(util.get_filters(player_data)) or active_chip(player_data) ~= nil
		local names, members = depot_groups(rows, snapshot, filtering)
		seq = logic.group_rows(names, members, player_data.expanded_depots)
		ctx.members = members
	else
		seq = rows
	end
	local first, last = util.paginate(player_data, TAB, #seq)

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
	if sync_header(player_data, w, hidden, status_header_tooltip(hidden, values, ctx), table.concat(tip_parts, ","), ctx.column, ctx.ascending)
		or state.grouped ~= grouped then
		state.keys = nil
		state.parts = nil
		state.grouped = grouped
	end
	local parts = state.parts
	if not parts then
		parts = {}
		state.parts = parts
	end

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
				local view = row_view(tr, ctx, alerts, filter_item, new_fuel[tr.id] or nil, w)
				entries[#entries + 1] = {
					key = view.id,
					sig = view.sig .. "\31" .. color,
					build = function()
						parts[view.id] = { net = view.net_sig, ship = view.ship_sig }
						return build_row(view, color, w, hidden)
					end,
					update = function(elem)
						local style = "cybersyn_train_row_" .. color
						if elem.style.name ~= style then
							-- Assigning a style drops style_mods: the fixed height is written again.
							elem.style = style
							elem.style.height = ROW_HEIGHT
						end
						update_row(elem, view, parts, w)
					end,
				}
			else
				local view = group_view(item.group, snapshot, ctx.members[item.group], ctx, expanded[item.group] == true)
				entries[#entries + 1] = {
					key = "g\1" .. item.group,
					sig = view.sig,
					build = function()
						local def = { type = "frame", style = "cybersyn_group_row", style_mods = { height = ROW_HEIGHT },
							tags = { depot_group = item.group } }
						for k, child in ipairs(group_children(view, w)) do def[k] = child end
						return util.hoverable(def, SCROLL)
					end,
					update = function(elem)
						elem.clear()
						for _, child in ipairs(group_children(view, w)) do gui.add(elem, child) end
					end,
				}
			end
		end
	end

	-- A list built from nothing (the window was just created, or it showed "Collecting…" while a reopened window waited
	-- for its first pass) gets its rows over two updates, and so does a list whose render memo was dropped when the
	-- window closed (every row rewritten): 27 rows cost 4-5 ms on pY 123 in one go.
	if #entries > FIRST_BUILD_ROWS then
		if #list.children == 0 or state.placeholder then
			for i = #entries, FIRST_BUILD_ROWS + 1, -1 do entries[i] = nil end
		elseif not state.sigs or next(state.sigs) == nil then
			-- Without an update a row keeps no sig, so the next render rewrites it.
			for i = FIRST_BUILD_ROWS + 1, #entries do entries[i].update = nil end
		end
	end
	local result = util.sync_children(list, entries, state, util.hold_active(player_data, SCROLL))
	state.last_result = result
	state.placeholder = (last < first and not snapshot.tick) or nil
	if result == "rebuilt" then
		local live = {}
		for _, key in ipairs(state.keys) do
			if parts[key] then live[key] = parts[key] end
		end
		state.parts = live
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
	local ids, keys, statuses, targets, groups, chips_shown, states = {}, {}, {}, {}, {}, {}, {}
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
			states[n] = chip.visible and chip.caption or false
		elseif row.tags.depot_group then
			local g = { name = row.tags.depot_group, captions = {} }
			for _, child in ipairs(row.children) do
				if child.type == "label" then g.captions[#g.captions + 1] = child.caption end
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
		summary = player_data.refs.manager_trains_tab_summary.caption,
		pager = player_data.refs[TAB .. "_pager_label"].caption,
		children = #list.children,
		refuel_hours = ctx.hours,
	}
end)

dev.register_rows(TAB, function(player_data)
	return stations_tab.measured_rows(player_data, "manager_trains_tab_content_frame", SCROLL)
end)

trains_tab.handle = {}

--- @param e {player_index: uint}
function trains_tab.wrapper(e, handler)
	local player = game.get_player(e.player_index)
	if not player then return end
	local player_data = storage.manager.players[e.player_index]
	handler(player, player_data, player_data.refs, e)
end

--- @param e EventData.on_gui_click
function trains_tab.handle.on_trains_item_click(player, player_data, refs, e)
	local hash = e.element.tags.item_hash
	if not hash then return end
	util.item_button_click(player, player_data, e, hash)
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
	})
end

return trains_tab
