-- The manager's filters: the station search, the item, network, surface and station chip a player sets, and the
-- predicates every tab applies them with.

local collector = require("scripts.gui.collector")
local util = require("scripts.gui.util")
local listing = require("scripts.gui.utils.listing")

local filters = {}

--- Whitespace-separated terms of a station-name query. Terms are matched as plain substrings (string.find with
--- plain = true), never as Lua patterns, so "[", "%" or "-" in a query match themselves. The query is lowercased the
--- way station names are (helpers.multilingual_to_lower), which leaves rich-text tags as they are, so a query that
--- contains an icon tag matches the names that show that icon.
--- @param text string?
--- @return string[]?
function filters.search_terms(text)
	if not text then return nil end
	local terms = {}
	for term in string.gmatch(helpers.multilingual_to_lower(text), "%S+") do
		terms[#terms + 1] = term
	end
	if #terms == 0 then return nil end
	return terms
end

--- True when every term occurs in `name_lower` (already normalised).
--- @param name_lower string
--- @param terms string[]
--- @return boolean
function filters.terms_match(name_lower, terms)
	for i = 1, #terms do
		if not string.find(name_lower, terms[i], 1, true) then return false end
	end
	return true
end

--- @param player_data PlayerData
--- @param text string?
function filters.set_search_query(player_data, text)
	if text == "" then text = nil end
	player_data.search_query = text
	player_data.search_terms = filters.search_terms(text)
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
function filters.get_filters(player_data)
	local terms = player_data.search_terms
	if terms == nil and player_data.search_query then
		terms = filters.search_terms(player_data.search_query)
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
function filters.filters_active(f, ignore_item)
	return f.terms ~= nil or f.network ~= nil or f.mask ~= -1 or f.surface ~= nil or f.station ~= nil
		or (not ignore_item and f.item ~= nil)
end

local btest = bit32.btest

--- @param network_name string?
--- @param network_mask int|{[string]: int}?
--- @param f ManagerFilters
--- @return boolean
function filters.network_passes(network_name, network_mask, f)
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
	if not filters.network_passes(row.network_name, row.networks or row.mask, f) then return false end
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
function filters.row_passes(row, f, ignore_item)
	local st = row.st
	if f.station and st.id ~= f.station then return false end
	if f.surface and st.surface_index ~= f.surface then return false end
	local terms = f.terms
	if terms and not filters.terms_match(st.name_lower, terms) then return false end
	return row_own_passes(row, f, ignore_item)
end

--- A station passes when any of its rows does. A record without rows (hand-built) is one row on its own lists.
--- @param st SnapshotStation
--- @param f ManagerFilters
--- @param ignore_item boolean?
--- @return boolean
function filters.station_passes(st, f, ignore_item)
	if f.station and st.id ~= f.station then return false end
	if f.surface and st.surface_index ~= f.surface then return false end
	local terms = f.terms
	if terms and not filters.terms_match(st.name_lower, terms) then return false end
	local rows = st.rows
	if rows == nil then
		if not filters.network_passes(st.network_name, st.network_mask, f) then return false end
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
function filters.overview_filters(player_data)
	local f = filters.get_filters(player_data)
	f.terms = nil
	-- The Overview ignores the station chip (its tooltip says so there).
	f.station = nil
	if f.item and not util.signal_hash_valid(f.item) then f.item = nil end
	return f
end

--- A plain string of every filter field, for caches keyed on the filters.
--- @param f ManagerFilters
--- @return string
function filters.filter_signature(f)
	return table.concat({
		f.terms and table.concat(f.terms, " ") or "", f.item or "", f.network or "", f.mask, f.surface or "",
		f.station or "",
	}, "\1")
end

--- Whether network name, network ID or surface is set: the filters that decide by a station's place, not its items.
--- @param f ManagerFilters
--- @return boolean
function filters.place_filters_active(f)
	return f.network ~= nil or f.mask ~= -1 or f.surface ~= nil
end

--- The locale-key suffix of the drill-down's empty texts: with a place filter or the station chip set, "No
--- station provides this item" would deny stations the filters merely hide, so the text names the filters.
--- Used as {"cybersyn-gui.item-empty-<table>" .. filters.empty_filter_suffix(f)}.
--- @param f ManagerFilters
--- @return string
function filters.empty_filter_suffix(f)
	if f.station ~= nil or filters.place_filters_active(f) then return "-filtered" end
	return ""
end

--- Whether requester `r_id` of an Unserved entry passes the network name, network ID and surface filters: read
--- from its snapshot record, or from the live station while the first pass is still collecting. A requester that is
--- gone passes only while none of those filters is set.
--- @param r_id uint
--- @param stations {[uint]: SnapshotStation}
--- @param f ManagerFilters
--- @return boolean
function filters.requester_passes(r_id, stations, f)
	if not filters.place_filters_active(f) then return true end
	local st = stations[r_id]
	if st then
		if f.surface and st.surface_index ~= f.surface then return false end
		return filters.network_passes(st.network_name, st.network_mask, f)
	end
	local station = storage.stations[r_id]
	local stop = station and station.entity_stop
	if not (stop and stop.valid) then return false end
	if f.surface and stop.surface_index ~= f.surface then return false end
	return filters.network_passes(station.network_name, station.network_mask, f)
end

--- Whether surface `surface_index` holds a Cybersyn station (the manager's surface default falls back to All without).
--- @param surface_index uint
--- @return boolean
function filters.surface_has_station(surface_index)
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
function filters.train_passes(tr, f, ignore_item)
	local station = f.station
	if station and tr.p_station_id ~= station and tr.r_station_id ~= station then return false end
	if f.surface and tr.surface_index ~= f.surface then return false end
	if not filters.network_passes(tr.network_name, tr.network_mask, f) then return false end
	if f.item and not ignore_item and not tr.manifest_hashes[f.item] then return false end
	if f.terms and not filters.train_terms_pass(tr, f.terms) then return false end
	return true
end

--- Text search on trains matches the names of the depot and of the current provider and requester, so searching
--- for a station also finds the trains serving it; a term "#<id>" also matches the train with that id (the stop
--- panel's "Open in manager").
--- @param tr SnapshotTrain
--- @param terms string[] lowercase
--- @return boolean
function filters.train_terms_pass(tr, terms)
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

--- Applies an item filter (hash or nil) to player data and the toolbar chooser.
--- @param player_data PlayerData
--- @param hash string?
function filters.set_item_filter(player_data, hash)
	if hash and not util.signal_hash_valid(hash) then hash = nil end
	player_data.search_item = hash
	-- No filter is ever hidden: setting one opens the filter row; the manager's render shows it.
	if hash then player_data.filter_row_open = true end
	local elem = player_data.refs and player_data.refs.manager_item_filter
	if elem and elem.valid then
		elem.elem_value = hash and util.signalid_from_hash(hash) or nil
	end
	listing.reset_pages(player_data)
end

--- The station chip: a station id, or nil to clear it. An id Cybersyn no longer knows clears it.
--- @param player_data PlayerData
--- @param id uint?
function filters.set_station_filter(player_data, id)
	if id and not storage.stations[id] then id = nil end
	if player_data.search_station == id then return end
	player_data.search_station = id
	if id then player_data.filter_row_open = true end
	listing.reset_pages(player_data)
end

--- The station chip's station when it still exists; a stale id is dropped (a removed stop), as an unknown item is.
--- @param player_data PlayerData
--- @return uint?
function filters.valid_station_filter(player_data)
	local id = player_data.search_station
	if id and not storage.stations[id] then
		player_data.search_station = nil
		id = nil
	end
	return id
end

return filters
