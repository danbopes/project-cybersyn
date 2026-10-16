local gui = require("__flib__.gui")
local mod_gui = require("__core__.lualib.mod-gui")

local manager = require("scripts.gui.manager")
local collector = require("scripts.gui.collector")
local util = require("scripts.gui.util")
local diag = require("scripts.diag")
local relative = require("scripts.gui.relative")
local trains_tab = require("scripts.gui.trains")
local extras = require("scripts.gui.extras")
local repair = require("scripts.gui.repair")
local explain = require("scripts.gui.explain")

trains_tab.set_relative(relative)
relative.set_pane_gone(trains_tab.on_pane_gone)

--- @class Manager
--- @field players table<uint, PlayerData>
--- @field pane_escapes {[uint]: {tick: uint, train: uint, controller: defines.controllers}}? Escapes that closed a Trains detail pane and wait to hand player.opened back to the window (manager.settle_pane_escapes)
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
--- @field return_to {entity: LuaEntity, tick: uint, controller: defines.controllers}? entity GUI a manager link opened, see util.open_entity
--- @field restore_opened {entity: LuaEntity, controller: defines.controllers}? player.opened goes back to the unpinned manager once no other GUI holds it
--- @field handed_back_tick uint? game tick on_gui_closed last handed player.opened back, see manager.handle.manager_closed_by_game
--- @field overlay_took true? the pinned window took player.opened for its overlays (manager.PINNED_OVERLAYS_TAKE_OPENED)
--- @field dialog_return {window: true?, entity: LuaEntity?}? what the action dialog took player.opened from
--- @field dialog_opening uint? the tick the action dialog took player.opened (the window's on_gui_closed ignores it)
--- @field selected_tab string? "overview_tab"|"inventory_tab"|"stations_tab"|"trains_tab"|"utilization_tab"|"delivery_breakdown_tab"
--- @field previous_tab string?
--- @field delivery_times_interval uint?
--- @field delivery_times_mode string?
--- @field delivery_times_selected {[string]: boolean}?
--- @field utilization_interval uint?
--- @field utilization_selected {[string]: boolean}?
--- @field inventory_cache table? inventory tab aggregate + top stations for one snapshot pass and filter set; dropped on close
--- @field inventory_version integer? bumped per inventory_cache rebuild, see inventory.get_cache
--- @field layout ManagerLayout? window size for the player's screen, see manager.layout
--- @field layout_override {width: number, height: number, scale: number}? emulated screen (dev.set_layout)
--- @field location {x: int, y: int}? window position in physical pixels, from on_gui_location_changed
--- @field filter_row_open true? the title bar's filter toggle
--- @field search_open true? the title bar's search toggle
--- @field search_focused true? the search field was clicked or focused and not confirmed since
--- @field auto_pinned true? "show on map" pinned the window; leaving remote view unpins it
--- @field markers uint[]? render object ids of the player's show-on-map marker pair
--- @field chip_sig string? item filter the chips show
--- @field collecting_shown int? progress the subheaders show, -1 = none
--- @field trains_badge int? alert count on the Trains tab
--- @field unserved_minutes int? cached cybersyn-manager-unserved-minutes
--- @field relative_open {kind: "stop"|"train", id: uint}? the Cybersyn panel beside an open vanilla window
--- @field relative RelativeState? that panel's render state, see scripts/gui/relative.lua
--- @field relative_effective_open true? the stop panel's Effective config section is expanded

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

--- Opens the manager on `tab` (the trains-window button, a HUD click), or switches an open one to it.
--- @param player LuaPlayer
--- @param pd PlayerData
--- @param tab string
local function open_manager_on(player, pd, tab)
	pd.selected_tab = tab
	if pd.is_manager_open then
		util.select_tab(pd, tab)
		local window = pd.refs and pd.refs.manager_window
		if not pd.pinning and window and window.valid then player.opened = window end
		manager.render(player, pd)
	else
		manager.handle.manager_open(player, pd, pd.refs)
	end
end
extras.set_open_manager(open_manager_on)
manager_gui.open_manager_on = open_manager_on

--- The remote interface's toggle_gui (scripts/remote-interface.lua), the same as the shortcut.
--- @param player_index uint
function cybersyn_manager_toggle(player_index)
	if not game.get_player(player_index) then return end
	local pd = storage.manager and storage.manager.players[player_index]
	if not pd then return end
	manager.wrapper({ player_index = player_index }, manager.handle.manager_toggle)
end

function manager_gui.on_lua_shortcut(e)
	if e.prototype_name == "cybersyn-toggle-gui" or e.input_name == "cybersyn-toggle-gui" or e.element then
		if e.element then
			if not e.element.valid then return end
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

--- Registered for every on_gui_closed (scripts/main.lua), so no registration depends on game state.
--- @param e EventData.on_gui_closed
function manager_gui.on_gui_closed(e)
	relative.on_gui_closed(e)
	manager_gui.on_lua_shortcut(e)
	-- Last: it destroys the dialog, the element of this event.
	repair.on_gui_closed(e)
	-- Closing the GUI a link opened hands player.opened back at once when nothing else holds it, so a second Escape
	-- closes the manager instead of opening the game menu. restore_opened stays set: the engine may still close the
	-- window again in this tick (locomotive GUI) or force-close it without an event while it switches to another GUI,
	-- and the manager tick then retries.
	local player_data = storage.manager and storage.manager.players[e.player_index]
	local pending = player_data and player_data.restore_opened
	if not (pending and e.entity and e.entity == pending.entity) then return end
	local player = game.get_player(e.player_index)
	-- A controller switch still in progress (remote view entered or left) is settled on the manager tick.
	if not player or player.controller_type ~= pending.controller then return end
	player_data.handed_back_tick = game.tick
	manager.restore_opened(player, player_data)
end

--- on_gui_click that no element handler took (scripts/main.lua): a click on a Trains row selects its train.
manager_gui.on_unhandled_click = trains_tab.on_row_click

--- Registered for every on_gui_opened (scripts/main.lua), after the entity GUI handlers of scripts/gui.lua.
--- @param e EventData.on_gui_opened
function manager_gui.on_gui_opened(e)
	manager.on_other_gui_opened(e)
	relative.on_gui_opened(e)
end

--- Registered for every on_train_schedule_changed (scripts/main.lua), after Cybersyn's own handler.
manager_gui.on_train_schedule_changed = relative.on_train_schedule_changed

--- Fields absent from PlayerData in older saves.
--- @param player_data PlayerData
local function init_player_fields(player_data)
	player_data.sort = player_data.sort or {}
	player_data.page = player_data.page or {}
	player_data.gui_state = player_data.gui_state or {}
	player_data.search_network_mask = player_data.search_network_mask or -1
	if player_data.paused == nil then player_data.paused = false end
	player_data.page_size = nil
	player_data.hover = nil
	if player_data.search_item and not util.signal_hash_valid(player_data.search_item) then
		player_data.search_item = nil
	end
	if player_data.search_network_name and not util.signal_hash_valid(player_data.search_network_name) then
		player_data.search_network_name = nil
	end
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
	extras.ensure_trains_anchor(player)

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
	if player_data and player_data.relative_open then relative.close(player, player_data) end
	if player_data then
		explain.close(player, player_data)
		if player then repair.close_dialog(player, player_data) end
	end
end

function manager_gui.on_player_removed(e)
	storage.manager.players[e.player_index] = nil
	collector.release_if_unused()
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
	elseif e.setting == "cybersyn-diagnostics" then
		-- The Log tab shows only while diagnostics are on; with manager updates off nothing else would hide it.
		local manager_data = storage.manager
		if not manager_data then return end
		for _, v in pairs(manager_data.players) do
			if not storage.diag then manager.log_tab.forget(v) end
			if v.refs and v.refs.manager_window and v.refs.manager_window.valid then
				manager.log_tab.refresh_visibility(v)
			end
		end
	elseif e.setting == "cybersyn-manager-hud" then
		local player_data = e.player_index and storage.manager.players[e.player_index]
		local player = e.player_index and game.get_player(e.player_index)
		if player and player_data then extras.hud_setting_changed(player, player_data) end
	elseif e.setting == "cybersyn-manager-unserved-minutes" then
		local player_data = e.player_index and storage.manager.players[e.player_index]
		if player_data then player_data.unserved_minutes = nil end
	elseif e.setting == "cybersyn-enable-planner" then
		-- Who paused the dispatcher, for the banner; nil player_index = the server or a script.
		local manager_data = storage.manager
		if not manager_data then return end
		manager_data.paused_by = settings.global["cybersyn-enable-planner"].value == false and (e.player_index or 0) or nil
		for i, v in pairs(manager_data.players) do
			local player = game.get_player(i)
			if player and v.refs and v.refs.manager_window and v.refs.manager_window.valid then
				manager.refresh_banners(v)
				manager.relayout(player, v)
			end
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

--- Forgets the player's window position and size and centres the window again (/cybersyn-reset-gui).
--- @param player LuaPlayer
function manager_gui.reset_gui(player)
	local player_data = storage.manager and storage.manager.players[player.index]
	if not player_data then return end
	player_data.location = nil
	player_data.layout = nil
	player_data.layout_override = nil
	player_data.filter_row_open = nil
	local refs = player_data.refs
	if refs and refs.manager_window and refs.manager_window.valid then
		manager.refresh_filter_row(player, player_data)
		manager.apply_layout(player, player_data)
		refs.manager_window.force_auto_center()
		if player_data.is_manager_open then manager.render(player, player_data) end
	end
	player.print({ "cybersyn-gui.reset-gui-done" })
end

commands.add_command("cybersyn-reset-gui", { "cybersyn-gui.reset-gui-help" }, function(command)
	local player = command.player_index and game.get_player(command.player_index)
	if player then manager_gui.reset_gui(player) end
end)

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
	manager_gui.settle()
	collector.tick()
	local surface_count
	for i, v in pairs(manager_data.players) do
		if not v.player_index then
			v.player_index = i
		end
		if v.is_manager_open then
			local player = game.get_player(i)
			if player and v.restore_opened and manager.restore_opened(player, v) then
				v.restore_opened = nil
				v.handed_back_tick = nil
			end
			if player then
				surface_count = surface_count or #game.surfaces
				if v.surface_count ~= surface_count then
					manager.rebuild_surface_dropdown(v)
				end
				if v.paused and (v.rendered_snapshot_tick or not collector.get().tick) then
					manager.update_status(v)
				else
					manager.render(player, v)
				end
			end
		end
	end
	extras.tick(manager_data)
	repair.tick(manager_data)
	explain.tick(manager_data)
	relative.tick(manager_data)
end

--- Escapes that closed an overlay or the action dialog hand player.opened back on a later tick (manager.lua,
--- repair.lua). Called from the planner's own tick too (scripts/main.lua), so the hand-back is a tick or two away
--- and a second Escape reaches the window instead of the game menu.
function manager_gui.settle()
	local manager_data = storage.manager
	if not (manager_data and (manager_data.pane_escapes or manager_data.dialog_escapes)) then return end
	manager.settle_pane_escapes()
	repair.settle()
end

--- Every extras.HUD_TICKS, whatever the manager's update rate (scripts/main.lua).
manager_gui.hud_tick = extras.hud_tick
manager_gui.HUD_TICKS = extras.HUD_TICKS

--- The Refresh allow-lists job while manager updates are off (scripts/main.lua's world-scan tick).
manager_gui.job_tick = repair.job_tick

--- Export jobs drain here only: a fixed nth tick, whatever the manager's update rate, off the manager's own ticks.
function manager_gui.export_tick()
	manager_gui.settle()
	manager.log_tab.export_tick()
	if storage.manager then repair.expire(storage.manager) end
end

--- on_player_display_resolution_changed / on_player_display_scale_changed.
function manager_gui.on_display_changed(e)
	local player_data = storage.manager and storage.manager.players[e.player_index]
	local player = game.get_player(e.player_index)
	if player and player_data then
		manager.relayout(player, player_data)
		relative.on_display_changed(player, player_data)
	end
end

--- on_player_controller_changed.
function manager_gui.on_controller_changed(e)
	local player_data = storage.manager and storage.manager.players[e.player_index]
	local player = game.get_player(e.player_index)
	if player and player_data then manager.on_controller_changed(player, player_data) end
end

--- The cybersyn-manager-search custom input (linked to the game's focus-search).
manager_gui.on_search_input = manager.on_search_input

--- The cybersyn-manager-world-click custom input (linked to the game's open-gui click).
--- @param e EventData.CustomInputEvent
function manager_gui.on_world_click(e)
	local player_data = storage.manager and storage.manager.players[e.player_index]
	if player_data and player_data.search_focused then
		player_data.search_focused = nil
		manager.overlay_closed(game.get_player(e.player_index), player_data)
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
		relative.reset(player, v)
		extras.reset(player, v)
		explain.close(player, v)
		repair.close_dialog(player, v)
		v.item_view = nil
		v.item_cache = nil
		v.is_manager_open = false
		v.gui_state = {}
		player.set_shortcut_toggled("cybersyn-toggle-gui", false)
	end
end

return manager_gui
