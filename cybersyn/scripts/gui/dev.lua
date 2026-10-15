-- Test hooks for driving the manager headlessly over RCON (remote interface "cybersyn-manager-dev"). Dev only: not a
-- stable API, and nothing in the mod or its compatibility code calls it. It is registered only when the startup
-- setting cybersyn-manager-dev-interface is on: startup settings are the same for every peer, unlike game state or
-- runtime settings, so a server and a joining client always agree on it.
-- Tab modules register dumpers here, so this file must not require the tab modules or manager.lua.

local flib_gui = require("__flib__.gui")
local util = require("scripts.gui.util")
local collector = require("scripts.gui.collector")

local dev = {}

--- Function registries filled while modules load; identical in every Lua state, so not game state.
--- @type {[string]: fun(player_data: PlayerData, player: LuaPlayer): any}
local dumpers = {}
local stats_fn

local manager_gui, manager

--- @param tab string "stations" or "stations_tab"
--- @return string
local function canonical(tab)
	if tab == "breakdown" then return "delivery_breakdown_tab" end
	if string.sub(tab, -4) ~= "_tab" then
		return tab .. "_tab"
	end
	return tab
end

--- Tab modules call this at load time. The dumper returns plain data describing what is rendered, in display order.
--- @param tab_name string
--- @param fn fun(player_data: PlayerData, player: LuaPlayer): any
function dev.register_dump(tab_name, fn)
	dumpers[canonical(tab_name)] = fn
end

--- The stats module may register a summary function for dev.stats().
--- @param fn fun(): any
function dev.register_stats(fn)
	stats_fn = fn
end

local function context(pi)
	local player = game.get_player(pi)
	if not player then error("no player " .. tostring(pi)) end
	local player_data = storage.manager.players[pi]
	if not player_data then error("no manager data for player " .. tostring(pi)) end
	return player, player_data, player_data.refs
end

local function state(pi)
	local _, pd = context(pi)
	return {
		is_open = pd.is_manager_open == true,
		selected_tab = pd.selected_tab,
		paused = pd.paused == true,
		pinning = pd.pinning == true,
		last_update_tick = pd.last_update_tick,
		rendered_snapshot_tick = pd.rendered_snapshot_tick,
		page = pd.page,
		page_size = util.page_size(pd),
		sort = pd.sort,
		filters = util.get_filters(pd),
		hover = pd.hover,
		tick = game.tick,
	}
end

local function render(player, pd)
	if pd.is_manager_open then manager.render(player, pd) end
end

local function summary()
	local s = collector.get()
	local function count(t)
		local n = 0
		for _ in pairs(t) do n = n + 1 end
		return n
	end
	local warming, comb_bad = 0, 0
	for _, st in pairs(s.stations) do
		if st.warming_up then warming = warming + 1 end
		if not st.comb_ok then comb_bad = comb_bad + 1 end
	end
	return {
		tick = s.tick,
		started_tick = s.started_tick,
		station_count = s.station_count,
		train_count = s.train_count,
		secondary = s.secondary_count,
		warming_up = warming,
		comb_not_ok = comb_bad,
		provided_items = count(s.inventory_all.provided),
		requested_items = count(s.inventory_all.requested),
		in_transit_items = count(s.inventory_all.in_transit),
		starved_keys = count(s.starved),
		starved_items = count(s.starved_items),
		starved_source = s.starved_source,
		fleet_total = s.fleet.total,
		fleet_by_status = s.fleet.by_status,
		available_by_network = s.fleet.available_by_network,
		layouts = count(s.fleet.by_layout),
		depots = s.depots,
		alerts = #s.alerts,
		tick_state = storage.tick_state,
	}
end

local function profile(n, fn)
	local total = game.create_profiler()
	local avg = game.create_profiler()
	for _ = 1, n do
		fn()
	end
	total.stop()
	avg.stop()
	avg.divide(n)
	return { "", "n=", n, " total ", total, " avg ", avg }
end

local interface = {}

--- Opens the manager pinned. Unless `async`, a pass the opening started is finished at once and the tab rendered
--- again, so a test or screenshot right after sees collected data; with `async` it runs over the next updates as for
--- a player.
function interface.open(pi, async)
	local player, pd, refs = context(pi)
	-- Pinned so no player.opened is needed (the lab player is offline).
	pd.pinning = true
	if not pd.is_manager_open then
		manager.handle.manager_open(player, pd, refs)
		if not async and collector.collecting() then
			collector.run_to_completion()
			manager.render(player, pd)
		end
	end
	manager.refresh_toggles(pd)
	return state(pi)
end

--- The title-bar status caption and the boosted pass progress (nil when no boosted pass runs).
function interface.status(pi)
	local _, pd, refs = context(pi)
	local label = refs.manager_updated_label
	return { caption = label and label.valid and label.caption or nil, collecting = collector.collecting(), snapshot_tick = collector.get().tick }
end

--- util.parse_rich_name, for checking the parser against names from a real save.
function interface.parse_name(name)
	return util.parse_rich_name(name)
end

function interface.close(pi)
	local player, pd, refs = context(pi)
	manager.handle.manager_close(player, pd, refs)
	return state(pi)
end

function interface.select_tab(pi, tab)
	local player, pd = context(pi)
	if not util.select_tab(pd, canonical(tab)) then
		return "no such tab: " .. tostring(tab)
	end
	render(player, pd)
	return pd.selected_tab
end

--- Keys present in `f` are applied; pass false to clear one. item is an item hash.
function interface.set_filter(pi, f)
	local player, pd = context(pi)
	f = f or {}
	if f.query ~= nil then util.set_search_query(pd, f.query or nil) end
	if f.item ~= nil then pd.search_item = f.item or nil end
	if f.network ~= nil then pd.search_network_name = f.network or nil end
	if f.mask ~= nil then pd.search_network_mask = f.mask or -1 end
	if f.surface ~= nil then pd.search_surface_idx = f.surface or nil end
	util.reset_pages(pd)
	manager.restore_filter_widgets(pd)
	render(player, pd)
	return util.get_filters(pd)
end

function interface.clear_filters(pi)
	local player, pd, refs = context(pi)
	manager.handle.manager_clear_filters(player, pd, refs)
	return util.get_filters(pd)
end

function interface.set_sort(pi, tab, column, ascending)
	local player, pd = context(pi)
	tab = canonical(tab)
	util.set_sort(pd, tab, column, ascending)
	manager.refresh_sort_headers(pd)
	render(player, pd)
	return pd.sort[tab]
end

function interface.set_page(pi, tab, page)
	local player, pd = context(pi)
	tab = canonical(tab)
	pd.page = pd.page or {}
	pd.page[tab] = page
	render(player, pd)
	return pd.page[tab]
end

--- Sets the Overview period (minutes: 10, 60 or 1440) as the drop-down would.
function interface.set_period(pi, minutes)
	local player, pd = context(pi)
	pd.overview_period = minutes
	render(player, pd)
	return pd.overview_period
end

function interface.set_paused(pi, paused)
	local player, pd = context(pi)
	pd.paused = paused and true or false
	manager.refresh_toggles(pd)
	if pd.paused then
		manager.update_status(pd)
	else
		render(player, pd)
	end
	return state(pi)
end

function interface.collect()
	storage.manager.snapshot_build = nil
	collector.run_to_completion()
	return summary()
end

function interface.summary()
	return summary()
end

--- Times `n` renders of the selected tab (no collection).
function interface.update(pi, n)
	local player, pd = context(pi)
	n = n or 1
	return profile(n, function()
		manager.update(storage, pd)
	end)
end

--- Times `n` full manager ticks (collector step + render for every open player).
function interface.tick(n)
	n = n or 1
	return profile(n, function()
		manager_gui.tick(storage)
	end)
end

--- One manager tick for player `pi`, its collector step and render timed separately, with the heap change (a drop
--- means a garbage collection cycle finished inside it); flags a completed pass.
function interface.tick_split(pi)
	local player, pd = context(pi)
	local before = collector.get().tick
	local heap = collectgarbage("count")
	local step = game.create_profiler()
	collector.tick()
	step.stop()
	local render = game.create_profiler()
	manager.render(player, pd)
	render.stop()
	return { "", "step ", step, " render ", render, " heap ", math.floor(collectgarbage("count") - heap), " KB",
		collector.get().tick ~= before and " (pass done)" or "" }
end

--- One collector step over at most `budget` stations, then a render of player `pi`: a pass in small steps on a
--- small save.
--- @return boolean completed
function interface.step(pi, budget)
	local player, pd = context(pi)
	local done = collector.step(budget)
	manager.render(player, pd)
	return done
end

--- Times `n` collector steps at the default batch size, then one full pass.
function interface.bench_collect(n)
	n = n or 1
	storage.manager.snapshot_build = nil
	local steps = profile(n, function()
		collector.step()
	end)
	storage.manager.snapshot_build = nil
	local full = profile(1, collector.run_to_completion)
	return { "", "steps: ", steps, "\nfull pass: ", full }
end

--- Times every budgeted collector step of one fresh pass, plus the render of player `pi` after each, separately.
--- Returns one LocalisedString per step.
function interface.bench_pass(pi)
	local pd = pi and select(2, context(pi))
	storage.manager.snapshot_build = nil
	local out = {}
	local done = false
	while not done do
		local step = game.create_profiler()
		done = collector.step()
		step.stop()
		local render = game.create_profiler()
		if pd then manager.update(storage, pd) end
		render.stop()
		out[#out + 1] = { "", #out + 1, done and " (last)" or "", " step ", step, " render ", render }
	end
	return out
end

function interface.dump(pi, tab)
	local player, pd = context(pi)
	tab = canonical(tab or pd.selected_tab or "")
	local fn = dumpers[tab]
	if not fn then return "no dumper for " .. tab end
	return fn(pd, player)
end

function interface.stats()
	if stats_fn then return stats_fn() end
	return storage.stats and storage.stats.totals or "no stats"
end

function interface.state(pi)
	return state(pi)
end

--- Rough size census of the snapshot: table and entry counts per station field.
function interface.census()
	local s = collector.get()
	local out = { stations = 0, station_fields = 0 }
	for _, st in pairs(s.stations) do
		out.stations = out.stations + 1
		for k, v in pairs(st) do
			out.station_fields = out.station_fields + 1
			if type(v) == "table" then
				local n = 0
				for _ in pairs(v) do n = n + 1 end
				out[k] = (out[k] or 0) + n
				out[k .. "_tables"] = (out[k .. "_tables"] or 0) + 1
			end
		end
	end
	local trains, manifest = 0, 0
	for _, tr in pairs(s.trains) do
		trains = trains + 1
		manifest = manifest + #tr.manifest
	end
	out.trains = trains
	out.manifest_entries = manifest
	return out
end

--- Discards both snapshot buffers (for measuring their memory).
function interface.drop_snapshot()
	storage.manager.snapshot = collector.empty()
	storage.manager.snapshot_build = nil
	return "ok"
end

--- Lua heap in KB, optionally after a full garbage collection.
function interface.mem(collect)
	if collect then collectgarbage("collect") end
	return (collectgarbage("count"))
end

--- Proves hover dispatch end to end without a cursor: raises a synthetic on_gui_hover (or on_gui_leave) through
--- flib on child `child_index` of the element `refs[container]`.
function interface.hover(pi, container, child_index, leave)
	local _, pd, refs = context(pi)
	local parent = refs[container]
	if not parent or not parent.valid then return "no container " .. tostring(container) end
	local child = parent.children[child_index or 1]
	if not child then return "container is empty" end
	local handled = flib_gui.dispatch({
		name = leave and defines.events.on_gui_leave or defines.events.on_gui_hover,
		element = child,
		player_index = pi,
		tick = game.tick,
	})
	local tags = child.tags
	local scope = tags.hover_scope or parent.name
	return {
		handled = handled,
		raise_hover_events = child.raise_hover_events,
		handler_tag = tags["__" .. script.mod_name .. "_handler"],
		hover = pd.hover,
		hold = util.hold_active(pd, scope),
	}
end

--- Which GUI events this mod has a handler for.
function interface.check_dispatch()
	return {
		on_gui_hover = script.get_event_handler(defines.events.on_gui_hover) ~= nil,
		on_gui_leave = script.get_event_handler(defines.events.on_gui_leave) ~= nil,
		on_gui_selected_tab_changed = script.get_event_handler(defines.events.on_gui_selected_tab_changed) ~= nil,
		on_gui_click = script.get_event_handler(defines.events.on_gui_click) ~= nil,
		on_player_left_game = script.get_event_handler(defines.events.on_player_left_game) ~= nil,
	}
end

--- Writes a runtime-global setting of this mod (no other mod's) from the mod's own context, which script-driven tests
--- cannot do from level scope. Fires on_runtime_mod_setting_changed like a change from the settings GUI.
--- @param name string
--- @param value boolean|number|string
function interface.set_setting(name, value)
	local proto = type(name) == "string" and prototypes.mod_setting[name]
	if not (proto and proto.mod == script.mod_name and proto.setting_type == "runtime-global") then
		error("not a runtime-global setting of " .. script.mod_name .. ": " .. tostring(name))
	end
	settings.global[name] = { value = value }
	return settings.global[name].value
end

--- @return boolean
function dev.enabled()
	local setting = settings.startup["cybersyn-manager-dev-interface"]
	return setting ~= nil and setting.value == true
end

--- @param gui_main table scripts/gui/main.lua module (manager_gui)
--- @param gui_manager table scripts/gui/manager.lua module
function dev.register(gui_main, gui_manager)
	manager_gui = gui_main
	manager = gui_manager
	if dev.enabled() and not remote.interfaces["cybersyn-manager-dev"] then
		remote.add_interface("cybersyn-manager-dev", interface)
	end
end

return dev
