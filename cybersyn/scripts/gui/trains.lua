local train_util = require("__flib__.train")
local gui = require("__flib__.gui")
local format = require("__flib__.format")

local constants = require("constants")
local util = require("scripts.gui.util")

local templates = require("scripts.gui.templates")
local collector = require("scripts.gui.collector")
local dev = require("scripts.gui.dev")

local trains_tab = {}

local TAB = "trains_tab"
local SCROLL = "manager_trains_tab_scroll_pane"
local DEFAULT_COLUMN = "train_id"
local SHIPMENT_COLUMNS = 6
local NETWORK_COLUMNS = 3

-- The total matches the Stations tab so the window keeps its width when switching tabs; the old 420 px network
-- column is split into status and network.
local widths = {
	trains = {
		train_id = 60,
		train_status = 334,
		network = 140,
		layout = 200,
		depot = 160,
		shipment = 36 * SHIPMENT_COLUMNS,
	},
}

local SORT_COLUMNS = { "train_id", "train_status", "network", "layout", "depot", "shipment" }

function trains_tab.create()
	local header = {
		type = "frame",
		style = "ltnm_table_toolbar_frame",
	}
	for i, column in ipairs(SORT_COLUMNS) do
		header[i] = templates.sort_checkbox(widths, "trains", column, column == DEFAULT_COLUMN,
			{ "cybersyn-gui.trains-sort-" .. string.gsub(column, "_", "-") }, false,
			trains_tab.handle.on_trains_sort_checkbox_changed)
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
				{
					name = SCROLL,
					type = "scroll-pane",
					style = "ltnm_table_scroll_pane",
					style_mods = { vertically_stretchable = true },
				},
				{
					type = "frame",
					style = "ltnm_subfooter_frame",
					{
						name = "manager_trains_tab_summary",
						type = "label",
						style = "ltnm_squashable_semibold_label",
						tooltip = { "cybersyn-gui.trains-sum-tooltip" },
					},
					{ type = "empty-widget", style = "flib_horizontal_pusher" },
					templates.pager(TAB, util.handle.pager_click),
				},
			},
		},
	}
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

--- Per-build name lookups. Station names come from the snapshot; refueler names cost an API call, so they are
--- resolved lazily and only for trains that are actually refuelling.
--- @param snapshot Snapshot
local function new_name_cache(snapshot)
	local refuelers = {}
	local stations = snapshot.stations
	--- @param tr SnapshotTrain
	--- @return string? name
	--- @return string? name_lower
	return function(tr, kind, id)
		if kind == "depot" then
			return tr.depot_name, string.lower(tr.depot_name)
		elseif kind == "station" then
			local st = id and stations[id]
			if st then return st.name, st.name_lower end
			local station = id and storage.stations[id]
			local stop = station and station.entity_stop
			if stop and stop.valid then
				local name = stop.backer_name
				return name, string.lower(name)
			end
		elseif kind == "refueler" and id then
			local cached = refuelers[id]
			if cached == nil then
				local refueler = storage.refuelers[id]
				local stop = refueler and refueler.entity_stop
				cached = (stop and stop.valid) and stop.backer_name or false
				refuelers[id] = cached
			end
			if cached then return cached, string.lower(cached) end
		end
		return nil, nil
	end
end

--- @param map_data MapData
--- @return {[uint]: string} sort keys (carriage count first, so short trains group together)
--- @return {[uint]: string} rich-text captions
local function layout_strings(map_data)
	local keys, captions = {}, {}
	for id, layout in pairs(map_data.layouts) do
		local raw = table.concat(layout, "")
		keys[id] = string.format("%03d", #layout) .. raw
		captions[id] = raw:gsub("0", "[item=locomotive]"):gsub("1", "[item=cargo-wagon]"):gsub("2", "[item=fluid-wagon]")
	end
	return keys, captions
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

--- Builds the sort-key function for a column; keys are computed once per row by util.sort_by.
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

--- Filtered and sorted trains, from the snapshot only (plus refueler names for trains that are refuelling).
--- Station-name search terms match the train's depot and its current provider/requester.
--- @param map_data MapData
--- @param player_data PlayerData
--- @return SnapshotTrain[] rows
--- @return Snapshot snapshot
--- @return {names: function, layout_captions: {[uint]: string}, key_fn: function, sprite_of: function}
function trains_tab.query(map_data, player_data)
	local snapshot = collector.get()
	local f = util.get_filters(player_data)
	local names = new_name_cache(snapshot)
	local rows = {}
	for _, tr in pairs(snapshot.trains) do
		if util.train_passes(tr, f) then
			rows[#rows + 1] = tr
		end
	end
	local column, ascending = util.get_sort(player_data, TAB, DEFAULT_COLUMN)
	local layout_keys, layout_captions = layout_strings(map_data)
	local key_fn = key_fn_for(column, names, layout_keys)
	util.sort_by(rows, key_fn, ascending, train_id_of)
	return rows, snapshot, { names = names, layout_captions = layout_captions, key_fn = key_fn, sprite_of = new_sprite_cache() }
end

--- @param train_entity LuaTrain
--- @return LuaEntity?
local function front_locomotive(train_entity)
	local locomotives = train_entity.locomotives
	return locomotives.front_movers[1] or locomotives.back_movers[1]
end

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
		if sprite then
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
			style = "ltnm_small_slot_button_default",
			ignored_by_interaction = true,
			sprite = entry.sprite,
			number = entry.number,
		}
	end
	return children
end

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

--- @param tr SnapshotTrain
--- @param filter_item string?
local function shipment_children(tr, filter_item)
	local children = {}
	for _, hash in ipairs(util.hashes_in_item_order(tr.manifest_hashes)) do
		local sprite, quality, name_tooltip = util.item_sprite_and_tooltip(hash)
		if sprite then
			local count = tr.manifest_hashes[hash]
			children[#children + 1] = util.hoverable({
				type = "sprite-button",
				sprite = sprite,
				quality = quality,
				style = hash == filter_item and "ltnm_selected_small_slot_button_default" or "ltnm_small_slot_button_default",
				mouse_button_filter = { "left", "right" },
				tooltip = { "", name_tooltip, "\n", { "cybersyn-gui.amount", format.number(count) }, "\n", { "cybersyn-gui.item-click-hint" } },
				tags = { item_hash = hash },
				handler = { [defines.events.on_gui_click] = trains_tab.handle.on_trains_item_click },
				{
					type = "label",
					style = "ltnm_label_signal_count",
					ignored_by_interaction = true,
					caption = format_signal_count(count),
				},
			}, SCROLL)
		end
	end
	return children
end

--- Everything a row shows, computed once per render for the trains on the visible page.
--- @class TrainRowView
--- @field id uint
--- @field status LocalisedString
--- @field target_kind string?
--- @field target_id uint?
--- @field target_name string?
--- @field alert int?
--- @field net {sprite: string, number: int?}[]
--- @field net_sig string
--- @field layout string
--- @field depot_id uint?
--- @field depot_name string
--- @field ship_sig string
--- @field tr SnapshotTrain
--- @field filter_item string?
--- @field sig string

--- @param tr SnapshotTrain
--- @param ctx table
--- @param alerts {[uint]: int}
--- @param filter_item string?
--- @return TrainRowView
local function row_view(tr, ctx, alerts, filter_item)
	local kind, id = target_of(tr)
	local target_name = kind and kind ~= "depot" and ctx.names(tr, kind, id) or nil
	local net, net_sig = network_entries(tr, ctx.sprite_of)
	local ship_sig = shipment_sig(tr, filter_item)
	local layout = tr.layout_id and ctx.layout_captions[tr.layout_id] or ""
	local alert = alerts[tr.id]
	local residue = (tr.status == STATUS_D and next(tr.manifest_hashes)) and 1 or 0
	local view = {
		id = tr.id,
		status = status_caption(tr),
		target_kind = kind ~= "depot" and kind or nil,
		target_id = kind ~= "depot" and id or nil,
		target_name = target_name,
		alert = alert,
		net = net,
		net_sig = net_sig,
		layout = layout,
		depot_id = tr.depot_id,
		depot_name = tr.depot_name,
		ship_sig = ship_sig,
		tr = tr,
		filter_item = filter_item,
	}
	view.sig = table.concat({
		tostring(tr.status), residue, kind or "", tostring(id), target_name or "", tostring(alert),
		net_sig, layout, tostring(tr.depot_id), tr.depot_name, ship_sig,
	}, "\31")
	return view
end

--- @param view TrainRowView
local function alert_caption(view)
	if not view.alert then return "" end
	local key = ALERT_MESSAGE[view.alert] or "cybersyn-gui.overview-alert-0"
	return { "", "[img=utility/warning_icon] [color=255,69,69]", { key }, "[/color]" }
end

local function stop_tooltip(kind)
	if kind == "station" then return constants.open_station_gui_tooltip end
	return { "cybersyn-gui.trains-open-stop-tooltip" }
end

--- @param view TrainRowView
--- @param index integer
--- @param map_data MapData
--- @return flib.GuiElemDef
local function build_row(view, index, map_data)
	local color = index % 2 == 0 and "dark" or "light"
	local train = map_data.trains[view.id]
	local entity = train and train.entity
	local locomotive = (entity and entity.valid) and front_locomotive(entity) or nil
	local w = widths.trains
	return util.hoverable({
		type = "frame",
		style = "ltnm_train_row_frame_" .. color,
		tags = { train_id = view.id },
		{
			type = "frame",
			style = "ltnm_table_inset_frame_" .. color,
			{
				type = "minimap",
				style = "ltnm_train_minimap",
				elem_mods = locomotive and { entity = locomotive } or nil,
				{ type = "label", style = "ltnm_minimap_label", caption = view.id },
				util.hoverable({
					type = "button",
					style = "ltnm_train_minimap_button",
					tooltip = { "cybersyn-gui.trains-open-train-tooltip" },
					tags = { train_id = view.id },
					handler = { [defines.events.on_gui_click] = trains_tab.handle.open_train_gui },
				}, SCROLL),
			},
		},
		{
			type = "flow",
			direction = "vertical",
			style_mods = { width = w.train_status, vertical_spacing = 2 },
			{ type = "label", style = "ltnm_semibold_label", caption = view.status },
			util.hoverable({
				type = "label",
				style = "ltnm_clickable_semibold_label",
				style_mods = { maximal_width = w.train_status },
				caption = view.target_name or "",
				visible = view.target_name ~= nil,
				tooltip = stop_tooltip(view.target_kind),
				tags = { stop_kind = view.target_kind, stop_id = view.target_id },
				handler = { [defines.events.on_gui_click] = trains_tab.handle.open_stop },
			}, SCROLL),
			{ type = "label", caption = alert_caption(view), visible = view.alert ~= nil },
		},
		{
			type = "table",
			style = "slot_table",
			column_count = NETWORK_COLUMNS,
			style_mods = { width = w.network },
			children = network_children(view.net),
		},
		{
			type = "label",
			style_mods = { width = w.layout },
			caption = view.layout,
		},
		util.hoverable({
			type = "label",
			style = "ltnm_clickable_semibold_label",
			style_mods = { width = w.depot },
			caption = view.depot_name,
			tooltip = stop_tooltip("depot"),
			tags = { stop_kind = "depot", stop_id = view.depot_id },
			handler = { [defines.events.on_gui_click] = trains_tab.handle.open_stop },
		}, SCROLL),
		{
			type = "frame",
			style = "ltnm_small_slot_table_frame_" .. color,
			style_mods = { width = w.shipment },
			{
				type = "table",
				style = "slot_table",
				column_count = SHIPMENT_COLUMNS,
				children = shipment_children(view.tr, view.filter_item),
			},
		},
	}, SCROLL)
end

--- Rewrites tags without dropping the flib handler and hover-scope keys stored in them.
--- @param elem LuaGuiElement
local function set_tag_values(elem, kind, id)
	local tags = elem.tags
	if tags.stop_kind == kind and tags.stop_id == id then return end
	tags.stop_kind = kind
	tags.stop_id = id
	elem.tags = tags
end

--- In-place update of a row whose sig changed. Network and shipment tables are only rebuilt when their own
--- part changed, and the minimap entity only when it went invalid.
--- @param row LuaGuiElement
--- @param view TrainRowView
--- @param parts {[uint]: {net: string, ship: string}}
--- @param map_data MapData
local function update_row(row, view, parts, map_data)
	local children = row.children
	local part = parts[view.id]
	if not part then
		part = {}
		parts[view.id] = part
	end

	local minimap = children[1].children[1]
	local current = minimap.entity
	if not (current and current.valid) then
		local train = map_data.trains[view.id]
		local entity = train and train.entity
		local locomotive = (entity and entity.valid) and front_locomotive(entity) or nil
		if locomotive then minimap.entity = locomotive end
	end

	local status_flow = children[2].children
	status_flow[1].caption = view.status
	local target = status_flow[2]
	target.caption = view.target_name or ""
	target.visible = view.target_name ~= nil
	target.tooltip = stop_tooltip(view.target_kind)
	set_tag_values(target, view.target_kind, view.target_id)
	status_flow[3].caption = alert_caption(view)
	status_flow[3].visible = view.alert ~= nil

	if part.net ~= view.net_sig then
		local net = children[3]
		net.clear()
		gui.add(net, network_children(view.net))
		part.net = view.net_sig
	end

	children[4].caption = view.layout
	local depot = children[5]
	depot.caption = view.depot_name
	set_tag_values(depot, "depot", view.depot_id)

	if part.ship ~= view.ship_sig then
		local ship = children[6].children[1]
		ship.clear()
		gui.add(ship, shipment_children(view.tr, view.filter_item))
		part.ship = view.ship_sig
	end
end

--- @param rows SnapshotTrain[]
--- @param alerts {[uint]: int}
--- @return LocalisedString caption
--- @return string sig
local function summary_caption(rows, alerts)
	local parked, to_p, loading, to_r, unloading, returning, refuel, alerted = 0, 0, 0, 0, 0, 0, 0, 0
	for i = 1, #rows do
		local tr = rows[i]
		local s = tr.status
		if s == STATUS_D then
			parked = parked + 1
		elseif s == STATUS_TO_P then
			to_p = to_p + 1
		elseif s == STATUS_P then
			loading = loading + 1
		elseif s == STATUS_TO_R then
			to_r = to_r + 1
		elseif s == STATUS_R then
			unloading = unloading + 1
		elseif s == STATUS_TO_D or s == STATUS_TO_D_BYPASS then
			returning = returning + 1
		elseif s == STATUS_TO_F or s == STATUS_F then
			refuel = refuel + 1
		end
		if alerts[tr.id] then alerted = alerted + 1 end
	end
	local sep = "  ·  "
	local caption = {
		"",
		{ "cybersyn-gui.trains-sum-parked", parked }, sep,
		{ "cybersyn-gui.trains-sum-to-p", to_p }, sep,
		{ "cybersyn-gui.trains-sum-loading", loading }, sep,
		{ "cybersyn-gui.trains-sum-to-r", to_r }, sep,
		{ "cybersyn-gui.trains-sum-unloading", unloading }, sep,
		{ "cybersyn-gui.trains-sum-returning", returning }, sep,
		{ "cybersyn-gui.trains-sum-refuel", refuel },
	}
	if alerted > 0 then
		caption[#caption + 1] = sep
		caption[#caption + 1] = { "cybersyn-gui.trains-sum-alerts", alerted }
	end
	local sig = table.concat({ parked, to_p, loading, to_r, unloading, returning, refuel, alerted }, ",")
	return caption, sig
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

--- @param map_data MapData
--- @param player_data PlayerData
function trains_tab.build(map_data, player_data)
	local refs = player_data.refs
	local scroll_pane = refs[SCROLL]
	if not (scroll_pane and scroll_pane.valid) then return end

	local rows, snapshot, ctx = trains_tab.query(map_data, player_data)
	local first, last = util.paginate(player_data, TAB, #rows)
	local alerts = alerts_by_train(snapshot)
	local filter_item = player_data.search_item

	local state = util.gui_state(player_data, SCROLL)
	local parts = state.parts
	if not parts then
		parts = {}
		state.parts = parts
	end

	local entries = {}
	if last < first then
		local empty_key
		if not snapshot.tick then
			empty_key = "cybersyn-gui.stations-collecting"
		elseif util.filters_active(util.get_filters(player_data)) and next(snapshot.trains) then
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
		for i = first, last do
			local view = row_view(rows[i], ctx, alerts, filter_item)
			entries[#entries + 1] = {
				key = view.id,
				sig = view.sig,
				build = function()
					parts[view.id] = { net = view.net_sig, ship = view.ship_sig }
					return build_row(view, i, map_data)
				end,
				update = function(elem)
					update_row(elem, view, parts, map_data)
				end,
			}
		end
	end

	local result = util.sync_children(scroll_pane, entries, state, util.hold_active(player_data, SCROLL))
	state.last_result = result
	if result == "rebuilt" then
		local live = {}
		for _, key in ipairs(state.keys) do
			if parts[key] then live[key] = parts[key] end
		end
		state.parts = live
	end

	local summary = refs.manager_trains_tab_summary
	if summary and summary.valid then
		-- Zero counts before the first pass reached the trains would read as an idle fleet.
		local show = snapshot.tick ~= nil or #rows > 0
		if summary.visible ~= show then summary.visible = show end
		local caption, sig = summary_caption(rows, alerts)
		if show and state.summary_sig ~= sig then
			summary.caption = caption
			state.summary_sig = sig
		end
	end
end

dev.register_dump(TAB, function(player_data)
	local scroll_pane = player_data.refs[SCROLL]
	local rows, _, ctx = trains_tab.query(storage, player_data)
	local key_of = {}
	for _, tr in ipairs(rows) do
		key_of[tr.id] = ctx.key_fn(tr)
	end
	local ids, keys, statuses, targets = {}, {}, {}, {}
	for _, row in ipairs(scroll_pane.children) do
		local id = row.tags.train_id
		if id then
			local n = #ids + 1
			ids[n] = id
			keys[n] = key_of[id]
			local status_flow = row.children[2].children
			statuses[n] = status_flow[1].caption
			targets[n] = status_flow[2].visible and status_flow[2].caption or false
		end
	end
	local column, ascending = util.get_sort(player_data, TAB, DEFAULT_COLUMN)
	local state = util.gui_state(player_data, SCROLL)
	local summary = player_data.refs.manager_trains_tab_summary
	return {
		ids = ids,
		keys = keys,
		statuses = statuses,
		targets = targets,
		column = column,
		ascending = ascending,
		page = player_data.page and player_data.page[TAB],
		total = #rows,
		last_result = state.last_result,
		summary_sig = state.summary_sig,
		pager = player_data.refs[TAB .. "_pager_label"].caption,
		children = #scroll_pane.children,
		summary = summary and summary.valid and summary.caption or nil,
	}
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
--- @param player_data PlayerData
function trains_tab.handle.open_train_gui(player, player_data, refs, e)
	local train_id = e.element.tags.train_id
	--- @type Train?
	local train = storage.trains[train_id]
	local train_entity = train and train.entity

	if not train_entity or not train_entity.valid then
		util.error_flying_text(player, { "cybersyn-message.error-train-is-invalid" })
		return
	end
	if e.shift then
		local locomotive = front_locomotive(train_entity)
		if locomotive then
			player.centered_on = locomotive
			if not player_data.pinning then util.close_manager_window(player, player_data, refs) end
		end
		return
	end
	local locomotive = train_util.get_main_locomotive(train_entity)
	if not (locomotive and locomotive.valid) then
		util.error_flying_text(player, { "cybersyn-gui.train-has-no-locomotive" })
		return
	end
	util.open_entity(player, player_data, locomotive)
end

--- Station, depot or refueler name clicked. Left: stop GUI; shift: map; control: (station) combinator;
--- alt: station control combinator.
--- @param e EventData.on_gui_click
function trains_tab.handle.open_stop(player, player_data, refs, e)
	local tags = e.element.tags
	local kind, id = tags.stop_kind, tags.stop_id
	local record
	if kind == "station" then
		record = storage.stations[id]
	elseif kind == "depot" then
		record = storage.depots[id]
	elseif kind == "refueler" then
		record = storage.refuelers[id]
	end
	local stop = record and record.entity_stop
	if not (stop and stop.valid) then
		util.error_flying_text(player, { "cybersyn-message.error-station-is-invalid" })
		return
	end

	if e.shift then
		player.centered_on = stop
		rendering.draw_circle({
			color = constants.colors.red.tbl,
			target = stop.position,
			surface = stop.surface,
			radius = 0.5,
			filled = false,
			width = 5,
			time_to_live = 60 * 3,
			players = { player },
		})
		if not player_data.pinning then util.close_manager_window(player, player_data, refs) end
	elseif e.control then
		local comb = kind == "station" and record.entity_comb1 or record.entity_comb
		if comb and comb.valid then
			util.open_entity(player, player_data, comb)
		else
			util.error_flying_text(player, { "cybersyn-message.error-cybernetic-combinator-not-found" })
		end
	elseif e.alt and kind == "station" then
		local comb = record.entity_comb2
		if comb and comb.valid then
			util.open_entity(player, player_data, comb)
		else
			util.error_flying_text(player, { "cybersyn-message.error-station-control-combinator-not-found" })
		end
	else
		util.open_entity(player, player_data, stop)
	end
end

--- @param e EventData.on_gui_click
function trains_tab.handle.on_trains_item_click(player, player_data, refs, e)
	local hash = e.element.tags.item_hash
	if not hash then return end
	util.item_button_click(player, player_data, e, hash)
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
	local active, ascending = util.get_sort(player_data, TAB, DEFAULT_COLUMN)
	util.sync_sort_header(element.parent, active, ascending)
	util.rerender(player, player_data)
end

gui.add_handlers(trains_tab.handle, trains_tab.wrapper)

return trains_tab
