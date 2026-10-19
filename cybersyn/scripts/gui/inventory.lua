local gui = require("__flib__.gui")

local util = require("scripts.gui.util")
local format = require("__flib__.format")
local collector = require("scripts.gui.collector")
local dev = require("scripts.gui.dev")
local stats = require("scripts.stats")
local logic = require("scripts.gui.tab-logic")
local stations_tab = require("scripts.gui.stations")

local inventory_tab = {}

--- @class PlayerData
--- @field inventory_sorts {[string]: string}? per grid the column its sort buttons chose; a grid without one follows
---   the tab's sort (util.get_sort), which the Overview's Throughput tile and the dev interface set
--- @field inventory_dim true? Provided dims the items nobody on the same network requests

local TAB = "inventory_tab"
local GRIDS = { "provided", "in_transit", "requested" }
local GRID_GAP = 12
-- Scroll bar and frame borders inside a grid.
local GRID_INNER = 16
local SLOT_ROW = 40
local TOP_N = 5
local WAIT_SIG_TICKS = 600
-- A completed pass changes a few hundred buttons on a large base; each costs 40-60 us on pY 123 (tooltip rebuild plus
-- API writes), so they are spread over renders rather than landing on one tick.
local BACKGROUND_UPDATE_BUDGET = 60
-- Below this a whole refresh is cheap, and a pass may complete on every render, which spreading would starve.
local SPREAD_MIN_STATIONS = 300

local DEFAULT_SORT = "item_order"
-- Engineers look for the biggest numbers first; item order reads naturally top-down; the largest shortage first.
local DEFAULT_ASCENDING = { item_order = true, amount = false, stations = false, wait = false, deficit = false }
local GRID_SORTS = {
	provided = { "item_order", "amount", "stations" },
	in_transit = { "item_order", "amount", "stations" },
	requested = { "item_order", "amount", "stations", "wait", "deficit" },
}
local SORT_SPRITE = {
	item_order = "utility/list_view",
	stations = "item/train-stop",
	wait = "utility/clock",
	deficit = "virtual-signal/signal-alert",
}
-- Without a fitting sprite the button shows a caption instead.
local SORT_CAPTION = { amount = "#" }

local function grid_table_name(grid)
	return "inventory_" .. grid .. "_table"
end

--- @param grid string
--- @param column string
--- @return flib.GuiElemDef
local function sort_button(grid, column)
	local locale = string.gsub(column, "_", "-")
	local def = {
		type = "button",
		name = "inventory_" .. grid .. "_sort_" .. column,
		style = "cybersyn_sort_tool_button",
		tooltip = { "cybersyn-gui.inventory-sort-" .. locale .. "-tooltip" },
		tags = { grid = grid, column = column },
		handler = { [defines.events.on_gui_click] = inventory_tab.handle.on_grid_sort_click },
	}
	local sprite = SORT_SPRITE[column]
	if sprite then
		def.type = "sprite-button"
		def.sprite = sprite
	else
		def.caption = SORT_CAPTION[column] or column
	end
	return def
end

--- @param grid string
local function grid_def(grid)
	local locale = string.gsub(grid, "_", "-")
	local header = {
		type = "frame",
		name = "inventory_" .. grid .. "_header_frame",
		style = "cybersyn_inventory_grid_header",
		{
			type = "label",
			name = "inventory_" .. grid .. "_header",
			style = "subheader_caption_label",
			caption = { "cybersyn-gui." .. locale },
			tooltip = { "cybersyn-gui.inventory-" .. locale .. "-legend" },
		},
		{ type = "empty-widget", style = "flib_horizontal_pusher" },
	}
	if grid == "provided" then
		header[#header + 1] = {
			type = "sprite-button",
			name = "inventory_dim_button",
			style = "cybersyn_sort_tool_button",
			sprite = "virtual-signal/signal-ghost",
			tooltip = { "cybersyn-gui.inventory-dim-tooltip" },
			handler = { [defines.events.on_gui_click] = inventory_tab.handle.on_dim_click },
		}
	end
	for _, column in ipairs(GRID_SORTS[grid]) do
		header[#header + 1] = sort_button(grid, column)
	end
	return {
		type = "frame",
		name = "inventory_" .. grid .. "_frame",
		direction = "vertical",
		style = "cybersyn_inventory_grid_frame",
		header,
		{
			type = "scroll-pane",
			name = "inventory_" .. grid .. "_scroll",
			style = "ltnm_slot_table_scroll_pane",
			style_mods = { horizontally_stretchable = true },
			vertical_scroll_policy = "auto-and-reserve-space",
			{
				type = "table",
				name = grid_table_name(grid),
				style = "slot_table",
				column_count = 9,
			},
		},
	}
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
			-- Its height and the grids' slot rows come from the window layout (inventory_tab.apply_layout).
			style_mods = { vertical_spacing = 0 },
			{
				name = "inventory_empty_flow",
				type = "flow",
				style = "ltnm_warning_flow",
				visible = false,
				{
					name = "inventory_empty_label",
					type = "label",
					style = "ltnm_semibold_label",
				},
			},
			{
				name = "inventory_grids_flow",
				type = "flow",
				direction = "horizontal",
				style_mods = { horizontal_spacing = GRID_GAP, top_margin = GRID_GAP },
				grid_def("provided"),
				grid_def("in_transit"),
				grid_def("requested"),
			},
		},
	}
end

--- Grid width and slot columns for a tab content width: three grids share the width evenly, 12 px apart.
--- @param cw int
--- @return int width
--- @return int columns
local function grid_size(cw)
	local width = math.floor((cw - 2 * GRID_GAP) / 3)
	return width, math.max(4, math.floor((width - GRID_INNER) / SLOT_ROW))
end

--- Recreates a grid's table when its column count must change (column_count is fixed at creation).
--- @param player_data PlayerData
--- @param grid string
--- @param columns int
local function ensure_columns(player_data, grid, columns)
	local refs = player_data.refs
	local name = grid_table_name(grid)
	local tbl = refs[name]
	if not (tbl and tbl.valid) or tbl.column_count == columns then return end
	local pane = tbl.parent
	tbl.destroy()
	local _, new = gui.add(pane, { type = "table", name = name, style = "slot_table", column_count = columns })
	refs[name] = new
	local state = util.gui_state(player_data, name)
	state.keys, state.sigs, state.render_sig, state.dirty = nil, nil, nil, nil
end

--- Whole slot rows: each grid's scroll pane shows exactly the layout's row count; the grids share the width.
--- @param player_data PlayerData
--- @param layout ManagerLayout
function inventory_tab.apply_layout(player_data, layout)
	local rows = layout.rows_by_tab[TAB]
	local width, columns = grid_size(layout.content_width)
	for _, grid in ipairs(GRIDS) do
		local frame = player_data.refs["inventory_" .. grid .. "_frame"]
		if frame and frame.valid then frame.style.width = width end
		local pane = player_data.refs["inventory_" .. grid .. "_scroll"]
		if pane and pane.valid then pane.style.height = rows * SLOT_ROW end
		ensure_columns(player_data, grid, columns)
	end
end

--- Whole slot rows a grid shows, measured from the elements rather than taken from the layout: the space the tab
--- content leaves below the grid header (content height less the visible strips above the grids, the gap and the
--- grid header, each as its element's style says), against the pane's height. A pane taller than that space, or
--- not a whole number of rows, shows fewer.
--- @param player_data PlayerData
--- @return int
function inventory_tab.rendered_rows(player_data)
	local refs = player_data.refs
	local pane, content, grids = refs.inventory_provided_scroll, refs.manager_inventory_content_frame, refs.inventory_grids_flow
	if not (pane and pane.valid and content and content.valid and grids and grids.valid and grids.visible) then return 0 end
	local space = content.style.maximal_height or 0
	for _, child in ipairs(content.children) do
		if child.visible and child ~= grids then
			space = space - math.max(child.style.minimal_height or 0, 0)
		end
	end
	space = space - (grids.style.top_margin or 0)
	local frame = pane.parent
	local header = frame.children[1]
	space = space - math.max(header.style.minimal_height or 0, header.style.maximal_height or 0)
	-- The grid frame's border, top and bottom.
	space = space - 8
	local h = math.min(pane.style.maximal_height or 0, space)
	return math.floor(h / SLOT_ROW)
end

dev.register_rows(TAB, inventory_tab.rendered_rows)

--- Keeps the TOP_N largest entries in a flat {mag, id, name, mag, id, name, ...} list, ties broken by station id
--- so the list does not depend on station iteration order.
--- @param top table
--- @param mag number
--- @param id uint
--- @param name string
local function top_insert(top, mag, id, name)
	local n = #top / 3
	if n == TOP_N then
		local last_mag = top[TOP_N * 3 - 2]
		if mag < last_mag or (mag == last_mag and id > top[TOP_N * 3 - 1]) then return end
	end
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

--- The per-network sums the deficit is computed from: r = requested, t = incoming deliveries, s = provider stock
--- not yet promised (provider signals plus their negative, outgoing deliveries).
--- @param nets table
--- @param name string
local function net_bucket(nets, name)
	local nb = nets[name]
	if not nb then
		nb = { r = {}, t = {}, s = {} }
		nets[name] = nb
	end
	return nb
end

--- The networks a station's numbers count on: the filter's network, its own, or for a station on several networks
--- each of them for its stock (it can supply any) and the first by name for its requests (counted once).
--- @param nets table
--- @param st SnapshotStation
--- @param network string? the network filter
--- @return table request_bucket
--- @return table[]? stock_buckets nil = the request bucket alone
local function station_buckets(nets, st, network)
	if network then return net_bucket(nets, network), nil end
	local name = st.network_name
	if name ~= NETWORK_EACH or type(st.network_mask) ~= "table" then return net_bucket(nets, name or ""), nil end
	local names = {}
	for n in pairs(st.network_mask) do names[#names + 1] = n end
	if #names == 0 then return net_bucket(nets, ""), nil end
	table.sort(names)
	local stock = {}
	for i, n in ipairs(names) do stock[i] = net_bucket(nets, n) end
	return stock[1], stock
end

--- @param buckets table[]
--- @param hash string
--- @param count number
local function add_stock(buckets, hash, count)
	for _, nb in ipairs(buckets) do nb.s[hash] = (nb.s[hash] or 0) + count end
end

--- One pass over the snapshot producing the per-grid totals and each item's top stations together, so a
--- tooltip's top list always agrees with the totals shown next to it. The deficit per item is the sum over the
--- networks of what each is short (logic.deficit), so stock on one network never offsets a shortage on another.
--- @param snapshot Snapshot
--- @param f ManagerFilters
local function aggregate_with_top(snapshot, f)
	local filtered = util.filters_active(f, true)
	local inv = { provided = {}, requested = {}, in_transit = {} }
	local top = { provided = {}, requested = {}, in_transit = {} }
	local has_wait = false
	local nets = {}
	for _, st in pairs(snapshot.stations) do
		if not filtered or util.station_passes(st, f, true) then
			local nb, stock = station_buckets(nets, st, f.network)
			local r, t, s = nb.r, nb.t, nb.s
			for hash, count in pairs(st.provided) do
				accumulate(inv.provided, top.provided, hash, count, count, st)
				if stock then add_stock(stock, hash, count) else s[hash] = (s[hash] or 0) + count end
			end
			local wait = st.wait
			for hash, req in pairs(st.requested) do
				if req.active then
					local agg = accumulate(inv.requested, top.requested, hash, req.count, -req.count, st)
					r[hash] = (r[hash] or 0) - req.count
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
					t[hash] = (t[hash] or 0) + count
				elseif stock then
					add_stock(stock, hash, count)
				else
					s[hash] = (s[hash] or 0) + count
				end
			end
		end
	end
	local deficit = {}
	local short = logic.deficit
	for _, nb in pairs(nets) do
		local t, s = nb.t, nb.s
		for hash, requested in pairs(nb.r) do
			local d = short(requested, t[hash], s[hash])
			if d > 0 then deficit[hash] = (deficit[hash] or 0) + d end
		end
	end
	inv.deficit = deficit
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
--- @return table cache
--- @return boolean? rebuilt
local function get_cache(player_data, snapshot, f)
	local fkey = filter_signature(f)
	local cache = player_data.inventory_cache
	local same_filters = cache ~= nil and cache.fkey == fkey
	if same_filters and cache.tick == snapshot.tick and cache.started == snapshot.started_tick then
		return cache
	end
	local spread = (snapshot.station_count or 0) >= SPREAD_MIN_STATIONS
	-- The tick a pass completes already carries the collector's final step, so the new totals wait one render.
	if spread and same_filters and snapshot.tick == game.tick and not cache.deferred then
		cache.deferred = true
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
		-- Computed by unrequested_of on the first render that dims, not on every pass.
		unrequested = nil,
		order = {},
		version = version,
		-- A refresh nobody asked for, on a base big enough to be worth spreading over renders.
		background = spread and same_filters,
	}
	player_data.inventory_cache = cache
	return cache, true
end

--- Sort key for one item of a grid. `wait` only means something for requests once a requester has a tracked
--- start (has_wait); before that it falls back to item order.
--- @param column string
--- @param grid string
--- @param bucket table the grid's aggregate
--- @param has_wait boolean?
--- @return string column_used
--- @return fun(hash: string): number?
local function key_fn(column, grid, bucket, has_wait, inv)
	if column == "deficit" and grid == "requested" and inv then
		local deficit = inv.deficit or {}
		return column, function(hash) return deficit[hash] or 0 end
	elseif column == "amount" then
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
	local used, fn = key_fn(column, grid, bucket, cache.has_wait, cache.inv)
	if used ~= column then ascending = true end
	util.sort_by(list, fn, ascending, item_order_tiebreak)
	cache.order[order_key] = list
	return list
end

local CLICK_HINT = { "", "\n", { "cybersyn-gui.item-click-hint" } }
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
	header.caption = { "cybersyn-gui.inventory-grid-caption", { "cybersyn-gui." .. string.gsub(grid, "_", "-") }, format.number(n) }
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

--- Entries are plain data and the tooltip is only assembled for buttons that are built or whose sig changed:
--- after a pass that is a few hundred of the ~700 buttons, and before it none.
--- @param ctx table per-grid render context from build_entries
--- @param entry table
--- @return LocalisedString
local function entry_tooltip(ctx, entry)
	local hash, agg = entry.key, entry.agg
	local _, _, name_tooltip = util.item_sprite_and_tooltip(hash)
	local tail = { "", "\n", { ctx.stations_key, tostring(agg.stations) } }
	if ctx.is_requested then
		local start = agg.earliest_wait_start
		if start then
			tail = { "", tail, "\n[color=yellow]", { "cybersyn-gui.waiting-for", util.format_duration(ctx.now - start) }, "[/color]" }
		end
		local transit = entry.transit
		if transit then
			tail = { "", tail, "\n[color=orange]", { "cybersyn-gui.in-transit-amount", format.number(transit.count) }, "[/color]" }
		else
			tail = { "", tail, "\n[color=red]", { "cybersyn-gui.not-in-transit" }, "[/color]" }
		end
		if entry.starved then
			tail = { "", tail, "\n[color=red]", { "cybersyn-gui.inventory-starved" }, "[/color]" }
		end
	end
	if entry.dim then
		tail = { "", tail, "\n[color=0.6,0.6,0.6]", { "cybersyn-gui.inventory-unrequested" }, "[/color]" }
	end
	if ctx.is_requested and entry.deficit and entry.deficit > 0 then
		tail = { "", tail, "\n", { "cybersyn-gui.inventory-deficit", format.number(entry.deficit) } }
	end
	local item_top = ctx.top_bucket[hash]
	return {
		"", name_tooltip, tail,
		"\n", { "cybersyn-gui.amount", format.number(math.abs(agg.count)) },
		"\n", { "cybersyn-gui.inventory-delivered-hour", format.number(entry.delivered or 0) },
		item_top and top_tooltip(item_top) or "",
		CLICK_HINT,
	}
end

--- @param ctx table
--- @param entry table
--- @return flib.GuiElemDef
local function entry_build(ctx, entry)
	local hash, agg = entry.key, entry.agg
	local sprite, quality = util.item_sprite_and_tooltip(hash)
	return util.hoverable({
		type = "sprite-button",
		sprite = sprite,
		quality = quality,
		style = entry.style,
		elem_tooltip = util.elem_tooltip(hash),
		tags = { kind = "item", id = hash },
		mouse_button_filter = { "left", "right" },
		handler = { [defines.events.on_gui_click] = util.handle.link_click },
		tooltip = entry_tooltip(ctx, entry),
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
	}, ctx.scope)
end

--- @param ctx table
--- @param elem LuaGuiElement
--- @param entry table
local function entry_update(ctx, elem, entry)
	local agg = entry.agg
	local count_caption = format_signal_count(agg.count)
	local stations_caption = format_signal_count(agg.stations)
	local labels = elem.children
	if labels[1].caption ~= count_caption then labels[1].caption = count_caption end
	if labels[2].caption ~= stations_caption then labels[2].caption = stations_caption end
	elem.tooltip = entry_tooltip(ctx, entry)
	local style = entry.style
	if elem.style.name ~= style then elem.style = style end
end

local function run_update(ctx, entry, elem, sigs)
	local sig = entry.sig
	if sigs[entry.key] == sig then return end
	local budget = ctx.budget
	if budget then
		if budget.n <= 0 then
			ctx.deferred = true
			return
		end
		budget.n = budget.n - 1
	end
	sigs[entry.key] = sig
	entry_update(ctx, elem, entry)
end

--- @param parent LuaGuiElement
--- @param ctx table
--- @param entries table[]
--- @param keys string[]
--- @param state table
local function rebuild_all(parent, ctx, entries, keys, state)
	parent.clear()
	local sigs = {}
	state.sigs = sigs
	for i = 1, #entries do
		local entry = entries[i]
		gui.add(parent, entry_build(ctx, entry))
		sigs[entry.key] = entry.sig
	end
	state.keys = keys
	state.dirty = nil
	return "rebuilt"
end

--- util.sync_children with the same state contract, but a changed key sequence is reached by destroying the
--- vanished buttons, swapping the moved ones and inserting the new ones at their index. A completed pass usually
--- adds or drops a handful of items, and a sort change only permutes them, so this keeps hundreds of buttons (and
--- the player's scroll position) instead of recreating every button after the first difference.
--- @param parent LuaGuiElement
--- @param ctx table
--- @param entries table[]
--- @param state {keys: string[]?, sigs: table?, dirty: true?}
--- @param hold boolean
--- @return "updated"|"held"|"rebuilt"
local function reconcile(parent, ctx, entries, state, hold)
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

	if not old then
		return rebuild_all(parent, ctx, entries, keys, state)
	end

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
			run_update(ctx, entries[i], elems[i], sigs)
		end
		state.dirty = nil
		return "updated"
	end
	local index_of = {}
	for i = 1, n do
		index_of[keys[i]] = i
	end
	if hold then
		for j = 1, #old do
			local i = index_of[old[j]]
			if i then run_update(ctx, entries[i], elems[j], sigs) end
		end
		state.dirty = true
		return "held"
	end

	local cur = {}
	for j = 1, #old do
		cur[j] = old[j]
	end
	for j = #cur, 1, -1 do
		local key = cur[j]
		if not index_of[key] then
			elems[j].destroy()
			table.remove(cur, j)
			table.remove(elems, j)
			sigs[key] = nil
		end
	end
	-- Each insert renumbers every later button, so a mostly new set (clearing a narrow filter) is cheaper to
	-- recreate than to splice into a handful of survivors.
	if n - #cur > #cur then
		return rebuild_all(parent, ctx, entries, keys, state)
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
				local def = entry_build(ctx, entry)
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
		run_update(ctx, entry, elems[i], sigs)
	end
	state.keys = keys
	state.dirty = nil
	return "rebuilt"
end

--- @param player_data PlayerData
--- @param table_elem LuaGuiElement
--- @param state table from util.gui_state
--- @param ctx table
--- @param entries table[]
local function render_grid(player_data, grid, table_elem, state, ctx, entries)
	local result = reconcile(table_elem, ctx, entries, state, util.hold_active(player_data, table_elem.name))
	-- While held the grid still shows the old set, so a new count would contradict the buttons under the cursor.
	if result ~= "held" then update_header(player_data, grid, #entries) end
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

-- Sigs are numeric digests rather than strings: building ~700 strings per render, with every number converted
-- to text, cost more than the updates they saved. A collision only delays one button's refresh to its next change.
local DIGEST_MOD = 4294967296
local function mix(d, v)
	return (d * 1000003 + v) % DIGEST_MOD
end

--- Order-sensitive digest of a flat top-station list. Station renames alone do not change it; they show up with
--- the item's next count change.
--- @param d number
--- @param top table?
--- @return number
local function mix_top(d, top)
	if not top then return mix(d, 0) end
	for i = 1, #top / 3 do
		local b = i * 3
		d = mix(mix(d, top[b - 1]), top[b - 2] % DIGEST_MOD)
	end
	return d
end

local COLOR_CODE = { green = 1, blue = 2, red = 3, orange = 4, pink = 5, grey = 6 }

--- @param cache table from get_cache
--- @param grid string
--- @param scope string hover scope (the grid's table name)
--- @param snapshot Snapshot
--- @param f ManagerFilters
--- @param selected string? item filter hash, highlighted rather than hidden
--- @param budget {n: integer}? shared by the grids of one render; nil = unlimited
--- @return table ctx
--- @return table[] entries
--- The provided items nobody on the same network requests, for the cache's pass and filters; computed only while
--- Dim unrequested is on.
--- @param cache table
--- @param snapshot Snapshot
--- @param f ManagerFilters
--- @return {[string]: true}
local function unrequested_of(cache, snapshot, f)
	local set = cache.unrequested
	if set then return set end
	local profiler = dev.enabled() and game.create_profiler() or nil
	set = logic.unrequested(snapshot.provider_masks or {}, snapshot.request_keys or {}, f.network)
	if profiler then
		profiler.stop()
		inventory_tab.dim_profile = profiler
	end
	cache.unrequested = set
	return set
end

local function build_entries(cache, grid, scope, snapshot, f, column, ascending, selected, now, budget, delivered, dim)
	local inv = cache.inv
	local bucket = inv[grid]
	local top_bucket = cache.top[grid]
	local hashes = ordered_hashes(cache, grid, column, ascending)
	-- On a large base the filtered item is usually far down a grid, where its highlight would go unseen, so it
	-- leads every grid it is in. The cached order is shared, so this works on a copy.
	if selected and bucket[selected] then
		local pinned = { selected }
		for _, hash in ipairs(hashes) do
			if hash ~= selected then pinned[#pinned + 1] = hash end
		end
		hashes = pinned
	end
	local is_requested = grid == "requested"
	local base_color = grid == "provided" and "green" or "blue"
	local ctx = {
		scope = scope,
		is_requested = is_requested,
		stations_key = STATIONS_KEY[grid],
		top_bucket = top_bucket,
		now = now,
		budget = budget,
	}
	local in_transit = inv.in_transit
	local inv_deficit = inv.deficit or {}
	local unrequested = dim and grid == "provided" and unrequested_of(cache, snapshot, f) or nil
	local entries = {}
	for i, hash in ipairs(hashes) do
		local agg = bucket[hash]
		local color, sig_extra, transit, starved, deficit
		local is_dim = unrequested ~= nil and unrequested[hash] == true
		if is_requested then
			transit = in_transit[hash]
			starved = is_starved(snapshot, f, hash)
			color = starved and "pink" or transit and "orange" or "red"
			deficit = inv_deficit[hash] or 0
			local start = agg.earliest_wait_start
			sig_extra = mix(mix(start and math.floor((now - start) / WAIT_SIG_TICKS) + 1 or 0, transit and transit.count % DIGEST_MOD or -1), starved and 1 or 0)
			sig_extra = mix(sig_extra, deficit % DIGEST_MOD)
		elseif is_dim then
			color = "grey"
		else
			color = base_color
		end
		local sent = delivered and delivered[hash] or 0
		local is_selected = hash == selected
		local style = (is_selected and "flib_selected_slot_button_" or "flib_slot_button_") .. color
		-- Content-based rather than version-based, so a completed pass only touches the items whose numbers moved.
		local sig = mix(mix(mix(agg.count % DIGEST_MOD, agg.stations), COLOR_CODE[color] * 2 + (is_selected and 1 or 0)), sig_extra or 0)
		sig = mix(mix_top(sig, top_bucket[hash]), sent % DIGEST_MOD)
		entries[i] = { key = hash, sig = sig, agg = agg, style = style, transit = transit, starved = starved, dim = is_dim,
			deficit = deficit, delivered = sent }
	end
	return ctx, entries
end

--- Empty grids alone do not say whether nothing matches or nothing has been collected yet. The message replaces
--- the grids, centred like the empty state of the Stations and Trains tabs. It follows the aggregate the grids show,
--- which reaches a completed pass a render or two after the pass itself (get_cache spreads the refresh).
--- @param refs table<string, LuaGuiElement>
--- @param cache table from get_cache
local function render_empty_label(refs, cache, f)
	local label, flow, grids = refs.inventory_empty_label, refs.inventory_empty_flow, refs.inventory_grids_flow
	if not (label and label.valid and flow and flow.valid and grids and grids.valid) then return end
	local inv = cache.inv
	local key
	if not cache.tick then
		key = "cybersyn-gui.stations-collecting"
	elseif not (next(inv.provided) or next(inv.requested) or next(inv.in_transit)) then
		key = util.filters_active(f, true) and "cybersyn-gui.inventory-no-match" or "cybersyn-gui.inventory-empty"
	end
	local show = key ~= nil
	if flow.visible ~= show then flow.visible = show end
	if grids.visible == show then grids.visible = not show end
	if key and label.tags.key ~= key then
		label.caption = { key }
		label.tags = { key = key }
	end
end

--- A grid's sort: the column its own buttons chose, else the tab's sort.
--- @param player_data PlayerData
--- @param grid string
--- @return string column
--- @return boolean ascending
local function grid_sort(player_data, grid)
	local sorts = player_data.inventory_sorts
	local column = sorts and sorts[grid]
	if column and DEFAULT_ASCENDING[column] ~= nil then return column, DEFAULT_ASCENDING[column] end
	return util.get_sort(player_data, TAB, DEFAULT_SORT)
end

--- The toggled state of the grids' sort buttons and the dim button.
--- @param player_data PlayerData
--- @param columns {[string]: string}
local function sync_buttons(player_data, columns)
	local refs = player_data.refs
	local state = util.gui_state(player_data, "inventory_buttons")
	local dim = refs.inventory_dim_button
	local sig = (player_data.inventory_dim and "d" or "") .. "|" .. columns.provided .. "|" .. columns.in_transit .. "|"
		.. columns.requested .. "|" .. (dim and dim.valid and dim.index or "")
	if state.sig == sig then return end
	state.sig = sig
	for _, grid in ipairs(GRIDS) do
		for _, column in ipairs(GRID_SORTS[grid]) do
			local button = refs["inventory_" .. grid .. "_sort_" .. column]
			if button and button.valid then button.toggled = columns[grid] == column end
		end
	end
	if dim and dim.valid then dim.toggled = player_data.inventory_dim == true end
end

--- The item filter highlights instead of hiding; the other filters restrict which stations are aggregated.
---@param map_data MapData
---@param player_data PlayerData
function inventory_tab.build(map_data, player_data)
	local refs = player_data.refs
	local snapshot = collector.get()
	local f = util.get_filters(player_data)
	local layout = player_data.layout
	local heights = { TAB .. "_banner", TAB .. "_subheader" }
	for _, grid in ipairs(GRIDS) do heights[#heights + 1] = "inventory_" .. grid .. "_header_frame" end
	stations_tab.fix_heights(refs, heights)
	if layout then
		local _, columns = grid_size(layout.content_width)
		for _, grid in ipairs(GRIDS) do ensure_columns(player_data, grid, columns) end
	end
	local sorts = {}
	local used = {}
	for _, grid in ipairs(GRIDS) do
		local column, ascending = grid_sort(player_data, grid)
		sorts[grid] = { column, ascending }
		local supported = false
		for _, c in ipairs(GRID_SORTS[grid]) do
			if c == column then supported = true end
		end
		used[grid] = supported and column or DEFAULT_SORT
	end
	sync_buttons(player_data, used)
	local cache, rebuilt = get_cache(player_data, snapshot, f)
	-- A background refresh aggregates on one render and applies on the next, so neither carries both costs.
	if rebuilt and cache.background then return end
	render_empty_label(refs, cache, f)
	-- The grids are hidden until a completed pass is aggregated. Left alone meanwhile, the buttons from before the
	-- window was closed are mostly reused then instead of all being built again (~20 ms for 600 items).
	if not cache.tick then return end
	local version = cache.version
	local selected = f.item
	local now = game.tick
	local minute = math.floor(now / 3600)
	-- Only a refresh nobody asked for is spread out; a filter or sort change shows complete numbers at once.
	local budget = cache.background and { n = BACKGROUND_UPDATE_BUDGET } or nil
	local dim = player_data.inventory_dim == true
	local delivered

	for _, grid in ipairs(GRIDS) do
		local scope = grid_table_name(grid)
		local table_elem = refs[scope]
		if table_elem and table_elem.valid then
			local state = util.gui_state(player_data, scope)
			local column, ascending = sorts[grid][1], sorts[grid][2]
			-- Wait times in the requested tooltips age even when nothing else changes; delivered amounts once a minute.
			local wait_bucket = grid == "requested" and cache.has_wait and math.floor(now / WAIT_SIG_TICKS) or ""
			local render_sig = version .. "|" .. column .. "|" .. tostring(ascending) .. "|" .. (selected or "") .. "|"
				.. table_elem.index .. "|" .. wait_bucket .. "|" .. minute .. "|" .. (dim and grid == "provided" and "d" or "")
			if state.render_sig ~= render_sig or state.dirty or not state.keys then
				if not delivered then
					-- Once a minute, not on each of the renders a refresh is spread over.
					delivered = util.delivered_items(player_data, 60)
				end
				-- A refresh spread over renders builds its entries once and works through them on the next renders
				-- (rebuilding every entry on each of them put the renders after a pass at the 5 ms edge on pY).
				local pending = state.pending
				local ctx, entries
				if pending and pending.sig == render_sig and pending.version == version then
					ctx, entries = pending.ctx, pending.entries
					ctx.budget, ctx.deferred, ctx.now = budget and { n = BACKGROUND_UPDATE_BUDGET } or nil, nil, now
				else
					ctx, entries = build_entries(cache, grid, scope, snapshot, f, column, ascending, selected, now, budget,
						delivered, dim)
				end
				local result = render_grid(player_data, grid, table_elem, state, ctx, entries)
				state.render_sig = (result ~= "held" and not ctx.deferred) and render_sig or nil
				state.pending = ctx.deferred and { sig = render_sig, version = version, ctx = ctx, entries = entries } or nil
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
	local out = { column = column, ascending = ascending, version = cache and cache.version, dim = player_data.inventory_dim == true }
	local unrequested = {}
	for hash in pairs(cache and cache.unrequested or {}) do unrequested[#unrequested + 1] = hash end
	table.sort(unrequested)
	out.unrequested = unrequested
	for _, grid in ipairs(GRIDS) do
		local hashes, captions, keys, styles, ranks, tooltips = {}, {}, {}, {}, {}, {}
		local bucket = cache and cache.inv[grid] or {}
		local grid_column, grid_ascending0 = grid_sort(player_data, grid)
		local used, fn = key_fn(grid_column, grid, bucket, cache and cache.has_wait, cache and cache.inv)
		local stale = 0
		for i, button in ipairs(refs[grid_table_name(grid)].children) do
			local hash = button.tags.id
			hashes[i] = hash
			captions[i] = button.children[1].caption
			styles[i] = button.style.name
			tooltips[i] = button.tooltip
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
		local grid_ascending = grid_ascending0
		if used ~= grid_column then grid_ascending = true end
		out[grid] = {
			hashes = hashes,
			captions = captions,
			keys = keys,
			styles = styles,
			ranks = ranks,
			tooltips = tooltips,
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

--- A grid's sort button: selects that column for the grid; the active one again goes back to item order.
--- @param e EventData.on_gui_click
function inventory_tab.handle.on_grid_sort_click(player, player_data, refs, e)
	local tags = e.element.tags
	local grid, column = tags.grid, tags.column
	if not (grid and column) then return end
	inventory_tab.set_grid_sort(player_data, grid, column)
	util.rerender(player, player_data)
end

--- @param player_data PlayerData
--- @param grid string
--- @param column string
function inventory_tab.set_grid_sort(player_data, grid, column)
	local current = grid_sort(player_data, grid)
	if current == column then column = DEFAULT_SORT end
	local sorts = player_data.inventory_sorts or {}
	sorts[grid] = column
	player_data.inventory_sorts = sorts
end

--- @param e EventData.on_gui_click
function inventory_tab.handle.on_dim_click(player, player_data, refs, e)
	player_data.inventory_dim = not player_data.inventory_dim or nil
	util.rerender(player, player_data)
end

gui.add_handlers(inventory_tab.handle, inventory_tab.wrapper)

if dev.enabled() and not remote.interfaces["cybersyn-manager-dev-inventory"] then
	remote.add_interface("cybersyn-manager-dev-inventory", {
		--- Clicks a grid's sort button; returns the grid's column.
		set_grid_sort = function(pi, grid, column)
			local player = game.get_player(pi)
			local player_data = storage.manager.players[pi]
			inventory_tab.set_grid_sort(player_data, grid, column)
			util.rerender(player, player_data)
			return (grid_sort(player_data, grid))
		end,
		clear_grid_sorts = function(pi)
			local player_data = storage.manager.players[pi]
			player_data.inventory_sorts = nil
			util.rerender(game.get_player(pi), player_data)
		end,
		set_dim = function(pi, on)
			local player_data = storage.manager.players[pi]
			player_data.inventory_dim = on or nil
			util.rerender(game.get_player(pi), player_data)
		end,
		--- The last Dim unrequested computation, as a profiler.
		dim_profile = function()
			return { "", "unrequested ", inventory_tab.dim_profile or "none" }
		end,
		--- The tooltip figure "Delivered · last hour" of an item, from stats.aggregate.
		delivered = function(hash)
			return format.number(stats.aggregate(60).items[hash] or 0)
		end,
		unrequested = function(network)
			local snapshot = collector.get()
			local set = logic.unrequested(snapshot.provider_masks or {}, snapshot.request_keys or {}, network)
			local out = {}
			for hash in pairs(set) do out[#out + 1] = hash end
			table.sort(out)
			return out
		end,
	})
end

return inventory_tab
