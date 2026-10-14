local gui = require("__flib__.gui")
local format = require("__flib__.format")
local collector = require("scripts.gui.collector")

local util = {}

--- Create a flying text at the player's cursor with an error sound.
--- @param player LuaPlayer
--- @param message LocalisedString
function util.error_flying_text(player, message)
	player.create_local_flying_text({ create_at_cursor = true, text = message })
	player.play_sound({ path = "utility/cannot_build" })
end

function util.gui_list(parent, iterator, test, build, update, ...)
	local children = parent.children
	local i = 0

	for k, v in table.unpack(iterator) do
		local passed = test(v, k, i, ...)
		if passed then
			i = i + 1
			local child = children[i]
			if not child then
				gui.build(parent, { build(...) })
				child = parent.children[i]
			end
			gui.update(child, update(v, k, i, ...))
		end
	end

	for j = i + 1, #children do
		children[j].destroy()
	end
end

--- Builds a valid sprite path or returns nil
--- @param item string
--- @return string, string, LocalizedString
function util.generate_item_references(item)
	local sprite = nil
	local image_path = ""
	local item_name
	if helpers.is_valid_sprite_path("item/" .. item) then
		sprite = "item/" .. item
		image_path = "[img=item." .. item .. "]"
		item_name = { "?", { "item-name." .. item }, { "entity-name." .. item }, "LocalizedString failure: " .. item }
	elseif helpers.is_valid_sprite_path("fluid/" .. item) then
		sprite = "fluid/" .. item
		image_path = "[img=fluid." .. item .. "]"
		item_name = { "?", { "fluid-name." .. item }, "LocalizedString failure: " .. item }
	elseif helpers.is_valid_sprite_path("virtual-signal/" .. item) then
		sprite = "virtual-signal/" .. item
		image_path = "[img=virtual-signal." .. item .. "]"
		item_name = { "?", { "virtual-signal." .. item }, "LocalizedString failure: " .. item }
	end
	return sprite, image_path, item_name
end

--- Turns SignalID into a valid rich-text definition of the signal icon.
--- @param signal SignalID
--- @return string
function util.rich_text_from_signal(signal)
	local quality = signal.quality or ""
	local type = signal.type or "item" -- if type is nil, it is item
	if type == "virtual" then
		type = "virtual-signal" -- rich text needs 'virtual-signal'
	end
	return "[" .. type .. "=" .. signal.name .. ",quality=" .. quality .. "]"
end

--- Returns a prototype based on an item name.
---@param name string
---@return LuaPrototypeBase
function util.prototype_from_name(name)
	return prototypes.item[name] or
		   prototypes.fluid[name] or
		   prototypes.virtual_signal[name] or
		   prototypes.entity[name] or
		   prototypes.recipe[name] or
		   prototypes.space_location[name] or
		   prototypes.asteroid_chunk[name] or
		   prototypes.quality[name]
end

--- Creates a SignalID structure from an item name and optional quality.
---@param name string
---@param quality string?
---@return SignalID
function util.signalid_from_name(name, quality)
	---@type SignalIDType
	-- TODO is there a better way to get item type from name?
	local signal_type = prototypes.item[name] ~= nil and "item" or
			prototypes.fluid[name] ~= nil and "fluid" or
			prototypes.virtual_signal[name] ~= nil and "virtual" or
			prototypes.entity[name] ~= nil and "entity" or
			prototypes.recipe[name] ~= nil and "recipe" or
			prototypes.space_location[name] ~= nil and "space-location" or
			prototypes.asteroid_chunk[name] ~= nil and "asteroid-chunk" or
			"quality"
	return {
		type = signal_type,
		name = name,
		quality = quality,
	}
end

--- False when the signal behind a stored hash no longer exists (its mod was removed), since writing it into
--- a choose-elem-button raises an error.
--- @param hash string?
--- @return boolean
function util.signal_hash_valid(hash)
	if type(hash) ~= "string" then return false end
	local name, quality = unhash_signal(hash)
	if quality and not prototypes.quality[quality] then return false end
	return util.prototype_from_name(name) ~= nil
end

--- @param hash string
--- @return SignalID
function util.signalid_from_hash(hash)
	local name, quality = unhash_signal(hash)
	return util.signalid_from_name(name, quality)
end

--- Formats a tick count as "1h 2m 3s", "2m 3s" or "3s".
--- @param ticks number
--- @return string
function util.format_duration(ticks)
	local seconds = math.floor(math.max(ticks or 0, 0) / 60)
	local minutes = math.floor(seconds / 60)
	local hours = math.floor(minutes / 60)
	if hours > 0 then
		return string.format("%dh %dm %ds", hours, minutes % 60, seconds % 60)
	elseif minutes > 0 then
		return string.format("%dm %ds", minutes, seconds % 60)
	end
	return string.format("%ds", seconds)
end

--- @param tick number? A past game tick.
--- @return LocalisedString
function util.time_ago(tick)
	if not tick then return { "cybersyn-gui.never" } end
	return { "cybersyn-gui.time-ago", util.format_duration(game.tick - tick) }
end

-- Pure functions of the loaded prototypes, so caching them per Lua state cannot desync.
local rank_cache = {}
local sprite_cache = {}

--- Rank of an item in the crafting-menu order (group, subgroup, order), quality as a fraction.
--- Unknown items rank after every known one.
--- @param hash string
--- @return number
function util.item_rank(hash)
	local rank = rank_cache[hash]
	if rank then return rank end
	local name, quality = unhash_signal(hash)
	local order = storage.manager and storage.manager.item_order
	rank = order and order[name] or 1e9
	if quality then
		local proto = prototypes.quality[quality]
		rank = rank + ((proto and proto.level or 15) + 1) / 32
	end
	rank_cache[hash] = rank
	return rank
end

--- Sprite, quality and a rich-text name for an item/fluid hash, or nil when no sprite exists.
--- @param hash string
--- @return string? sprite
--- @return string? quality
--- @return LocalisedString? name_tooltip "[img] Localised name"
--- @return SignalID? signal
function util.item_sprite_and_tooltip(hash)
	local cached = sprite_cache[hash]
	if cached == nil then
		local name, quality = unhash_signal(hash)
		local signal = util.signalid_from_name(name, quality)
		local sprite = (signal.type == "fluid" and "fluid/" or signal.type == "virtual" and "virtual-signal/" or "item/") .. name
		if helpers.is_valid_sprite_path(sprite) then
			local proto = util.prototype_from_name(name)
			cached = {
				sprite = sprite,
				quality = quality,
				tooltip = { "", util.rich_text_from_signal(signal), " ", proto and proto.localised_name or name },
				signal = signal,
			}
		else
			cached = false
		end
		sprite_cache[hash] = cached
	end
	if not cached then return nil end
	return cached.sprite, cached.quality, cached.tooltip, cached.signal
end

--- Decorate-sort-undecorate. `key_fn` runs once per row; the comparator touches no API.
--- Keys must all be numbers or all strings; nil keys sort last in both directions.
--- Ties are broken by `tiebreak_fn(row)` ascending (must be unique and comparable), else by input position.
--- @param rows any[] Sorted in place and returned.
--- @param key_fn fun(row: any): (number|string|nil)
--- @param ascending boolean
--- @param tiebreak_fn (fun(row: any): (number|string))?
--- @return any[]
function util.sort_by(rows, key_fn, ascending, tiebreak_fn)
	local n = #rows
	local decorated = {}
	for i = 1, n do
		local row = rows[i]
		decorated[i] = { key_fn(row), tiebreak_fn and tiebreak_fn(row) or i, row }
	end
	table.sort(decorated, function(a, b)
		local ka, kb = a[1], b[1]
		if ka ~= kb then
			if ka == nil then return false end
			if kb == nil then return true end
			if ascending then return ka < kb end
			return ka > kb
		end
		return a[2] < b[2]
	end)
	for i = 1, n do
		rows[i] = decorated[i][3]
	end
	return rows
end

--- Per-player render state for a container, created on demand.
--- @param player_data PlayerData
--- @param name string
--- @return {keys: (string|number)[]?, dirty: true?}
function util.gui_state(player_data, name)
	local states = player_data.gui_state
	if not states then
		states = {}
		player_data.gui_state = states
	end
	local state = states[name]
	if not state then
		state = {}
		states[name] = state
	end
	return state
end

local function run_update(entry, elem, index, sigs)
	local update = entry.update
	if not update then return end
	local sig = entry.sig
	if sig ~= nil then
		if sigs[entry.key] == sig then return end
		sigs[entry.key] = sig
	end
	update(elem, entry, index)
end

--- Reconciles `parent`'s children with `entries`, an ordered array of
--- `{key=, build=fun(): GuiElemDef, update=fun(elem, entry, index)?, sig=string|number?}`.
--- Same key sequence: `update` each child in place. Otherwise, when `hold` is set, structure is left alone
--- (children whose key is still present get `update`d) and `state.dirty` is set; when not held, the common
--- prefix is updated in place, the rest destroyed and rebuilt.
--- `sig`, when given, is a cheap signature of everything `update` writes: an unchanged sig skips the update.
--- @param parent LuaGuiElement
--- @param entries {key: string|number, build: fun(): flib.GuiElemDef, update: fun(elem: LuaGuiElement, entry: table, index: integer)?, sig: (string|number)?}[]
--- @param state {keys: (string|number)[]?, sigs: {[string|number]: string|number}?, dirty: true?} from util.gui_state
--- @param hold boolean?
--- @return "updated"|"held"|"rebuilt"
function util.sync_children(parent, entries, state, hold)
	local n = #entries
	local keys = {}
	for i = 1, n do
		keys[i] = entries[i].key
	end
	local old = state.keys
	local children = parent.children
	if old and #old ~= #children then
		old = nil
	end
	local sigs = state.sigs
	if not old or not sigs then
		sigs = {}
		state.sigs = sigs
	end

	local prefix = 0
	if old then
		local m = math.min(#old, n)
		while prefix < m and old[prefix + 1] == keys[prefix + 1] do
			prefix = prefix + 1
		end
		if prefix == n and #old == n then
			for i = 1, n do
				run_update(entries[i], children[i], i, sigs)
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
				if i then
					run_update(entries[i], children[j], i, sigs)
				end
			end
			state.dirty = true
			return "held"
		end
	end

	for i = 1, prefix do
		run_update(entries[i], children[i], i, sigs)
	end
	if prefix == 0 then
		parent.clear()
	else
		for j = #children, prefix + 1, -1 do
			children[j].destroy()
		end
	end
	local new_sigs = {}
	for i = 1, prefix do
		local key = keys[i]
		new_sigs[key] = sigs[key]
	end
	for i = prefix + 1, n do
		local entry = entries[i]
		gui.add(parent, entry.build())
		if entry.sig ~= nil then new_sigs[entry.key] = entry.sig end
	end
	state.sigs = new_sigs
	state.keys = keys
	state.dirty = nil
	return "rebuilt"
end

util.HOVER_HOLD_TICKS = 600

util.handle = {}

--- @param e {player_index: uint}
function util.wrapper(e, handler)
	local player = game.get_player(e.player_index)
	if not player then return end
	local player_data = storage.manager.players[e.player_index]
	if not player_data then return end
	handler(player, player_data, player_data.refs, e)
end

--- @param player_data PlayerData
--- @param e EventData.on_gui_hover
function util.handle.hover_enter(player, player_data, refs, e)
	local elem = e.element
	if not elem or not elem.valid then return end
	local scope = elem.tags.hover_scope
	if not scope then
		local parent = elem.parent
		scope = parent and parent.name or nil
	end
	player_data.hover = { tick = game.tick, scope = scope, index = elem.index }
end

--- @param player_data PlayerData
--- @param e EventData.on_gui_leave
function util.handle.hover_leave(player, player_data, refs, e)
	local hover = player_data.hover
	-- A leave can arrive after the hover of the next element; only clear our own.
	if hover and e.element and e.element.valid and hover.index == e.element.index then
		player_data.hover = nil
	end
end

--- Merges the hover/leave handlers into an element's handler table.
--- A bare function handler would fire on hover events too, so a function is treated as on_gui_click.
--- @param handlers (function|table<defines.events, function>)?
--- @return table<defines.events, function>
function util.with_hover(handlers)
	local out = {}
	if type(handlers) == "function" then
		out[defines.events.on_gui_click] = handlers
	elseif handlers then
		for k, v in pairs(handlers) do
			out[k] = v
		end
	end
	out[defines.events.on_gui_hover] = util.handle.hover_enter
	out[defines.events.on_gui_leave] = util.handle.hover_leave
	return out
end

--- Makes an element definition hover-aware for `scope` (normally the name of the container passed to sync_children).
--- @param def flib.GuiElemDef Modified in place and returned.
--- @param scope string
--- @return flib.GuiElemDef
function util.hoverable(def, scope)
	def.raise_hover_events = true
	local tags = def.tags or {}
	tags.hover_scope = scope
	def.tags = tags
	def.handler = util.with_hover(def.handler)
	return def
end

--- True while the cursor is over an element of `scope`, with a timeout in case a leave event is lost.
--- @param player_data PlayerData
--- @param scope string
--- @return boolean
function util.hold_active(player_data, scope)
	local hover = player_data.hover
	return hover ~= nil and hover.scope == scope and game.tick - hover.tick < util.HOVER_HOLD_TICKS
end

--- A click proves the cursor is still on a hoverable element, so it restarts the hold timeout; repeated
--- shift-clicks on one slot would otherwise lose the hold after HOVER_HOLD_TICKS.
--- @param e EventData.on_gui_click
function util.touch_hover(e)
	local elem = e.element
	if not (elem and elem.valid) then return end
	local scope = elem.tags.hover_scope
	if not scope then return end
	local manager_data = storage.manager
	local player_data = manager_data and manager_data.players[e.player_index]
	if not player_data then return end
	local hover = player_data.hover
	if hover and hover.scope == scope and hover.index == elem.index then
		hover.tick = game.tick
	else
		player_data.hover = { tick = game.tick, scope = scope, index = elem.index }
	end
end

--- @param text string?
--- @return string[]?
function util.search_terms(text)
	if not text then return nil end
	local terms = {}
	for term in string.gmatch(string.lower(text), "%S+") do
		terms[#terms + 1] = term
	end
	if #terms == 0 then return nil end
	return terms
end

--- @param player_data PlayerData
--- @param text string?
function util.set_search_query(player_data, text)
	if text == "" then text = nil end
	player_data.search_query = text
	player_data.search_terms = util.search_terms(text)
end

--- @class ManagerFilters
--- @field terms string[]? lowercase, AND-ed plain substrings of the station name
--- @field item string? item hash
--- @field network string? network signal name
--- @field mask int -1 = any
--- @field surface uint? surface index

--- @param player_data PlayerData
--- @return ManagerFilters
function util.get_filters(player_data)
	local terms = player_data.search_terms
	if terms == nil and player_data.search_query then
		terms = util.search_terms(player_data.search_query)
		player_data.search_terms = terms
	end
	return {
		terms = terms,
		item = player_data.search_item,
		network = player_data.search_network_name,
		mask = player_data.search_network_mask or -1,
		surface = player_data.search_surface_idx,
	}
end

--- @param f ManagerFilters
--- @param ignore_item boolean?
--- @return boolean
function util.filters_active(f, ignore_item)
	return f.terms ~= nil or f.network ~= nil or f.mask ~= -1 or f.surface ~= nil or (not ignore_item and f.item ~= nil)
end

local btest = bit32.btest

--- @param network_name string?
--- @param network_mask int|{[string]: int}?
--- @param f ManagerFilters
--- @return boolean
function util.network_passes(network_name, network_mask, f)
	local want = f.network
	if want then
		if network_name == NETWORK_EACH then
			local mask = type(network_mask) == "table" and network_mask[want]
			return mask and btest(f.mask, mask) or false
		end
		if network_name ~= want then return false end
		return type(network_mask) == "number" and btest(f.mask, network_mask)
	elseif f.mask ~= -1 then
		if type(network_mask) == "table" then
			for _, mask in pairs(network_mask) do
				if btest(f.mask, mask) then return true end
			end
			return false
		end
		return type(network_mask) == "number" and btest(f.mask, network_mask)
	end
	return true
end

--- @param st SnapshotStation
--- @param f ManagerFilters
--- @param ignore_item boolean?
--- @return boolean
function util.station_passes(st, f, ignore_item)
	if f.surface and st.surface_index ~= f.surface then return false end
	local terms = f.terms
	if terms then
		local name = st.name_lower
		for i = 1, #terms do
			if not string.find(name, terms[i], 1, true) then return false end
		end
	end
	if not util.network_passes(st.network_name, st.network_mask, f) then return false end
	local item = f.item
	if item and not ignore_item then
		if not (st.provided[item] or st.requested[item] or st.deliveries[item]) then return false end
	end
	return true
end

--- Station-name terms are not applied to trains.
--- @param tr SnapshotTrain
--- @param f ManagerFilters
--- @param ignore_item boolean?
--- @return boolean
function util.train_passes(tr, f, ignore_item)
	if f.surface and tr.surface_index ~= f.surface then return false end
	if not util.network_passes(tr.network_name, tr.network_mask, f) then return false end
	if f.item and not ignore_item and not tr.manifest_hashes[f.item] then return false end
	return true
end

--- @param player_data PlayerData
--- @param tab string canonical tab name, e.g. "stations_tab"
--- @param default_column string
--- @return string column
--- @return boolean ascending
function util.get_sort(player_data, tab, default_column)
	local sorts = player_data.sort
	if not sorts then
		sorts = {}
		player_data.sort = sorts
	end
	local sort = sorts[tab]
	if not sort then
		sort = { column = default_column, ascending = true }
		sorts[tab] = sort
	end
	return sort.column, sort.ascending
end

--- First selection of a column sorts ascending; selecting the active column again flips it.
--- Passing `ascending` sets the direction explicitly.
--- @param player_data PlayerData
--- @param tab string
--- @param column string
--- @param ascending boolean?
function util.set_sort(player_data, tab, column, ascending)
	player_data.sort = player_data.sort or {}
	local sort = player_data.sort[tab]
	if ascending == nil then
		if sort and sort.column == column then
			ascending = not sort.ascending
		else
			ascending = true
		end
	end
	player_data.sort[tab] = { column = column, ascending = ascending }
	util.reset_page(player_data, tab)
end

--- @param player_data PlayerData
--- @return integer
function util.page_size(player_data)
	local size = player_data.page_size
	if not size then
		local setting = settings.get_player_settings(player_data.player_index)["cybersyn-manager-page-size"]
		size = setting and setting.value --[[@as integer]] or 50
		player_data.page_size = size
	end
	return size
end

--- @param player_data PlayerData
--- @param tab string
function util.reset_page(player_data, tab)
	if player_data.page then player_data.page[tab] = nil end
end

--- @param player_data PlayerData
function util.reset_pages(player_data)
	player_data.page = {}
end

--- Clamps the tab's page to `total`, refreshes the tab's pager widgets (if built with templates.pager) and
--- returns the 1-based inclusive slice to render. `last < first` when `total` is 0.
--- @param player_data PlayerData
--- @param tab string
--- @param total integer
--- @return integer first
--- @return integer last
--- @return integer page
--- @return integer pages
function util.paginate(player_data, tab, total)
	local size = util.page_size(player_data)
	local pages = math.max(1, math.ceil(total / size))
	player_data.page = player_data.page or {}
	local page = math.min(math.max(player_data.page[tab] or 1, 1), pages)
	player_data.page[tab] = page
	local first = (page - 1) * size + 1
	local last = math.min(total, page * size)

	local refs = player_data.refs
	local label = refs and refs[tab .. "_pager_label"]
	if label and label.valid then
		local caption
		if total == 0 then
			caption = { "cybersyn-gui.pager-empty" }
		else
			caption = { "cybersyn-gui.pager-range", format.number(first), format.number(last), format.number(total) }
		end
		label.caption = caption
		local back, forward = page > 1, page < pages
		refs[tab .. "_pager_first"].enabled = back
		refs[tab .. "_pager_prev"].enabled = back
		refs[tab .. "_pager_next"].enabled = forward
		refs[tab .. "_pager_last"].enabled = forward
	end
	return first, last, page, pages
end

--- @param e EventData.on_gui_click
function util.handle.pager_click(player, player_data, refs, e)
	local tags = e.element.tags
	local tab, action = tags.pager_tab, tags.pager_action
	if not tab then return end
	player_data.page = player_data.page or {}
	local page = player_data.page[tab] or 1
	if action == "first" then
		page = 1
	elseif action == "prev" then
		page = page - (e.shift and 10 or 1)
	elseif action == "next" then
		page = page + (e.shift and 10 or 1)
	elseif action == "last" then
		page = math.huge
	end
	player_data.page[tab] = math.max(1, page)
	util.rerender(player, player_data)
end

local rerender_fn

--- Lets manager.lua provide the immediate re-render without a require cycle.
--- @param fn fun(player: LuaPlayer, player_data: PlayerData)
function util.set_rerender(fn)
	rerender_fn = fn
end

--- Re-renders the selected tab now instead of waiting for the next manager update.
--- @param player LuaPlayer?
--- @param player_data PlayerData
function util.rerender(player, player_data)
	if rerender_fn then rerender_fn(player, player_data) end
end

--- Switches the tabbed pane and keeps `player_data.selected_tab` in sync (setting the index raises no event).
--- @param player_data PlayerData
--- @param tab string e.g. "stations_tab"
--- @return boolean found
function util.select_tab(player_data, tab)
	local pane = player_data.refs and player_data.refs.manager_tabbed_pane
	if not pane or not pane.valid then return false end
	for i, t in ipairs(pane.tabs) do
		if t.tab.name == "manager_" .. tab then
			pane.selected_tab_index = i
			player_data.selected_tab = tab
			return true
		end
	end
	return false
end

--- Applies an item filter (hash or nil) to player data and the toolbar chooser.
--- @param player_data PlayerData
--- @param hash string?
function util.set_item_filter(player_data, hash)
	if hash and not util.signal_hash_valid(hash) then hash = nil end
	player_data.search_item = hash
	local elem = player_data.refs and player_data.refs.manager_item_filter
	if elem and elem.valid then
		elem.elem_value = hash and util.signalid_from_hash(hash) or nil
	end
	util.reset_pages(player_data)
end

--- Standard click semantics for item buttons. Left: filter and go to Stations; shift+left: filter and stay;
--- right: clear the item filter.
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param e EventData.on_gui_click
--- @param hash string
function util.item_button_click(player, player_data, e, hash)
	if e.button == defines.mouse_button_type.right then
		util.set_item_filter(player_data, nil)
	elseif e.button == defines.mouse_button_type.left then
		util.set_item_filter(player_data, hash)
		local name = unhash_signal(hash)
		interface_raise_item_selected(player.index, name)
		interop_add_recent_item(player.index, name, "cybersyn")
		player_data.recent_panel_dirty = true
		if not e.shift then
			util.select_tab(player_data, "stations_tab")
		end
	else
		return
	end
	util.rerender(player, player_data)
end

--- Restyles a tab's sort header checkboxes to match the stored sort, since the header is built with a fixed
--- default column and the stored sort outlives window rebuilds.
--- @param toolbar LuaGuiElement? the frame holding the sort checkboxes
--- @param column string
--- @param ascending boolean
function util.sync_sort_header(toolbar, column, ascending)
	if not (toolbar and toolbar.valid) then return end
	for _, child in pairs(toolbar.children) do
		if child.type == "checkbox" then
			local tags = child.tags
			if tags.column then
				local active = tags.column == column
				local style = active and "ltnm_selected_sort_checkbox" or "ltnm_sort_checkbox"
				if child.style.name ~= style then
					child.style = style
					if tags.width then child.style.width = tags.width end
				end
				if active and child.state ~= not ascending then child.state = not ascending end
			end
		end
	end
end

--- @param hashes {[string]: any}
--- @return string[]
function util.hashes_in_item_order(hashes)
	local list = {}
	for hash in pairs(hashes) do
		list[#list + 1] = hash
	end
	return util.sort_by(list, util.item_rank, true, function(h) return h end)
end

--- Updates a slot table based on the passed criteria.
--- @param manifest Manifest?
--- @param color string
--- @return GuiElemDef[]
function util.slot_table_build_from_manifest(manifest, color)
	---@type GuiElemDef[]
	local children = {}
	if manifest then
		for _, item in pairs(manifest) do
			local item_prototype = util.prototype_from_name(item.name)
			local signal = util.signalid_from_name(item.name, item.quality)
			children[#children + 1] = {
				type = "choose-elem-button",
				elem_type = "signal",
				signal = signal,
				enabled = false,
				style = "ltnm_small_slot_button_" .. color,
				tooltip = {
					"",
					util.rich_text_from_signal(signal),
					" ", item_prototype.localised_name,
					" shipped",
					"\n Amount: " .. format.number(item.count),
				},
				children = {
					{
						type = "label",
						style = "ltnm_label_signal_count",
						ignored_by_interaction = true,
						caption = format_signal_count(item.count),
					},
				},
			}
		end
	end
	return children
end

local function slot_button(hash, count, color, tooltip_tail)
	local sprite, quality, name_tooltip = util.item_sprite_and_tooltip(hash)
	if not sprite then return nil end
	local tooltip = { "", name_tooltip }
	for _, part in ipairs(tooltip_tail) do
		tooltip[#tooltip + 1] = part
	end
	return {
		type = "sprite-button",
		sprite = sprite,
		quality = quality,
		enabled = false,
		style = "ltnm_small_slot_button_" .. color,
		tooltip = tooltip,
		tags = { item_hash = hash },
		children = {
			{
				type = "label",
				style = "ltnm_label_signal_count",
				ignored_by_interaction = true,
				caption = format_signal_count(count),
			},
		},
	}
end

--- Provided (green) and requested (red, orange below threshold) items of a snapshot station, in item order.
--- @param st SnapshotStation
--- @return GuiElemDef[]
function util.slot_table_build_from_station(st)
	local children = {}
	local now = game.tick
	for _, hash in ipairs(util.hashes_in_item_order(st.provided)) do
		children[#children + 1] = slot_button(hash, st.provided[hash], "green", {
			" ", { "cybersyn-gui.provided" },
			"\n", { "cybersyn-gui.amount", format.number(st.provided[hash]) },
		})
	end
	for _, hash in ipairs(util.hashes_in_item_order(st.requested)) do
		local req = st.requested[hash]
		local tail
		if req.active then
			tail = { " ", { "cybersyn-gui.requested" } }
			local start = st.wait[hash]
			if start then
				tail[#tail + 1] = "\n[color=yellow]"
				tail[#tail + 1] = { "cybersyn-gui.waiting-for", util.format_duration(now - start) }
				tail[#tail + 1] = "[/color]"
			end
		else
			tail = { " ", { "cybersyn-gui.requested-below-threshold" } }
		end
		tail[#tail + 1] = "\n"
		tail[#tail + 1] = { "cybersyn-gui.amount", format.number(req.count) }
		children[#children + 1] = slot_button(hash, req.count, req.active and "red" or "orange", tail)
	end
	return children
end

--- @param st SnapshotStation
--- @return GuiElemDef[]
function util.slot_table_build_from_deliveries(st)
	local children = {}
	for _, hash in ipairs(util.hashes_in_item_order(st.deliveries)) do
		local count = st.deliveries[hash]
		children[#children + 1] = slot_button(hash, count, count > 0 and "green" or "blue", {
			" ", count > 0 and { "cybersyn-gui.incoming" } or { "cybersyn-gui.outgoing" },
			"\n", { "cybersyn-gui.amount", format.number(count) },
		})
	end
	return children
end

--- Virtual control signals (station combinator) and per-item thresholds (control combinator).
--- @param st SnapshotStation
--- @return GuiElemDef[]
function util.slot_table_build_from_control_signals(st)
	local children = {}
	local names = {}
	for name in pairs(st.control) do
		names[#names + 1] = name
	end
	table.sort(names)
	for _, name in ipairs(names) do
		local count = st.control[name]
		local sprite = "virtual-signal/" .. name
		if helpers.is_valid_sprite_path(sprite) then
			local proto = prototypes.virtual_signal[name]
			children[#children + 1] = {
				type = "sprite-button",
				sprite = sprite,
				enabled = false,
				style = "ltnm_small_slot_button_default",
				tooltip = { "", "[virtual-signal=" .. name .. "] ", proto and proto.localised_name or name, "\n", { "cybersyn-gui.amount", format.number(count) } },
				children = {
					{ type = "label", style = "ltnm_label_signal_count", ignored_by_interaction = true, caption = format_signal_count(count) },
				},
			}
		end
	end
	for _, hash in ipairs(util.hashes_in_item_order(st.thresholds)) do
		children[#children + 1] = slot_button(hash, st.thresholds[hash], "default", {
			"\n", { "cybersyn-gui.request-threshold", format.number(st.thresholds[hash]) },
		})
	end
	return children
end

function util.sorted_iterator(arr, src_tbl, sort_state)
	local step = sort_state and 1 or -1
	local i = sort_state and 1 or #arr

	return function()
				local j = i + step
				if arr[j] then
					i = j
					local arr_value = arr[j]
					return arr_value, src_tbl[arr_value]
				end
			end,
			arr
end

local MAX_INT = 2147483648 -- math.pow(2, 31)
function util.signed_int32(val)
	return (val >= MAX_INT and val - (2 * MAX_INT)) or val
end

--- @param force boolean? Close even when pinned (close button, toggle shortcut).
function util.close_manager_window(player, player_data, refs, force)
	if player_data.pinning and not force then
		return
	end

	refs.manager_window.visible = false
	player_data.visible = false
	-- Cleared first: releasing player.opened re-enters the close path through on_gui_closed.
	player_data.is_manager_open = false
	player_data.hover = nil

	if player.opened == refs.manager_window then
		player.opened = nil
	end

	player.set_shortcut_toggled("cybersyn-toggle-gui", false)
	collector.release_if_unused()
end

function util.build_train_layout_table(map_data)
	local layouts = map_data.layouts
	local layouts_table = {}
	for i, v in pairs(layouts) do
		local layout_string = table.concat(v, ",")
		layout_string = layout_string.gsub(layout_string, "0", "[item=locomotive]")
		layout_string = layout_string.gsub(layout_string, "1", "[item=cargo-wagon]")
		layout_string = layout_string.gsub(layout_string, "2", "[item=fluid-wagon]")
		layout_string = layout_string.gsub(layout_string, ",", "")
		layouts_table[i] = layout_string
	end
	return layouts_table
end

gui.add_handlers(util.handle, util.wrapper, "cybersyn_util")

return util
