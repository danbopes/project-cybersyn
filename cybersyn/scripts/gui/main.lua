local gui = require("__flib__.gui")
local mod_gui = require("__core__.lualib.mod-gui")

local manager = require("scripts.gui.manager")
local collector = require("scripts.gui.collector")
local util = require("scripts.gui.util")

--- @class Manager
--- @field players table<uint, PlayerData>
--- @field item_order table<string, int>
--- @field snapshot Snapshot last complete snapshot (scripts/gui/collector.lua)
--- @field snapshot_build Snapshot? pass in progress, with transient ids/i/r_keys/p_keys

--- @class PlayerData
--- @field player_index uint
--- @field is_manager_open boolean
--- @field refs {[string]: LuaGuiElement}
--- @field search_query string? raw text of the station-name search
--- @field search_terms string[]? lowercase terms derived from search_query
--- @field search_network_name string?
--- @field search_network_mask int
--- @field search_surface_idx uint?
--- @field search_item string? item hash (name or name|quality)
--- @field surface_dropdown_ids {[integer]: uint}? drop-down index -> surface index
--- @field surface_count integer? #game.surfaces when the drop-down was built
--- @field sort {[string]: {column: string, ascending: boolean}}? per tab, see util.get_sort
--- @field page {[string]: integer}? current page per tab, see util.paginate
--- @field page_size integer? cached cybersyn-manager-page-size
--- @field gui_state {[string]: {keys: (string|number)[]?, dirty: true?}}? per container, see util.sync_children
--- @field hover {tick: uint, scope: string?, index: uint}? element under the cursor, see util.hold_active
--- @field paused boolean? title-bar pause: no renders and no collection for this player
--- @field last_update_tick uint? game tick of the last render
--- @field rendered_snapshot_tick uint? snapshot tick shown by the last render
--- @field pinning boolean
--- @field selected_tab string? "overview_tab"|"inventory_tab"|"stations_tab"|"trains_tab"|"utilization_tab"|"delivery_breakdown_tab"
--- @field previous_tab string?
--- @field delivery_times_interval uint?
--- @field delivery_times_mode string?
--- @field delivery_times_selected {[string]: boolean}?
--- @field utilization_interval uint?
--- @field utilization_selected {[string]: boolean}?

local function top_left_button_update(player, player_data)
	local button_flow = mod_gui.get_button_flow(player)
	local button = button_flow["top_left_button"]
	if player_data.disable_top_left_button then
		if button then
			button.destroy()
		end
	elseif not button then
		gui.add(button_flow, {
			type = "sprite-button",
			name = "top_left_button",
			style = "mis_mod_gui_button_green",
			sprite = "mis_configure_white",
			tooltip = { "", "\n", { "cybersyn.gui.configure-tooltip" } },
			handler = manager.handle.manager_toggle,
		})
	end
end

local manager_gui = {}
manager_gui.manager = manager

function manager_gui.on_lua_shortcut(e)
	if e.prototype_name == "cybersyn-toggle-gui" or e.input_name == "cybersyn-toggle-gui" or e.element then
		if e.element then
			if e.element.name == "manager_window" then
				if e.name == defines.events.on_gui_closed then
					manager.wrapper(e, manager.handle.manager_closed_by_game)
				else
					manager.wrapper(e, manager.handle.manager_toggle)
				end
			elseif e.element.name == COMBINATOR_NAME and e.name == defines.events.on_gui_closed then
				-- With the manager enabled, this handler overwrites the combinator's
				-- on_gui_close handler. Copy the logic to close the combinator's GUI here
				-- as well.
				local player = game.get_player(e.player_index)
				if not player then return end
				if player.gui.screen[COMBINATOR_NAME] then
					player.gui.screen[COMBINATOR_NAME].destroy()
				end
			end
		else
			manager.wrapper(e, manager.handle.manager_toggle)
		end
	end
end

--- Fields added by the facelift; old saves lack them.
--- @param player_data PlayerData
local function init_player_fields(player_data)
	player_data.sort = player_data.sort or {}
	player_data.page = player_data.page or {}
	player_data.gui_state = player_data.gui_state or {}
	player_data.search_network_mask = player_data.search_network_mask or -1
	if player_data.paused == nil then player_data.paused = false end
	player_data.page_size = nil
	player_data.hover = nil
	if player_data.search_query and not player_data.search_terms then
		util.set_search_query(player_data, player_data.search_query)
	end
end

local function create_player(player_index)
	local player = game.get_player(player_index)
	if not player then return end

	local player_data = {
		player_index = player_index,
		search_network_mask = -1,
		pinning = false,
		refs = manager.create(player),
		selected_tab = "overview_tab",
	}
	init_player_fields(player_data)
	storage.manager.players[player_index] = player_data

	--manager.update(storage, player, player_data)
	--top_left_button_update(player, player_data)
end

function manager_gui.on_player_created(e)
	create_player(e.player_index)
end

function manager_gui.on_player_left_game(e)
	local player = game.get_player(e.player_index)
	local player_data = storage.manager and storage.manager.players[e.player_index]
	if player and player_data and player_data.is_manager_open then
		manager.wrapper(e, manager.handle.manager_close)
	end
end

function manager_gui.on_player_removed(e)
	storage.manager.players[e.player_index] = nil
end

--script.on_event(defines.events.on_player_joined_game, function(e)
--end)

--script.on_event(defines.events.on_player_left_game, function(e)
--end)

function manager_gui.on_runtime_mod_setting_changed(e)
	if e.setting == "cybersyn-disable-top-left-button" then
		if not e.player_index then return end
		local player = game.get_player(e.player_index)
		if not player then return end

		local player_data = storage.manager.players[e.player_index]
		player_data.disable_top_left_button = player.mod_settings["cybersyn-disable-top-left-button"].value
		top_left_button_update(player, player_data)
	elseif e.setting == "cybersyn-manager-page-size" then
		local player_data = e.player_index and storage.manager.players[e.player_index]
		if player_data then
			player_data.page_size = nil
			util.reset_pages(player_data)
		end
	elseif e.setting == "cybersyn-enable-analytics" then
		-- Rebuild all GUIs when analytics setting changes to show/hide tabs
		local manager_data = storage.manager
		if manager_data then
			for i, v in pairs(manager_data.players) do
				local player = game.get_player(i)
				if player ~= nil then
					manager_gui.reset_player(i, v)
				end
			end
		end
	end
end

commands.add_command("cybersyn_rebuild_manager_windows", nil, function(command)
	local manager_data = storage.manager
	if manager_data then
		---@param v PlayerData
		for i, v in pairs(manager_data.players) do
			local player = game.get_player(i)
			if player ~= nil then
				manager_gui.reset_player(i, v)
			end
		end
	end
end)

--- @param manager Manager
local function init_items(manager)
	local item_order = {}
	manager.item_order = item_order
	local i = 1

	for _, protos in pairs { prototypes.item, prototypes.fluid } do
		--- @type (LuaItemPrototype|LuaFluidPrototype)[]
		local all_items = {}
		for _, proto in pairs(protos) do
			all_items[#all_items + 1] = proto
		end
		table.sort(all_items, function(a, b)
			if a.group.order == b.group.order then
				if a.subgroup.order == b.subgroup.order then
					return a.order < b.order
				else
					return a.subgroup.order < b.subgroup.order
				end
			else
				return a.group.order < b.group.order
			end
		end)
		for _, v in ipairs(all_items) do
			item_order[v.name] = i
			i = i + 1
		end
	end
end


function manager_gui.on_migration()
	if not storage.manager then
		manager_gui.on_init()
	end
	if not storage.recent_external_items then
		storage.recent_external_items = {}
	end

	for i, p in pairs(game.players) do
		if storage.manager.players[i] == nil then
			create_player(i)
		end
	end

	for i, v in pairs(storage.manager.players) do
		init_player_fields(v)
		manager_gui.reset_player(i, v)
	end

	init_items(storage.manager)
	collector.init()
end

function manager_gui.on_init()
	storage.manager = {
		players = {},
	}
	storage.recent_external_items = {}
	init_items(storage.manager)
	collector.init()
end
--gui.handle_events()

---@param global cybersyn.global
function manager_gui.tick(storage)
	local manager_data = storage.manager
	if not manager_data then return end
	collector.tick()
	local surface_count
	for i, v in pairs(manager_data.players) do
		if not v.player_index then
			v.player_index = i
		end
		if v.is_manager_open then
			local player = game.get_player(i)
			if player then
				surface_count = surface_count or #game.surfaces
				if v.surface_count ~= surface_count then
					manager.rebuild_surface_dropdown(v)
				end
				if v.paused then
					manager.update_status(v)
				else
					manager.render(player, v)
				end
				if v.recent_panel_dirty then
					v.recent_panel_dirty = nil
					manager.build_recent_panel(player, v)
				end
			end
		end
	end
end

---@param i string|uint
---@param v LuaPlayer
function manager_gui.reset_player(i, v)
	local player = game.get_player(i)
	if player ~= nil then
		if v.refs and v.refs.manager_window and v.refs.manager_window.valid then
			v.refs.manager_window.destroy()
		end
		v.refs = manager.create(player)
		v.is_manager_open = false
		v.gui_state = {}
		player.set_shortcut_toggled("cybersyn-toggle-gui", false)
	end
end

return manager_gui
