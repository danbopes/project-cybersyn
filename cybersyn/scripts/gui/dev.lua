-- Test hooks for driving the manager headlessly over RCON (remote interface "cybersyn-manager-dev"). Dev only: not a
-- stable API, and nothing in the mod or its compatibility code calls it. It is registered only when the startup
-- setting cybersyn-manager-dev-interface is on: startup settings are the same for every peer, unlike game state or
-- runtime settings, so a server and a joining client always agree on it.
-- Tab modules register dumpers here, so this file must not require the tab modules or manager.lua.

local flib_gui = require("__flib__.gui")
local util = require("scripts.gui.util")
local collector = require("scripts.gui.collector")
local diag = require("scripts.diag")
local stats = require("scripts.stats")
local lint = require("scripts.lint")

local dev = {}

--- Function registries filled while modules load; identical in every Lua state, so not game state.
--- @type {[string]: fun(player_data: PlayerData, player: LuaPlayer): any}
local dumpers = {}
local stats_fn

local manager_gui, manager
--- Functions tab modules add with dev.add, merged into the interface when it is registered.
local dev_functions = {}

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

--- A tab module adds a dev function of its own (loaded before dev.register publishes the interface).
--- @param name string
--- @param fn function
function dev.add(name, fn)
	dev_functions[name] = fn
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
		page_size = util.page_size(pd, pd.selected_tab),
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

--- The selected tab's subheader progress ("Collecting… n %", nil while hidden), the title-bar status caption and
--- whether it shows, and the boosted pass progress (nil when no boosted pass runs).
function interface.status(pi)
	local _, pd, refs = context(pi)
	local label = refs.manager_updated_label
	local note = refs[(pd.selected_tab or "overview_tab") .. "_collecting"]
	return {
		subheader = note and note.valid and note.visible and note.caption or nil,
		caption = label and label.valid and label.caption or nil,
		title_visible = label and label.valid and label.visible or false,
		collecting = collector.collecting(),
		snapshot_tick = collector.get().tick,
	}
end

local ROW_COUNTERS = {}

--- Tab modules report how many rows they render (PLAN3 §6 gate 5).
--- @param tab string
--- @param fn fun(player_data: PlayerData): int
function dev.register_rows(tab, fn)
	ROW_COUNTERS[canonical(tab)] = fn
end

--- Computed against rendered rows of a tab, and the window height against 0.85 of the screen.
function interface.rows(pi, tab)
	local player, pd = context(pi)
	tab = canonical(tab or pd.selected_tab or "overview")
	local layout = pd.layout or manager.layout(player, pd)
	local fn = ROW_COUNTERS[tab]
	return {
		tab = tab,
		computed = layout.rows_by_tab[tab],
		rendered = fn and fn(pd) or nil,
		page_size = util.page_size(pd, tab),
		width = layout.width,
		content_height = layout.content_height,
		window_height = layout.window_height,
		max_height = math.floor(0.85 * layout.screen_height),
		screen = { layout.screen_width, layout.screen_height, layout.scale },
	}
end

--- Emulates another screen (physical resolution and UI scale) for the layout; no arguments = the player's own.
function interface.set_layout(pi, width, height, scale)
	local player, pd = context(pi)
	pd.layout_override = width and { width = width, height = height, scale = scale or 1 } or nil
	manager.relayout(player, pd)
	return interface.rows(pi, pd.selected_tab)
end

--- The search custom input (Ctrl+F) as the player would press it.
function interface.search_input(pi)
	manager.on_search_input({ player_index = pi, input_name = "cybersyn-manager-search" })
	local _, pd, refs = context(pi)
	local field = refs[(pd.selected_tab or "") .. "_search_field"]
	return { selected_tab = pd.selected_tab, open = pd.search_open == true, visible = field and field.valid and field.visible or false }
end

--- Escape in the focused search field.
function interface.cancel_search(pi)
	local player, pd = context(pi)
	pd.search_focused = true
	return manager.cancel_search(player, pd)
end

--- The strips at the top of every tab: banner, search field, item chip, collecting note.
function interface.header(pi)
	local _, pd, refs = context(pi)
	local out = {}
	for _, tab in ipairs({ "overview_tab", "inventory_tab", "stations_tab", "trains_tab" }) do
		local function get(name)
			local e = refs[tab .. name]
			return e and e.valid and e or nil
		end
		local banner, label, field, chip, flow = get("_banner"), get("_banner_label"), get("_search_field"), get("_chip"), get("_chip_flow")
		out[tab] = {
			banner = banner and banner.visible or false,
			banner_caption = label and label.caption or nil,
			search = field and field.visible or false,
			search_text = field and field.text or nil,
			chip = flow and flow.visible or false,
			chip_caption = chip and chip.caption or nil,
			chip_tooltip = chip and chip.tooltip or nil,
		}
	end
	out.filter_row = refs.manager_filter_row.visible
	out.filter_button = refs.manager_filter_button.style.name
	out.search_button = refs.manager_search_button.style.name
	out.back_button = refs.manager_back_button.visible
	out.trains_badge = refs.manager_trains_tab.badge_text
	out.location = pd.location
	out.layout_width = pd.layout and pd.layout.width
	return out
end

--- Clicks child `index` of the element refs[ref] (or the element itself when index is nil; a list of indices walks
--- down that many levels) through flib, with optional modifiers {shift, control, alt, right}.
function interface.click(pi, ref, index, mods)
	local _, pd, refs = context(pi)
	local elem = refs[ref]
	if not (elem and elem.valid) then return "no element " .. tostring(ref) end
	for _, i in ipairs(type(index) == "table" and index or { index }) do
		elem = elem.children[i]
		if not elem then return "no child " .. serpent.line(index) end
	end
	mods = mods or {}
	return flib_gui.dispatch({
		name = defines.events.on_gui_click,
		element = elem,
		player_index = pi,
		tick = game.tick,
		button = mods.right and defines.mouse_button_type.right or defines.mouse_button_type.left,
		shift = mods.shift == true,
		control = mods.control == true,
		alt = mods.alt == true,
	})
end

--- Escape as an unpinned player presses it (on_gui_closed of the window); the pin is restored afterwards.
function interface.escape(pi)
	local player, pd, refs = context(pi)
	local pinning = pd.pinning
	pd.pinning = false
	manager.handle.manager_closed_by_game(player, pd, refs)
	pd.pinning = pinning
	return state(pi)
end

--- /cybersyn-reset-gui for player `pi`.
function interface.reset_gui(pi)
	local player = context(pi)
	manager_gui.reset_gui(player)
	return interface.header(pi)
end

--- A runtime-global setting written as player `pi` would from the settings GUI: the change event carries that
--- player's index (a script write carries none).
function interface.set_setting_as(pi, name, value)
	interface.set_setting(name, value)
	manager_gui.on_runtime_mod_setting_changed({ setting = name, setting_type = "runtime-global", player_index = pi })
	return settings.global[name].value
end

--- A player setting of this mod for player `pi`, written from the mod's context.
function interface.set_player_setting(pi, name, value)
	local proto = prototypes.mod_setting[name]
	if not (proto and proto.mod == script.mod_name and proto.setting_type == "runtime-per-user") then
		error("not a runtime-per-user setting of " .. script.mod_name .. ": " .. tostring(name))
	end
	settings.get_player_settings(pi)[name] = { value = value }
	local _, pd = context(pi)
	pd.unserved_minutes = nil
	pd.page_size = nil
	return settings.get_player_settings(pi)[name].value
end

--- Clicks a link cell's semantics (util.handle_link_click) without a cursor.
function interface.link_click(pi, kind, id, mods)
	local player, pd = context(pi)
	mods = mods or {}
	local fake = {
		element = { tags = { kind = kind, id = id } },
		button = mods.right and defines.mouse_button_type.right or defines.mouse_button_type.left,
		shift = mods.shift == true, control = mods.control == true, alt = mods.alt == true,
		player_index = pi,
	}
	util.handle_link_click(player, pd, fake)
	return {
		controller = player.controller_type,
		pinning = pd.pinning == true,
		auto_pinned = pd.auto_pinned == true,
		markers = pd.markers,
		opened = player.opened and player.opened.name or nil,
		item = pd.search_item,
		tab = pd.selected_tab,
	}
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

--- `n` runs of the fixed export tick (one export chunk each).
function interface.export_tick(n)
	for _ = 1, n or 1 do manager_gui.export_tick() end
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

-- ---- diagnostics (PLAN3 §4.5, §6 gate 2; the contract in tests/lab/README.md)

--- @param e DiagEntry
--- @return table plain copy with reason names instead of codes
local function entry_view(e)
	local rej = {}
	for i = 1, REJ_COUNT do
		if e.rej[i] ~= 0 then rej[REJ_NAMES[i]] = e.rej[i] end
	end
	return {
		reason = REASON_NAMES[e.reason],
		pending = e.pending and REASON_NAMES[e.pending] or nil,
		pending_since = e.pending_since,
		n = e.n,
		first_tick = e.first_tick,
		last_tick = e.last_tick,
		p_station_id = e.p_station_id,
		p_count = e.p_count,
		p_threshold = e.p_threshold,
		lost_n = e.lost_n,
		lost_to = e.lost_to,
		a = e.a,
		b = e.b,
		rej = rej,
		changes = #e.changes,
		suppressed_until = e.suppressed_until,
	}
end

--- Unserved entries of one requester, keyed by item hash.
--- @param r_station_id uint
function interface.diag_unserved(r_station_id)
	local d = storage.diag
	local out = {}
	local by_item = d and d.unserved[r_station_id]
	if not by_item then return out end
	for ix, e in pairs(by_item) do
		out[d.item_hash[ix]] = entry_view(e)
	end
	return out
end

--- Live entries per confirmed reason name.
function interface.diag_counts()
	local out = {}
	for code, n in pairs(diag.counts_by_reason()) do
		out[REASON_NAMES[code]] = n
	end
	return out
end

--- @param ev table a diag.events row
local function event_view(ev, d)
	return {
		seq = ev.seq,
		tick = ev.tick,
		kind = DIAG_KIND_NAMES[ev.kind] or ev.kind,
		sev = DIAG_SEV_NAMES[ev.sev] or ev.sev,
		code = ev.code,
		code_name = diag.code_name(ev.kind, ev.code),
		delivery = ev.delivery,
		train = ev.train,
		station = ev.station,
		station2 = ev.station2,
		item = ev.item ~= 0 and d.item_hash[ev.item] or nil,
		a = ev.a,
		b = ev.b,
	}
end

--- Events with seq above from_seq (exclusive), oldest first; from_seq nil = the newest `limit`.
function interface.diag_events(from_seq, limit)
	local d = storage.diag
	local out = {}
	if not d then return out end
	for i, ev in ipairs(diag.events(nil, from_seq, limit or 1000)) do out[i] = event_view(ev, d) end
	return out
end

--- diag.last_for, as plain rows.
function interface.diag_last_for(kind, id, n)
	local d = storage.diag
	local out = {}
	if not d then return out end
	for i, ev in ipairs(diag.last_for(kind, id, n or 10)) do out[i] = event_view(ev, d) end
	return out
end

--- diag.unserved_rows, as plain rows.
function interface.diag_unserved_rows(limit, item, reason_name)
	local out = {}
	local rows = diag.unserved_rows({ limit = limit, item = item, reason = reason_name and REASON_BY_NAME[reason_name] })
	for i, r in ipairs(rows) do
		out[i] = { r_station_id = r.r_station_id, hash = r.hash, reason = REASON_NAMES[r.entry.reason],
			first_tick = r.entry.first_tick }
	end
	return out
end

function interface.diag_state()
	local d = storage.diag
	local verify = storage.diag_verify_interrupt
	local _, horizon = diag.horizon()
	local out = {
		mode = d and d.mode or "off",
		ring_basic_size = d and d.ring_basic.size or 0,
		ring_full_size = d and d.ring_full.size or 0,
		count_basic = d and d.ring_basic.count or 0,
		count_full = d and d.ring_full.count or 0,
		seq = d and d.seq or 0,
		unserved_entries = d and d.unserved_n or 0,
		unserved_dropped = d and d.unserved_dropped or 0,
		loaded_tick = d and d.loaded_tick or nil,
		inherit_until = d and d.inherit_until or nil,
		inherit_open = d ~= nil and d.inherit_cycles ~= nil,
		horizon_ticks = horizon,
		interrupt_checks = verify and verify.checks or nil,
		interrupt_mismatches = verify and verify.mismatches or nil,
		export_jobs = #diag.export_jobs(),
		kinds = DIAG_KIND_NAMES,
		tick = game.tick,
	}
	return out
end

--- Writes one ring event as a hook would (tests of the Log): kind and sev by name, the other columns from `f`.
--- @return uint? seq
function interface.diag_event(kind_name, sev_name, f)
	local d = storage.diag
	if not d then return nil end
	local kind, sev
	for k, name in ipairs(DIAG_KIND_NAMES) do if name == kind_name then kind = k end end
	for k, name in ipairs(DIAG_SEV_NAMES) do if name == sev_name then sev = k end end
	if not (kind and sev) then error("unknown kind or severity " .. tostring(kind_name) .. " " .. tostring(sev_name)) end
	f = f or {}
	local item = f.item and diag.intern(d, f.item) or 0
	return diag.event(d, kind, sev, f.code or 0, f.delivery or 0, f.train or 0, f.station or 0, f.station2 or 0, item,
		f.a or 0, f.b or 0)
end

function interface.diag_reset()
	diag.reset()
	return interface.diag_state()
end

--- Exports the rings at once (the GUI's export runs in chunks on a fixed nth tick) and returns the path under
--- script-output.
function interface.diag_export(pi)
	local player = pi and pi > 0 and game.get_player(pi)
	local path = diag.export(player and player.connected and pi or 0, nil)
	if not path then return nil end
	local d = storage.diag
	while d.export_jobs[1] do diag.export_step() end
	return path
end

--- Queues an export like the GUI would; the manager tick writes it.
function interface.diag_export_async(pi)
	local player = pi and pi > 0 and game.get_player(pi)
	return diag.export(player and player.connected and pi or 0, nil)
end

--- @param kind "request"|"station"|"lint"
--- @param until_ticks uint? from now; nil = until the reason changes
function interface.diag_ack(kind, id, sub, until_ticks, player_index)
	local ack = diag.ack(kind, id, sub, player_index, until_ticks and (game.tick + until_ticks) or nil)
	return { player_index = ack.player_index, tick = ack.tick, until_tick = ack.until_tick,
		reason = ack.reason and REASON_NAMES[ack.reason] or nil }
end

function interface.diag_unack(kind, id, sub, player_index)
	return diag.unack(kind, id, sub, player_index)
end

function interface.diag_is_acked(kind, id, sub)
	return diag.is_acked(kind, id, sub) ~= nil
end

function interface.diag_acks()
	return storage.acks
end

--- True exactly when the key's confirmed reason is `name` (PLAN3 §6 gate 2).
function interface.assert_reason(station_id, item_hash, name)
	local d = storage.diag
	local by_item = d and d.unserved[station_id]
	local ix = d and d.item_ix[item_hash]
	local e = by_item and ix and by_item[ix]
	return e ~= nil and REASON_NAMES[e.reason] == name
end

--- Lab flag DIAG_VERIFY_INTERRUPT: tick_dispatch also reads every candidate's schedule and counts the cases where
--- the cached in_interrupt disagrees (the decision still uses the cache, as without the flag).
function interface.diag_verify_interrupt(on)
	storage.diag_verify_interrupt = on and { checks = 0, mismatches = 0 } or nil
	return storage.diag_verify_interrupt
end

--- Compares the cached in_interrupt of every Cybersyn train with its schedule now.
function interface.diag_check_interrupts()
	local out = { trains = 0, in_interrupt = 0, mismatches = 0, ids = {} }
	for id, train in pairs(storage.trains) do
		local e = train.entity
		if e and e.valid then
			out.trains = out.trains + 1
			local live = train_in_interrupt(e)
			if live then out.in_interrupt = out.in_interrupt + 1 end
			if live ~= (train.in_interrupt == true) then
				out.mismatches = out.mismatches + 1
				out.ids[#out.ids + 1] = id
			end
		end
	end
	return out
end

--- Size of storage.diag as JSON, entry and ring counts (growth gate).
function interface.diag_size()
	local d = storage.diag
	if not d then return { json = 0 } end
	-- Entries some evaluation touched since the previous cycle began: the keys failing right now.
	local live = 0
	local since = d.cycle_prev or d.cycle_start
	for _, by_item in pairs(d.unserved) do
		for _, e in pairs(by_item) do
			if e.last_tick >= since then live = live + 1 end
		end
	end
	return {
		json = #helpers.table_to_json(d),
		acks_json = storage.acks and #helpers.table_to_json(storage.acks) or 0,
		unserved_entries = d.unserved_n,
		live_entries = live,
		cycle_ticks = d.cycle_prev and (d.cycle_start - d.cycle_prev) or nil,
		count_basic = d.ring_basic.count,
		count_full = d.ring_full.count,
		items = #d.item_hash,
		alert_last = table_size(d.alert_last),
		unpowered = table_size(d.unpowered),
		stations_with_entries = table_size(d.unserved),
	}
end

--- The always-on train and stats fields: available counters against the planner's table, the hour's minimum and
--- no-train failures.
function interface.diag_stats(minutes)
	local s = stats.get()
	local counts = {}
	for name, ids in pairs(storage.available_trains) do counts[name] = table_size(ids) end
	local agg = stats.aggregate(minutes or 60)
	return {
		available_count = s.available_count,
		available_actual = counts,
		min_available_by_network = agg.min_available_by_network,
		no_train_failures = agg.no_train_failures,
		cycle = s.cycle,
	}
end

--- The phase-2 snapshot fields: how many station and train records carry each, plus the declared fleet tables.
function interface.snapshot_fields()
	local snap = collector.get()
	local out = { stations = 0, read_tick = 0, lint_zero = 0, lint_number = 0, lint_matches = 0, unserved = 0,
		unserved_count = 0, trains = 0, state = 0,
		state_since = 0, in_interrupt_bool = 0, has_path_bool = 0, waiting_at_signal = 0, signal_unit_number = 0 }
	for _, st in pairs(snap.stations) do
		out.stations = out.stations + 1
		if st.read_tick then out.read_tick = out.read_tick + 1 end
		if st.lint == 0 then out.lint_zero = out.lint_zero + 1 end
		if type(st.lint) == "number" then out.lint_number = out.lint_number + 1 end
		if st.lint == lint.bits_of(st.id) then out.lint_matches = out.lint_matches + 1 end
		if st.unserved then
			out.unserved = out.unserved + 1
			out.unserved_count = out.unserved_count + st.unserved.count
		end
	end
	for _, tr in pairs(snap.trains) do
		out.trains = out.trains + 1
		if tr.state then out.state = out.state + 1 end
		if tr.state_since then out.state_since = out.state_since + 1 end
		if type(tr.in_interrupt) == "boolean" then out.in_interrupt_bool = out.in_interrupt_bool + 1 end
		if type(tr.has_path) == "boolean" then out.has_path_bool = out.has_path_bool + 1 end
		if tr.state == defines.train_state.wait_signal then out.waiting_at_signal = out.waiting_at_signal + 1 end
		if tr.signal_unit_number then out.signal_unit_number = out.signal_unit_number + 1 end
	end
	local fleet = snap.fleet
	out.min_available_by_network = fleet.min_available_by_network
	out.capability = fleet.capability
	out.mask_or = fleet.mask_or
	out.depots_by_name = snap.depots_by_name
	return out
end

-- ---- setup lint, fleet facts, cycle figures, the actions gate (PLAN3 §4.12, §4.2, §4.4, §4.14)

--- @param f LintFinding
local function finding_view(f)
	return {
		subject = LINT_SUBJECT_NAMES[f.subject],
		id = f.id,
		check = LINT_NAMES[f.check],
		predicts = LINT_PREDICTS[f.check] and REASON_NAMES[LINT_PREDICTS[f.check]] or nil,
		predicts_p = lint.predicts(f.check, "p") and REASON_NAMES[lint.predicts(f.check, "p")] or nil,
		a = f.a,
		b = f.b,
		network = f.network,
		item = f.item,
		message = f.message,
	}
end

--- Runs the station and train jobs of a fresh lint pass to completion (collecting a snapshot first when there is
--- none) and returns the pass summary.
function interface.lint_run()
	if not collector.get().tick then collector.run_to_completion() end
	local s = lint.run_to_completion()
	return { pass = s.pass, tick = s.tick, findings = #s.findings }
end

--- Findings of the last complete pass, optionally only those of one subject id or check name.
function interface.lint_findings(id, check_name)
	local out = {}
	local check = check_name and LINT_BY_NAME[check_name]
	for _, f in ipairs(lint.findings()) do
		if (not id or f.id == id) and (not check or f.check == check) then out[#out + 1] = finding_view(f) end
	end
	return out
end

--- Check names set in a station's, depot's or refueler's mask (or a train's, with is_train), and the snapshot record's
--- st.lint for a station.
function interface.lint_bits(id, is_train)
	local s = lint.state()
	local mask = (is_train and s.train_bits[id] or s.bits[id]) or 0
	local names = {}
	for check = 1, LINT_COUNT do
		if lint.has(mask, check) then names[#names + 1] = LINT_NAMES[check] end
	end
	local st = not is_train and collector.get().stations[id]
	return { mask = mask, checks = names, st_lint = st and st.lint or nil }
end

--- True exactly when the subject's last mask has the check (PLAN3 §6.2, phase 2b).
function interface.assert_lint(id, check_name, is_train)
	local check = LINT_BY_NAME[check_name]
	if not check then error("unknown lint check " .. tostring(check_name)) end
	local s = lint.state()
	local mask = (is_train and s.train_bits[id] or s.bits[id]) or 0
	return lint.has(mask, check)
end

--- The reason code name a check predicts on a station in `role` ("r" or "p"), nil when it predicts none.
function interface.lint_predicts(check_name, role)
	local check = LINT_BY_NAME[check_name]
	if not check then error("unknown lint check " .. tostring(check_name)) end
	local code = lint.predicts(check, role)
	return code and REASON_NAMES[code] or nil
end

function interface.lint_state()
	local s = lint.state()
	local job = s.job
	return { pass = s.pass, tick = s.tick, updates = s.updates, findings = #s.findings,
		running = job and { i = job.i, n = #job.sids + #(job.dids or {}) + #(job.fids or {}), ti = job.ti,
			nt = job.tids and #job.tids or 0, updates = job.updates } or nil,
		world_running = s.world_job ~= nil, world_tick = s.world and s.world.tick or nil,
		world_findings = s.world and #s.world.findings or nil }
end

--- One lint update as the manager tick runs it, timed (the gate's per-update figure); `records`/`trains` override the
--- batch sizes.
function interface.lint_step(n, records, trains)
	return profile(n or 1, function() lint.step(records, trains) end)
end

--- The world scan run to completion now; returns its findings (printed only when `print` is true).
function interface.lint_scan_world(player_index, print)
	local world = lint.scan_world_now(player_index, not print)
	local out = {}
	for i, f in ipairs(world.findings) do out[i] = finding_view(f) end
	return out
end

function interface.fleet_capability()
	local fleet = collector.get().fleet
	return { capability = fleet.capability, mask_or = fleet.mask_or, in_interrupt_count = fleet.in_interrupt_count,
		not_refuelled_count = fleet.not_refuelled_count, group_depots = fleet.group_depots }
end

--- "network:hash" -> the lowest provider item threshold the last snapshot holds.
function interface.provider_overrides()
	return collector.get().provider_overrides or {}
end

function interface.depots_by_name()
	return collector.get().depots_by_name
end

--- Train fields the fleet summary copies for the Trains tab (in_group, refuel_tick).
function interface.snapshot_train(id)
	local tr = collector.get().trains[id]
	return tr and { in_group = tr.in_group, refuel_tick = tr.refuel_tick, state = tr.state } or nil
end

--- storage.stats.cycle: the last planner cycle's ticks, dispatches and tick_dispatch calls.
function interface.cycle()
	return stats.get().cycle
end

--- The per-(item, network) no-train alerts of the planner (B6).
function interface.alert_dedupe()
	local ad = storage.alert_dedupe
	if not ad then return { cycle = 0, sent = 0, keys = {} } end
	local keys = {}
	for key, e in pairs(ad.keys) do
		keys[key] = { cycle = e.cycle, code = DIAG_ALERT_NAMES[e.code], r_id = e.r_id, p_id = e.p_id, wait = e.wait,
			shown = e.shown, sent = e.sent }
	end
	return { cycle = ad.cycle, sent = ad.sent, keys = keys }
end

--- Dispatches a console command's handler with a synthetic event, as the engine would for `player_index`
--- (nil = the server console). The gate test: the engine's own command path cannot be driven from RCON as a player.
function interface.run_command(name, player_index, parameter)
	local handler = cybersyn_command_handlers[name]
	if not handler then error("no such command " .. tostring(name)) end
	handler({ name = name, player_index = player_index, tick = game.tick, parameter = parameter })
	return true
end

--- Raises Cybersyn's on_train_schedule_changed handler for a train as a player's edit would (the engine raises it
--- with player_index only for GUI edits, which a headless lab cannot make).
function interface.train_schedule_changed(train_id, player_index)
	local train = storage.trains[train_id]
	if not (train and train.entity and train.entity.valid) then error("no Cybersyn train " .. tostring(train_id)) end
	on_train_schedule_changed({ train = train.entity, player_index = player_index, tick = game.tick,
		name = defines.events.on_train_schedule_changed })
	return true
end

--- PLAN3 §4.5 decision check: requests the planner polled as active whose (requester, item) has no unserved entry.
--- Reads the manager snapshot (collect first); `min_wait` in ticks filters on the tracked request start.
function interface.diag_coverage(min_wait, top)
	local d = storage.diag
	local snap = collector.get()
	local now = game.tick
	local out = { stations_active = 0, stations_uncovered = 0, keys_active = 0, keys_uncovered = 0,
		keys_uncovered_waiting = 0, failed_display_uncovered = 0, examples = {} }
	local examples = {}
	for id, st in pairs(snap.stations) do
		local station = storage.stations[id]
		local by_item = d and d.unserved[id]
		local active, uncovered = false, false
		for hash, req in pairs(st.requested) do
			if req.active then
				active = true
				out.keys_active = out.keys_active + 1
				local ix = d and d.item_ix[hash]
				if not (by_item and ix and by_item[ix]) then
					uncovered = true
					out.keys_uncovered = out.keys_uncovered + 1
					local start = station and station.request_start_ticks and station.request_start_ticks[hash]
					local wait = start and (now - start) or nil
					if wait and wait >= (min_wait or 0) then
						out.keys_uncovered_waiting = out.keys_uncovered_waiting + 1
						examples[#examples + 1] = { id = id, name = st.name, item = hash, wait = wait,
							priority = station and station.priority, deliveries = st.deliveries_total, limit = st.trains_limit,
							last_delivery_tick = st.last_delivery_tick, display_state = station and station.display_state }
					end
				end
			end
		end
		if active then out.stations_active = out.stations_active + 1 end
		if uncovered then
			out.stations_uncovered = out.stations_uncovered + 1
			if station and bit32.band(station.display_state or 0, 2) ~= 0 then
				out.failed_display_uncovered = out.failed_display_uncovered + 1
			end
		end
	end
	table.sort(examples, function(a, b) return a.wait > b.wait end)
	for i = 1, math.min(top or 10, #examples) do out.examples[i] = examples[i] end
	return out
end

--- Modules that dev.lua must not require (they require it) add their own functions to the interface at load time,
--- before dev.register publishes it.
--- @param fns {[string]: function}
function dev.extend(fns)
	for name, fn in pairs(fns) do interface[name] = fn end
end

--- Tab modules add their own functions to the interface while they load (before dev.register runs).
--- @param name string
--- @param fn function
function dev.register_function(name, fn)
	interface[name] = fn
end

--- Calls an interface function from Lua (a tab module's dev function reusing another).
--- @param name string
function dev.call(name, ...)
	return interface[name](...)
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
		for name, fn in pairs(dev_functions) do interface[name] = fn end
		remote.add_interface("cybersyn-manager-dev", interface)
	end
end

return dev
