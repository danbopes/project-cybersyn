-- Measured extras of PLAN3 §11 (phase 10) that only read game state: the path trace, pins, Test path, the button
-- in the vanilla trains window and the opt-in HUD line. Actions that change game state live in repair.lua.

local gui = require("__flib__.gui")
local format = require("__flib__.format")

local util = require("scripts.gui.util")
local logic = require("scripts.gui.extras-logic")
local utext = require("scripts.gui.unserved-text")
local actions = require("scripts.actions")
local diag = require("scripts.diag")
local stats = require("scripts.stats")
local dev = require("scripts.gui.dev")

--- @class PlayerData
--- @field path_trace {train_id: uint, ids: uint[], until_tick: uint, rails: int, runs: int, segments: int}? the drawn trace
--- @field test_path ExtrasPathResult? the latest Test path result
--- @field last_pin {kind: string, id: uint, label: string, tick: uint}? the latest pin this player added
--- @field hud_on boolean? cached cybersyn-manager-hud; nil = read it again
--- @field hud_location {x: int, y: int}? the HUD's position, physical px

--- @class ExtrasPathResult
--- @field stop_id uint
--- @field train_id uint?
--- @field found boolean
--- @field no_rail boolean? the stop is not connected to a rail, so there is nothing to ask the pathfinder
--- @field length number?
--- @field depot string? the train's depot name
--- @field seq int bumps per result, for render signatures
--- @field tick uint

local extras = {}
extras.handle = {}

local PANEL = "cybersyn_relative_panel"
local TRAINS_ANCHOR = "cybersyn_trains_gui"
local HUD = "cybersyn_hud"
local TRACE_COLOR = { 0.25, 0.8, 1, 0.9 }
-- Not a multiple of the usual manager intervals (60, 30, 20, ... ticks), so a HUD refresh seldom shares their tick.
local HUD_TICKS = 301
extras.HUD_TICKS = HUD_TICKS

local open_manager_fn

--- Lets gui/main.lua hand in the manager's open without a require cycle (manager -> overview -> explain -> extras).
--- @param fn fun(player: LuaPlayer, player_data: PlayerData, tab: string)
function extras.set_open_manager(fn)
	open_manager_fn = fn
end

--- The subject of the relative panel an element sits in ({kind, id} tags of relative.build's frame).
--- @param elem LuaGuiElement
--- @return string? kind "stop"|"train"
--- @return uint? id
function extras.panel_subject(elem)
	while elem and elem.valid do
		if elem.name == PANEL then
			local tags = elem.tags
			return tags.kind, tags.id
		end
		elem = elem.parent
	end
	return nil, nil
end

--- @param id uint
--- @return LuaEntity? stop
--- @return (Station|Depot|Refueler)? record
--- @return "station"|"depot"|"refueler"|nil kind
local function stop_record(id)
	local record, kind = storage.stations[id], "station"
	if not record then record, kind = storage.depots[id], "depot" end
	if not record then record, kind = storage.refuelers[id], "refueler" end
	local stop = record and record.entity_stop
	if stop and stop.valid then return stop, record, kind end
	return nil, nil, nil
end
extras.stop_record = stop_record

--- @param id uint
--- @return LuaTrain?
local function lua_train(id)
	local train = storage.trains[id]
	local entity = train and train.entity
	if entity and entity.valid then return entity end
	return nil
end

-- ---------------------------------------------------------------- path trace (§11.1)

--- Destroys the player's trace (button pressed again, another train selected, or time out).
--- @param pd PlayerData
function extras.clear_path_trace(pd)
	local t = pd.path_trace
	if not t then return end
	for _, id in ipairs(t.ids) do
		local obj = rendering.get_object_by_id(id)
		if obj and obj.valid then obj.destroy() end
	end
	pd.path_trace = nil
end

--- A panel or pane selected another subject: a trace of a different train goes.
--- @param pd PlayerData
--- @param kind string?
--- @param id uint?
function extras.on_selection(pd, kind, id)
	local t = pd.path_trace
	if t and not (kind == "train" and id == t.train_id) then extras.clear_path_trace(pd) end
end

--- Draws the rest of a train's path (from the rail it is on) as collinear runs, in both render modes, for this player
--- only, for TRACE_TICKS. Returns nil and a reason when the train has no path.
--- @param player LuaPlayer
--- @param pd PlayerData
--- @param train_id uint
--- @return table? trace
--- @return LocalisedString? why not
function extras.draw_path_trace(player, pd, train_id)
	extras.clear_path_trace(pd)
	local entity = lua_train(train_id)
	if not entity then return nil, { "cybersyn-message.error-train-is-invalid" } end
	local path = entity.path
	if not (path and path.valid and path.size > 0) then return nil, { "cybersyn-gui.path-trace-none" } end
	local rails = path.rails
	local size = path.size
	local xs, ys, n = {}, {}, 0
	for i = math.max(1, path.current), size do
		local rail = rails[i]
		if rail and rail.valid then
			local p = rail.position
			n = n + 1
			xs[n], ys[n] = p.x, p.y
		end
	end
	local vx, vy, runs = logic.sample_runs(xs, ys, n)
	local surface = entity.front_stock.surface
	local ids = {}
	local def = {
		color = TRACE_COLOR,
		width = 4,
		surface = surface,
		players = { player },
		time_to_live = logic.TRACE_TICKS,
		from = { 0, 0 },
		to = { 0, 0 },
	}
	for _, mode in ipairs({ "game", "chart" }) do
		def.render_mode = mode
		def.width = mode == "game" and 6 or 8
		for i = 1, #vx - 1 do
			def.from = { vx[i], vy[i] }
			def.to = { vx[i + 1], vy[i + 1] }
			ids[#ids + 1] = rendering.draw_line(def).id
		end
	end
	local trace = { train_id = train_id, ids = ids, until_tick = game.tick + logic.TRACE_TICKS, rails = n, runs = runs,
		segments = #vx - 1, size = size }
	pd.path_trace = trace
	return trace
end

--- Path trace button: draws the trace, or removes it when it shows this train already.
--- @param player LuaPlayer
--- @param pd PlayerData
--- @param train_id uint
function extras.toggle_path_trace(player, pd, train_id)
	if extras.trace_shown(pd, train_id) then
		extras.clear_path_trace(pd)
		return
	end
	local trace, why = extras.draw_path_trace(player, pd, train_id)
	if not trace then util.error_flying_text(player, why) end
end

--- @param pd PlayerData
--- @param train_id uint
--- @return boolean
function extras.trace_shown(pd, train_id)
	local t = pd.path_trace
	return t ~= nil and t.train_id == train_id and game.tick < t.until_tick
end

-- ---------------------------------------------------------------- pins (§11.2)

--- Pins a stop (backer name) or a train ("Train <id>", on its front stock) on the player's map.
--- @param player LuaPlayer
--- @param kind string "station"|"depot"|"refueler"|"stop"|"train"
--- @param id uint
--- @return boolean pinned
function extras.add_pin(player, kind, id)
	local entity, label
	if kind == "train" then
		local train = lua_train(id)
		entity = train and train.front_stock
		label = "Train " .. tostring(id)
	else
		entity = stop_record(id)
		label = entity and entity.backer_name
	end
	if not (entity and entity.valid) then
		util.error_flying_text(player, { kind == "train" and "cybersyn-message.error-train-is-invalid"
			or "cybersyn-message.error-station-is-invalid" })
		return false
	end
	player.add_pin({ entity = entity, label = label })
	local pd = storage.manager and storage.manager.players[player.index]
	if pd then pd.last_pin = { kind = kind, id = id, label = label, tick = game.tick } end
	player.create_local_flying_text({ text = { "cybersyn-gui.pin-added", label }, create_at_cursor = true })
	return true
end

-- ---------------------------------------------------------------- Test path (§11.7)

--- Whether a train's network can serve a station's, loosely: only to rank the pathfinder's subject.
local function network_match(station, train)
	local s_net, t_net = station.network_name, train.network_name
	if not (s_net and t_net) then return false end
	if s_net == NETWORK_EACH then
		local mask = station.network_mask
		if type(mask) ~= "table" then return false end
		if t_net == NETWORK_EACH then
			local tmask = train.network_mask
			if type(tmask) ~= "table" then return false end
			for name in pairs(tmask) do if mask[name] then return true end end
			return false
		end
		return mask[t_net] ~= nil
	end
	if t_net == NETWORK_EACH then
		local tmask = train.network_mask
		return type(tmask) == "table" and tmask[s_net] ~= nil
	end
	return s_net == t_net
end

--- The trains a Test path may ask about: Cybersyn trains on the stop's surface, network-matched when any is.
--- @param record Station|Depot|Refueler
--- @param stop LuaEntity
--- @return PathCandidate[]
local function path_candidates(record, stop)
	local surface = stop.surface_index
	local matched, any = {}, {}
	local accepted = record.accepted_layouts
	for id, train in pairs(storage.trains) do
		local entity = train.entity
		local front = entity and entity.valid and entity.front_stock
		if front and front.surface_index == surface then
			local c = {
				id = id,
				available = train.is_available == true,
				fits = record.allows_all_trains == true or (accepted ~= nil and accepted[train.layout_id] ~= nil),
				capacity = (train.item_slot_capacity or 0) + (train.fluid_capacity or 0) / 1000,
			}
			any[#any + 1] = c
			if record.network_name and network_match(record, train) then matched[#matched + 1] = c end
		end
	end
	return #matched > 0 and matched or any
end

--- Asks the pathfinder whether one train can reach the stop and records the answer for the player's panels. A
--- read-only action: the manual_action event and the log line as for the others, but the result line goes to the
--- clicking player only, since anyone may run it.
--- @param player LuaPlayer
--- @param pd PlayerData
--- @param stop_id uint
--- @param named_train uint? a train the caller names (the row's delivery)
--- @return ExtrasPathResult?
function extras.test_path(player, pd, stop_id, named_train)
	local stop, record = stop_record(stop_id)
	if not (stop and record) then
		util.error_flying_text(player, { "cybersyn-message.error-station-is-invalid" })
		return nil
	end
	local seq = ((pd.test_path and pd.test_path.seq) or 0) + 1
	local train_id = named_train and lua_train(named_train) and named_train
		or logic.pick_train(path_candidates(record, stop))
	local result = { stop_id = stop_id, train_id = train_id, found = false, seq = seq, tick = game.tick }
	local train = train_id and storage.trains[train_id]
	local entity = train and lua_train(train_id)
	-- The pathfinder requires a goal stop that sits on a rail (a mined or destroyed rail leaves a registered stop).
	local rail = stop.connected_rail
	if not (rail and rail.valid) then
		result.no_rail = true
	elseif entity then
		-- The pathfinder starts where the train is; it names the depot only when the train is parked there.
		local depot = train.status == STATUS_D and train.depot_id and storage.depots[train.depot_id]
		local depot_stop = depot and depot.entity_stop
		result.depot = depot_stop and depot_stop.valid and depot_stop.backer_name or nil
		local res = game.train_manager.request_train_path({
			train = entity,
			goals = { { train_stop = stop } },
		})
		result.found = res.found_path == true
		if result.found then result.length = res.total_length end
	end
	pd.test_path = result
	actions.audit(ACTION_TEST_PATH, stop_id, player, { "cybersyn-gui.audit-test-path" },
		{ "cybersyn-messages.audit-test-path", player.name, "[train-stop=" .. stop.unit_number .. "]",
			extras.path_caption(result) }, train_id, stop_id, true)
	return result
end

--- One line for a Test path result.
--- @param r ExtrasPathResult
--- @return LocalisedString
function extras.path_caption(r)
	if r.no_rail then return { "cybersyn-gui.test-path-no-rail" } end
	if not r.train_id then return { "cybersyn-gui.test-path-no-train" } end
	if r.found then
		return { "cybersyn-gui.test-path-found", tostring(r.train_id), format.number(math.floor((r.length or 0) + 0.5)) }
	end
	if r.depot then return { "cybersyn-gui.test-path-none", r.depot, tostring(r.train_id) } end
	return { "cybersyn-gui.test-path-none-train", tostring(r.train_id) }
end

--- The result line for a stop when the player's latest Test path was about it, else nil.
--- @param pd PlayerData
--- @param stop_id uint
--- @return LocalisedString? caption
--- @return int seq
function extras.path_note(pd, stop_id)
	local r = pd.test_path
	if not (r and r.stop_id == stop_id) then return nil, 0 end
	return extras.path_caption(r), r.seq
end

-- ---------------------------------------------------------------- relative panel tools

local function tool(name, sprite, tooltip, handler, toggled, enabled)
	return {
		type = "sprite-button",
		name = name,
		style = "tool_button",
		sprite = sprite,
		tooltip = tooltip,
		toggled = toggled or nil,
		enabled = enabled ~= false,
		handler = { [defines.events.on_gui_click] = handler },
	}
end

--- Tool buttons for the stop panel's first footer row.
--- @return flib.GuiElemDef[]
function extras.stop_tools()
	return {
		tool("test_path", "utility/no_path_icon", { "cybersyn-gui.relative-test-path-tooltip" },
			extras.handle.extras_test_path),
		tool("pin", "utility/custom_tag_in_map_view", { "cybersyn-gui.relative-pin-tooltip" }, extras.handle.extras_pin),
	}
end

--- Tool buttons for the train panel's action row.
--- @param pd PlayerData
--- @param train_id uint
--- @return flib.GuiElemDef[]
function extras.train_tools(pd, train_id)
	return {
		tool("path_trace", "utility/gps_map_icon", { "cybersyn-gui.relative-path-trace-tooltip" },
			extras.handle.extras_path_trace, extras.trace_shown(pd, train_id)),
		tool("pin", "utility/custom_tag_in_map_view", { "cybersyn-gui.relative-pin-tooltip" }, extras.handle.extras_pin),
	}
end

--- Part of the footer's signature that these tools change.
--- @param pd PlayerData
--- @param kind string
--- @param id uint
--- @return string
function extras.tools_sig(pd, kind, id)
	if kind == "train" then return extras.trace_shown(pd, id) and "t" or "" end
	local _, seq = extras.path_note(pd, id)
	return tostring(seq)
end

function extras.handle.extras_path_trace(player, pd, e)
	local kind, id = extras.panel_subject(e.element)
	if kind ~= "train" then return end
	extras.toggle_path_trace(player, pd, id)
	util.rerender(player, pd)
	if extras.on_change then extras.on_change(player, pd) end
end

function extras.handle.extras_pin(player, pd, e)
	local kind, id = extras.panel_subject(e.element)
	if not kind then return end
	extras.add_pin(player, kind == "train" and "train" or "stop", id)
end

function extras.handle.extras_test_path(player, pd, e)
	local kind, id = extras.panel_subject(e.element)
	if kind ~= "stop" then return end
	extras.test_path(player, pd, id)
	if extras.on_change then extras.on_change(player, pd) end
end

-- ---------------------------------------------------------------- trains_gui anchor (§11.3)

--- The "Open Cybersyn manager" button above the vanilla trains window, created once per player.
--- @param player LuaPlayer
function extras.ensure_trains_anchor(player)
	local root = player.gui.relative
	local frame = root[TRAINS_ANCHOR]
	if frame and frame.valid then return end
	gui.add(root, {
		type = "frame",
		name = TRAINS_ANCHOR,
		style = "cybersyn_trains_anchor_frame",
		anchor = { gui = defines.relative_gui_type.trains_gui, position = defines.relative_gui_position.top },
		{
			type = "button",
			name = "open_manager",
			caption = { "cybersyn-gui.trains-gui-open-manager" },
			tooltip = { "cybersyn-gui.trains-gui-open-manager-tooltip" },
			handler = { [defines.events.on_gui_click] = extras.handle.extras_trains_gui_open },
		},
	})
end

--- @param player LuaPlayer
function extras.reset_trains_anchor(player)
	local frame = player.gui.relative[TRAINS_ANCHOR]
	if frame and frame.valid then frame.destroy() end
	extras.ensure_trains_anchor(player)
end

function extras.handle.extras_trains_gui_open(player, pd)
	if open_manager_fn then open_manager_fn(player, pd, "trains_tab") end
end

-- ---------------------------------------------------------------- HUD line (§11.9)

--- @param player LuaPlayer
--- @param pd PlayerData
--- @return boolean
local function hud_wanted(player, pd)
	if pd.hud_on == nil then
		local s = settings.get_player_settings(player)["cybersyn-manager-hud"]
		pd.hud_on = s ~= nil and s.value == true
	end
	return pd.hud_on
end

--- Networks that have Cybersyn trains, at most a minute old: the available-train counters only know networks that
--- had a train available since the load, and a network whose trains were never free has 0 free trains, not none.
--- Only the HUD tick writes the cache; any other caller (the read-only query interface) reads it or scans.
--- @param keep boolean write the scan into the cache
--- @return {[string]: true}
local function train_networks(keep)
	local m = storage.manager
	local cached = m and m.hud_networks
	if cached and game.tick - cached.tick < 3600 then return cached.set end
	local set = {}
	for _, train in pairs(storage.trains) do
		local net = train.network_name
		if net == NETWORK_EACH then
			local mask = train.network_mask
			if type(mask) == "table" then
				for n in pairs(mask) do set[n] = true end
			end
		elseif net then
			set[net] = true
		end
	end
	if keep and m then m.hud_networks = { tick = game.tick, set = set } end
	return set
end

--- The HUD's two captions, from diag.counts_by_reason(), the available-train counters and the cached network set;
--- nothing here wakes the collector.
--- @param keep boolean? cache the network scan (the HUD tick only)
--- @return LocalisedString line1
--- @return LocalisedString line2
--- @return table values
function extras.hud_text(keep)
	local d = storage.diag
	local s = stats.get()
	local v = logic.hud_values(diag.counts_by_reason(), s and s.available_count or {}, train_networks(keep == true))
	local headroom = v.headroom and format.number(v.headroom) or utext.NO_VALUE
	if not d then
		return { "cybersyn-gui.hud-line-off", headroom }, { "cybersyn-gui.hud-diag-off" }, v
	end
	local line2
	if v.unserved == 0 then
		line2 = { "cybersyn-gui.hud-all-served" }
	else
		line2 = { "cybersyn-gui.hud-top", utext.chip_caption(v.top_reason), format.number(v.top_count) }
	end
	return { "cybersyn-gui.hud-line", format.number(v.unserved), headroom }, line2, v
end

--- @param player LuaPlayer
--- @param pd PlayerData
--- @return LuaGuiElement
local function hud_frame(player, pd)
	local frame = player.gui.screen[HUD]
	if frame and frame.valid then return frame end
	local _, f = gui.add(player.gui.screen, {
		type = "frame",
		name = HUD,
		style = "cybersyn_hud_frame",
		direction = "horizontal",
		handler = { [defines.events.on_gui_location_changed] = extras.handle.extras_hud_moved },
		{ type = "empty-widget", name = "drag", style = "cybersyn_hud_drag" },
		{
			type = "flow",
			name = "lines",
			direction = "vertical",
			style_mods = { vertical_spacing = 0 },
			{ type = "label", name = "line1", style = "cybersyn_hud_label", tooltip = { "cybersyn-gui.hud-tooltip" },
				handler = { [defines.events.on_gui_click] = extras.handle.extras_hud_click } },
			{ type = "label", name = "line2", style = "cybersyn_hud_note", tooltip = { "cybersyn-gui.hud-tooltip" },
				handler = { [defines.events.on_gui_click] = extras.handle.extras_hud_click } },
		},
	})
	f.drag.drag_target = f
	local loc = pd.hud_location
	if loc then
		f.location = loc
	else
		local scale = player.display_scale
		f.location = { x = math.floor(12 * scale), y = math.floor(player.display_resolution.height * 0.5) }
	end
	return f
end

--- Shows, refreshes or removes one player's HUD.
--- @param player LuaPlayer
--- @param pd PlayerData
function extras.hud_refresh(player, pd)
	if not hud_wanted(player, pd) then
		local frame = player.gui.screen[HUD]
		if frame and frame.valid then frame.destroy() end
		return
	end
	local frame = hud_frame(player, pd)
	local l1, l2 = extras.hud_text(true)
	frame.lines.line1.caption = l1
	frame.lines.line2.caption = l2
end

--- Every HUD_TICKS (registered unconditionally in scripts/main.lua): connected players with the setting on.
function extras.hud_tick()
	local manager_data = storage.manager
	if not manager_data then return end
	for i, pd in pairs(manager_data.players) do
		local player = game.get_player(i)
		if player and player.connected and (pd.hud_on ~= false) then extras.hud_refresh(player, pd) end
	end
end

--- The per-user setting changed: read it again and apply it now.
--- @param player LuaPlayer
--- @param pd PlayerData
function extras.hud_setting_changed(player, pd)
	pd.hud_on = nil
	extras.hud_refresh(player, pd)
end

function extras.handle.extras_hud_moved(player, pd, e)
	local loc = e.element.location
	if loc then pd.hud_location = { x = loc.x, y = loc.y } end
end

function extras.handle.extras_hud_click(player, pd)
	if open_manager_fn then open_manager_fn(player, pd, "overview_tab") end
end

-- ---------------------------------------------------------------- manager tick

--- Drops a trace whose objects timed out.
--- @param manager_data Manager
function extras.tick(manager_data)
	local now = game.tick
	for _, pd in pairs(manager_data.players) do
		local t = pd.path_trace
		if t and now >= t.until_tick then pd.path_trace = nil end
	end
end

--- @param player LuaPlayer
--- @param pd PlayerData
function extras.reset(player, pd)
	extras.clear_path_trace(pd)
	extras.reset_trains_anchor(player)
	local hud = player.gui.screen[HUD]
	if hud and hud.valid then hud.destroy() end
	pd.hud_on = nil
end

function extras.wrapper(e, handler)
	local player = game.get_player(e.player_index)
	local pd = storage.manager and storage.manager.players[e.player_index]
	if not (player and pd) then return end
	handler(player, pd, e)
end

gui.add_handlers(extras.handle, extras.wrapper, "cybersyn_extras")
util.set_pin(extras.add_pin)

-- ---------------------------------------------------------------- dev interface

local function dev_context(pi)
	local player = game.get_player(pi)
	if not player then error("no player " .. tostring(pi)) end
	local pd = storage.manager.players[pi]
	if not pd then error("no manager data for player " .. tostring(pi)) end
	return player, pd
end

--- The mod's rendering objects for one player (or all of them).
local function object_count(player)
	local n = 0
	for _, obj in ipairs(rendering.get_all_objects(script.mod_name)) do
		if obj.valid then
			if not player then
				n = n + 1
			else
				local players = obj.players
				for _, p in ipairs(players or {}) do
					if p.index == player.index then
						n = n + 1
						break
					end
				end
			end
		end
	end
	return n
end

dev.extend({
	--- Draws a trace for a train (the one with the longest path when id is nil), timing the draw.
	path_trace = function(pi, train_id)
		local player, pd = dev_context(pi)
		if not train_id then
			local best, best_d
			for id, train in pairs(storage.trains) do
				local entity = train.entity
				local path = entity and entity.valid and entity.path
				if path and path.valid and (not best_d or path.total_distance > best_d) then
					best, best_d = id, path.total_distance
				end
			end
			train_id = best
			if not train_id then return { error = "no train has a path" } end
		end
		local before = object_count(player)
		local p = game.create_profiler()
		local trace, why = extras.draw_path_trace(player, pd, train_id)
		p.stop()
		local entity = lua_train(train_id)
		local path = entity and entity.path
		return {
			train_id = train_id,
			drawn = trace ~= nil,
			why = why,
			rails = trace and trace.rails,
			size = trace and trace.size,
			runs = trace and trace.runs,
			segments = trace and trace.segments,
			objects = trace and #trace.ids or 0,
			before = before,
			after = object_count(player),
			total_distance = path and path.valid and path.total_distance or nil,
			ms = { "", p },
		}
	end,
	path_trace_state = function(pi)
		local player, pd = dev_context(pi)
		local t = pd.path_trace
		return { shown = t ~= nil, train_id = t and t.train_id, objects = object_count(player), all = object_count(nil),
			until_tick = t and t.until_tick, tick = game.tick }
	end,
	path_trace_clear = function(pi)
		local _, pd = dev_context(pi)
		extras.clear_path_trace(pd)
	end,
	path_trace_select = function(pi, kind, id)
		local _, pd = dev_context(pi)
		extras.on_selection(pd, kind, id)
	end,
	last_pin = function(pi)
		local _, pd = dev_context(pi)
		return pd.last_pin
	end,
	test_path = function(pi, stop_id, train_id)
		local player, pd = dev_context(pi)
		local r = extras.test_path(player, pd, stop_id, train_id)
		if not r then return nil end
		return { stop_id = r.stop_id, train_id = r.train_id, found = r.found, no_rail = r.no_rail, length = r.length,
			depot = r.depot, caption = extras.path_caption(r) }
	end,
	--- Emulates the click on the trains-window button (an offline player cannot open the vanilla trains window).
	trains_gui_button = function(pi)
		local player, pd = dev_context(pi)
		extras.ensure_trains_anchor(player)
		local frame = player.gui.relative[TRAINS_ANCHOR]
		local anchor = frame.anchor
		extras.handle.extras_trains_gui_open(player, pd)
		return { exists = frame.valid, anchor_gui = anchor and anchor.gui, caption = frame.open_manager.caption,
			opened = pd.is_manager_open == true, tab = pd.selected_tab }
	end,
	hud = function(pi, on)
		local player, pd = dev_context(pi)
		if on ~= nil then
			settings.get_player_settings(player)["cybersyn-manager-hud"] = { value = on }
			pd.hud_on = nil
		end
		extras.hud_refresh(player, pd)
		local frame = player.gui.screen[HUD]
		local _, _, v = extras.hud_text()
		return {
			shown = frame ~= nil and frame.valid,
			line1 = frame and frame.valid and frame.lines.line1.caption or nil,
			line2 = frame and frame.valid and frame.lines.line2.caption or nil,
			values = v,
			location = frame and frame.valid and frame.location or nil,
		}
	end,
	hud_move = function(pi, x, y)
		local player, pd = dev_context(pi)
		local frame = player.gui.screen[HUD]
		if not (frame and frame.valid) then return nil end
		frame.location = { x = x, y = y }
		extras.handle.extras_hud_moved(player, pd, { element = frame })
		return pd.hud_location
	end,
})

return extras
