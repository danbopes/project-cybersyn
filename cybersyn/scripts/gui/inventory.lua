local gui = require("__flib__.gui")

local util = require("scripts.gui.util")
local templates = require("scripts.gui.templates")
local format = require("__flib__.format")
local collector = require("scripts.gui.collector")
local dev = require("scripts.gui.dev")

local inventory_tab = {}

function inventory_tab.create()
	return {
		tab = {
			name = "manager_inventory_tab",
			type = "tab",
			caption = { "cybersyn-gui.inventory" },
			ref = { "inventory", "tab" },
			handler = { [defines.events.on_gui_click] = inventory_tab.handle.on_inventory_tab_selected },
		},
		content = {
			name = "manager_inventory_content_frame",
			type = "flow",
			style_mods = { horizontal_spacing = 12 },
			direction = "horizontal",
			ref = { "inventory", "content_frame" },
			templates.inventory_slot_table("provided", 12),
			templates.inventory_slot_table("in_transit", 8),
			templates.inventory_slot_table("requested", 8),
		},
	}
end

local TAB = "inventory_tab"

--- @param scope string name of the grid, for hover-hold
--- @param hash string
--- @param agg {count: int, stations: int}
--- @param style string
--- @param tooltip_tail LocalisedString[]
local function item_entry(scope, hash, agg, style, tooltip_tail, sig_extra)
	local sprite, quality, name_tooltip = util.item_sprite_and_tooltip(hash)
	if not sprite then return nil end
	local tooltip = { "", name_tooltip }
	for _, part in ipairs(tooltip_tail) do
		tooltip[#tooltip + 1] = part
	end
	local count_caption = format_signal_count(agg.count)
	local stations_caption = format_signal_count(agg.stations)
	return {
		key = hash,
		sig = agg.count .. "|" .. agg.stations .. "|" .. style .. "|" .. (sig_extra or ""),
		build = function()
			return util.hoverable({
				type = "sprite-button",
				sprite = sprite,
				quality = quality,
				style = style,
				tags = { item_hash = hash },
				handler = { [defines.events.on_gui_click] = inventory_tab.handle.on_inventory_item_click },
				tooltip = tooltip,
				children = {
					{
						type = "label",
						style = "ltnm_label_signal_count_inventory",
						ignored_by_interaction = true,
						caption = count_caption,
					},
					{
						type = "label",
						style = "ltnm_label_train_count_inventory",
						ignored_by_interaction = true,
						caption = stations_caption,
					},
				},
			}, scope)
		end,
		update = function(elem)
			local labels = elem.children
			if labels[1].caption ~= count_caption then labels[1].caption = count_caption end
			if labels[2].caption ~= stations_caption then labels[2].caption = stations_caption end
			elem.tooltip = tooltip
			if elem.style.name ~= style then elem.style = style end
		end,
	}
end

--- @param player_data PlayerData
--- @param table_elem LuaGuiElement
--- @param entries table[]
local function render_grid(player_data, table_elem, entries)
	local scope = table_elem.name
	util.sync_children(table_elem, entries, util.gui_state(player_data, scope), util.hold_active(player_data, scope))
end

--- The item filter highlights instead of hiding; the other filters restrict which stations are aggregated.
---@param map_data MapData
---@param player_data PlayerData
function inventory_tab.build(map_data, player_data)
	local refs = player_data.refs
	local snapshot = collector.get()
	local f = util.get_filters(player_data)
	local inv
	if util.filters_active(f, true) then
		inv = collector.aggregate(snapshot, function(st) return util.station_passes(st, f, true) end)
	else
		inv = snapshot.inventory_all
	end
	local selected = f.item
	local now = game.tick

	local provided_children = {}
	for _, hash in ipairs(util.hashes_in_item_order(inv.provided)) do
		local agg = inv.provided[hash]
		provided_children[#provided_children + 1] = item_entry("inventory_provided_table", hash, agg,
			hash == selected and "flib_selected_slot_button_green" or "flib_slot_button_green", {
				"\n", { "cybersyn-gui.provided-by-stations", tostring(agg.stations) },
				"\n", { "cybersyn-gui.amount", format.number(agg.count) },
			})
	end

	local in_transit_children = {}
	for _, hash in ipairs(util.hashes_in_item_order(inv.in_transit)) do
		local agg = inv.in_transit[hash]
		in_transit_children[#in_transit_children + 1] = item_entry("inventory_in_transit_table", hash, agg,
			hash == selected and "flib_selected_slot_button_blue" or "flib_slot_button_blue", {
				"\n", { "cybersyn-gui.in-transit-to-stations", tostring(agg.stations) },
				"\n", { "cybersyn-gui.amount", format.number(agg.count) },
			})
	end

	local requested_children = {}
	for _, hash in ipairs(util.hashes_in_item_order(inv.requested)) do
		local agg = inv.requested[hash]
		local transit = inv.in_transit[hash]
		local color = transit and "orange" or "red"
		local tail = {
			"\n", { "cybersyn-gui.requested-by-stations", tostring(agg.stations) },
			"\n", { "cybersyn-gui.amount", format.number(agg.count) },
		}
		if agg.earliest_wait_start then
			tail[#tail + 1] = "\n[color=yellow]"
			tail[#tail + 1] = { "cybersyn-gui.waiting-for", util.format_duration(now - agg.earliest_wait_start) }
			tail[#tail + 1] = "[/color]"
		end
		if transit then
			tail[#tail + 1] = "\n[color=orange]"
			tail[#tail + 1] = { "cybersyn-gui.in-transit-amount", format.number(transit.count) }
			tail[#tail + 1] = "[/color]"
		else
			tail[#tail + 1] = "\n[color=red]"
			tail[#tail + 1] = { "cybersyn-gui.not-in-transit" }
			tail[#tail + 1] = "[/color]"
		end
		local sig_extra = (transit and transit.count or "") .. "|" .. (agg.earliest_wait_start and math.floor((now - agg.earliest_wait_start) / 60) or "")
		requested_children[#requested_children + 1] = item_entry("inventory_requested_table", hash, agg,
			(hash == selected and "flib_selected_slot_button_" or "flib_slot_button_") .. color, tail, sig_extra)
	end

	render_grid(player_data, refs.inventory_provided_table, provided_children)
	render_grid(player_data, refs.inventory_in_transit_table, in_transit_children)
	render_grid(player_data, refs.inventory_requested_table, requested_children)
end

dev.register_dump(TAB, function(player_data)
	local refs = player_data.refs
	local out = {}
	for _, grid in ipairs({ "provided", "in_transit", "requested" }) do
		local hashes, captions = {}, {}
		for i, button in ipairs(refs["inventory_" .. grid .. "_table"].children) do
			hashes[i] = button.tags.item_hash
			captions[i] = button.children[1].caption
		end
		out[grid] = { hashes = hashes, captions = captions }
	end
	return out
end)

inventory_tab.handle = {}

--- @param e {player_index: uint}
function inventory_tab.wrapper(e, handler)
	local player = game.get_player(e.player_index)
	if not player then return end
	local player_data = storage.manager.players[e.player_index]
	handler(player, player_data, player_data.refs, e)
end

---@param player LuaPlayer
---@param player_data PlayerData
function inventory_tab.handle.on_inventory_tab_selected(player, player_data)
	player_data.selected_tab = "inventory_tab"
end

---@param player LuaPlayer
---@param player_data PlayerData
---@param refs table<string, LuaGuiElement>
---@param e EventData.on_gui_click
function inventory_tab.handle.on_inventory_item_click(player, player_data, refs, e)
	local element = e.element
	local hash = element and element.tags.item_hash
	if not hash then return end
	util.item_button_click(player, player_data, e, hash)
end

gui.add_handlers(inventory_tab.handle, inventory_tab.wrapper)

return inventory_tab
