
local manager = require("scripts.gui.manager")
local collector = require("scripts.gui.collector")
local util = require("scripts.gui.util")
local filters = require("scripts.gui.utils.filters")
local relative = require("scripts.gui.relative")
local trains_tab = require("scripts.gui.trains")
local extras = require("scripts.gui.extras")
local repair = require("scripts.gui.repair")
local explain = require("scripts.gui.explain")

trains_tab.set_relative(relative)
relative.set_pane_gone(trains_tab.on_pane_gone)

--- @class Manager
--- @field players table<uint, PlayerData>
--- @field confirm_any true? some player may have a confirm button armed (repair.expire)
--- @field item_order table<string, int>
--- @field snapshot Snapshot last complete snapshot (scripts/gui/collector.lua)
--- @field snapshot_build Snapshot? pass in progress, with transient ids/i/r_keys/p_keys
--- @field collect_boost uint? tick the opening boost started; set while collector.boost_tick steps a pass every tick
--- @field collect_quiet true? the boost refreshes a complete snapshot: no placeholders and no "Collecting…" note
--- @field release_at uint? the last window closed: the kept snapshot is released at this tick (collector.release_due)
--- @field settle int? renders the per-tick handler still owes after a boosted pass completed
--- @field settle_tick uint? tick of its latest such render: a manager update on that tick does not render again
--- @field collect_log {epoch: int, base: int, ids: uint[]}? station records replaced since the snapshot started, see
---   collector.changed_since
--- @field collect_spare {[string]: table}? a completed pass's bookkeeping tables, cleared and reused by the next one
--- @field name_parts {[string]: RichNameParts}? parsed depot and refueler names, kept as long as the snapshot
--- @field lint LintState? see lint.state
--- @field paused_by uint? who turned the planner off, for the paused banner (0 = not a player)
--- @field relative_any true? a stop or train panel may be open; relative.tick clears it once none is
--- @field repair_job RepairJob? the running Refresh allow-lists job

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
--- @field search_station uint? station id of the station chip; dropped by filters.valid_station_filter once the stop is gone
--- @field surface_dropdown_ids {[integer]: uint}? drop-down index -> surface index
--- @field sort {[string]: {column: string, ascending: boolean}}? per tab, see listing.get_sort
--- @field page {[string]: integer}? current page per tab, see listing.paginate
--- @field gui_state {[string]: {keys: (string|number)[]?, dirty: true?}}? per container, see sync.sync_children
--- @field hover {tick: uint, scope: string?, index: uint}? element under the cursor, see hover.hold_active
--- @field paused boolean? title-bar pause: no renders and no collection for this player
--- @field last_update_tick uint? game tick of the last render
--- @field rendered_snapshot_tick uint? snapshot tick shown by the last render
--- @field pinning boolean
--- @field return_to (LuaEntity|LuaGuiElement)? the GUI a manager link opened; closing it hands player.opened back (nav.open_entity)
--- @field map_from {controller: defines.controllers, position: MapPosition, surface: uint}? the view "show on map" left, for Back
--- @field selected_tab string? "overview_tab"|"inventory_tab"|"stations_tab"|"trains_tab"|"utilization_tab"|"delivery_breakdown_tab"
--- @field previous_tab string?
--- @field inventory_cache table? inventory tab aggregate + top stations for one snapshot pass and filter set; dropped on close
--- @field inventory_version integer? bumped per inventory_cache rebuild, see inventory.get_cache
--- @field layout ManagerLayout? window size for the player's screen, see manager.layout
--- @field location {x: int, y: int}? window position in physical pixels, from on_gui_location_changed
--- @field filter_row_open true? the filter row is open (the title bar's filter button is lit); closing it clears its filters
--- @field search_open true? the title bar's search toggle
--- @field markers uint[]? render object ids of the player's show-on-map marker pair
--- @field chip_sig string? item filter the chips show
--- @field collecting_shown int? progress the subheaders show, -1 = none
--- @field trains_badge int? alert count on the Trains tab
--- @field relative_open {kind: "stop"|"train", id: uint, mount: string?, narrow: true?, tick: uint?, pane_narrow: boolean?, groups: int?}? the Cybersyn panel beside an open vanilla window: `narrow` = stop panel hidden on a narrow screen; `tick`, `pane_narrow`, `groups` = the docked train pane it was placed beside, see relative.lua place_train
--- @field remote_entered_tick uint? last tick the controller changed from the character to remote view (the train pane's width depends on it)
--- @field relative RelativeState? that panel's render state, see scripts/gui/relative.lua
--- @field relative_effective_open true? the stop panel's Effective config section is expanded

local manager_gui = {}
manager_gui.manager = manager

--- The remote interface's toggle_gui (scripts/remote-interface.lua), the same as the shortcut.
--- @param player_index uint
function manager_gui.toggle(player_index)
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
				-- The combinator's own close handler keeps the window when its combinator is already gone.
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

--- Every on_gui_closed (scripts/main.lua); the engine keeps one handler per event, so its consumers run from here.
--- @param e EventData.on_gui_closed
function manager_gui.on_gui_closed(e)
	-- The combinator window and the elevator panel close as they would without the manager.
	on_entity_gui_closed(e)
	-- Before the close path below: it destroys the combinator frame, which may be the GUI a manager link opened.
	manager.on_linked_gui_closed(e)
	-- Any entity GUI closing hides the panels beside it.
	relative.on_gui_closed(e)
	-- The manager window's own close, and a combinator frame whose combinator is gone.
	manager_gui.on_lua_shortcut(e)
end

--- on_gui_click that no element handler took (scripts/main.lua): a click on a Trains row selects its train.
manager_gui.on_unhandled_click = trains_tab.on_row_click

--- Every on_gui_opened (scripts/main.lua); the engine keeps one handler per event, so its consumers run from here.
--- @param e EventData.on_gui_opened
function manager_gui.on_gui_opened(e)
	-- The combinator window and the elevator panel open as they would without the manager.
	on_entity_gui_opened_closed(e)
	-- Another GUI taking player.opened closes an unpinned manager, as the game's windows do.
	manager.on_other_gui_opened(e)
	-- A stop or train window gets its panels.
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
	-- A hover names an element of the window that reset_player rebuilds next.
	player_data.hover = nil
	if player_data.search_item and not util.signal_hash_valid(player_data.search_item) then
		player_data.search_item = nil
	end
	if player_data.search_network_name and not util.signal_hash_valid(player_data.search_network_name) then
		player_data.search_network_name = nil
	end
	filters.valid_station_filter(player_data)
	if player_data.search_query and not player_data.search_terms then
		filters.set_search_query(player_data, player_data.search_query)
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
	if player_data then explain.close(player, player_data) end
end

function manager_gui.on_player_removed(e)
	storage.manager.players[e.player_index] = nil
	-- Nobody can reopen a window to profit from a kept snapshot when the last one left with the player.
	collector.release_if_unused()
end

--script.on_event(defines.events.on_player_joined_game, function(e)
--end)

--script.on_event(defines.events.on_player_left_game, function(e)
--end)

function manager_gui.on_runtime_mod_setting_changed(e)
	if e.setting == "cybersyn-diagnostics" then
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
	elseif e.setting == "cybersyn-enable-planner" then
		-- Who paused the dispatcher, for the banner; nil player_index = the server or a script.
		local manager_data = storage.manager
		if not manager_data then return end
		manager_data.paused_by = manager.dispatch_paused() and (e.player_index or 0) or nil
		for i, v in pairs(manager_data.players) do
			local player = game.get_player(i)
			if player and v.refs and v.refs.manager_window and v.refs.manager_window.valid then
				manager.refresh_banners(v)
				manager.relayout(player, v)
			end
		end
	elseif e.setting == "cybersyn-enable-analytics" then
		-- The Breakdown tab exists only while analytics records, so every window is rebuilt.
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
	manager.close_filter_row(player, player_data)
	local refs = player_data.refs
	if refs and refs.manager_window and refs.manager_window.valid then
		manager.apply_layout(player, player_data)
		refs.manager_window.force_auto_center()
		if player_data.is_manager_open then manager.render(player, player_data) end
	end
	player.print({ "cybersyn-gui.reset-gui-done" })
end

commands.add_command("cybersyn-reset-gui", { "cybersyn-messages.reset-gui-command-help" }, function(command)
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
	init_items(storage.manager)
	collector.init()
end
--gui.handle_events()

--- Renders an open window, or for a paused one that already shows data only its status line.
--- @param i uint
--- @param v PlayerData
--- @param owed boolean? a settle render: a paused window already showing this snapshot renders too, so a first build
---   the tab deferred over these renders (Stations, Trains) finishes instead of leaving its placeholder until unpause
local function refresh_window(i, v, owed)
	local player = game.get_player(i)
	if not player then return end
	local tick = collector.get().tick
	if v.paused and (v.rendered_snapshot_tick or not tick) and not (owed and v.rendered_snapshot_tick == tick) then
		manager.update_status(v)
	else
		manager.render(player, v)
	end
end

--- One manager update. While the opening boost runs, and on the ticks after it, the per-tick handler owns the
--- collection and the renders (manager_gui.boost_tick): the update then neither steps nor renders, only refreshes
--- the status lines, so a step and a render never share a tick whichever handler the engine calls first.
--- @param manager_data Manager
--- @return boolean ran collected or rendered
local function update(manager_data)
	local boosting = manager_data.collect_boost ~= nil and collector.wanted()
	local held = boosting or manager_data.settle ~= nil or manager_data.settle_tick == game.tick
	local ran = not held and collector.tick()
	for i, v in pairs(manager_data.players) do
		if not v.player_index then
			v.player_index = i
		end
		if v.is_manager_open then
			local player = game.get_player(i)
			if player then
				if not held then
					refresh_window(i, v)
					ran = true
				elseif boosting then
					manager.update_status(v)
				end
			end
		end
	end
	extras.tick(manager_data)
	explain.tick(manager_data)
	relative.tick(manager_data)
	return ran
end

---@param global cybersyn.global
function manager_gui.tick(storage)
	local manager_data = storage.manager
	if not manager_data then return end
	update(manager_data)
end

local function settle_renders(manager_data)
	for i, v in pairs(manager_data.players) do
		if v.is_manager_open then refresh_window(i, v, true) end
	end
end

local function boost_note(manager_data)
	for _, v in pairs(manager_data.players) do
		if v.is_manager_open then manager.update_status(v) end
	end
end

--- Every tick, whatever the settings (scripts/main.lua): frees a kept
--- snapshot when its time is up, steps the opening boost, and renders on the ticks after the boost completed, never on
--- a step's own tick. Reads only storage; idle it reads six fields.
function manager_gui.boost_tick()
	local manager_data = storage.manager
	if not manager_data then return end
	if manager_data.release_at then collector.release_due() end
	local settle = manager_data.settle
	if settle then
		-- Owed by a render on this very tick (collector.owe_render): one heavy render per tick.
		if manager_data.settle_tick == game.tick then return end
		manager_data.settle = settle > 1 and settle - 1 or nil
		manager_data.settle_tick = game.tick
		settle_renders(manager_data)
		return
	end
	local started = manager_data.collect_boost
	if not started or started == game.tick then return end
	collector.boost_tick()
	-- A boost that outlasts NOTE_TICKS (a huge base, or GC cycles inside it) shows its progress from then on.
	if manager_data.collect_boost and not manager_data.collect_quiet and game.tick - started >= collector.NOTE_TICKS then
		boost_note(manager_data)
	end
end

--- Every extras.HUD_TICKS, whatever the manager's update rate (scripts/main.lua).
manager_gui.hud_tick = extras.hud_tick
manager_gui.HUD_TICKS = extras.HUD_TICKS

--- Armed confirm buttons expire and the Refresh allow-lists job advances, every REPAIR_JOB_NTH (scripts/main.lua).
function manager_gui.repair_tick()
	local m = storage.manager
	if not m then return end
	repair.expire(m)
	repair.job_tick()
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

--- on_surface_created/deleted/renamed/imported: open windows rebuild the surface drop-down and its visibility; a
--- closed window rebuilds it when it opens.
function manager_gui.on_surfaces_changed()
	local manager_data = storage.manager
	if not manager_data then return end
	for i, v in pairs(manager_data.players) do
		local player = v.is_manager_open and game.get_player(i)
		if player then
			manager.rebuild_surface_dropdown(v)
			manager.refresh_filter_row(player, v)
		end
	end
end

--- on_player_controller_changed.
function manager_gui.on_controller_changed(e)
	local player_data = storage.manager and storage.manager.players[e.player_index]
	local player = game.get_player(e.player_index)
	if player and player_data then
		manager.on_controller_changed(player, player_data)
		relative.on_controller_changed(player, player_data, e)
	end
end

--- The cybersyn-manager-search custom input (linked to the game's focus-search).
manager_gui.on_search_input = manager.on_search_input

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
		v.item_view = nil
		v.item_cache = nil
		v.item_refs = nil
		v.is_manager_open = false
		v.gui_state = {}
		player.set_shortcut_toggled("cybersyn-toggle-gui", false)
	end
end

return manager_gui
