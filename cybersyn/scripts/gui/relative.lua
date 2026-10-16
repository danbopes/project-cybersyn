-- Cybersyn panels beside the vanilla train-stop and train windows (PLAN3 §4.9). One builder, relative.build, makes
-- the panel anywhere (the in-window Trains detail pane of phase 9 mounts it too); relative.open mounts it beside the
-- vanilla window (see "mounting") once per player and kind, and only shows it for a Cybersyn stop or train. While a panel is open it is refreshed on the manager tick: each section is rebuilt only when
-- its signature changes, and ages are rounded to 10 s so an idle panel rebuilds nothing.
--
-- Data: the manager snapshot's station record while a manager window keeps one; otherwise one live read of this
-- stop's combinators per refresh (collector.read_station). The fleet counts of the Effective config section come from
-- a walk over storage.trains in chunks, only while that section is open.

local gui = require("__flib__.gui")
local format = require("__flib__.format")

local util = require("scripts.gui.util")
local collector = require("scripts.gui.collector")
local manager = require("scripts.gui.manager")
local dev = require("scripts.gui.dev")
local diag = require("scripts.diag")
local lint = require("scripts.lint")
local utext = require("scripts.gui.unserved-text")
local rtext = require("scripts.gui.relative-text")

local relative = {}

local WIDTH = 300
-- Inside the body's 8 px padding, leaving room for the scroll bar a tall panel gets (relative.fit).
local INNER = WIDTH - 28
local MOUNT = { stop = "cybersyn_relative_stop", train = "cybersyn_relative_train" }
local PANEL = "cybersyn_relative_panel"
local EVENTS = 10
-- Rows of the stop's event list while the Effective config is expanded, so the panel fits a 1080p screen at scale 1.
local EVENTS_COMPACT = 4
local SLOT_COLUMNS = 7
local SLOT_ROWS = 3
local UNSERVED_ROWS = 3
local EFFECTIVE_ITEMS = 6
-- Trains of storage.trains the Effective config walk counts per refresh, and how long a finished count is used.
local FLEET_CHUNK = 150
local FLEET_TTL = 1800
local WAIT_SIGNAL = defines.train_state.wait_signal

relative.WIDTH = WIDTH
relative.FLEET_CHUNK = FLEET_CHUNK

local STOP_SECTIONS = { "head", "slots", "unserved", "deliveries", "control", "setup", "effective", "events", "buttons" }
local TRAIN_SECTIONS = { "head", "manifest", "route", "schedule", "signal", "events", "buttons" }

local STATUS_COLOR = {
	no_power = "red",
	disabled = "purple",
	warming_up = "cyan",
	starved = "pink",
	saturated = "orange",
	idle = "white",
	ok = "green",
}

local ROLLING_STOCK = { locomotive = true, ["cargo-wagon"] = true, ["fluid-wagon"] = true, ["artillery-wagon"] = true }

local STATE_NAMES = {}
for name, v in pairs(defines.train_state) do STATE_NAMES[v] = name end

local STATE_CHIP = {
	[defines.train_state.no_path] = "cybersyn_chip_red",
	[defines.train_state.destination_full] = "cybersyn_chip_orange",
	[defines.train_state.wait_signal] = "cybersyn_chip_orange",
}

local TRAIN_STATUS_KEY = {
	[STATUS_D] = "cybersyn-gui.parked-at-depot",
	[STATUS_TO_P] = "cybersyn-gui.fetching-from",
	[STATUS_P] = "cybersyn-gui.loading-at",
	[STATUS_TO_R] = "cybersyn-gui.delivering-to",
	[STATUS_R] = "cybersyn-gui.unloading-at",
	[STATUS_TO_D] = "cybersyn-gui.returning-to-depot",
	[STATUS_TO_D_BYPASS] = "cybersyn-gui.returning-to-depot",
	[STATUS_TO_F] = "cybersyn-gui.trains-going-to-refuel",
	[STATUS_F] = "cybersyn-gui.trains-refuelling",
}

local S_COLOUR = { cyan = "0.4,0.9,1", green = "0.3,1,0.3", red = "1,0.35,0.35" }

relative.handle = {}

-- ---------------------------------------------------------------- small helpers

local function short_age(ticks)
	return util.short_duration(rtext.age_step(ticks))
end

local function label(caption, extra)
	local def = { type = "label", caption = caption }
	if extra then
		for k, v in pairs(extra) do def[k] = v end
	end
	return def
end

--- A label that wraps inside the panel.
local function line(caption, tooltip, color)
	return {
		type = "label",
		caption = caption,
		tooltip = tooltip,
		style_mods = { single_line = false, maximal_width = INNER, font_color = color },
	}
end

local function note(caption, tooltip)
	return line(caption, tooltip, { 0.65, 0.65, 0.65 })
end

local function heading(caption)
	return { type = "label", style = "caption_label", caption = caption }
end

local function network_rich(name)
	if not name then return { "cybersyn-gui.station-no-network" } end
	if name == NETWORK_EACH then return { "cybersyn-gui.network-each" } end
	if prototypes.virtual_signal[name] then return "[virtual-signal=" .. name .. "] " .. name end
	if prototypes.item[name] then return "[item=" .. name .. "] " .. name end
	if prototypes.fluid[name] then return "[fluid=" .. name .. "] " .. name end
	return name
end

--- Networks of a station or refueler as {name, mask} pairs, in a stable order.
local function networks_of(network_name, network_mask)
	local out = {}
	if network_name == NETWORK_EACH then
		if type(network_mask) == "table" then
			for name, mask in pairs(network_mask) do out[#out + 1] = { name = name, mask = mask } end
			table.sort(out, function(a, b) return a.name < b.name end)
		end
	elseif network_name then
		out[1] = { name = network_name, mask = type(network_mask) == "number" and network_mask or 0 }
	end
	return out
end

local function stop_name(kind, id)
	local record
	if kind == "station" then
		record = storage.stations[id]
	elseif kind == "depot" then
		record = storage.depots[id]
	elseif kind == "refueler" then
		record = storage.refuelers[id]
	end
	local stop = record and record.entity_stop
	return stop and stop.valid and stop.backer_name or nil
end

--- A link cell to a station, depot or refueler (util.handle_link_click semantics).
local function stop_link(kind, id, max_width)
	local name = id and stop_name(kind, id)
	return {
		type = "button",
		style = "cybersyn_link_button",
		style_mods = { maximal_width = max_width or INNER, height = 24 },
		caption = name or utext.NO_VALUE,
		enabled = name ~= nil,
		tooltip = name and { "", "[font=default-semibold]", name, "[/font]\n", util.LINK_FOOTER } or nil,
		tags = name and { kind = kind, id = id } or {},
		mouse_button_filter = { "left" },
		handler = { [defines.events.on_gui_click] = util.handle.link_click },
	}
end

local function slot(hash, count, color, tooltip)
	local sprite, quality, name_tooltip = util.item_sprite_and_tooltip(hash)
	if not sprite then return nil end
	return {
		type = "sprite-button",
		sprite = sprite,
		quality = quality,
		style = "ltnm_small_slot_button_" .. color,
		tooltip = { "", name_tooltip, tooltip },
		elem_tooltip = util.elem_tooltip(hash),
		tags = { kind = "item", id = hash },
		mouse_button_filter = { "left", "right" },
		handler = { [defines.events.on_gui_click] = util.handle.link_click },
		{
			type = "label",
			style = "ltnm_label_signal_count",
			ignored_by_interaction = true,
			caption = format_signal_count(count),
		},
	}
end

--- A slot table of at most SLOT_ROWS rows, with "+n more" below when it overflows.
local function slot_table(slots, total)
	local tbl = {
		type = "frame",
		style = "ltnm_small_slot_table_frame_light",
		{ type = "table", style = "slot_table", column_count = SLOT_COLUMNS },
	}
	local cap = SLOT_COLUMNS * SLOT_ROWS
	for i = 1, math.min(#slots, cap) do tbl[1][#tbl[1] + 1] = slots[i] end
	local out = { tbl }
	if total > cap then out[2] = note({ "cybersyn-gui.relative-more", tostring(total - cap) }) end
	return out
end

local function sev_color(sev)
	if sev == DIAG_SEV_ERROR then return { 1, 0.45, 0.4 } end
	if sev == DIAG_SEV_WARNING then return { 1, 0.78, 0.45 } end
	return nil
end

-- ---------------------------------------------------------------- builder

--- The panel: a 300 px inside_shallow_frame with the dispatcher-paused banner, a subheader captioned "Cybersyn" and
--- one empty flow per section, which relative.refresh fills. Mountable anywhere.
--- @param parent LuaGuiElement
--- @param kind "stop"|"train"
--- @param id uint?
--- @return LuaGuiElement panel
function relative.build(parent, kind, id)
	local sections = kind == "train" and TRAIN_SECTIONS or STOP_SECTIONS
	local body = {
		type = "flow",
		name = "body",
		direction = "vertical",
		style_mods = { padding = 8, vertical_spacing = 8 },
	}
	for _, name in ipairs(sections) do
		body[#body + 1] = {
			type = "flow",
			name = name,
			direction = "vertical",
			visible = false,
			style_mods = { vertical_spacing = 4, maximal_width = INNER },
		}
	end
	local _, panel = gui.add(parent, {
		type = "frame",
		name = PANEL,
		style = "inside_shallow_frame",
		direction = "vertical",
		style_mods = { width = WIDTH },
		tags = { kind = kind, id = id },
		{
			type = "frame",
			name = "banner",
			style = "cybersyn_banner_frame",
			visible = false,
			{ type = "label", name = "banner_label", style = "cybersyn_banner_label" },
		},
		{
			type = "frame",
			name = "subheader",
			style = "subheader_frame",
			style_mods = { horizontally_stretchable = true },
			{ type = "label", name = "caption_label", style = "subheader_caption_label", caption = { "cybersyn-gui.relative-caption" } },
			{ type = "empty-widget", style = "flib_horizontal_pusher" },
			{
				type = "sprite-button",
				name = "effective_button",
				style = "tool_button",
				sprite = "utility/expand",
				visible = kind == "stop",
				tooltip = { "cybersyn-gui.relative-effective-tooltip" },
				handler = { [defines.events.on_gui_click] = relative.handle.relative_toggle_effective },
			},
		},
		{
			type = "scroll-pane",
			name = "scroll",
			style = "flib_naked_scroll_pane_no_padding",
			horizontal_scroll_policy = "never",
			vertical_scroll_policy = "auto",
			body,
		},
	})
	return panel
end

-- ---------------------------------------------------------------- state

--- @class RelativeState per player, for the open panel; plain data
--- @field kind "stop"|"train"
--- @field id uint
--- @field sigs {[string]: string}
--- @field rebuilds int sections rebuilt since the panel opened
--- @field rebuilt {[string]: int}? the same per section
--- @field refreshes int
--- @field st SnapshotStation? the live record while no snapshot holds this station (never a snapshot record)
--- @field starved {[string]: true} this station's request keys nobody provides, from the planner's economy
--- @field cursor DiagScanCursor?
--- @field fleet {key: string, ids: uint[], i: int, counts: {[string]: RelativeFleetCount}, done_tick: uint?}?
--- @field schedule {records: table[], tick: uint}?

local function new_state(kind, id)
	return { kind = kind, id = id, sigs = {}, rebuilds = 0, refreshes = 0, starved = {} }
end

local function hidden() return nil end

--- Rebuilds one section when its signature changed; `build` returns its children (nil or empty = hidden). Callers
--- compare the signature first, so a section that did not change allocates no builder closure.
local function section(state, body, name, sig, build)
	if state.sigs[name] == sig then return end
	local flow = body[name]
	if not (flow and flow.valid) then return end
	state.sigs[name] = sig
	flow.clear()
	local defs = build()
	local shown = defs ~= nil and #defs > 0
	if shown then
		for _, def in ipairs(defs) do
			if def then gui.add(flow, def) end
		end
	end
	if flow.visible ~= shown then flow.visible = shown end
	state.rebuilds = state.rebuilds + 1
	local by = state.rebuilt
	if not by then
		by = {}
		state.rebuilt = by
	end
	by[name] = (by[name] or 0) + 1
end

-- ---------------------------------------------------------------- stop model

--- This station's active request keys nobody on its networks provides, from the planner's economy, which is complete
--- only while it dispatches; between those ticks the last answer stands.
local function update_starved(state, st)
	if storage.tick_state ~= STATE_DISPATCH or not st then return end
	local economy = storage.economy
	if not economy then return end
	local r_stops, p_stops = economy.all_r_stops, economy.all_p_stops
	local starved = {}
	for _, net in ipairs(networks_of(st.network_name, st.network_mask)) do
		for hash, req in pairs(st.requested) do
			if req.active then
				local key = net.name .. ":" .. hash
				if r_stops[key] and not p_stops[key] then starved[key] = true end
			end
		end
	end
	state.starved = starved
end

--- The station record the panel shows: the manager snapshot's while one is live, else a live read of the stop.
--- @return SnapshotStation?
--- @return "snapshot"|"live"
local function station_record(state, id)
	local snap = collector.get()
	local st = snap.tick and snap.stations[id]
	if st then
		state.st = nil
		return st, "snapshot"
	end
	update_starved(state, state.st)
	state.st = collector.read_station(id, state.st, state.starved)
	return state.st, "live"
end

--- The stop's findings of the last lint pass, looked up again only when a pass completed.
local function lint_findings_of(state, id, pass)
	local cached = state.findings
	if cached and cached.pass == pass and cached.id == id then return cached.list end
	local out = {}
	for _, f in ipairs(lint.findings()) do
		if f.id == id and f.subject ~= LINT_SUBJECT_TRAIN then out[#out + 1] = f end
	end
	state.findings = { pass = pass, id = id, list = out }
	return out
end

--- Unserved entries of a requester, oldest first.
local function unserved_rows(id)
	local by_item = diag.unserved_for(id)
	local rows = {}
	if not by_item then return rows end
	for ix, e in pairs(by_item) do
		local hash = diag.item_hash(ix)
		if hash then rows[#rows + 1] = { ix = ix, hash = hash, e = e } end
	end
	table.sort(rows, function(a, b)
		if a.e.first_tick ~= b.e.first_tick then return a.e.first_tick < b.e.first_tick end
		return a.ix < b.ix
	end)
	return rows
end

--- Item maps fold into weighted sums for their signatures: each item weighs its crafting-order rank (distinct per
--- item and quality), so a change of any count or of the item set changes the sums; building a string per item cost
--- a live read's refresh 20-40 µs on a 10-item requester.
--- @return string
local function content_sig(n, a, b, c)
	return string.format("%d:%.17g:%.17g:%.17g", n, a, b, c)
end

--- A signature over a station record's contents, computed again only when the record was refilled (a snapshot
--- record changes once per collector pass; walking a big requester's items every refresh cost more than the rest).
--- @param fn fun(st: SnapshotStation, arg: any): string
--- @return string
local function record_sig(state, name, st, fn, arg)
	local cache = state.rsig
	if not cache then
		cache = {}
		state.rsig = cache
	end
	local e = cache[name]
	if e and e.tick == st.read_tick and e.id == st.id then return e.sig end
	local sig = fn(st, arg)
	cache[name] = { tick = st.read_tick, id = st.id, sig = sig }
	return sig
end

local function slots_content(st)
	local n, a, b, c = 0, 0, 0, 0
	for hash, count in pairs(st.provided) do
		local r = util.item_rank(hash)
		n, a, b = n + 1, a + r, b + count * r
	end
	for hash, req in pairs(st.requested) do
		local r = util.item_rank(hash)
		n, a, b, c = n + 1, a - r, b + req.count * r, c + req.threshold * r + (req.active and r or 0)
	end
	return content_sig(n, a, b, c)
end

local function deliveries_content(st, total)
	local n, a, b = 0, 0, 0
	for hash, count in pairs(st.deliveries) do
		local r = util.item_rank(hash)
		n, a, b = n + 1, a + r, b + count * r
	end
	return content_sig(n, a, b, total)
end

local function control_content(st)
	local parts = {}
	for name, count in pairs(st.control) do parts[#parts + 1] = name .. "=" .. count end
	parts[#parts + 1] = "|"
	for hash, v in pairs(st.thresholds) do parts[#parts + 1] = hash .. "=" .. v end
	return table.concat(parts, ",")
end

local function eff_inputs_content(st)
	local parts = { st.trains_limit, st.control[REQUEST_THRESHOLD] or "", st.control[REQUEST_FLUID_THRESHOLD] or "",
		st.control[SIGNAL_PRIORITY] or "" }
	for hash, req in pairs(st.requested) do parts[#parts + 1] = hash .. "=" .. req.threshold end
	return table.concat(parts, ",")
end

--- The fleet counts for this stop's networks: a walk over storage.trains, FLEET_CHUNK trains per refresh, restarted
--- once a finished count is FLEET_TTL old or the stop's networks changed.
--- @return {[string]: RelativeFleetCount}? counts nil while the first walk runs
--- @return number progress 0..1
local function fleet_counts(state, nets, key)
	local now = game.tick
	local f = state.fleet
	if not f or f.key ~= key or (f.done_tick and now - f.done_tick >= FLEET_TTL) then
		local ids = {}
		for tid in pairs(storage.trains) do ids[#ids + 1] = tid end
		table.sort(ids)
		local counts = {}
		for _, n in ipairs(nets) do counts[n.name] = rtext.new_fleet_count(n.mask) end
		local result = f and f.key == key and f.result or nil
		f = { key = key, ids = ids, i = 0, counts = counts, result = result }
		state.fleet = f
	end
	if not f.done_tick then
		local ids, trains = f.ids, storage.trains
		local stop = math.min(#ids, f.i + FLEET_CHUNK)
		for i = f.i + 1, stop do
			local train = trains[ids[i]]
			if train and train.entity and train.entity.valid then rtext.count_train(f.counts, train) end
		end
		f.i = stop
		if stop >= #ids then
			f.done_tick = now
			f.result = f.counts
			f.ids = nil
		end
	end
	return f.result, #(f.ids or {}) > 0 and f.i / #f.ids or 1
end

--- The Effective config numbers (PLAN3 §4.9, A8 + B15).
local function build_effective(state, st, station, nets, counts, progress)
	local snap = collector.get()
	local live = snap.tick ~= nil
	local control = st.control
	local m = {
		base_item = control[REQUEST_THRESHOLD] and math.abs(control[REQUEST_THRESHOLD]) or (mod_settings.r_threshold or 1),
		base_item_signal = control[REQUEST_THRESHOLD] ~= nil,
		limit = st.trains_limit,
		priority = control[SIGNAL_PRIORITY] or mod_settings.priority or 0,
		s_colour = rtext.s_colour(station.display_state),
		counting = counts == nil and progress or nil,
		nets = {},
		items = {},
		capability_source = live and "snapshot" or "walk",
	}
	if control[REQUEST_FLUID_THRESHOLD] then
		m.base_fluid, m.base_fluid_signal = math.abs(control[REQUEST_FLUID_THRESHOLD]), true
	elseif (mod_settings.r_fluid_threshold or 0) > 0 then
		m.base_fluid = mod_settings.r_fluid_threshold
	else
		m.base_fluid = m.base_item
	end
	local allows_all = station.allows_all_trains == true
	local accepted = station.accepted_layouts or {}
	local best_items, best_fluid = 0, 0
	for _, net in ipairs(nets) do
		local capability = live and snap.fleet.capability[net.name] or (counts and counts[net.name] and counts[net.name].capability)
		local c = counts and counts[net.name]
		local trains, ok, items, fluid = lint.eligible(capability, net.mask, allows_all, accepted)
		local n_accepted, allow_trains, missing = rtext.allow_list(accepted, allows_all, capability, net.mask)
		m.nets[#m.nets + 1] = {
			name = net.name,
			mask = net.mask,
			trains = c and c.trains or nil,
			depots = c and c.depots or nil,
			eligible = trains,
			item_capacity = items,
			fluid_capacity = fluid,
			accepted = n_accepted,
			allow_trains = allow_trains,
			missing = missing,
			known = capability ~= nil,
		}
		if items > best_items then best_items = items end
		if fluid > best_fluid then best_fluid = fluid end
	end
	m.item_capacity, m.fluid_capacity = best_items, best_fluid
	local entries = diag.unserved_for(st.id)
	local list = util.hashes_in_item_order(st.requested)
	for i = 1, math.min(#list, EFFECTIVE_ITEMS) do
		local hash = list[i]
		local req = st.requested[hash]
		local name = unhash_signal(hash)
		local is_fluid = prototypes.fluid[name] ~= nil
		local override
		for _, net in ipairs(nets) do
			local o = snap.provider_overrides and snap.provider_overrides[net.name .. ":" .. hash]
			if o and (not override or o < override) then override = o end
		end
		local effective, overridden = rtext.effective_threshold(req.threshold, override)
		local stack = not is_fluid and (get_stack_size(nil, name) or 1) or nil
		local need = is_fluid and effective or rtext.stacks(effective, stack)
		local capacity = is_fluid and best_fluid or best_items
		local e
		local ix = entries and storage.diag and storage.diag.item_ix[hash]
		if ix then e = entries[ix] end
		m.items[#m.items + 1] = {
			hash = hash,
			threshold = req.threshold,
			override = overridden and override or nil,
			effective = effective,
			is_fluid = is_fluid,
			stack = stack,
			need = need,
			capacity = capacity,
			gap = capacity - need,
			warn = capacity > 0 and need >= capacity,
			p_count = e and e.p_count or nil,
			p_threshold = e and e.p_threshold or nil,
		}
	end
	m.more_items = math.max(0, #list - EFFECTIVE_ITEMS)
	return m
end

--- build_effective, rebuilt only when its inputs moved: the record was refilled, a new snapshot or fleet count, the
--- combinator display; the unserved entries' p_count / p_threshold are read again on every refresh.
local function effective_model(state, st, station, nets, nets_key)
	local counts, progress = fleet_counts(state, nets, nets_key)
	local c = state.eff
	local snap_tick = collector.get().tick
	local done = state.fleet and state.fleet.done_tick
	-- What the section reads from the record: a live record is refilled every refresh, mostly with the same values.
	local inputs = record_sig(state, "eff_inputs", st, eff_inputs_content)
	local m
	if c and c.id == st.id and c.inputs == inputs and c.snap == snap_tick and c.done == done and
		c.display == station.display_state and c.all == station.allows_all_trains then
		m = c.model
	else
		m = build_effective(state, st, station, nets, counts, progress)
		state.eff = { id = st.id, inputs = inputs, snap = snap_tick, done = done, display = station.display_state,
			all = station.allows_all_trains, model = m }
	end
	m.counting = counts == nil and progress or nil
	local entries = diag.unserved_for(st.id)
	local d = storage.diag
	for _, it in ipairs(m.items) do
		local ix = entries and d and d.item_ix[it.hash]
		local e = ix and entries[ix]
		it.p_count = e and e.p_count or nil
		it.p_threshold = e and e.p_threshold or nil
	end
	return m
end

--- Everything the stop panel shows, as plain values.
--- @return table?
local function stop_model(pd, state)
	local id = state.id
	local station = storage.stations[id]
	local depot = not station and storage.depots[id] or nil
	local refueler = not (station or depot) and storage.refuelers[id] or nil
	local record = station or depot or refueler
	local stop = record and record.entity_stop
	if not (stop and stop.valid) then return nil end
	local now = game.tick
	local m = {
		kind = "stop",
		id = id,
		sub = station and "station" or depot and "depot" or "refueler",
		name = stop.backer_name,
		trains_count = stop.trains_count,
		lint_bits = lint.bits_of(id),
		lint_pass = storage.manager.lint and storage.manager.lint.pass or 0,
		read_tick = now,
		source = "live",
	}
	if station then
		local st, source = station_record(state, id)
		if not st then return nil end
		m.source = source
		m.read_tick = st.read_tick or now
		m.is_p, m.is_r, m.is_stack = st.is_p, st.is_r, st.is_stack
		m.network_name = st.network_name
		local nc = state.nets
		local mask = st.network_mask
		if not (nc and nc.id == st.id and nc.name == st.network_name and type(mask) == "number" and nc.mask == mask) then
			local nets = networks_of(st.network_name, st.network_mask)
			local parts = {}
			for i, n in ipairs(nets) do parts[i] = n.name .. "=" .. n.mask end
			nc = { id = st.id, name = st.network_name, mask = type(mask) == "number" and mask or nil, nets = nets,
				key = table.concat(parts, ",") }
			state.nets = nc
		end
		m.nets = nc.nets
		m.nets_key = nc.key
		m.status = st.status
		m.deliveries = st.deliveries_total
		m.limit = st.trains_limit
		m.unserved = unserved_rows(id)
		m.st = st
		m.display_state = station.display_state
		if pd.relative_effective_open then m.effective = effective_model(state, st, station, m.nets, m.nets_key) end
	elseif depot then
		m.limit = stop.trains_limit
		m.parked = depot.available_train_id
		m.deliveries = depot.available_train_id and 1 or 0
	else
		m.network_name = refueler.network_name
		m.nets = networks_of(refueler.network_name, refueler.network_mask)
		m.limit = stop.trains_limit
		m.deliveries = refueler.trains_total or 0
	end
	m.occupancy_lint = lint.has(m.lint_bits, LINT_OCCUPANCY) or lint.has(m.lint_bits, LINT_PHANTOM)
	m.findings = lint_findings_of(state, id, m.lint_pass)
	return m
end

-- ---------------------------------------------------------------- stop sections

local function status_caption(status)
	return { "", "[img=flib_indicator_" .. (STATUS_COLOR[status] or "white") .. "] ",
		{ "cybersyn-gui.station-status-" .. string.gsub(status, "_", "-") } }
end

local function lint_chip(check, tooltip)
	return {
		type = "button",
		style = LINT_SEVERITY[check] == DIAG_SEV_ERROR and "cybersyn_chip_red" or "cybersyn_chip_orange",
		caption = { "cybersyn-diag.lint-" .. LINT_KEYS[check] },
		tooltip = tooltip,
	}
end

local function finding_fix(f)
	return { "cybersyn-diag.lint-fix-" .. LINT_KEYS[f.check], tostring(f.a or 0), tostring(f.b or 0),
		f.network and network_rich(f.network) or "?" }
end

local function render_stop_head(state, body, m)
	local nets_sig = {}
	for i, n in ipairs(m.nets or {}) do nets_sig[i] = n.name .. "=" .. n.mask end
	local sig = table.concat({ m.sub, tostring(m.is_p), tostring(m.is_r), tostring(m.is_stack), tostring(m.status),
		table.concat(nets_sig, ","), m.deliveries or 0, m.limit or 0, m.trains_count or 0, tostring(m.occupancy_lint),
		tostring(m.parked) }, "|")
	if state.sigs["head"] ~= sig then
		section(state, body, "head", sig, function()
			local out = {}
			if m.sub == "station" then
				out[#out + 1] = line({ "cybersyn-gui.relative-role", rtext.role(m.is_p, m.is_r, m.is_stack) })
			else
				out[#out + 1] = line({ "cybersyn-gui.relative-role", { "cybersyn-gui.relative-role-" .. m.sub } })
			end
			if m.nets then
				if #m.nets == 0 then
					out[#out + 1] = line({ "cybersyn-gui.relative-network", { "cybersyn-gui.station-no-network" } })
				end
				for _, n in ipairs(m.nets) do
					out[#out + 1] = line({ "cybersyn-gui.relative-network-mask", network_rich(n.name), rtext.mask_text(n.mask) })
				end
			end
			if m.status then
				out[#out + 1] = line({ "cybersyn-gui.relative-status", status_caption(m.status) },
					{ "cybersyn-gui.station-status-" .. string.gsub(m.status, "_", "-") .. "-tooltip" })
			end
			local pair = {
				type = "flow",
				direction = "horizontal",
				style_mods = { vertical_align = "center", horizontal_spacing = 8 },
				label({ "cybersyn-gui.relative-trains", rtext.trains_pair(m.deliveries, m.limit), tostring(m.trains_count) },
					{ tooltip = { "cybersyn-gui.relative-trains-tooltip" } }),
			}
			if m.occupancy_lint then
				local check = lint.has(m.lint_bits, LINT_PHANTOM) and LINT_PHANTOM or LINT_OCCUPANCY
				local f
				for _, x in ipairs(m.findings) do
					if x.check == check then f = x end
				end
				pair[#pair + 1] = lint_chip(check, f and finding_fix(f) or nil)
			end
			out[#out + 1] = pair
			return out
		end)
	end
end

local function render_slots(state, body, m)
	local st = m.st
	-- The expanded Effective config replaces the slot rows (it lists the requests with their thresholds), so the panel
	-- still fits a 1080p screen at scale 1.
	if not st or m.effective then
		if state.sigs["slots"] ~= "" then section(state, body, "slots", "", hidden) end
		return
	end
	local sig = record_sig(state, "slots", st, slots_content)
	if state.sigs["slots"] ~= sig then
		section(state, body, "slots", sig, function()
			local slots = {}
			local total = 0
			for _, hash in ipairs(util.hashes_in_item_order(st.provided)) do
				total = total + 1
				slots[#slots + 1] = slot(hash, st.provided[hash], "green",
					{ "", " ", { "cybersyn-gui.provided" }, "\n", { "cybersyn-gui.amount", format.number(st.provided[hash]) } })
			end
			for _, hash in ipairs(util.hashes_in_item_order(st.requested)) do
				local req = st.requested[hash]
				total = total + 1
				slots[#slots + 1] = slot(hash, req.count, req.active and "red" or "orange", {
					"", " ", req.active and { "cybersyn-gui.requested" } or { "cybersyn-gui.requested-below-threshold" },
					"\n", { "cybersyn-gui.amount", format.number(req.count) },
					"\n", { "cybersyn-gui.request-threshold", format.number(req.threshold) },
				})
			end
			if total == 0 then return { note({ "cybersyn-gui.relative-no-items" }) } end
			local out = { heading({ "cybersyn-gui.provided-requested" }) }
			for _, def in ipairs(slot_table(slots, total)) do out[#out + 1] = def end
			return out
		end)
	end
end

local function surface_name(index)
	local s = game.get_surface(index)
	return s and s.name or tostring(index)
end

local function render_unserved(state, body, m, compact)
	local rows = m.unserved
	if not rows or #rows == 0 or not storage.diag then
		if state.sigs["unserved"] ~= "" then section(state, body, "unserved", "", hidden) end
		return
	end
	local now = game.tick
	local d = storage.diag
	local inherit_before = diag.inherit_threshold(d)
	-- The payload, the evaluation count and the losses move with every planner cycle on a busy base; they are refreshed
	-- with the 10 s age step, the reason and the provider at once.
	local a, b, c = 0, 0, 0
	for i = 1, math.min(#rows, UNSERVED_ROWS) do
		local r, e = rows[i], rows[i].e
		local w = util.item_rank(r.hash) * i
		a = a + w * e.reason + (diag.is_acked("request", state.id, r.hash) and w or 0)
		b = b + w * e.first_tick
		c = c + w * (e.p_station_id or 0)
	end
	local unserved_sig = content_sig(#rows, a, b, c) .. ":" .. math.floor(now / rtext.AGE_STEP) .. (compact and "c" or "")
	if state.sigs["unserved"] ~= unserved_sig then
		section(state, body, "unserved", unserved_sig, function()
			local st = m.st
			local out = { heading({ "cybersyn-gui.relative-unserved", tostring(#rows) }) }
			for i = 1, math.min(#rows, UNSERVED_ROWS) do
				local r, e = rows[i], rows[i].e
				local sprite, quality, item_tooltip = util.item_sprite_and_tooltip(r.hash)
				local req = st and st.requested[r.hash]
				local wait = now - e.first_tick
				local inherited = e.first_tick < inherit_before
				local tip = utext.chip_tooltip({
					item = item_tooltip or r.hash,
					requested = req and -req.count or nil,
					requester = m.name,
					reason = e.reason,
					a = e.a,
					b = e.b,
					network = m.network_name and network_rich(m.network_name) or nil,
					rej = e.rej,
					wait = wait,
					inherited = inherited,
					n = e.n,
					surface_name = surface_name,
				}, util.format_duration)
				local acked = diag.is_acked("request", state.id, r.hash) ~= nil
				local stock = utext.stock_caption(e.reason, e.a, e.b)
				local row = {
					type = "flow",
					direction = "horizontal",
					style_mods = { vertical_align = "center", horizontal_spacing = 6 },
					sprite and {
						type = "sprite-button",
						style = "cybersyn_unserved_item",
						sprite = sprite,
						quality = quality,
						elem_tooltip = util.elem_tooltip(r.hash),
						tags = { kind = "item", id = r.hash },
						mouse_button_filter = { "left", "right" },
						handler = { [defines.events.on_gui_click] = util.handle.link_click },
					} or label(r.hash),
					{
						type = "button",
						style = acked and "cybersyn_chip_grey" or utext.chip_style(e.reason),
						caption = utext.chip_caption(e.reason),
						tooltip = tip,
					},
					label(stock ~= utext.NO_VALUE and stock or ""),
					label(utext.wait_caption(rtext.age_step(wait), inherited, util.short_duration),
						{ style_mods = { font_color = { 0.7, 0.7, 0.7 } } }),
				}
				out[#out + 1] = row
				-- The expanded Effective config needs the room; the four lines stay in the chip's tooltip.
				if i == 1 and not compact then out[#out + 1] = line(tip) end
			end
			if #rows > UNSERVED_ROWS then
				out[#out + 1] = note({ "cybersyn-gui.relative-more", tostring(#rows - UNSERVED_ROWS) })
			end
			return out
		end)
	end
end

local function render_deliveries(state, body, m)
	local st = m.st
	-- The expanded Effective config replaces the slot rows (it lists the requests with their thresholds), so the panel
	-- still fits a 1080p screen at scale 1.
	if not st or m.effective then
		if state.sigs["deliveries"] ~= "" then section(state, body, "deliveries", "", hidden) end
		return
	end
	local sig = record_sig(state, "deliveries", st, deliveries_content, m.deliveries or 0)
	if state.sigs["deliveries"] ~= sig then
		section(state, body, "deliveries", sig, function()
			local out = { heading({ "cybersyn-gui.relative-in-flight", tostring(m.deliveries or 0) }) }
			local slots, total = {}, 0
			for _, hash in ipairs(util.hashes_in_item_order(st.deliveries)) do
				local count = st.deliveries[hash]
				total = total + 1
				slots[#slots + 1] = slot(hash, count, count > 0 and "green" or "blue", {
					"", " ", count > 0 and { "cybersyn-gui.incoming" } or { "cybersyn-gui.outgoing" },
					"\n", { "cybersyn-gui.amount", format.number(count) },
				})
			end
			if total == 0 then return nil end
			for _, def in ipairs(slot_table(slots, total)) do out[#out + 1] = def end
			return out
		end)
	end
end

local function render_control(state, body, m)
	local st = m.st
	-- The expanded Effective config replaces the slot rows (it lists the requests with their thresholds), so the panel
	-- still fits a 1080p screen at scale 1.
	if not st or m.effective then
		if state.sigs["control"] ~= "" then section(state, body, "control", "", hidden) end
		return
	end
	local sig = record_sig(state, "control", st, control_content)
	if state.sigs["control"] ~= sig then
		section(state, body, "control", sig, function()
			local slots = util.slot_table_build_from_control_signals(st)
			if #slots == 0 then return nil end
			local out = { heading({ "cybersyn-gui.control-signals" }) }
			for _, def in ipairs(slot_table(slots, #slots)) do out[#out + 1] = def end
			return out
		end)
	end
end

local function render_setup(state, body, m)
	local sig = m.lint_bits .. ":" .. m.lint_pass
	if state.sigs["setup"] ~= sig then
		section(state, body, "setup", sig, function()
			local out = { heading({ "cybersyn-gui.relative-setup" }) }
			if #m.findings == 0 then
				if m.lint_pass == 0 then
					out[#out + 1] = note({ "cybersyn-gui.relative-setup-not-run" })
				else
					out[#out + 1] = note({ "cybersyn-gui.relative-setup-none" })
				end
				return out
			end
			for _, f in ipairs(m.findings) do
				out[#out + 1] = line({ "", "• ", { "cybersyn-diag.lint-" .. LINT_KEYS[f.check] } }, nil, sev_color(LINT_SEVERITY[f.check]))
				out[#out + 1] = note(finding_fix(f))
			end
			return out
		end)
	end
end

local function render_effective(state, body, m)
	local e = m.effective
	if not e then
		if state.sigs["effective"] ~= "" then section(state, body, "effective", "", hidden) end
		return
	end
	if not e.sig then
		local parts = { e.base_item, tostring(e.base_item_signal), e.base_fluid, e.limit, e.priority, e.s_colour,
			e.item_capacity, e.fluid_capacity, e.more_items }
		for _, n in ipairs(e.nets) do
			parts[#parts + 1] = table.concat({ n.name, n.mask, tostring(n.trains), tostring(n.depots), n.item_capacity,
				n.fluid_capacity, tostring(n.accepted), n.allow_trains, table.concat(n.missing, "/"), tostring(n.known) }, ":")
		end
		for _, it in ipairs(e.items) do
			parts[#parts + 1] = table.concat({ it.hash, it.threshold, tostring(it.override), it.need, it.capacity }, ":")
		end
		e.sig = table.concat(parts, "|")
	end
	local sig = e.sig
	if e.counting then sig = sig .. "|c" .. math.floor(e.counting * 10) end
	for i, it in ipairs(e.items) do
		if it.p_count then sig = sig .. "|" .. i .. "=" .. it.p_count .. "/" .. tostring(it.p_threshold) end
	end
	if state.sigs["effective"] ~= sig then
		section(state, body, "effective", sig, function()
			local out = { heading({ "cybersyn-gui.relative-effective" }) }
			out[#out + 1] = line({ "cybersyn-gui.relative-eff-threshold", format.number(e.base_item),
				e.base_item_signal and { "cybersyn-gui.relative-from-signal" } or { "cybersyn-gui.relative-from-default" },
				m.is_stack and { "cybersyn-gui.relative-unit-stacks" } or { "cybersyn-gui.relative-unit-items" } })
			out[#out + 1] = line({ "cybersyn-gui.relative-eff-fluid", format.number(e.base_fluid) })
			if #e.items > 0 then
				local RED = { 1, 0.45, 0.4 }
				local function cell(caption, tooltip, color)
					return { type = "label", caption = caption, tooltip = tooltip,
						style_mods = { horizontal_align = "right", minimal_width = 56, font_color = color } }
				end
				local tbl = {
					type = "table",
					column_count = 4,
					style_mods = { horizontal_spacing = 12, vertical_spacing = 2 },
					label({ "cybersyn-gui.relative-eff-col-item" }, { style = "bold_label" }),
					cell({ "cybersyn-gui.relative-eff-col-threshold" }, { "cybersyn-gui.relative-eff-col-threshold-tooltip" }),
					cell({ "cybersyn-gui.relative-eff-col-need" }, { "cybersyn-gui.relative-eff-col-need-tooltip" }),
					cell({ "cybersyn-gui.relative-eff-col-gap" }, { "cybersyn-gui.relative-eff-col-gap-tooltip" }),
				}
				for i = 2, 4 do tbl[i].style_mods.font = "default-semibold" end
				local warned = 0
				for _, it in ipairs(e.items) do
					local sprite, quality = util.item_sprite_and_tooltip(it.hash)
					local tip = { "", { "cybersyn-gui.relative-eff-item-tooltip", format.number(it.threshold),
						it.stack and tostring(it.stack) or utext.NO_VALUE } }
					if it.override then
						tip[#tip + 1] = "\n"
						tip[#tip + 1] = { "cybersyn-gui.relative-eff-override", format.number(it.override) }
					end
					if it.p_count then
						tip[#tip + 1] = "\n"
						tip[#tip + 1] = { "cybersyn-gui.relative-eff-provider", format.number(it.p_count),
							format.number(it.p_threshold or 0) }
					end
					if it.warn then warned = warned + 1 end
					local color = it.warn and RED or nil
					tbl[#tbl + 1] = sprite and {
						type = "sprite-button",
						style = "cybersyn_name_icon",
						sprite = sprite,
						quality = quality,
						elem_tooltip = util.elem_tooltip(it.hash),
						tooltip = tip,
					} or label(it.hash)
					tbl[#tbl + 1] = cell(format.number(it.effective) .. (it.override and "*" or ""), tip)
					tbl[#tbl + 1] = cell(it.is_fluid and format.number(it.need) or { "cybersyn-gui.relative-eff-stacks", tostring(it.need) }, nil, color)
					tbl[#tbl + 1] = cell(it.capacity > 0 and ((it.gap >= 0 and "+" or "−") .. format.number(math.abs(it.gap))) or utext.NO_VALUE,
						nil, color)
				end
				out[#out + 1] = tbl
				if warned > 0 then
					out[#out + 1] = line({ "cybersyn-gui.relative-eff-warn", tostring(warned), tostring(e.item_capacity),
						format.number(e.fluid_capacity) }, nil, RED)
				end
			end
			if e.more_items > 0 then out[#out + 1] = note({ "cybersyn-gui.relative-more", tostring(e.more_items) }) end
			out[#out + 1] = line({ "cybersyn-gui.relative-eff-limit", e.limit >= rtext.UNLIMITED and "∞" or tostring(e.limit),
				tostring(e.priority) })
			if e.counting then
				out[#out + 1] = note({ "cybersyn-gui.relative-eff-counting", tostring(math.floor(e.counting * 100)) })
			end
			for _, n in ipairs(e.nets) do
				out[#out + 1] = line({ "cybersyn-gui.relative-eff-mask", network_rich(n.name), rtext.mask_text(n.mask),
					n.trains and tostring(n.trains) or "…", n.depots and tostring(n.depots) or "…" })
				if n.known then
					out[#out + 1] = line({ "cybersyn-gui.relative-eff-capacity", tostring(n.item_capacity),
						format.number(n.fluid_capacity), tostring(n.eligible) })
					local layouts = {}
					for i, layout_id in ipairs(n.missing) do
						if i > 4 then
							layouts[#layouts + 1] = "…"
							break
						end
						layouts[#layouts + 1] = rtext.layout_text(storage.layouts[layout_id])
					end
					local allow
					if n.accepted == false then
						allow = { "cybersyn-gui.relative-eff-allow-all", tostring(n.allow_trains) }
					else
						allow = { "cybersyn-gui.relative-eff-allow", tostring(n.accepted), tostring(n.allow_trains),
							#layouts > 0 and table.concat(layouts, ", ") or utext.NO_VALUE }
					end
					out[#out + 1] = line(allow, { "cybersyn-gui.relative-eff-allow-tooltip" },
						n.allow_trains == 0 and { 1, 0.45, 0.4 } or nil)
				end
			end
			out[#out + 1] = line({ "cybersyn-gui.relative-eff-s", "[color=" .. S_COLOUR[e.s_colour] .. "]S[/color]",
				{ "cybersyn-gui.relative-s-" .. e.s_colour } }, { "cybersyn-gui.relative-s-legend" })
			return out
		end)
	end
end

local function event_rows_sig(rows, now)
	local parts = { math.floor(now / rtext.AGE_STEP) }
	for i, ev in ipairs(rows) do parts[i + 1] = ev.seq end
	return table.concat(parts, ",")
end

local function render_events(state, body, kind, id, shown)
	if not storage.diag then
		state.cursor = nil
		if state.sigs["events"] ~= "" then section(state, body, "events", "", hidden) end
		return
	end
	local cursor = state.cursor
	if not cursor then
		cursor = diag.scan_cursor(kind, id, EVENTS)
		state.cursor = cursor
	end
	local rows = diag.last_for_step(cursor)
	local now = game.tick
	shown = shown or EVENTS
	-- The rows change only when the cursor's newest row or its first row does; the ages only every AGE_STEP.
	local step = math.floor(now / rtext.AGE_STEP)
	local first = rows[1] and rows[1].seq or 0
	local ec = state.events_sig
	local events_sig
	if ec and ec.first == first and ec.n == #rows and ec.step == step and ec.done == cursor.done and ec.shown == shown then
		events_sig = ec.sig
	else
		events_sig = event_rows_sig(rows, now) .. (cursor.done and "" or "+") .. shown
		state.events_sig = { first = first, n = #rows, step = step, done = cursor.done, shown = shown, sig = events_sig }
	end
	if state.sigs["events"] ~= events_sig then
		section(state, body, "events", events_sig, function()
			local out = { heading({ "cybersyn-gui.relative-events" }) }
			if #rows == 0 then
				out[#out + 1] = note(cursor.done and { kind == "train" and "cybersyn-gui.relative-events-none-train"
					or "cybersyn-gui.relative-events-none" } or { "cybersyn-gui.relative-events-scanning" })
				return out
			end
			local d = storage.diag
			for i, ev in ipairs(rows) do
				if i > shown then break end
				local caption = rtext.event_row(ev, now, util.short_duration)
				local hash = ev.item ~= 0 and d and d.item_hash[ev.item] or nil
				local _, _, item_tooltip = hash and util.item_sprite_and_tooltip(hash)
				if item_tooltip then caption = { "", caption, "  ", item_tooltip } end
				out[#out + 1] = line(caption, { "cybersyn-gui.relative-event-tooltip", util.format_duration(now - ev.tick),
					tostring(ev.seq) }, sev_color(ev.sev))
			end
			return out
		end)
	end
end

local function tool(name, sprite, tooltip, handler, enabled, tags)
	return {
		type = "sprite-button",
		name = name,
		style = "tool_button",
		sprite = sprite,
		tooltip = tooltip,
		enabled = enabled ~= false,
		tags = tags,
		handler = handler and { [defines.events.on_gui_click] = handler } or nil,
	}
end

local function render_stop_buttons(state, body, m)
	local station = storage.stations[state.id]
	local has2 = station and station.entity_comb2 and station.entity_comb2.valid or false
	local buttons_sig = m.sub .. tostring(has2)
	if state.sigs["buttons"] ~= buttons_sig then
		section(state, body, "buttons", buttons_sig, function()
			local row = {
				type = "flow",
				direction = "horizontal",
				style_mods = { vertical_align = "center", horizontal_spacing = 4 },
				{
					type = "button",
					name = "open_manager",
					caption = { "cybersyn-gui.relative-open-manager" },
					tooltip = { m.sub == "station" and "cybersyn-gui.relative-open-manager-tooltip"
						or "cybersyn-gui.relative-open-manager-depot-tooltip" },
					handler = { [defines.events.on_gui_click] = relative.handle.relative_open_manager },
				},
				tool("comb1", "item/cybersyn-combinator", { "cybersyn-gui.relative-comb1" }, relative.handle.relative_comb),
			}
			if m.sub == "station" then
				row[#row + 1] = tool("comb2", "item/cybersyn-combinator", { "cybersyn-gui.relative-comb2" },
					relative.handle.relative_comb, has2)
			end
			row[#row + 1] = { type = "empty-widget", style = "flib_horizontal_pusher" }
			row[#row + 1] = tool("rescan", "utility/refresh", { "cybersyn-gui.relative-rescan-later" }, nil, false)
			row[#row + 1] = tool("test_path", "utility/rail_path_not_possible", { "cybersyn-gui.relative-test-path-later" }, nil, false)
			return { row }
		end)
	end
end

-- ---------------------------------------------------------------- train model and sections

--- Schedule records as plain data, read once on open and again on on_train_schedule_changed.
local function read_schedule(state, entity)
	local records = {}
	local schedule = entity.get_schedule()
	for i, r in ipairs(schedule.get_records() or {}) do
		records[i] = {
			station = r.station,
			rail = r.rail ~= nil,
			temporary = r.temporary == true,
			created_by_interrupt = r.created_by_interrupt == true,
		}
	end
	state.schedule = { records = records, tick = game.tick }
end

--- @return table?
local function train_model(pd, state)
	local train = storage.trains[state.id]
	local entity = train and train.entity
	if not (entity and entity.valid) then return nil end
	if not state.schedule then read_schedule(state, entity) end
	local now = game.tick
	local current = entity.get_schedule().current
	local state_now = entity.state
	local m = {
		kind = "train",
		id = state.id,
		status = train.status,
		state = state_now,
		state_name = STATE_NAMES[state_now],
		state_since = train.state_tick,
		manifest = train.manifest or {},
		p_station_id = train.p_station_id,
		r_station_id = train.r_station_id,
		depot_id = train.depot_id,
		refueler_id = train.refueler_id,
		dispatch_tick = train.dispatch_tick,
		refuel_tick = train.refuel_tick,
		delivery_id = train.delivery_id,
		schedule = state.schedule.records,
		current = current,
		read_tick = now,
	}
	if state_now == WAIT_SIGNAL then
		local signal = entity.signal
		if signal and signal.valid then m.signal = signal end
	end
	return m
end

local function status_target(m)
	local s = m.status
	if s == STATUS_TO_P or s == STATUS_P then return "station", m.p_station_id end
	if s == STATUS_TO_R or s == STATUS_R then return "station", m.r_station_id end
	if s == STATUS_TO_F or s == STATUS_F then return "refueler", m.refueler_id end
	return "depot", m.depot_id
end

local function render_train_head(state, body, m)
	local now = game.tick
	local since = m.state_since and rtext.age_step(now - m.state_since) or -1
	local kind, target = status_target(m)
	local sig = table.concat({ m.status or -1, tostring(m.state), since, kind, tostring(target),
		tostring(target and stop_name(kind, target)) }, "|")
	if state.sigs["head"] ~= sig then
		section(state, body, "head", sig, function()
			local key = TRAIN_STATUS_KEY[m.status]
			local status = key and { key } or { "cybersyn-gui.trains-custom-status", tostring(m.status) }
			local out = {
				{
					type = "flow",
					direction = "horizontal",
					style_mods = { vertical_align = "center", horizontal_spacing = 4 },
					label(status, { style = "bold_label" }),
					stop_link(kind, target, INNER - 120),
				},
			}
			out[#out + 1] = {
				type = "flow",
				direction = "horizontal",
				style_mods = { vertical_align = "center", horizontal_spacing = 8 },
				{
					type = "button",
					style = STATE_CHIP[m.state] or "cybersyn_chip_grey",
					caption = { "cybersyn-gui.relative-state-" .. string.gsub(m.state_name or "unknown", "_", "-") },
					tooltip = { "cybersyn-gui.relative-state-tooltip" },
				},
				label(since >= 0 and { "cybersyn-gui.relative-in-state", util.short_duration(since) } or "",
					{ tooltip = m.state_since and util.format_duration(now - m.state_since) or nil }),
			}
			return out
		end)
	end
end

local function render_manifest(state, body, m)
	local parts = {}
	for i, it in ipairs(m.manifest) do parts[i] = (it.name or "?") .. ":" .. tostring(it.quality) .. "=" .. (it.count or 0) end
	local manifest_sig = table.concat(parts, ",")
	if state.sigs["manifest"] ~= manifest_sig then
		section(state, body, "manifest", manifest_sig, function()
			if #m.manifest == 0 then return nil end
			local slots = {}
			for _, it in ipairs(m.manifest) do
				local hash = hash_item(it.name, it.quality)
				slots[#slots + 1] = slot(hash, it.count, "default",
					{ "", "\n", { "cybersyn-gui.amount", format.number(it.count) } })
			end
			local out = { heading({ "cybersyn-gui.shipment" }) }
			for _, def in ipairs(slot_table(slots, #slots)) do out[#out + 1] = def end
			return out
		end)
	end
end

local function render_route(state, body, m)
	local now = game.tick
	local dispatched = m.dispatch_tick and rtext.age_step(now - m.dispatch_tick) or -1
	local refuel = m.refuel_tick and rtext.age_step(now - m.refuel_tick) or -1
	local sig = table.concat({ m.status or -1, tostring(m.p_station_id), tostring(m.r_station_id), tostring(m.depot_id),
		tostring(m.p_station_id and stop_name("station", m.p_station_id)),
		tostring(m.r_station_id and stop_name("station", m.r_station_id)),
		tostring(m.depot_id and stop_name("depot", m.depot_id)), dispatched, refuel }, "|")
	if state.sigs["route"] ~= sig then
		section(state, body, "route", sig, function()
			local out = {}
			local s = m.status
			if (m.p_station_id or m.r_station_id) and s and s >= STATUS_TO_P and s <= STATUS_R then
				out[#out + 1] = {
					type = "flow",
					direction = "horizontal",
					style_mods = { vertical_align = "center", horizontal_spacing = 4 },
					stop_link("station", m.p_station_id, math.floor((INNER - 24) / 2)),
					label("→"),
					stop_link("station", m.r_station_id, math.floor((INNER - 24) / 2)),
				}
			end
			out[#out + 1] = {
				type = "flow",
				direction = "horizontal",
				style_mods = { vertical_align = "center", horizontal_spacing = 4 },
				label({ "cybersyn-gui.relative-depot" }),
				stop_link("depot", m.depot_id, INNER - 80),
			}
			if dispatched >= 0 then
				out[#out + 1] = line({ "cybersyn-gui.relative-dispatched", util.short_duration(dispatched) })
			end
			out[#out + 1] = line({ "cybersyn-gui.relative-refuel",
				refuel >= 0 and { "cybersyn-gui.time-ago", util.short_duration(refuel) } or { "cybersyn-gui.never" } })
			return out
		end)
	end
end

local function render_schedule(state, body, m)
	local sig = tostring(state.schedule and state.schedule.tick) .. ":" .. tostring(m.current)
	if state.sigs["schedule"] ~= sig then
		section(state, body, "schedule", sig, function()
			local records = m.schedule
			if #records == 0 then return nil end
			local out = { heading({ "cybersyn-gui.relative-schedule" }) }
			for i, r in ipairs(records) do
				local row = rtext.schedule_row(i, r, m.current)
				out[#out + 1] = line(row.caption, nil, row.active and { 1, 0.74, 0.4 } or nil)
			end
			return out
		end)
	end
end

local function render_signal(state, body, m)
	local sig = m.signal and tostring(m.signal.unit_number) or ""
	if state.sigs["signal"] ~= sig then
		section(state, body, "signal", sig, function()
			if not m.signal then return nil end
			return {
				{
					type = "flow",
					direction = "horizontal",
					style_mods = { vertical_align = "center", horizontal_spacing = 8 },
					label({ "cybersyn-gui.relative-waiting-signal" }),
					{
						type = "button",
						name = "locate_signal",
						caption = { "cybersyn-gui.relative-locate" },
						tooltip = { "cybersyn-gui.relative-locate-signal-tooltip" },
						handler = { [defines.events.on_gui_click] = relative.handle.relative_locate_signal },
					},
				},
			}
		end)
	end
end

local function render_train_buttons(state, body, m)
	local buttons_sig = "train"
	if state.sigs["buttons"] ~= buttons_sig then
		section(state, body, "buttons", buttons_sig, function()
			return {
				{
					type = "flow",
					direction = "horizontal",
					style_mods = { vertical_align = "center", horizontal_spacing = 4 },
					{
						type = "button",
						name = "open_manager",
						caption = { "cybersyn-gui.relative-open-manager" },
						tooltip = { "cybersyn-gui.relative-open-manager-train-tooltip" },
						handler = { [defines.events.on_gui_click] = relative.handle.relative_open_manager },
					},
					{
						type = "button",
						name = "locate",
						caption = { "cybersyn-gui.relative-locate" },
						tooltip = { "cybersyn-gui.relative-locate-train-tooltip" },
						handler = { [defines.events.on_gui_click] = relative.handle.relative_locate_train },
					},
					{ type = "empty-widget", style = "flib_horizontal_pusher" },
					tool("path_trace", "utility/rail_path_not_possible", { "cybersyn-gui.relative-path-trace-later" }, nil, false),
				},
			}
		end)
	end
end

-- ---------------------------------------------------------------- refresh

local function render_banner(state, panel)
	-- mod_settings mirrors the setting (scripts/main.lua grab_all_settings), without a settings.global read per refresh.
	local paused = mod_settings.enable_planner == false
	local by = paused and storage.manager.paused_by or nil
	local sig = paused and ("p" .. tostring(by)) or ""
	if state.sigs.banner == sig then return end
	state.sigs.banner = sig
	local banner = panel.banner
	banner.visible = paused
	if paused then
		local who = by and by > 0 and game.get_player(by)
		banner.banner_label.caption = who and { "cybersyn-gui.dispatch-paused-by", who.name } or { "cybersyn-gui.dispatch-paused" }
		banner.banner_label.tooltip = { "cybersyn-gui.dispatch-paused-tooltip" }
	end
end

local function render_caption(state, panel, m, pd)
	local now = game.tick
	local age = now - (m.read_tick or now)
	local sig = utext.read_step(age) .. (m.source or "")
	if state.sigs.caption ~= sig then
		state.sigs.caption = sig
		panel.subheader.caption_label.tooltip = { "", utext.read_ago(age, util.format_duration),
			m.source == "live" and { "cybersyn-gui.relative-source-live" } or "" }
	end
	local open = pd.relative_effective_open == true
	local shown = m.sub == "station"
	local bsig = (open and "o" or "c") .. (shown and "s" or "h")
	if state.sigs.effective_button ~= bsig then
		state.sigs.effective_button = bsig
		local button = panel.subheader.effective_button
		button.toggled = open
		button.sprite = open and "utility/collapse" or "utility/expand"
		button.visible = shown
	end
end

--- Refreshes `panel` (a relative.build result) for state.kind/state.id; returns the model, nil when the subject is gone.
--- @param pd PlayerData
--- @param state RelativeState
--- @param panel LuaGuiElement
--- @return table?
function relative.render(pd, state, panel)
	state.refreshes = state.refreshes + 1
	local body = panel.scroll.body
	render_banner(state, panel)
	if state.kind == "stop" then
		local m = stop_model(pd, state)
		if not m then return nil end
		render_caption(state, panel, m, pd)
		render_stop_head(state, body, m)
		render_slots(state, body, m)
		local compact = pd.relative_effective_open == true
		render_unserved(state, body, m, compact)
		render_deliveries(state, body, m)
		render_control(state, body, m)
		render_setup(state, body, m)
		render_effective(state, body, m)
		if m.sub == "station" then
			render_events(state, body, "station", state.id, compact and EVENTS_COMPACT or EVENTS)
		else
			if state.sigs["events"] ~= "" then section(state, body, "events", "", hidden) end
		end
		render_stop_buttons(state, body, m)
		return m
	end
	local m = train_model(pd, state)
	if not m then return nil end
	render_caption(state, panel, m, pd)
	render_train_head(state, body, m)
	render_manifest(state, body, m)
	render_route(state, body, m)
	render_schedule(state, body, m)
	render_signal(state, body, m)
	render_events(state, body, "train", state.id)
	render_train_buttons(state, body, m)
	return m
end

-- ---------------------------------------------------------------- mounting

-- The stop panel is anchored to the train-stop window. The train window of 2.0 is the remote view's docked side
-- pane, and a relative GUI anchored to train_gui is drawn in the middle of the screen whatever its position (lab,
-- 2.0.77: left, right, top and bottom all land on the centre, over the train the view follows), so the train panel is
-- a screen frame placed right of that pane: 451 logical px wide below the 40 px title bar, measured at UI scale 1.5
-- on 3840x2160 and 1.0 on 1920x1080.
local ANCHORS = {
	stop = { gui = defines.relative_gui_type.train_stop_gui, position = defines.relative_gui_position.right, type = "train-stop" },
}
local TRAIN_PANE_RIGHT = 451
local TRAIN_PANE_TOP = 40
local GAP = 8
-- Logical px of the screen height the panel leaves free: the title bars above it and the subheader inside it.
local SCREEN_MARGIN = 120

--- @param player LuaPlayer
--- @param kind "stop"|"train"
--- @return LuaGuiElement root
local function root_of(player, kind)
	return kind == "train" and player.gui.screen or player.gui.relative
end

--- The mount of `kind` if it exists.
--- @return LuaGuiElement?
local function mount_of(player, kind)
	local frame = root_of(player, kind)[MOUNT[kind]]
	return frame and frame.valid and frame or nil
end

--- The player's mount for `kind`, created on first use.
--- @param player LuaPlayer
--- @param kind "stop"|"train"
--- @return LuaGuiElement mount
--- @return LuaGuiElement panel
local function mount(player, kind)
	local frame = mount_of(player, kind)
	if frame and frame[PANEL] then return frame, frame[PANEL] end
	if frame then frame.destroy() end
	frame = root_of(player, kind).add({ type = "frame", name = MOUNT[kind], direction = "vertical", anchor = ANCHORS[kind],
		visible = false })
	frame.style.padding = 8
	return frame, relative.build(frame, kind, nil)
end

--- Places the train panel beside the docked train pane for the player's current UI scale.
--- @param player LuaPlayer
--- @param frame LuaGuiElement
local function place_train(player, frame)
	local scale = player.display_scale
	frame.location = { x = math.floor((TRAIN_PANE_RIGHT + GAP) * scale), y = math.floor((TRAIN_PANE_TOP + GAP) * scale) }
end

--- Caps the panel's height to the player's screen: a stop with many requests, findings and events scrolls instead of
--- running off a 1080p screen at scale 1.
--- @param player LuaPlayer
--- @param panel LuaGuiElement a relative.build result
function relative.fit(player, panel)
	local height = math.floor(player.display_resolution.height / player.display_scale) - SCREEN_MARGIN
	local scroll = panel.scroll
	if scroll.style.maximal_height ~= height then scroll.style.maximal_height = height end
end

local function hide_all(player)
	for kind in pairs(MOUNT) do
		local frame = mount_of(player, kind)
		if frame and frame.visible then frame.visible = false end
	end
end

--- Closes the panel state of a player (the vanilla window closed, the player left).
--- @param player LuaPlayer?
--- @param pd PlayerData
function relative.close(player, pd)
	pd.relative_open = nil
	pd.relative = nil
	if player then hide_all(player) end
end

--- Shows the panel for a Cybersyn stop or train and renders it at once.
--- @param player LuaPlayer
--- @param pd PlayerData
--- @param kind "stop"|"train"
--- @param id uint
function relative.open(player, pd, kind, id)
	hide_all(player)
	local frame, panel = mount(player, kind)
	local state = pd.relative
	if not (state and state.kind == kind and state.id == id) then
		state = new_state(kind, id)
		pd.relative = state
	end
	panel.tags = { kind = kind, id = id }
	pd.relative_open = { kind = kind, id = id }
	if kind == "train" then place_train(player, frame) end
	relative.fit(player, panel)
	frame.visible = true
	if not relative.render(pd, state, panel) then relative.close(player, pd) end
end

--- What a vanilla window shows, as a relative panel subject: a Cybersyn stop or train, else nil.
--- @param entity LuaEntity
--- @return "stop"|"train"|nil kind
--- @return uint? id
--- @return boolean? cybersyn
local function subject_of(entity)
	if entity.type == "train-stop" then
		local id = entity.unit_number
		return "stop", id, (storage.stations[id] or storage.depots[id] or storage.refuelers[id]) ~= nil
	end
	if ROLLING_STOCK[entity.type] then
		local train = entity.train
		if not (train and train.valid) then return nil end
		return "train", train.id, storage.trains[train.id] ~= nil
	end
	return nil
end

--- on_gui_opened (registered unconditionally in scripts/main.lua).
--- @param e EventData.on_gui_opened
function relative.on_gui_opened(e)
	if e.gui_type ~= defines.gui_type.entity then return end
	local entity = e.entity
	if not (entity and entity.valid) then return end
	local manager_data = storage.manager
	local pd = manager_data and manager_data.players[e.player_index]
	local player = game.get_player(e.player_index)
	if not (pd and player) then return end
	local kind, id, cybersyn = subject_of(entity)
	if not kind then return end
	if not cybersyn then
		relative.close(player, pd)
		return
	end
	relative.open(player, pd, kind, id)
end

--- on_gui_closed of any entity GUI hides the panels.
--- @param e EventData.on_gui_closed
function relative.on_gui_closed(e)
	if e.gui_type ~= defines.gui_type.entity then return end
	local manager_data = storage.manager
	local pd = manager_data and manager_data.players[e.player_index]
	if not (pd and pd.relative_open) then return end
	relative.close(game.get_player(e.player_index), pd)
end

--- The manager tick: refreshes every open panel.
--- @param manager_data Manager
function relative.tick(manager_data)
	for i, pd in pairs(manager_data.players) do
		local open = pd.relative_open
		if open then
			local player = game.get_player(i)
			local frame = player and mount_of(player, open.kind)
			local panel = frame and frame[PANEL]
			local state = pd.relative
			if not (panel and state) then
				pd.relative_open = nil
				pd.relative = nil
			elseif not relative.render(pd, state, panel) then
				relative.close(player, pd)
			end
		end
	end
end

--- A schedule change of the train an open panel shows: read its records again on the next render.
--- @param e EventData.on_train_schedule_changed
function relative.on_train_schedule_changed(e)
	local manager_data = storage.manager
	if not manager_data then return end
	local train = e.train
	if not (train and train.valid) then return end
	local id = train.id
	for _, pd in pairs(manager_data.players) do
		local state = pd.relative
		if state and state.kind == "train" and state.id == id then state.schedule = nil end
	end
end

-- ---------------------------------------------------------------- handlers

function relative.wrapper(e, handler)
	local player = game.get_player(e.player_index)
	local manager_data = storage.manager
	local pd = manager_data and manager_data.players[e.player_index]
	if not (player and pd) then return end
	handler(player, pd, e)
end

local function rerender(player, pd)
	local open = pd.relative_open
	if not open then return end
	local frame = mount_of(player, open.kind)
	local panel = frame and frame[PANEL]
	if panel and pd.relative then relative.render(pd, pd.relative, panel) end
end

--- @param player LuaPlayer
--- @param pd PlayerData
function relative.handle.relative_toggle_effective(player, pd)
	pd.relative_effective_open = not pd.relative_effective_open or nil
	local state = pd.relative
	if state then
		state.sigs.effective = nil
		state.fleet = nil
		state.eff = nil
	end
	rerender(player, pd)
end

--- Opens the manager on the Stations tab searching for this stop (a depot: the Trains tab searching its name), or on
--- the Trains tab searching "#<id>" for a train. The other filters are cleared so the subject is in the list.
--- @param player LuaPlayer
--- @param pd PlayerData
function relative.open_manager(player, pd)
	local state = pd.relative
	if not state then return end
	local tab, query
	if state.kind == "train" then
		tab, query = "trains_tab", "#" .. state.id
	else
		local station = storage.stations[state.id]
		local name = stop_name(station and "station" or storage.depots[state.id] and "depot" or "refueler", state.id)
		if not name then return end
		tab, query = station and "stations_tab" or "trains_tab", name
	end
	util.set_search_query(pd, query)
	pd.search_open = true
	pd.search_item = nil
	pd.search_network_name = nil
	pd.search_network_mask = -1
	pd.search_surface_idx = nil
	pd.stations_status_filter = nil
	util.reset_pages(pd)
	pd.selected_tab = tab
	local refs = pd.refs
	if pd.is_manager_open then
		util.select_tab(pd, tab)
		manager.restore_filter_widgets(pd)
		local window = refs.manager_window
		if not pd.pinning and window and window.valid then player.opened = window end
		manager.render(player, pd)
	else
		manager.handle.manager_open(player, pd, refs)
	end
end

function relative.handle.relative_open_manager(player, pd)
	relative.open_manager(player, pd)
end

--- comb1 / comb2 tool buttons: the station's (or depot's, refueler's) combinators.
function relative.handle.relative_comb(player, pd, e)
	local state = pd.relative
	if not state or state.kind ~= "stop" then return end
	local which = e.element.name
	local station = storage.stations[state.id]
	local record = station or storage.depots[state.id] or storage.refuelers[state.id]
	local comb
	if station then
		comb = which == "comb2" and station.entity_comb2 or station.entity_comb1
	else
		comb = record and record.entity_comb
	end
	if comb and comb.valid then
		util.open_entity(player, pd, comb)
	else
		util.error_flying_text(player, { "cybersyn-message.error-cybernetic-combinator-not-found" })
	end
end

function relative.handle.relative_locate_train(player, pd)
	local state = pd.relative
	local train = state and state.kind == "train" and storage.trains[state.id]
	local entity = train and train.entity
	local front = entity and entity.valid and entity.front_stock
	if front then util.show_on_map(player, pd, front, front) end
end

function relative.handle.relative_locate_signal(player, pd)
	local state = pd.relative
	local train = state and state.kind == "train" and storage.trains[state.id]
	local entity = train and train.entity
	local signal = entity and entity.valid and entity.signal
	if signal and signal.valid then util.show_on_map(player, pd, signal) end
end

gui.add_handlers(relative.handle, relative.wrapper, "cybersyn_relative")

-- ---------------------------------------------------------------- dev interface

--- Plain data for a rendered element subtree: captions and visibility, depth first.
local function element_view(elem)
	local v = { name = elem.name ~= "" and elem.name or nil, type = elem.type }
	if elem.type == "label" or elem.type == "button" then v.caption = elem.caption end
	if elem.type == "sprite-button" then
		v.sprite = elem.sprite
		v.enabled = elem.enabled
	end
	if elem.type == "button" and not elem.enabled then v.enabled = false end
	local kids = elem.children
	if #kids > 0 then
		v.children = {}
		for i, c in ipairs(kids) do v.children[i] = element_view(c) end
	end
	return v
end

local function strip_model(m)
	if not m then return nil end
	local out = {}
	for k, v in pairs(m) do
		if k ~= "st" and k ~= "signal" and k ~= "findings" then out[k] = v end
	end
	if m.findings then
		out.findings = {}
		for i, f in ipairs(m.findings) do out.findings[i] = { check = LINT_NAMES[f.check], a = f.a, b = f.b, network = f.network } end
	end
	if m.unserved then
		out.unserved = {}
		for i, r in ipairs(m.unserved) do out.unserved[i] = { hash = r.hash, reason = REASON_NAMES[r.e.reason], a = r.e.a, b = r.e.b } end
	end
	if m.signal then out.signal = m.signal.unit_number end
	return out
end

local function dev_context(pi)
	local player = game.get_player(pi)
	if not player then error("no player " .. tostring(pi)) end
	local pd = storage.manager.players[pi]
	if not pd then error("no manager data for player " .. tostring(pi)) end
	return player, pd
end

local function dev_entity(kind, id)
	if kind == "stop" then
		local record = storage.stations[id] or storage.depots[id] or storage.refuelers[id]
		if record then return record.entity_stop end
		for _, surface in pairs(game.surfaces) do
			for _, stop in ipairs(surface.find_entities_filtered({ type = "train-stop" })) do
				if stop.unit_number == id then return stop end
			end
		end
		return nil
	end
	local train = storage.trains[id]
	local entity = train and train.entity
	if entity and entity.valid then return entity.front_stock end
	for _, surface in pairs(game.surfaces) do
		for _, t in ipairs(game.train_manager.get_trains({ surface = surface })) do
			if t.id == id then return t.front_stock end
		end
	end
	return nil
end

local dev_fns = {}

--- Emulates on_gui_opened of a stop's or train's vanilla window: player.opened cannot be set for an offline player,
--- so the handler is called directly with the event the engine would raise.
function dev_fns.relative_open(pi, kind, id)
	local entity = dev_entity(kind, id)
	if not entity then return "no entity for " .. tostring(kind) .. " " .. tostring(id) end
	relative.on_gui_opened({ name = defines.events.on_gui_opened, player_index = pi, gui_type = defines.gui_type.entity,
		entity = entity, tick = game.tick })
	return dev_fns.relative_dump(pi)
end

--- Emulates on_gui_closed of the window the panel belongs to.
function dev_fns.relative_close(pi)
	local player, pd = dev_context(pi)
	local open = pd.relative_open
	local entity = open and dev_entity(open.kind, open.id)
	relative.on_gui_closed({ name = defines.events.on_gui_closed, player_index = pi, gui_type = defines.gui_type.entity,
		entity = entity, tick = game.tick })
	return dev_fns.relative_dump(pi)
end

--- The open panel: subject, mount visibility, the model the last refresh used, and every section's rendered captions.
function dev_fns.relative_dump(pi)
	local player, pd = dev_context(pi)
	local out = { open = pd.relative_open, effective_open = pd.relative_effective_open == true, mounts = {} }
	for kind in pairs(MOUNT) do
		local frame = mount_of(player, kind)
		out.mounts[kind] = frame and { visible = frame.visible, anchor = kind == "stop" and frame.anchor or nil,
			location = kind == "train" and frame.location or nil } or nil
	end
	local open = pd.relative_open
	local state = pd.relative
	if not (open and state) then return out end
	local frame = mount_of(player, open.kind)
	local panel = frame[PANEL]
	out.width = panel.style.minimal_width
	out.caption = panel.subheader.caption_label.caption
	out.caption_tooltip = panel.subheader.caption_label.tooltip
	out.banner = panel.banner.visible and panel.banner.banner_label.caption or nil
	out.rebuilds = state.rebuilds
	out.rebuilt = state.rebuilt
	out.refreshes = state.refreshes
	out.sections = {}
	for _, s in ipairs(panel.scroll.body.children) do
		out.sections[s.name] = { visible = s.visible, content = s.visible and element_view(s).children or nil }
	end
	if open.kind == "stop" then
		out.model = strip_model(stop_model(pd, state))
	else
		out.model = strip_model(train_model(pd, state))
	end
	if state.cursor then
		out.cursor = { done = state.cursor.done, examined = state.cursor.examined, rows = #state.cursor.rows }
	end
	return out
end

--- `n` refreshes of the open panel, profiled (the PLAN3 §5 row 5 gate: ≤ 0.2 ms per refresh). With `rebuild`, every
--- section is rebuilt each time (the signatures are dropped first): the cost of a refresh in which everything changed.
function dev_fns.relative_refresh_ms(pi, n, rebuild)
	local player, pd = dev_context(pi)
	local open = pd.relative_open
	if not open then return "no panel open" end
	local frame = mount_of(player, open.kind)
	local panel = frame[PANEL]
	n = n or 1
	local total = game.create_profiler()
	for _ = 1, n do
		if rebuild then pd.relative.sigs = {} end
		relative.render(pd, pd.relative, panel)
	end
	total.stop()
	local avg = game.create_profiler()
	avg.stop()
	avg.add(total)
	avg.divide(n)
	return { "", "n=", n, " total ", total, " avg ", avg }
end

--- One refresh of the open stop panel split into its steps, each timed (where a refresh spends its time).
function dev_fns.relative_profile(pi)
	local player, pd = dev_context(pi)
	local open = pd.relative_open
	if not open or open.kind ~= "stop" then return "no stop panel open" end
	local panel = mount_of(player, "stop")[PANEL]
	local state = pd.relative
	local body = panel.scroll.body
	local out = { "" }
	local function step(name, fn)
		local p = game.create_profiler()
		local r = fn()
		p.stop()
		out[#out + 1] = { "", name, " ", p, "  " }
		return r
	end
	state.refreshes = state.refreshes + 1
	step("banner", function() render_banner(state, panel) end)
	local m = step("model", function() return stop_model(pd, state) end)
	if not m then return "gone" end
	local compact = pd.relative_effective_open == true
	step("caption", function() render_caption(state, panel, m, pd) end)
	step("head", function() render_stop_head(state, body, m) end)
	step("slots", function() render_slots(state, body, m) end)
	step("unserved", function() render_unserved(state, body, m, compact) end)
	step("deliveries", function() render_deliveries(state, body, m) end)
	step("control", function() render_control(state, body, m) end)
	step("setup", function() render_setup(state, body, m) end)
	step("effective", function() render_effective(state, body, m) end)
	step("events", function() render_events(state, body, "station", state.id, compact and EVENTS_COMPACT or EVENTS) end)
	step("buttons", function() render_stop_buttons(state, body, m) end)
	return out
end

function dev_fns.relative_toggle_effective(pi)
	local player, pd = dev_context(pi)
	relative.handle.relative_toggle_effective(player, pd)
	return pd.relative_effective_open == true
end

--- Clicks a button of the open panel by its element name ("open_manager", "comb1", "locate", ...).
function dev_fns.relative_click(pi, name)
	local player, pd = dev_context(pi)
	local open = pd.relative_open
	if not open then return "no panel open" end
	local panel = mount_of(player, open.kind)[PANEL]
	local function find(elem)
		if elem.name == name then return elem end
		for _, c in ipairs(elem.children) do
			local hit = find(c)
			if hit then return hit end
		end
	end
	local elem = find(panel)
	if not elem then return "no element " .. tostring(name) end
	return gui.dispatch({ name = defines.events.on_gui_click, element = elem, player_index = pi, tick = game.tick,
		button = defines.mouse_button_type.left, shift = false, control = false, alt = false })
end

dev.extend(dev_fns)

return relative
