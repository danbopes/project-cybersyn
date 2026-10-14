local train_util = require("__flib__.train")
local gui = require("__flib__.gui")

local constants = require("constants")
local util = require("scripts.gui.util")

local templates = require("scripts.gui.templates")
local collector = require("scripts.gui.collector")
local dev = require("scripts.gui.dev")

local trains_tab = {}

function trains_tab.create(widths)
	return {
		tab = {
			name = "manager_trains_tab",
			type = "tab",
			--caption = #trains_sorted == 0 and { "cybersyn-gui.trains" } or { "cybersyn-gui.trains", #train_list },
			caption = { "cybersyn-gui.trains" },
			--badge_text = format.number(#ltn_data.sorted_trains.composition),
			handler = { [defines.events.on_gui_click] = trains_tab.handle.on_trains_tab_selected },
		},
		content = {
			name = "manager_trains_tab_content_frame",
			type = "frame",
			style = "ltnm_main_content_frame",
			direction = "vertical",
			children = {
				{
					type = "frame",
					style = "ltnm_table_toolbar_frame",
					templates.sort_checkbox(widths, "trains", "train_id", true, nil, false, trains_tab.handle.on_trains_sort_checkbox_changed),
					templates.sort_checkbox(widths, "trains", "status", false, nil, false, trains_tab.handle.on_trains_sort_checkbox_changed),
					templates.sort_checkbox(widths, "trains", "layout", false, nil, false, trains_tab.handle.on_trains_sort_checkbox_changed),
					templates.sort_checkbox(widths, "trains", "depot", false, nil, false, trains_tab.handle.on_trains_sort_checkbox_changed),
					templates.column_label({ trains = { shipment = widths.trains.shipment - 50 } }, "trains", "shipment"),
				},
				{ name = "manager_trains_tab_scroll_pane", type = "scroll-pane", style = "ltnm_table_scroll_pane" },
				templates.pager("trains_tab", util.handle.pager_click),
				{
					name = "trains_warning_flow",
					type = "flow",
					style = "ltnm_warning_flow",
				},
			},
		},
	}
end

local TAB = "trains_tab"

--- @param map_data MapData
--- @return {[uint]: string}
local function layout_keys(map_data)
	local keys = {}
	for id, layout in pairs(map_data.layouts) do
		keys[id] = table.concat(layout, "")
	end
	return keys
end

--- Filtered and sorted train ids, from the snapshot only.
--- @param map_data MapData
--- @param player_data PlayerData
--- @return uint[] ids
--- @return Snapshot snapshot
function trains_tab.query(map_data, player_data)
	local snapshot = collector.get()
	local f = util.get_filters(player_data)
	local rows = {}
	for _, tr in pairs(snapshot.trains) do
		if util.train_passes(tr, f) then
			rows[#rows + 1] = tr
		end
	end
	local column, ascending = util.get_sort(player_data, TAB, "train_id")
	local key_fn
	if column == "status" then
		key_fn = function(tr) return tr.status or 0 end
	elseif column == "layout" then
		local keys = layout_keys(map_data)
		key_fn = function(tr) return keys[tr.layout_id] or "" end
	elseif column == "depot" then
		key_fn = function(tr) return tr.depot_name end
	else
		key_fn = function(tr) return tr.id end
	end
	util.sort_by(rows, key_fn, ascending, function(tr) return tr.id end)
	local ids = {}
	for i, tr in ipairs(rows) do
		ids[i] = tr.id
	end
	return ids, snapshot
end

--- @param map_data MapData
--- @param player_data PlayerData
function trains_tab.build(map_data, player_data)
	local widths = constants.gui["en"]
	local refs = player_data.refs

	local trains_sorted, snapshot = trains_tab.query(map_data, player_data)
	local first, last = util.paginate(player_data, TAB, #trains_sorted)

	local layouts_table = util.build_train_layout_table(map_data)

	local scroll_pane = refs.manager_trains_tab_scroll_pane
	if next(scroll_pane.children) ~= nil then
		refs.manager_trains_tab_scroll_pane.clear()
	end

	if #trains_sorted == 0 then
		gui.add(scroll_pane, {
			type = "label",
			style = "ltnm_semibold_label",
			caption = { "cybersyn-gui.no-trains" },
		})
	else
		for idx = first, last do
			local train_id = trains_sorted[idx]
			local tr = snapshot.trains[train_id]
			local train = map_data.trains[train_id]
			local train_entity = train and train.entity
			if not (train_entity and train_entity.valid) then
				goto continue
			end
			local depot_name = tr.depot_name
			local locomotive
			if train_entity.locomotives["front_movers"][1] then
				locomotive = train_entity.locomotives["front_movers"][1]
			else
				locomotive = train_entity.locomotives["back_movers"][1]
			end
			local manifest = tr.manifest
			local network_sprite = "utility/close_black"
			local network_name = tr.network_name
			---@type int?
			local network_id = nil
			---@type {name: string, sprite: string, mask: int?}[]
			local network_entries = {}
			if network_name then
				if network_name == NETWORK_EACH then
					local each_sprite = util.generate_item_references(NETWORK_EACH)
					if not each_sprite then
						each_sprite = "utility/close_black"
					end
					network_entries[#network_entries + 1] = { name = NETWORK_EACH, sprite = each_sprite, mask = nil }

					---@type {name: string, sprite: string, mask: int}[]
					local mask_entries = {}
					for name, mask in pairs(tr.network_mask or {}) do
						local sprite = util.generate_item_references(name)
						if sprite then
							mask_entries[#mask_entries + 1] = { name = name, sprite = sprite, mask = mask }
						end
					end
					table.sort(mask_entries, function(a, b)
						return a.name < b.name
					end)
					for _, entry in ipairs(mask_entries) do
						network_entries[#network_entries + 1] = entry
					end
					if #mask_entries == 0 then
						network_entries[#network_entries + 1] = {
							name = "utility/close_black",
							sprite = "utility/close_black",
							mask = nil,
						}
					end
				else
					network_id = tr.network_mask --[[@as int]]
					network_sprite, _, _ = util.generate_item_references(network_name)
				end
			end

			local network_children = {}
			if network_name == NETWORK_EACH and #network_entries > 0 then
				for _, entry in ipairs(network_entries) do
					network_children[#network_children + 1] = {
						type = "sprite-button",
						style = "ltnm_small_slot_button_default",
						enabled = true,
						ignored_by_interaction = true,
						sprite = entry.sprite,
						number = entry.mask,
					}
				end
			else
				network_children[1] = {
					type = "sprite-button",
					style = "ltnm_small_slot_button_default",
					enabled = true,
					ignored_by_interaction = true,
					sprite = network_sprite,
					number = network_id,
				}
			end

			local network_widget
			if network_name == NETWORK_EACH and #network_entries > 6 then
				network_widget = {
					type = "table",
					style = "slot_table",
					column_count = 6,
					style_mods = { horizontal_align = "center" },
					children = network_children,
				}
			else
				network_widget = {
					type = "flow",
					direction = "horizontal",
					style_mods = { horizontal_align = "center" },
					children = network_children,
				}
			end
			local color = idx % 2 == 0 and "dark" or "light"
			gui.add(scroll_pane, {
				type = "frame",
				style = "ltnm_table_row_frame_" .. color,
				{
					type = "frame",
					style = "ltnm_table_inset_frame_" .. color,
					{
						type = "minimap",
						name = "train_minimap",
						style = "ltnm_train_minimap",

						{ type = "label", style = "ltnm_minimap_label", caption = train_id },
						{
							type = "button",
							style = "ltnm_train_minimap_button",
							tooltip = { "cybersyn-gui.open-train-gui" },
							tags = { train_id = train_id },
							handler = { [defines.events.on_gui_click] = trains_tab.handle.open_train_gui },
						},
					},
				},
				{
					type = "frame",
					style = "ltnm_table_row_frame_" .. color,
					style_mods = { width = widths.trains.status },
					network_widget,
				},
				{
					type = "label",
					style_mods = { width = widths.trains.layout },
					caption = layouts_table[train.layout_id],
				},
				{
					type = "label",
					style_mods = { width = widths.trains.depot },
					caption = depot_name,
				},
				{
					type = "frame",
					name = "shipment_frame",
					style = "ltnm_small_slot_table_frame_" .. color,
					style_mods = { width = widths.trains.shipment },
					{
						type = "table",
						name = "shipment_table",
						style = "slot_table",
						column_count = widths.trains.shipment_columns,
						{},
					},
				},
			}, refs)
			refs.train_minimap.entity = locomotive
			gui.add(refs.shipment_table, util.slot_table_build_from_manifest(manifest, "default"))
			::continue::
		end
	end
end

dev.register_dump(TAB, function(player_data)
	local ids = {}
	for _, row in ipairs(player_data.refs.manager_trains_tab_scroll_pane.children) do
		local inset = row.children[1]
		local minimap = inset and inset.children[1]
		local button = minimap and minimap.children[2]
		if button then ids[#ids + 1] = button.tags.train_id end
	end
	local column, ascending = util.get_sort(player_data, TAB, "train_id")
	return { ids = ids, column = column, ascending = ascending, page = player_data.page and player_data.page[TAB] }
end)

trains_tab.handle = {}

--- @param e {player_index: uint}
function trains_tab.wrapper(e, handler)
	local player = game.get_player(e.player_index)
	if not player then return end
	local player_data = storage.manager.players[e.player_index]
	handler(player, player_data, player_data.refs, e)
end

--- @param e GuiEventData
--- @param player_data PlayerData
function trains_tab.handle.open_train_gui(player, player_data, refs, e)
	local train_id = e.element.tags.train_id
	--- @type Train
	local train = storage.trains[train_id]
	local train_entity = train.entity

	if not train_entity or not train_entity.valid then
		util.error_flying_text(player, { "message.ltnm-error-train-is-invalid" })
		return
	end
	train_util.open_gui(player.index, train_entity)
end

---@param player LuaPlayer
---@param player_data PlayerData
function trains_tab.handle.on_trains_tab_selected(player, player_data)
	player_data.selected_tab = "trains_tab"
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
	local active, ascending = util.get_sort(player_data, TAB, "train_id")
	for _, child in pairs(element.parent.children) do
		local tags = child.type == "checkbox" and child.tags
		if tags and tags.column then
			child.style = tags.column == active and "ltnm_selected_sort_checkbox" or "ltnm_sort_checkbox"
			if tags.width then child.style.width = tags.width end
			if tags.column == active then child.state = not ascending end
		end
	end
	util.rerender(player, player_data)
end

gui.add_handlers(trains_tab.handle, trains_tab.wrapper)

return trains_tab
