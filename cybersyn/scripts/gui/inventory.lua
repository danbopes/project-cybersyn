local gui = require("__flib__.gui")

local util = require("scripts.gui.util")
local constants = require("constants")
local format = require("__flib__.format")
local collector = require("scripts.gui.collector")
local dev = require("scripts.gui.dev")

local inventory_tab = {}

local TAB = "inventory_tab"
local GRIDS = { "provided", "in_transit", "requested" }
local GRID_COLUMNS = { provided = 12, in_transit = 8, requested = 8 }
local TOP_N = 5
local WAIT_SIG_TICKS = 600

local SORT_COLUMNS = { "item_order", "amount", "stations", "wait" }
local DEFAULT_SORT = "item_order"
-- Engineers look for the biggest numbers first; item order reads naturally top-down.
local DEFAULT_ASCENDING = { item_order = true, amount = false, stations = false, wait = false }

local function grid_table_name(grid)
	return "inventory_" .. grid .. "_table"
end

--- @param grid string
local function grid_def(grid)
	local columns = GRID_COLUMNS[grid]
	local locale = string.gsub(grid, "_", "-")
	return {
		type = "flow",
		direction = "vertical",
		{
			type = "label",
			name = "inventory_" .. grid .. "_header",
			style = "bold_label",
			caption = { "cybersyn-gui." .. locale },
			tooltip = { "cybersyn-gui.inventory-" .. locale .. "-legend" },
		},
		{
			type = "frame",
			style = "deep_frame_in_shallow_frame",
			style_mods = { height = constants.gui_inventory_table_height },
			{
				type = "scroll-pane",
				style = "ltnm_slot_table_scroll_pane",
				style_mods = { width = 40 * columns + 12, minimal_height = constants.gui_inventory_table_height },
				vertical_scroll_policy = "auto-and-reserve-space",
				{
					type = "table",
					name = grid_table_name(grid),
					style = "slot_table",
					column_count = columns,
				},
			},
		},
	}
end

local function sort_toolbar_def()
	local children = {
		type = "flow",
		name = "inventory_sort_toolbar",
		direction = "horizontal",
		style_mods = { vertical_align = "center", horizontal_spacing = 12 },
		{ type = "label", style = "bold_label", caption = { "cybersyn-gui.inventory-sort-by" } },
	}
	for _, column in ipairs(SORT_COLUMNS) do
		local locale = string.gsub(column, "_", "-")
		children[#children + 1] = {
			type = "checkbox",
			name = "inventory_sort_" .. column,
			style = column == DEFAULT_SORT and "ltnm_selected_sort_checkbox" or "ltnm_sort_checkbox",
			caption = { "cybersyn-gui.inventory-sort-" .. locale },
			tooltip = { "cybersyn-gui.inventory-sort-" .. locale .. "-tooltip" },
			state = false,
			tags = { column = column },
			handler = { [defines.events.on_gui_checked_state_changed] = inventory_tab.handle.on_inventory_sort_changed },
		}
	end
	return children
end

function inventory_tab.create()
	return {
		tab = {
			name = "manager_inventory_tab",
			type = "tab",
			caption = { "cybersyn-gui.inventory" },
			handler = { [defines.events.on_gui_click] = inventory_tab.handle.on_inventory_tab_selected },
		},
		content = {
			name = "manager_inventory_content_frame",
			type = "flow",
			direction = "vertical",
			style_mods = { vertical_spacing = 8 },
			sort_toolbar_def(),
			{
				type = "flow",
				direction = "horizontal",
				style_mods = { horizontal_spacing = 12 },
				grid_def("provided"),
				grid_def("in_transit"),
				grid_def("requested"),
			},
		},
	}
end

--- Keeps the TOP_N largest entries in a flat {mag, id, name, mag, id, name, ...} list, ties broken by station id
--- so the list does not depend on station iteration order.
--- @param top table
--- @param mag number
--- @param id uint
--- @param name string
local function top_insert(top, mag, id, name)
	local n = #top / 3
	local pos = n + 1
	for i = 1, n do
		local m, other = top[i * 3 - 2], top[i * 3 - 1]
		if mag > m or (mag == m and id < other) then
			pos = i
			break
		end
	end
	if pos > TOP_N then return end
	local last = math.min(n, TOP_N - 1)
	for i = last, pos, -1 do
		local b = i * 3
		top[b + 1], top[b + 2], top[b + 3] = top[b - 2], top[b - 1], top[b]
	end
	local b = pos * 3
	top[b - 2], top[b - 1], top[b] = mag, id, name
end

--- @param bucket table
--- @param top_bucket table
--- @param hash string
--- @param count int signed amount added to the total
--- @param mag number magnitude used to rank the station
--- @param st SnapshotStation
local function accumulate(bucket, top_bucket, hash, count, mag, st)
	local agg = bucket[hash]
	if agg then
		agg.count = agg.count + count
		agg.stations = agg.stations + 1
	else
		agg = { count = count, stations = 1 }
		bucket[hash] = agg
	end
	local top = top_bucket[hash]
	if not top then
		top = {}
		top_bucket[hash] = top
	end
	top_insert(top, mag, st.id, st.name)
	return agg
end

--- One pass over the snapshot producing the per-grid totals and each item's top stations together, so a
--- tooltip's top list always agrees with the totals shown next to it.
--- @param snapshot Snapshot
--- @param f ManagerFilters
local function aggregate_with_top(snapshot, f)
	local filtered = util.filters_active(f, true)
	local inv = { provided = {}, requested = {}, in_transit = {} }
	local top = { provided = {}, requested = {}, in_transit = {} }
	local has_wait = false
	for _, st in pairs(snapshot.stations) do
		if not filtered or util.station_passes(st, f, true) then
			for hash, count in pairs(st.provided) do
				accumulate(inv.provided, top.provided, hash, count, count, st)
			end
			local wait = st.wait
			for hash, req in pairs(st.requested) do
				if req.active then
					local agg = accumulate(inv.requested, top.requested, hash, req.count, -req.count, st)
					local start = wait and wait[hash]
					if start and (not agg.earliest_wait_start or start < agg.earliest_wait_start) then
						agg.earliest_wait_start = start
						has_wait = true
					end
				end
			end
			for hash, count in pairs(st.deliveries) do
				if count > 0 then
					accumulate(inv.in_transit, top.in_transit, hash, count, count, st)
				end
			end
		end
	end
	return inv, top, has_wait
end

--- @param f ManagerFilters
local function filter_signature(f)
	return (f.terms and table.concat(f.terms, " ") or "") .. "|" .. (f.network or "") .. "|" .. f.mask .. "|" .. (f.surface or "")
end

--- The aggregate is recomputed only when a collector pass completes or the filters change, and lives in storage so
--- the rendered output never depends on whether a client happened to have it cached.
--- @param player_data PlayerData
--- @param snapshot Snapshot
--- @param f ManagerFilters
local function get_cache(player_data, snapshot, f)
	local fkey = filter_signature(f)
	local cache = player_data.inventory_cache
	if cache and cache.tick == snapshot.tick and cache.started == snapshot.started_tick and cache.fkey == fkey then
		return cache
	end
	local inv, top, has_wait = aggregate_with_top(snapshot, f)
	-- Kept outside the cache, which is dropped on close, so a grid's render signature can never repeat a stale one.
	local version = (player_data.inventory_version or 0) + 1
	player_data.inventory_version = version
	cache = {
		tick = snapshot.tick,
		started = snapshot.started_tick,
		fkey = fkey,
		inv = inv,
		top = top,
		has_wait = has_wait,
		order = {},
		version = version,
	}
	player_data.inventory_cache = cache
	return cache
end

--- Sort key for one item of a grid. `wait` only means something for requests while wait tracking produced data;
--- otherwise it falls back to item order.
--- @param column string
--- @param grid string
--- @param bucket table the grid's aggregate
--- @param has_wait boolean?
--- @return string column_used
--- @return fun(hash: string): number?
local function key_fn(column, grid, bucket, has_wait)
	if column == "amount" then
		return column, function(hash) return math.abs(bucket[hash].count) end
	elseif column == "stations" then
		return column, function(hash) return bucket[hash].stations end
	elseif column == "wait" and grid == "requested" and has_wait then
		return column, function(hash)
			local start = bucket[hash].earliest_wait_start
			return start and -start or nil
		end
	end
	return "item_order", util.item_rank
end

-- Equal keys fall back to crafting-menu order rather than the hash's alphabetical order; the fixed-width rank keeps
-- the string comparison numeric, and the hash suffix keeps it unique. Memoised like util.item_rank: a pure function
-- of the loaded prototypes, so a cold cache on a joining client cannot change the result.
local tiebreak_cache = {}
local function item_order_tiebreak(hash)
	local key = tiebreak_cache[hash]
	if not key then
		key = string.format("%016.5f|%s", util.item_rank(hash), hash)
		tiebreak_cache[hash] = key
	end
	return key
end

--- Display order, memoised in the cache because it only changes with the aggregate or the sort.
--- @param cache table
--- @param grid string
--- @param column string
--- @param ascending boolean
--- @return string[] hashes in display order
local function ordered_hashes(cache, grid, column, ascending)
	local order_key = grid .. "|" .. column .. "|" .. tostring(ascending)
	local cached = cache.order[order_key]
	if cached then return cached end
	local bucket = cache.inv[grid]
	local list = {}
	for hash in pairs(bucket) do
		if util.item_sprite_and_tooltip(hash) then list[#list + 1] = hash end
	end
	local used, fn = key_fn(column, grid, bucket, cache.has_wait)
	if used ~= column then ascending = true end
	util.sort_by(list, fn, ascending, item_order_tiebreak)
	cache.order[order_key] = list
	return list
end

--- @param top table flat top-station list
--- @return LocalisedString
local function top_tooltip(top)
	local out = { "", "\n\n", { "cybersyn-gui.inventory-top-stations" } }
	for i = 1, #top / 3 do
		local b = i * 3
		out[#out + 1] = { "", "\n", { "cybersyn-gui.inventory-top-station-line", top[b], format.number(top[b - 2]) } }
	end
	return out
end

--- @param scope string
--- @param hash string
--- @param agg table
--- @param style string
--- @param sig string
--- @param tooltip_fn fun(): LocalisedString
local function item_entry(scope, hash, agg, style, sig, tooltip_fn)
	return {
		key = hash,
		sig = sig,
		build = function()
			local sprite, quality = util.item_sprite_and_tooltip(hash)
			return util.hoverable({
				type = "sprite-button",
				sprite = sprite,
				quality = quality,
				style = style,
				tags = { item_hash = hash },
				handler = { [defines.events.on_gui_click] = inventory_tab.handle.on_inventory_item_click },
				tooltip = tooltip_fn(),
				{
					type = "label",
					style = "ltnm_label_signal_count_inventory",
					ignored_by_interaction = true,
					caption = format_signal_count(agg.count),
				},
				{
					type = "label",
					style = "ltnm_label_train_count_inventory",
					ignored_by_interaction = true,
					caption = format_signal_count(agg.stations),
				},
			}, scope)
		end,
		update = function(elem)
			local count_caption = format_signal_count(agg.count)
			local stations_caption = format_signal_count(agg.stations)
			local labels = elem.children
			if labels[1].caption ~= count_caption then labels[1].caption = count_caption end
			if labels[2].caption ~= stations_caption then labels[2].caption = stations_caption end
			elem.tooltip = tooltip_fn()
			if elem.style.name ~= style then elem.style = style end
		end,
	}
end

local CLICK_HINT = { "", "\n", { "cybersyn-gui.inventory-click-hint" } }
local STATIONS_KEY = {
	provided = "cybersyn-gui.provided-by-stations",
	in_transit = "cybersyn-gui.in-transit-to-stations",
	requested = "cybersyn-gui.requested-by-stations",
}

--- @param player_data PlayerData
--- @param grid string
--- @param n integer
local function update_header(player_data, grid, n)
	local header = player_data.refs["inventory_" .. grid .. "_header"]
	if not (header and header.valid) then return end
	local state = util.gui_state(player_data, header.name)
	if state.n == n then return end
	state.n = n
	header.caption = { "cybersyn-gui.inventory-grid-header", { "cybersyn-gui." .. string.gsub(grid, "_", "-") }, format.number(n) }
end

local function run_update(entry, elem, index, sigs)
	local sig = entry.sig
	if sigs[entry.key] == sig then return end
	sigs[entry.key] = sig
	entry.update(elem, entry, index)
end

--- util.sync_children with the same state contract, but a changed key sequence is reached by destroying the
--- vanished buttons, swapping the moved ones and inserting the new ones at their index. A completed pass usually
--- adds or drops a handful of items, and a sort change only permutes them, so this keeps hundreds of buttons (and
--- the player's scroll position) instead of recreating every button after the first difference.
--- @param parent LuaGuiElement
--- @param entries table[]
--- @param state {keys: string[]?, sigs: table?, dirty: true?}
--- @param hold boolean
--- @return "updated"|"held"|"rebuilt"
local function reconcile(parent, entries, state, hold)
	local n = #entries
	local keys = {}
	for i = 1, n do
		keys[i] = entries[i].key
	end
	local old = state.keys
	local elems = parent.children
	if old and #old ~= #elems then old = nil end
	local sigs = old and state.sigs or {}
	state.sigs = sigs

	if old then
		local same = #old == n
		if same then
			for i = 1, n do
				if old[i] ~= keys[i] then
					same = false
					break
				end
			end
		end
		if same then
			for i = 1, n do
				run_update(entries[i], elems[i], i, sigs)
			end
			state.dirty = nil
			return "updated"
		end
		if hold then
			local index_of = {}
			for i = 1, n do
				index_of[keys[i]] = i
			end
			for j = 1, #old do
				local i = index_of[old[j]]
				if i then run_update(entries[i], elems[j], i, sigs) end
			end
			state.dirty = true
			return "held"
		end
	end

	if not old then
		parent.clear()
		sigs = {}
		state.sigs = sigs
		for i = 1, n do
			local entry = entries[i]
			gui.add(parent, entry.build())
			sigs[entry.key] = entry.sig
		end
		state.keys = keys
		state.dirty = nil
		return "rebuilt"
	end

	local wanted = {}
	for i = 1, n do
		wanted[keys[i]] = true
	end
	local cur = {}
	for j = 1, #old do
		cur[j] = old[j]
	end
	for j = #cur, 1, -1 do
		local key = cur[j]
		if not wanted[key] then
			elems[j].destroy()
			table.remove(cur, j)
			table.remove(elems, j)
			sigs[key] = nil
		end
	end
	local pos_of = {}
	for j = 1, #cur do
		pos_of[cur[j]] = j
	end
	for i = 1, n do
		local key = keys[i]
		local entry = entries[i]
		if cur[i] ~= key then
			local j = pos_of[key]
			if j then
				parent.swap_children(i, j)
				cur[i], cur[j] = cur[j], cur[i]
				elems[i], elems[j] = elems[j], elems[i]
				pos_of[cur[i]] = i
				pos_of[cur[j]] = j
			else
				local def = entry.build()
				def.index = i
				local _, elem = gui.add(parent, def)
				table.insert(cur, i, key)
				table.insert(elems, i, elem)
				for m = i + 1, #cur do
					pos_of[cur[m]] = m
				end
				sigs[key] = entry.sig
			end
		end
		run_update(entry, elems[i], i, sigs)
	end
	state.keys = keys
	state.dirty = nil
	return "rebuilt"
end

--- @param player_data PlayerData
--- @param table_elem LuaGuiElement
--- @param state table from util.gui_state
--- @param entries table[]
local function render_grid(player_data, grid, table_elem, state, entries)
	local result = reconcile(table_elem, entries, state, util.hold_active(player_data, table_elem.name))
	update_header(player_data, grid, #entries)
	return result
end

--- @param snapshot Snapshot
--- @param f ManagerFilters
--- @param hash string
local function is_starved(snapshot, f, hash)
	if f.network then
		local starved = snapshot.starved
		return starved ~= nil and starved[f.network .. ":" .. hash] == true
	end
	local items = snapshot.starved_items
	return items ~= nil and items[hash] == true
end

--- @param cache table from get_cache
--- @param grid string
--- @param scope string hover scope (the grid's table name)
--- @param snapshot Snapshot
--- @param f ManagerFilters
--- @param selected string? item filter hash, highlighted rather than hidden
--- @return table[] entries for util.sync_children
local function build_entries(cache, grid, scope, snapshot, f, column, ascending, selected, now)
	local inv = cache.inv
	local bucket = inv[grid]
	local top_bucket = cache.top[grid]
	local hashes = ordered_hashes(cache, grid, column, ascending)
	local is_requested = grid == "requested"
	local base_color = grid == "provided" and "green" or "blue"
	local stations_key = STATIONS_KEY[grid]
	local entries = {}
	for i, hash in ipairs(hashes) do
		local agg = bucket[hash]
		local color, sig_extra, transit, starved
		if is_requested then
			transit = inv.in_transit[hash]
			starved = is_starved(snapshot, f, hash)
			color = starved and "pink" or transit and "orange" or "red"
			local start = agg.earliest_wait_start
			sig_extra = (starved and "s" or "") .. "|" .. (start and math.floor((now - start) / WAIT_SIG_TICKS) or "") .. "|"
				.. (transit and transit.count or "")
		else
			color = base_color
		end
		local style = (hash == selected and "flib_selected_slot_button_" or "flib_slot_button_") .. color
		local item_top = top_bucket[hash]
		-- Content-based rather than version-based, so a completed pass only touches the items whose numbers moved.
		local sig = agg.count .. "|" .. agg.stations .. "|" .. style .. "|" .. (sig_extra or "") .. "|"
			.. (item_top and table.concat(item_top, "\31") or "")
		entries[i] = item_entry(scope, hash, agg, style, sig, function()
			local _, _, name_tooltip = util.item_sprite_and_tooltip(hash)
			local tail = { "", "\n", { stations_key, tostring(agg.stations) } }
			if is_requested then
				local start = agg.earliest_wait_start
				if start then
					tail = { "", tail, "\n[color=yellow]", { "cybersyn-gui.waiting-for", util.format_duration(now - start) }, "[/color]" }
				end
				if transit then
					tail = { "", tail, "\n[color=orange]", { "cybersyn-gui.in-transit-amount", format.number(transit.count) }, "[/color]" }
				else
					tail = { "", tail, "\n[color=red]", { "cybersyn-gui.not-in-transit" }, "[/color]" }
				end
				if starved then
					tail = { "", tail, "\n[color=red]", { "cybersyn-gui.inventory-starved" }, "[/color]" }
				end
			end
			return {
				"", name_tooltip, tail,
				"\n", { "cybersyn-gui.amount", format.number(math.abs(agg.count)) },
				item_top and top_tooltip(item_top) or "",
				CLICK_HINT,
			}
		end)
	end
	return entries
end

--- The item filter highlights instead of hiding; the other filters restrict which stations are aggregated.
---@param map_data MapData
---@param player_data PlayerData
function inventory_tab.build(map_data, player_data)
	local refs = player_data.refs
	local snapshot = collector.get()
	local f = util.get_filters(player_data)
	local cache = get_cache(player_data, snapshot, f)
	local version = cache.version
	local column, ascending = util.get_sort(player_data, TAB, DEFAULT_SORT)
	util.sync_sort_header(refs.inventory_sort_toolbar, column, ascending)
	local selected = f.item
	local now = game.tick

	for _, grid in ipairs(GRIDS) do
		local scope = grid_table_name(grid)
		local table_elem = refs[scope]
		if table_elem and table_elem.valid then
			local state = util.gui_state(player_data, scope)
			-- Wait times in the requested tooltips age even when nothing else changes.
			local wait_bucket = grid == "requested" and cache.has_wait and math.floor(now / WAIT_SIG_TICKS) or ""
			local render_sig = version .. "|" .. column .. "|" .. tostring(ascending) .. "|" .. (selected or "") .. "|"
				.. table_elem.index .. "|" .. wait_bucket
			if state.render_sig ~= render_sig or state.dirty or not state.keys then
				local entries = build_entries(cache, grid, scope, snapshot, f, column, ascending, selected, now)
				local result = render_grid(player_data, grid, table_elem, state, entries)
				state.render_sig = result ~= "held" and render_sig or nil
			end
		end
	end
end

--- Dump for the dev interface: per grid the rendered hashes and count captions in display order, and the sort key
--- of each, recomputed from the cached aggregate the render used.
dev.register_dump(TAB, function(player_data)
	local refs = player_data.refs
	local column, ascending = util.get_sort(player_data, TAB, DEFAULT_SORT)
	local cache = player_data.inventory_cache
	local out = { column = column, ascending = ascending, version = cache and cache.version }
	for _, grid in ipairs(GRIDS) do
		local hashes, captions, keys, styles, ranks = {}, {}, {}, {}, {}
		local bucket = cache and cache.inv[grid] or {}
		local used, fn = key_fn(column, grid, bucket, cache and cache.has_wait)
		local stale = 0
		for i, button in ipairs(refs[grid_table_name(grid)].children) do
			local hash = button.tags.item_hash
			hashes[i] = hash
			captions[i] = button.children[1].caption
			styles[i] = button.style.name
			ranks[i] = util.item_rank(hash)
			local agg = bucket[hash]
			keys[i] = agg and fn(hash) or false
			if not agg or captions[i] ~= format_signal_count(agg.count) or button.children[2].caption ~= format_signal_count(agg.stations) then
				stale = stale + 1
			end
		end
		local expected = 0
		for hash in pairs(bucket) do
			if util.item_sprite_and_tooltip(hash) then expected = expected + 1 end
		end
		local grid_ascending = ascending
		if used ~= column then grid_ascending = true end
		out[grid] = {
			hashes = hashes,
			captions = captions,
			keys = keys,
			styles = styles,
			ranks = ranks,
			column = used,
			ascending = grid_ascending,
			header = refs["inventory_" .. grid .. "_header"].caption,
			stale = stale,
			expected = expected,
		}
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
	player_data.selected_tab = TAB
end

---@param player LuaPlayer
---@param player_data PlayerData
---@param refs table<string, LuaGuiElement>
---@param e EventData.on_gui_checked_state_changed
function inventory_tab.handle.on_inventory_sort_changed(player, player_data, refs, e)
	local column = e.element.tags.column --[[@as string]]
	if not column then return end
	local current = util.get_sort(player_data, TAB, DEFAULT_SORT)
	if current == column then
		util.set_sort(player_data, TAB, column)
	else
		util.set_sort(player_data, TAB, column, DEFAULT_ASCENDING[column])
	end
	util.rerender(player, player_data)
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
