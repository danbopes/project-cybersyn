local gui = require("__flib__.gui")
local format = require("__flib__.format")
local flib_train = require("__flib__.train")
local collector = require("scripts.gui.collector")
local stats = require("scripts.stats")
local lint = require("scripts.lint")
local diag = require("scripts.diag")
local logic = require("scripts.gui.tab-logic")
local pm = require("scripts.gui.problems-model")

local util = {}

--- Create a flying text at the player's cursor with an error sound.
--- @param player LuaPlayer
--- @param message LocalisedString
function util.error_flying_text(player, message)
	player.create_local_flying_text({ create_at_cursor = true, text = message })
	player.play_sound({ path = "utility/cannot_build" })
end

--- A station's network as a caption: the signal's icon, "Each" for the each-network, "?" without one. Explain and
--- the item drill-down both go through here so they name a network the same way.
--- @param network_name string?
--- @return LocalisedString
function util.network_caption(network_name)
	if network_name == NETWORK_EACH then return { "cybersyn-gui.network-each" } end
	return network_icon(network_name)
end

--- @param index uint
--- @return string
function util.surface_name(index)
	local s = game.get_surface(index)
	return s and s.name or tostring(index)
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
		local proto = prototypes.item[item]
		item_name = proto and proto.localised_name or item
	elseif helpers.is_valid_sprite_path("fluid/" .. item) then
		sprite = "fluid/" .. item
		image_path = "[img=fluid." .. item .. "]"
		local proto = prototypes.fluid[item]
		item_name = proto and proto.localised_name or item
	elseif helpers.is_valid_sprite_path("virtual-signal/" .. item) then
		sprite = "virtual-signal/" .. item
		image_path = "[img=virtual-signal." .. item .. "]"
		local proto = prototypes.virtual_signal[item]
		item_name = proto and proto.localised_name or item
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

--- Two units at most ("42s", "3m 05s", "1h 05m", "2d 03h"), so one duration reads the same in every tab;
--- util.format_duration has the full precision for tooltips.
util.short_duration = logic.short_duration
util.format_duration = logic.format_duration

-- Pure functions of the loaded prototypes, so caching them per Lua state cannot desync.
local rank_cache = {}
local sprite_cache = {}
local sprite_valid = {}
local network_sprites = {}

--- The sprite of a network signal (item, fluid or virtual signal), nil when none can be drawn. Memoised: each lookup
--- is up to three is_valid_sprite_path calls, and the tabs ask for every row.
--- @param name string
--- @return string?
function util.network_sprite(name)
	local sprite = network_sprites[name]
	if sprite == nil then
		sprite = util.generate_item_references(name) or false
		network_sprites[name] = sprite
	end
	return sprite or nil
end

--- `path` when the loaded prototypes can draw it, else `fallback` (nil allowed). Memoised: tabs ask on every row
--- of every update.
--- @param path string?
--- @param fallback string?
--- @return string?
function util.valid_sprite(path, fallback)
	if not path then return fallback end
	local ok = sprite_valid[path]
	if ok == nil then
		ok = helpers.is_valid_sprite_path(path)
		sprite_valid[path] = ok
	end
	if ok then return path end
	return fallback
end

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
		-- A quality removed by a mod change still lingers in persisted hashes, and gui.add throws on it.
		if helpers.is_valid_sprite_path(sprite) and not (quality and not prototypes.quality[quality]) then
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
--- Ties are broken by `tiebreak_fn(row)` ascending, then by `tiebreak2_fn(row)` ascending (together they must be unique
--- and comparable), else by input position.
--- @param rows any[] Sorted in place and returned.
--- @param key_fn fun(row: any): (number|string|nil)
--- @param ascending boolean
--- @param tiebreak_fn (fun(row: any): (number|string))?
--- @param tiebreak2_fn (fun(row: any): (number|string))?
--- @return any[]
function util.sort_by(rows, key_fn, ascending, tiebreak_fn, tiebreak2_fn)
	local n = #rows
	local decorated = {}
	for i = 1, n do
		local row = rows[i]
		decorated[i] = { key_fn(row), tiebreak_fn and tiebreak_fn(row) or i, tiebreak2_fn and tiebreak2_fn(row) or i, row }
	end
	table.sort(decorated, function(a, b)
		local ka, kb = a[1], b[1]
		if ka ~= kb then
			if ka == nil then return false end
			if kb == nil then return true end
			if ascending then return ka < kb end
			return ka > kb
		end
		local ta, tb = a[2], b[2]
		if ta ~= tb then return ta < tb end
		return a[3] < b[3]
	end)
	for i = 1, n do
		rows[i] = decorated[i][4]
	end
	return rows
end

--- Writes caption (and tooltip, when given) only when `sig` changed since the last write. LocalisedString captions
--- cannot be compared with the element's, so the last plain-string signature is kept in `cache`, keyed by the
--- element's name: two elements of one name must not share a cache, or one of them stops updating.
--- @param cache table
--- @param elem LuaGuiElement?
--- @param sig string
--- @param caption LocalisedString
--- @param tooltip LocalisedString?
function util.set_if_changed(cache, elem, sig, caption, tooltip)
	if not (elem and elem.valid) then return end
	local key = elem.name
	if cache[key] == sig then return end
	cache[key] = sig
	elem.caption = caption
	if tooltip ~= nil then elem.tooltip = tooltip end
end

--- Per-player render state for a container, created on demand.
--- @param player_data PlayerData
--- @param name string
--- @return {keys: (string|number)[]?, dirty: true?}
function util.gui_state(player_data, name)
	return get_or_create(get_or_create(player_data, "gui_state"), name)
end

--- @class SyncOptions
--- @field build fun(entry: table): flib.GuiElemDef? for entries without their own `build`
--- @field update fun(elem: LuaGuiElement, entry: table, index: integer)? for entries without their own `update`
--- @field reuse fun(elem: LuaGuiElement, old_key: any, entry: table)? for entries without their own `reuse`
--- @field add fun(parent: LuaGuiElement, index: integer?, entry: table): LuaGuiElement? creates the child itself instead
--- of `build` (index nil = append)
--- @field after fun(elem: LuaGuiElement, entry: table, index: integer, fresh: boolean)? runs for every placed child,
--- `fresh` when it was built or reused in this call
--- @field gone fun(key: any)? runs for every key whose child is destroyed
--- @field elems boolean? the children live in `state.elems` instead of being read from `parent.children` (which makes a
--- wrapper per child on every call)
--- @field budget {n: integer}? updates this call may run; a skipped one keeps its old sig and sets `deferred`
--- @field build_budget integer? children this call may build; the entries after the first one over it wait for the
--- next call
--- @field destroy_vanished boolean? destroy children whose key vanished first instead of offering them for reuse
--- @field rebuild_mostly_new boolean? clear and rebuild when more keys are new than survive: each insert renumbers
--- every later child, so splicing a mostly new set into a few survivors costs more than recreating it
--- @field moved_keeps_sig boolean? a moved child's update does not depend on its index, so moving it writes nothing
--- @field deferred true? set by the call when `budget` ran out

local function run_update(entry, elem, index, sigs, opts)
	local update = entry.update or (opts and opts.update)
	if not update then return end
	local sig = entry.sig
	if sig ~= nil then
		if sigs[entry.key] == sig then return end
		local budget = opts and opts.budget
		if budget then
			if budget.n <= 0 then
				opts.deferred = true
				return
			end
			budget.n = budget.n - 1
		end
		sigs[entry.key] = sig
	end
	update(elem, entry, index)
end

--- A re-sort mostly permutes the same rows, and rebuilding a heavy row costs far more than moving it: survivors are
--- swapped into place, a child whose key vanished is handed to a new key through `reuse(elem, old_key, entry)` when
--- there is one (then updated like a survivor), and only the remaining new keys are built, at their index.
local function sync_moved(parent, entries, keys, old, elems, state, sigs, opts)
	local n = #entries
	local build_fn = opts and opts.build
	local reuse_fn = opts and opts.reuse
	local add = opts and opts.add
	local after = opts and opts.after
	local gone = opts and opts.gone
	local build_left = opts and opts.build_budget
	local keep_sig = opts and opts.moved_keeps_sig
	local wanted = {}
	for i = 1, n do
		wanted[keys[i]] = true
	end
	local cur, pos_of, old_index = {}, {}, {}
	local free = {}
	if opts and opts.destroy_vanished then
		local m = 0
		for j = 1, #old do
			local key, elem = old[j], elems[j]
			if wanted[key] then
				m = m + 1
				cur[m] = key
				elems[m] = elem
			else
				elem.destroy()
				sigs[key] = nil
				if gone then gone(key) end
			end
		end
		for j = #elems, m + 1, -1 do
			elems[j] = nil
		end
		if opts.rebuild_mostly_new and n - m > m then
			parent.clear()
			if gone then
				for j = 1, m do gone(cur[j]) end
			end
			cur = {}
			for j = m, 1, -1 do
				elems[j] = nil
			end
			sigs = {}
		end
	else
		for j = 1, #old do
			cur[j] = old[j]
		end
	end
	for j = 1, #cur do
		local key = cur[j]
		pos_of[key] = j
		old_index[key] = j
		if not wanted[key] then free[#free + 1] = key end
	end
	-- Positions before i are final, so every unclaimed child sits at i or later.
	local function swap(i, j)
		parent.swap_children(i, j)
		cur[i], cur[j] = cur[j], cur[i]
		elems[i], elems[j] = elems[j], elems[i]
		pos_of[cur[i]] = i
		pos_of[cur[j]] = j
	end
	local i = 1
	while i <= n do
		local key = keys[i]
		local entry = entries[i]
		local fresh = false
		local reuse = entry.reuse or reuse_fn
		if cur[i] == key then
			-- A child that moved must learn its new index even when its data did not change.
			if not keep_sig and old_index[key] ~= i then sigs[key] = nil end
			run_update(entry, elems[i], i, sigs, opts)
		elseif pos_of[key] then
			swap(i, pos_of[key])
			if not keep_sig then sigs[key] = nil end
			run_update(entry, elems[i], i, sigs, opts)
		elseif reuse and #free > 0 then
			-- The lowest free child, so the children above the change are not moved.
			local old_key = table.remove(free)
			local j = pos_of[old_key]
			if j ~= i then swap(i, j) end
			pos_of[old_key] = nil
			sigs[old_key] = nil
			cur[i] = key
			pos_of[key] = i
			reuse(elems[i], old_key, entry)
			sigs[key] = nil
			run_update(entry, elems[i], i, sigs, opts)
			fresh = true
		else
			if build_left then
				if build_left <= 0 then break end
				build_left = build_left - 1
			end
			local elem
			if add then
				elem = add(parent, i <= #cur and i or nil, entry)
			else
				local def = (entry.build or build_fn)(entry)
				def.index = i <= #cur and i or nil
				local _, added = gui.add(parent, def)
				elem = added
				if entry.built then entry.built(elem, entry) end
			end
			table.insert(cur, i, key)
			table.insert(elems, i, elem)
			for m = i, #cur do
				pos_of[cur[m]] = m
			end
			sigs[key] = entry.sig
			fresh = true
		end
		if after then after(elems[i], entry, i, fresh) end
		i = i + 1
	end
	for j = #cur, i, -1 do
		elems[j].destroy()
		sigs[cur[j]] = nil
		if gone then gone(cur[j]) end
		cur[j] = nil
		elems[j] = nil
	end
	state.sigs = sigs
	state.keys = cur
	if opts and opts.elems then state.elems = elems end
	state.dirty = nil
	return "rebuilt"
end

--- Invariants: keys are unique within one call; with `movable`, `update` applies everything that depends on the
--- child's index unless `moved_keeps_sig` is set; a budget defers work only by keeping the old sig and setting
--- `deferred`, so the next call picks it up. Tests: the "sync_children" ones in
--- tests/unit/util_test.lua.
--- Reconciles `parent`'s children with `entries`, an ordered array of
--- `{key=, build=fun(entry): GuiElemDef, update=fun(elem, entry, index)?, sig=string|number?}` (build, built and reuse
--- also get the entry, so one function can serve every row).
--- Same key sequence: `update` each child in place. Otherwise, when `hold` is set, structure is left alone
--- (children whose key is still present get `update`d) and `state.dirty` is set; when not held, the common
--- prefix is updated in place, the rest destroyed and rebuilt.
--- `sig`, when given, is a cheap signature of everything `update` writes: an unchanged sig skips the update.
--- `built(elem)`, when given, receives each child right after `build` created it.
--- @param parent LuaGuiElement
--- @param entries {key: string|number, build: fun(): flib.GuiElemDef, update: fun(elem: LuaGuiElement, entry: table, index: integer)?, sig: (string|number)?}[]
--- @param state {keys: (string|number)[]?, sigs: {[string|number]: string|number}?, dirty: true?, elems: LuaGuiElement[]?} from util.gui_state
--- @param hold boolean?
--- @param movable (boolean|SyncOptions)? keep children whose key survives and move them into place instead of
--- rebuilding from the first difference; `update` then also runs for a moved or reused child and must apply anything
--- that depends on its index (see sync_moved). A table is movable with options.
--- @return "updated"|"held"|"rebuilt"
function util.sync_children(parent, entries, state, hold, movable)
	local opts = type(movable) == "table" and movable or nil
	local n = #entries
	local keys = {}
	for i = 1, n do
		keys[i] = entries[i].key
	end
	local old = state.keys
	local children
	if opts and opts.elems then
		children = state.elems
		if not (old and children and #old == #children and (not children[1] or children[1].valid)) then
			old = nil
		end
	else
		children = parent.children
		if old and #old ~= #children then
			old = nil
		end
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
			local after = opts and opts.after
			for i = 1, n do
				run_update(entries[i], children[i], i, sigs, opts)
				if after then after(children[i], entries[i], i, false) end
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
					run_update(entries[i], children[j], i, sigs, opts)
				end
			end
			state.dirty = true
			return "held"
		end
	end

	if opts then
		if not old then
			parent.clear()
			return sync_moved(parent, entries, keys, {}, {}, state, sigs, opts)
		end
		return sync_moved(parent, entries, keys, old, children, state, sigs, opts)
	end
	if movable and old then
		return sync_moved(parent, entries, keys, old, children, state, sigs)
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
		local _, elem = gui.add(parent, entry.build(entry))
		if entry.built then entry.built(elem, entry) end
		if entry.sig ~= nil then new_sigs[entry.key] = entry.sig end
	end
	state.sigs = new_sigs
	state.keys = keys
	state.dirty = nil
	return "rebuilt"
end

util.HOVER_HOLD_TICKS = 600

util.handle = {}

--- A Cybersyn stop by unit number: station first, then depot, then refueler, nil when its stop entity is gone.
--- @param id uint
--- @return LuaEntity? stop
--- @return (Station|Depot|Refueler)? record
--- @return "station"|"depot"|"refueler"|nil kind
function util.stop_record(id)
	local record, kind = storage.stations[id], "station"
	if not record then record, kind = storage.depots[id], "depot" end
	if not record then record, kind = storage.refuelers[id], "refueler" end
	local stop = record and record.entity_stop
	if stop and stop.valid then return stop, record, kind end
	return nil, nil, nil
end

--- @param e {player_index: uint}
function util.wrapper(e, handler)
	local player = game.get_player(e.player_index)
	if not player then return end
	local player_data = storage.manager.players[e.player_index]
	if not player_data then return end
	handler(player, player_data, player_data.refs, e)
end

--- The three-argument form for panels that live outside the manager window, so they can fire before
--- `storage.manager` exists.
--- @param e {player_index: uint}
function util.wrapper_pd(e, handler)
	local player = game.get_player(e.player_index)
	local pd = storage.manager and storage.manager.players[e.player_index]
	if not (player and pd) then return end
	handler(player, pd, e)
end

--- @param player_data PlayerData
--- @param e EventData.on_gui_hover
function util.handle.hover_enter(player, player_data, refs, e)
	local elem = e.element
	if not elem or not elem.valid then return end
	player_data.hover = { tick = game.tick, scope = elem.tags.hover_scope, index = elem.index }
	-- A pointer that arrives after a row-changing click in the same tick holds the rows it now rests on.
	player_data.hold_released_tick = nil
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

--- True while the cursor is over an element of `scope`. The API cannot report the cursor position, so three patches
--- keep the recorded hover honest: HOVER_HOLD_TICKS ends a hold whose leave never arrives (a destroyed or rebuilt element
--- raises no on_gui_leave); release_hold lifts it for the rest of the tick of a row-changing click, until the next
--- hover_enter; touch_hover restarts the timeout on clicks, so repeated clicks on one element keep the hold.
--- @param player_data PlayerData
--- @param scope string
--- @return boolean
function util.hold_active(player_data, scope)
	local hover = player_data.hover
	return hover ~= nil and hover.scope == scope and game.tick - hover.tick < util.HOVER_HOLD_TICKS
		and player_data.hold_released_tick ~= game.tick
end

--- @class PlayerData
--- @field hold_released_tick uint? the tick in which a row-changing click lifted the hover hold (util.release_hold)

--- A click whose purpose is to change the rows (an acknowledgement, a show/hide toggle) renders them in its own event.
--- The hover stays recorded: the pointer is still on the table, so the hold protects the rows that slid under it from
--- the next tick on.
--- @param player_data PlayerData
function util.release_hold(player_data)
	player_data.hold_released_tick = game.tick
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

-- Players whose player.opened the mod itself is moving (util.switch_opened). Not saved: the engine raises the
-- on_gui_closed and on_gui_opened of such a move inside the assignment, so the flag never outlives one call.
local switching = {}

--- Runs `move`, which changes what player.opened is (a link opening an entity, the action dialog, show on map), so
--- that the manager's on_gui_closed and on_gui_opened handlers know the switch is the mod's and not the player's.
--- Desync-safe: the flag is set and cleared within one call on every peer. Only the mod's own moves that the close and
--- open handlers must ignore go through here; those handlers' own re-takes of player.opened stay outside it.
--- @param player LuaPlayer
--- @param move fun()
function util.switch_opened(player, move)
	switching[player.index] = true
	move()
	switching[player.index] = nil
end

--- @param player_index uint
--- @return boolean
function util.switching(player_index)
	return switching[player_index] == true
end

--- Whitespace-separated terms of a station-name query. Terms are matched as plain substrings (string.find with
--- plain = true), never as Lua patterns, so "[", "%" or "-" in a query match themselves. The query is lowercased the
--- way station names are (helpers.multilingual_to_lower), which leaves rich-text tags as they are, so a query that
--- contains an icon tag matches the names that show that icon.
--- @param text string?
--- @return string[]?
function util.search_terms(text)
	if not text then return nil end
	local terms = {}
	for term in string.gmatch(helpers.multilingual_to_lower(text), "%S+") do
		terms[#terms + 1] = term
	end
	if #terms == 0 then return nil end
	return terms
end

--- A sort key that orders the digit runs of a string by their value ("stn-2" before "stn-10"): each run becomes its
--- length in two digits followed by the digits without leading zeros.
--- @param s string
--- @return string
function util.natural_key(s)
	return (string.gsub(s, "%d+", function(d)
		d = string.gsub(d, "^0+", "")
		if d == "" then d = "0" end
		return string.format("%02d", #d) .. d
	end))
end

--- True when every term occurs in `name_lower` (already normalised).
--- @param name_lower string
--- @param terms string[]
--- @return boolean
function util.terms_match(name_lower, terms)
	for i = 1, #terms do
		if not string.find(name_lower, terms[i], 1, true) then return false end
	end
	return true
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
--- @field station uint? station id (the station chip): only that station's rows pass

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
		station = player_data.search_station,
	}
end

--- @param f ManagerFilters
--- @param ignore_item boolean?
--- @return boolean
function util.filters_active(f, ignore_item)
	return f.terms ~= nil or f.network ~= nil or f.mask ~= -1 or f.surface ~= nil or f.station ~= nil
		or (not ignore_item and f.item ~= nil)
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

--- The row's own part of row_passes: its network and its item.
--- @param row SnapshotInventory
--- @param f ManagerFilters
--- @param ignore_item boolean?
--- @return boolean
local function row_own_passes(row, f, ignore_item)
	if not util.network_passes(row.network_name, row.networks or row.mask, f) then return false end
	local item = f.item
	if item and not ignore_item then
		-- Deliveries belong to the station; they show on its first row.
		if not (row.provided[item] or row.requested[item] or (row.index == 0 and row.st.deliveries[item])) then
			return false
		end
	end
	return true
end

--- Whether one inventory row (collector.inventories) passes the filters: its station's surface, name terms and the
--- station chip, then the row's own network, mask and item.
--- @param row SnapshotInventory
--- @param f ManagerFilters
--- @param ignore_item boolean?
--- @return boolean
function util.row_passes(row, f, ignore_item)
	local st = row.st
	if f.station and st.id ~= f.station then return false end
	if f.surface and st.surface_index ~= f.surface then return false end
	local terms = f.terms
	if terms and not util.terms_match(st.name_lower, terms) then return false end
	return row_own_passes(row, f, ignore_item)
end

--- A station passes when any of its rows does. A record without rows (hand-built) is one row on its own lists.
--- @param st SnapshotStation
--- @param f ManagerFilters
--- @param ignore_item boolean?
--- @return boolean
function util.station_passes(st, f, ignore_item)
	if f.station and st.id ~= f.station then return false end
	if f.surface and st.surface_index ~= f.surface then return false end
	local terms = f.terms
	if terms and not util.terms_match(st.name_lower, terms) then return false end
	local rows = st.rows
	if rows == nil then
		if not util.network_passes(st.network_name, st.network_mask, f) then return false end
		local item = f.item
		if item and not ignore_item then
			if not (st.provided[item] or st.requested[item] or st.deliveries[item]) then return false end
		end
		return true
	end
	for i = 1, #rows do
		if row_own_passes(rows[i], f, ignore_item) then return true end
	end
	return false
end

--- The filters the Overview applies: network name, network ID, surface and item. It has no station search,
--- so the terms are left out: a query typed on another tab would otherwise filter it invisibly.
--- @param player_data PlayerData
--- @return ManagerFilters
function util.overview_filters(player_data)
	local f = util.get_filters(player_data)
	f.terms = nil
	-- The Overview ignores the station chip (its tooltip says so there).
	f.station = nil
	if f.item and not util.signal_hash_valid(f.item) then f.item = nil end
	return f
end

--- A plain string of every filter field, for caches keyed on the filters.
--- @param f ManagerFilters
--- @return string
function util.filter_signature(f)
	return table.concat({
		f.terms and table.concat(f.terms, " ") or "", f.item or "", f.network or "", f.mask, f.surface or "",
		f.station or "",
	}, "\1")
end

--- Whether network name, network ID or surface is set: the filters that decide by a station's place, not its items.
--- @param f ManagerFilters
--- @return boolean
function util.place_filters_active(f)
	return f.network ~= nil or f.mask ~= -1 or f.surface ~= nil
end

--- The locale-key suffix of the drill-down's empty texts: with a place filter or the station chip set, "No
--- station provides this item" would deny stations the filters merely hide, so the text names the filters.
--- Used as {"cybersyn-gui.item-empty-<table>" .. util.empty_filter_suffix(f)}.
--- @param f ManagerFilters
--- @return string
function util.empty_filter_suffix(f)
	if f.station ~= nil or util.place_filters_active(f) then return "-filtered" end
	return ""
end

--- Whether requester `r_id` of an Unserved entry passes the network name, network ID and surface filters: read
--- from its snapshot record, or from the live station while the first pass is still collecting. A requester that is
--- gone passes only while none of those filters is set.
--- @param r_id uint
--- @param stations {[uint]: SnapshotStation}
--- @param f ManagerFilters
--- @return boolean
function util.requester_passes(r_id, stations, f)
	if not util.place_filters_active(f) then return true end
	local st = stations[r_id]
	if st then
		if f.surface and st.surface_index ~= f.surface then return false end
		return util.network_passes(st.network_name, st.network_mask, f)
	end
	local station = storage.stations[r_id]
	local stop = station and station.entity_stop
	if not (stop and stop.valid) then return false end
	if f.surface and stop.surface_index ~= f.surface then return false end
	return util.network_passes(station.network_name, station.network_mask, f)
end

--- Lint bits of the checks whose findings are errors (LINT_SEVERITY).
util.lint_error_mask = pm.error_mask

--- The error-severity checks station `id` fails that are not acknowledged: the Overview's Misconfigured rule, the
--- one problems-model applies to the Stations rows, so the line and its rows agree.
--- @param id uint station id
--- @param bits int? the station's lint bits (SnapshotStation.lint)
--- @param by_check {[int]: int}? adds 1 per open check
--- @return int open
function util.open_setup_errors(id, bits, by_check)
	return pm.open_errors(id, bits, diag.is_acked, by_check)
end

--- Whether surface `surface_index` holds a Cybersyn station (the manager's surface default falls back to All without).
--- @param surface_index uint
--- @return boolean
function util.surface_has_station(surface_index)
	for _, station in pairs(storage.stations) do
		local stop = station.entity_stop
		if stop and stop.valid and stop.surface_index == surface_index then return true end
	end
	return false
end

--- Station-name terms are not applied to trains.
--- @param tr SnapshotTrain
--- @param f ManagerFilters
--- @param ignore_item boolean?
--- @return boolean
function util.train_passes(tr, f, ignore_item)
	local station = f.station
	if station and tr.p_station_id ~= station and tr.r_station_id ~= station then return false end
	if f.surface and tr.surface_index ~= f.surface then return false end
	if not util.network_passes(tr.network_name, tr.network_mask, f) then return false end
	if f.item and not ignore_item and not tr.manifest_hashes[f.item] then return false end
	if f.terms and not util.train_terms_pass(tr, f.terms) then return false end
	return true
end

--- Text search on trains matches the names of the depot and of the current provider and requester, so searching
--- for a station also finds the trains serving it; a term "#<id>" also matches the train with that id (the stop
--- panel's "Open in manager").
--- @param tr SnapshotTrain
--- @param terms string[] lowercase
--- @return boolean
function util.train_terms_pass(tr, terms)
	local stations = collector.get().stations
	local depot = tr.depot_name and helpers.multilingual_to_lower(tr.depot_name)
	local p = tr.p_station_id and stations[tr.p_station_id]
	local r = tr.r_station_id and stations[tr.r_station_id]
	p = p and p.name_lower
	r = r and r.name_lower
	local id_term = "#" .. tostring(tr.id)
	for i = 1, #terms do
		local term = terms[i]
		if not (term == id_term or (depot and string.find(depot, term, 1, true))
				or (p and string.find(p, term, 1, true))
				or (r and string.find(r, term, 1, true))) then
			return false
		end
	end
	return true
end

--- @param player_data PlayerData
--- @param tab string canonical tab name, e.g. "stations_tab"
--- @param default_column string
--- @return string column
--- @return boolean ascending
function util.get_sort(player_data, tab, default_column)
	local sorts = get_or_create(player_data, "sort")
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

-- Upper bound for a tab without a window layout: about 9 ms per Stations render at 500 rows on a 2,000-station base,
-- so 200 stays near the 5 ms render budget.
util.MAX_PAGE_SIZE = 200

--- Rows per page of a list tab: as many as its window height fits (player_data.layout), at most
--- util.MAX_PAGE_SIZE.
--- @param player_data PlayerData
--- @param tab string?
--- @return integer
function util.page_size(player_data, tab)
	local size = util.MAX_PAGE_SIZE
	local layout = tab and player_data.layout
	local rows = layout and layout.rows_by_tab and layout.rows_by_tab[tab]
	if rows and rows < size then return rows end
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
--- @param size integer? rows per page when the tab gives up some of its rows (default util.page_size)
--- @param fewer integer? rows the page gives up to a strip the tab shows above its list (Trains: wrapped chips)
--- @param range_key string? the range caption's locale key when the rows are not what the tab's summary counts
--- (Trains grouped by depot: "pager-range-rows", group rows included)
--- @return integer first
--- @return integer last
--- @return integer page
--- @return integer pages
function util.paginate(player_data, tab, total, size, fewer, range_key)
	size = math.max((size or util.page_size(player_data, tab)) - (fewer or 0), 1)
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
			caption = { range_key or "cybersyn-gui.pager-range", format.number(first), format.number(last), format.number(total) }
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

--- @class WindowFns
--- @field open fun(player: LuaPlayer, player_data: PlayerData)
--- @field close fun(player: LuaPlayer, player_data: PlayerData)
--- @field focus fun(player: LuaPlayer, player_data: PlayerData, tab: string, focus: ManagerFocus)

--- @type WindowFns?
local window_fns

--- Lets manager.lua open the window, focus a subject in it (a stop panel's click) and close it the way its close
--- button does (a shift-click on a link) without a require cycle.
--- @param fns WindowFns
function util.set_window_fns(fns)
	window_fns = fns
end

--- Items delivered in the last `minutes`, from stats.aggregate, cached per game minute for this player and shared by
--- every view (the Inventory tooltips, the item drill-down), so they never show two figures in the same minute.
--- @param player_data PlayerData
--- @param minutes int
--- @return {[string]: int}
function util.delivered_items(player_data, minutes)
	local minute = math.floor(game.tick / 3600)
	local cache = player_data.delivered_items
	if not (cache and cache.minute == minute) then
		cache = { minute = minute, by_period = {} }
		player_data.delivered_items = cache
	end
	local items = cache.by_period[minutes]
	if not items then
		items = stats.aggregate(minutes).items
		cache.by_period[minutes] = items
	end
	return items
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
	-- No filter is ever hidden: setting one opens the filter row; the manager's render shows it.
	if hash then player_data.filter_row_open = true end
	local elem = player_data.refs and player_data.refs.manager_item_filter
	if elem and elem.valid then
		elem.elem_value = hash and util.signalid_from_hash(hash) or nil
	end
	util.reset_pages(player_data)
end

--- The station chip: a station id, or nil to clear it. An id Cybersyn no longer knows clears it.
--- @param player_data PlayerData
--- @param id uint?
function util.set_station_filter(player_data, id)
	if id and not storage.stations[id] then id = nil end
	if player_data.search_station == id then return end
	player_data.search_station = id
	if id then player_data.filter_row_open = true end
	util.reset_pages(player_data)
end

--- The station chip's station when it still exists; a stale id is dropped (a removed stop), as an unknown item is.
--- @param player_data PlayerData
--- @return uint?
function util.valid_station_filter(player_data)
	local id = player_data.search_station
	if id and not storage.stations[id] then
		player_data.search_station = nil
		id = nil
	end
	return id
end

--- Every item cell's click, in any tab and panel: left sets the item filter and selects the
--- Inventory, which shows the item's drill-down while the filter is set (opening the window when the cell is outside
--- it); shift+left sets the filter and selects Stations; right clears the item filter. A stop panel's slot carries its
--- station (tags.station): the click also sets the station chip, and an in-flight slot (tags.flight) lands on the
--- Trains tab, where the trains carrying it to or from that station are; shift there keeps the tab and leaves the
--- chip off, so the view covers every stop, and right does nothing, as the panel shows no filter.
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param e EventData.on_gui_click
--- @param hash string
function util.item_button_click(player, player_data, e, hash)
	local tags = e.element and e.element.tags
	local station = tags and tags.station
	if e.button == defines.mouse_button_type.right then
		-- A stop panel shows no filter, so its slots have nothing to clear.
		if station then return end
		util.set_item_filter(player_data, nil)
	elseif e.button == defines.mouse_button_type.left then
		local name = unhash_signal(hash)
		interface_raise_item_selected(player.index, name)
		if station and window_fns then
			-- Through manager.focus: a chip, search or place filter left from earlier would hide the very station the
			-- slot belongs to, and a closed window would otherwise open on the surface default. Shift lands on the
			-- same tab without the station chip, so the drill-down or Trains cover every stop.
			local tab = tags.flight and "trains_tab" or "inventory_tab"
			window_fns.focus(player, player_data, tab, { item = hash, station = not e.shift and station or nil,
				reveal = tags.flight and { all = true } or nil })
			return
		end
		util.set_item_filter(player_data, hash)
		local tab = e.shift and "stations_tab" or "inventory_tab"
		if not util.select_tab(player_data, tab) then player_data.selected_tab = tab end
		if not player_data.is_manager_open then
			-- The train panel's cells: a left click opens the window on the drill-down.
			if not e.shift and window_fns then window_fns.open(player, player_data) end
			return
		end
	else
		return
	end
	util.rerender(player, player_data)
end

--- Restyles a tab's sort header checkboxes to match the stored sort, since the header is built with a fixed
--- default column and the stored sort outlives window rebuilds.
--- @param cell LuaGuiElement? a header cell holding a sort checkbox
--- @param column string
--- @param ascending boolean
function util.sync_sort_header(cell, column, ascending)
	if not (cell and cell.valid) then return end
	for _, child in pairs(cell.children) do
		if child.type == "checkbox" then
			local tags = child.tags
			if tags.column then
				local active = tags.column == column
				local style = active and "ltnm_selected_sort_checkbox" or "ltnm_sort_checkbox"
				if child.style.name ~= style then child.style = style end
				-- An inactive arrow shows the direction a click on it would sort, not whatever it was last left at.
				local state
				if active then
					state = not ascending
				else
					state = tags.default_state
				end
				if state ~= nil and child.state ~= state then child.state = state end
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
		elem_tooltip = util.elem_tooltip(hash),
		tags = { kind = "item", id = hash },
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
		if util.valid_sprite(sprite) then
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

--- Opens an entity's GUI from a manager link. An unpinned manager stays on screen and takes player.opened back when
--- that GUI closes (manager.on_linked_gui_closed), so a second Escape closes the manager.
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param entity LuaEntity
function util.open_entity(player, player_data, entity)
	util.switch_opened(player, function() player.opened = entity end)
	if player_data.pinning or not player_data.is_manager_open then return end
	local window = player_data.refs.manager_window
	if player.opened_gui_type == defines.gui_type.none then
		player.opened = window
	elseif player.opened ~= window then
		-- What holds player.opened now, not the entity: Cybersyn's combinator replaces the entity's window with its own.
		player_data.return_to = player.opened
	end
end

-- ---------------------------------------------------------------- links

local elem_tooltip_cache = {}

--- The native item or fluid tooltip of an item hash (stacks above a custom tooltip), or nil for anything else.
--- @param hash string
--- @return ElemID?
function util.elem_tooltip(hash)
	local cached = elem_tooltip_cache[hash]
	if cached == nil then
		local name, quality = unhash_signal(hash)
		if prototypes.item[name] and not (quality and not prototypes.quality[quality]) then
			cached = { type = "item-with-quality", name = name, quality = quality or "normal" }
		elseif prototypes.fluid[name] then
			cached = { type = "fluid", name = name }
		else
			cached = false
		end
		elem_tooltip_cache[hash] = cached
	end
	return cached or nil
end

--- The modifier line at the end of every link cell's tooltip.
util.LINK_FOOTER = { "cybersyn-gui.link-footer" }

local MARKER_TICKS = 300

--- One marker pair per player (map and world view); drawing a new pair removes the old one.
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param target LuaEntity
function util.draw_markers(player, player_data, target)
	local old = player_data.markers
	if old then
		for _, id in ipairs(old) do
			local obj = rendering.get_object_by_id(id)
			if obj and obj.valid then obj.destroy() end
		end
	end
	local common = {
		color = { 1, 0.27, 0.27 },
		target = target,
		surface = target.surface,
		radius = 2,
		filled = false,
		width = 6,
		time_to_live = MARKER_TICKS,
		players = { player },
	}
	common.render_mode = "game"
	local world = rendering.draw_circle(common)
	common.render_mode = "chart"
	common.radius = 4
	local chart = rendering.draw_circle(common)
	player_data.markers = { world.id, chart.id }
end

local refresh_toggles_fn

--- Lets manager.lua repaint the title-bar toggles without a require cycle.
--- @param fn fun(player_data: PlayerData)
function util.set_refresh_toggles(fn)
	refresh_toggles_fn = fn
end

-- The zoom a click on a vanilla map pin lands on, measured: re-measure if the pin's zoom changes. It must be written
-- after centered_on, which enters remote view and resets the zoom.
local SHOW_ZOOM = 1.5

--- Shift-click on a link: the view a click on the target's map pin gives (remote view following the target at the
--- screen centre, zoom 1.5) and a marker pair on it. Entering remote view closes the GUI that holds player.opened, so
--- an unpinned manager takes it back in the same switch and stays open, with Back to the view it came from.
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param target LuaEntity
--- @param follow LuaEntity? an entity for remote view to follow (a train's front stock)
function util.show_on_map(player, player_data, target, follow)
	local window = player_data.refs and player_data.refs.manager_window
	local hold = player_data.is_manager_open and not player_data.pinning and window and window.valid
	if hold and not player_data.map_from then
		-- A player whose own view is the remote one (on a space platform) never leaves remote view: Back returns them
		-- to where they looked from.
		player_data.map_from = { controller = player.controller_type, position = player.position,
			surface = player.surface_index }
	end
	util.switch_opened(player, function()
		-- centered_on switches to remote view and to the target's surface itself; set_controller{type = remote} would
		-- reset the zoom to 0.6, and a zoom written before the switch does not stick.
		player.centered_on = follow or target
		player.zoom = SHOW_ZOOM
		if hold then player.opened = window end
	end)
	util.draw_markers(player, player_data, target)
	if refresh_toggles_fn then refresh_toggles_fn(player_data) end
end

--- @param e EventData.on_gui_click
--- @return string? kind
--- @return any id
local function link_target(e)
	local tags = e.element.tags
	local kind, id = tags.kind, tags.id
	if kind and id ~= nil then return kind, id end
	if tags.item_hash then return "item", tags.item_hash end
	if tags.train_id then return "train", tags.train_id end
	if tags.stop_kind then return tags.stop_kind, tags.stop_id end
	if tags.station_id then return "station", tags.station_id end
	return nil, nil
end

local pin_fn

--- Lets extras.lua take control+shift clicks (add a map pin) without a require cycle.
--- @param fn fun(player: LuaPlayer, kind: string, id: uint)
function util.set_pin(fn)
	pin_fn = fn
end

--- Whether a click came from inside the open manager window, not from a stop or train panel beside a game window.
--- Synthetic events (the Log rows) carry a plain table for an element and come from the window.
--- @param player_data PlayerData
--- @param element LuaGuiElement|table?
--- @return boolean
local function in_manager(player_data, element)
	if not player_data.is_manager_open then return false end
	if not (element and element.object_name == "LuaGuiElement") then return true end
	local window = player_data.refs and player_data.refs.manager_window
	if not (window and window.valid) then return false end
	local index = window.index
	while element do
		if element.index == index then return true end
		element = element.parent
	end
	return false
end

--- Shift-click on a link inside the window: the map view replaces the window, pinned or not, instead of the
--- window holding over the map with Back. From a panel the window is not involved and stays as it is.
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param e EventData.on_gui_click
--- @param target LuaEntity
--- @param follow LuaEntity?
local function show_from_link(player, player_data, e, target, follow)
	if window_fns and in_manager(player_data, e.element) then window_fns.close(player, player_data) end
	util.show_on_map(player, player_data, target, follow)
end

--- Every link cell's click: left = open, shift = show on map (closing the window), control = combinator, alt = control combinator,
--- control + shift = a map pin, right on an item = clear the item filter. Train and stop links take no right-click.
--- Tags {kind = "station"|"depot"|"refueler"|"train"|"item"|"entity", id};
--- "entity" is a stop or combinator Cybersyn has not registered, by unit number, as the lint registry recorded it, or a
--- Cybersyn combinator by unit number (a Stations row's inventory marker). The older tag shapes of the Stations and
--- Trains rows are read too.
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param e EventData.on_gui_click
--- @param kind string? the target when the cell's tags do not carry it (a cell whose tags name something else, e.g. the Trains state icon)
--- @param id (uint|string)?
function util.handle_link_click(player, player_data, e, kind, id)
	if not kind then kind, id = link_target(e) end
	if not kind then return end
	if kind == "item" then
		util.item_button_click(player, player_data, e, id)
		return
	end
	if e.button and e.button ~= defines.mouse_button_type.left then return end
	if e.control and e.shift then
		if kind ~= "entity" and pin_fn then pin_fn(player, kind, id) end
		return
	end
	if kind == "train" then
		local train = storage.trains[id]
		local entity = train and train.entity
		if not (entity and entity.valid) then
			util.error_flying_text(player, { "cybersyn-message.error-train-is-invalid" })
			return
		end
		local locomotive = flib_train.get_main_locomotive(entity)
		if e.shift then
			local front = entity.front_stock
			if front then show_from_link(player, player_data, e, front, front) end
			return
		end
		if not (locomotive and locomotive.valid) then
			util.error_flying_text(player, { "cybersyn-gui.train-has-no-locomotive" })
			return
		end
		util.open_entity(player, player_data, locomotive)
		return
	end
	if kind == "entity" then
		local entity = lint.registry_entity(id)
		if not entity and type(id) == "number" then
			-- A Stations row's inventory marker: a combinator Cybersyn registered, which the lint registry does not
			-- hold (game.get_entity_by_unit_number needs a prototype flag the combinator does not set).
			local to_comb = storage.to_comb
			entity = to_comb and to_comb[id] or nil
		end
		if not (entity and entity.valid) then
			util.error_flying_text(player, { "cybersyn-message.error-station-is-invalid" })
		elseif e.shift then
			show_from_link(player, player_data, e, entity)
		else
			util.open_entity(player, player_data, entity)
		end
		return
	end
	local record
	if kind == "station" then
		record = storage.stations[id]
	elseif kind == "depot" then
		record = storage.depots[id]
	elseif kind == "refueler" then
		record = storage.refuelers[id]
	end
	local stop = record and record.entity_stop
	if not (stop and stop.valid) then
		util.error_flying_text(player, { "cybersyn-message.error-station-is-invalid" })
		return
	end
	if e.shift then
		show_from_link(player, player_data, e, stop)
	elseif e.control then
		local comb = kind == "station" and record.entity_comb1 or record.entity_comb
		if comb and comb.valid then
			util.open_entity(player, player_data, comb)
		else
			util.error_flying_text(player, { "cybersyn-message.error-cybernetic-combinator-not-found" })
		end
	elseif e.alt and kind == "station" then
		local comb = record.entity_comb2
		if comb and comb.valid then
			util.open_entity(player, player_data, comb)
		else
			util.error_flying_text(player, { "cybersyn-message.error-station-control-combinator-not-found" })
		end
	else
		util.open_entity(player, player_data, stop)
	end
end

--- @param e EventData.on_gui_click
function util.handle.link_click(player, player_data, refs, e)
	util.touch_hover(e)
	util.handle_link_click(player, player_data, e)
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
	player_data.return_to = nil
	player_data.map_from = nil
	player_data.hover = nil
	player_data.inventory_cache = nil
	player_data.delivered_items = nil
	player_data.trains_query = nil
	player_data.overview_failing = nil
	-- Render signatures and row memos only skip redundant updates, and the memos reference snapshot records, so
	-- they are not worth keeping in the save while closed; a container without them updates every child once on
	-- the next render.
	local states = player_data.gui_state
	if states then
		for _, state in pairs(states) do
			state.sigs = nil
			state.cells = nil
			state.content_sigs = nil
		end
	end

	if player.opened == refs.manager_window then
		player.opened = nil
	end

	player.set_shortcut_toggled("cybersyn-toggle-gui", false)
	collector.on_last_close()
	-- The Stations query cache stays with a kept snapshot: a reopen folds in what changed instead of classifying and
	-- sorting every station in its first paint (12-15 ms on a 2,000-station base). collector.release drops it.
	if not storage.manager.release_at then player_data.stations_query = nil end
end

--- util.sync_children for a `table` element whose rows are `columns` cells wide. The first `first` children (a
--- header row, say) are left alone. Each entry's `build` returns one GuiElemDef per cell and `update` receives the
--- row's cells as an array; keys, sigs and `hold` work as in util.sync_children.
--- @param tbl LuaGuiElement
--- @param columns integer
--- @param first integer
--- @param entries {key: string|number, build: fun(): flib.GuiElemDef[], update: fun(cells: LuaGuiElement[], entry: table, index: integer)?, sig: (string|number)?}[]
--- @param state {keys: (string|number)[]?, sigs: {[string|number]: string|number}?, dirty: true?} from util.gui_state
--- @param hold boolean?
--- @return "updated"|"held"|"rebuilt"
function util.sync_table_rows(tbl, columns, first, entries, state, hold)
	local n = #entries
	local old = state.keys
	local sigs = state.sigs
	if not old or not sigs then
		old = nil
		sigs = {}
		state.sigs = sigs
	end
	-- Unchanged keys and sigs (the common render) read no element: `tbl.children` wraps every cell of the table.
	local same = old ~= nil and #old == n
	if same then
		for i = 1, n do
			if old[i] ~= entries[i].key then
				same = false
				break
			end
		end
	end
	local children
	if same then
		for i = 1, n do
			local entry = entries[i]
			local fn = entry.update
			local sig = entry.sig
			if fn and (sig == nil or sigs[entry.key] ~= sig) then
				if not children then
					children = tbl.children
					-- Someone else changed the table: rebuild instead of writing into the wrong cells.
					if first + n * columns ~= #children then
						same = false
						break
					end
				end
				if sig ~= nil then sigs[entry.key] = sig end
				local cells = {}
				local base = first + (i - 1) * columns
				for c = 1, columns do cells[c] = children[base + c] end
				fn(cells, entry, i)
			end
		end
		if same then
			state.dirty = nil
			return "updated"
		end
	end
	children = children or tbl.children
	if old and first + #old * columns ~= #children then old = nil end
	local keys = {}
	for i = 1, n do keys[i] = entries[i].key end

	local function update(entry, row, index)
		local fn = entry.update
		if not fn then return end
		local sig = entry.sig
		if sig ~= nil then
			if sigs[entry.key] == sig then return end
			sigs[entry.key] = sig
		end
		local cells = {}
		local base = first + (row - 1) * columns
		for c = 1, columns do
			cells[c] = children[base + c]
		end
		fn(cells, entry, index)
	end

	local prefix = 0
	if old then
		local m = math.min(#old, n)
		while prefix < m and old[prefix + 1] == keys[prefix + 1] do
			prefix = prefix + 1
		end
		if hold then
			local index_of = {}
			for i = 1, n do
				index_of[keys[i]] = i
			end
			for j = 1, #old do
				local i = index_of[old[j]]
				if i then
					update(entries[i], j, i)
				end
			end
			state.dirty = true
			return "held"
		end
	end

	for i = 1, prefix do
		update(entries[i], i, i)
	end
	-- Rows past the common prefix are rebound in place when their entries can (`rebind` rewrites every cell, tags
	-- included): removing one row then rewrites the rows below it instead of destroying and building them again.
	local reuse = prefix
	local old_n = old and #old or 0
	while reuse < math.min(old_n, n) and entries[reuse + 1].rebind do reuse = reuse + 1 end
	for i = prefix + 1, reuse do
		local entry = entries[i]
		local cells = {}
		local base = first + (i - 1) * columns
		for c = 1, columns do cells[c] = children[base + c] end
		entry.rebind(cells, entry, i)
	end
	for j = #children, first + reuse * columns + 1, -1 do
		children[j].destroy()
	end
	local new_sigs = {}
	for i = 1, prefix do
		local key = keys[i]
		new_sigs[key] = sigs[key]
	end
	for i = prefix + 1, reuse do
		local entry = entries[i]
		if entry.sig ~= nil then new_sigs[entry.key] = entry.sig end
	end
	for i = reuse + 1, n do
		local entry = entries[i]
		for _, def in ipairs(entry.build()) do
			gui.add(tbl, def)
		end
		if entry.sig ~= nil then new_sigs[entry.key] = entry.sig end
	end
	state.sigs = new_sigs
	state.keys = keys
	state.dirty = nil
	return "rebuilt"
end

gui.add_handlers(util.handle, util.wrapper, "cybersyn_util")

return util
